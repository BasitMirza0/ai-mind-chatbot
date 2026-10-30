import 'dart:async';
import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../controllers/voice_controller.dart';
import '../services/app_session.dart';
import '../services/backend_ai_service.dart';
import '../services/conversation_repository.dart';
import '../services/speech_coordinator.dart';
import '../services/speech_output.dart';
import '../services/voice_device_access.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/conversation_components.dart';
import '../widgets/voice_visualization.dart';
import 'login_screen.dart';

class VoiceScreen extends StatefulWidget {
  final AppSession? session;
  final ConversationRepository? repository;
  final VoiceController? controller;
  const VoiceScreen({
    super.key,
    this.session,
    this.repository,
    this.controller,
  });
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with WidgetsBindingObserver {
  late final AppSession _session = widget.session ?? FirebaseAppSession();
  late final ChatController _chat =
      widget.controller?.chat ??
      ChatController(
        ai: BackendAiService(),
        repository:
            widget.repository ?? FirebaseConversationRepository(_session),
        currentUid: () => _session.uid,
        conversationType: 'voice',
        systemPrompt: 'voice',
      ); // Server owns the actual voice prompt.
  late final VoiceController _voice =
      widget.controller ??
      VoiceController(
        chat: _chat,
        speech: SpeechCoordinator.shared,
        output: DeviceSpeechOutput.shared,
        currentUid: () => _session.uid,
      );
  String? _uid;
  bool _allowPop = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uid = _session.uid;
    _session.addListener(_identity);
    _voice.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _identity() {
    if (_uid != _session.uid) {
      _uid = _session.uid;
      _voice.sessionChanged();
    }
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A first-time permission dialog makes the activity inactive. A real
    // background/hidden transition still cancels even during initialization.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        (state == AppLifecycleState.inactive &&
            _voice.phase != VoicePhase.initializing)) {
      _voice.pause(reason: 'background');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_identity);
    _voice.removeListener(_changed);
    if (widget.controller == null) {
      _voice.dispose();
      _chat.dispose();
    } else {
      _voice.pause();
    }
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  String get _title => switch (_voice.phase) {
    VoicePhase.idle => 'Ready when you are',
    VoicePhase.listening => 'Listening…',
    VoicePhase.initializing => 'Getting ready…',
    VoicePhase.transcribing => 'Finishing your words…',
    VoicePhase.processing => 'Thinking…',
    VoicePhase.speaking => 'Speaking…',
    VoicePhase.paused => 'Response stopped',
    VoicePhase.error => 'Let’s try again',
  };
  static const _hints = {
    VoicePhase.idle: 'Tap the microphone and speak naturally.',
    VoicePhase.initializing:
        'Preparing your microphone. Allow access if Android asks.',
    VoicePhase.transcribing:
        'Waiting for the final transcript. You can still stop.',
    VoicePhase.listening:
        'Pause to finish your question, or tap Send when you’re ready.',
    VoicePhase.processing: 'You can stop the response at any time.',
    VoicePhase.speaking:
        'Tap Stop to end playback, or New turn to ask another question.',
    VoicePhase.paused: 'The microphone and spoken reply are stopped.',
  };
  String get _detail =>
      _voice.phase == VoicePhase.error
          ? _voice.error ?? 'Voice is unavailable right now.'
          : _hints[_voice.phase]!;

