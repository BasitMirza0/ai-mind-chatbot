import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/backend_api_config.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/services/speech_output.dart';
import 'package:ai_chatbot/services/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_voice_dependencies.dart';

void main() {
  late FakeSession session;
  late FakeRepository repo;
  late FakeAi ai;
  late FakeSpeechDriver driver;
  late SpeechCoordinator speech;
  late FakeSpeechOutput output;
  late ChatController chat;
  late VoiceController voice;
  setUp(() {
    session = FakeSession();
    repo = FakeRepository();
    ai = FakeAi();
    driver = FakeSpeechDriver();
    speech = SpeechCoordinator(driver);
    output = FakeSpeechOutput();
    chat = ChatController(
      ai: ai,
      repository: repo,
      currentUid: () => session.uid,
      conversationType: 'voice',
      systemPrompt: 'voice',
    );
    voice = VoiceController(
      chat: chat,
      speech: speech,
      output: output,
      currentUid: () => session.uid,
    );
  });
  tearDown(() async {
    voice.dispose();
    chat.dispose();
    session.dispose();
    await ai.close();
  });
  Future<void> answer(String value) async {
    ai.streams.last.add(value);
    await ai.streams.last.close();
    await tick();
    output.complete();
    await tick();
  }

  test(
    'rapid microphone taps share one initialization and one session',
    () async {
      driver.permissionGate = Completer();
      final pending = voice.begin();
      await tick();
      expect(voice.phase, VoicePhase.initializing);
      await voice.begin();
      await voice.begin();
      expect(driver.initializations, 1);
      driver.permissionGate!.complete(true);
      await pending;
      expect(driver.listens, 1);
      expect(voice.phase, VoicePhase.listening);
      await voice.begin();
      expect(driver.listens, 1);
    },
  );
  test('denied permission can recover on an explicit subsequent tap', () async {
    driver.permitted = false;
    await voice.begin();
    expect(voice.needsMicrophoneSettings, true);
    driver.permitted = true;
    await voice.begin();
    expect(driver.listens, 1);
    expect(voice.phase, VoicePhase.listening);
    expect(ai.streams, isEmpty);
  });
  for (final code in [
    'permission_permanently_denied',
    'recognizer_unavailable',
  ]) {
    test('$code offers recovery without requesting AI', () async {
      driver.initializationError = SpeechInputFailure(code);
      await voice.begin();
      expect(voice.errorCode, code);
      expect(voice.needsMicrophoneSettings, true);
      expect(ai.streams, isEmpty);
      expect(repo.writes, isEmpty);
    });
  }
  test(
    'notListening waits for final correction and duplicate callbacks submit once',
    () async {
      await voice.begin();
      final result = driver.result!;
      result(const SpeechText('What is flatter', false));
      driver.status!('notListening');
      expect(voice.phase, VoicePhase.transcribing);
      await tick();
      expect(ai.streams, isEmpty);
      result(const SpeechText('What is Flutter?', true, confidence: .95));
      result(const SpeechText('Duplicate', true));
      driver.status!('done');
      await tick();
      expect(ai.streams.length, 1);
      expect(ai.histories.single.single['text'], 'What is Flutter?');
      await answer('Flutter is a UI toolkit.');
      expect(voice.phase, VoicePhase.idle);
    },
  );
  test(
    'manual finish stops recording and waits for final text instead of canceling it',
    () async {
      driver.finalOnStop = false;
      await voice.begin();
      driver.result!(const SpeechText('What is', false));
      final finished = voice.finishListening();
      await tick();
      expect(driver.finishes, 1);
      expect(ai.streams, isEmpty);
      driver.result!(const SpeechText('What is Flutter?', true));
      await tick();
      expect(ai.histories.last.last['text'], 'What is Flutter?');
      await answer('A framework.');
      await finished;
    },
  );
  test('empty final result never submits or automatically restarts', () async {
    await voice.begin();
    driver.result!(const SpeechText('  ', true));
    await tick();
    expect(ai.streams, isEmpty);
    expect(driver.listens, 1);
    expect(voice.errorCode, 'no_speech');
  });
  test('known low-confidence words require explicit confirmation', () async {
    await voice.begin();
    driver.result!(const SpeechText('Perhaps Flutter', true, confidence: .1));
    await tick();
    expect(ai.streams, isEmpty);
    expect(voice.canConfirmTranscript, true);
    final confirm = voice.confirmTranscript();
    await tick();
    expect(ai.streams.length, 1);
    await answer('Flutter is a toolkit.');
    await confirm;
  });
  test(
    'turns preserve context, exact original Markdown, stable IDs and ordering',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('What is Flutter?', true));
      await tick();
      await answer('**Flutter** is a UI toolkit.');
      expect(driver.listens, 1);
      await voice.begin();
      driver.result!(const SpeechText('Which language does it use?', true));
      await tick();
      expect(ai.histories.last.map((m) => m['text']), [
        'What is Flutter?',
        '**Flutter** is a UI toolkit.',
        'Which language does it use?',
      ]);
      await answer('It uses **Dart**.');
      expect(repo.records.values.single.map((m) => m.text), [
        'What is Flutter?',
        '**Flutter** is a UI toolkit.',
        'Which language does it use?',
        'It uses **Dart**.',
      ]);
      expect(repo.writes.map((w) => w.$3).toSet().length, 4);
      expect(output.spoken, ['Flutter is a UI toolkit.', 'It uses Dart.']);
      expect(driver.initializations, 1);
      expect(voice.phase, VoicePhase.idle);
    },
  );
  test(
    'new turn explicitly interrupts playback before starting recognition',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', true));
      await tick();
      ai.streams.last.add('Answer');
      await ai.streams.last.close();
      await tick();
      expect(voice.phase, VoicePhase.speaking);
      await voice.begin();
      expect(output.stops, 1);
      expect(driver.listens, 2);
      expect(voice.phase, VoicePhase.listening);
      expect(ai.streams.length, 1);
    },
  );
  test(
    'TTS failure retains completed reply and explicit replay never calls AI',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', true));
      await tick();
      ai.streams.last.add('A saved answer');
      await ai.streams.last.close();
      await tick();
      output.pending!.completeError(
        const SpeechOutputFailure('voice_unavailable'),
      );
      await tick();
      expect(voice.phase, VoicePhase.error);
      expect(voice.needsSpeechSettings, true);
      expect(chat.conversation.messages.last.saved, true);
      final replay = voice.replay();
      await tick();
      output.complete();
      await replay;
      expect(ai.streams.length, 1);
      expect(output.spoken.length, 2);
      expect(voice.phase, VoicePhase.idle);
    },
  );
  test(
    'save failure allows playback and save-only retry without duplicate speech',
    () async {
      repo.failBotSave = true;
      await voice.begin();
      driver.result!(const SpeechText('Question', true));
      await tick();
      await answer('A completed answer');
      expect(voice.phase, VoicePhase.idle);
      expect(voice.needsSave, true);
      expect(voice.notice, contains('not saved'));
      repo.failBotSave = false;
      await voice.retry();
      expect(ai.streams.length, 1);
      expect(output.spoken.length, 1);
      expect(repo.writes.length, 2);
      expect(voice.needsSave, false);
    },
  );
  test(
    'token limit is retained, not spoken or saved; explicit continuation completes',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', true));
      await tick();
      ai.streams.last.add('Partial ');
      ai.streams.last.addError(
        const BackendApiException('response_limit', 'Length limit reached.'),
      );
      await tick();
      await tick();
      expect(voice.canContinue, true);
      expect(output.spoken, isEmpty);
      expect(repo.writes.length, 1);
      final id = chat.conversation.messages.last.id;
      final pending = voice.retry(continuing: true);
      await tick();
      await answer('ending.');
      await pending;
      expect(chat.conversation.messages.last.id, id);
      expect(chat.conversation.messages.last.text, 'Partial ending.');
      expect(output.spoken, ['Partial ending.']);
      expect(repo.writes.length, 2);
    },
  );
  test('Stop listening revokes callbacks immediately', () async {
    await voice.begin();
    final callback = driver.result!;
    voice.pause();
    callback(const SpeechText('Late final', true));
    await tick();
    expect(ai.streams, isEmpty);
    expect(voice.phase, VoicePhase.paused);
  });
  test(
    'conversation switch during processing invalidates the old voice operation',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', true));
      await tick();
      chat.newConversation();
      ai.streams.last.add('Late answer');
      await tick();
      expect(voice.phase, VoicePhase.paused);
      expect(output.spoken, isEmpty);
      expect(chat.conversation.messages, isEmpty);
      expect(voice.transcript, isEmpty);
    },
  );
  for (final user in [null, 'bob']) {
    test(
      'identity change to $user rejects pending generation and speech',
      () async {
        await voice.begin();
        driver.result!(const SpeechText('Private', true));
        await tick();
        session.change(user);
        voice.sessionChanged();
        ai.streams.last.add('Late private reply');
        await tick();
        expect(voice.transcript, isEmpty);
        expect(output.spoken, isEmpty);
        expect(chat.conversation.messages, isEmpty);
        expect(repo.writes.every((w) => w.$1 == 'alice'), true);
      },
    );
  }
  for (final user in [null, 'bob']) {
    test(
      'identity change to $user stops native playback and clears transcript',
      () async {
        await voice.begin();
        driver.result!(const SpeechText('Question', true));
        await tick();
        ai.streams.last.add('Answer');
        await ai.streams.last.close();
        await tick();
        expect(voice.phase, VoicePhase.speaking);
        session.change(user);
        voice.sessionChanged();
        await tick();
        expect(output.stops, 1);
        expect(voice.transcript, isEmpty);
        expect(chat.conversation.messages, isEmpty);
        expect(driver.listens, 1);
      },
    );
  }
  test(
    'disposal during initialization cannot revive native recording',
    () async {
      final localAi = FakeAi();
      final localChat = ChatController(
        ai: localAi,
        repository: repo,
        currentUid: () => session.uid,
      );
      final localDriver =
          FakeSpeechDriver()..permissionGate = Completer<bool>();
      final localVoice = VoiceController(
        chat: localChat,
        speech: SpeechCoordinator(localDriver),
        output: FakeSpeechOutput(),
        currentUid: () => session.uid,
      );
      final pending = localVoice.begin();
      await tick();
      localVoice.dispose();
      localChat.dispose();
      localDriver.permissionGate!.complete(true);
      await pending;
      await tick();
      expect(localDriver.listens, 0);
      expect(localAi.streams, isEmpty);
      await localAi.close();
    },
  );
  test(
    'releasing pending initialization synchronously prevents a stale lease',
    () async {
      driver.permissionGate = Completer();
      final first = Object(), second = Object();
      final acquired = speech.acquire(
        first,
        onStatus: (_) {},
        onError: (_) {},
        onLost: () {},
      );
      await tick();
      final released = speech.release(first);
      final next = speech.acquire(
        second,
        onStatus: (_) {},
        onError: (_) {},
        onLost: () {},
      );
      driver.permissionGate!.complete(true);
      expect(await acquired, false);
      await released;
      expect(await next, true);
      await speech.release(first);
      expect(speech.owns(second), true);
      await speech.release(second);
    },
  );
  test(
    'speech formatter retains prose and table meaning without Markdown syntax',
    () {
      const original =
          '## A heading\n\n**Bold** and *italic* with [guide](https://example.com/private/path).\n\n| Language | Use |\n| --- | --- |\n| Dart | Flutter |\n\n```dart\nprint("Hello");\n```\n\nhttps://example.org/a/long/path\n\n---';
      final spoken = speechFriendlyText(original);
      expect(spoken, contains('Language: Dart. Use: Flutter'));
      expect(spoken, contains('print("Hello");'));
      expect(spoken, contains('link to example.org'));
      for (final marker in [
        '##',
        '**',
        '```',
        '| ---',
        '/private/path',
        '/a/long/path',
      ]) {
        expect(spoken, isNot(contains(marker)));
      }
      expect(original, contains('```dart'));
    },
  );
  test(
    'speech segments retain sentence order and do not split surrogate pairs',
    () {
      final source = List.generate(
        100,
        (i) => 'Sentence $i about Flutter.',
      ).join(' ');
      final pieces = speechSegments(source, maxLength: 90);
      expect(pieces.every((p) => p.length <= 90), true);
      expect(pieces.join(' '), source);
      final emoji = speechSegments('😀' * 20, maxLength: 7);
      expect(emoji.join(), '😀' * 20);
      expect(emoji.every((p) => p.runes.every((r) => r == 0x1F600)), true);
    },
  );
  test(
    'pause preserves transcript and partial AI text without successful assistant save',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Keep my words', true));
      await tick();
      ai.streams.last.add('Partial reply');
      await tick();
      voice.pause();
      ai.streams.last.add('Late tail');
      await tick();
      expect(voice.transcript, 'Keep my words');
      expect(chat.conversation.messages.last.text, 'Partial reply');
      expect(chat.conversation.messages.last.state, ReplyState.stopped);
      expect(repo.writes.length, 1);
    },
  );
}
