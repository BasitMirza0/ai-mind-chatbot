# AI Mind backend — Phase 1A

For the current Phase 3A corrections, execution blockers and exact Vivo acceptance
procedure, see [Phase 3A report](../docs/PHASE_3A_REPORT.md). Public model support
and mocked tests do not establish a successful live phone round trip.

Private FastAPI boundary between Flutter and the official Groq REST API. No public
deployment is included. No transcript database, conversation migration, anonymous
Firebase accounts, or live Firestore rules changes are performed by this backend.

## Architecture and API

`Flutter → Firebase ID token → FastAPI → UID quotas → Groq`

- `app/config.py`: environment settings, bounded limits, safe production checks.
- `app/auth.py`: Firebase Admin ID-token verification with revocation checking;
  captures UID from verified claims. Only password/Google identities are accepted.
- `app/schemas.py`: strict request schemas; client-selected UID/model/system prompt
  and unknown fields are rejected.
- `app/middleware.py`: bounded raw bodies, including chunked uploads, total upload
  timeout, request IDs, no-store headers and sanitized unexpected errors.
- `app/limits.py`: development-only memory limiter and atomic shared Redis quotas.
- `app/provider.py`: fixed official Groq endpoint, configurable models, bounded
  output, safe provider failures, stream inactivity and total deadlines.
- `app/images.py`: base64, byte, format, pixel and single-frame validation with Pillow.
- `app/main.py`: endpoints, pre-header error handling, SSE framing, disconnect cleanup.

| Endpoint | Contract |
| --- | --- |
| `GET /health` | Public liveness only: `{"status":"ok"}`. Does not assert readiness. |
| `POST /v1/chat/stream` | Bearer Firebase ID token. JSON `messages:[{role,content}]`, `mode:chat\|voice`. |
| `POST /v1/images/analyze` | Same auth. JSON `image_base64`, `mime_type`, `prompt`, optional `history`. Returns `text`, `request_id`. |

Messages accept `user`/`assistant` roles. The server owns the chat/voice prompts.
Before text begins, failures use non-200 JSON:
`{"error":{"code":"...","message":"safe public message","retryable":true,"request_id":"..."}}`.
After SSE begins, events are `delta` (`{"text":"..."}`), followed by exactly one
`done` (`{"finish_reason":"stop","request_id":"..."}`) or `error` (same error envelope).
A truncated, malformed or interrupted response is an error. Flutter removes its
unfinished placeholder and does not persist/speak the error as an AI answer.
Automatic provider retries are intentionally absent to avoid duplicate generations.

## Local setup (Python 3.11+)

From the repository root:

```sh
python3 -m venv backend/.venv
backend/.venv/bin/python -m pip install -r backend/requirements-dev.txt
umask 077
cp -n backend/.env.example backend/.env
chmod 600 backend/.env
```

Edit **only the ignored `backend/.env`** privately:

1. Set a newly issued `GROQ_API_KEY`; revoke the old compromised key manually.
2. Set `FIREBASE_PROJECT_ID` to the same Firebase project used by Android.
3. Set `GOOGLE_APPLICATION_CREDENTIALS` to an absolute path to a private Firebase
   service-account JSON **outside this repository**, or use configured ADC.
   The account must be able to read Firebase Authentication users for revocation
   checking. A managed deployment should prefer workload identity over JSON keys.
4. Keep `VISION_ENABLED=false` until your account's model permission and a
   non-private image test confirm vision access; then explicitly enable it.

Never paste keys/tokens into shell commands, screenshots, Git commits or support
reports. No real token, provider key, or service account is shipped in tests.
Unsigned Firebase Auth emulator tokens are explicitly refused, including in dev.

Run locally, bound to loopback, without request access logging:

```sh
backend/.venv/bin/python -m uvicorn app.main:app --app-dir backend --host 127.0.0.1 --port 8000 --no-access-log
curl --fail http://127.0.0.1:8000/health
flutter run --dart-define=AI_MIND_BACKEND_URL=http://10.0.2.2:8000
```

