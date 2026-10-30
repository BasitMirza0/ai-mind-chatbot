import 'dart:convert';

/// Frame before decoding JSON. Limits apply during buffering, not after an
/// unbounded LineSplitter has accumulated a newline-free response.
Stream<({String event, String data})> decodeBackendSse(
    Stream<List<int>> chunks, {int maxEventBytes = 65536}) async* {
  final line = <int>[];
  final data = <String>[];
  var event = '', size = 0;
  var previousCr = false;
  await for (final chunk in chunks) {
    for (final byte in chunk) {
      if (byte == 10 && previousCr) {
        previousCr = false;
        continue;
      }
      previousCr = byte == 13;
      if (byte != 10 && byte != 13) {
        line.add(byte);
        if (++size > maxEventBytes) {
          throw const FormatException('Oversized SSE event');
        }
        continue;
      }
      final value = utf8.decode(line);
      line.clear();
      if (value.isEmpty) {
        if (data.isNotEmpty) yield (event: event, data: data.join('\n'));
        data.clear(); event = ''; size = 0;
      } else if (value.startsWith('data:')) {
        final field = value.substring(5);
        data.add(field.startsWith(' ') ? field.substring(1) : field);
      } else if (value.startsWith('event:')) {
        event = value.substring(6).trim();
      }
    }
  }
  // No blank-line boundary means the final event was truncated.
}
