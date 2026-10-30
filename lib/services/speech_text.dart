import 'package:markdown/markdown.dart' as md;

/// A playback representation only. Never used for persistence or AI context.
String speechFriendlyText(String source) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  String read(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is! md.Element) return '';
    final children = node.children ?? <md.Node>[];
    if (node.tag == 'hr') return '\n';
    if (node.tag == 'img') return node.attributes['alt'] ?? '';
    if (node.tag == 'table') {
      final rows = <List<String>>[];
      void collect(md.Node child) {
        if (child is! md.Element) return;
        if (child.tag == 'tr') {
          rows.add(
            (child.children ?? []).map(read).map((s) => s.trim()).toList(),
          );
        } else {
          for (final nested in child.children ?? <md.Node>[]) {
            collect(nested);
          }
        }
      }

      collect(node);
      if (rows.isEmpty) return '';
      final header = rows.first;
      return '\n${rows.skip(1).map((row) => List.generate(row.length, (i) => i < header.length && header[i].isNotEmpty ? '${header[i]}: ${row[i]}' : row[i]).join('. ')).join('.\n')}\n';
    }
    final value = children.map(read).join();
    if (node.tag == 'pre') return '\nCode example. $value\n';
    if ([
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'blockquote',
      'br',
    ].contains(node.tag)) {
      return '$value\n';
    }
    return value;
  }

  return nodes
      .map(read)
      .join('\n')
      .replaceAllMapped(RegExp(r'(?:https?://|www\.)[^\s<>]+'), (match) {
        final value = match[0]!;
        final uri = Uri.tryParse(
          value.startsWith('www.') ? 'https://$value' : value,
        );
        return uri?.host.isNotEmpty == true
            ? 'link to ${uri!.host}'
            : 'link in the transcript';
      })
      .replaceAll(RegExp(r'[•●◆◇★☆✦✧]'), ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\s*\n\s*'), '\n')
      .trim();
}

/// Preserve sentence/word order and stay below Android's UTF-16 input bound.
List<String> speechSegments(String text, {int maxLength = 3000}) {
  if (maxLength < 2) throw ArgumentError.value(maxLength);
  final segments = <String>[];
  var remaining = text.trim();
  while (remaining.length > maxLength) {
    var end = maxLength;
    final candidate = remaining.substring(0, end);
    final boundaries =
        RegExp(r'[.!?](?:\s|$)|\n').allMatches(candidate).toList();
    if (boundaries.isNotEmpty && boundaries.last.end > maxLength ~/ 3) {
      end = boundaries.last.end;
    } else {
      final space = candidate.lastIndexOf(RegExp(r'\s'));
      if (space > maxLength ~/ 3) end = space;
    }
    final unit = remaining.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    segments.add(remaining.substring(0, end).trim());
    remaining = remaining.substring(end).trimLeft();
  }
  if (remaining.isNotEmpty) segments.add(remaining);
  return segments;
}