Android emulator uses `10.0.2.2`. For a USB Android device, use `adb reverse
tcp:8000 tcp:8000` and pass `http://127.0.0.1:8000` instead. HTTP exceptions exist
only in the Android **debug** manifest for loopback/emulator hosts. Release
configuration requires HTTPS. A Flutter hot restart does not change dart-defines;
restart `flutter run` when changing the backend address.

Sign in through the existing app. No automatic guest migration is performed.
Guests can browse but must sign in for chat, voice and image analysis. The local
Firebase Android client config remains ignored; maintain a separate private copy.

## Models and account verification

Official documentation checked on 2026-10-26:

- [GPT OSS 120B](https://console.groq.com/docs/model/openai/gpt-oss-120b):
  `openai/gpt-oss-120b`, text input/output, configurable default text candidate.
- [Groq vision documentation](https://console.groq.com/docs/vision):
  `qwen/qwen3.8-27b`, image understanding, configurable vision candidate.
- [Supported models](https://console.groq.com/docs/models) and
  [deprecations](https://console.groq.com/docs/deprecations).

Public capabilities are confirmed; **your account's access is not verified**.
Use the Groq console with the new key to check model permissions. Model listing
alone does not prove successful image inference. Validate with a non-private image.
Image analysis describes an existing image; it does not generate images.

## Limits and production boundary

Defaults: 8 MB raw JSON, 5 MB decoded image, 16 million pixels, JPEG/PNG/WebP,
single-frame images, 64 chat messages, 12,000 characters per message, 48,000
aggregate context characters, and 2,048 output tokens. Settings can lower limits.
Images are sent to Groq and are not stored by this backend. No application-level
end-to-end encryption or guarantee about provider retention is implied.

Defaults per verified UID: 10 attempted requests/minute, 100/day (UTC), two
concurrent requests. Invalid images/provider failures after admission still count;
quotas are not refunded. The same quota covers chat, voice and image requests.

`RATE_LIMIT_BACKEND=memory` is **single-process development only**, resets on
restart and is not production protection. `ENVIRONMENT=production` refuses this
mode and requires a provider key, project ID, and `RATE_LIMIT_BACKEND=redis` with
`REDIS_URL`. Redis admission is one Lua operation shared across workers: rolling
minute limit, daily quota and concurrency leases. Crashed workers' leases expire.
Redis failures deny requests; there is no permissive fallback. Use a protected
Redis deployment with ACLs, persistence and TLS/private networking. Per-UID quotas
are not a complete abuse or billing strategy: ingress/global budgets, account
creation abuse, App Check, monitoring and operational testing remain Phase 1B work.

Timeouts are configurable for auth, uploads, upstream connection/read, total
nonstreaming request and total generation. Disconnects close upstream work and
release concurrency leases. Requests do not accept upstream URLs or image URLs.
No CORS origins are enabled; Android does not need browser CORS.

Do not enable HTTP/header/body debug logging or request-body capture in a proxy,
APM agent or exception reporter. Application errors deliberately omit provider
response text, validation inputs, credentials and token contents.

## Tests

```sh
backend/.venv/bin/python -m pytest -c backend/pytest.ini backend/tests -q
flutter test --no-pub test/backend_ai_service_test.dart
flutter analyze --no-pub
python3 scripts/check_public_files.py
cd security_tests
npm install
npm run test:emulator
```

Backend tests mock upstream HTTP and verified identity; separate auth-boundary
tests mock only the Admin SDK's verification result/failure. They do not prove live
Firebase signature/revocation behavior or Groq account access. Redis tests use
fakeredis with Lua, not a deployed Redis cluster. The Firestore tests use the real
rules engine in a loopback **demo-ai-mind** emulator, never the live project.

In the implementation environment, Flutter client tests passed (16 tests), while
Python/npm installs were blocked by DNS restrictions and emulator startup by local
port permissions. Backend and rule-engine results must be obtained on a machine
with dependency downloads and loopback listening available. Python/JS syntax
checks passed. Do not treat unexecuted tests as a security sign-off.

Dependencies use bounded requirements; no resolved Python/npm lockfile could be
generated without successful installation. Resolve and lock the tested versions
before deployment. Existing unrelated starter widget-test failure remains outside
Phase 1A; see the root README.
