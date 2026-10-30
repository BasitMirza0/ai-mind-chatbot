import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // Save a new chat session
  Future<String> createChat(String firstMessage, {String type = 'chat'}) async {
    final uid = _uid;
    if (uid == null) return '';
    final doc = await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .add({
      'title': firstMessage.length > 40
          ? '${firstMessage.substring(0, 40)}...'
          : firstMessage,
      'type': type,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  // Save message to a chat
  Future<void> saveMessage(
      String chatId, String role, String text) async {
    final uid = _uid;
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add({
      'role': role,
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
    });
    await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .update({'updatedAt': FieldValue.serverTimestamp()});
  }

  // Get all chats for sidebar
  Stream<List<Map<String, dynamic>>> getChats() {
    final uid = _uid;
    if (uid == null) return Stream.value([]);
    return _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .toList());
  }

  // Get messages for a chat
  Future<List<Map<String, dynamic>>> getMessages(String chatId) async {
    final uid = _uid;
    if (uid == null) return [];
    final snap = await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp')
        .get();
    return snap.docs
        .map((doc) => {
      'role': doc['role'] as String,
      'text': doc['text'] as String,
    })
        .toList();
  }

  // Delete a chat and all its messages
  Future<void> deleteChat(String chatId) async {
    final uid = _uid;
    if (uid == null) return;
    // Delete all messages in parallel, then the chat document.
    final messages = await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .get();
    await Future.wait(messages.docs.map((doc) => doc.reference.delete()));
    await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .delete();
  }

  // Rename a chat
  Future<void> renameChat(String chatId, String newTitle) async {
    final uid = _uid;
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .update({
      'title': newTitle,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Update chat title from first message
  Future<void> updateChatTitle(
      String chatId, String firstMessage) async {
    final uid = _uid;
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .update({
      'title': firstMessage.length > 40
          ? '${firstMessage.substring(0, 40)}...'
          : firstMessage,
    });
  }
}