import asyncio
import json

import httpx
import pytest
from test_api import AUTH, CHAT, client_for, event, settings, upstream


@pytest.mark.parametrize('reason', ['stop', 'length'])
@pytest.mark.parametrize('count', [1, 250])
def test_short_and_long_terminal_reasons_are_explicit(reason, count, caplog):
    content = 'Synthetic response text. ' * 8
    wire = event(content) * count + event(None, reason) + 'data: [DONE]\n\n'
    with client_for(upstream(wire)) as client:
        response = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert response.text.count('event: delta') == count
        assert response.text.count('event: done') == 1
        assert 'event: error' not in response.text
        assert f'"finish_reason": "{reason}"' in response.text
        rid = response.headers['x-request-id']
    entries = [json.loads(r.message.split('ai_mind_stream ', 1)[1])
               for r in caplog.records if r.name == 'aimind.stream']
    assert all(r['request_id'] == rid for r in entries)
    assert any(r['state'] == 'terminal_sent' and r['terminal'] == 'done' for r in entries)
    assert not any(r['state'] == 'upstream_cancelled' for r in entries)
    assert content not in caplog.text
    assert 'test-token' not in caplog.text
    assert 'test-only-placeholder' not in caplog.text


def test_limit_before_visible_text_is_a_terminal_limit_not_lost_first_event():
    with client_for(upstream(event(None, 'length') + 'data: [DONE]\n\n')) as client:
        r = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert r.status_code == 200
        assert r.text.count('event: done') == 1
        assert '"length"' in r.text


@pytest.mark.parametrize('tail', ['', event(None, 'stop'), event(None, 'stop') + 'data: [DONE]\n'])
def test_large_prefix_without_framed_terminal_is_never_success(tail):
    with client_for(upstream(event('Substantial text. ' * 1000) + tail)) as client:
        r = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert 'Substantial text.' in r.text
        assert 'event: done' not in r.text
        assert r.text.count('event: error') == 1


def test_long_stream_network_error_is_private_and_categorized(caplog):
    class Broken(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield event('content ' * 1000).encode()
            raise httpx.ReadError('PRIVATE_PROVIDER_ERROR_CONTENT')
    with client_for(lambda _: httpx.Response(200, stream=Broken(), headers={'content-type': 'text/event-stream'})) as client:
        r = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert 'provider_unavailable' in r.text
        assert 'event: done' not in r.text
        assert 'PRIVATE_PROVIDER_ERROR_CONTENT' not in r.text + caplog.text
        assert 'provider_network' in caplog.text


def test_timeout_after_text_sends_error_and_logs_category(caplog):
    class Stall(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield event('content ' * 500).encode()
            await asyncio.sleep(1)
    with client_for(lambda _: httpx.Response(200, stream=Stall(), headers={'content-type': 'text/event-stream'}),
                    config=settings(provider_read_timeout_seconds=.02)) as client:
        r = client.post('/v1/chat/stream', json=CHAT, headers=AUTH)
        assert 'provider_timeout' in r.text
        assert 'provider_idle_timeout' in caplog.text
        assert 'terminal_sent' in caplog.text


def test_prompt_and_limit_remain_server_configurable():
    def handler(request):
        body = json.loads(request.content)
        assert body['model'] == 'openai/gpt-oss-120b'
        assert body['max_completion_tokens'] == 8192
        assert body['messages'][0]['content'] == 'Custom instruction'
        return httpx.Response(200, text=event('Done', 'stop')+'data: [DONE]\n\n', headers={'content-type':'text/event-stream'})
    with client_for(handler, config=settings(chat_instructions='Custom instruction')) as client:
        assert client.post('/v1/chat/stream', json=CHAT, headers=AUTH).status_code == 200
