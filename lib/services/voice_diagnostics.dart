import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'voice_trace_sink_stub.dart'
    if (dart.library.io) 'voice_trace_sink_io.dart'
    as sink;

/// Content-free debug evidence. Never accepts transcripts, account IDs or tokens.
void traceVoice(
  String state, {
  required int elapsedMs,
  int characters = 0,
  String? category,
  String? requestId,
}) {
  if (!kDebugMode) return;
  String safe(String value) =>
      RegExp(r'^[a-z_]{1,48}$').hasMatch(value) ? value : 'unknown';
  final record = jsonEncode({
    'state': safe(state),
    'elapsed_ms': elapsedMs,
    'characters': characters,
    if (category != null) 'category': safe(category),
    if (requestId != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId))
      'request_id': requestId,
  });
  debugPrint('ai_mind_voice $record');
  if (const bool.fromEnvironment('AI_MIND_TRACE_FILE')) {
    sink.writeVoiceTrace(record);
  }
}
