import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../controllers/sidebar_controller.dart';
import '../models/conversation.dart';
import '../services/app_session.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'conversation_components.dart';
import 'entry_components.dart';
import 'profile_avatar.dart';
import 'mind_mark.dart';

class ChatSidebar extends StatefulWidget {
  final SidebarController history;
  final ChatController chat;
  final AppSession session;
  final VoidCallback onClose, onNew, onLogin, onSignOut;
  final ValueChanged<String> onOpen;
  final ValueChanged<ConversationSummary> onOptions;
  final DateTime Function()? clock;
  const ChatSidebar({super.key, required this.history, required this.chat,
    required this.session, required this.onClose, required this.onNew,
    required this.onLogin, required this.onSignOut, required this.onOpen,
    required this.onOptions, this.clock});
  @override State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  late final TextEditingController _search;
  final _focus = FocusNode();
  @override void initState() {
    super.initState();
    _search = TextEditingController(text: widget.history.rawQuery);
    widget.history.addListener(_syncSearch);
  }
  void _syncSearch() {
    if (_search.text != widget.history.rawQuery) {
      _search.value = TextEditingValue(text: widget.history.rawQuery,
        selection: TextSelection.collapsed(offset: widget.history.rawQuery.length));
    }
  }
  void _dismiss(VoidCallback action) {
    FocusManager.instance.primaryFocus?.unfocus();
    action();
  }
  @override void dispose() {
    widget.history.removeListener(_syncSearch);
    _search.dispose(); _focus.dispose();
    super.dispose();
  }
  @override Widget build(BuildContext context) => Drawer(
    semanticLabel: 'Conversation menu', backgroundColor: AppColors.canvas,
    surfaceTintColor: Colors.transparent,
    width: (MediaQuery.sizeOf(context).width - 40).clamp(0, 360),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(24))),
    child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(child: AnimatedBuilder(
        animation: Listenable.merge([widget.history, widget.chat, widget.session]),
        builder: (context, _) => LayoutBuilder(builder: (context, box) {
          final fixedControls = box.maxHeight >= 580 && MediaQuery.textScalerOf(context).scale(16) <= 24;
          return Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 8, 8, 8), child: Row(children: [
              const ExcludeSemantics(child: MindMark(size: 30)),
              const SizedBox(width: 10),
              Expanded(child: Text('AI Mind', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTypography.title.copyWith(fontSize: 21))),
              IconButton(tooltip: 'Close history', onPressed: () => _dismiss(widget.onClose),
                icon: const Icon(Icons.close_rounded, size: 22)),
            ])),
            if (fixedControls) _controls(),
            Expanded(child: CustomScrollView(key: const Key('conversation-menu-scroll'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                if (!fixedControls) SliverToBoxAdapter(child: _controls()),
                ..._content(),
                if (!fixedControls) SliverToBoxAdapter(child: _profile()),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ])),
            if (fixedControls) _profile(),
          ]);
        }),
      ))));

  Widget _controls() {
    final history = widget.history;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FilledButton.icon(key: const Key('sidebar-new-chat'), onPressed: () => _dismiss(widget.onNew),
          style: FilledButton.styleFrom(backgroundColor: AppColors.purple,
            foregroundColor: AppColors.paper, minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm))),
          icon: const Icon(Icons.edit_square, size: 20), label: const Text('New chat')),
        const SizedBox(height: 14),
        TextField(key: const Key('drawer-search'), controller: _search, focusNode: _focus,
          style: AppTypography.label, textInputAction: TextInputAction.search,
          onSubmitted: (_) => _focus.unfocus(), onChanged: history.setQuery,
          decoration: InputDecoration(hintText: 'Search conversation titles',
            hintStyle: AppTypography.caption.copyWith(fontSize: 13),
            filled: true, fillColor: AppColors.paper,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            prefixIcon: const Icon(Icons.search_rounded, size: 21, color: AppColors.secondaryInk),
            suffixIcon: history.rawQuery.isEmpty ? null : IconButton(tooltip: 'Clear search',
              onPressed: () => history.setQuery(''), icon: const Icon(Icons.close_rounded, size: 20)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.controlOutline)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.controlOutline)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm), borderSide: const BorderSide(color: AppColors.purple, width: 2)))),
        Row(children: [
          Expanded(child: Semantics(liveRegion: true, child: Text(
            history.searching ? 'Searching titles…' : '${history.items.length} saved titles loaded',
            style: AppTypography.caption))),
          if (widget.session.uid != null) IconButton(tooltip: 'Refresh history',
            onPressed: history.loading ? null : history.refresh,
            icon: const Icon(Icons.refresh_rounded, size: 19, color: AppColors.secondaryInk)),
        ]),
      ]));
  }

  List<Widget> _content() {
    final history = widget.history;
    Widget inset(Widget child) => Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: child);
    if (widget.session.uid == null) {
      return [SliverToBoxAdapter(child: inset(MindStatus(title: 'Your conversations belong to you',
        detail: 'Sign in to save and revisit your chats.', action: 'Sign in',
        onAction: () => _dismiss(widget.onLogin))))];
    }
    final saved = history.items;
    final ids = saved.map((c) => c.id).toSet();
    final local = widget.chat.localConversations.where((c) => !ids.contains(c.id) && history.matches(c.title));
    final rows = <Object>[];
    if (local.isNotEmpty) {
      rows.add('Open in this session');
      rows.addAll(local.map((c) => (ConversationSummary(c.id, c.title), false)));
    }
    String? lastGroup;
    final now = widget.clock?.call() ?? DateTime.now();
    for (final item in saved.where((c) => history.matches(c.title))) {
      final group = sidebarDateGroup(item.updatedAt, now);
      if (lastGroup != group) { rows.add(group); lastGroup = group; }
      rows.add((item, true));
    }
    return [
      if (history.isFromCache) SliverToBoxAdapter(child: inset(const Text(
        'Showing cached history. It may be incomplete while offline.', style: AppTypography.caption))),
      if (history.historyChanged) SliverToBoxAdapter(child: inset(const Text(
        'History updated. Load older conversations again if needed.', style: AppTypography.caption))),
      if (history.failed) SliverToBoxAdapter(child: inset(MindStatus(title: 'History is unavailable',
        detail: 'Check your connection. Loaded titles are kept until you retry.', error: true,
        action: 'Retry history', onAction: history.refresh))),
      if (history.loading) SliverToBoxAdapter(child: inset(const EntryLoadingIndicator(label: 'Loading history'))),
      SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12), sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final row = rows[index];
          if (row is String) { return Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
            child: Semantics(header: true, child: Text(row, style: AppTypography.caption.copyWith(fontWeight: FontWeight.w500)))); }
          final (summary, saved) = row as (ConversationSummary, bool);
          return SidebarConversationRow(key: ValueKey('sidebar-${summary.id}'), chat: summary,
            selected: summary.id == widget.chat.conversation.id,
            onOpen: () => _dismiss(() => widget.onOpen(summary.id)),
            onOptions: saved ? () => _dismiss(() => widget.onOptions(summary)) : null);
        }, childCount: rows.length))),
      if (!history.loading && !history.failed && rows.isEmpty) SliverToBoxAdapter(child: inset(
        MindStatus(title: history.query.isEmpty ? 'Saved conversations will appear here.' : 'No matching conversations.',
          icon: history.query.isEmpty ? Icons.chat_bubble_outline_rounded : Icons.search_off_rounded,
          detail: history.query.isEmpty ? 'Start a chat and come back to it here.' : 'Try another title or load older conversations. Message contents aren’t searched.'))),
      if (history.moreFailed) SliverToBoxAdapter(child: inset(const Text(
        'Could not load older conversations. Check your connection and retry.', style: AppTypography.caption))),
      if (history.hasMore) SliverToBoxAdapter(child: inset(TextButton.icon(
        onPressed: history.loadingMore || history.failed ? null : history.loadMore,
        icon: const Icon(Icons.expand_more_rounded, size: 20),
        label: Text(history.loadingMore ? 'Loading older conversations…' : history.moreFailed ? 'Retry older conversations' : 'Load older conversations')))),
      if (!history.loading && saved.isNotEmpty) SliverToBoxAdapter(child: inset(Text(
        history.hasMore ? 'Search covers loaded titles only.' : history.isFromCache ? 'Search covers available cached titles.' : 'Search covers loaded titles, not messages.',
        style: AppTypography.caption))),
    ];
  }

  Widget _profile() => Container(decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.outline))),
    padding: const EdgeInsets.fromLTRB(20, 12, 8, 12), child: Row(children: [
      ProfileAvatar(uid: widget.session.uid, name: widget.session.name,
        photoUrl: widget.session.photoUrl, size: 36),
      const SizedBox(width: 10),
      Expanded(child: Tooltip(message: widget.session.name, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.session.uid == null ? 'Guest' : widget.session.name,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.label),
        Text(widget.session.uid == null ? 'Browse at your pace' : 'Your conversations', style: AppTypography.caption),
      ]))),
      if (widget.session.uid != null) IconButton(tooltip: 'Sign out', onPressed: widget.onSignOut,
        icon: const Icon(Icons.logout_rounded, size: 20)),
    ]));
}

/// Compact sidebar-only row; Home and dedicated History retain their cards.
class SidebarConversationRow extends StatelessWidget {
  final ConversationSummary chat;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback? onOptions;
  const SidebarConversationRow({super.key, required this.chat, required this.selected,
    required this.onOpen, this.onOptions});
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 3),
    child: Material(color: selected ? AppColors.lavenderSurface : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.sm), clipBehavior: Clip.antiAlias,
      child: Row(children: [
        Expanded(child: Semantics(selected: selected, child: InkWell(onTap: onOpen,
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Row(children: [
              ExcludeSemantics(child: Icon(chat.type == 'voice' ? Icons.graphic_eq_rounded : Icons.chat_bubble_outline_rounded,
                size: 18, color: selected ? AppColors.purple : AppColors.secondaryInk)),
              const SizedBox(width: 10),
              Expanded(child: Tooltip(message: chat.title, child: Text(chat.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.label.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400)))),
            ])))))),
        if (onOptions != null) IconButton(tooltip: 'Options for ${chat.title}', onPressed: onOptions,
          icon: const Icon(Icons.more_horiz_rounded, size: 20, color: AppColors.secondaryInk)),
      ])));
}
