"""Private local readiness check. Never prints credentials, tokens or responses.

--provider makes a small, billable Groq test request using backend/.env.
It is not proof of Firebase authentication, phone connectivity or persistence.
"""
import argparse
import asyncio
from pathlib import Path


async def check(provider: bool) -> int:
    try:
        import firebase_admin
        import httpx
        from firebase_admin import credentials
        from app.config import Settings
        from app.provider import GroqProvider
        from app.schemas import ChatRequest
    except ImportError:
        print('BLOCKED: install backend/requirements-dev.txt in backend/.venv first.')
        return 1
    try:
        settings = Settings()
        required = {
            'GROQ_API_KEY': bool(settings.groq_api_key.get_secret_value()),
            'FIREBASE_PROJECT_ID': bool(settings.firebase_project_id.strip()),
            'GOOGLE_APPLICATION_CREDENTIALS': bool(settings.google_application_credentials),
        }
        for name, present in required.items():
            print(f'{name}: {"configured" if present else "not configured"}')
        if not required['GROQ_API_KEY'] or not required['FIREBASE_PROJECT_ID']:
            return 1
        if settings.google_application_credentials:
            file = Path(settings.google_application_credentials).expanduser()
            if not file.is_absolute() or not file.is_file():
                print('BLOCKED: GOOGLE_APPLICATION_CREDENTIALS must name an existing absolute file path.')
                return 1
            credential = credentials.Certificate(str(file))
        else:
            credential = credentials.ApplicationDefault()
            credential.get_credential()
        application = firebase_admin.initialize_app(credential, options={
            'projectId': settings.firebase_project_id,
            'httpTimeout': settings.auth_timeout_seconds,
        }, name='ai-mind-local-check')
        try:
            if application.project_id != settings.firebase_project_id:
                print('BLOCKED: Firebase Admin project does not match backend configuration.')
                return 1
            print('PASS: Firebase Admin SDK initialized for the configured project.')
            print('Live ID-token/revocation authorization still requires a signed-in app request.')
        finally:
            firebase_admin.delete_app(application)
        print(f'Quota storage: {settings.rate_limit_backend}; memory is development-only.')
        if not provider:
            print('Local fields checked. No provider or authenticated request was made.')
            return 0
        async with httpx.AsyncClient(timeout=httpx.Timeout(20, connect=5),
                                     trust_env=False, follow_redirects=False) as client:
            response = await client.get('https://api.groq.com/openai/v1/models',
                headers={'Authorization': f'Bearer {settings.groq_api_key.get_secret_value()}'})
            if response.status_code != 200:
                print(f'BLOCKED: provider model check returned HTTP {response.status_code}; body withheld.')
                return 1
            available = {item['id'] for item in response.json()['data'] if isinstance(item, dict) and 'id' in item}
            if settings.groq_text_model not in available:
                print('BLOCKED: configured text model is not listed for this account.')
                return 1
            print('Configured text model: listed for this account.')
            payload = ChatRequest.model_validate({'messages': [
                {'role': 'user', 'content': 'Reply with one short sentence saying hello.'}]})
            completed = False
            characters = 0
            async for event, text in GroqProvider(settings, client).stream(payload):
                if event == 'delta':
                    characters += len(text)
                elif event == 'done':
                    completed = text == 'stop'
            if not completed or not characters:
                print('BLOCKED: provider test did not complete.')
                return 1
            print('PASS: genuine provider stream completed. Response text withheld.')
            print('Still required: authenticated Flutter request, save and reopen on Vivo.')
            return 0
    except Exception:
        # SDK/configuration exceptions may contain private paths or credentials.
        print('BLOCKED: local configuration or provider check failed. No private exception details printed.')
        return 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', action='store_true', help='Make one real Groq test generation')
    args = parser.parse_args()
    raise SystemExit(asyncio.run(check(args.provider)))
