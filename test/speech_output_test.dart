import 'dart:async';
import 'package:ai_chatbot/services/speech_output.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  const accessChannel = MethodChannel('ai_mind/voice');
  final calls = <MethodCall>[];
  Completer<Object?>? initializeGate, speakGate;
  List<Map<String, String>> voices = [];
  bool languageAvailable = true;
  int maxLength = 4000;
  Future<Object?> Function()? nextSpeak;
  late DeviceSpeechOutput output;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    initializeGate = null;
    speakGate = null;
    voices = [];
    languageAvailable = true;
    maxLength = 4000;
    nextSpeak = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setSpeechRate' && initializeGate != null) {
            return initializeGate!.future;
          }
          if (call.method == 'getDefaultVoice') return {'locale': 'en-US'};
          if (call.method == 'getMaxSpeechInputLength') return maxLength;
          if (call.method == 'getVoices') return voices;
          if (call.method == 'isLanguageAvailable') return languageAvailable;
          if (call.method == 'speak' && nextSpeak != null) return nextSpeak!();
          if (call.method == 'speak' && speakGate != null) {
            return speakGate!.future;
          }
          return 1;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(accessChannel, (call) async => true);
    output = DeviceSpeechOutput();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(accessChannel, null);
  });
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> event(String name, {String target = 'flutter_tts'}) async {
    ServicesBinding.instance.channelBuffers.push(
      target,
      const StandardMethodCodec().encodeMethodCall(MethodCall(name, true)),
      (_) {},
    );
    await flush();
  }

  test(
    'prewarming configures once without acquiring playback or speaking',
    () async {
      await Future.wait([output.prepare(), output.prepare()]);
      expect(calls.where((c) => c.method == 'setSpeechRate').length, 1);
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
      await output.speak(Object(), 'Ready');
      expect(calls.where((c) => c.method == 'setSpeechRate').length, 1);
    },
  );
  test('installed offline high-quality English voice is preferred', () async {
    voices = [
      {
        'name': 'network',
        'locale': 'en-US',
        'network_required': '1',
        'quality': 'very high',
      },
      {
        'name': 'offline',
        'locale': 'en-US',
        'network_required': '0',
        'quality': 'high',
      },
      {
        'name': 'basic',
        'locale': 'en-US',
        'network_required': '0',
        'quality': 'normal',
      },
    ];
    await output.speak(Object(), 'Hello');
    expect(
      (calls.firstWhere((c) => c.method == 'setVoice').arguments
          as Map)['name'],
      'offline',
    );
  });
  test(
    'no suitable voice returns a recoverable failure without speaking',
    () async {
      languageAvailable = false;
      await expectLater(
        output.speak(Object(), 'Hello'),
        throwsA(
          isA<SpeechOutputFailure>().having(
            (e) => e.code,
            'code',
            'voice_unavailable',
          ),
        ),
      );
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
    },
  );
  test(
    'long speech segments wait in order below the native input limit',
    () async {
      maxLength = 80;
      final gates = <Completer<Object?>>[];
      nextSpeak = () {
        final gate = Completer<Object?>();
        gates.add(gate);
        return gate.future;
      };
      final source = List.generate(
        16,
        (i) => 'Sentence $i about Flutter.',
      ).join(' ');
      var complete = false;
      final pending = output
          .speak(Object(), source)
          .then((_) => complete = true);
      await flush();
      expect(gates.length, 1);
      for (var index = 0; !complete && index < 20; index++) {
        expect(gates.length, index + 1);
        gates[index].complete(1);
        await flush();
      }
      await pending;
      final segments =
          calls
              .where((c) => c.method == 'speak')
              .map((c) => c.arguments as String)
              .toList();
      expect(segments.every((s) => s.length <= 80), true);
      expect(segments.join(' '), source);
    },
  );
  test(
    'Speaking begins only on native start; stale global completion cannot finish it',
    () async {
      speakGate = Completer();
      var started = 0, finished = false;
      final pending = output
          .speak(Object(), 'Hello', onStart: () => started++)
          .then((_) => finished = true);
      await flush();
      expect(started, 0);
      await event('speak.onComplete');
      expect(finished, false);
      await event('speak.onStart');
      expect(started, 1);
      await event('speak.onStart');
      expect(started, 1);
      speakGate!.complete(1);
      await pending;
      expect(finished, true);
    },
  );
  test(
    'Android audio-focus loss interrupts playback and releases its waiter',
    () async {
      speakGate = Completer();
      final pending = output.speak(Object(), 'Hello');
      final checked = expectLater(
        pending,
        throwsA(
          isA<SpeechOutputFailure>().having(
            (e) => e.code,
            'code',
            'audio_focus',
          ),
        ),
      );
      await flush();
      await event('speak.onStart');
      await event('audioFocusLost', target: 'ai_mind/voice');
      await checked;
      speakGate!.complete(1);
      await flush();
      expect(calls.where((c) => c.method == 'stop'), isNotEmpty);
    },
  );
  test('stop during native initialization prevents a late utterance', () async {
    initializeGate = Completer();
    final owner = Object();
    final pending = output.speak(owner, 'Private text');
    await flush();
    await output.stop(owner);
    initializeGate!.complete(1);
    await pending;
    expect(calls.where((c) => c.method == 'speak'), isEmpty);
  });
  test('same owner restarting cannot revive an old initialization', () async {
    initializeGate = Completer();
    final owner = Object();
    final old = output.speak(owner, 'Old');
    await flush();
    await output.stop(owner);
    final next = output.speak(owner, 'Current', locale: 'ur_PK');
    initializeGate!.complete(1);
    await Future.wait([old, next]);
    final spoken = calls.where((c) => c.method == 'speak').toList();
    expect(spoken.length, 1);
    expect(spoken.single.arguments, 'Current');
    expect(
      calls.where((c) => c.method == 'setLanguage').last.arguments,
      'ur-PK',
    );
    await output.stop(owner);
  });
  test(
    'stop completes a pending native speak and ignores a stale owner',
    () async {
      speakGate = Completer();
      final owner = Object();
      var completed = false;
      final pending = output
          .speak(owner, 'Reply')
          .then((_) => completed = true);
      await flush();
      expect(completed, false);
      await output.stop(Object());
      expect(completed, false);
      await output.stop(owner);
      await pending;
      expect(completed, true);
      speakGate!.complete(1);
      await flush();
    },
  );
  test('native speech failure propagates for visible error feedback', () async {
    speakGate = Completer();
    final owner = Object();
    final pending = output.speak(owner, 'Reply');
    final expectation = expectLater(
      pending,
      throwsA(isA<SpeechOutputFailure>()),
    );
    await flush();
    speakGate!.complete(0);
    await expectation;
    await output.stop(owner);
  });
}
