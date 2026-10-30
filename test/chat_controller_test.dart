import 'dart:async';
import 'dart:typed_data';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/backend_api_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';

void main() {
  late FakeSession session;
  late FakeRepository repository;
  late FakeAi ai;
  late ChatController chat;
  setUp(() {
    session = FakeSession(); repository = FakeRepository(); ai = FakeAi();
    chat = ChatController(ai: ai, repository: repository, currentUid: () => session.uid);
  });
  tearDown(() async { chat.dispose(); session.dispose(); await ai.close(); });
  Future<void> answer(String text) async { ai.streams.last.add(text); await ai.streams.last.close(); await tick(); }

  test('double send during conversation creation creates one user and request', () async {
    repository.createGate = Completer<void>(); chat.setDraft('Hello');
    final pending = chat.send(); await chat.send();
    expect(chat.conversation.messages.where((m) => m.role == 'user').length, 1);
    repository.createGate!.complete(); await tick();
    expect(ai.streams.length, 1); await answer('Hi'); await pending;
    expect(repository.writes.length, 2); expect(chat.busy, false);
  });
  test('late stream cannot overwrite new chat; previous turn and draft are retained', () async {
    chat.setDraft('First'); final request = chat.send(); await tick();
    final old = chat.conversation; ai.streams.last.add('Partial'); await tick();
    chat.setDraft('Unsent draft'); chat.newConversation();
    ai.streams.last.add('stale'); await request;
    expect(chat.conversation.messages, isEmpty);
    await chat.open(old.id);
    expect(chat.conversation.draft, 'Unsent draft');
    expect(old.messages.last.text, 'Partial');
    expect(old.messages.last.state, ReplyState.stopped);
    expect(repository.writes.length, 1);
  });
  test('switching preserves attachments without putting raw images in storage', () async {
    chat.attach(Uint8List.fromList([1,2,3])); final id = chat.conversation.id;
    chat.newConversation(); await chat.open(id);
    expect(chat.conversation.attachment, [1,2,3]); expect(repository.writes, isEmpty);
  });
  test('out-of-order loads cannot replace the most recently chosen conversation', () async {
    repository.loads['a'] = Completer(); repository.loads['b'] = Completer();
    final a = chat.open('a'); final b = chat.open('b');
    repository.loads['b']!.complete([ChatMessage(id:'b1',role:'user',text:'B',saved:true)]); await b;
    repository.loads['a']!.complete([ChatMessage(id:'a1',role:'user',text:'A',saved:true)]); await a;
    expect(chat.conversation.id,'b'); expect(chat.loading,false);
  });
  test('send is blocked during loading and load failure preserves old draft', () async {
    chat.setDraft('Keep me'); repository.loads['a'] = Completer();
    final pending = chat.open('a'); await chat.send(); expect(ai.streams,isEmpty);
    repository.loads['a']!.completeError(StateError('offline')); await pending;
    expect(chat.loading,false); expect(chat.loadError,isNotNull); expect(chat.conversation.draft,'Keep me');
  });
  test('provider failure is not persisted; retry reuses saved user ID', () async {
    chat.setDraft('Question'); final first = chat.send(); await tick();
    final userId=chat.conversation.messages.first.id;
    ai.streams.last.add('Partial'); ai.streams.last.addError(const BackendApiException('offline','Backend unavailable'));
    await first; expect(chat.busy,false); expect(repository.writes.length,1);
    expect(chat.conversation.error,'Backend unavailable');
    final retry=chat.retry(); await tick(); await answer('Complete'); await retry;
    expect(repository.writes.length,2); expect(chat.conversation.messages.first.id,userId);
    expect(chat.conversation.messages.length,2);
    expect(repository.records.values.single.last.text,'Complete');
  });
  test('stop cancels transport and preserves partial text without saving it', () async {
    chat.setDraft('Question'); final request = chat.send(); await tick();
    ai.streams.last.add('Partial'); await tick(); chat.stop(); await request;
    expect(ai.cancellations,1); expect(chat.busy,false); expect(chat.conversation.messages.last.text,'Partial');
    expect(repository.writes.length,1); expect(chat.conversation.notice,isNotNull);
  });
  test('stop while a user write completes never writes into the next chat', () async {
    repository.saveGate=Completer(); chat.setDraft('Keep this'); final request=chat.send(); await tick();
    final old=chat.conversation; chat.newConversation(); repository.saveGate!.complete(); await request;
    expect(repository.writes.single.$2,old.id); expect(old.messages.first.saved,true);
    expect(chat.conversation.messages,isEmpty); expect(ai.streams,isEmpty);
  });
  test('account change cancels work, clears private drafts and blocks stale save', () async {
    chat.setDraft('Private'); final request=chat.send(); await tick();
    session.change('bob'); chat.sessionChanged(); ai.streams.last.add('Stale secret'); await request;
    expect(chat.conversation.messages,isEmpty); expect(chat.localConversations,isEmpty);
    expect(repository.writes.every((w) => w.$1=='alice'),true); expect(chat.busy,false);
  });
  test('session change during create cannot issue provider request or cross-user write', () async {
    repository.createGate=Completer(); chat.setDraft('Private'); final request=chat.send();
    session.change('bob'); chat.sessionChanged(); repository.createGate!.complete(); await request;
    expect(ai.streams,isEmpty); expect(repository.writes,isEmpty);
  });
  test('save failure retains answer; save retry does not request AI again', () async {
    repository.failBotSave=true; chat.setDraft('Question'); final request=chat.send(); await tick();
    await answer('Keep this answer'); await request;
    expect(chat.conversation.messages.last.text,'Keep this answer'); expect(chat.conversation.messages.last.saved,false);
    expect(chat.busy,false); expect(chat.saving,false);
    repository.failBotSave=false; await chat.retry();
    expect(ai.streams.length,1); expect(chat.conversation.messages.last.saved,true);
    expect(repository.writes.length,2);
  });
  test('failed create keeps user input and uses same IDs on retry', () async {
    repository.failCreate=true; chat.setDraft('Do not lose'); await chat.send();
    final ids=chat.conversation.messages.map((m)=>m.id).toList();
    expect(chat.busy,false); expect(chat.conversation.messages.first.text,'Do not lose');
    repository.failCreate=false; final retry=chat.retry(); await tick(); await answer('Done'); await retry;
    expect(chat.conversation.messages.first.id,ids.first); expect(repository.created.length,1);
  });
  test('regenerate appends a turn, preserving original response and IDs', () async {
    chat.setDraft('Question'); final request=chat.send(); await tick(); await answer('Original'); await request;
    final original=chat.conversation.messages.last;
    final regenerate=chat.regenerate(); await tick(); await answer('Alternative'); await regenerate;
    expect(chat.conversation.messages.length,4); expect(chat.conversation.messages[1],same(original));
    expect(repository.writes.length,4);
  });
  test('image cancellation rejects late result and clears loading', () async {
    ai.imageGate=Completer(); chat.attach(Uint8List.fromList([1,2,3])); final request=chat.send(); await tick();
    chat.stop(); ai.imageGate!.complete('Late image result'); await request;
    expect(chat.busy,false); expect(repository.writes.length,1);
    expect(chat.conversation.messages.last.state,ReplyState.stopped);
  });
  test('guests never issue AI or storage writes', () async {
    session.change(null); chat.sessionChanged(); chat.setDraft('Hello'); await chat.send();
    expect(ai.streams,isEmpty); expect(repository.writes,isEmpty); expect(chat.conversation.draft,'Hello');
  });
  test('dispose during stream causes no notification or response write', () async {
    chat.setDraft('Hello'); final pending=chat.send(); await tick();
    var notifications=0; chat.addListener(()=>notifications++);
    chat.dispose(); final count=notifications; ai.streams.last.add('late'); await pending;
    expect(notifications,count); expect(repository.writes.length,1);
    // Replace the disposed instance for common teardown.
    chat=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
  });
  test('guest draft survives sign-in without transferring a previous user session', () async {
    session.change(null); chat.sessionChanged(); chat.setDraft('Draft before sign-in');
    session.change('bob'); chat.sessionChanged();
    expect(chat.conversation.draft,'Draft before sign-in');
    session.change('carol'); chat.sessionChanged(); expect(chat.conversation.draft,isEmpty);
  });
  test('long histories use bounded recent context without changing saved records', () async {
    for(var i=0;i<80;i++) {
      chat.conversation.messages.add(ChatMessage(id:'legacy-$i',role:i.isEven?'user':'bot',text:'Earlier turn $i',saved:true));
    }
    chat.conversation.created=true; chat.setDraft('Latest question');
    final pending=chat.send();await tick();
    expect(ai.histories.single.length,64);
    expect(ai.histories.single.last['text'],'Latest question');
    expect(chat.conversation.contextNotice,isNotNull);
    await answer('Fresh reply');await pending;
    expect(chat.conversation.messages.length,82);
    expect(chat.conversation.messages.first.id,'legacy-0');
  });
  test('overlong input is rejected before persistence or provider calls', () async {
    chat.setDraft('x' * 12001);await chat.send();
    expect(repository.writes,isEmpty);expect(ai.streams,isEmpty);
    expect(chat.conversation.draft.length,12001);expect(chat.conversation.error,isNotNull);
  });
  test('retrying a later failed turn retains an earlier stopped partial reply', () async {
    chat.setDraft('First');final first=chat.send();await tick();
    ai.streams.last.add('Earlier partial');await tick();chat.stop();await first;
    final partial=chat.conversation.messages.last;
    chat.setDraft('Second');final second=chat.send();await tick();ai.streams.last.addError(StateError('offline'));await second;
    final retry=chat.retry();await tick();await answer('Second answer');await retry;
    expect(chat.conversation.messages,contains(partial));expect(partial.text,'Earlier partial');
  });

}
