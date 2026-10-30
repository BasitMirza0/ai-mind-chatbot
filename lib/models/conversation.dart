import 'dart:typed_data';

enum ReplyState { complete, streaming, stopped, failed, truncated }

class ChatMessage {
  final String id;
  final String role;
  String text;
  final Uint8List? image;
  bool saved;
  ReplyState state;
  String? requestId, failureCode;
  // Account-scoped, memory-only snapshots of explicitly retried attempts.
  final List<String> previousAttempts = [];
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.image,
    this.saved = false,
    this.state = ReplyState.complete,
  });
  Map<String, dynamic> get api => {'role': role, 'text': text};
}

class ConversationSummary {
  final String id;
  final String title;
  final String type;
  final DateTime? updatedAt;
  const ConversationSummary(
    this.id,
    this.title, {
    this.type = 'chat',
    this.updatedAt,
  });
}

class Conversation {
  final String id;
  String title;
  final List<ChatMessage> messages;
  String draft = '';
  Uint8List? attachment;
  String? error;
  String? notice;
  String? contextNotice;
  bool created;
  Conversation(
    this.id, {
    this.title = 'New conversation',
    this.created = false,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];
  bool get hasUnsaved =>
      draft.isNotEmpty ||
      attachment != null ||
      messages.any((m) => !m.saved && m.text.isNotEmpty);
}
