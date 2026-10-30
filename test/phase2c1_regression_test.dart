import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/login_screen.dart';
import 'package:ai_chatbot/screens/signup_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/chat_sidebar.dart';
import 'package:ai_chatbot/widgets/voice_visualization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_auth.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  void viewport(WidgetTester t,Size size) {
    t.view.devicePixelRatio=1;t.view.physicalSize=size;
    addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetViewInsets);
  }
  Widget shell(Widget screen,{double scale=1,bool reduced=false})=>MaterialApp(theme:AppTheme.light,
    builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(textScaler:TextScaler.linear(scale),disableAnimations:reduced,
      padding:const EdgeInsets.only(top:24,bottom:24),viewPadding:const EdgeInsets.only(top:24,bottom:24)),child:child!),
    home:Builder(builder:(ctx)=>Scaffold(body:TextButton(onPressed:()=>Navigator.push(ctx,MaterialPageRoute<void>(builder:(_)=>screen)),child:const Text('Open screen')))));
  Future<void> open(WidgetTester t,Widget screen,{double scale=1,bool reduced=false})async {
    await t.pumpWidget(shell(screen,scale:scale,reduced:reduced));await t.tap(find.text('Open screen'));await t.pumpAndSettle();
  }
  for(final size in [const Size(360,800),const Size(393,852),const Size(430,932)]) {
    for(final signup in [false,true]) {
      testWidgets('${signup?'Sign-up':'Login'} is static and correctly ordered at $size; keyboard keeps actions reachable',(t)async {
        viewport(t,size);final auth=FakeAuth();await open(t,signup?SignupScreen(gateway:auth):LoginScreen(gateway:auth));
        final order=[find.byTooltip('Back'),find.text('AI Mind'),find.byKey(const Key('auth-heading')),
          find.byKey(const Key('auth-email')),find.byKey(const Key('auth-password')),
          if(signup)find.byKey(const Key('auth-confirm'))else find.text('Forgot password?'),
          find.byKey(const Key('auth-submit')),find.byKey(const Key('auth-google')),find.byKey(const Key('auth-mode'))];
        for(var i=1;i<order.length;i++) {expect(t.getCenter(order[i]).dy,greaterThan(t.getCenter(order[i-1]).dy));}
        final scroll=find.descendant(of:find.byKey(const Key('auth-scroll')),matching:find.byType(Scrollable)).first;
        expect(t.state<ScrollableState>(scroll).position.maxScrollExtent,0);
        expect(find.byKey(const Key('auth-mode')).hitTestable(),findsOneWidget);
        await t.enterText(find.byKey(const Key('auth-password')),'  exact password  ');
        t.view.viewInsets=const FakeViewPadding(bottom:310);await t.pumpAndSettle();
        for(final key in ['auth-password','auth-submit','auth-google']) {
          await t.ensureVisible(find.byKey(Key(key)));await t.pumpAndSettle();
          expect(t.getRect(find.byKey(Key(key))).bottom,lessThanOrEqualTo(size.height-310));
          expect(find.byKey(Key(key)).hitTestable(),findsOneWidget);
        }
        t.view.resetViewInsets();await t.pumpAndSettle();
        expect(t.widget<TextFormField>(find.byKey(const Key('auth-password'))).controller!.text,'  exact password  ');
        expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for(final size in [const Size(320,568),const Size(852,393)]) {
    testWidgets('auth fallback is scrollable and accessible at $size and text200',(t)async {
      viewport(t,size);await open(t,SignupScreen(gateway:FakeAuth()),scale:2);
      for(final key in ['auth-password','auth-confirm','auth-submit','auth-google','auth-mode']) {
        await t.ensureVisible(find.byKey(Key(key)));await t.pumpAndSettle();expect(find.byKey(Key(key)).hitTestable(),findsOneWidget);expect(t.takeException(),isNull);
      }
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('hamburger opens from left with scrim; close, swipe and Android Back keep Chat alive',(t)async {
    viewport(t,const Size(393,852));final session=FakeSession();final repo=FakeRepository()..summaries=[const ConversationSummary('a','Saved thought')];final ai=FakeAi();
    final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);addTearDown((){chat.dispose();session.dispose();ai.close();});
    await open(t,ChatScreen(session:session,controller:chat));expect(find.byIcon(Icons.menu_rounded),findsOneWidget);expect(find.text('History'),findsNothing);
    final menu=find.byKey(const Key('chat-menu'));await t.tap(menu);await t.pump();await t.pump(const Duration(milliseconds:70));
    expect(t.getRect(find.byType(Drawer)).left,lessThan(0));await t.pumpAndSettle();expect(t.getRect(find.byType(Drawer)).left,0);
    final scaffold=t.state<ScaffoldState>(find.ancestor(of:menu,matching:find.byType(Scaffold)).first);
    expect(scaffold.isDrawerOpen,true);expect(scaffold.widget.drawerScrimColor!.a,greaterThan(0));expect(find.text('Saved thought'),findsOneWidget);
    await t.binding.handlePopRoute();await t.pumpAndSettle();expect(scaffold.isDrawerOpen,false);expect(find.byType(ChatScreen),findsOneWidget);
    await t.tap(menu);await t.pumpAndSettle();await t.tap(find.byTooltip('Close history'));await t.pumpAndSettle();expect(scaffold.isDrawerOpen,false);
    await t.tap(menu);await t.pumpAndSettle();await t.dragFrom(const Offset(290,300),const Offset(-280,0));await t.pumpAndSettle();expect(scaffold.isDrawerOpen,false);
    await t.tap(menu);await t.pumpAndSettle();await t.tapAt(const Offset(380,400));await t.pumpAndSettle();expect(scaffold.isDrawerOpen,false);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('drawer selection, current marker, new chat, rename and deletion preserve stream guards',(t)async {
    viewport(t,const Size(393,852));final session=FakeSession();final repo=FakeRepository()..summaries=[const ConversationSummary('a','Saved thought')];
    repo.records['a']=[ChatMessage(id:'saved',role:'bot',text:'Saved answer',saved:true)];final ai=FakeAi();
    final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);addTearDown((){chat.dispose();session.dispose();ai.close();});
    await open(t,ChatScreen(session:session,controller:chat),reduced:true);chat.setDraft('Current question');final request=chat.send();await t.pump();await t.pump();
    final oldId=chat.conversation.id;ai.streams.last.add('Partial');await t.pump();
    await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();await t.ensureVisible(find.text('Saved thought'));await t.tap(find.text('Saved thought'));await t.pumpAndSettle();
    ai.streams.last.add('Late response');await request;await t.pump();expect(chat.conversation.id,'a');expect(chat.conversation.messages.single.text,'Saved answer');expect(ai.cancellations,greaterThan(0));
    await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();
    expect(t.widgetList<SidebarConversationRow>(find.byType(SidebarConversationRow)).where((w)=>w.chat.id=='a').every((w)=>w.selected),true);
    await t.ensureVisible(find.byTooltip('Options for Saved thought'));await t.tap(find.byTooltip('Options for Saved thought'));await t.pumpAndSettle();
    await t.tap(find.text('Rename'));await t.pumpAndSettle();await t.enterText(find.byType(TextFormField),'Renamed thought');await t.tap(find.text('Save'));await t.pumpAndSettle();expect(repo.renamed,[('alice','a','Renamed thought')]);
    await t.ensureVisible(find.byTooltip('Options for Saved thought'));await t.tap(find.byTooltip('Options for Saved thought'));await t.pumpAndSettle();await t.tap(find.text('Delete'));await t.pumpAndSettle();expect(repo.deleted,isEmpty);
    await t.tap(find.text('Keep'));await t.pumpAndSettle();expect(repo.deleted,isEmpty);
    await t.ensureVisible(find.byTooltip('Options for Saved thought'));await t.tap(find.byTooltip('Options for Saved thought'));await t.pumpAndSettle();await t.tap(find.text('Delete'));await t.pumpAndSettle();await t.tap(find.widgetWithText(TextButton,'Delete'));await t.pumpAndSettle();expect(repo.deleted,['a']);
    await t.ensureVisible(find.text('New chat'));await t.tap(find.text('New chat'));await t.pumpAndSettle();expect(chat.conversation.messages,isEmpty);expect(chat.conversation.id,isNot(oldId));
    expect(repo.records[oldId]!.where((m)=>m.role=='bot'),isEmpty);expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('drawer supports loading, offline, empty, search and landscape large text',(t)async {
    viewport(t,const Size(852,393));final session=FakeSession();final stream=StreamController<List<ConversationSummary>>();final repo=FakeRepository()..history=stream.stream;
    final ai=FakeAi();final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);addTearDown((){chat.dispose();session.dispose();stream.close();ai.close();});
    await open(t,ChatScreen(session:session,controller:chat),scale:2);await t.tap(find.byKey(const Key('chat-menu')));await t.pump();await t.pump(const Duration(seconds:1));
    await t.ensureVisible(find.bySemanticsLabel('Loading history'));expect(t.takeException(),isNull);
    stream.addError(StateError('offline'));await t.pump();await t.ensureVisible(find.text('History is unavailable'));expect(find.text('History is unavailable'),findsOneWidget);
    stream.add([]);await t.pump();await t.ensureVisible(find.text('Saved conversations will appear here.'));expect(t.takeException(),isNull);
    stream.add([const ConversationSummary('a','A saved thought')]);await t.pump();await t.drag(find.byKey(const Key('conversation-menu-scroll')),const Offset(0,1000));await t.pump();await t.ensureVisible(find.byKey(const Key('drawer-search')));await t.enterText(find.byKey(const Key('drawer-search')),'nothing');await t.pump(const Duration(milliseconds:300));
    await t.ensureVisible(find.text('No matching conversations.'));expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('drawer search survives reopening and resets when identity changes',(t)async {
    viewport(t,const Size(393,852));final session=FakeSession();final repo=FakeRepository()..summaries=[const ConversationSummary('a','Saved thought'),const ConversationSummary('b','Other idea')];
    final ai=FakeAi();final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);addTearDown((){chat.dispose();session.dispose();ai.close();});
    await open(t,ChatScreen(session:session,controller:chat));await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('drawer-search')),'saved');await t.pumpAndSettle();expect(find.text('Other idea'),findsNothing);
    await t.tap(find.byTooltip('Close history'));await t.pumpAndSettle();await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byKey(const Key('drawer-search'))).controller!.text,'saved');expect(find.text('Other idea'),findsNothing);
    repo.summaries=[const ConversationSummary('new','New account idea')];session.change('bob');await t.pumpAndSettle();
    if(find.byKey(const Key('drawer-search')).evaluate().isEmpty) {await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();}
    expect(t.widget<TextField>(find.byKey(const Key('drawer-search'))).controller!.text,isEmpty);
    expect(find.text('New account idea'),findsOneWidget);expect(find.text('Saved thought'),findsNothing);await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('repeated Voice visual navigation disposes the visual ticker',(t)async {
    for(var i=0;i<4;i++) {
      await t.pumpWidget(shell(const Center(child:VoiceVisualization(phase:VoicePhase.listening))));
      await t.tap(find.text('Open screen'));await t.pump();await t.pump(const Duration(milliseconds:400));
      Navigator.of(t.element(find.byType(VoiceVisualization))).pop();await t.pump();await t.pump(const Duration(milliseconds:400));
      expect(find.byType(VoiceVisualization),findsNothing);expect(t.hasRunningAnimations,false);expect(t.takeException(),isNull);
      await t.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets('orb active states, stop, reduced motion and repeated disposal',(t)async {
    for(var repeat=0;repeat<3;repeat++) {
      for(final phase in VoicePhase.values) {
        await t.pumpWidget(MaterialApp(home:Center(child:VoiceVisualization(phase:phase))));await t.pump(const Duration(milliseconds:400));
        expect(t.widget<VoiceVisualization>(find.byType(VoiceVisualization)).phase,phase);
        if(phase!=VoicePhase.speaking){for(var frame=0;frame<120;frame++){await t.pump(const Duration(milliseconds:16));}}
        expect(t.hasRunningAnimations,phase==VoicePhase.speaking);
        await t.pumpWidget(MaterialApp(home:MediaQuery(data:const MediaQueryData(disableAnimations:true),child:VoiceVisualization(phase:phase))));await t.pump();expect(t.hasRunningAnimations,false);
        await t.pumpWidget(const SizedBox.shrink());await t.pump(const Duration(seconds:1));expect(t.takeException(),isNull);expect(t.hasRunningAnimations,false);
      }
    }
  });
}
