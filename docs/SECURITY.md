# AI Mind — Security and deployment notes

AI Mind demonstrates an authenticated Flutter-to-FastAPI architecture. Its local development configuration is **not** a turnkey public production service.

## Key separation

- **Groq API keys:** server only (`backend/.env` for local development), never embedded in Flutter or committed to Git.
- **Firebase Admin JSON:** private credential stored outside the project and referenced by `GOOGLE_APPLICATION_CREDENTIALS`.
- **Firebase client configuration:** identifies a client application; do not confuse this with Admin credentials. Authorization still requires appropriately deployed Firestore Security Rules and backend token verification.
- **Old exposed keys:** revoke; do not publish legacy Git history or backup archives that may contain them.

## Authorization and quotas

Authenticated AI endpoints must verify Firebase ID tokens and derive user identity from verified claims, never a user-supplied UID. Proposed repository Firestore Rules and emulator tests must be reviewed and **deployed separately** to the intended Firebase project; storing rules in Git does not mean they are active.

Memory-backed rate limiting is for local development only. Production deployments need shared/durable enforcement (for example Redis), concurrency limits, usage observability, and safe failure behavior.

## Network boundary

Use localhost plus `adb reverse` for debug device testing. Release builds need a separately maintained HTTPS backend and a secure deployment process. Do not expose a developer laptop's private FastAPI port to the public internet.

## Publication checklist

- [ ] New provider key is configured; old compromised key has been revoked.
- [ ] No `.env`, Admin JSON, Android signing keys, logs, caches, local backups or private design references are staged.
- [ ] No sensitive text, private files, or secrets appear in source, reports, screenshots, or Git history.
- [ ] Secret scanner finishes successfully against the **exact** public snapshot.
- [ ] App screenshots are approved for public distribution, including names and conversation previews.
- [ ] Firestore rule status is accurately documented (local tests are not a live deployment).
- [ ] Local debug URL is not presented as a publicly hosted service.
- [ ] Third-party artwork and font licenses are preserved as applicable.

## Vulnerability reporting

Please avoid posting security vulnerabilities or credentials in a public issue. Contact the repository maintainer privately through their GitHub profile.
