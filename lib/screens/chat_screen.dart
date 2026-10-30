import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/speech_coordinator.dart';
import '../controllers/chat_controller.dart';
import '../controllers/sidebar_controller.dart';
import '../services/sidebar_history_source.dart';
import '../widgets/chat_sidebar.dart';
import '../models/conversation.dart';
import '../services/app_session.dart';
import '../services/backend_ai_service.dart';
import '../services/conversation_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/chat_message_card.dart';
import '../widgets/chat_design.dart';
import '../widgets/conversation_components.dart';
import '../widgets/entry_components.dart';
import 'login_screen.dart';

class ChatScreen extends StatefulWidget {
  final String? presetPrompt, loadChatId;
  final AppSession? session;
  final ConversationRepository? repository;
  final ChatController? controller;
  final SidebarHistorySource? sidebarSource;
  final WidgetBuilder? loginBuilder;
  const ChatScreen({
    super.key,
    this.presetPrompt,
    this.loadChatId,
    this.session,
    this.repository,
    this.controller,
    this.loginBuilder,
    this.sidebarSource,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final AppSession _session;
  late final ConversationRepository _repository;
  late final ChatController _chat;
  late final SidebarController _sidebar;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();
  final _speech = SpeechCoordinator.shared;
  bool _listening = false, _speechStarting = false, _picking = false;
  bool _allowPop = false;
  int _speechGeneration = 0;
  String? _uid;
  String? _visibleId;
  void _closeHistory() {
    FocusManager.instance.primaryFocus?.unfocus();
    _scaffold.currentState?.closeDrawer();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.session ?? FirebaseAppSession();
    _repository =
        widget.repository ??
        widget.controller?.repository ??
        FirebaseConversationRepository(_session);
    _chat =
        widget.controller ??
        ChatController(
          ai: BackendAiService(),
          repository: _repository,
          currentUid: () => _session.uid,
        );
    _uid = _session.uid;
    _sidebar = SidebarController(
      widget.sidebarSource ?? _repository as SidebarHistorySource,
      _uid,
    );
    _session.addListener(_sessionChanged);
    _chat.addListener(_changed);
    _chat.streamingText.addListener(_streamChanged);
    _input.addListener(() => _chat.setDraft(_input.text));
    if (widget.presetPrompt != null) _chat.setDraft(widget.presetPrompt!);
    _syncDraft();
    if (widget.loadChatId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chat.open(widget.loadChatId!);
      });
    }
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (_uid != _session.uid) {
      _uid = _session.uid;
      unawaited(_stopSpeech());
      _chat.sessionChanged();
      _sidebar.changeUser(_uid);
    }
    setState(() {});
  }

  void _syncDraft() {
    if (_input.text != _chat.conversation.draft) {
      _input.value = TextEditingValue(
        text: _chat.conversation.draft,
        selection: TextSelection.collapsed(
          offset: _chat.conversation.draft.length,
        ),
      );
    }
  }

  void _changed() {
    if (!mounted) return;
    final changedThread = _visibleId != _chat.conversation.id;
    _visibleId = _chat.conversation.id;
    _syncDraft();
    setState(() {});
    _scrollBottom(force: changedThread);
  }

