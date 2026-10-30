import asyncio
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextvars import ContextVar
from dataclasses import dataclass

import firebase_admin
from fastapi import Request
from firebase_admin import auth, credentials
from firebase_admin import exceptions as firebase_errors
from google.auth import exceptions as google_errors
from requests import exceptions as transport_errors

from .config import Settings
from .diagnostics import trace
from .errors import ApiError

_request_id = ContextVar("auth_request_id", default="unassigned")


def verification_failure(error: Exception) -> tuple[str, bool]:
    """Fixed, content-free categories; only transport/service failures retry."""
    if isinstance(error, auth.CertificateFetchError):
        return "certificate_fetch", True
    if isinstance(error, (firebase_errors.DeadlineExceededError, transport_errors.Timeout)):
        return "verification_timeout", True
    if isinstance(error, (firebase_errors.UnavailableError, google_errors.TransportError,
                          transport_errors.ConnectionError)):
        return "verification_network", True
    if isinstance(error, google_errors.RefreshError):
        return "admin_credentials", False
    if isinstance(error, (firebase_errors.UnauthenticatedError, firebase_errors.PermissionDeniedError)):
        return "admin_authorization", False
    return "verification_unexpected", False


@dataclass(frozen=True)
class Identity:
    uid: str


class FirebaseVerifier:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._app = None
        self._initialization_lock = threading.Lock()
        # A cancelled asyncio waiter cannot kill a synchronous Admin SDK call.
        # Retain its admission slot until the actual worker finishes.
        self._workers = ThreadPoolExecutor(max_workers=settings.max_auth_workers,
                                           thread_name_prefix="firebase-verify")
        self._worker_lock = threading.Lock()
        self._pending = set()
        self._closed = False

    def _verify(self, token: str) -> dict:
        # Never accidentally accept unsigned emulator tokens in this API.
        if os.environ.get("FIREBASE_AUTH_EMULATOR_HOST"):
            raise ApiError(503, "auth_unavailable", "Authentication is not configured safely.")
        if not self.settings.firebase_project_id:
            raise ApiError(503, "auth_unavailable", "Backend authentication is not configured.")
        with self._initialization_lock:
            if self._app is None:
                # ADC may be used, but only the configured project is accepted.
                try:
                    cred = (credentials.Certificate(self.settings.google_application_credentials)
                            if self.settings.google_application_credentials else None)
                    self._app = firebase_admin.initialize_app(
                        cred, options={"projectId": self.settings.firebase_project_id,
                                       "httpTimeout": self.settings.auth_timeout_seconds},
                        name=f"ai-mind-{id(self)}",
                    )
                except (ValueError, OSError):
                    raise ApiError(503, "auth_configuration", "Backend authentication is not configured correctly.") from None
        return auth.verify_id_token(token, app=self._app, check_revoked=True,
                                    clock_skew_seconds=5)

    def _worker_finished(self, future):
        with self._worker_lock:
            self._pending.discard(future)
            close_app = self._closed and not self._pending
        if close_app:
            self._delete_app()

    async def _attempt(self, token: str) -> dict:
        with self._worker_lock:
            if self._closed or len(self._pending) >= self.settings.max_auth_workers:
                raise ApiError(503, "auth_busy", "Authentication is busy. Please retry shortly.", True)
            future = self._workers.submit(self._verify, token)
            self._pending.add(future)
        # Register outside the lock: an already-finished Future calls immediately.
        future.add_done_callback(self._worker_finished)
        return await asyncio.wrap_future(future)

    async def verify(self, token: str) -> Identity:
        request_id = _request_id.get()
        started = time.monotonic()
        attempt = 0
        def record(state, **fields):
            trace(request_id, state, attempt=attempt,
                  elapsed_ms=round((time.monotonic() - started) * 1000), **fields)
        try:
            # Both attempts share one total deadline; never retry a timed-out
            # worker or any generation request. Verification precedes Groq.
            async with asyncio.timeout(self.settings.auth_timeout_seconds):
                for attempt in (1, 2):
                    record("auth_attempt")
                    try:
                        claims = await self._attempt(token)
                        break
                    except Exception as error:
                        category, transient = verification_failure(error)
                        if attempt != 1 or not transient:
                            raise
                        record("auth_retry", category=category)
                        await asyncio.sleep(.15)
        except asyncio.CancelledError:
            record("auth_cancelled", category="request_cancelled")
            raise
        except ApiError as error:
            record("auth_failed", category=error.code)
            raise
        except (auth.InvalidIdTokenError, auth.ExpiredIdTokenError,
                auth.RevokedIdTokenError, auth.UserDisabledError, ValueError):
            record("auth_failed", category="invalid_token")
            raise ApiError(401, "invalid_token", "Please sign in again.") from None
        except TimeoutError:
            record("auth_failed", category="auth_deadline")
            raise ApiError(503, "auth_unavailable", "Authentication is temporarily unavailable.", True) from None
        except Exception as error:
            record("auth_failed", category=verification_failure(error)[0])
            # Never return SDK exception text, credentials, or raw token contents.
            raise ApiError(503, "auth_unavailable", "Authentication is temporarily unavailable.", True) from None
        provider = claims.get("firebase", {}).get("sign_in_provider")
        uid = claims.get("uid")
        if provider not in {"password", "google.com"}:
            record("auth_failed", category="sign_in_required")
            raise ApiError(403, "sign_in_required", "Sign in with email or Google to use AI.")
        if not isinstance(uid, str) or not uid or len(uid) > 128:
            record("auth_failed", category="invalid_token")
            raise ApiError(401, "invalid_token", "Please sign in again.")
        record("auth_verified")
        return Identity(uid=uid)

    def _delete_app(self):
        with self._initialization_lock:
            if self._app is not None:
                firebase_admin.delete_app(self._app)
                self._app = None

    def close(self):
        with self._worker_lock:
            self._closed = True
            close_app = not self._pending
        self._workers.shutdown(wait=False, cancel_futures=True)
        if close_app:
            self._delete_app()


async def authenticated_user(request: Request) -> Identity:
    value = request.headers.get("authorization", "")
    scheme, _, token = value.partition(" ")
    if scheme.lower() != "bearer" or not token or len(token) > 8192 or " " in token:
        raise ApiError(401, "sign_in_required", "Sign in to use AI.")
    context = _request_id.set(request.state.request_id)
    try:
        identity = await request.app.state.verifier.verify(token)
    finally:
        _request_id.reset(context)
    request.state.identity = identity
    return identity
