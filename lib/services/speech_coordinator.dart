import 'dart:async';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'voice_device_access.dart';

class SpeechText {
  final String words;
  final bool isFinal;

  /// Null means the platform did not supply a confidence score.
  final double? confidence;
  const SpeechText(this.words, this.isFinal, {this.confidence});
}

class SpeechLanguage {
  final String id, name;
  const SpeechLanguage(this.id, this.name);
}

class SpeechInputFailure implements Exception {
  final String code;
  const SpeechInputFailure(this.code);
}

abstract interface class SpeechDriver {
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  });
  Future<void> listen({
    String? locale,
    required void Function(SpeechText) onResult,
  });
  Future<void> stop();
  Future<void> cancel();
  Future<List<SpeechLanguage>> languages();
}

class DeviceSpeechDriver implements SpeechDriver {
  final SpeechToText _speech;
  final VoiceDeviceAccess access;
  DeviceSpeechDriver({VoiceDeviceAccess? access, SpeechToText? speech})
    : access = access ?? VoiceDeviceAccess.shared,
      _speech = speech ?? SpeechToText();
  @override
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  }) async {
    if (!await access.recognitionAvailable()) {
      throw const SpeechInputFailure('recognizer_unavailable');
    }
    final permission = await access.microphoneStatus();
    if (permission == 'permanentlyDenied') {
      throw const SpeechInputFailure('permission_permanently_denied');
    }
    if (permission != 'granted') await access.markMicrophoneRequested();
    try {
      final ready = await _speech.initialize(
        onStatus: onStatus,
        onError: (error) => onError(error.errorMsg),
        debugLogging: false,
        // This phase uses the phone microphone, without requiring Bluetooth.
        options: [SpeechToText.androidNoBluetooth],
      );
      if (!ready) {
        final denied = await access.microphoneStatus();
        throw SpeechInputFailure(
          denied == 'permanentlyDenied'
              ? 'permission_permanently_denied'
              : 'permission_denied',
        );
      }
      return true;
    } on PlatformException catch (error) {
      throw SpeechInputFailure(
        error.code == 'recognizerNotAvailable'
            ? 'recognizer_unavailable'
            : 'recognizer_initialization',
      );
    }
  }

  @override
  Future<void> listen({
    String? locale,
    required void Function(SpeechText) onResult,
  }) async {
    // Permission can be revoked after the plugin's one successful initialize.
    if (!await _speech.hasPermission) {
      throw const SpeechInputFailure('permission_permanently_denied');
    }
    await _speech.listen(
      onResult:
          (result) => onResult(
            SpeechText(
              result.recognizedWords,
              result.finalResult,
              confidence: result.hasConfidenceRating ? result.confidence : null,
            ),
          ),
      listenOptions: SpeechListenOptions(
        localeId: locale,
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
  @override
  Future<void> cancel() => _speech.cancel();
  @override
  Future<List<SpeechLanguage>> languages() async =>
      (await _speech.locales())
          .map((l) => SpeechLanguage(l.localeId, l.name))
          .toList();
}

/// One plugin initializer, one microphone lease, and serialized native calls.
/// Revocation is synchronous even when permission/initialization is still pending.
class SpeechCoordinator {
  static final shared = SpeechCoordinator(DeviceSpeechDriver());
  final SpeechDriver driver;
  SpeechCoordinator(this.driver);
  Object? _owner, _requestedOwner;
  int _intent = 0, _generation = 0;
  bool _ready = false, _acceptEvents = false;
  void Function(String)? _status, _error;
  void Function()? _lost;
  Future<void> _queue = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  bool owns(Object owner) => identical(owner, _owner);
  Future<bool> acquire(
    Object owner, {
    required void Function(String) onStatus,
    required void Function(String) onError,
    required void Function() onLost,
  }) {
    final intent = ++_intent;
    _requestedOwner = owner;
    return _serial(() async {
      if (intent != _intent) return false;
      if (!owns(owner)) {
        final lost = _lost;
        _generation++;
        _acceptEvents = false;
        _owner = null;
        _lost = null;
        lost?.call();
        await driver.cancel();
        if (intent != _intent) return false;
      }
      _owner = owner;
      _status = onStatus;
      _error = onError;
      _lost = onLost;
      if (!_ready) {
        _ready = await driver.initialize(
          onStatus: (status) {
            if (_acceptEvents && _owner != null) _status?.call(status);
          },
          onError: (error) {
            if (_acceptEvents && _owner != null) _error?.call(error);
          },
        );
      }
      return intent == _intent && _ready && owns(owner);
    });
  }

  Future<void> listen(
    Object owner, {
    String? locale,
    required void Function(SpeechText) onResult,
  }) {
    final intent = _intent;
    return _serial(() async {
      if (!owns(owner) || !_ready || intent != _intent) return;
      final generation = ++_generation;
      _acceptEvents = true;
      await driver.listen(
        locale: locale,
        onResult: (result) {
          if (owns(owner) && _acceptEvents && generation == _generation) {
            onResult(result);
          }
        },
      );
    });
  }

  /// Stop recording, but retain the lease until Android delivers its final text.
  Future<void> finish(Object owner) => _serial(() async {
    if (owns(owner) && _acceptEvents) await driver.stop();
  });
  Future<List<SpeechLanguage>> languages(Object owner) => _serial(
    () async => owns(owner) && _ready ? driver.languages() : <SpeechLanguage>[],
  );
  Future<void> release(Object owner) {
    if (identical(_requestedOwner, owner)) {
      _intent++;
      _requestedOwner = null;
    }
    if (!owns(owner)) return Future.value();
    _generation++;
    _acceptEvents = false;
    _owner = null;
    _status = null;
    _error = null;
    _lost = null;
    return _serial(driver.cancel);
  }
}
