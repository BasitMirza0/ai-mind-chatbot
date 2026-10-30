import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../services/app_session.dart';
import '../services/conversation_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/conversation_components.dart';
import '../widgets/entry_components.dart';
import 'chat_screen.dart';
import 'login_screen.dart';

class ChatHistoryScreen extends StatefulWidget {
  final AppSession? session;
  final ConversationRepository? repository;
  final Widget Function(String)? chatBuilder;
  const ChatHistoryScreen({super.key, this.session, this.repository, this.chatBuilder});
  @override State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}
class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  late final AppSession _session = widget.session ?? FirebaseAppSession();
  late final ConversationRepository _repository = widget.repository ?? FirebaseConversationRepository(_session);
  late Stream<List<ConversationSummary>> _history;
  final _search = TextEditingController();
  String? _uid;
  final _busy = <String>{};
  @override void initState() { super.initState(); _uid = _session.uid; _refresh(); _session.addListener(_identity); }
  void _refresh() { _history = _session.uid == null ? Stream.value([]) : _repository.watch(_session.uid!); }
  void _identity() {
    if (!mounted) return;
    if (_uid != _session.uid) { _uid = _session.uid; _search.clear(); _refresh(); }
    setState(() {});
  }
  @override void dispose() { _session.removeListener(_identity); if (widget.session == null) _session.dispose(); _search.dispose(); super.dispose(); }
  Future<void> _options(BuildContext ctx, ConversationSummary chat) async {
    final uid = _session.uid;
    if (uid == null || _busy.contains(chat.id)) return;
    final action = await showModalBottomSheet<String>(context: ctx, builder: (sheet) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(sheet, 'rename')),
      ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Delete'), onTap: () => Navigator.pop(sheet, 'delete')),
    ])));
    if (!ctx.mounted || uid != _session.uid || action == null) return;
    String? name;
    if (action == 'delete') {
      if (!await confirmConversationDelete(ctx, chat.title)) return;
    } else {
      var draft = chat.title;
      name = await showDialog<String>(context: ctx, builder: (dialog) => AlertDialog(title: const Text('Rename conversation'),
        content: TextFormField(initialValue: draft, maxLength: 200, decoration: const InputDecoration(labelText: 'Conversation name'), onChanged: (value) => draft = value),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          TextButton(onPressed: () { if (draft.trim().isNotEmpty) Navigator.pop(dialog, draft.trim()); }, child: const Text('Save'))]));
      if (name == null) return;
    }
    if (!mounted || uid != _session.uid) return;
    setState(() => _busy.add(chat.id));
    try {
      if (action == 'delete') { await _repository.delete(uid, chat.id); }
      else { await _repository.rename(uid, chat.id, name!); }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not update history. Check your connection and retry.')));
    } finally { if (mounted) setState(() => _busy.remove(chat.id)); }
  }
  @override Widget build(BuildContext context) => MindPage(builder: (ctx) => Scaffold(
    appBar: AppBar(backgroundColor: AppColors.canvas, surfaceTintColor: Colors.transparent, title: const Text('Your conversations')),
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: AppSpacing.contentWidth), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 20), child: TextField(controller: _search,
        onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: 'Search conversations', prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty ? null : IconButton(tooltip: 'Clear search', onPressed: () => setState(_search.clear), icon: const Icon(Icons.close_rounded)),
          filled: true, fillColor: AppColors.paper, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16))))),
      Expanded(child: _session.uid == null ? ListView(padding: const EdgeInsets.all(24), children: [MindStatus(
        title: 'A place for your conversations', detail: 'Sign in to save and revisit your ideas.', action: 'Sign in',
        onAction: () => Navigator.of(context).push(mindRoute(ctx, const LoginScreen())))])
        : StreamBuilder<List<ConversationSummary>>(key: ValueKey(_uid), stream: _history, builder: (_, snap) {
          if (snap.hasError) { return ListView(padding: const EdgeInsets.all(24), children: [MindStatus(title: 'History is unavailable',
            detail: 'Check your connection and try again.', error: true, action: 'Retry', onAction: () => setState(_refresh))]); }
          if (!snap.hasData) return const Center(child: EntryLoadingIndicator(label: 'Loading conversations'));
          final matches = snap.data!.where((c) => c.title.toLowerCase().contains(_search.text.trim().toLowerCase())).toList();
          if (matches.isEmpty) { return ListView(padding: const EdgeInsets.all(24), children: [MindStatus(
            title: snap.data!.isEmpty ? 'Your next idea starts here' : 'No matching conversations',
            detail: snap.data!.isEmpty ? 'Conversations you save will appear here.' : 'Try another word or clear your search.')]); }
          return ListView.builder(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), itemCount: matches.length, itemBuilder: (_, index) {
            final chat = matches[index];
            if (_busy.contains(chat.id)) return const Padding(padding: EdgeInsets.all(24), child: EntryLoadingIndicator(label: 'Updating conversation'));
            return ConversationTile(chat: chat, onOptions: () => _options(ctx, chat), onOpen: () => Navigator.of(context).push(mindRoute(ctx,
              widget.chatBuilder?.call(chat.id) ?? ChatScreen(loadChatId: chat.id, session: _session, repository: _repository))));
          });
        })),
    ])))),
  ));
}
