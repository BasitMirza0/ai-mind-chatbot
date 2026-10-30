import asyncio
import json

import httpx
import pytest
from firebase_admin import auth

from app.auth import FirebaseVerifier
from app.errors import ApiError
from test_api import AUTH, CHAT, client_for, event, settings, upstream


class Fragmented(httpx.AsyncByteStream):
    def __init__(self, wire):
        self.wire = wire
        self.closed = False

    async def __aiter__(self):
        for byte in self.wire:
            yield bytes([byte])

    async def aclose(self):
        self.closed = True


def test_groq_fragmented_unicode_reasoning_metadata_and_usage():
    wire = (': heartbeat\r\n\r\n' +
            'data: {"choices":[{"delta":{"reasoning":"private reasoning"}}]}\r\n\r\n' +
            event('سلام') + event(' friend', 'stop') +
            'data: {"choices":[],"usage":{"completion_tokens":12}}\n\n' +
            'data: [DONE]\n\n').encode()
    stream = Fragmented(wire)
    def handler(request):
        body = json.loads(request.content)
        assert request.url.host == 'api.groq.com'
        assert body['model'] == 'openai/gpt-oss-120b'
        assert body['stream'] is True
        assert body['messages'][-1] == CHAT['messages'][0]
        return httpx.Response(200, stream=stream, headers={'content-type': 'text/event-stream'})
    with client_for(handler) as client:
        response = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert response.status_code == 200
        assert response.text.count('event: done') == 1
        assert 'سلام' in response.text
        assert 'private reasoning' not in response.text
    assert stream.closed


@pytest.mark.parametrize('wire', [
    event('   ', 'stop') + 'data: [DONE]\n\n',
    event('Hello', 'stop') + 'data: [DONE]\n',
    'data: ' + 'x' * 65_537,
    'data: x\n' * 10_000,
    event('Partial') + 'data: {"choices":null}\n\n',
    event('Partial', 'tool_calls') + 'data: [DONE]\n\n',
], ids=['whitespace-only', 'unterminated-done', 'oversized-line',
        'oversized-multiline-event', 'invalid-choices', 'unsupported-tool-completion'])
def test_invalid_or_blank_completion_never_emits_done(wire):
    with client_for(upstream(wire)) as client:
        response = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert 'event: done' not in response.text
        assert response.status_code == 502 or 'event: error' in response.text


@pytest.mark.asyncio
@pytest.mark.parametrize('provider', ['password', 'google.com'])
async def test_both_sign_in_methods_use_verified_claims(monkeypatch, provider):
    verifier = FirebaseVerifier(settings())
    monkeypatch.setattr(verifier, '_verify', lambda _: {'uid': 'verified', 'firebase': {'sign_in_provider': provider}})
    assert (await verifier.verify('test-only')).uid == 'verified'


@pytest.mark.asyncio
@pytest.mark.parametrize('exception', [auth.InvalidIdTokenError, auth.ExpiredIdTokenError,
                                      auth.RevokedIdTokenError, auth.UserDisabledError])
async def test_token_failures_are_private_and_unauthorized(monkeypatch, exception):
    verifier = FirebaseVerifier(settings())
    def fail(_):
        if exception is auth.ExpiredIdTokenError:
            raise exception('PRIVATE_TOKEN_DETAILS', cause=None)
        raise exception('PRIVATE_TOKEN_DETAILS')
    monkeypatch.setattr(verifier, '_verify', fail)
    with pytest.raises(ApiError) as result:
        await verifier.verify('test-only')
    assert result.value.status == 401
    assert 'PRIVATE_TOKEN_DETAILS' not in str(result.value)


def test_total_stream_deadline_survives_frequent_reasoning_events():
    class Reasoning(httpx.AsyncByteStream):
        async def __aiter__(self):
            while True:
                await asyncio.sleep(.002)
                yield b'data: {"choices":[{"delta":{"reasoning":"working"}}]}\n\n'
    with client_for(lambda _: httpx.Response(200, stream=Reasoning(), headers={'content-type': 'text/event-stream'}),
                    config=settings(stream_timeout_seconds=.02)) as client:
        response = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert response.status_code == 504
        assert response.json()['error']['code'] == 'provider_timeout'


def test_failed_stream_releases_concurrency_for_retry():
    with client_for(upstream(event('partial')), config=settings(max_concurrent_requests=1)) as client:
        for _ in range(2):
            response = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
            assert response.status_code == 200
            assert 'event: error' in response.text
            assert 'quota_exceeded' not in response.text
