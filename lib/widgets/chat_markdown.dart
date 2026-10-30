import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'chat_design.dart';

/// Only a presentation prefix. The controller always retains the full response.
/// Ambiguous trailing syntax waits for more input; completion/Stop renders the
/// original source verbatim through the Markdown parser, including literal text.
String streamingMarkdownPrefix(String source) {
  final lines = source.split('\n');
  var offset = 0;
  String? fence;
  var fenceLength = 0;
  var inTable = false;
  var inlineStart = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final last = i == lines.length - 1;
    final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (fence != null) {
      if (marker != null &&
          marker[1]!.startsWith(fence) &&
          marker[1]!.length >= fenceLength &&
          marker[2]!.trim().isEmpty) {
        if (last) return source.substring(0, offset);
        fence = null;
        inlineStart = offset + line.length + 1;
      } else if (last) {
        // Do not flash the first one or two characters of a closing fence.
        final tail = line.trim();
        if (tail.isNotEmpty &&
            tail.length < fenceLength &&
            tail.split('').every((c) => c == fence)) {
          return source.substring(0, offset);
        }
        return source;
      }
    } else if (marker != null) {
      if (last) return source.substring(0, offset);
      fence = marker[1]![0];
      fenceLength = marker[1]!.length;
    } else {
      // Wait for a table header's delimiter line. Otherwise a header briefly
      // appears as pipe-delimited prose before becoming a table.
      final hasPipe = RegExp(r'(?<!\\)\|').hasMatch(line);
      final delimiter =
          hasPipe &&
          RegExp(r'^[\s|:\-]+$').hasMatch(line) &&
          line.contains('---');
      if (delimiter && !last) inTable = true;
      if (line.trim().isEmpty && !last) inTable = false;
      if (hasPipe &&
          (last ||
              (!inTable &&
                  i == lines.length - 2 &&
                  RegExp(r'^[\s|:\-]*$').hasMatch(lines.last)))) {
        return source.substring(0, offset);
      }
      if (last && RegExp(r'^\s*(#{1,6}|[-*_~`]+|\d+[.)])\s*$').hasMatch(line)) {
        return source.substring(0, offset);
      }
    }
    offset += line.length + 1;
  }

  // Defer an unfinished inline construct, without adding synthetic punctuation
  // or deleting any content from the actual message. Inspect the current
  // paragraph only; completed blocks remain stable as tokens arrive.
  final start = source.lastIndexOf('\n\n') + 2;
  final paragraphStart = (start < 2 ? 0 : start).clamp(
    inlineStart,
    source.length,
  );
  final pending = <(String, int)>[];
  for (var i = paragraphStart; i < source.length; i++) {
    final c = source[i];
    if (c == r'\') {
      i++;
      continue;
    }
    if (pending.isNotEmpty && pending.last.$1.startsWith('`') && c != '`') {
      continue;
    }
    if (c == '[') {
      pending.add(('[', i));
      continue;
    }
    if (c == ']' && pending.isNotEmpty && pending.last.$1 == '[') {
      final opening = pending.removeLast();
      if (i + 1 == source.length) return source.substring(0, opening.$2);
      if (source[i + 1] == '(') {
        pending.add(('link', opening.$2));
        i++;
      }
      continue;
    }
    if (c == ')' && pending.isNotEmpty && pending.last.$1 == 'link') {
      pending.removeLast();
      continue;
    }
    if (pending.isNotEmpty && pending.last.$1 == 'link') continue;
    if (c != '*' && c != '_' && c != '`' && c != '~') continue;
    var end = i + 1;
    while (end < source.length && source[end] == c) {
      end++;
    }
    final token = source.substring(i, end);
    final before = i == 0 ? ' ' : source[i - 1];
    final after = end == source.length ? '' : source[end];
    if (pending.isNotEmpty &&
        pending.last.$1 == token &&
        (c == '`' || before.trim().isNotEmpty)) {
      pending.removeLast();
    } else if ((c != '_' || !RegExp(r'\w').hasMatch(before)) &&
        (c == '`' || after.isEmpty || after.trim().isNotEmpty) &&
        (c != '~' || token.length == 2)) {
      pending.add((token, i));
    }
    i = end - 1;
  }
  return pending.isEmpty ? source : source.substring(0, pending.first.$2);
}

