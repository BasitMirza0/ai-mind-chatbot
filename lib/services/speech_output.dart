import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'speech_text.dart';
import 'voice_device_access.dart';

abstract interface class SpeechOutput {
  Future<void> speak(
    Object owner,
    String text, {
    String? locale,
    VoidCallback? onStart,
  });
  Future<void> stop(Object owner);
}

abstract interface class PreparedSpeechOutput {
  Future<void> prepare();
}

class SpeechOutputFailure implements Exception {
  final String code;
  const SpeechOutputFailure(this.code);
}

class DeviceSpeechOutput implements SpeechOutput, PreparedSpeechOutput {
  static final shared = DeviceSpeechOutput();
  final FlutterTts _tts = FlutterTts();
  final VoiceDeviceAccess access;
  DeviceSpeechOutput({VoiceDeviceAccess? access})
    : access = access ?? VoiceDeviceAccess.shared;
  Future<void>? _initialization;
  Future<void> _commands = Future.value(), _stopping = Future.value();
  Object? _owner;
  int _generation = 0, _maxLength = 3000;
  Completer<void>? _cancel, _failure;
  VoidCallback? _onStart;
  List<Map> _voices = [];
  String? _defaultLanguage;
  bool _nativeActive = false;
  bool _nativeStarted = false;
  bool _stopFailed = false;
  @override
  Future<void> prepare() =>
      _initialization ??= _initialize()
          .timeout(const Duration(seconds: 10))
          .catchError((Object error, StackTrace stack) {
            _initialization = null;
            Error.throwWithStackTrace(error, stack);
          });
  Future<void> _serial(Future<void> Function() action) {
    final result = _commands.then((_) => action());
    _commands = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _nativeFailure(String code) {
    if (_nativeActive && _failure?.isCompleted == false) {
      _failure!.completeError(SpeechOutputFailure(code));
    }
  }

  Future<void> _initialize() async {
    _tts.setStartHandler(() {
      if (_nativeActive) {
        _nativeStarted = true;
        _onStart?.call();
      }
    });
    // Completion is the awaited invocation, not an uncorrelated global callback.
    _tts.setErrorHandler((_) => _nativeFailure('playback_failed'));
    _tts.setCancelHandler(() {
      // An old stop callback can arrive before the next utterance starts.
      if (_nativeStarted) _nativeFailure('playback_interrupted');
    });
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _tts.setSharedInstance(true);
    }
    await _tts.setSpeechRate(.46);
    await _tts.setVolume(1);
    await _tts.setPitch(1);
    await _tts.awaitSpeakCompletion(true);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _tts.setQueueMode(0);
      await _tts.setAudioAttributesForNavigation();
      final max = await _tts.getMaxSpeechInputLength;
      if (max != null && max >= 2) _maxLength = math.min(3000, max);
      final voice = await _tts.getDefaultVoice;
      if (voice is Map) _defaultLanguage = voice['locale'] as String?;
    }
    final voices = await _tts.getVoices;
    _voices = voices is List ? voices.whereType<Map>().toList() : [];
  }

  Future<void> _language(String? locale) async {
    final requested = locale?.replaceAll('_', '-');
    final wanted = requested ?? 'en-US';
    final family = wanted.split('-').first.toLowerCase();
    final candidates =
        _voices
            .where(
              (voice) =>
                  voice['name'] is String &&
                  voice['locale'] is String &&
                  (voice['locale'] as String)
                          .toLowerCase()
                          .split(RegExp('[-_]'))
                          .first ==
                      family &&
                  !(voice['features']?.toString().contains('notInstalled') ??
                      false),
            )
            .toList();
    int score(Map voice) =>
        (voice['network_required'] == '1' || voice['network_required'] == true
            ? 0
            : 100) +
        (voice['locale'].toString().replaceAll('_', '-').toLowerCase() ==
                wanted.toLowerCase()
            ? 20
            : 0) +
        (voice['quality'] == 'very high'
            ? 10
            : voice['quality'] == 'high'
            ? 5
            : 0);
    candidates.sort((a, b) => score(b).compareTo(score(a)));
    if (candidates.isNotEmpty) {
      final voice = candidates.first;
      if (await _tts.setLanguage(voice['locale'] as String) != 0 &&
          await _tts.setVoice({
                'name': voice['name'] as String,
                'locale': voice['locale'] as String,
              }) !=
              0) {
        return;
      }
    }
    final fallback = [
      wanted,
      if (requested == null && _defaultLanguage != null) _defaultLanguage!,
    ];
    for (final language in fallback) {
      if (await _tts.isLanguageAvailable(language) == true &&
          await _tts.setLanguage(language) != 0) {
        return;
      }
    }
    throw const SpeechOutputFailure('voice_unavailable');
  }

  @override
  Future<void> speak(
    Object owner,
    String text, {
    String? locale,
    VoidCallback? onStart,
  }) async {
    if (_owner != null) await stop(_owner!);
    final generation = ++_generation;
    _owner = owner;
    final cancelled = Completer<void>();
    _cancel = cancelled;
    bool valid() => generation == _generation && identical(owner, _owner);
    var started = false;
    Future<void> run() async {
      await _stopping;
      if (!valid()) return;
      await prepare();
      if (!valid()) return;
      await _serial(() async {
        if (!valid()) return;
        await _language(locale);
        if (!valid()) return;
        if (!await access.requestPlaybackFocus()) {
          throw const SpeechOutputFailure('audio_focus');
        }
        if (!valid()) return;
        access.onAudioFocusLost = () => _nativeFailure('audio_focus');
      });
      for (final segment in speechSegments(text, maxLength: _maxLength)) {
        if (!valid()) return;
        final failure = Completer<void>();
        // Attach error handling before native callbacks can fire.
        final waitForFailure = failure.future;
        Future<void>? native;
        _failure = failure;
        _onStart = () {
          if (valid() && !started) {
            started = true;
            onStart?.call();
          }
        };
        final result = Completer<void>();
        final outcome = Future.any<void>([
          result.future,
          waitForFailure,
          cancelled.future,
        ]);
        await _serial(() async {
          if (!valid()) {
            result.complete();
            return;
          }
          _nativeActive = true;
          _nativeStarted = false;
          native = _tts.speak(segment).then<void>((value) {
            if (valid() && value == 0) {
              throw const SpeechOutputFailure('playback_failed');
            }
          });
          native!.then(
            (_) {
              if (!result.isCompleted) result.complete();
            },
            onError: (Object e, StackTrace s) {
              if (!result.isCompleted) result.completeError(e, s);
            },
          );
        });
        await outcome.timeout(
          Duration(seconds: math.max(30, segment.length ~/ 8 + 15)),
          onTimeout: () => throw const SpeechOutputFailure('playback_timeout'),
        );
        if (!valid()) return;
        _nativeActive = false;
        _failure = null;
        _onStart = null;
      }
    }

    try {
      await Future.any<void>([run(), cancelled.future]);
    } finally {
      if (valid()) await stop(owner);
    }
  }

  @override
  Future<void> stop(Object owner) {
    if (!identical(owner, _owner) && (_owner != null || !_stopFailed)) {
      return _owner == null ? _stopping : Future.value();
    }
    _generation++;
    _owner = null;
    _nativeActive = false;
    _nativeStarted = false;
    _failure = null;
    _onStart = null;
    access.onAudioFocusLost = null;
    if (_cancel?.isCompleted == false) _cancel!.complete();
    _cancel = null;
    _stopping = _serial(() async {
      try {
        await _tts.stop().timeout(const Duration(seconds: 2));
        await access.releasePlaybackFocus().timeout(const Duration(seconds: 2));
        _stopFailed = false;
      } catch (_) {
        _stopFailed = true;
        throw const SpeechOutputFailure('stop_failed');
      }
    });
    return _stopping;
  }
}
