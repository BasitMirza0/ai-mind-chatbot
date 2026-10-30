import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/conversation.dart';
import '../services/speech_coordinator.dart';
import '../services/speech_output.dart';
import '../services/speech_text.dart';
import '../services/voice_diagnostics.dart';
import 'chat_controller.dart';

enum VoicePhase {
  idle,
  initializing,
  listening,
  transcribing,
  processing,
  speaking,
  paused,
  error,
}

/// A deliberate, turn-based session. A native final result submits once; playback
/// completion returns to Ready. There is no background/always-on recognizer.
class VoiceController extends ChangeNotifier {
  final ChatController chat;
  final SpeechCoordinator speech;
  final SpeechOutput output;
  final String? Function() currentUid;
  VoiceController({
    required this.chat,
    required this.speech,
    required this.output,
    required this.currentUid,
  }) {
    _conversationId = chat.conversation.id;
    chat.addListener(_chatChanged);
    chat.streamingText.addListener(_streamChanged);
  }
  VoicePhase phase = VoicePhase.idle;
  late String _conversationId;
  void _chatChanged() {
    if (_conversationId != chat.conversation.id) {
      _conversationId = chat.conversation.id;
      if (active) pause(reason: 'conversation_changed');
      transcript = '';
      error = null;
      errorCode = null;
      notice = null;
      _spokenMessageId = null;
    }
    _changed();
  }

  String transcript = '';
  String? error, errorCode, notice, locale;
  List<SpeechLanguage> languages = [];
  bool _disposed = false, _manualFinish = false;
  final _clock = Stopwatch();
  bool _firstDelta = false;
  String? _activeRequestId;
  void _trace(String state, {String? category, int characters = 0}) {
    traceVoice(
      state,
      elapsedMs: _clock.elapsedMilliseconds,
      category: category,
      characters: characters,
      requestId: _activeRequestId,
    );
  }

  void _streamChanged() {
    if (!_disposed &&
        phase == VoicePhase.processing &&
        !_firstDelta &&
        chat.streamingText.value.isNotEmpty) {
      _firstDelta = true;
      _activeRequestId = chat.conversation.messages.last.requestId;
      _trace('first_delta');
    }
  }

  int _generation = 0;
  double? _confidence;
  String? _spokenMessageId;
  Timer? _finalTimer, _listenTimer;
  Completer<void>? _turnDone;
  Future<void> _cleanup = Future.value();
  bool get active => [
    VoicePhase.initializing,
    VoicePhase.listening,
    VoicePhase.transcribing,
    VoicePhase.processing,
    VoicePhase.speaking,
  ].contains(phase);
  bool get needsMicrophoneSettings => [
    'permission_denied',
    'permission_permanently_denied',
    'recognizer_unavailable',
  ].contains(errorCode);
  bool get needsSpeechSettings => [
    'voice_unavailable',
    'playback_failed',
    'playback_timeout',
  ].contains(errorCode);
  bool get canConfirmTranscript =>
      phase == VoicePhase.error &&
      transcript.trim().isNotEmpty &&
      ['low_confidence', 'final_missing'].contains(errorCode);
  bool get canRetryResponse => !active && chat.canRetry;
  bool get canContinue => !active && chat.canContinue;
  bool get canReplay =>
      !active &&
      chat.conversation.messages.isNotEmpty &&
      chat.conversation.messages.last.role == 'bot' &&
      chat.conversation.messages.last.state == ReplyState.complete;
  bool get needsSave => chat.conversation.messages.any(
    (m) => !m.saved && m.state == ReplyState.complete,
  );
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(int generation, String uid) =>
      !_disposed && generation == _generation && currentUid() == uid;
  void _finishTurn() {
    _finalTimer?.cancel();
    _listenTimer?.cancel();
    if (_turnDone?.isCompleted == false) _turnDone!.complete();
  }

  void _fail(String code, String message) {
    _trace('error', category: code);
    pause(deliberate: false);
    errorCode = code;
    error = message;
    phase = VoicePhase.error;
    _changed();
  }

