import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/conversation.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'chat_markdown.dart';
import 'chat_design.dart';

bool safeChatLink(Uri? uri) =>
    uri != null &&
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

Future<void> openChatLink(
  BuildContext context,
  String? href, {
  Future<bool> Function(Uri)? launcher,
}) async {
  final uri = Uri.tryParse(href ?? '');
  if (!safeChatLink(uri)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Only web links can be opened.')),
    );
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: const Text('Open external website?'),
          content: SingleChildScrollView(child: Text(uri.toString())),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open website'),
            ),
          ],
        ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final opened =
        await (launcher?.call(uri!) ??
            launchUrl(uri!, mode: LaunchMode.externalApplication));
    if (!opened) throw StateError('Unavailable');
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this link.')),
      );
    }
  }
}

class ChatMessageCard extends StatelessWidget {
  final ChatMessage message;
  final ValueNotifier<String>? streamingText;
  final VoidCallback? onRegenerate, onRetry, onContinue;
  const ChatMessageCard({
    super.key,
    required this.message,
    this.streamingText,
    this.onRegenerate,
    this.onRetry,
    this.onContinue,
  });

  String get _status {
    if (message.state == ReplyState.stopped) {
      return 'Stopped by you · not saved';
    }
    if (message.state == ReplyState.truncated) {
      return 'Length limit reached · not saved';
    }
    return switch (message.failureCode) {
      'firestore' => 'Could not save. Your response is still here.',
      'sign_in_required' || 'invalid_token' || 'auth_unavailable' =>
        'Sign-in could not be verified. Please sign in again.',
      'provider_timeout' ||
      'backend_timeout' => 'Response timed out · partial text kept here',
      'backend_unavailable' =>
        'Connection interrupted · partial text kept here',
      'provider_busy' || 'quota_exceeded' => 'AI is busy. Try again shortly.',
      'provider_configuration' ||
      'provider_not_configured' => 'AI service configuration needs attention.',
      'provider_rejected' => 'AI service could not process this request.',
      'provider_unavailable' ||
      'provider_stream_error' ||
      'invalid_provider_stream' =>
        'AI service interrupted · partial text kept here',
      _ => 'Response interrupted · partial text kept here',
    };
  }

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!user)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.purple,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'm',
                      style: TextStyle(
                        fontSize: 17,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('AI MIND', style: ChatDesign.identity),
                ],
              ),
            ),
          ),
        if (message.image != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                message.image!,
                height: 150,
                fit: BoxFit.contain,
                semanticLabel: 'Attached image',
                errorBuilder:
                    (_, __, ___) => const Text('Image preview unavailable'),
              ),
            ),
          ),
        if (user)
          SelectableText(message.text, style: ChatDesign.body)
        else
          ValueListenableBuilder<String>(
            valueListenable:
                streamingText ?? AlwaysStoppedAnimation(message.text),
            builder:
                (_, text, __) => ChatMarkdown(
                  text: streamingText == null ? message.text : text,
                  streaming: streamingText != null,
                  onOpenLink: (href) => openChatLink(context, href),
                ),
          ),
        if (!user)
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.textScalerOf(context).scale(24) + 24,
            ),
            child: Row(
              children: [
                if (streamingText != null)
                  const ChatGenerationIndicator()
                else if (message.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Copy message',
                    style: IconButton.styleFrom(
                      foregroundColor: AppColors.secondaryInk,
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: message.text),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Message copied')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                if (onRegenerate != null)
                  Flexible(
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.secondaryInk,
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: onRegenerate,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text(
                        'Regenerate',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (message.state != ReplyState.complete && streamingText == null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _status,
                style: AppTypography.caption.copyWith(
                  color:
                      message.state == ReplyState.stopped ||
                              message.state == ReplyState.truncated
                          ? AppColors.secondaryInk
                          : AppColors.errorInk,
                ),
              ),
            ),
          ),
        if (!message.saved && message.state == ReplyState.complete)
          const Text('Not saved yet', style: AppTypography.caption),
        if (onContinue != null || onRetry != null)
          Wrap(
            spacing: 8,
            children: [
              if (onContinue != null)
                TextButton.icon(
                  onPressed: onContinue,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                  label: const Text('Continue response'),
                ),
              if (onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(
                    message.state == ReplyState.complete
                        ? 'Retry saving'
                        : message.state == ReplyState.stopped
                        ? 'Retry response'
                        : 'Retry',
                  ),
                ),
            ],
          ),
        if (message.previousAttempts.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            dense: true,
            title: Text(
              'Previous incomplete attempts (${message.previousAttempts.length})',
              style: AppTypography.caption,
            ),
            children: [
              for (final text in message.previousAttempts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(text, style: ChatDesign.body),
                ),
            ],
          ),
      ],
    );
    return RepaintBoundary(
      child: Semantics(
        container: true,
        label: user ? 'Your message' : 'AI Mind response',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child:
              user
                  ? Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FractionallySizedBox(
                      widthFactor: ChatDesign.userWidth,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.lavenderSurface,
                            borderRadius: ChatDesign.userRadius,
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  )
                  : content,
        ),
      ),
    );
  }
}