  void _streamChanged() => _scrollBottom();
  bool _scrollScheduled = false;
  bool _followingOutput = true;
  void _scrollBottom({bool force = false}) {
    if (force) _followingOutput = true;
    if (_scrollScheduled || !mounted || !_followingOutput) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted ||
          !_scroll.hasClients ||
          !_followingOutput ||
          _scroll.position.isScrollingNotifier.value) {
        return;
      }
      if ((_scroll.position.maxScrollExtent - _scroll.offset).abs() > .5) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  bool _onChatScroll(ScrollNotification notification) {
    // Code/table horizontal scrolling must never change vertical follow intent.
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _followingOutput = notification.metrics.extentAfter <= 100;
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stopSpeech());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_sessionChanged);
    _chat.removeListener(_changed);
    _chat.streamingText.removeListener(_streamChanged);
    _chat.stop(notify: false);
    if (widget.controller == null) _chat.dispose();
    if (widget.session == null) _session.dispose();
    unawaited(_speech.release(this).catchError((_) {}));
    _sidebar.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _login() async {
    await Navigator.of(context).push(
      mindRoute(
        context,
        widget.loginBuilder?.call(context) ?? const LoginScreen(),
      ),
    );
    if (mounted) _sessionChanged();
  }

  Future<void> _send() async {
    if (_session.uid == null) {
      await _login();
      return;
    }
    if (_chat.busy || _chat.loading || _chat.saving || _picking) return;
    // Start the controller synchronously so repeated taps cannot race speech.stop.
    unawaited(_stopSpeech());
    unawaited(_chat.send());
    _scrollBottom(force: true);
  }

  Future<void> _stopSpeech() async {
    _speechGeneration++;
    if (!_listening && !_speechStarting) return;
    _listening = false;
    try {
      await _speech.release(this);
    } catch (_) {
      /* Device plugin may be unavailable. */
    }
    if (mounted) setState(() {});
  }

  Future<void> _voiceInput() async {
    if (_listening) {
      await _stopSpeech();
      return;
    }
    if (_speechStarting || _chat.busy || _chat.loading) return;
    if (_session.uid == null) {
      await _login();
      return;
    }
    final id = _chat.conversation.id;
    final uid = _session.uid;
    final generation = ++_speechGeneration;
    bool valid() =>
        mounted &&
        generation == _speechGeneration &&
        _chat.conversation.id == id &&
        _session.uid == uid &&
        !_chat.busy;
    setState(() => _speechStarting = true);
    try {
      final ready = await _speech.acquire(
        this,
        onLost: () {
          _speechGeneration++;
          if (mounted) setState(() => _listening = false);
        },
        onError: (_) {
          if (mounted) {
            setState(() => _listening = false);
            _snack('Voice input stopped. Check microphone permissions.');
          }
        },
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => _listening = false);
          }
        },
      );
      if (!valid()) {
        await _speech.release(this);
        return;
      }
      if (!ready) {
        await _speech.release(this);
        _snack('Voice input is unavailable. Check microphone permissions.');
        return;
      }
      setState(() => _listening = true);
      await _speech.listen(
        this,
        onResult: (result) {
          if (valid() && _listening) {
            _input.value = TextEditingValue(
              text: result.words,
              selection: TextSelection.collapsed(offset: result.words.length),
            );
          }
        },
      );
    } catch (_) {
      if (mounted) {
        _listening = false;
        _snack('Voice input is unavailable on this device.');
      }
    } finally {
      if (mounted) setState(() => _speechStarting = false);
    }
  }

  Future<void> _pick(BuildContext ctx) async {
    if (_picking || _chat.busy || _chat.loading) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: ctx,
      builder:
          (sheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Ask about an image', style: AppTypography.title),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_outlined),
                  title: const Text('Choose a photo'),
                  onTap: () => Navigator.pop(sheet, ImageSource.gallery),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(sheet, ImageSource.camera),
                ),
              ],
            ),
          ),
    );
    if (source == null || !mounted) return;
    final id = _chat.conversation.id;
    final uid = _session.uid;
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null) return;
      if (await file.length() > 5000000) {
        _snack('Choose an image smaller than 5 MB.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (mounted && _chat.conversation.id == id && _session.uid == uid) {
        _chat.attach(bytes);
      }
    } catch (_) {
      _snack('Could not access the image. Check photo or camera permissions.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _leave(BuildContext ctx) async {
    if (_chat.busy || _chat.saving || _chat.hasUnsaved) {
      final leave = await showDialog<bool>(
        context: ctx,
        builder:
            (dialog) => AlertDialog(
              title: const Text('Leave this chat?'),
              content: const Text(
                'Saved messages stay in history. Drafts, attachments and unsaved replies will be lost when you leave. Any active response will stop.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep chatting'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Leave'),
                ),
              ],
            ),
      );
      if (leave != true || !mounted) return;
    }
    _chat.stop();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _new() {
    unawaited(_stopSpeech());
    _chat.newConversation();
  }

  void _open(String id) {
    unawaited(_stopSpeech());
    _chat.open(id);
  }

  Future<void> _options(BuildContext ctx, ConversationSummary summary) async {
    final uid = _session.uid;
    if (uid == null) return;
    final action = await showModalBottomSheet<String>(
      context: ctx,
      builder:
          (sheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Rename'),
                  onTap: () => Navigator.pop(sheet, 'rename'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Delete'),
                  onTap: () => Navigator.pop(sheet, 'delete'),
                ),
              ],
            ),
          ),
    );
    if (!ctx.mounted || uid != _session.uid || action == null) return;
    // Avoid deleting or renaming a conversation while writes target it.
    if (_chat.busy || _chat.saving) {
      _snack('Stop the response and finish saving before changing history.');
      return;
    }
    try {
      if (action == 'delete') {
        if (!await confirmConversationDelete(ctx, summary.title) ||
            !mounted ||
            _session.uid != uid) {
          return;
        }
        await _repository.delete(uid, summary.id);
        if (mounted && _session.uid == uid) {
          _chat.forget(summary.id);
          _sidebar.refresh();
        }
      } else {
        String title = summary.title;
        final result = await showDialog<String>(
          context: ctx,
          builder:
              (dialog) => AlertDialog(
                title: const Text('Rename conversation'),
                content: TextFormField(
                  initialValue: title,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Conversation name',
                  ),
                  onChanged: (value) => title = value,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      if (title.trim().isNotEmpty) {
                        Navigator.pop(dialog, title.trim());
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
        );
        if (result != null && mounted && _session.uid == uid) {
          await _repository.rename(uid, summary.id, result);
          if (mounted && _session.uid == uid) {
            _chat.renameLocal(summary.id, result);
            _sidebar.refresh();
          }
        }
      }
    } catch (_) {
      _snack(
        'Could not update the conversation. Check your connection and retry.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => MindPage(
    builder:
        (ctx) => PopScope(
          canPop: _allowPop,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_scaffold.currentState?.isDrawerOpen == true) {
              _scaffold.currentState!.closeDrawer();
            } else {
              _leave(ctx);
            }
          },
          child: Scaffold(
            key: _scaffold,
            resizeToAvoidBottomInset: false,
            drawerEnableOpenDragGesture: true,
            drawerEdgeDragWidth: 24,
            drawerScrimColor: AppColors.ink.withValues(alpha: .32),
            onDrawerChanged: (open) {
              if (!open) FocusManager.instance.primaryFocus?.unfocus();
            },
            drawer: ChatSidebar(
              history: _sidebar,
              chat: _chat,
              session: _session,
              onClose: _closeHistory,
              onNew: () {
                _closeHistory();
                _new();
              },
              onOpen: (id) {
                _closeHistory();
                _open(id);
              },
              onOptions: (summary) => _options(ctx, summary),
              onLogin: () {
                _closeHistory();
                _login();
              },
              onSignOut: _signOut,
            ),
            body: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: MediaQuery.removeViewInsets(
                context: ctx,
                removeBottom: true,
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final keyboard =
                          MediaQuery.viewInsetsOf(context).bottom > 0;
                      final compact = keyboard && box.maxHeight < 300;
                      return Column(
                        children: [
                          if (!compact)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    key: const Key('chat-menu'),
                                    tooltip: 'Open conversation menu',
                                    onPressed: () {
                                      _focus.unfocus();
                                      _scaffold.currentState!.openDrawer();
                                    },
                                    icon: const Icon(Icons.menu_rounded),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'AI Mind',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTypography.title.copyWith(
                                            fontSize: 20,
                                          ),
                                        ),
                                        if (box.maxHeight >= 300)
                                          Text(
                                            _chat.conversation.messages.isEmpty
                                                ? 'Room for your thoughts'
                                                : 'Your conversation',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppTypography.caption,
                                          ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'New chat',
                                    onPressed: _new,
                                    icon: const Icon(Icons.edit_square),
                                  ),
                                  IconButton(
                                    tooltip: 'Back to previous screen',
                                    onPressed: () => _leave(ctx),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                                ],
                              ),
                            ),
                          const Divider(height: 1, color: AppColors.outline),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: AppSpacing.contentWidth,
                                ),
                                child: _body(ctx),
                              ),
                            ),
                          ),
                          _composer(
                            ctx,
                            keyboardOpen: keyboard,
                            compact: compact,
                            lines:
                                compact
                                    ? 1
                                    : keyboard
                                    ? 3
                                    : 4,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
  );
  Widget _body(BuildContext ctx) {
    if (_chat.loading) {
      return const Center(
        child: EntryLoadingIndicator(label: 'Loading conversation'),
      );
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _scrollBottom();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onChatScroll,
        child: ListView(
          key: const Key('chat-message-list'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(
            ChatDesign.gutter,
            18,
            ChatDesign.gutter,
            8,
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (_chat.loadError != null)
              MindStatus(
                title: _chat.loadError!,
                error: true,
                action: 'Retry loading',
                onAction: () => _chat.open(_chat.failedLoadId!),
              ),
            if (_chat.conversation.messages.isEmpty) _welcome(ctx),
            for (final message in _chat.conversation.messages)
              ChatMessageCard(
                key: ValueKey(message.id),
                message: message,
                streamingText:
                    message.state == ReplyState.streaming
                        ? _chat.streamingText
                        : null,
                onContinue:
                    message == _chat.conversation.messages.last &&
                            _chat.canContinue
                        ? _chat.continueResponse
                        : null,
                onRetry:
                    message == _chat.conversation.messages.last &&
                            message.role == 'bot' &&
                            _chat.canRetry
                        ? _chat.retry
                        : null,
                onRegenerate:
                    message == _chat.conversation.messages.last &&
                            message.role == 'bot' &&
                            message.state == ReplyState.complete &&
                            message.saved &&
                            !_chat.busy &&
                            !_chat.saving &&
                            !_chat.conversation.hasUnsaved
                        ? () => _regenerate(ctx)
                        : null,
              ),
            if (_chat.conversation.contextNotice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _chat.conversation.contextNotice!,
                  style: AppTypography.caption,
                ),
              ),
            if (_chat.conversation.error != null &&
                (_chat.conversation.messages.isEmpty ||
                    _chat.conversation.messages.last.role == 'user'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _chat.conversation.error!,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.errorInk,
                  ),
                ),
              ),
            if (!_chat.busy &&
                !_chat.saving &&
                _chat.conversation.error == null &&
                _chat.conversation.notice == null &&
                _chat.conversation.messages.isNotEmpty &&
                _chat.conversation.messages.last.role == 'user')
              TextButton.icon(
                onPressed: _chat.retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry response'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _regenerate(BuildContext ctx) async {
    final yes = await showDialog<bool>(
      context: ctx,
      builder:
          (dialog) => AlertDialog(
            title: const Text('Try another response?'),
            content: const Text(
              'A new turn will be added. Your original answer stays in this conversation.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Regenerate'),
              ),
            ],
          ),
    );
    if (yes == true && mounted) _chat.regenerate();
  }

  Widget _welcome(BuildContext context) => MindEntrance(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Center(
          child: ExcludeSemantics(
            child: Image.asset(
              'assets/images/robot.png',
              height: 138,
              width: 138,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'What’s on\nyour mind?',
          style: AppTypography.headline.copyWith(fontSize: 36),
        ),
        const SizedBox(height: 12),
        const Text(
          'Start with a question, a rough idea, or a photo you’d like to understand.',
          style: AppTypography.body,
        ),
        const SizedBox(height: 22),
        for (final prompt in [
          'Help me shape an idea',
          'Explain something simply',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () {
                _input.text = prompt;
                _focus.requestFocus();
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                alignment: Alignment.centerLeft,
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.controlOutline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(prompt),
            ),
          ),
        if (_session.uid == null)
          TextButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.lock_outline_rounded, size: 18),
            label: const Text('Sign in to ask AI Mind'),
          ),
        const SizedBox(height: 16),
      ],
    ),
  );
  Widget _composer(
    BuildContext ctx, {
    required bool keyboardOpen,
    required bool compact,
    required int lines,
  }) => Container(
    key: const Key('chat-composer'),
    color: AppColors.canvas,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact && _chat.conversation.attachment != null)
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _chat.conversation.attachment!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        semanticLabel: 'Selected image',
                        errorBuilder:
                            (_, __, ___) => const Icon(Icons.image_outlined),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Image ready to analyze',
                        style: AppTypography.caption,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove image',
                      onPressed: () => _chat.attach(null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              if (!compact && _listening)
                Semantics(
                  liveRegion: true,
                  child: const Text(
                    'Listening… Tap the microphone to stop.',
                    style: AppTypography.caption,
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.paper,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: AppColors.controlOutline),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip:
                            compact && _chat.conversation.attachment != null
                                ? 'Remove image'
                                : 'Attach image for analysis',
                        onPressed:
                            _chat.busy || _chat.loading || _picking
                                ? null
                                : compact &&
                                    _chat.conversation.attachment != null
                                ? () => _chat.attach(null)
                                : () => _pick(ctx),
                        icon:
                            _picking
                                ? const EntryLoadingIndicator(
                                  label: 'Opening photo',
                                )
                                : Icon(
                                  compact &&
                                          _chat.conversation.attachment != null
                                      ? Icons.image_not_supported_outlined
                                      : Icons.add_rounded,
                                ),
                      ),
                      Expanded(
                        child: Semantics(
                          label: 'Message AI Mind',
                          child: TextField(
                            key: const Key('chat-input'),
                            controller: _input,
                            focusNode: _focus,
                            enabled: !_chat.loading,
                            minLines: 1,
                            maxLines: lines,
                            maxLength: 12000,
                            textCapitalization: TextCapitalization.sentences,
                            style: AppTypography.body.copyWith(
                              color: AppColors.ink,
                              height: 1.45,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 13,
                              ),
                              hintText: 'Message…',
                              hintMaxLines: 1,
                              border: InputBorder.none,
                              counterText: '',
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip:
                            _listening ? 'Stop voice input' : 'Dictate message',
                        onPressed:
                            _chat.busy || _chat.loading || _speechStarting
                                ? null
                                : _voiceInput,
                        icon: Icon(
                          _listening
                              ? Icons.mic_rounded
                              : Icons.mic_none_rounded,
                          color: _listening ? AppColors.errorInk : null,
                        ),
                      ),
                      if (compact)
                        IconButton(
                          tooltip: 'Hide keyboard',
                          onPressed: _focus.unfocus,
                          icon: const Icon(Icons.keyboard_hide_rounded),
                        ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _input,
                        builder:
                            (_, value, __) => IconButton.filled(
                              tooltip:
                                  _chat.saving
                                      ? 'Saving conversation'
                                      : _chat.busy
                                      ? 'Stop generating'
                                      : _session.uid == null
                                      ? 'Sign in to send'
                                      : 'Send message',
                              onPressed:
                                  _chat.busy && !_chat.saving
                                      ? _chat.stop
                                      : _chat.busy ||
                                          _chat.saving ||
                                          _chat.loading ||
                                          _picking ||
                                          (value.text.trim().isEmpty &&
                                              _chat.conversation.attachment ==
                                                  null)
                                      ? null
                                      : _send,
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: AppColors.purple,
                                foregroundColor: AppColors.paper,
                                disabledBackgroundColor: AppColors.outline,
                              ),
                              icon: Icon(
                                _chat.saving
                                    ? Icons.more_horiz_rounded
                                    : _chat.busy
                                    ? Icons.stop_rounded
                                    : Icons.arrow_upward_rounded,
                              ),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!keyboardOpen && MediaQuery.sizeOf(ctx).height > 500)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'AI can make mistakes. Check important information.',
                    textAlign: TextAlign.center,
                    style: AppTypography.caption,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> _signOut() async {
    if (_chat.hasUnsaved || _chat.busy || _chat.saving) {
      _snack('Save your work or leave the chat before signing out.');
      return;
    }
    try {
      await _session.signOut();
    } catch (_) {
      _snack('Could not sign out. Please retry.');
    }
  }
}
