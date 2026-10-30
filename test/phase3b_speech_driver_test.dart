import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/services/voice_device_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('ai_mind/voice');
  const plugin = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final calls = <MethodCall>[];
  var permission = 'denied', available = true, grant = true;
  late DeviceSpeechDriver driver;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    permission = 'denied';
    available = true;
    grant = true;
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      return switch (call.method) {
        'microphoneStatus' => permission,
        'recognitionAvailable' => available,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        if (grant) permission = 'granted';
        return grant;
      }
      if (call.method == 'has_permission') return permission == 'granted';
      if (call.method == 'locales') return ['en_US:English'];
      return true;
    });
    driver = DeviceSpeechDriver(
      access: VoiceDeviceAccess(),
      speech: SpeechToText.withMethodChannel(),
    );
  });
  tearDown(() async {
    await driver.cancel();
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(plugin, null);
  });
  test(
    'first microphone request is plugin-owned and initialization is retained',
    () async {
      final coordinator = SpeechCoordinator(driver);
      final owner = Object();
      await coordinator.acquire(
        owner,
        onStatus: (_) {},
        onError: (_) {},
        onLost: () {},
      );
      await coordinator.listen(owner, onResult: (_) {});
      await coordinator.release(owner);
      await coordinator.acquire(
        owner,
        onStatus: (_) {},
        onError: (_) {},
        onLost: () {},
      );
      expect(calls.where((c) => c.method == 'initialize').length, 1);
      expect(
        calls.where((c) => c.method == 'markMicrophoneRequested').length,
        1,
      );
      await coordinator.release(owner);
    },
  );
  test(
    'permanent denial does not repeatedly invoke the permission dialog',
    () async {
      permission = 'permanentlyDenied';
      await expectLater(
        driver.initialize(onStatus: (_) {}, onError: (_) {}),
        throwsA(
          isA<SpeechInputFailure>().having(
            (e) => e.code,
            'code',
            'permission_permanently_denied',
          ),
        ),
      );
      expect(calls.where((c) => c.method == 'initialize'), isEmpty);
    },
  );
  test(
    'missing recognizer is distinct from denied microphone permission',
    () async {
      available = false;
      await expectLater(
        driver.initialize(onStatus: (_) {}, onError: (_) {}),
        throwsA(
          isA<SpeechInputFailure>().having(
            (e) => e.code,
            'code',
            'recognizer_unavailable',
          ),
        ),
      );
      expect(
        calls.where((c) => c.method == 'markMicrophoneRequested'),
        isEmpty,
      );
    },
  );
  test(
    'revoked permission after initialization is detected before listen',
    () async {
      await driver.initialize(onStatus: (_) {}, onError: (_) {});
      permission = 'permanentlyDenied';
      await expectLater(
        driver.listen(onResult: (_) {}),
        throwsA(isA<SpeechInputFailure>()),
      );
      expect(calls.where((c) => c.method == 'listen'), isEmpty);
    },
  );
}
