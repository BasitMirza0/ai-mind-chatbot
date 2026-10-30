import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/conversation.dart';
import 'app_session.dart';

/// Read-only, bounded title history. No message contents are fetched for search.
abstract interface class SidebarHistorySource {
  Stream<SidebarPage> watchRecent(String uid);
  Future<SidebarPage> loadOlder(String uid, Object cursor);
}

class SidebarPage {
  final List<ConversationSummary> items;
  final Object? cursor;
  final bool hasMore, isFromCache;
  const SidebarPage(this.items, {this.cursor, this.hasMore = false,
    this.isFromCache = false});
}

class _Cursor {
  final String uid;
  final DocumentSnapshot<Map<String, dynamic>> document;
  const _Cursor(this.uid, this.document);
}

class FirebaseSidebarHistorySource implements SidebarHistorySource {
  static const pageSize = 50;
  final AppSession session;
  final FirebaseFirestore db;
  FirebaseSidebarHistorySource(this.session, this.db);

  void _owner(String uid) {
    if (session.uid != uid) throw StateError('Session changed');
  }

  Query<Map<String, dynamic>> _query(String uid) {
    _owner(uid);
    return db.collection('users').doc(uid).collection('chats')
      .orderBy('updatedAt', descending: true);
  }

  SidebarPage _page(String uid, QuerySnapshot<Map<String, dynamic>> snapshot) {
    _owner(uid);
    final docs = snapshot.docs.take(pageSize).toList();
    return SidebarPage(docs.map((doc) {
      final data = doc.data();
      final title = data['title'];
      final type = data['type'];
      final date = data['updatedAt'];
      return ConversationSummary(doc.id,
        title is String && title.trim().isNotEmpty ? title : 'Conversation',
        type: type is String ? type : 'chat',
        updatedAt: date is Timestamp ? date.toDate() : null);
    }).toList(), cursor: docs.isEmpty ? null : _Cursor(uid, docs.last),
      hasMore: snapshot.docs.length > pageSize,
      isFromCache: snapshot.metadata.isFromCache);
  }

  @override
  Stream<SidebarPage> watchRecent(String uid) => _query(uid)
    .limit(pageSize + 1).snapshots(includeMetadataChanges: true)
    .map((snapshot) => _page(uid, snapshot));

  @override
  Future<SidebarPage> loadOlder(String uid, Object cursor) async {
    if (cursor is! _Cursor || cursor.uid != uid) {
      throw StateError('Invalid history cursor');
    }
    final snapshot = await _query(uid).startAfterDocument(cursor.document)
      .limit(pageSize + 1).get().timeout(const Duration(seconds: 15));
    return _page(uid, snapshot);
  }
}
