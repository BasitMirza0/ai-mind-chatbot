import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
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
      systemPrompt: 'voice',
      conversationType: 'voice',
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
  test(
    'one initializer routes callbacks to the active screen; stale owners cannot cancel it',
    () async {
      final first = Object(), second = Object();
      var lost = 0;
      final statuses = <String>[];
      final results = <String>[];
      await speech.acquire(
        first,
        onStatus: (_) => statuses.add('first'),
        onError: (_) {},
        onLost: () => lost++,
      );
      await speech.listen(
        first,
        onResult: (r) => results.add('old:${r.words}'),
      );
      final stale = driver.result!;
      await speech.acquire(
        second,
        onStatus: (_) => statuses.add('second'),
        onError: (_) {},
        onLost: () {},
      );
      await speech.listen(
        second,
        onResult: (r) => results.add('new:${r.words}'),
      );
      final cancels = driver.cancels;
      await speech.release(first);
      expect(driver.cancels, cancels);
      stale(const SpeechText('late', true));
      driver.result!(const SpeechText('current', true));
      driver.status!('done');
      expect(driver.initializations, 1);
      expect(lost, 1);
      expect(results, ['new:current']);
      expect(statuses, ['second']);
      await speech.release(second);
    },
  );
  test(
    'permission denial yields a visible error without AI or persistence',
    () async {
      driver.permitted = false;
      await voice.begin();
      expect(voice.phase, VoicePhase.error);
      expect(voice.error, contains('permission'));
      expect(ai.streams, isEmpty);
      expect(repo.writes, isEmpty);
    },
  );
  test('guests do not request microphone permission or AI', () async {
    session.change(null);
    voice.sessionChanged();
    await voice.begin();
    expect(driver.initializations, 0);
    expect(voice.error, contains('Sign in'));
  });
  test(
    'listening processing speaking and Ready use real completions',
    () async {
      await voice.begin();
      expect(voice.phase, VoicePhase.listening);
      driver.result!(const SpeechText('A question', false));
      final pending = voice.finishListening();
      await tick();
      expect(voice.phase, VoicePhase.processing);
      expect(ai.streams.length, 1);
      ai.streams.single.add('**A clear answer.**');
      await ai.streams.single.close();
      await tick();
      expect(voice.phase, VoicePhase.speaking);
      expect(output.spoken, ['A clear answer.']);
      expect(repo.writes.length, 2);
      output.complete();
      await pending;
      expect(voice.phase, VoicePhase.idle);
      expect(driver.listens, 1);
    },
  );
  test('double final/status submission sends exactly one request', () async {
    await voice.begin();
    driver.result!(const SpeechText('One question', false));
    final pending = voice.finishListening();
    await voice.finishListening();
    driver.status!('done');
    await tick();
    expect(ai.streams.length, 1);
    voice.pause();
    await pending;
    expect(voice.phase, VoicePhase.paused);
  });
  test(
    'stop during processing cancels and late output cannot speak or persist',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', false));
      final pending = voice.finishListening();
      await tick();
      ai.streams.last.add('partial');
      await tick();
      voice.pause();
      ai.streams.last.add('late');
      await pending;
      expect(voice.phase, VoicePhase.paused);
      expect(output.spoken, isEmpty);
      expect(repo.writes.length, 1);
    },
  );
  test('paused TTS does not automatically restart the microphone', () async {
    await voice.begin();
    driver.result!(const SpeechText('Question', false));
    final pending = voice.finishListening();
    await tick();
    ai.streams.last.add('Answer');
    await ai.streams.last.close();
    await tick();
    voice.pause();
    output.complete();
    await pending;
    expect(voice.phase, VoicePhase.paused);
    expect(driver.listens, 1);
  });
  test('language is forwarded to recognition and output', () async {
    await voice.loadLanguages();
    expect(voice.languages.length, 2);
    voice.setLanguage('ur_PK');
    await voice.begin();
    expect(driver.locale, 'ur_PK');
    driver.result!(const SpeechText('Question', false));
    final pending = voice.finishListening();
    await tick();
    ai.streams.last.add('Answer');
    await ai.streams.last.close();
    await tick();
    expect(output.locales, ['ur_PK']);
    voice.pause();
    await pending;
  });
  test('permission result after pause cannot start listening', () async {
    driver.permissionGate = Completer();
    final start = voice.begin();
    await tick();
    voice.pause();
    driver.permissionGate!.complete(true);
    await start;
    await tick();
    expect(driver.listens, 0);
    expect(voice.phase, VoicePhase.paused);
  });
  test('account changes clear transcript and reject late replies', () async {
    await voice.begin();
    driver.result!(const SpeechText('Private', false));
    final request = voice.finishListening();
    await tick();
    session.change('bob');
    voice.sessionChanged();
    ai.streams.last.add('private result');
    await request;
    expect(voice.transcript, isEmpty);
    expect(chat.conversation.messages, isEmpty);
    expect(output.spoken, isEmpty);
  });
  test('permission errors stop instead of restarting endlessly', () async {
    await voice.begin();
    driver.error!('error_permission');
    await tick();
    expect(voice.phase, VoicePhase.error);
    expect(driver.listens, 1);
    expect(voice.error, contains('permission'));
  });
  test(
    'backend failure is visible and never becomes a saved assistant response',
    () async {
      await voice.begin();
      driver.result!(const SpeechText('Question', false));
      final request = voice.finishListening();
      await tick();
      ai.streams.last.addError(StateError('offline'));
      await request;
      expect(voice.phase, VoicePhase.error);
      expect(repo.writes.length, 1);
      expect(output.spoken, isEmpty);
    },
  );
  test('network recognition errors give connection guidance', () async {
    await voice.begin();
    driver.error!('error_network');
    await tick();
    expect(voice.phase, VoicePhase.error);
    expect(voice.error, contains('connection'));
    expect(ai.streams, isEmpty);
  });
  test('no-match does not restart and pause cancels final callbacks', () async {
    await voice.begin();
    driver.error!('error_no_match');
    await tick();
    expect(voice.phase, VoicePhase.error);
    expect(driver.listens, 1);
    await voice.begin();
    final stale = driver.result!;
    voice.pause();
    stale(const SpeechText('Do not submit after pause', true));
    await tick();
    expect(ai.streams, isEmpty);
    expect(voice.phase, VoicePhase.paused);
  });
  test('final recognition submits without artificial delay', () async {
    await voice.begin();
    driver.result!(const SpeechText('A final question', true));
    await tick();
    expect(ai.streams.length, 1);
    voice.pause();
    await tick();
  });
}
