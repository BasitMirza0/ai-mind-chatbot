import asyncio
import base64
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.auth import FirebaseVerifier, Identity
from app.config import Settings
from app.errors import ApiError
from app.limits import MemoryLimiter, RedisLimiter, admission
from app.main import create_app, while_connected
from app.schemas import ChatRequest

AUTH = {"Authorization": "Bearer test-token"}
CHAT = {"messages": [{"role": "user", "content": "Hello"}]}


def settings(**overrides):
    return Settings(_env_file=None, groq_api_key="test-only-placeholder",
                    firebase_project_id="demo-ai-mind", **overrides)


class FakeVerifier:
    async def verify(self, token):
        if token != "test-token":
            raise ApiError(401, "invalid_token", "Please sign in again.")
        return Identity("alice")

    def close(self):
        pass


def client_for(handler=None, config=None, verifier=None):
    handler = handler or (lambda request: httpx.Response(500))
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return TestClient(create_app(config or settings(), verifier=verifier or FakeVerifier(), client=http))


def event(content=None, finish=None):
    return "data: " + json.dumps({"choices": [{"delta": {"content": content}, "finish_reason": finish}]}) + "\n\n"


def upstream(text):
    return lambda request: httpx.Response(200, text=text, headers={"content-type": "text/event-stream"})


def image_payload():
    out = io.BytesIO()
    Image.new("RGB", (2, 2)).save(out, format="PNG")
    return {"image_base64": base64.b64encode(out.getvalue()).decode(), "mime_type": "image/png", "prompt": "Describe"}


def test_health_is_liveness_only():
    with client_for() as client:
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Basic invalid"}, {"Authorization": "Bearer invalid"}])
@pytest.mark.parametrize("path,payload", [("/v1/chat/stream", CHAT), ("/v1/images/analyze", image_payload())])
def test_missing_or_invalid_auth_never_contacts_provider(headers, path, payload):
    def forbidden(request):
        pytest.fail("Unauthenticated request reached provider")
    with client_for(forbidden) as client:
        assert client.post(path, json=payload, headers=headers).status_code == 401


def test_missing_provider_key_is_explicit_and_private():
    # Explicit empty key also overrides any key exported by the developer's
    # shell; the private .env is neither loaded nor needed by this test app.
    config = Settings(_env_file=None, groq_api_key="", firebase_project_id="demo-ai-mind",
                      max_concurrent_requests=1)
    def forbidden(request):
        pytest.fail("Missing-key request reached provider transport")
    with client_for(forbidden, config=config) as client:
        # A second request must also return 503, not a leaked-concurrency 429.
        for _ in range(2):
            response = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
            assert response.status_code == 503
            assert response.headers["content-type"].startswith("application/json")
            assert response.json()["error"]["code"] == "provider_not_configured"
            assert response.json()["error"]["message"] == "AI is not configured on the backend yet."
            assert response.json()["error"]["request_id"] == response.headers["x-request-id"]


@pytest.mark.parametrize("status,expected", [(400, 502), (401, 503), (403, 503), (404, 502),
                                           (413, 502), (422, 502), (429, 429), (500, 502), (503, 502), (302, 502)])
def test_provider_failures_have_safe_http_errors(status, expected):
    with client_for(lambda request: httpx.Response(status, text="PRIVATE_UPSTREAM_MARKER")) as client:
        response = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
        assert response.status_code == expected
        assert "PRIVATE_UPSTREAM_MARKER" not in response.text
        assert response.json()["error"]["request_id"] == response.headers["x-request-id"]


def test_stream_success_and_server_owned_prompt():
    def handler(request):
        body = json.loads(request.content)
        assert body["model"] == "openai/gpt-oss-120b"
        assert body["messages"][0]["role"] == "system"
        assert "two or three" in body["messages"][0]["content"]
        return upstream(event("Hello") + event(" world", "stop") + "data: [DONE]\n\n")(request)
    with client_for(handler) as client:
        response = client.post("/v1/chat/stream", json={**CHAT, "mode": "voice"}, headers=AUTH)
        assert response.status_code == 200
        assert response.text.count("event: delta") == 2
        assert response.text.count("event: done") == 1
        assert "event: error" not in response.text


@pytest.mark.parametrize("ending", ["data: not-json\n\n", "data: {\"error\":{\"message\":\"PRIVATE_UPSTREAM_MARKER\"}}\n\n",
                                    event(None, "tool_calls") + "data: [DONE]\n\n", ""])
def test_post_header_stream_errors_are_terminal_events(ending):
    with client_for(upstream(event("Partial") + ending)) as client:
        response = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
        assert response.status_code == 200
        assert "event: delta" in response.text
        assert response.text.count("event: error") == 1
        assert "event: done" not in response.text
        assert "PRIVATE_UPSTREAM_MARKER" not in response.text


def test_empty_stream_is_http_error_before_sse_headers():
    with client_for(upstream("data: [DONE]\n\n")) as client:
        assert client.post("/v1/chat/stream", json=CHAT, headers=AUTH).status_code == 502


