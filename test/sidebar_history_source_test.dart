import 'dart:async';
import 'package:ai_chatbot/services/sidebar_history_source.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';

// SDK doubles exercise the production adapter's path, bound, cursor and owner
// checks. They do not claim live Firebase or security-rules validation.
class _Database implements FirebaseFirestore {
  final paths = <String>[];
  final limits = <int>[];
  final orders = <(Object, bool)>[];
  final cursors = <DocumentSnapshot>[];
  final snapshots = StreamController<QuerySnapshot<Map<String, dynamic>>>();
  bool includeMetadata = false;
  Completer<QuerySnapshot<Map<String, dynamic>>>? read;
  @override CollectionReference<Map<String, dynamic>> collection(String path) {
    paths.add(path); return _Collection(this, path);
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Collection implements CollectionReference<Map<String, dynamic>> {
  final _Database db;
  @override final String path;
  _Collection(this.db, this.path);
  @override DocumentReference<Map<String, dynamic>> doc([String? path]) {
    final full = '${this.path}/$path'; db.paths.add(full); return _Document(db, full);
  }
  @override Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    db.orders.add((field, descending)); return _Query(db);
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Document implements DocumentReference<Map<String, dynamic>> {
  final _Database db;
  @override final String path;
  _Document(this.db, this.path);
  @override CollectionReference<Map<String, dynamic>> collection(String path) {
    final full = '${this.path}/$path'; db.paths.add(full); return _Collection(db, full);
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Query implements Query<Map<String, dynamic>> {
  final _Database db;
  _Query(this.db);
  @override Query<Map<String, dynamic>> limit(int limit) { db.limits.add(limit); return this; }
  @override Query<Map<String, dynamic>> startAfterDocument(DocumentSnapshot snapshot) {
    db.cursors.add(snapshot); return this;
  }
  @override Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource}) {
    db.includeMetadata = includeMetadataChanges; return db.snapshots.stream;
  }
  @override Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) => db.read!.future;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class _Metadata implements SnapshotMetadata {
  @override final bool isFromCache;
  _Metadata(this.isFromCache);
  @override bool get hasPendingWrites => false;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Snapshot implements QuerySnapshot<Map<String, dynamic>> {
  @override final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  @override final SnapshotMetadata metadata;
  _Snapshot(this.docs, {bool cached = false}) : metadata = _Metadata(cached);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Doc implements QueryDocumentSnapshot<Map<String, dynamic>> {
  @override final String id;
  final Map<String, dynamic> value;
  _Doc(this.id, this.value);
  @override Map<String, dynamic> data() => value;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('owned title query is limited to 50 plus sentinel and paginates after last displayed document', () async {
    final session = FakeSession(); final db = _Database(); final source = FirebaseSidebarHistorySource(session, db);
    final pageFuture = source.watchRecent('alice').first;
    final date = DateTime(2026, 10, 27);
    final docs = List.generate(51, (i) => _Doc('id$i', {'title': 'Title $i', 'updatedAt': Timestamp.fromDate(date), 'type': 'chat'}));
    db.snapshots.add(_Snapshot(docs, cached: true)); final page = await pageFuture;
    expect(db.paths, ['users', 'users/alice', 'users/alice/chats']);
    expect(db.orders, [('updatedAt', true)]); expect(db.limits, [51]); expect(db.includeMetadata, true);
    expect(page.items.length, 50); expect(page.hasMore, true); expect(page.isFromCache, true);
    expect(page.items.first.updatedAt, date); expect(page.items.last.id, 'id49');
    db.read = Completer(); final older = source.loadOlder('alice', page.cursor!);
    expect(db.cursors.single, same(docs[49])); expect(db.limits, [51, 51]);
    db.read!.complete(_Snapshot([docs.last, _Doc('legacy', {'title': null, 'updatedAt': null})]));
    final result = await older; expect(result.hasMore, false); expect(result.items.first.id, 'id50');
    expect(result.items.last.title, 'Conversation'); expect(result.items.last.updatedAt, isNull);
    expect(db.paths.any((path) => path.contains('messages')), false);
    session.change('bob'); await expectLater(source.loadOlder('bob', page.cursor!), throwsStateError);
    session.dispose(); await db.snapshots.close();
  });

  test('owner is checked before storage and again after asynchronous snapshot delivery', () async {
    final session = FakeSession(); final db = _Database(); final source = FirebaseSidebarHistorySource(session, db);
    expect(() => source.watchRecent('bob'), throwsStateError); expect(db.paths, isEmpty);
    final pending = source.watchRecent('alice').first;
    final checked = expectLater(pending, throwsStateError);
    session.change('bob'); db.snapshots.add(_Snapshot([_Doc('private', {'title': 'Private'})])); await checked;
    session.dispose(); await db.snapshots.close();
  });

  test('late page is rejected on identity change and provider failure is propagated', () async {
    final session = FakeSession(); final db = _Database(); final source = FirebaseSidebarHistorySource(session, db);
    final first = source.watchRecent('alice').first;
    db.snapshots.add(_Snapshot([_Doc('a', {'title': 'A'})])); final page = await first;
    db.read = Completer(); final pending = source.loadOlder('alice', page.cursor!);
    final checked = expectLater(pending, throwsStateError);
    session.change('bob'); db.read!.complete(_Snapshot([])); await checked;
    session.change('alice'); db.read = Completer();
    final failure = expectLater(source.loadOlder('alice', page.cursor!), throwsStateError);
    db.read!.completeError(StateError('unavailable')); await failure;
    await expectLater(source.loadOlder('alice', 'invalid cursor'), throwsStateError);
    session.dispose(); await db.snapshots.close();
  });
}
