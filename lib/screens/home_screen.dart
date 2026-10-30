import 'dart:async';
import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../services/app_session.dart';
import '../services/conversation_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/conversation_components.dart';
import '../widgets/entry_components.dart';
import '../widgets/profile_avatar.dart';
import 'chat_screen.dart';
import 'chat_history_screen.dart';
import 'voice_screen.dart';
import 'login_screen.dart';

const mindPrompts = [
  ('Find the words', 'Help me write a thoughtful message.', Icons.edit_note_rounded),
  ('Make a plan', 'Help me break a goal into manageable steps.', Icons.checklist_rounded),
  ('Understand an idea', 'Explain a tricky concept with a simple example.', Icons.lightbulb_outline_rounded),
];

class HomeScreen extends StatefulWidget {
  final AppSession? session;
  final ConversationRepository? repository;
  final Widget Function(String? prompt, String? chatId)? chatBuilder;
  final WidgetBuilder? voiceBuilder;
  final WidgetBuilder? historyBuilder;
  final WidgetBuilder? loginBuilder;
  const HomeScreen({super.key, this.session, this.repository, this.chatBuilder,
    this.voiceBuilder, this.historyBuilder, this.loginBuilder});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppSession _session;
  late final ConversationRepository _repository;
  late Stream<List<ConversationSummary>> _history;
  String? _uid;
  bool _accountBusy = false;
  final Set<String> _deleting = {};
  @override void initState() {
    super.initState();
    _session = widget.session ?? FirebaseAppSession();
    _repository = widget.repository ?? FirebaseConversationRepository(_session);
    _uid = _session.uid;
    _refreshHistory();
    _session.addListener(_sessionChanged);
  }
  void _refreshHistory() { _history = _session.uid == null ? Stream.value([]) : _repository.watch(_session.uid!); }
  void _sessionChanged() {
    if (!mounted) return;
    if (_uid != _session.uid) { _uid = _session.uid; _refreshHistory(); }
    setState(() {});
  }
  @override void dispose() {
    _session.removeListener(_sessionChanged);
    if (widget.session == null) _session.dispose();
    super.dispose();
  }
  void _chat({String? prompt, String? id}) => Navigator.of(context).push(mindRoute(context,
    widget.chatBuilder?.call(prompt, id) ?? ChatScreen(presetPrompt: prompt, loadChatId: id,
      session: _session, repository: _repository)));
  void _login() => Navigator.of(context).push(mindRoute(context,
    widget.loginBuilder?.call(context) ?? const LoginScreen()));
  Future<void> _logout() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try { await _session.signOut(); } catch (_) { _snack('Could not sign out. Please retry.'); }
    finally { if (mounted) setState(() => _accountBusy = false); }
  }
  void _snack(String message) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }
  Future<void> _delete(BuildContext ctx, ConversationSummary chat) async {
    final uid = _session.uid;
    if (uid == null || _deleting.contains(chat.id)) return;
    if (!await confirmConversationDelete(ctx, chat.title) || !mounted || uid != _session.uid) return;
    setState(() => _deleting.add(chat.id));
    try { await _repository.delete(uid, chat.id); }
    catch (_) { _snack('Could not delete the conversation. Check your connection and retry.'); }
    finally { if (mounted) setState(() => _deleting.remove(chat.id)); }
  }
  String get _greeting {
    final hour = DateTime.now().hour;
    return hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
  }
  @override Widget build(BuildContext context) => MindPage(builder: (ctx) => Scaffold(
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: AppSpacing.contentWidth),
      child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 16, 24, 24), child: MindEntrance(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ProfileAvatar(uid: _session.uid, name: _session.name, photoUrl: _session.photoUrl),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_greeting, style: AppTypography.caption), const SizedBox(height: 3),
              Text(_session.uid == null ? 'Welcome to AI Mind' : _session.name,
                style: AppTypography.label.copyWith(fontSize: 17)),
            ])),
            const SizedBox(width: 4),
            if (_session.uid == null) TextButton(onPressed: _login, child: const Text('Sign in'))
            else IconButton(tooltip: 'Sign out', onPressed: _accountBusy ? null : _logout,
              icon: _accountBusy ? const EntryLoadingIndicator(label: 'Signing out') : const Icon(Icons.logout_rounded)),
          ]),
          const SizedBox(height: 24),
          Text('Make space for\na good idea.', style: AppTypography.headline.copyWith(fontSize: 28)),
          const SizedBox(height: 10),
          Text('Ask, explore, or pick up where you left off.', style: AppTypography.body.copyWith(fontSize: 14)),
          const SizedBox(height: 18),
          _actions(ctx),
          const SizedBox(height: 20),
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, children: [
            Text('Your conversations', style: AppTypography.label.copyWith(fontSize: 20)),
            if (_session.uid != null) TextButton(onPressed: () => Navigator.of(context).push(mindRoute(ctx,
              widget.historyBuilder?.call(context) ?? ChatHistoryScreen(session: _session, repository: _repository))), child: const Text('View all')),
          ]),
          const SizedBox(height: 12), _recent(ctx),
          const SizedBox(height: 28),
          Text('A place to begin', style: AppTypography.label.copyWith(fontSize: 20)),
          const SizedBox(height: 12),
          for (final prompt in mindPrompts) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Material(color: AppColors.paper, borderRadius: BorderRadius.circular(AppRadii.sm),
              child: InkWell(borderRadius: BorderRadius.circular(AppRadii.sm), onTap: () => _chat(prompt: prompt.$2),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), child: Row(children: [
                  Icon(prompt.$3, color: AppColors.purple), const SizedBox(width: 12),
                  Expanded(child: Text(prompt.$1, style: AppTypography.label)),
                  const Icon(Icons.north_east_rounded, size: 18, color: AppColors.secondaryInk),
                ]))))),

        ])),
      )),
    )),
  ));
  Widget _actions(BuildContext context) => LayoutBuilder(builder: (ctx, box) {
    final narrow = box.maxWidth < 280 || MediaQuery.textScalerOf(ctx).scale(16) > 23;
    final chat = _ActionCard(title: 'Let’s talk', subtitle: 'Start a conversation',
      icon: Icons.chat_bubble_outline_rounded, primary: true, onTap: () => _chat());
    final voice = _ActionCard(title: 'Use your voice', subtitle: 'Think out loud',
      icon: Icons.graphic_eq_rounded, onTap: () => Navigator.of(context).push(mindRoute(context,
        widget.voiceBuilder?.call(context) ?? VoiceScreen(session: _session, repository: _repository))));
    return narrow ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [chat, const SizedBox(height: 12), voice])
      : IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: chat), const SizedBox(width: 12), Expanded(child: voice)]));
  });
  Widget _recent(BuildContext context) {
    if (_session.uid == null) { return MindStatus(title: 'Keep your thoughts together',
      detail: 'Browse freely. Sign in to ask AI Mind and save your conversations.', icon: Icons.lock_outline_rounded,
      action: 'Sign in', onAction: _login); }
    return StreamBuilder<List<ConversationSummary>>(key: ValueKey(_session.uid), stream: _history,
      builder: (ctx, snapshot) {
        if (snapshot.hasError) { return MindStatus(title: 'History is unavailable',
          detail: 'Check your connection and try again.', error: true, icon: Icons.cloud_off_rounded,
          action: 'Retry', onAction: () => setState(_refreshHistory)); }
        if (!snapshot.hasData) { return const EntrySurface(child: Row(children: [
          EntryLoadingIndicator(label: 'Loading conversations'), SizedBox(width: 12),
          Expanded(child: Text('Loading conversations…', style: AppTypography.body))])); }
        if (snapshot.data!.isEmpty) { return MindStatus(title: 'Your next idea starts here',
          detail: 'Start a conversation and return to it whenever you need.', action: 'Start a chat', onAction: () => _chat()); }
        return Column(children: snapshot.data!.take(4).map((chat) => _deleting.contains(chat.id)
          ? const Padding(padding: EdgeInsets.all(16), child: EntryLoadingIndicator(label: 'Deleting conversation'))
          : ConversationTile(chat: chat, onOpen: () => _chat(id: chat.id),
              onOptions: () => _delete(context, chat), optionsTooltip: 'Delete conversation ${chat.title}',
              optionsIcon: Icons.delete_outline_rounded)).toList());
      });
  }
}

class _ActionCard extends StatelessWidget {
  final String title, subtitle;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;
  const _ActionCard({required this.title, required this.subtitle, required this.icon,
    required this.onTap, this.primary = false});
  @override Widget build(BuildContext context) => Material(
    color: primary ? AppColors.purple : AppColors.lavenderSurface,
    elevation: primary ? 1 : 0, shadowColor: AppColors.purple.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(AppRadii.card), clipBehavior: Clip.antiAlias,
    child: Ink(decoration: BoxDecoration(gradient: primary ? const LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [AppColors.purple, AppColors.purplePressed]) : null),
    child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: primary ? AppColors.paper : AppColors.purple, size: 28),
        const SizedBox(height: 12),
        Text(title, style: AppTypography.label.copyWith(fontSize: 17,
          color: primary ? AppColors.paper : AppColors.ink)), const SizedBox(height: 6),
        Text(subtitle, style: AppTypography.caption.copyWith(fontSize: 13,
          color: primary ? AppColors.paper : AppColors.secondaryInk)),
      ])))));
}