  void _inputFailure(Object failure) {
    if (failure is SpeechOutputFailure) {
      _fail(
        'playback_failed',
        'Speech playback could not stop. Check Android speech output before trying again.',
      );
      return;
    }
    final code =
        failure is SpeechInputFailure
            ? failure.code
            : 'recognizer_initialization';
    final message = switch (code) {
      'permission_denied' =>
        'Microphone permission is needed. Tap Start talking to try again, or enable it in Android Settings.',
      'permission_permanently_denied' =>
        'Microphone permission is off. Enable it for AI Mind in Android Settings, then return and tap Start talking.',
      'recognizer_unavailable' =>
        'Android speech recognition is unavailable. Enable or install a speech recognition service in Android Settings.',
      _ =>
        'Voice input is unavailable. Check your microphone and connection, then try again.',
    };
    _fail(code, message);
  }

  Future<bool> _acquire(int generation, String uid) => speech.acquire(
    this,
    onLost: () {
      if (_valid(generation, uid)) pause();
    },
    onStatus: (status) {
      if (!_valid(generation, uid) ||
          ![VoicePhase.listening, VoicePhase.transcribing].contains(phase)) {
        return;
      }
      if (status == 'done' || status == 'notListening') {
        phase = VoicePhase.transcribing;
        _changed();
        _awaitFinal(generation, uid);
      }
    },
    onError: (code) {
      if (!_valid(generation, uid) ||
          ![VoicePhase.listening, VoicePhase.transcribing].contains(phase)) {
        return;
      }
      if (code == 'error_no_match' || code == 'error_speech_timeout') {
        _fail(
          transcript.trim().isEmpty ? 'no_speech' : 'final_missing',
          transcript.trim().isEmpty
              ? 'No speech detected. Tap Start talking when you are ready.'
              : 'Recognition ended before a final transcript. Check your words before sending.',
        );
      } else if ([
        'error_network',
        'error_network_timeout',
        'error_server',
        'error_server_disconnected',
      ].contains(code)) {
        _fail(
          'recognition_network',
          'Voice recognition could not connect. Check your connection and try again.',
        );
      } else if (code == 'error_permission' ||
          code == 'error_insufficient_permissions') {
        _inputFailure(
          const SpeechInputFailure('permission_permanently_denied'),
        );
      } else {
        _fail(
          'recognition_interrupted',
          'Microphone interrupted. Tap Start talking to try again.',
        );
      }
    },
  );
  Future<void> loadLanguages() async {
    if (active) return;
    final uid = currentUid();
    if (uid == null) {
      _fail(
        'sign_in_required',
        'Sign in to use voice. Guest browsing remains available.',
      );
      return;
    }
    final generation = ++_generation;
    phase = VoicePhase.initializing;
    _changed();
    try {
      await _cleanup;
      if (!_valid(generation, uid)) return;
      final ready = await _acquire(generation, uid);
      if (!_valid(generation, uid)) return;
      if (!ready) throw const SpeechInputFailure('permission_denied');
      final available = await speech.languages(this);
      await speech.release(this);
      if (!_valid(generation, uid)) return;
      languages = available;
      phase = VoicePhase.idle;
      _changed();
    } catch (e) {
      if (_valid(generation, uid)) _inputFailure(e);
    }
  }

  void setLanguage(String? value) {
    pause();
    locale = value;
    error = null;
    errorCode = null;
    _changed();
  }

