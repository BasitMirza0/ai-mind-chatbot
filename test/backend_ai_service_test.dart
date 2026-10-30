import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_chatbot/services/backend_ai_service.dart';
import 'package:ai_chatbot/services/backend_api_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const config = BackendApiConfig(baseUrl: 'https://backend.example');
final messages = <Map<String, dynamic>>[{'role': 'user', 'text': 'Hello'}];
const success = 'event: delta\ndata: {"text":"Hello"}\n\n'
    'event: done\ndata: {"finish_reason":"stop","request_id":"test"}\n\n';

BackendAiService service(http.Client client, {BackendApiConfig settings = config,
    Future<String?> Function()? token}) => BackendAiService(
  config: settings, clientFactory: () => client,
  tokenProvider: token ?? () async => 'test-only-id-token',
);

Matcher errorCode(String code) => isA<BackendApiException>()
    .having((e) => e.code, 'code', code);

void main() {
  test('account cancellation during token retrieval sends no stale request', () async {
    final token = Completer<String?>();
    var requests = 0;
    final api = service(MockClient((request) async {
      requests++;
      return http.Response(success, 200, headers: {'content-type': 'text/event-stream'});
    }), token: () => token.future);
    final result = api.streamMessage(messages).toList();
    await Future<void>.delayed(Duration.zero);
    api.cancelPendingRequests();
    token.complete('old-account-token');
    expect(await result, isEmpty);
    expect(requests, 0);
  });

  test('temporary authentication failure never automatically resends generation', () async {
    var requests = 0;
    final api = service(MockClient((request) async {
      requests++;
      return http.Response(jsonEncode({'error': {
        'code': 'auth_unavailable', 'message': 'Authentication is temporarily unavailable.',
        'retryable': true,
      }}), 503);
    }));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('auth_unavailable')));
    expect(requests, 1);
  });

  test('backend URL is required, HTTPS by default, local HTTP debug only', () {
    expect(() => const BackendApiConfig().endpoint('/v1/chat/stream'),
        throwsA(errorCode('backend_not_configured')));
    expect(() => const BackendApiConfig(baseUrl: 'http://public.example').endpoint('/x'),
        throwsA(errorCode('unsafe_backend_url')));
    expect(() => const BackendApiConfig(baseUrl: 'http://127.0.0.1:8000', allowLocalHttp: false).endpoint('/x'),
        throwsA(errorCode('unsafe_backend_url')));
    expect(const BackendApiConfig(baseUrl: 'http://10.0.2.2:8000').endpoint('/x').host, '10.0.2.2');
    expect(() => const BackendApiConfig(baseUrl: 'https://user:password@backend.example').endpoint('/x'),
        throwsA(errorCode('backend_not_configured')));
  });

  test('guests are rejected before any HTTP request', () async {
    var called = false;
    final api = service(MockClient((request) async { called = true; return http.Response('', 200); }),
        token: () async => null);
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('sign_in_required')));
    expect(called, isFalse);
  });

  test('only backend receives the Firebase token, normalized history and voice mode', () async {
    final api = service(MockClient((request) async {
      expect(request.url.toString(), 'https://backend.example/v1/chat/stream');
      expect(request.headers['Authorization'], 'Bearer test-only-id-token');
      expect(request.followRedirects, isFalse);
      final body = jsonDecode(request.body) as Map;
      expect(body['mode'], 'voice');
      expect(body.containsKey('systemPrompt'), isFalse);
      expect(body.containsKey('model'), isFalse);
      expect(body['messages'], [{'role': 'user', 'content': 'Hello'}]);
      return http.Response(success, 200, headers: {'content-type': 'text/event-stream'});
    }));
    expect(await api.streamMessage(messages, systemPrompt: 'legacy voice prompt').join(), 'Hello');
  });

  test('fragmented UTF-8 SSE is reconstructed correctly', () async {
    final bytes = utf8.encode(success.replaceFirst('Hello', 'سلام'));
    final api = service(MockClient.streaming((request, body) async => http.StreamedResponse(
        Stream.fromIterable(bytes.map((b) => [b])), 200,
        headers: {'content-type': 'text/event-stream'})));
    expect(await api.streamMessage(messages).join(), 'سلام');
  });

  test('HTTP authentication errors stay errors rather than assistant text', () async {
    final api = service(MockClient((request) async => http.Response(jsonEncode({
      'error': {'code': 'invalid_token', 'message': 'Please sign in again.', 'retryable': false}
    }), 401)));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('invalid_token')));
  });

  test('proxy HTML is not displayed as an assistant reply or public error', () async {
    final api = service(MockClient((request) async => http.Response('<html>private upstream detail</html>', 502)));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('backend_error')));
  });

  test('midstream error surfaces after partial text without fake success', () async {
    final api = service(MockClient((request) async => http.Response(
        'event: delta\ndata: {"text":"Partial"}\n\n'
        'event: error\ndata: {"error":{"code":"provider_timeout","message":"Please retry.","retryable":true}}\n\n',
        200, headers: {'content-type': 'text/event-stream'})));
    final chunks = <String>[];
    await expectLater(api.streamMessage(messages).forEach(chunks.add), throwsA(errorCode('provider_timeout')));
    expect(chunks, ['Partial']);
  });

  test('missing completion boundary is an error', () async {
    final api = service(MockClient((request) async => http.Response(
        'event: delta\ndata: {"text":"Partial"}\n\n', 200,
        headers: {'content-type': 'text/event-stream'})));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('incomplete_response')));
  });

  test('malformed SSE and wrong content type are rejected', () async {
    for (final response in [
      http.Response('event: delta\ndata: not-json\n\n', 200, headers: {'content-type': 'text/event-stream'}),
      http.Response('{}', 200, headers: {'content-type': 'application/json'}),
    ]) {
      final api = service(MockClient((request) async => response));
      await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('invalid_response')));
    }
  });

  test('backend unavailability is an explicit connection error', () async {
    final api = service(MockClient((request) async => throw http.ClientException('network unavailable')));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('backend_unavailable')));
  });

  test('stream header timeouts are bounded', () async {
    final api = service(MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(success, 200, headers: {'content-type': 'text/event-stream'});
    }), settings: const BackendApiConfig(baseUrl: 'https://backend.example',
        streamHeaderTimeout: Duration(milliseconds: 2)));
    await expectLater(api.streamMessage(messages).toList(), throwsA(errorCode('backend_timeout')));
    await Future<void>.delayed(const Duration(milliseconds: 25));
  });

  test('image uploads carry correct MIME and do not duplicate current prompt', () async {
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
    final api = service(MockClient((request) async {
      expect(request.url.path, '/v1/images/analyze');
      final body = jsonDecode(request.body) as Map;
      expect(body['mime_type'], 'image/png');
      expect(body['history'], isEmpty);
      expect(body['prompt'], 'Hello');
      return http.Response('{"text":"An image","request_id":"test"}', 200);
    }));
    expect(await api.analyzeImage(png, 'Hello', messages), 'An image');
  });

  test('oversized images fail locally before transmission', () async {
    final api = service(MockClient((request) async => throw StateError('Must not send')));
    await expectLater(api.analyzeImage(Uint8List(5000001), 'Describe', []), throwsA(errorCode('image_too_large')));
  });

  test('image HTTP failures are errors', () async {
    final api = service(MockClient((request) async => http.Response(
        '{"error":{"code":"vision_disabled","message":"Image analysis is not enabled."}}', 503)));
    await expectLater(api.analyzeImage(Uint8List.fromList([255, 216, 255]), 'Describe', []),
        throwsA(errorCode('vision_disabled')));
  });

  test('nonstreaming images use the total request deadline while awaiting headers', () async {
    final api = service(MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 15));
      return http.Response('{"text":"An image","request_id":"test"}', 200);
    }), settings: const BackendApiConfig(baseUrl: 'https://backend.example',
        connectionTimeout: Duration(milliseconds: 2), requestTimeout: Duration(milliseconds: 100)));
    expect(await api.analyzeImage(Uint8List.fromList([255, 216, 255]), 'Describe', []), 'An image');
  });

  test('cancellation closes active transport and ignores subsequent chunks', () async {
    final stream = StreamController<List<int>>();
    final transport = TrackingClient(stream.stream);
    final api = service(transport);
    final result = api.streamMessage(messages).toList();
    await transport.started.future;
    api.cancelPendingRequests();
    expect(transport.closed, isTrue);
    stream.add(utf8.encode(success));
    await stream.close();
    expect(await result, isEmpty);
  });
}

class TrackingClient extends http.BaseClient {
  final Stream<List<int>> stream;
  final started = Completer<void>();
  bool closed = false;
  TrackingClient(this.stream);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    started.complete();
    return http.StreamedResponse(stream, 200, headers: {'content-type': 'text/event-stream'});
  }

  @override
  void close() { closed = true; }
}
