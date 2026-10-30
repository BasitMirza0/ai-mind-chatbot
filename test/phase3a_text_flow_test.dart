import 'dart:async';
import 'dart:convert';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/backend_ai_service.dart';
import 'package:ai_chatbot/services/backend_api_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/fake_chat_dependencies.dart';

const config = BackendApiConfig(baseUrl: 'https://backend.example');
const input = [{'role': 'user', 'text': 'Hello'}];
const done = 'event: done\ndata: {"finish_reason":"stop","request_id":"test"}\n\n';
String delta(String text) => 'event: delta\ndata: ${jsonEncode({'text': text})}\n\n';
Matcher code(String value) => isA<BackendApiException>().having((e) => e.code, 'code', value);
BackendAiService api(http.Client client, {BackendApiConfig settings = config,
  Future<String?> Function()? token}) => BackendAiService(config: settings,
    clientFactory: () => client, tokenProvider: token ?? () async => 'test-only-id-token');

void main() {
  test('header wait accommodates server prefetch independently of token acquisition', () async {
    final service = api(MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return http.Response(delta('Hello') + done, 200, headers: {'content-type': 'text/event-stream'});
    }), settings: const BackendApiConfig(baseUrl: 'https://backend.example',
      connectionTimeout: Duration(milliseconds: 5), streamHeaderTimeout: Duration(seconds: 1)));
    expect(await service.streamMessage(input).join(), 'Hello');
  });

  test('SSE multiline CRLF, metadata comments and split UTF-8 decode correctly', () async {
    final bytes = utf8.encode(': heartbeat\r\n\r\nevent: delta\r\ndata: {"text":\r\ndata: "سلام"}\r\n\r\n$done');
    final service = api(MockClient.streaming((_, __) async => http.StreamedResponse(
      Stream.fromIterable(bytes.map((b) => [b])), 200, headers: {'content-type': 'text/event-stream'})));
    expect(await service.streamMessage(input).join(), 'سلام');
  });

  for (final wire in [
    'event: delta\ndata: ${'x' * 65537}',
    'event: delta\n${'data: x\n' * 10000}',
    '${delta('x' * 50000)}${delta('x' * 50001)}$done',
  ]) {
    test('oversized response fails before unbounded buffering (${wire.length} bytes)', () async {
      final service = api(MockClient((_) async => http.Response(wire, 200, headers: {'content-type': 'text/event-stream'})));
      await expectLater(service.streamMessage(input).toList(), throwsA(code('invalid_response')));
    });
  }

  test('whitespace-only and unterminated done events never count as success', () async {
    for (final wire in [delta('   ') + done, '${delta('Hello')}${done.trimRight()}\n']) {
      final service = api(MockClient((_) async => http.Response(wire, 200, headers: {'content-type': 'text/event-stream'})));
      await expectLater(service.streamMessage(input).join(), throwsA(code('incomplete_response')));
    }
  });

  test('idle stream times out; cancellation during token acquisition sends nothing', () async {
    final stream = StreamController<List<int>>();
    final service = api(MockClient.streaming((_, __) async => http.StreamedResponse(stream.stream, 200,
      headers: {'content-type': 'text/event-stream'})), settings: const BackendApiConfig(
        baseUrl: 'https://backend.example', streamIdleTimeout: Duration(milliseconds: 10)));
    await expectLater(service.streamMessage(input).join(), throwsA(code('backend_timeout')));
    await stream.close();
    final token = Completer<String?>(); var calls = 0;
    final cancelled = api(MockClient((_) async { calls++; return http.Response('', 500); }), token: () => token.future);
    final pending = cancelled.streamMessage(input).toList(); await tick();
    cancelled.cancelPendingRequests(); token.complete('test-only-old-token');
    expect(await pending, isEmpty); expect(calls, 0);
  });

  test('mocked transport round trip streams progressively, saves stable IDs and reopens saved title', () async {
    final session = FakeSession(); final repo = FakeRepository();
    final wire = StreamController<List<int>>(); final started = Completer<void>(); var calls = 0;
    final service = api(MockClient.streaming((request, body) async {
      calls++;
      expect(request.headers['Authorization'], 'Bearer test-only-id-token');
      expect(request.url.host, 'backend.example'); expect(request.followRedirects, false);
      final json = jsonDecode(utf8.decode(await body.toBytes())) as Map;
      expect(json['messages'], [{'role': 'user', 'content': 'Keep a useful thought'}]);
      expect(json.containsKey('uid'), false); expect(json.containsKey('model'), false);
      started.complete();
      return http.StreamedResponse(wire.stream, 200, headers: {'content-type': 'text/event-stream'});
    }));
    final chat = ChatController(ai: service, repository: repo, currentUid: () => session.uid);
    chat.setDraft('Keep a useful thought'); final request = chat.send(); await started.future;
    await chat.send(); expect(calls, 1);
    wire.add(utf8.encode(delta('A useful'))); await tick(); await tick();
    expect(chat.streamingText.value, 'A useful'); expect(repo.writes.length, 1);
    wire.add(utf8.encode(delta(' answer') + done)); await request;
    final id = chat.conversation.id;
    expect(chat.conversation.messages.map((m) => m.saved), [true, true]);
    expect(repo.records[id]!.map((m) => m.role), ['user', 'bot']);
    expect(repo.records[id]!.last.text, 'A useful answer');
    repo.summaries = [ConversationSummary(id, 'My renamed conversation')];
    final reopened = ChatController(ai: service, repository: repo, currentUid: () => session.uid);
    await reopened.open(id); expect(reopened.conversation.title, 'My renamed conversation');
    expect(reopened.conversation.messages.last.id, chat.conversation.messages.last.id);
    reopened.dispose(); chat.dispose(); session.dispose(); await wire.close();
  });

  test('transport error is not saved; retry reuses user ID and save failure retries only storage', () async {
    final session = FakeSession(); final repo = FakeRepository(); var calls = 0;
    final service = api(MockClient((_) async {
      calls++;
      return http.Response(calls == 1 ? '${delta('Partial')}event: error\ndata: {"error":{"code":"provider_busy","message":"Try again later."}}\n\n'
        : delta('Complete answer') + done, 200, headers: {'content-type': 'text/event-stream'});
    }));
    final chat = ChatController(ai: service, repository: repo, currentUid: () => session.uid);
    chat.setDraft('Question'); await chat.send();
    final userId = chat.lastUser!.id;
    expect(chat.conversation.error, 'Try again later.'); expect(repo.writes.length, 1); expect(chat.busy, false);
    repo.failBotSave = true; await chat.retry();
    expect(chat.lastUser!.id, userId); expect(chat.conversation.messages.last.saved, false); expect(chat.saving, false);
    repo.failBotSave = false; await chat.retry(); expect(calls, 2);
    expect(chat.conversation.messages.last.saved, true); expect(repo.writes.length, 2);
    chat.dispose(); session.dispose();
  });

  test('sign-out during real client parsing cancels and prevents any late assistant persistence', () async {
    final session = FakeSession(); final repo = FakeRepository();
    final wire = StreamController<List<int>>(); final started = Completer<void>();
    final service = api(MockClient.streaming((_, __) async {
      started.complete(); return http.StreamedResponse(wire.stream, 200, headers: {'content-type': 'text/event-stream'});
    }));
    final chat = ChatController(ai: service, repository: repo, currentUid: () => session.uid);
    chat.setDraft('Private question'); final pending = chat.send(); await started.future;
    wire.add(utf8.encode(delta('Partial'))); await tick();
    session.change(null); chat.sessionChanged();
    wire.add(utf8.encode(delta('Late answer') + done)); await pending;
    expect(chat.conversation.messages, isEmpty); expect(chat.busy, false);
    expect(repo.writes.length, 1); expect(repo.writes.single.$1, 'alice');
    expect(repo.records.values.expand((m) => m).where((m) => m.role == 'bot'), isEmpty);
    chat.dispose(); session.dispose(); await wire.close();
  });
}
