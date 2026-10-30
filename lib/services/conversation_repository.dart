import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/conversation.dart';
import 'app_session.dart';
import 'sidebar_history_source.dart';

abstract interface class ConversationRepository {
  String newId();
  Stream<List<ConversationSummary>> watch(String uid);
  Future<List<ChatMessage>> load(String uid, String chatId);
  Future<ConversationSummary?> summary(String uid, String chatId);
  Future<void> create(String uid, String chatId, String title, {String type = 'chat'});
  Future<void> save(String uid, String chatId, ChatMessage message);
  Future<void> rename(String uid, String chatId, String title);
  Future<void> delete(String uid, String chatId);
}

/// Home/Chat adapter. Paths and fields match existing records and security rules.
/// Every operation captures its owner; it never switches paths after an await.
class FirebaseConversationRepository implements ConversationRepository, SidebarHistorySource {
  final AppSession session;
  final FirebaseFirestore db;
  FirebaseConversationRepository(this.session, {FirebaseFirestore? firestore})
      : db = firestore ?? FirebaseFirestore.instance;
  @override Stream<SidebarPage> watchRecent(String uid) =>
      FirebaseSidebarHistorySource(session, db).watchRecent(uid);
  @override Future<SidebarPage> loadOlder(String uid, Object cursor) =>
      FirebaseSidebarHistorySource(session, db).loadOlder(uid, cursor);
  void _owner(String uid) {
    if (session.uid != uid) throw StateError('Session changed');
  }
  CollectionReference<Map<String, dynamic>> _chats(String uid) {
    _owner(uid);
    return db.collection('users').doc(uid).collection('chats');
  }
  @override String newId() => db.collection('users').doc().id;
  @override Stream<List<ConversationSummary>> watch(String uid) => _chats(uid)
      .orderBy('updatedAt', descending: true).snapshots().map((snapshot) {
        _owner(uid);
        return snapshot.docs.map((doc) {
          final data = doc.data();
          return ConversationSummary(doc.id, data['title'] as String? ?? 'Conversation',
            type: data['type'] as String? ?? 'chat',
            updatedAt: (data['updatedAt'] as Timestamp?)?.toDate());
        }).toList();
      });
  @override Future<List<ChatMessage>> load(String uid, String chatId) async {
    final snapshot = await _chats(uid).doc(chatId).collection('messages')
        .orderBy('timestamp').get().timeout(const Duration(seconds: 15));
    _owner(uid);
    return snapshot.docs.map((d) => ChatMessage(id: d.id,
      role: d.data()['role'] as String? ?? 'bot', text: d.data()['text'] as String? ?? '', saved: true)).toList();
  }
  @override Future<ConversationSummary?> summary(String uid, String chatId) async {
    final snapshot = await _chats(uid).doc(chatId).get().timeout(const Duration(seconds: 15));
    _owner(uid);
    final data = snapshot.data();
    if (data == null) return null;
    return ConversationSummary(chatId, data['title'] as String? ?? 'Conversation',
      type: data['type'] as String? ?? 'chat',
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate());
  }
  @override Future<void> create(String uid, String chatId, String title, {String type = 'chat'}) async {
    final ref = _chats(uid).doc(chatId);
    await db.runTransaction((tx) async {
      final existing = await tx.get(ref);
      _owner(uid);
      if (!existing.exists) {
        tx.set(ref, {'title': title, 'type': type,
          'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()});
      }
    }).timeout(const Duration(seconds: 15));
  }
  @override Future<void> save(String uid, String chatId, ChatMessage message) async {
    final chat = _chats(uid).doc(chatId);
    final ref = chat.collection('messages').doc(message.id);
    // Stable IDs plus read-before-create allow safe retries, including an
    // ambiguous timeout. Existing immutable messages are never overwritten.
    await db.runTransaction((tx) async {
      final existing = await tx.get(ref);
      _owner(uid);
      if (existing.exists) {
        if (existing.data()?['role'] != message.role || existing.data()?['text'] != message.text) {
          throw StateError('Message identifier conflict');
        }
        return;
      }
      tx.set(ref, {'role': message.role, 'text': message.text,
        'timestamp': FieldValue.serverTimestamp()});
      tx.update(chat, {'updatedAt': FieldValue.serverTimestamp()});
    }).timeout(const Duration(seconds: 15));
  }
  @override Future<void> rename(String uid, String chatId, String title) =>
      _chats(uid).doc(chatId).update({'title': title,
        'updatedAt': FieldValue.serverTimestamp()}).timeout(const Duration(seconds: 15));
  @override Future<void> delete(String uid, String chatId) async {
    final chat = _chats(uid).doc(chatId);
    // Bound batches for large legacy conversations. No data is deleted without
    // an explicit UI confirmation. Interrupted deletions can be retried.
    while (true) {
      _owner(uid);
      final page = await chat.collection('messages').limit(400).get()
          .timeout(const Duration(seconds: 15));
      _owner(uid);
      if (page.docs.isEmpty) break;
      final batch = db.batch();
      for (final doc in page.docs) { batch.delete(doc.reference); }
      await batch.commit().timeout(const Duration(seconds: 15));
    }
    _owner(uid);
    await chat.delete().timeout(const Duration(seconds: 15));
  }
}