class ChatMarkdown extends StatelessWidget {
  final String text;
  final bool streaming;
  final void Function(String?) onOpenLink;
  const ChatMarkdown({
    super.key,
    required this.text,
    required this.onOpenLink,
    this.streaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final body = ChatDesign.body;
    TextStyle heading(double size) => body.copyWith(
      fontSize: size,
      height: 1.35,
      fontWeight: FontWeight.w700,
    );
    // Measure ordered-list markers at the user's text scale. A fixed indent
    // causes "2." to wrap onto two lines at large accessibility settings.
    var widestMarker = '9.';
    for (final match in RegExp(
      r'^\s*(\d{1,9})[.)]\s',
      multiLine: true,
    ).allMatches(text)) {
      if (match[1]!.length + 1 > widestMarker.length) {
        widestMarker = '${match[1]}.';
      }
    }
    final scaler = MediaQuery.textScalerOf(context);
    final marker = TextPainter(
      text: TextSpan(text: widestMarker, style: body),
      textScaler: scaler,
      textDirection: Directionality.of(context),
    )..layout();
    final listIndent = marker.width + scaler.scale(8);
    marker.dispose();
    return MarkdownBody(
      data: streaming ? streamingMarkdownPrefix(text) : text,
      selectable: true,
      fitContent: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (_, href, __) => onOpenLink(href),
      // Preserve the existing policy: provider images never trigger a fetch.
      imageBuilder:
          (_, __, alt) => Text(
            alt?.isNotEmpty == true
                ? '[Image: $alt]'
                : '[External image omitted]',
            style: AppTypography.caption,
          ),
      builders: {'pre': _CodeBlockBuilder()},
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: body,
        h1: heading(19),
        h2: heading(18),
        h3: heading(17),
        h4: heading(16),
        h5: heading(16),
        h6: heading(16),
        strong: const TextStyle(fontWeight: FontWeight.w700),
        em: const TextStyle(fontStyle: FontStyle.italic),
        a: const TextStyle(
          color: AppColors.purple,
          decoration: TextDecoration.underline,
        ),
        blockSpacing: 9,
        listIndent: listIndent,
        listBullet: body,
        code: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          color: AppColors.ink,
          backgroundColor: AppColors.lavenderSurface,
        ),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
        ),
        blockquote: body.copyWith(color: AppColors.secondaryInk),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        blockquoteDecoration: const BoxDecoration(
          color: AppColors.lavenderPaper,
          border: BorderDirectional(
            start: BorderSide(color: AppColors.lavender, width: 3),
          ),
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        tableHead: body.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
        tableBody: body.copyWith(fontSize: 14),
        tableHeadAlign: TextAlign.left,
        // Bound prose cells so a sentence does not create a screen-wide column.
        // Wider tables retain horizontal scrolling; source/copy stays unchanged.
        tableColumnWidth: FixedColumnWidth(
          ((MediaQuery.sizeOf(context).width - 36) / 2).clamp(140.0, 200.0),
        ),
        tableScrollbarThumbVisibility: true,
        tablePadding: const EdgeInsets.only(bottom: 10),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        tableHeadCellsDecoration: const BoxDecoration(
          color: AppColors.lavenderSurface,
        ),
        tableCellsDecoration: const BoxDecoration(color: AppColors.paper),
        tableBorder: TableBorder.all(color: AppColors.outline, width: 0.6),
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language =
        code?.attributes['class']?.replaceFirst('language-', '') ?? 'Code';
    return ChatCodeBlock(code: element.textContent, language: language);
  }
}

class ChatCodeBlock extends StatefulWidget {
  final String code, language;
  const ChatCodeBlock({super.key, required this.code, required this.language});
  @override
  State<ChatCodeBlock> createState() => _ChatCodeBlockState();
}

class _ChatCodeBlockState extends State<ChatCodeBlock> {
  final _scroll = ScrollController();
  bool _expanded = false;
  bool? _wrap;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plain =
        const [
          'Code',
          'text',
          'plaintext',
          'md',
          'markdown',
          '',
        ].contains(widget.language.toLowerCase()) ||
        widget.language == 'Code';
    final wrap = _wrap ?? plain;
    final lines = widget.code.split('\n');
    final long = lines.length > 12 || widget.code.length > 1400;
    // Only the preview is collapsed. Copy always uses the untouched full source.
    final preview =
        long && !_expanded
            ? lines.take(10).join('\n').characters.take(1400).toString()
            : widget.code;
    final foreground = plain ? AppColors.ink : const Color(0xFFF5F0FC);
    final muted = plain ? AppColors.secondaryInk : const Color(0xFFD4CCE5);
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.5,
      color: foreground,
    );
    final text = SelectableText(preview, style: style);
    final body =
        wrap
            ? Padding(padding: const EdgeInsets.all(12), child: text)
            : Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                child: text,
              ),
            );
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: plain ? AppColors.lavenderPaper : const Color(0xFF2C2938),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption.copyWith(color: muted),
                  ),
                ),
                IconButton(
                  tooltip: wrap ? 'Disable line wrapping' : 'Wrap code lines',
                  onPressed: () => setState(() => _wrap = !wrap),
                  icon: Icon(Icons.wrap_text_rounded, size: 18, color: muted),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: foreground,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: widget.code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: foreground.withValues(alpha: .12)),
          if (long && !_expanded)
            SizedBox(height: 200, child: SingleChildScrollView(child: body))
          else
            body,
          if (long)
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: foreground,
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 18,
              ),
              label: Text(
                _expanded
                    ? 'Show less'
                    : 'Show full block (${lines.length} lines)',
              ),
            ),
        ],
      ),
    );
  }
}
