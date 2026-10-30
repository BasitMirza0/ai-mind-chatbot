import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'chat_trace_sink_stub.dart'
    if (dart.library.io) 'chat_trace_sink_io.dart'
    as sink;

/// No user/account IDs, message IDs, prompts, responses, tokens or exception
/// strings belong here. Correlation IDs are random per HTTP request.
class ChatTrace {
  final String state;
  final String? requestId, category, finishReason;
  final int characters;
  const ChatTrace(
    this.state, {
    this.requestId,
    this.category,
    this.finishReason,
    this.characters = 0,
  });
  Map<String, Object> get fields => {
    'state': _safe(state),
    if (requestId != null)
      'request_id': safeRequestId(requestId) ?? 'unassigned',
    if (category != null) 'category': _safe(category!),
    if (finishReason != null) 'finish_reason': _safe(finishReason!),
    'characters': characters,
  };
  static String _safe(String value) =>
      RegExp(r'^[a-z_]{1,48}$').hasMatch(value) ? value : 'unknown';
}

String? safeRequestId(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value) ? value : null;

void logChatTrace(ChatTrace trace) {
  // Debug acceptance evidence only; no unsolicited release telemetry.
  if (kDebugMode) {
    final record = jsonEncode(trace.fields);
    debugPrint('ai_mind_stream $record');
    // Opt-in acceptance journal for devices whose OEM disables logcat output.
    // Only the allowlisted metadata above reaches this sink.
    if (const bool.fromEnvironment('AI_MIND_TRACE_FILE')) {
      sink.writeTrace(record);
    }
  }
}

abstract interface class AiStreamDiagnostics {
  ValueListenable<ChatTrace> get streamTrace;
}
