import 'dart:convert';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/backend_ai_service.dart';
import 'package:ai_chatbot/services/backend_api_config.dart';
import 'package:ai_chatbot/services/chat_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/fake_chat_dependencies.dart';

const rid = '0123456789abcdef0123456789abcdef';
String delta(String value) =>
    'event: delta\ndata: ${jsonEncode({'text': value})}\n\n';
String done(String reason) =>
    'event: done\ndata: ${jsonEncode({'finish_reason': reason, 'request_id': rid})}\n\n';
BackendAiService service(
  http.Client client, {
  BackendApiConfig config = const BackendApiConfig(
    baseUrl: 'https://backend.example',
  ),
}) => BackendAiService(
  config: config,
  clientFactory: () => client,
  tokenProvider: () async => 'test-only-token',
);
http.Response response(String wire) => http.Response(
  wire,
  200,
  headers: {'content-type': 'text/event-stream', 'x-request-id': rid},
);

void main() {
  for (final length in [10, 30000]) {
    test(
      'successful $length-character stream saves only after terminal and correlates',
      () async {
        final repo = FakeRepository();
        final s = FakeSession();
        final source = 'x' * length;
        final ai = service(
          MockClient((_) async => response(delta(source) + done('stop'))),
        );
        final traces = <ChatTrace>[];
        ai.streamTrace.addListener(() => traces.add(ai.streamTrace.value));
        final chat = ChatController(
          ai: ai,
          repository: repo,
          currentUid: () => s.uid,
        );
        chat.setDraft('Synthetic question');
        await chat.send();
        expect(chat.conversation.messages.last.saved, isTrue);
        expect(repo.records.values.single.last.text, source);
        expect(chat.conversation.messages.last.requestId, rid);
        expect(
          traces.any(
            (e) => e.state == 'terminal_received' && e.finishReason == 'stop',
          ),
          isTrue,
        );
        expect(
          jsonEncode(traces.map((t) => t.fields).toList()),
          isNot(contains('test-only-token')),
        );
        chat.dispose();
        s.dispose();
      },
    );
  }

  for (final ending in [
    '',
    'event: done\ndata: {"finish_reason":"stop"}\n',
    done('length'),
  ]) {
    test(
      'substantial prefix with ${ending.isEmpty
          ? 'EOF'
          : ending.contains('length')
          ? 'length'
          : 'unfinished event'} remains unsaved',
      () async {
        var calls = 0;
        final repo = FakeRepository();
        final session = FakeSession();
        final ai = service(
          MockClient((_) async {
            calls++;
            return response(delta('prefix ' * 3000) + ending);
          }),
        );
        final chat = ChatController(
          ai: ai,
          repository: repo,
          currentUid: () => session.uid,
        );
        chat.setDraft('Question');
        await chat.send();
        expect(calls, 1);
        expect(repo.writes, hasLength(1));
        expect(chat.conversation.messages.last.text, 'prefix ' * 3000);
        expect(chat.conversation.messages.last.saved, false);
        expect(
          chat.conversation.messages.last.state,
          ending.contains('length') ? ReplyState.truncated : ReplyState.failed,
        );
        expect(chat.canContinue, ending.contains('length'));
        chat.dispose();
        session.dispose();
      },
    );
  }

  test(
    'explicit continuation keeps IDs, sends bounded context and persists only after stop',
    () async {
      final ai = FakeAi();
      final repo = FakeRepository();
      final session = FakeSession();
      final chat = ChatController(
        ai: ai,
        repository: repo,
        currentUid: () => session.uid,
      );
      chat.setDraft('Detailed guidance');
      final first = chat.send();
      await tick();
      final partial = 'A paragraph. ' * 3000;
      ai.streams.last.add(partial);
      ai.streams.last.addError(
        const BackendApiException('response_limit', 'Length limit'),
      );
      await first;
      final ids = chat.conversation.messages.map((m) => m.id).toList();
      expect(chat.canContinue, true);
      expect(repo.writes.length, 1);
      final continuation = chat.continueResponse();
      await tick();
      await chat.continueResponse(); // Duplicate tap must be a no-op.
      expect(ai.streams, hasLength(2));
      expect(ai.histories.last.last['role'], 'user');
      expect(
        ai.histories.last.every(
          (m) => (m['text'] as String).runes.length <= 12000,
        ),
        true,
      );
      expect(
        ai.histories.last.fold<int>(
          0,
          (n, m) => n + (m['text'] as String).runes.length,
        ),
        lessThanOrEqualTo(48000),
      );
      ai.streams.last.add('The ending.');
      await ai.streams.last.close();
      await continuation;
      expect(chat.conversation.messages.map((m) => m.id).toList(), ids);
      expect(repo.writes.length, 2);
      expect(repo.records.values.single.last.text, '${partial}The ending.');
      chat.dispose();
      session.dispose();
      await ai.close();
    },
  );

  test(
    'retry archives partial source without duplicate turns or automatic generation',
    () async {
      final ai = FakeAi();
      final repo = FakeRepository();
      final session = FakeSession();
      final chat = ChatController(
        ai: ai,
        repository: repo,
        currentUid: () => session.uid,
      );
      chat.setDraft('Question');
      final pending = chat.send();
      await tick();
      ai.streams.last.add('Original partial');
      ai.streams.last.addError(
        const BackendApiException('backend_unavailable', 'Offline'),
      );
      await pending;
      final ids = chat.conversation.messages.map((m) => m.id).toList();
      expect(ai.streams.length, 1);
      final retry = chat.retry();
      await tick();
      expect(chat.conversation.messages.last.previousAttempts, [
        'Original partial',
      ]);
      ai.streams.last.add('Replacement');
      await ai.streams.last.close();
      await retry;
      expect(chat.conversation.messages.map((m) => m.id).toList(), ids);
      expect(repo.writes.length, 2);
      chat.dispose();
      session.dispose();
      await ai.close();
    },
  );

  test(
    'continued response sign-out cancels and clears private partial drafts',
    () async {
      final ai = FakeAi();
      final repo = FakeRepository();
      final session = FakeSession();
      final chat = ChatController(
        ai: ai,
        repository: repo,
        currentUid: () => session.uid,
      );
      chat.setDraft('Question');
      final pending = chat.send();
      await tick();
      ai.streams.last.add('Partial');
      ai.streams.last.addError(
        const BackendApiException('response_limit', 'Limit'),
      );
      await pending;
      final continued = chat.continueResponse();
      await tick();
      session.change(null);
      chat.sessionChanged();
      ai.streams.last.add('Late');
      await continued;
      expect(chat.localConversations, isEmpty);
      expect(repo.writes.length, 1);
      expect(ai.cancellations, greaterThan(0));
      chat.dispose();
      session.dispose();
      await ai.close();
    },
  );

  test(
    'save failure is categorized and retries only storage after a long success',
    () async {
      var requests = 0;
      final repo = FakeRepository()..failBotSave = true;
      final session = FakeSession();
      final ai = service(
        MockClient((_) async {
          requests++;
          return response(delta('detail ' * 3000) + done('stop'));
        }),
      );
      final chat = ChatController(
        ai: ai,
        repository: repo,
        currentUid: () => session.uid,
      );
      chat.setDraft('Question');
      await chat.send();
      expect(chat.conversation.messages.last.state, ReplyState.complete);
      expect(chat.conversation.messages.last.failureCode, 'firestore');
      repo.failBotSave = false;
      await chat.retry();
      expect(requests, 1);
      expect(chat.conversation.messages.last.saved, true);
      expect(repo.writes.length, 2);
      chat.dispose();
      session.dispose();
    },
  );

  test(
    'diagnostics reject content-like fields and malformed correlation IDs',
    () {
      final trace = ChatTrace(
        'request_error',
        requestId: 'private prompt here',
        category: 'Bearer secret text',
        finishReason: 'private content',
      );
      expect(trace.fields['request_id'], 'unassigned');
      expect(trace.fields['category'], 'unknown');
      expect(trace.fields['finish_reason'], 'unknown');
    },
  );
}
