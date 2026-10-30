import 'dart:io';

Future<void> _pending = Future.value();
void writeVoiceTrace(String record) {
  _pending = _pending.then((_) async {
    try {
      final file = File('${Directory.systemTemp.path}/ai-mind-voice.jsonl');
      final rotate = await file.exists() && await file.length() > 65536;
      await file.writeAsString(
        '$record\n',
        mode: rotate ? FileMode.write : FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      /* Diagnostics never affect a voice turn. */
    }
  });
}
