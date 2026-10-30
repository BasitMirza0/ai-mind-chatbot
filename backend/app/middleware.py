import asyncio
from uuid import uuid4

from starlette.responses import JSONResponse

from .diagnostics import trace
from .errors import ApiError


class RequestBoundary:
    """Bound raw ASGI bodies, including chunked bodies, before JSON parsing."""

    def __init__(self, app, settings):
        self.app, self.settings = app, settings

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        request_id = uuid4().hex
        scope.setdefault("state", {})["request_id"] = request_id
        response_started = False
        trace(request_id, "request_received")

        async def safe_send(message):
            nonlocal response_started
            if message["type"] == "http.response.start":
                response_started = True
                message["headers"] = [*message.get("headers", []),
                                      (b"x-request-id", request_id.encode()),
                                      (b"cache-control", b"no-store"),
                                      (b"x-content-type-options", b"nosniff")]
            await send(message)
            if message["type"] == "http.response.start":
                trace(request_id, "response_headers", status=message["status"])
            elif message["type"] == "http.response.body":
                body = message.get("body", b"")
                if body.startswith((b"event: done\n", b"event: error\n")):
                    trace(request_id, "terminal_sent", terminal="done" if body.startswith(b"event: done") else "error")

        try:
            headers = dict(scope.get("headers", []))
            length = headers.get(b"content-length")
            if length is not None:
                try:
                    count = int(length)
                except ValueError:
                    raise ApiError(400, "invalid_request", "Invalid request length.") from None
                if count < 0:
                    raise ApiError(400, "invalid_request", "Invalid request length.")
                if count > self.settings.max_request_bytes:
                    raise ApiError(413, "request_too_large", "Request exceeds the configured size limit.")
            body = bytearray()
            async with asyncio.timeout(self.settings.body_timeout_seconds):
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    body.extend(message.get("body", b""))
                    if len(body) > self.settings.max_request_bytes:
                        raise ApiError(413, "request_too_large", "Request exceeds the configured size limit.")
                    if not message.get("more_body", False):
                        break
        except TimeoutError:
            error = ApiError(408, "request_timeout", "Request upload timed out.", True)
            return await JSONResponse(error.payload(request_id), status_code=408)(scope, receive, safe_send)
        except ApiError as error:
            return await JSONResponse(error.payload(request_id), status_code=error.status)(scope, receive, safe_send)

        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        try:
            await self.app(scope, replay, safe_send)
        except Exception:
            # Do not let a server traceback serialize private exception arguments.
            # Stream errors have their own terminal event handler; never send a
            # second HTTP response if headers have already been written.
            if not response_started:
                error = ApiError(500, "internal_error", "An unexpected backend error occurred.", True)
                await JSONResponse(error.payload(request_id), status_code=500)(scope, receive, safe_send)