  // Reserve the same hint space across normal phases. A one-line Ready hint
  // changing to two-line Listening must not shift the whole centered orb.
  double _hintHeight(BuildContext context, double width) {
    var height = 0.0;
    for (final hint in _hints.values) {
      final painter = TextPainter(
        text: TextSpan(
          text: hint,
          style: AppTypography.body.copyWith(fontSize: 14, height: 1.5),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: (width - 48).clamp(1, double.infinity));
      if (painter.height > height) height = painter.height;
      painter.dispose();
    }
    return height;
  }

  Future<void> _mic() async {
    if (_session.uid == null) {
      await Navigator.of(context).push(mindRoute(context, const LoginScreen()));
      return;
    }
    switch (_voice.phase) {
      case VoicePhase.listening:
        await _voice.finishListening();
      case VoicePhase.initializing:
      case VoicePhase.transcribing:
      case VoicePhase.processing:
      case VoicePhase.speaking:
        _voice.pause();
      case VoicePhase.idle:
      case VoicePhase.paused:
      case VoicePhase.error:
        await _voice.begin();
    }
  }

  Future<void> _settings({bool output = false}) async {
    final recognition = _voice.errorCode == 'recognizer_unavailable';
    _voice.pause();
    try {
      final opened = await VoiceDeviceAccess.shared.openSettings(
        speechOutput: output,
        recognition: recognition,
      );
      if (!opened) throw StateError('Settings unavailable');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Open Android Settings to manage microphone permission or speech output.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _leave(BuildContext ctx) async {
    _voice.pause(reason: 'navigation');
    if (_chat.hasUnsaved) {
      final leave = await showDialog<bool>(
        context: ctx,
        builder:
            (dialog) => AlertDialog(
              title: const Text('Leave voice?'),
              content: const Text(
                'Saved messages remain in history. Unsaved replies will be lost.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Stay'),
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
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _languages(BuildContext ctx) async {
    await _voice.loadLanguages();
    if (!ctx.mounted || _voice.languages.isEmpty) return;
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      builder:
          (sheet) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheet).height * .65,
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Speech language', style: AppTypography.title),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        ListTile(
                          title: const Text('Device default'),
                          trailing:
                              _voice.locale == null
                                  ? const Icon(Icons.check_rounded)
                                  : null,
                          onTap: () {
                            _voice.setLanguage(null);
                            Navigator.pop(sheet);
                          },
                        ),
                        for (final language in _voice.languages)
                          ListTile(
                            title: Text(language.name),
                            subtitle: Text(language.id),
                            trailing:
                                _voice.locale == language.id
                                    ? const Icon(Icons.check_rounded)
                                    : null,
                            onTap: () {
                              _voice.setLanguage(language.id);
                              Navigator.pop(sheet);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _transcript(BuildContext ctx) async {
    _voice.pause(reason: 'transcript');
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      builder:
          (sheet) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheet).height * .75,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('Your conversation', style: AppTypography.title),
                  const SizedBox(height: 16),
                  if (_chat.conversation.messages.isEmpty)
                    const Text(
                      'Your words and replies will appear here.',
                      style: AppTypography.body,
                    ),
                  for (final message in _chat.conversation.messages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.role == 'user' ? 'You' : 'AI Mind',
                            style: AppTypography.label,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            message.text.isEmpty
                                ? 'No completed response'
                                : message.text,
                            style: AppTypography.body,
                          ),
                          if (!message.saved)
                            const Text(
                              'Not saved',
                              style: AppTypography.caption,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _reset(BuildContext ctx) async {
    _voice.pause(reason: 'new_session');
    if (_chat.hasUnsaved) {
      final reset = await showDialog<bool>(
        context: ctx,
        builder:
            (dialog) => AlertDialog(
              title: const Text('Start a new voice chat?'),
              content: const Text(
                'Saved history remains. Unsaved replies in this session will be discarded.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Start new'),
                ),
              ],
            ),
      );
      if (reset != true || !mounted) return;
    }
    _voice.reset();
  }

  Widget _recoveryActions() => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    children: [
      if (_voice.canRetryResponse)
        TextButton.icon(
          onPressed: _voice.retry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(_voice.needsSave ? 'Retry saving' : 'Retry response'),
        ),
      if (_voice.canContinue)
        TextButton(
          onPressed: () => _voice.retry(continuing: true),
          child: const Text('Continue response'),
        ),
      if (_voice.canConfirmTranscript)
        TextButton(
          onPressed: _voice.confirmTranscript,
          child: const Text('Use these words'),
        ),
      if (_voice.canReplay)
        TextButton.icon(
          onPressed: _voice.replay,
          icon: const Icon(Icons.volume_up_outlined, size: 18),
          label: const Text('Read again'),
        ),
      if (_voice.needsMicrophoneSettings)
        TextButton(
          onPressed: _settings,
          child: const Text('Open Android settings'),
        ),
      if (_voice.needsSpeechSettings)
        TextButton(
          onPressed: () => _settings(output: true),
          child: const Text('Speech output settings'),
        ),
    ],
  );

  Widget _controls(BuildContext ctx) {
    final listening = _voice.phase == VoicePhase.listening;
    final speaking = _voice.phase == VoicePhase.speaking;
    final label =
        listening
            ? 'Send'
            : _voice.active
            ? 'Stop'
            : _session.uid == null
            ? 'Sign in'
            : 'Start talking';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _VoiceControl(
                  label:
                      _voice.locale == null
                          ? 'Auto'
                          : _voice.locale!
                              .split(RegExp(r'[_-]'))
                              .first
                              .toUpperCase(),
                  tooltip: 'Speech language',
                  icon: Icons.language_rounded,
                  onPressed: _voice.active ? null : () => _languages(ctx),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Semantics(
                  button: true,
                  label: label,
                  child: Tooltip(
                    message: label,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: const Key('voice-primary'),
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.transparent,
                        borderRadius: BorderRadius.circular(40),
                        onTap: _mic,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: ExcludeSemantics(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 76,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFFAB9BE9),
                                        Color(0xFF7360C9),
                                        Color(0xFF514198),
                                      ],
                                    ),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: .85,
                                      ),
                                      width: 2,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x286551C8),
                                        blurRadius: 20,
                                        offset: Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    listening
                                        ? Icons.arrow_upward_rounded
                                        : _voice.active
                                        ? Icons.stop_rounded
                                        : Icons.mic_none_rounded,
                                    color: Colors.white,
                                    size: 30,
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  style: AppTypography.label,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _VoiceControl(
                  label:
                      listening
                          ? 'Pause'
                          : speaking
                          ? 'New turn'
                          : 'Transcript',
                  tooltip:
                      listening
                          ? 'Stop listening'
                          : speaking
                          ? 'Interrupt and start a new turn'
                          : 'View transcript',
                  icon:
                      listening
                          ? Icons.close_rounded
                          : speaking
                          ? Icons.mic_none_rounded
                          : Icons.chat_bubble_outline_rounded,
                  onPressed:
                      listening
                          ? _voice.pause
                          : speaking
                          ? _voice.begin
                          : () => _transcript(ctx),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext ctx, double height, double width) {
    final hasWords =
        _voice.transcript.isNotEmpty || _chat.conversation.messages.isNotEmpty;
    final scale = MediaQuery.textScalerOf(ctx).scale(16) / 16;
    final orbSize = (height * (hasWords ? .27 : .46) / (scale > 1.5 ? 1.2 : 1))
        .clamp(130.0, width.clamp(130.0, 330.0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            child: AnimatedSwitcher(
              key: const Key('voice-state-label'),
              transitionBuilder:
                  (child, animation) => FadeTransition(
                    opacity: animation.drive(
                      CurveTween(
                        curve: const Interval(.5, 1, curve: Curves.easeOut),
                      ),
                    ),
                    child: child,
                  ),
              duration: AppMotion.duration(
                ctx,
                const Duration(milliseconds: 220),
              ),
              layoutBuilder:
                  (current, previous) => Stack(
                    alignment: Alignment.center,
                    children: [
                      ...previous.map(
                        (child) => ExcludeSemantics(child: child),
                      ),
                      if (current != null) current,
                    ],
                  ),
              child: Text(
                _title,
                key: ValueKey(_title),
                textAlign: TextAlign.center,
                style: AppTypography.title.copyWith(
                  fontSize: width < 350 ? 24 : 27,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -.7,
                  height: 1.25,
                ),
              ),
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(end: orbSize),
            duration: AppMotion.duration(ctx, AppMotion.page),
            curve: Curves.easeInOutCubic,
            builder:
                (_, value, __) =>
                    VoiceVisualization(phase: _voice.phase, size: value),
          ),
          if (_voice.phase == VoicePhase.error)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.errorSurface.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _detail,
                  textAlign: TextAlign.center,
                  style: AppTypography.body.copyWith(
                    fontSize: 14,
                    color: AppColors.errorInk,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              height: _hintHeight(ctx, width),
              child: Center(
                child: Text(
                  _detail,
                  textAlign: TextAlign.center,
                  style: AppTypography.body.copyWith(fontSize: 14, height: 1.5),
                ),
              ),
            ),
          ValueListenableBuilder<String>(
            valueListenable: _chat.streamingText,
            builder: (_, stream, __) {
              final messages = _chat.conversation.messages;
              final text =
                  stream.isNotEmpty
                      ? stream
                      : messages.isNotEmpty && messages.last.role == 'bot'
                      ? messages.last.text
                      : '';
              if (_voice.transcript.isEmpty && text.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 20),
                child: _VoiceTranscriptPanel(
                  transcript: _voice.transcript,
                  reply: text,
                  maxHeight: (height * .32).clamp(150.0, 260.0),
                ),
              );
            },
          ),
          if (_voice.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _voice.notice!,
                  style: AppTypography.caption.copyWith(fontSize: 13),
                ),
              ),
            ),
          _recoveryActions(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MindPage(
    builder:
        (ctx) => PopScope(
          canPop: _allowPop,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _leave(ctx);
          },
          child: Scaffold(
            backgroundColor: AppColors.canvas,
            body: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFF9F7F3),
                    Color(0xFFE6E5FB),
                    Color(0xFFF0E6F7),
                    Color(0xFFF9F7F3),
                  ],
                  stops: [0, .35, .7, 1],
                ),
              ),
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: LayoutBuilder(
                      builder: (_, box) {
                        // Short windows and large text use a single scroll surface so even
                        // the controls remain reachable when the keyboard occupies space.
                        final compact =
                            box.maxHeight < 480 ||
                            MediaQuery.textScalerOf(ctx).scale(16) > 26;
                        final header = Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Row(
                            children: [
                              _VoiceNavButton(
                                tooltip: 'Back',
                                icon: Icons.arrow_back_rounded,
                                onPressed: () => _leave(ctx),
                              ),
                              Expanded(
                                child: Text(
                                  'Voice',
                                  textAlign: TextAlign.center,
                                  style: AppTypography.title.copyWith(
                                    fontSize: 19,
                                    letterSpacing: .1,
                                  ),
                                ),
                              ),
                              _VoiceNavButton(
                                tooltip: 'New voice conversation',
                                icon: Icons.add_rounded,
                                onPressed: () => _reset(ctx),
                              ),
                            ],
                          ),
                        );
                        if (compact) {
                          return SingleChildScrollView(
                            child: Column(
                              children: [
                                header,
                                _content(ctx, box.maxHeight, box.maxWidth),
                                _controls(ctx),
                              ],
                            ),
                          );
                        }
                        return Column(
                          children: [
                            header,
                            Expanded(
                              child: LayoutBuilder(
                                builder:
                                    (_, available) => SingleChildScrollView(
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minHeight: available.maxHeight,
                                        ),
                                        child: Center(
                                          child: _content(
                                            ctx,
                                            box.maxHeight,
                                            box.maxWidth,
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                            _controls(ctx),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
  );
}

class _VoiceNavButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  const _VoiceNavButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 22),
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      backgroundColor: Colors.white.withValues(alpha: .65),
      foregroundColor: AppColors.ink,
      side: const BorderSide(color: Color(0xFFE3DEEF)),
    ),
  );
}

class _VoiceControl extends StatelessWidget {
  final String label, tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  const _VoiceControl({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      enabled: onPressed != null,
      label: '$tooltip, $label',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: .65),
                      border: Border.all(color: AppColors.outline),
                    ),
                    child: Icon(
                      icon,
                      size: 22,
                      color:
                          onPressed == null
                              ? AppColors.controlOutline
                              : AppColors.purplePressed,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption.copyWith(
                      fontSize: 12,
                      color:
                          onPressed == null
                              ? AppColors.secondaryInk
                              : AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _VoiceTranscriptPanel extends StatefulWidget {
  final String transcript, reply;
  final double maxHeight;
  const _VoiceTranscriptPanel({
    required this.transcript,
    required this.reply,
    required this.maxHeight,
  });
  @override
  State<_VoiceTranscriptPanel> createState() => _VoiceTranscriptPanelState();
}

class _VoiceTranscriptPanelState extends State<_VoiceTranscriptPanel> {
  final _scroll = ScrollController();
  @override
  void didUpdateWidget(covariant _VoiceTranscriptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nearBottom = !_scroll.hasClients || _scroll.position.extentAfter < 40;
    if (nearBottom && widget.reply != oldWidget.reply) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _words(String label, String text, bool user) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: user ? const Color(0xFFEDE6F7) : const Color(0xCCFFFFFF),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE3DDED)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTypography.label.copyWith(
            fontSize: 12,
            color: AppColors.purplePressed,
          ),
        ),
        const SizedBox(height: 6),
        SelectableText(
          text,
          style: AppTypography.body.copyWith(
            fontSize: 15,
            height: 1.5,
            color: AppColors.ink,
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: widget.maxHeight),
    child: Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        key: const Key('voice-transcript-panel'),
        controller: _scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.transcript.isNotEmpty)
              _words('You', widget.transcript, true),
            if (widget.transcript.isNotEmpty && widget.reply.isNotEmpty)
              const SizedBox(height: 8),
            if (widget.reply.isNotEmpty) _words('AI Mind', widget.reply, false),
          ],
        ),
      ),
    ),
  );
}
