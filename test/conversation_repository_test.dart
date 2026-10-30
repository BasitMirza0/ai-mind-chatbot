import 'dart:async';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/conversation_repository.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';

// Small transaction double tests the real adapter's paths, immutable schema and
// read-before-create behavior. It is not an emulator or a security-rules test.
class _Database implements FirebaseFirestore {
  final records=<String,Map<String,dynamic>>{};
  final sets=<String>[];
  Completer<void>? readGate;
  @override CollectionReference<Map<String,dynamic>> collection(String path)=>_Collection(this,path);
  @override Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout=const Duration(seconds:30),int maxAttempts=5})=>handler(_Transaction(this));
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
// Intentional isolated test double for the SDK adapter.
// ignore: subtype_of_sealed_class
class _Collection implements CollectionReference<Map<String,dynamic>> {
  final _Database db;
  @override final String path;
  _Collection(this.db,this.path);
  @override DocumentReference<Map<String,dynamic>> doc([String? path])=>_Document(db,'${this.path}/${path ?? 'generated'}');
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Document implements DocumentReference<Map<String,dynamic>> {
  final _Database db;
  @override final String path;
  _Document(this.db,this.path);
  @override CollectionReference<Map<String,dynamic>> collection(String path)=>_Collection(db,'${this.path}/$path');
  @override String get id=>path.split('/').last;
  @override Future<DocumentSnapshot<Map<String,dynamic>>> get([GetOptions? options]) async {
    if(db.readGate!=null)await db.readGate!.future;
    return _Snapshot<Map<String,dynamic>>(db.records[path]);
  }
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
// ignore: subtype_of_sealed_class
class _Snapshot<T> implements DocumentSnapshot<T> {
  final T? value;
  _Snapshot(this.value);
  @override bool get exists=>value!=null;
  @override T? data()=>value;
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Transaction implements Transaction {
  final _Database db;
  _Transaction(this.db);
  @override Future<DocumentSnapshot<T>> get<T extends Object?>(DocumentReference<T> ref) async {
    if(db.readGate!=null)await db.readGate!.future;
    return _Snapshot<T>(db.records[ref.path] as T?);
  }
  @override Transaction set<T>(DocumentReference<T> ref,T data,[SetOptions? options]) {
    db.records[ref.path]=Map<String,dynamic>.from(data as Map);db.sets.add(ref.path);return this;
  }
  @override Transaction update(DocumentReference ref,Map<Object,Object?> data) {
    db.records[ref.path]!.addAll(data.map((k,v)=>MapEntry(k.toString(),v)));return this;
  }
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main() {
  late FakeSession session;late _Database db;late FirebaseConversationRepository repository;
  setUp(() {session=FakeSession();db=_Database();repository=FirebaseConversationRepository(session,firestore:db);});
  tearDown(()=>session.dispose());
  test('saved summary restores renamed title and checks owner after read',()async {
    db.records['users/alice/chats/chat']={'title':'A renamed title','type':'chat','updatedAt':Timestamp.fromDate(DateTime(2026,10,28))};
    final summary=await repository.summary('alice','chat');
    expect(summary!.title,'A renamed title');expect(summary.updatedAt,DateTime(2026,10,28));
    await expectLater(repository.summary('bob','chat'),throwsStateError);
    db.readGate=Completer();final pending=repository.summary('alice','chat');
    session.change('bob');db.readGate!.complete();await expectLater(pending,throwsStateError);
  });
  test('stable IDs preserve legacy paths and rule-compatible append-only fields',()async {
    await repository.create('alice','chat','Title');
    final message=ChatMessage(id:'message',role:'user',text:'Hello');
    await repository.save('alice','chat',message);
    expect(db.records.keys,containsAll(['users/alice/chats/chat','users/alice/chats/chat/messages/message']));
    expect(db.records['users/alice/chats/chat']!.keys,unorderedEquals(['title','type','createdAt','updatedAt']));
    expect(db.records['users/alice/chats/chat/messages/message']!.keys,unorderedEquals(['role','text','timestamp']));
    expect(db.records['users/alice/chats/chat/messages/message']!['timestamp'],isA<FieldValue>());
  });
  test('voice preserves the existing type and user-scoped conversation schema',()async {
    await repository.create('alice','voice','A spoken thought',type:'voice');
    expect(db.records['users/alice/chats/voice']!['type'],'voice');
    expect(db.records['users/alice/chats/voice']!.keys,unorderedEquals(['title','type','createdAt','updatedAt']));
  });
  test('ambiguous write retry never creates a duplicate or updates an immutable message',()async {
    await repository.create('alice','chat','Original');await repository.create('alice','chat','Replacement');
    final message=ChatMessage(id:'stable',role:'bot',text:'Keep this answer');
    await repository.save('alice','chat',message);await repository.save('alice','chat',message);
    expect(db.sets.length,2);expect(db.records['users/alice/chats/chat']!['title'],'Original');
    await expectLater(repository.save('alice','chat',ChatMessage(id:'stable',role:'bot',text:'Changed')),throwsStateError);
    expect(db.records['users/alice/chats/chat/messages/stable']!['text'],'Keep this answer');
  });
  test('mismatched owner is rejected before touching storage',()async {
    await expectLater(repository.create('bob','chat','Title'),throwsStateError);
    expect(db.records,isEmpty);
  });
  test('account change while a transaction reads cannot redirect or commit the write',()async {
    db.readGate=Completer();final pending=repository.create('alice','chat','Private');
    session.change('bob');db.readGate!.complete();await expectLater(pending,throwsStateError);
    expect(db.records,isEmpty);
  });
}
