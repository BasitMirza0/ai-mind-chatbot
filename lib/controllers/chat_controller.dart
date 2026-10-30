import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/conversation.dart';
import '../services/ai_service.dart';
import '../services/chat_diagnostics.dart';
import '../services/backend_api_config.dart';
import '../services/conversation_repository.dart';

/// Owns one request at a time. Cached conversations retain drafts and unsaved
/// work while switching. Generation + owner guards reject every stale callback.
class ChatController extends ChangeNotifier {
  final AiService ai;
  final ConversationRepository repository;
  final String? Function() currentUid;
  final String? systemPrompt;
  final String conversationType;
  final Map<String, Conversation> _cache = {};
  late Conversation conversation;
  String? _owner;
  bool _disposed = false;
  int _generation = 0;
  StreamSubscription<String>? _subscription;
  Completer<void>? _streamDone;
  bool busy = false;
  bool loading = false;
  bool saving = false;
  String? loadError;
  String? failedLoadId;
  // Stream chunks update only the active reply widget.
  final ValueNotifier<String> streamingText = ValueNotifier('');
  ChatController({
    required this.ai,
    required this.repository,
    required this.currentUid,
    this.systemPrompt,
    this.conversationType = 'chat',
  }) {
    _owner = currentUid();
    conversation = Conversation(repository.newId());
    _cache[conversation.id] = conversation;
  }
  List<Conversation> get localConversations =>
      _cache.values
          .where(
            (c) =>
                c.messages.isNotEmpty ||
                c.draft.isNotEmpty ||
                c.attachment != null,
          )
          .toList()
          .reversed
          .toList();
  bool get hasUnsaved => _cache.values.any((c) => c.hasUnsaved);
  bool _valid(int generation, String uid) =>
      !_disposed &&
      generation == _generation &&
      currentUid() == uid &&
      _owner == uid;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void sessionChanged() {
    if (_owner == currentUid()) return;
    final guestDraft = _owner == null ? conversation.draft : '';
    final guestAttachment = _owner == null ? conversation.attachment : null;
    stop();
    _owner = currentUid();
    _cache.clear();
    conversation =
        Conversation(repository.newId())
          ..draft = guestDraft
          ..attachment = guestAttachment;
    _cache[conversation.id] = conversation;
    loadError = null;
    failedLoadId = null;
    loading = false;
    _emit();
  }

  void setDraft(String value) {
    conversation.draft = value;
  }

  void attach(Uint8List? bytes) {
    conversation.attachment = bytes;
    _emit();
  }

  void stop({bool notify = true}) {
    _generation++;
    ai.cancelPendingRequests();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (_streamDone?.isCompleted == false) _streamDone!.complete();
    _streamDone = null;
    if (busy) {
      for (final m in conversation.messages) {
        if (m.state == ReplyState.streaming) m.state = ReplyState.stopped;
      }
      conversation.notice =
          'Stopped. Incomplete replies stay on this screen and are not saved.';
    }
    busy = false;
    saving = false;
    loading = false;
    streamingText.value = '';
    if (notify) _emit();
  }

  void renameLocal(String id, String title) {
    _cache[id]?.title = title;
    _emit();
  }

  void forget(String id) {
    _cache.remove(id);
    if (conversation.id == id) newConversation();
    _emit();
  }

  void newConversation() {
    stop();
    conversation = Conversation(repository.newId());
    _cache[conversation.id] = conversation;
    loadError = null;
    failedLoadId = null;
    _emit();
  }

  Future<void> open(String id) async {
    stop();
    final uid = currentUid();
    if (uid == null) return;
    final generation = _generation;
    loadError = null;
    failedLoadId = null;
    if (_cache.containsKey(id)) {
      conversation = _cache[id]!;
      _emit();
      return;
    }
    loading = true;
    _emit();
    try {
      final loaded = await Future.wait<Object?>([
        repository.load(uid, id),
        repository.summary(uid, id),
      ]);
      if (!_valid(generation, uid)) return;
      final messages = loaded[0] as List<ChatMessage>;
      final summary = loaded[1] as ConversationSummary?;
      conversation = Conversation(
        id,
        created: true,
        messages: messages,
        title:
            summary?.title ??
            (messages.isEmpty ? 'Conversation' : _title(messages.first.text)),
      );
      _cache[id] = conversation;
    } catch (_) {
      if (_valid(generation, uid)) {
        loadError =
            'Could not load this conversation. Check your connection and retry.';
        failedLoadId = id;
      }
    } finally {
      if (_valid(generation, uid)) {
        loading = false;
        _emit();
      }
    }
  }