  Future<void> begin() async {
    final uid = currentUid();
    if (uid == null) {
      _fail(
        'sign_in_required',
        'Sign in to use voice. Guest browsing remains available.',
      );
      return;
    }
    if ([
      VoicePhase.initializing,
      VoicePhase.listening,
      VoicePhase.transcribing,
      VoicePhase.processing,
    ].contains(phase)) {
      return;
    }
    if (needsSave) {
      _fail(
        'save_pending',
        'Save the previous turn before starting another. Retry saving does not ask AI again.',
      );
      return;
    }
    if (output is PreparedSpeechOutput) {
      // Prepare only the engine, without playback/focus. A failure remains
      // visible if actual playback is later requested; no AI request is retried.
      unawaited(
        (output as PreparedSpeechOutput).prepare().catchError((Object _) {}),
      );
    }
    // A deliberate new turn may interrupt playback; it never overlaps STT/TTS.
    pause();
    final generation = ++_generation;
    _turnDone = Completer<void>();
    _clock
      ..reset()
      ..start();
    _firstDelta = false;
    _activeRequestId = null;
    _trace('initializing');
    _manualFinish = false;
    _confidence = null;
    error = null;
    errorCode = null;
    notice = null;
    phase = VoicePhase.initializing;
    _changed();
    try {
      await _cleanup;
      if (!_valid(generation, uid)) return;
      final ready = await _acquire(generation, uid);
      if (!_valid(generation, uid)) return;
      if (!ready) throw const SpeechInputFailure('permission_denied');
      transcript = '';
      _trace('listening');
      phase = VoicePhase.listening;
      _changed();
      _listenTimer = Timer(const Duration(seconds: 65), () {
        if (_valid(generation, uid) && phase == VoicePhase.listening) {
          unawaited(finishListening());
        }
      });
      await speech.listen(
        this,
        locale: locale,
        onResult: (result) {
          if (!_valid(generation, uid) ||
              ![
                VoicePhase.listening,
                VoicePhase.transcribing,
              ].contains(phase)) {
            return;
          }
          transcript = result.words;
          _confidence = result.confidence;
          _changed();
          if (result.isFinal) unawaited(_submit(generation, uid));
        },
      );
    } catch (e) {
      if (_valid(generation, uid)) _inputFailure(e);
    }
  }

  void _awaitFinal(int generation, String uid) {
    if (_finalTimer?.isActive == true) return;
    // The plugin itself waits up to two seconds for Android's final result.
    _finalTimer = Timer(const Duration(seconds: 3), () {
      if (!_valid(generation, uid) || phase != VoicePhase.transcribing) return;
      if (_manualFinish && transcript.trim().isNotEmpty) {
        unawaited(_submit(generation, uid));
      } else {
        _fail(
          transcript.trim().isEmpty ? 'no_speech' : 'final_missing',
          transcript.trim().isEmpty
              ? 'No speech detected. Tap Start talking when you are ready.'
              : 'No final transcript arrived. Check your words before sending.',
        );
      }
    });
  }

  Future<void> finishListening() async {
    if (phase != VoicePhase.listening) return;
    final uid = currentUid();
    if (uid == null) {
      pause();
      return;
    }
    final generation = _generation;
    final done = _turnDone;
    _manualFinish = true;
    phase = VoicePhase.transcribing;
    _changed();
    _awaitFinal(generation, uid);
    try {
      await speech.finish(this);
    } catch (e) {
      if (_valid(generation, uid)) _inputFailure(e);
    }
    if (done != null) await done.future;
  }

  Future<void> confirmTranscript() async {
    if (!canConfirmTranscript || currentUid() == null) return;
    final generation = ++_generation;
    final uid = currentUid()!;
    _confidence = null;
    error = null;
    errorCode = null;
    _turnDone = Completer<void>();
    phase = VoicePhase.transcribing;
    await _submit(generation, uid);
  }

  Future<void> _submit(int generation, String uid) async {
    if (!_valid(generation, uid) ||
        ![VoicePhase.listening, VoicePhase.transcribing].contains(phase)) {
      return;
    }
    final text = transcript.trim();
    if (text.isEmpty) {
      _fail(
        'no_speech',
        'No speech detected. Tap Start talking when you are ready.',
      );
      return;
    }
    if (_confidence != null && _confidence! >= 0 && _confidence! < .4) {
      _fail(
        'low_confidence',
        'I’m not sure I heard correctly. Check your words before sending.',
      );
      return;
    }
    if (text.runes.length > 12000) {
      _fail(
        'transcript_too_long',
        'That turn is too long. Try a shorter question.',
      );
      return;
    }
    _finalTimer?.cancel();
    _listenTimer?.cancel();
    _trace('final_transcript', characters: text.runes.length);
    phase = VoicePhase.processing;
    _trace('processing');
    _changed(); // Claim submission before any await.
    try {
      await speech.release(this);
      if (!_valid(generation, uid)) return;
      chat.setDraft(text);
      await chat.send();
      if (_valid(generation, uid)) await _afterReply(generation, uid);
    } catch (_) {
      if (_valid(generation, uid)) {
        _fail(
          'voice_request',
          'Could not complete this turn. Check your connection and retry.',
        );
      }
    }
  }

