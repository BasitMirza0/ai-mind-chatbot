import asyncio
import base64
import json
from collections.abc import AsyncIterator

import anyio
import httpx

from .config import Settings
from .diagnostics import trace
from .errors import ApiError
from .schemas import ChatRequest, ImageRequest
from .sse import sse_data

CHAT_PROMPT = (
    "You are AI Mind, a helpful, clear, friendly assistant. "
    "Use Markdown when helpful. Do not claim to browse or access live data."
)
VOICE_PROMPT = (
    "You are AI Mind, a warm conversational voice assistant. Respond in the same "
    "language as the user, in two or three concise sentences. Use plain text, "
    "without Markdown, code blocks or lists. Do not claim access to live data."
)
VISION_PROMPT = (
    "You are AI Mind, an assistant with image understanding. Describe visible "
    "content and answer the user's question. Do not claim to generate images."
)


def provider_error(status: int) -> ApiError:
    if status == 429:
        return ApiError(429, "provider_busy", "AI capacity is temporarily limited. Try again later.", True)
    if status in (401, 403):
        return ApiError(503, "provider_configuration", "The AI provider is not configured correctly.")
    if status in (400, 404, 413, 422):
        return ApiError(502, "provider_rejected", "The AI provider could not process this request.")
    return ApiError(502, "provider_unavailable", "The AI provider is temporarily unavailable.", True)


