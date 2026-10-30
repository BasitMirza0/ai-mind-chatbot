import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android settings/focus only. STT permission requests remain plugin-owned.
class VoiceDeviceAccess {
  static final shared = VoiceDeviceAccess();
  static const _channel = MethodChannel('ai_mind/voice');
  VoidCallback? onAudioFocusLost;
  VoiceDeviceAccess() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioFocusLost') onAudioFocusLost?.call();
    });
  }
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<String> microphoneStatus() async =>
      _android
          ? await _channel.invokeMethod<String>('microphoneStatus') ?? 'denied'
          : 'granted';
  Future<void> markMicrophoneRequested() async {
    if (_android) await _channel.invokeMethod<void>('markMicrophoneRequested');
  }

  Future<bool> recognitionAvailable() async =>
      !_android ||
      await _channel.invokeMethod<bool>('recognitionAvailable') == true;
  Future<bool> requestPlaybackFocus() async =>
      !_android ||
      await _channel.invokeMethod<bool>('requestPlaybackFocus') == true;
  Future<void> releasePlaybackFocus() async {
    if (_android) await _channel.invokeMethod<void>('releasePlaybackFocus');
  }

  Future<bool> openSettings({
    bool speechOutput = false,
    bool recognition = false,
  }) async =>
      _android &&
      await _channel.invokeMethod<bool>(
            speechOutput
                ? 'openSpeechSettings'
                : recognition
                ? 'openRecognitionSettings'
                : 'openAppSettings',
          ) ==
          true;
}