  Future<void> retry({bool continuing = false}) async {
    if (active || !chat.canRetry || currentUid() == null) return;
    final uid = currentUid()!;
    final generation = ++_generation;
    _clock
      ..reset()
      ..start();
    _firstDelta = false;
    _activeRequestId = null;
    _trace('retry_started');
    error = null;
    errorCode = null;
    notice = null;
    phase = VoicePhase.processing;
    _changed();
    if (continuing) {
      await chat.continueResponse();
    } else {
      await chat.retry();
    }
    if (_valid(generation, uid)) await _afterReply(generation, uid);
  }

  Future<void> replay() async {
    if (!canReplay || currentUid() == null) return;
    final uid = currentUid()!;
    final generation = ++_generation;
    _clock
      ..reset()
      ..start();
    _trace('replay_started');
    error = null;
    errorCode = null;
    _spokenMessageId = null;
    phase = VoicePhase.processing;
    _changed();
    await _afterReply(generation, uid);
  }

  Future<void> _afterReply(int generation, String uid) async {
    final messages = chat.conversation.messages;
    final reply =
        messages.isNotEmpty && messages.last.role == 'bot'
            ? messages.last
            : null;
    _activeRequestId = reply?.requestId;
    if (reply == null || reply.state != ReplyState.complete) {
      _fail(
        reply?.failureCode ?? 'incomplete_response',
        chat.conversation.error ??
            'Response interrupted. The partial answer stays in your transcript.',
      );
      return;
    }
    notice =
        reply.saved
            ? null
            : 'Your answer is complete, but not saved. Retry saving before leaving.';
    if (_spokenMessageId == reply.id) {
      phase = VoicePhase.idle;
      _finishTurn();
      _changed();
      return;
    }
    _trace('reply_ready', characters: reply.text.runes.length);
    final spokenText = speechText(reply.text);
    if (spokenText.isEmpty) {
      phase = VoicePhase.idle;
      _finishTurn();
      _changed();
      return;
    }
    try {
      await output.speak(
        this,
        spokenText,
        locale: locale,
        onStart: () {
          if (!_valid(generation, uid)) return;
          _spokenMessageId = reply.id;
          _trace('speaking');
          phase = VoicePhase.speaking;
          _changed();
        },
      );
      if (_valid(generation, uid)) {
        _trace('ready');
        phase = VoicePhase.idle;
        _finishTurn();
        _changed();
      }
    } catch (e) {
      if (!_valid(generation, uid)) return;
      final code = e is SpeechOutputFailure ? e.code : 'playback_failed';
      _fail(code, switch (code) {
        'voice_unavailable' =>
          'No suitable speech voice is available. Install a voice in Android speech settings. Your answer remains in the transcript.',
        'audio_focus' || 'playback_interrupted' =>
          'Playback was interrupted by Android. Your answer is still here; tap Read again when ready.',
        _ =>
          'Your answer is here, but could not be read aloud. Check Android speech settings or tap Read again.',
      });
    }
  }

  static String speechText(String raw) => speechFriendlyText(raw);
  void pause({bool deliberate = true, String reason = 'user'}) {
    if (active && deliberate) _trace('stopped', category: reason);
    _generation++;
    _finishTurn();
    final release = speech.release(this);
    final stop = output.stop(this);
    final generation = _generation;
    _cleanup = Future.wait([release, stop]).then<void>((_) {});
    unawaited(
      _cleanup.catchError((Object _) {
        if (!_disposed && generation == _generation) {
          errorCode = 'playback_failed';
          error =
              'Audio could not be released. Check Android speech settings before trying again.';
          phase = VoicePhase.error;
          _changed();
        }
      }),
    );
    chat.stop();
    phase = VoicePhase.paused;
    _changed();
  }

  void reset() {
    pause();
    chat.newConversation();
    transcript = '';
    error = null;
    errorCode = null;
    notice = null;
    _spokenMessageId = null;
    phase = VoicePhase.idle;
    _changed();
  }

  void sessionChanged() {
    pause(reason: 'account_changed');
    chat.sessionChanged();
    transcript = '';
    error = null;
    errorCode = null;
    notice = null;
    _spokenMessageId = null;
    phase = VoicePhase.idle;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    chat.removeListener(_chatChanged);
    chat.streamingText.removeListener(_streamChanged);
    super.dispose();
  }
}