class GroqProvider:
    # Host is fixed: clients cannot choose an upstream endpoint or model.
    URL = "https://api.groq.com/openai/v1/chat/completions"

    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        self.settings, self.client = settings, client

    def _headers(self):
        key = self.settings.groq_api_key.get_secret_value()
        if not key:
            raise ApiError(503, "provider_not_configured", "AI is not configured on the backend yet.")
        return {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    async def stream(self, payload: ChatRequest, request_id: str = "unassigned") -> AsyncIterator[tuple[str, str]]:
        body = {
            "model": self.settings.groq_text_model,
            "messages": [{"role": "system", "content": VOICE_PROMPT if payload.mode == "voice" else self.settings.chat_instructions},
                         *[m.model_dump() for m in payload.messages]],
            "max_completion_tokens": self.settings.max_output_tokens,
            "stream": True,
        }
        # Do not keep a timeout context across a yield: initial prefetch and
        # StreamingResponse consume this generator from different asyncio tasks.
        deadline = asyncio.get_running_loop().time() + self.settings.stream_timeout_seconds
        response = None
        finish = None
        terminal_seen = False
        output_chars = 0
        timeout_category = "provider_header_timeout"
        trace(request_id, "upstream_started", max_output_tokens=self.settings.max_output_tokens)
        try:
            request = self.client.build_request("POST", self.URL, headers=self._headers(), json=body)
            async with asyncio.timeout(self.settings.stream_timeout_seconds):
                response = await self.client.send(request, stream=True)
            trace(request_id, "upstream_headers", status=response.status_code)
            if response.status_code != 200:
                raise provider_error(response.status_code)
            if "text/event-stream" not in response.headers.get("content-type", ""):
                raise ApiError(502, "invalid_provider_stream", "AI returned an invalid stream.", True)
            finish = None
            received_text = False
            output_chars = 0
            events = sse_data(response.aiter_bytes()).__aiter__()
            while True:
                remaining = deadline - asyncio.get_running_loop().time()
                timeout_category = "provider_deadline" if remaining <= self.settings.provider_read_timeout_seconds else "provider_idle_timeout"
                if remaining <= 0:
                    raise TimeoutError
                try:
                    async with asyncio.timeout(min(remaining, self.settings.provider_read_timeout_seconds)):
                        data = await anext(events)
                except StopAsyncIteration:
                    break
                if data == "[DONE]":
                    if finish not in ("stop", "length"):
                        raise ApiError(502, "incomplete_response", "AI did not complete its response. Please retry.", True)
                    if not received_text and finish != "length":
                        raise ApiError(502, "incomplete_response", "AI returned no answer. Please retry.", True)
                    trace(request_id, "upstream_terminal", finish_reason=finish, characters=output_chars)
                    terminal_seen = True
                    yield "done", finish
                    return
                event = json.loads(data)
                if "error" in event:
                    raise ApiError(502, "provider_stream_error", "AI generation failed. Please retry.", True)
                choices = event.get("choices", [])
                if not choices:
                    continue
                choice = choices[0]
                content = choice.get("delta", {}).get("content")
                if content is not None and not isinstance(content, str):
                    raise ValueError("Invalid delta")
                if content:
                    received_text = received_text or bool(content.strip())
                    output_chars += len(content)
                    if output_chars > 100_000:
                        raise ValueError("Oversized output")
                    yield "delta", content
                if choice.get("finish_reason") is not None:
                    finish = choice["finish_reason"]
                    trace(request_id, "upstream_finish", finish_reason=finish if finish in ("stop", "length", "content_filter", "tool_calls") else "unknown", characters=output_chars)
            raise ApiError(502, "incomplete_response", "AI connection ended before completion. Please retry.", True)
        except ApiError as error:
            trace(request_id, "upstream_error", category=error.code, characters=output_chars)
            raise
        except (asyncio.CancelledError, GeneratorExit):
            if not terminal_seen:
                trace(request_id, "upstream_cancelled", category="client_disconnect", characters=output_chars)
            raise
        except (TimeoutError, httpx.TimeoutException):
            trace(request_id, "upstream_error", category=timeout_category, characters=output_chars)
            raise ApiError(504, "provider_timeout", "AI took too long to respond. Please retry.", True) from None
        except httpx.HTTPError:
            trace(request_id, "upstream_error", category="provider_network", characters=output_chars)
            raise ApiError(502, "provider_unavailable", "Cannot connect to the AI provider. Please retry.", True) from None
        except (ValueError, TypeError, KeyError, IndexError, AttributeError):
            trace(request_id, "upstream_error", category="invalid_provider_stream", characters=output_chars)
            raise ApiError(502, "invalid_provider_stream", "AI returned an invalid stream. Please retry.", True) from None
        finally:
            if response is not None:
                with anyio.CancelScope(shield=True):
                    await response.aclose()

    async def image(self, payload: ImageRequest, raw: bytes) -> str:
        if not self.settings.vision_enabled:
            raise ApiError(503, "vision_disabled", "Image analysis is not enabled on this backend.")
        body = {
            "model": self.settings.groq_vision_model,
            "messages": [{"role": "system", "content": VISION_PROMPT},
                         *[m.model_dump() for m in payload.history],
                         {"role": "user", "content": [
                             {"type": "text", "text": payload.prompt},
                             {"type": "image_url", "image_url": {
                                 "url": f"data:{payload.mime_type};base64,{base64.b64encode(raw).decode()}"}},
                         ]}],
            "max_completion_tokens": self.settings.max_output_tokens,
        }
        try:
            async with asyncio.timeout(self.settings.request_timeout_seconds):
                async with self.client.stream("POST", self.URL, headers=self._headers(), json=body) as response:
                    if response.status_code != 200:
                        raise provider_error(response.status_code)
                    data = bytearray()
                    async for chunk in response.aiter_bytes():
                        data.extend(chunk)
                        if len(data) > 1_000_000:
                            raise ValueError("Oversized response")
                    result = json.loads(data)
                    choice = result["choices"][0]
                    text = choice["message"]["content"]
                    if not isinstance(text, str) or not text.strip() or choice.get("finish_reason") != "stop":
                        raise ValueError("Incomplete response")
                    return text
        except ApiError:
            raise
        except (TimeoutError, httpx.TimeoutException):
            raise ApiError(504, "provider_timeout", "Image analysis timed out. Please retry.", True) from None
        except httpx.HTTPError:
            raise ApiError(502, "provider_unavailable", "Cannot connect to the AI provider. Please retry.", True) from None
        except (ValueError, TypeError, KeyError, IndexError):
            raise ApiError(502, "invalid_provider_response", "AI returned an invalid image analysis response.", True) from None