  String _title(String text) => String.fromCharCodes(text.runes.take(60));
  Future<void> send() async {
    if (busy || loading || saving || currentUid() == null) return;
    final text = conversation.draft.trim();
    final image = conversation.attachment;
    if (text.isEmpty && image == null) return;
    if (text.runes.length > 12000) {
      conversation.error = 'Keep your message within 12,000 characters.';
      _emit();
      return;
    }
    // Resolve the previous unsaved turn before accepting another one.
    if (conversation.messages.any(
      (m) => !m.saved && m.state == ReplyState.complete,
    )) {
      conversation.error =
          'Save or retry the previous message before sending another.';
      _emit();
      return;
    }
    final message = ChatMessage(
      id: repository.newId(),
      role: 'user',
      text: text.isEmpty ? 'Describe this image' : text,
      image: image,
    );
    conversation.messages.add(message);
    if (!conversation.created) conversation.title = _title(message.text);
    conversation.draft = '';
    conversation.attachment = null;
    await _generate(message);
  }

  ChatMessage? get lastUser {
    for (final m in conversation.messages.reversed) {
      if (m.role == 'user') return m;
    }
    return null;
  }

  bool get canRetry {
    if (busy || loading || saving || currentUid() == null || lastUser == null) {
      return false;
    }
    final tail = conversation.messages.skip(
      conversation.messages.indexOf(lastUser!) + 1,
    );
    return tail.isEmpty || tail.any((m) => !m.saved);
  }

  Future<void> retry() async {
    if (busy || loading || saving || currentUid() == null || lastUser == null) {
      return;
    }
    final user = lastUser!;
    // A completed but unsaved reply is retried as a write, never billed again.
    if (conversation.messages.any(
      (m) => m.role == 'bot' && m.state == ReplyState.complete && !m.saved,
    )) {
      await savePending();
      return;
    }
    final userIndex = conversation.messages.indexOf(user);
    final tail = conversation.messages.skip(userIndex + 1).toList();
    if (tail.any((m) => m.state == ReplyState.complete && m.saved)) return;
    final partials = tail.where(
      (m) => m.role == 'bot' && m.state != ReplyState.complete,
    );
    final partial = partials.isEmpty ? null : partials.last;
    if (partial != null && partial.text.isNotEmpty) {
      partial.previousAttempts.add(partial.text);
      partial.text = '';
    }
    await _generate(user, target: partial);
  }

  bool get canContinue =>
      canRetry &&
      conversation.messages.last.role == 'bot' &&
      conversation.messages.last.state == ReplyState.truncated &&
      conversation.messages.last.text.isNotEmpty &&
      lastUser?.image == null;

  Future<void> continueResponse() async {
    if (!canContinue) return;
    await _generate(
      lastUser!,
      target: conversation.messages.last,
      continuing: true,
    );
  }

  Future<void> regenerate() async {
    if (busy ||
        loading ||
        saving ||
        lastUser == null ||
        conversation.hasUnsaved) {
      return;
    }
    // Immutable history: append a new turn, preserving the original answer.
    conversation.draft = lastUser!.text;
    conversation.attachment = lastUser!.image;
    await send();
  }

