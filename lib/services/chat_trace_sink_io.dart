import 'dart:io';

Future<void> _pending = Future<void>.value();

/// Debug-only, opt-in, bounded metadata journal in the OS temporary cache.
/// Failure must never affect generation or persistence.
void writeTrace(String record) {
  _pending = _pending.then((_) async {
    try {
      final file = File('${Directory.systemTemp.path}/ai-mind-stream.jsonl');
      final rotate = await file.exists() && await file.length() > 65536;
      await file.writeAsString(
        '$record\n',
        mode: rotate ? FileMode.write : FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      // Observability must not become a chat failure.
    }
  });
}
