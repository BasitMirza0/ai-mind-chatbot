"""Verification-only recovery: no credentials, Firebase network or billable calls."""
import asyncio
import json
import threading

import pytest
from app.auth import FirebaseVerifier
from app.errors import ApiError
from firebase_admin import auth
from firebase_admin import exceptions as firebase_errors
from google.auth import exceptions as google_errors
from test_api import AUTH, CHAT, client_for, event, settings, upstream

CLAIMS = {"uid": "private-test-user", "firebase": {"sign_in_provider": "password"}}


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [auth.CertificateFetchError("PRIVATE", cause=None),
    firebase_errors.UnavailableError("PRIVATE"), firebase_errors.DeadlineExceededError("PRIVATE"),
    google_errors.TransportError("PRIVATE")])
async def test_transient_verification_recovers_once(monkeypatch, failure):
    verifier = FirebaseVerifier(settings())
    calls = []
    def verify(token):
        calls.append(token)
        if len(calls) == 1:
            raise failure
        return CLAIMS
    monkeypatch.setattr(verifier, "_verify", verify)
    try:
        assert (await verifier.verify("PRIVATE_TOKEN")).uid == CLAIMS["uid"]
        assert len(calls) == 2
    finally:
        verifier.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("failure,status", [
    (auth.InvalidIdTokenError("PRIVATE"), 401),
    (auth.ExpiredIdTokenError("PRIVATE", cause=None), 401),
    (auth.RevokedIdTokenError("PRIVATE"), 401),
    (auth.UserDisabledError("PRIVATE"), 401),
    (google_errors.RefreshError("PRIVATE"), 503),
    (firebase_errors.PermissionDeniedError("PRIVATE"), 503),
    (RuntimeError("PRIVATE"), 503),
])
async def test_nontransient_failures_never_retry(monkeypatch, failure, status, caplog):
    verifier = FirebaseVerifier(settings())
    calls = []
    def verify(token):
        calls.append(token)
        raise failure
    monkeypatch.setattr(verifier, "_verify", verify)
    try:
        with pytest.raises(ApiError) as result:
            await verifier.verify("PRIVATE_TOKEN")
        assert result.value.status == status
        assert len(calls) == 1
        assert "PRIVATE" not in caplog.text + str(result.value)
    finally:
        verifier.close()


def test_exhausted_auth_retry_never_reaches_groq(monkeypatch, caplog):
    verifier = FirebaseVerifier(settings())
    calls = []
    def verify(token):
        calls.append(token)
        raise auth.CertificateFetchError("PRIVATE_CERTIFICATE_DETAIL", cause=None)
    monkeypatch.setattr(verifier, "_verify", verify)
    def forbidden(request):
        pytest.fail("Failed verification reached the billable provider")
    with client_for(forbidden, verifier=verifier) as client:
        result = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
    assert result.status_code == 503
    assert len(calls) == 2
    records = [json.loads(r.message.split(" ", 1)[1]) for r in caplog.records
               if r.message.startswith("ai_mind_stream ")]
    auth_records = [r for r in records if r["state"].startswith("auth_")]
    assert all(r["request_id"] == result.headers["x-request-id"] for r in auth_records)
    assert any(r.get("category") == "certificate_fetch" for r in auth_records)
    assert "PRIVATE_CERTIFICATE_DETAIL" not in caplog.text + result.text


def test_auth_recovery_starts_exactly_one_generation(monkeypatch):
    verifier = FirebaseVerifier(settings())
    checks, generations = [], []
    def verify(token):
        checks.append(token)
        if len(checks) == 1:
            raise firebase_errors.UnavailableError("PRIVATE")
        return CLAIMS
    def generate(request):
        generations.append(True)
        return upstream(event("Hello", "stop") + "data: [DONE]\n\n")(request)
    monkeypatch.setattr(verifier, "_verify", verify)
    with client_for(generate, verifier=verifier) as client:
        result = client.post("/v1/chat/stream", json=CHAT, headers=AUTH)
    assert result.status_code == 200
    assert result.text.count("event: done") == 1
    assert len(checks) == 2 and len(generations) == 1


@pytest.mark.asyncio
async def test_deadline_keeps_worker_slot_until_real_completion(monkeypatch):
    verifier = FirebaseVerifier(settings(auth_timeout_seconds=.1, max_auth_workers=1))
    entered, release = threading.Event(), threading.Event()
    calls = []
    def verify(token):
        calls.append(token)
        entered.set()
        release.wait(3)
        return CLAIMS
    monkeypatch.setattr(verifier, "_verify", verify)
    try:
        first = asyncio.create_task(verifier.verify("private-one"))
        assert await asyncio.to_thread(entered.wait, 2)
        with pytest.raises(ApiError) as result:
            await first
        assert result.value.code == "auth_unavailable"
        with pytest.raises(ApiError) as result:
            await verifier.verify("private-two")
        assert result.value.code == "auth_busy"
        assert len(calls) == 1  # No retry of the still-running timed-out worker.
        release.set()
        async with asyncio.timeout(2):
            while verifier._pending:
                await asyncio.sleep(.001)
        assert (await verifier.verify("private-three")).uid == CLAIMS["uid"]
    finally:
        release.set()
        verifier.close()


@pytest.mark.asyncio
async def test_cancelled_waiter_does_not_release_live_worker_or_retry(monkeypatch):
    verifier = FirebaseVerifier(settings(max_auth_workers=1))
    entered, release = threading.Event(), threading.Event()
    def verify(token):
        entered.set()
        release.wait(3)
        return CLAIMS
    monkeypatch.setattr(verifier, "_verify", verify)
    try:
        task = asyncio.create_task(verifier.verify("private"))
        assert await asyncio.to_thread(entered.wait, 2)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        with pytest.raises(ApiError) as result:
            await verifier.verify("another")
        assert result.value.code == "auth_busy"
    finally:
        release.set()
        verifier.close()


@pytest.mark.asyncio
async def test_close_defers_firebase_disposal_until_worker_finishes(monkeypatch):
    verifier = FirebaseVerifier(settings())
    application = object()
    verifier._app = application
    entered, release, deleted = threading.Event(), threading.Event(), threading.Event()
    def verify(token):
        entered.set()
        release.wait(3)
        return CLAIMS
    def delete(app):
        assert app is application
        deleted.set()
    monkeypatch.setattr(verifier, "_verify", verify)
    monkeypatch.setattr("app.auth.firebase_admin.delete_app", delete)
    try:
        task = asyncio.create_task(verifier.verify("private"))
        assert await asyncio.to_thread(entered.wait, 2)
        verifier.close()
        assert not deleted.is_set()
        with pytest.raises(ApiError):
            await verifier.verify("private")
        release.set()
        await task
        assert await asyncio.to_thread(deleted.wait, 2)
    finally:
        release.set()
        verifier.close()


@pytest.mark.asyncio
async def test_invalid_admin_setup_is_not_reported_as_bad_user_token(monkeypatch):
    verifier = FirebaseVerifier(settings())
    def invalid_setup(*args, **kwargs):
        raise ValueError("PRIVATE_ADMIN_CONFIGURATION")
    monkeypatch.delenv("FIREBASE_AUTH_EMULATOR_HOST", raising=False)
    monkeypatch.setattr("app.auth.firebase_admin.initialize_app", invalid_setup)
    try:
        with pytest.raises(ApiError) as result:
            await verifier.verify("private-token")
        assert result.value.status == 503
        assert result.value.code == "auth_configuration"
        assert "PRIVATE_ADMIN_CONFIGURATION" not in str(result.value)
    finally:
        verifier.close()