@pytest.mark.parametrize("payload", [{"messages": []}, {"messages": [{"role": "system", "content": "PRIVATE_INPUT"}]},
                                    {"messages": [{"role": "user", "content": " "}]},
                                    {**CHAT, "uid": "bob"}, {**CHAT, "model": "client-choice"},
                                    {"messages": CHAT["messages"] * 65},
                                    {"messages": [{"role": "user", "content": "x" * 12001}]}])
def test_invalid_input_does_not_echo_conversations(payload):
    with client_for() as client:
        response = client.post("/v1/chat/stream", json=payload, headers=AUTH)
        assert response.status_code == 422
        assert "PRIVATE_INPUT" not in response.text


def test_body_limit_including_chunked_requests():
    with client_for(config=settings(max_request_bytes=1024)) as client:
        assert client.post("/v1/chat/stream", content=b"x" * 1025, headers=AUTH).status_code == 413
        response = client.post("/v1/chat/stream", content=iter([b"x" * 600, b"x" * 600]), headers=AUTH)
        assert response.status_code == 413


def test_context_limit():
    with client_for(config=settings(max_history_characters=4)) as client:
        assert client.post("/v1/chat/stream", json=CHAT, headers=AUTH).status_code == 413


@pytest.mark.parametrize("change", [{"image_base64": "!!!!"}, {"mime_type": "image/jpeg"},
                                    {"mime_type": "image/svg+xml"}, {"prompt": " "}])
def test_invalid_image(change):
    with client_for(config=settings(vision_enabled=True)) as client:
        assert client.post("/v1/images/analyze", json={**image_payload(), **change}, headers=AUTH).status_code == 422


def test_image_byte_and_pixel_limits():
    payload = image_payload()
    payload["image_base64"] = base64.b64encode(b"x" * 1025).decode()
    with client_for(config=settings(max_image_bytes=1024, vision_enabled=True)) as client:
        assert client.post("/v1/images/analyze", json=payload, headers=AUTH).status_code == 413
    with client_for(config=settings(max_image_pixels=1, vision_enabled=True)) as client:
        assert client.post("/v1/images/analyze", json=image_payload(), headers=AUTH).status_code == 422


def test_vision_is_opt_in_and_image_success_uses_vision_model():
    with client_for() as client:
        assert client.post("/v1/images/analyze", json=image_payload(), headers=AUTH).status_code == 503
    def handler(request):
        body = json.loads(request.content)
        assert body["model"] == "qwen/qwen3.8-27b"
        assert body["messages"][-1]["content"][-1]["image_url"]["url"].startswith("data:image/png;base64,")
        return httpx.Response(200, json={"choices": [{"message": {"content": "A small image"}, "finish_reason": "stop"}]})
    with client_for(handler, config=settings(vision_enabled=True)) as client:
        response = client.post("/v1/images/analyze", json=image_payload(), headers=AUTH)
        assert response.status_code == 200
        assert response.json()["text"] == "A small image"


@pytest.mark.parametrize("status", [401, 429, 500])
def test_image_provider_errors_are_safe(status):
    with client_for(lambda request: httpx.Response(status, text="PRIVATE_UPSTREAM_MARKER"), config=settings(vision_enabled=True)) as client:
        response = client.post("/v1/images/analyze", json=image_payload(), headers=AUTH)
        assert response.status_code != 200
        assert "PRIVATE_UPSTREAM_MARKER" not in response.text


def test_provider_connection_failure():
    def handler(request):
        raise httpx.ConnectError("PRIVATE_NETWORK_MARKER")
    with client_for(handler) as client:
        response = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
        assert response.status_code == 502
        assert "PRIVATE_NETWORK_MARKER" not in response.text


class SlowStream(httpx.AsyncByteStream):
    closed = False
    async def __aiter__(self):
        await asyncio.sleep(2)
        yield b"never"
    async def aclose(self):
        self.closed = True


def test_stream_inactivity_timeout_closes_upstream():
    slow = SlowStream()
    with client_for(lambda request: httpx.Response(200, stream=slow, headers={"content-type": "text/event-stream"}),
                    config=settings(provider_read_timeout_seconds=0.01)) as client:
        assert client.post("/v1/chat/stream", json=CHAT, headers=AUTH).status_code == 504
    assert slow.closed


@pytest.mark.asyncio
async def test_memory_limits_quota_concurrency_and_uid_isolation():
    limiter = MemoryLimiter(settings(requests_per_minute=2, requests_per_day=2, max_concurrent_requests=1))
    alice = await limiter.acquire("alice")
    with pytest.raises(ApiError, match="quota_exceeded"):
        await limiter.acquire("alice")
    bob = await limiter.acquire("bob")
    await limiter.release("alice", alice)
    second = await limiter.acquire("alice")
    await limiter.release("alice", second)
    with pytest.raises(ApiError):
        await limiter.acquire("alice")
    await limiter.release("bob", bob)


