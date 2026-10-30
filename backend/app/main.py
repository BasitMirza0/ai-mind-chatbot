import asyncio
import json
import logging
from contextlib import asynccontextmanager

import anyio
import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.concurrency import run_in_threadpool
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse, StreamingResponse

from .auth import FirebaseVerifier, Identity, authenticated_user
from .config import Settings
from .diagnostics import trace
from .errors import ApiError
from .images import validated_image
from .limits import MemoryLimiter, RedisLimiter, admission
from .middleware import RequestBoundary
from .provider import GroqProvider
from .schemas import (
    ChatRequest,
    DeltaEvent,
    DoneEvent,
    ErrorResponse,
    HealthResponse,
    ImageRequest,
    ImageResponse,
)


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


async def while_connected(request: Request, operation):
    """Cancel pre-stream/image work after FastAPI has consumed the body."""
    async def disconnect():
        # is_disconnected() uses an already-cancelled AnyIO scope to poll.
        # That scope can swallow our task.cancel(), leaving cleanup's gather()
        # waiting forever. Await the ASGI receiver directly instead. This watcher
        # is stopped before StreamingResponse takes ownership of the receiver.
        while True:
            if (await request.receive())["type"] == "http.disconnect":
                return

    work = asyncio.ensure_future(operation)
    watcher = asyncio.create_task(disconnect())
    try:
        done, _ = await asyncio.wait({work, watcher}, return_when=asyncio.FIRST_COMPLETED)
        if work in done:
            return await work
        raise ApiError(499, "client_disconnected", "The client disconnected.")
    finally:
        for task in (work, watcher):
            if not task.done():
                task.cancel()
        await asyncio.gather(work, watcher, return_exceptions=True)


def create_app(settings: Settings | None = None, *, verifier=None, client=None, limiter=None):
    settings = settings or Settings()
    verifier = verifier or FirebaseVerifier(settings)
    limiter = limiter or (RedisLimiter(settings) if settings.rate_limit_backend == "redis" else MemoryLimiter(settings))
    http = client or httpx.AsyncClient(
        timeout=httpx.Timeout(settings.provider_read_timeout_seconds,
                              connect=settings.connect_timeout_seconds),
        limits=httpx.Limits(max_connections=50, max_keepalive_connections=10),
        follow_redirects=False, trust_env=False,
    )
    # Application code never logs headers, provider bodies, prompts or tokens.
    # Prevent HTTP client debug configuration from logging upstream traffic.
    logging.getLogger("httpx").disabled = True
    logging.getLogger("httpcore").disabled = True

    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            await http.aclose()
            await limiter.close()
            verifier.close()

    app = FastAPI(title="AI Mind API", version="0.1.0", lifespan=lifespan,
                  docs_url="/docs" if settings.environment == "development" else None,
                  redoc_url=None)
    app.add_middleware(RequestBoundary, settings=settings)
    app.state.verifier = verifier
    app.state.limiter = limiter
    app.state.provider = GroqProvider(settings, http)

    @app.exception_handler(ApiError)
    async def api_error(request, error):
        headers = {"WWW-Authenticate": "Bearer"} if error.status == 401 else {}
        if error.status == 429:
            headers["Retry-After"] = "60"
        return JSONResponse(error.payload(request.state.request_id), error.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        # FastAPI's default detail includes input values; never echo private input.
        return await api_error(request, ApiError(422, "invalid_request", "Request fields are invalid or exceed limits."))

    @app.exception_handler(HTTPException)
    async def http_error(request, error):
        return await api_error(request, ApiError(error.status_code, "http_error", "Request could not be processed."))

    @app.exception_handler(Exception)
    async def unexpected_error(request, error):
        return await api_error(request, ApiError(500, "internal_error", "An unexpected backend error occurred.", True))

    @app.get("/health", response_model=HealthResponse)
    async def health():
        # Liveness only; does not claim credentials, Firebase, Redis or models work.
        return HealthResponse()

    error_responses = {code: {"model": ErrorResponse} for code in (401, 403, 413, 422, 429, 502, 503, 504)}

    @app.post("/v1/chat/stream", response_class=StreamingResponse, responses=error_responses,
              description="SSE delta {text}, then exactly one done {finish_reason,request_id} or error {error}. Never treat an error as assistant text.")
    async def chat(payload: ChatRequest, request: Request, identity: Identity = Depends(authenticated_user)):
        if sum(len(m.content) for m in payload.messages) > settings.max_history_characters:
            raise ApiError(413, "context_too_large", "Conversation context exceeds the configured limit.")
        lease = await limiter.acquire(identity.uid)
        iterator = app.state.provider.stream(payload, request.state.request_id)
        try:
            # Provider status/initial errors remain real HTTP errors before SSE starts.
            first = await while_connected(request, anext(iterator))
        except BaseException:
            with anyio.CancelScope(shield=True):
                await iterator.aclose()
                await limiter.release(identity.uid, lease)
            raise

        async def events():
            terminal = False
            try:
                event, value = first
                while True:
                    if event == "delta":
                        yield sse("delta", DeltaEvent(text=value).model_dump())
                    elif event == "done":
                        terminal = True
                        trace(request.state.request_id, "terminal_prepared", terminal="done", finish_reason=value)
                        yield sse("done", DoneEvent(finish_reason=value, request_id=request.state.request_id).model_dump())
                        break
                    else:
                        raise ApiError(502, "invalid_provider_stream", "AI returned an invalid stream.", True)
                    try:
                        event, value = await anext(iterator)
                    except StopAsyncIteration:
                        raise ApiError(502, "incomplete_response", "AI connection ended before completion. Please retry.", True) from None
            except ApiError as error:
                terminal = True
                trace(request.state.request_id, "terminal_prepared", terminal="error", category=error.code)
                yield sse("error", error.payload(request.state.request_id))
            except asyncio.CancelledError:
                trace(request.state.request_id, "downstream_cancelled", category="client_disconnect")
                raise
            except Exception:
                terminal = True
                trace(request.state.request_id, "terminal_prepared", terminal="error", category="stream_failed")
                yield sse("error", ApiError(502, "stream_failed", "AI generation failed. Please retry.", True).payload(request.state.request_id))
            finally:
                trace(request.state.request_id, "stream_closed", terminal=terminal)
                with anyio.CancelScope(shield=True):
                    await iterator.aclose()
                    await limiter.release(identity.uid, lease)

        return StreamingResponse(events(), media_type="text/event-stream",
                                 headers={"X-Accel-Buffering": "no"})

    @app.post("/v1/images/analyze", response_model=ImageResponse, responses=error_responses)
    async def image(payload: ImageRequest, request: Request, identity: Identity = Depends(authenticated_user)):
        if len(payload.prompt) + sum(len(m.content) for m in payload.history) > settings.max_history_characters:
            raise ApiError(413, "context_too_large", "Conversation context exceeds the configured limit.")
        async with admission(limiter, identity.uid):
            raw = await run_in_threadpool(validated_image, payload, settings)
            result = await while_connected(request, app.state.provider.image(payload, raw))
            return ImageResponse(text=result, request_id=request.state.request_id)

    return app


app = create_app()
