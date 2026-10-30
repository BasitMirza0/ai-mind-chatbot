import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/home_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/chat_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/visual_capture.dart';

Widget shell(Widget screen, {double scale=1, double keyboard=0, bool reduced=true}) => MaterialApp(
  theme: AppTheme.legacy, builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
    textScaler: TextScaler.linear(scale), disableAnimations: reduced,
    viewInsets: EdgeInsets.only(bottom: keyboard)), child: child!), home: screen);
void viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize=size; tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
}
void main() {
  setUpAll(loadPreviewFonts);
  for (final size in [const Size(360,800), const Size(393,852), const Size(430,932), const Size(852,393)]) {
    for (final scale in [1.0,2.0]) {
      testWidgets('Home/Chat fit $size at text $scale with long names and messages', (tester) async {
        viewport(tester,size);
        final session=FakeSession(displayName:'Alexandria Morgan with a very long display name');
        final repository=FakeRepository()..summaries=[const ConversationSummary('saved','A long conversation title about thoughtful writing and finding clarity')];
        final ai=FakeAi();
        final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
        addTearDown(() {controller.dispose();session.dispose();ai.close();});
        await tester.pumpWidget(shell(HomeScreen(session:session,repository:repository),scale:scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(),isNull);
        await tester.scrollUntilVisible(find.text('Your conversations'),250,scrollable:find.byType(Scrollable).first);
        expect(tester.takeException(),isNull);
        controller.conversation.messages.addAll([
          ChatMessage(id:'u',role:'user',text:'How can I make room for a creative project?',saved:true),
          ChatMessage(id:'b',role:'bot',text:'## Start small\n\nChoose one meaningful step.\n\n- Set aside 15 minutes.\n- Keep a note of your ideas.\n\n```dart\nfinal idea = "A very long code line that should be scrollable without overflowing the screen";\n```\n\n[Read more](https://example.com)\n\n${'A thoughtful explanation. ' * 70}',saved:true),
        ]);
        await tester.pumpWidget(shell(ChatScreen(session:session,repository:repository,controller:controller),scale:scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(shell(ChatScreen(session:session,repository:repository,controller:controller),scale:scale,keyboard: size.height<500 ? 190 : 310));
        await tester.pumpAndSettle();
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('Home actions route to Chat, Voice, History and sign-in; prompt remains a draft', (tester) async {
    viewport(tester,const Size(393,852));
    final session=FakeSession(); final repository=FakeRepository();
    addTearDown(session.dispose);
    Widget destination(String text)=>Scaffold(appBar:AppBar(),body:Text(text));
    String? prompt;
    await tester.pumpWidget(shell(HomeScreen(session:session,repository:repository,
      chatBuilder:(p,id){prompt=p;return destination('Chat destination');},
      voiceBuilder:(_)=>destination('Voice destination'),historyBuilder:(_)=>destination('History destination'),
      loginBuilder:(_)=>destination('Login destination'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Let’s talk'));await tester.pumpAndSettle();expect(find.text('Chat destination'),findsOneWidget);
    await tester.pageBack();await tester.pumpAndSettle();
    await tester.tap(find.text('Use your voice'));await tester.pumpAndSettle();expect(find.text('Voice destination'),findsOneWidget);
    await tester.pageBack();await tester.pumpAndSettle();
    await tester.tap(find.text('Find the words'));await tester.pumpAndSettle();expect(prompt,'Help me write a thoughtful message.');
    await tester.pageBack();await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View all'));await tester.tap(find.text('View all'));await tester.pumpAndSettle();expect(find.text('History destination'),findsOneWidget);
    await tester.pageBack();await tester.pumpAndSettle();session.change(null);await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in').first);await tester.tap(find.text('Sign in').first);await tester.pumpAndSettle();expect(find.text('Login destination'),findsOneWidget);
  });
  testWidgets('history loading, empty and offline states are distinct', (tester) async {
    final session=FakeSession();addTearDown(session.dispose);
    final pending=StreamController<List<ConversationSummary>>();addTearDown(pending.close);
    final repository=FakeRepository()..history=pending.stream;
    await tester.pumpWidget(shell(HomeScreen(session:session,repository:repository)));
    await tester.pump();await tester.ensureVisible(find.text('Loading conversations…'));expect(find.text('Your next idea starts here'),findsNothing);
    pending.add([]);await tester.pumpAndSettle();expect(find.text('Your next idea starts here'),findsOneWidget);
    pending.addError(StateError('offline'));await tester.pumpAndSettle();expect(find.text('History is unavailable'),findsOneWidget);
    expect(find.text('Retry'),findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('deleting from Home requires confirmation', (tester) async {
    final session=FakeSession(); final repository=FakeRepository()..summaries=[const ConversationSummary('a','Saved idea')];
    addTearDown(session.dispose);
    await tester.pumpWidget(shell(HomeScreen(session:session,repository:repository)));await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Delete conversation Saved idea'));await tester.tap(find.byTooltip('Delete conversation Saved idea'));await tester.pumpAndSettle();
    expect(repository.deleted,isEmpty);await tester.tap(find.text('Keep'));await tester.pumpAndSettle();expect(repository.deleted,isEmpty);
    await tester.tap(find.byTooltip('Delete conversation Saved idea'));await tester.pumpAndSettle();await tester.tap(find.text('Delete'));await tester.pumpAndSettle();
    expect(repository.deleted,['a']);
  });
  testWidgets('Chat send/stop/retry and New Chat retain drafts; guests route to sign in', (tester) async {
    viewport(tester,const Size(393,852));
    final session=FakeSession();final repository=FakeRepository();final ai=FakeAi();
    final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    await tester.pumpWidget(shell(ChatScreen(session:session,controller:controller,
      loginBuilder:(_)=>const Scaffold(body:Text('Sign in destination')))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-input')),'Question');await tester.pump();
    await tester.tap(find.byTooltip('Send message'));await tester.pump();await tester.pump();
    expect(ai.streams.length,1);ai.streams.last.add('Working on it');await tester.pump();
    await tester.tap(find.byTooltip('Stop generating'));await tester.pumpAndSettle();expect(controller.busy,false);
    await tester.ensureVisible(find.text('Retry response'));await tester.tap(find.text('Retry response'));await tester.pump();await tester.pump();
    expect(ai.streams.length,2);ai.streams.last.add('Complete');await ai.streams.last.close();await tester.pumpAndSettle();
    expect(find.text('Complete'),findsOneWidget);
    await tester.enterText(find.byKey(const Key('chat-input')),'Draft for later');final id=controller.conversation.id;
    await tester.tap(find.byTooltip('New chat'));await tester.pumpAndSettle();expect(controller.conversation.messages,isEmpty);
    await controller.open(id);await tester.pumpAndSettle();expect(find.text('Draft for later'),findsOneWidget);
    session.change(null);await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-input')),'Guest question');await tester.pump();
    await tester.tap(find.byTooltip('Sign in to send'));await tester.pumpAndSettle();expect(find.text('Sign in destination'),findsOneWidget);
    expect(ai.streams.length,2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Back confirms unsaved draft and animation disposal is safe', (tester) async {
    final session=FakeSession();final repository=FakeRepository();final ai=FakeAi();
    final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    await tester.pumpWidget(MaterialApp(theme:AppTheme.light,home:Builder(builder:(ctx)=>Scaffold(body:TextButton(
      onPressed:()=>Navigator.push(ctx,MaterialPageRoute<void>(builder:(_)=>ChatScreen(session:session,controller:controller))),child:const Text('Open'))))));
    await tester.tap(find.text('Open'));await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-input')),'Do not discard silently');
    await tester.tap(find.byTooltip('Back to previous screen'));await tester.pumpAndSettle();expect(find.text('Leave this chat?'),findsOneWidget);
    await tester.tap(find.text('Keep chatting'));await tester.pumpAndSettle();expect(find.text('Do not discard silently'),findsOneWidget);
    await tester.tap(find.byTooltip('Back to previous screen'));await tester.pumpAndSettle();await tester.tap(find.text('Leave'));await tester.pumpAndSettle();
    expect(find.text('Open'),findsOneWidget);expect(tester.takeException(),isNull);
  });
  testWidgets('copy copies text and external links require confirmation', (tester) async {
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform,(call) async {
      if(call.method=='Clipboard.setData')clipboard=(call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(()=>messenger.setMockMethodCallHandler(SystemChannels.platform,null));
    await tester.pumpWidget(MaterialApp(theme:AppTheme.light,home:Scaffold(body:ChatMessageCard(message:ChatMessage(id:'a',role:'bot',text:'A clear answer.',saved:true)))));
    await tester.tap(find.byTooltip('Copy message'));await tester.pumpAndSettle();expect(clipboard,'A clear answer.');
    final ctx=tester.element(find.byType(ChatMessageCard));
    Uri? opened;final pending=openChatLink(ctx,'https://example.com/ideas',launcher:(uri)async{opened=uri;return true;});
    await tester.pumpAndSettle();expect(opened,isNull);await tester.tap(find.text('Open website'));await tester.pumpAndSettle();await pending;
    expect(opened.toString(),'https://example.com/ideas');
    for(final link in ['javascript:alert(1)','file:///secret','intent://open','https://user:pass@example.com']) { expect(safeChatLink(Uri.tryParse(link)),false); }
  });
  testWidgets('Home and Chat satisfy labeled target and Android touch guidelines', (tester) async {
    viewport(tester,const Size(393,852));final semantics=tester.ensureSemantics();
    final session=FakeSession(user:null);final repository=FakeRepository();final ai=FakeAi();
    final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    for(final screen in [HomeScreen(session:session,repository:repository),ChatScreen(session:session,controller:controller)]) {
      await tester.pumpWidget(shell(screen));await tester.pumpAndSettle();
      await expectLater(tester,meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester,meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester,meetsGuideline(textContrastGuideline));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });
  testWidgets('streaming does not pull the reader away from earlier messages', (tester) async {
    viewport(tester,const Size(393,852));
    final session=FakeSession();final repository=FakeRepository();final ai=FakeAi();
    final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    controller.conversation.created=true;
    for(var i=0;i<12;i++) {
      controller.conversation.messages.add(ChatMessage(id:'old-$i',role:i.isEven?'user':'bot',text:'Earlier message $i. ${'More detail. '*20}',saved:true));
    }
    await tester.pumpWidget(shell(ChatScreen(session:session,controller:controller)));
    await tester.pumpAndSettle();
    controller.setDraft('New question');final pending=controller.send();await tester.pump();await tester.pump();
    final list=find.byType(ListView).first;
    final scrollable=tester.state<ScrollableState>(find.descendant(of:list,matching:find.byType(Scrollable)).first);
    scrollable.position.jumpTo(0);await tester.pump();
    ai.streams.last.add('A late response chunk');await tester.pump();await tester.pump();
    expect(scrollable.position.pixels,0);
    controller.stop();await pending;
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Markdown links are wired and remote illustrations are not fetched', (tester) async {
    await tester.pumpWidget(MaterialApp(theme:AppTheme.light,home:Scaffold(body:ChatMessageCard(
      message:ChatMessage(id:'m',role:'bot',text:'[Open guide](https://example.com/guide)\n\n![Remote picture](https://example.com/track.png)',saved:true)))));
    await tester.pumpAndSettle();
    expect(find.byType(Image),findsNothing);
    await tester.tap(find.text('Open guide'));await tester.pumpAndSettle();
    expect(find.text('Open external website?'),findsOneWidget);
    expect(find.text('https://example.com/guide'),findsOneWidget);
    await tester.tap(find.text('Cancel'));await tester.pumpAndSettle();
  });

  testWidgets('Android Back closes conversation drawer before leaving Chat', (tester) async {
    final session=FakeSession();final repository=FakeRepository();final ai=FakeAi();
    final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    await tester.pumpWidget(MaterialApp(theme:AppTheme.light,home:Builder(builder:(ctx)=>Scaffold(body:TextButton(
      onPressed:()=>Navigator.push(ctx,MaterialPageRoute<void>(builder:(_)=>ChatScreen(session:session,controller:controller))),child:const Text('Home'))))));
    await tester.tap(find.text('Home'));await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open conversation menu'));await tester.pumpAndSettle();
    expect(find.byTooltip('Close history').hitTestable(),findsOneWidget);
    await tester.binding.handlePopRoute();await tester.pumpAndSettle();
    expect(find.byType(ChatScreen),findsOneWidget);
    expect(find.byTooltip('Close history').hitTestable(),findsNothing);
    await tester.binding.handlePopRoute();await tester.pumpAndSettle();
    expect(find.byType(ChatScreen),findsNothing);expect(find.text('Home'),findsOneWidget);
  });

}
