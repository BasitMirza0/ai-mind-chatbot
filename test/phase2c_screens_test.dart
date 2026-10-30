import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_history_screen.dart';
import 'package:ai_chatbot/screens/home_screen.dart';
import 'package:ai_chatbot/screens/login_screen.dart';
import 'package:ai_chatbot/screens/signup_screen.dart';
import 'package:ai_chatbot/screens/voice_screen.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/voice_visualization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_auth.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_voice_dependencies.dart';

void main() {
  for (final size in [const Size(360,800), const Size(393,852), const Size(430,932), const Size(852,393)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cohesive screens fit $size at text $scale, including keyboard and reduced motion', (t) async {
        t.view.devicePixelRatio=1; t.view.physicalSize=size;
        addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetViewInsets);
        final session=FakeSession(displayName:'Alexandra Morgan with a very long family name');
        final repo=FakeRepository()..summaries=[const ConversationSummary('one','A longer conversation name with plenty of room for ideas')];
        final ai=FakeAi();final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);
        final voice=VoiceController(chat:chat,speech:SpeechCoordinator(FakeSpeechDriver()),output:FakeSpeechOutput(),currentUid:()=>session.uid);
        addTearDown(() {voice.dispose();chat.dispose();session.dispose();ai.close();});
        Widget app(Widget screen)=>MaterialApp(theme:AppTheme.light, builder:(ctx,child)=>MediaQuery(
          data:MediaQuery.of(ctx).copyWith(textScaler:TextScaler.linear(scale),disableAnimations:true,
            padding:const EdgeInsets.only(top:24,bottom:24),viewPadding:const EdgeInsets.only(top:24,bottom:24)),child:child!),home:screen);
        for(final screen in [LoginScreen(gateway:FakeAuth()),SignupScreen(gateway:FakeAuth()),
          HomeScreen(session:session,repository:repo),ChatHistoryScreen(session:session,repository:repo),
          VoiceScreen(session:session,controller:voice)]) {
          await t.pumpWidget(app(screen));await t.pumpAndSettle();expect(t.takeException(),isNull,reason:screen.runtimeType.toString());
          if(screen is LoginScreen || screen is SignupScreen) {
            t.view.viewInsets=FakeViewPadding(bottom:size.height<500?160:310);
            await t.enterText(find.byKey(const Key('auth-email')),'someone@example.com');await t.pumpAndSettle();
            await t.ensureVisible(find.byKey(const Key('auth-password')));await t.pumpAndSettle();expect(t.takeException(),isNull);
            t.view.resetViewInsets();
          }
          await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();expect(t.takeException(),isNull);
        }
      });
    }
  }
  testWidgets('dedicated history search, selection, rename and confirmed deletion stay user scoped', (t) async {
    final session=FakeSession(); final repo=FakeRepository()..summaries=[const ConversationSummary('one','A saved idea'),const ConversationSummary('two','Other thoughts')];
    addTearDown(session.dispose);
    await t.pumpWidget(MaterialApp(home:ChatHistoryScreen(session:session,repository:repo,chatBuilder:(id)=>Scaffold(appBar:AppBar(),body:Text('Opened $id')))));
    await t.pumpAndSettle();await t.enterText(find.byType(TextField),'saved');await t.pumpAndSettle();
    expect(find.text('Other thoughts'),findsNothing);await t.tap(find.text('A saved idea'));await t.pumpAndSettle();expect(find.text('Opened one'),findsOneWidget);
    await t.pageBack();await t.pumpAndSettle();
    await t.tap(find.byTooltip('Options for A saved idea').first);await t.pumpAndSettle();await t.tap(find.text('Rename'));await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField),'A better name');await t.tap(find.text('Save'));await t.pumpAndSettle();expect(repo.renamed,[('alice','one','A better name')]);
    await t.tap(find.byTooltip('Options for A saved idea').first);await t.pumpAndSettle();await t.tap(find.text('Delete'));await t.pumpAndSettle();expect(repo.deleted,isEmpty);
    await t.tap(find.text('Keep'));await t.pumpAndSettle();expect(repo.deleted,isEmpty);
    await t.tap(find.byTooltip('Options for A saved idea').first);await t.pumpAndSettle();await t.tap(find.text('Delete'));await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton,'Delete'));await t.pumpAndSettle();expect(repo.deleted,['one']);
    session.change(null);await t.pumpAndSettle();expect(find.text('A saved idea'),findsNothing);expect(find.text('A place for your conversations'),findsOneWidget);
  });
  testWidgets('history separates loading, error, empty and no matches', (t) async {
    final session=FakeSession(); final stream=StreamController<List<ConversationSummary>>();final repo=FakeRepository()..history=stream.stream;
    addTearDown(() {session.dispose();stream.close();});
    await t.pumpWidget(MaterialApp(home:ChatHistoryScreen(session:session,repository:repo)));await t.pump();
    expect(find.bySemanticsLabel('Loading conversations'),findsOneWidget);
    stream.addError(StateError('offline'));await t.pump();expect(find.text('History is unavailable'),findsOneWidget);
    stream.add([]);await t.pump();expect(find.text('Your next idea starts here'),findsOneWidget);
    stream.add([const ConversationSummary('a','An idea')]);await t.pump();await t.enterText(find.byType(TextField),'none');await t.pump();
    expect(find.text('No matching conversations'),findsOneWidget);
  });
  testWidgets('Voice permission error and state controls are real; leaving cancels listeners', (t) async {
    final session=FakeSession();final ai=FakeAi();final chat=ChatController(ai:ai,repository:FakeRepository(),currentUid:()=>session.uid);
    final driver=FakeSpeechDriver()..permitted=false;final voice=VoiceController(chat:chat,speech:SpeechCoordinator(driver),output:FakeSpeechOutput(),currentUid:()=>session.uid);
    addTearDown((){voice.dispose();chat.dispose();session.dispose();ai.close();});
    await t.pumpWidget(MaterialApp(builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(disableAnimations:true),child:child!),home:VoiceScreen(session:session,controller:voice)));
    await t.tap(find.text('Start talking'));await t.pumpAndSettle();expect(find.text('Let’s try again'),findsOneWidget);
    expect(find.text('Microphone permission is needed. Tap Start talking to try again, or enable it in Android Settings.'),findsOneWidget);
    driver.permitted=true;await t.tap(find.text('Start talking'));await t.pumpAndSettle();expect(find.text('Listening…'),findsOneWidget);
    await t.tap(find.text('Pause'));await t.pumpAndSettle();expect(find.text('Response stopped'),findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());await t.pump();expect(t.takeException(),isNull);expect(voice.phase,VoicePhase.paused);
  });
  testWidgets('Login and Voice controls have labels, contrast and comfortable targets', (t) async {
    final semantics=t.ensureSemantics();
    final session=FakeSession();final ai=FakeAi();final chat=ChatController(ai:ai,repository:FakeRepository(),currentUid:()=>session.uid);
    final voice=VoiceController(chat:chat,speech:SpeechCoordinator(FakeSpeechDriver()),output:FakeSpeechOutput(),currentUid:()=>session.uid);
    addTearDown((){voice.dispose();chat.dispose();session.dispose();ai.close();});
    for(final screen in [LoginScreen(gateway:FakeAuth()),VoiceScreen(session:session,controller:voice)]) {
      await t.pumpWidget(MaterialApp(builder:(ctx, child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(disableAnimations:true),child:child!),home:screen));await t.pumpAndSettle();
      await expectLater(t,meetsGuideline(androidTapTargetGuideline));await expectLater(t,meetsGuideline(labeledTapTargetGuideline));
      await expectLater(t,meetsGuideline(textContrastGuideline));await t.pumpWidget(const SizedBox.shrink());
    }
    semantics.dispose();
  });
  testWidgets('voice animation follows active states, reduced motion and disposal',(t)async {
    Widget visual(VoicePhase phase,{bool reduced=false})=>MaterialApp(home:MediaQuery(
      data:MediaQueryData(disableAnimations:reduced),child:VoiceVisualization(phase:phase)));
    await t.pumpWidget(visual(VoicePhase.listening));await t.pump(const Duration(milliseconds:300));expect(t.hasRunningAnimations,true);
    await t.pumpWidget(visual(VoicePhase.paused));for(var frame=0;frame<120;frame++){await t.pump(const Duration(milliseconds:16));}expect(t.hasRunningAnimations,false);
    await t.pumpWidget(visual(VoicePhase.speaking,reduced:true));await t.pump();expect(t.hasRunningAnimations,false);
    await t.pumpWidget(visual(VoicePhase.processing));await t.pump();expect(t.hasRunningAnimations,true);
    await t.pumpWidget(const SizedBox.shrink());await t.pump(const Duration(seconds:2));expect(t.takeException(),isNull);expect(t.hasRunningAnimations,false);
  });

}