  Future<void> _generate(
    ChatMessage user, {
    ChatMessage? target,
    bool continuing = false,
  }) async {
    final uid = currentUid();
    if (uid == null) return;
    final c = conversation;
    final generation = ++_generation;
    busy = true;
    c.error = null;
    c.notice = null;
    final bot =
        target ??
        ChatMessage(
          id: repository.newId(),
          role: 'bot',
          text: '',
          state: ReplyState.streaming,
        );
    bot.state = ReplyState.streaming;
    bot.failureCode = null;
    if (target == null) c.messages.add(bot);
    final partialPrefix = continuing ? bot.text : '';
    streamingText.value = bot.text;
    final diagnostics =
        ai is AiStreamDiagnostics ? ai as AiStreamDiagnostics : null;
    void traceChanged() {
      if (!_valid(generation, uid)) return;
      final trace = diagnostics!.streamTrace.value;
      if (trace.requestId != null) bot.requestId = trace.requestId;
    }

    diagnostics?.streamTrace.addListener(traceChanged);
    var stage = 'firestore';
    _emit();
    try {
      if (!c.created) {
        await repository.create(uid, c.id, c.title, type: conversationType);
        if (!_valid(generation, uid)) return;
        c.created = true;
      }
      if (!user.saved) {
        await repository.save(uid, c.id, user);
        // Even after Stop, this captured write may already have committed.
        // Stable IDs make a later retry safe; never touch another thread.
        if (_disposed || currentUid() != uid) return;
        user.saved = true;
        if (!_valid(generation, uid)) return;
      }
      final eligible =
          c.messages
              .where(
                (m) =>
                    m != bot &&
                    (m.role == 'user' || m.state == ReplyState.complete) &&
                    m.text.isNotEmpty,
              )
              .toList();
      final recent = <ChatMessage>[];
      var characters = 0;
      for (final m in eligible.reversed) {
        final length = m.text.runes.length;
        if (recent.length == 64 ||
            length > 12000 ||
            characters + length > 48000) {
          break;
        }
        recent.add(m);
        characters += length;
      }
      c.contextNotice =
          recent.length < eligible.length
              ? 'Using recent messages for this reply. Your full saved conversation stays in history.'
              : null;
      final history = recent.reversed.map((m) => m.api).toList();
      if (continuing) {
        // These are request-only context turns. No invented user message is
        // persisted, and the partial source itself is never edited or deduped.
        final runes = partialPrefix.runes.toList();
        final tail =
            runes.length > 36000 ? runes.sublist(runes.length - 36000) : runes;
        final context = <Map<String, dynamic>>[];
        for (var i = 0; i < tail.length; i += 12000) {
          context.add({
            'role': 'bot',
            'text': String.fromCharCodes(tail.skip(i).take(12000)),
          });
        }
        context.add({
          'role': 'user',
          'text':
              'Continue the interrupted answer exactly from where it ended. Do not repeat the existing text or add an introduction. If a code fence is open, continue inside it.',
        });
        var budget = context.fold<int>(
          0,
          (n, m) => n + (m['text'] as String).runes.length,
        );
        while (history.isNotEmpty &&
            (history.length + context.length > 64 ||
                budget +
                        history.fold<int>(
                          0,
                          (n, m) => n + (m['text'] as String).runes.length,
                        ) >
                    48000)) {
          history.removeAt(0);
        }
        history.addAll(context);
        if (runes.length > 36000) {
          c.contextNotice =
              'Continuing from the end of this long response. The full text stays here.';
        }
      }
      stage = 'generation';
      if (user.image != null) {
        final text = await ai.analyzeImage(user.image!, user.text, history);
        if (!_valid(generation, uid)) return;
        bot.text = text;
      } else {
        final done = Completer<void>();
        _streamDone = done;
        _subscription = ai
            .streamMessage(history, systemPrompt: systemPrompt)
            .listen(
              (chunk) {
                if (!_valid(generation, uid)) return;
                bot.text += chunk;
                streamingText.value = bot.text;
              },
              onError: (Object error, StackTrace stack) {
                if (!done.isCompleted) done.completeError(error, stack);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        await done.future;
        if (!_valid(generation, uid)) return;
      }
      if (bot.text.trim().isEmpty) {
        throw const BackendApiException(
          'empty',
          'No response received. Please retry.',
        );
      }
      bot.state = ReplyState.complete;
      saving = true;
      stage = 'firestore';
      logChatTrace(
        ChatTrace(
          'save_started',
          requestId: bot.requestId,
          characters: bot.text.runes.length,
        ),
      );
      _emit();
      await repository.save(uid, c.id, bot);
      if (_disposed || currentUid() != uid) return;
      bot.saved = true;
      logChatTrace(
        ChatTrace(
          'save_succeeded',
          requestId: bot.requestId,
          characters: bot.text.runes.length,
        ),
      );
    } catch (error) {
      if (!_valid(generation, uid)) return;
      bot.failureCode =
          stage == 'firestore'
              ? 'firestore'
              : error is BackendApiException
              ? error.code
              : 'generation_failed';
      if (error is BackendApiException) {
        bot.requestId = error.requestId ?? bot.requestId;
      }
      if (bot.state != ReplyState.complete) {
        bot.state =
            bot.failureCode == 'response_limit'
                ? ReplyState.truncated
                : ReplyState.failed;
      }
      logChatTrace(
        ChatTrace(
          stage == 'firestore' ? 'save_failed' : 'reply_interrupted',
          requestId: bot.requestId,
          category: bot.failureCode,
          characters: bot.text.runes.length,
        ),
      );
      c.error =
          bot.state == ReplyState.complete
              ? 'Your reply is here, but could not be saved. Retry saving before leaving.'
              : error is BackendApiException
              ? error.message
              : stage == 'firestore'
              ? 'Could not save your message. Check your connection and retry.'
              : 'Response interrupted. Check your connection and retry.';
    } finally {
      diagnostics?.streamTrace.removeListener(traceChanged);
      if (_valid(generation, uid)) {
        _subscription = null;
        _streamDone = null;
        busy = false;
        saving = false;
        streamingText.value = '';
        _emit();
      }
    }
  }

  Future<void> savePending() async {
    final uid = currentUid();
    if (uid == null || busy || saving || loading) return;
    final c = conversation;
    final generation = ++_generation;
    saving = true;
    c.error = null;
    _emit();
    try {
      if (!c.created) {
        await repository.create(uid, c.id, c.title, type: conversationType);
      }
      if (!_valid(generation, uid)) return;
      c.created = true;
      for (final m in c.messages.where(
        (m) => !m.saved && m.state == ReplyState.complete,
      )) {
        logChatTrace(
          ChatTrace(
            'save_started',
            requestId: m.requestId,
            characters: m.text.runes.length,
          ),
        );
        await repository.save(uid, c.id, m);
        if (!_valid(generation, uid)) return;
        m.saved = true;
        logChatTrace(
          ChatTrace(
            'save_succeeded',
            requestId: m.requestId,
            characters: m.text.runes.length,
          ),
        );
      }
    } catch (_) {
      logChatTrace(const ChatTrace('save_failed', category: 'firestore'));
      if (_valid(generation, uid)) {
        c.error =
            'Still unable to save. Your work remains here; check your connection.';
      }
    } finally {
      if (_valid(generation, uid)) {
        saving = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop(notify: false);
    streamingText.dispose();
    super.dispose();
  }
}