@pytest.mark.asyncio
async def test_redis_admission_is_atomic_and_shared():
    import fakeredis.aioredis
    shared = fakeredis.aioredis.FakeRedis()
    first = RedisLimiter(settings(requests_per_minute=2, requests_per_day=2, max_concurrent_requests=1), shared)
    second = RedisLimiter(first.settings, shared)
    lease = await first.acquire("alice")
    with pytest.raises(ApiError):
        await second.acquire("alice")
    await first.release("alice", lease)
    lease = await second.acquire("alice")
    await second.release("alice", lease)
    with pytest.raises(ApiError):
        await first.acquire("alice")
    assert await second.acquire("bob")
    await shared.aclose()


@pytest.mark.asyncio
async def test_redis_outage_fails_closed():
    class BrokenRedis:
        async def eval(self, *args):
            raise OSError("private redis url")
    limiter = RedisLimiter(settings(), BrokenRedis())
    with pytest.raises(ApiError) as error:
        await limiter.acquire("alice")
    assert error.value.status == 503
    assert "private redis url" not in str(error.value)


def test_production_rejects_memory_limiter_and_emulator_auth(monkeypatch):
    with pytest.raises(ValueError):
        settings(environment="production")
    monkeypatch.setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
    with pytest.raises(ApiError):
        FirebaseVerifier(settings())._verify("unsigned")


@pytest.mark.asyncio
async def test_real_auth_boundary_rejects_anonymous_and_invalid_tokens(monkeypatch):
    verifier = FirebaseVerifier(settings())
    monkeypatch.setattr(verifier, "_verify", lambda token: {"uid": "alice", "firebase": {"sign_in_provider": "anonymous"}})
    with pytest.raises(ApiError) as error:
        await verifier.verify("test")
    assert error.value.status == 403
    def invalid(token):
        from firebase_admin import auth
        raise auth.InvalidIdTokenError("PRIVATE_TOKEN_MARKER")
    monkeypatch.setattr(verifier, "_verify", invalid)
    with pytest.raises(ApiError) as error:
        await verifier.verify("invalid")
    assert error.value.status == 401
    assert "PRIVATE_TOKEN_MARKER" not in str(error.value)


@pytest.mark.asyncio
async def test_verified_identity_is_captured_not_supplied_by_client(monkeypatch):
    verifier = FirebaseVerifier(settings())
    monkeypatch.setattr(verifier, "_verify", lambda token: {"uid": "verified-uid", "firebase": {"sign_in_provider": "google.com"}})
    assert (await verifier.verify("test")).uid == "verified-uid"


@pytest.mark.asyncio
async def test_admin_sdk_verification_requires_revocation_check(monkeypatch):
    from firebase_admin import auth
    verifier = FirebaseVerifier(settings())
    application = object()
    verifier._app = application
    calls = []
    def verify(token, **kwargs):
        calls.append(kwargs)
        return {"uid": "alice", "firebase": {"sign_in_provider": "password"}}
    monkeypatch.delenv("FIREBASE_AUTH_EMULATOR_HOST", raising=False)
    monkeypatch.setattr(auth, "verify_id_token", verify)
    assert (await verifier.verify("test")).uid == "alice"
    assert calls == [{"app": application, "check_revoked": True, "clock_skew_seconds": 5}]


@pytest.mark.asyncio
async def test_redis_concurrent_workers_cannot_overspend_shared_quota():
    import fakeredis.aioredis
    shared = fakeredis.aioredis.FakeRedis()
    config = settings(requests_per_minute=3, requests_per_day=3, max_concurrent_requests=3)
    first, second = RedisLimiter(config, shared), RedisLimiter(config, shared)
    results = await asyncio.gather(*[(first if i % 2 else second).acquire("alice")
                                     for i in range(12)], return_exceptions=True)
    assert sum(isinstance(result, str) for result in results) == 3
    assert sum(isinstance(result, ApiError) for result in results) == 9
    await shared.aclose()


@pytest.mark.asyncio
async def test_disconnect_cancels_work_and_releases_admission():
    cancelled = asyncio.Event()
    class Disconnected:
        async def receive(self):
            return {"type": "http.disconnect"}
    async def pending():
        try:
            await asyncio.sleep(10)
        finally:
            cancelled.set()
    limiter = MemoryLimiter(settings(max_concurrent_requests=1))
    with pytest.raises(ApiError):
        async with admission(limiter, "alice"):
            await while_connected(Disconnected(), pending())
    assert cancelled.is_set()
    assert await limiter.acquire("alice")


@pytest.mark.asyncio
async def test_generator_cancellation_closes_upstream():
    from app.provider import GroqProvider
    class Tracked(httpx.AsyncByteStream):
        closed = False
        async def __aiter__(self):
            yield event("Partial").encode()
            await asyncio.sleep(10)
        async def aclose(self):
            self.closed = True
    stream = Tracked()
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda request: httpx.Response(
            200, stream=stream, headers={"content-type": "text/event-stream"}))) as client:
        generator = GroqProvider(settings(), client).stream(ChatRequest.model_validate(CHAT))
        assert await anext(generator) == ("delta", "Partial")
        await generator.aclose()
    assert stream.closed
