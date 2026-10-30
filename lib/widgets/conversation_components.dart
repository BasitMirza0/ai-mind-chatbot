import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/conversation.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'entry_components.dart';

class MindPage extends StatelessWidget {
  final WidgetBuilder builder;
  const MindPage({super.key, required this.builder});
  @override Widget build(BuildContext context) => Theme(data: AppTheme.light,
    child: AnnotatedRegion<SystemUiOverlayStyle>(value: AppTheme.lightSystemUi,
      child: Builder(builder: builder)));
}

Route<T> mindRoute<T>(BuildContext context, Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, __, ___) => page,
  transitionDuration: AppMotion.duration(context, AppMotion.route),
  reverseTransitionDuration: AppMotion.duration(context, AppMotion.route),
  transitionsBuilder: (_, animation, __, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: AppMotion.curve), child: child));

class MindEntrance extends StatelessWidget {
  final Widget child;
  const MindEntrance({super.key, required this.child});
  @override Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: AppMotion.reduced(context) ? 1 : 0, end: 1),
    duration: AppMotion.duration(context, AppMotion.entrance),
    curve: AppMotion.curve, child: child,
    builder: (_, value, child) => Opacity(opacity: value,
      child: Transform.translate(offset: Offset(0, 8 * (1 - value)), child: child)));
}

class MindStatus extends StatelessWidget {
  final String title;
  final String? detail;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;
  final bool error;
  const MindStatus({super.key, required this.title, this.detail,
    this.icon = Icons.chat_bubble_outline_rounded, this.action, this.onAction, this.error = false});
  @override Widget build(BuildContext context) => Semantics(liveRegion: error,
    child: EntrySurface(color: error ? AppColors.errorSurface : AppColors.paper,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 22, color: error ? AppColors.errorInk : AppColors.purple),
          const SizedBox(width: 12), Expanded(child: Text(title, style: AppTypography.label)),
        ]),
        if (detail != null) ...[const SizedBox(height: 8), Text(detail!, style: AppTypography.body.copyWith(fontSize: 14))],
        if (onAction != null) TextButton(onPressed: onAction, child: Text(action!)),
      ])));
}

class ConversationTile extends StatelessWidget {
  final ConversationSummary chat;
  final VoidCallback onOpen;
  final VoidCallback? onOptions;
  final bool selected;
  final String? optionsTooltip;
  final IconData optionsIcon;
  const ConversationTile({super.key, required this.chat, required this.onOpen,
    this.onOptions, this.selected = false, this.optionsTooltip, this.optionsIcon = Icons.more_horiz_rounded});
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(color: selected ? AppColors.lavenderSurface : AppColors.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm),
        side: const BorderSide(color: AppColors.outline)), clipBehavior: Clip.antiAlias,
      child: Row(children: [Expanded(child: InkWell(onTap: onOpen,
        child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Icon(chat.type == 'voice' ? Icons.graphic_eq_rounded : Icons.chat_bubble_outline_rounded,
            color: AppColors.purple, size: 20), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chat.title, style: AppTypography.label),
            const SizedBox(height: 4), Text(chat.type == 'voice' ? 'Voice conversation' : 'Conversation', style: AppTypography.caption),
          ])),
          if (onOptions == null) const Icon(Icons.arrow_outward_rounded, color: AppColors.secondaryInk, size: 18),
        ])))),
        if (onOptions != null) IconButton(tooltip: optionsTooltip ?? 'Options for ${chat.title}', onPressed: onOptions,
          icon: Icon(optionsIcon)),
      ])));
}

Future<bool> confirmConversationDelete(BuildContext context, String title) async =>
  await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
    title: const Text('Delete conversation?'), content: Text('“$title” and its messages will be permanently deleted.'),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))])) ?? false;
