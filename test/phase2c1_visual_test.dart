import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/login_screen.dart';
import 'package:ai_chatbot/screens/signup_screen.dart';
import 'package:ai_chatbot/screens/voice_screen.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/theme/app_colors.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/voice_visualization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_auth.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_voice_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  testWidgets('render corrected screens and every Voice state with synthetic fixtures',(t)async {
    t.view.devicePixelRatio=1;addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetViewInsets);
    final session=FakeSession();final repo=FakeRepository()..summaries=[const ConversationSummary('one','A little room for creativity'),const ConversationSummary('two','Finding the right words')];
    repo.records['one']=[ChatMessage(id:'saved',role:'user',text:'Help me find more time for creative work.',saved:true)];
    final ai=FakeAi();final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);
    final voice=VoiceController(chat:chat,speech:SpeechCoordinator(FakeSpeechDriver()),output:FakeSpeechOutput(),currentUid:()=>session.uid);
    addTearDown((){voice.dispose();chat.dispose();session.dispose();ai.close();});final boundary=GlobalKey();
    Widget app(Widget screen,{double scale=1})=>RepaintBoundary(key:boundary,child:MaterialApp(debugShowCheckedModeBanner:false,theme:AppTheme.light,
      builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(disableAnimations:true,textScaler:TextScaler.linear(scale),
        padding:const EdgeInsets.only(top:24,bottom:24),viewPadding:const EdgeInsets.only(top:24,bottom:24)),child:child!),home:screen));
    Future<void> render(Widget screen,String name,{double scale=1,bool pushed=false})async {
      await t.pumpWidget(app(pushed?const Scaffold():screen,scale:scale));await t.pumpAndSettle();
      if(pushed) {Navigator.of(t.element(find.byType(Scaffold))).push(MaterialPageRoute<void>(builder:(_)=>screen));await t.pumpAndSettle();}
      await capturePreview(t,boundary,'../phase2c1/after_$name');expect(t.takeException(),isNull);
      await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
    }
    for(final size in [const Size(360,800),const Size(393,852),const Size(430,932),const Size(852,393)]) {
      t.view.physicalSize=size;final suffix='${size.width.toInt()}x${size.height.toInt()}';
      await render(LoginScreen(gateway:FakeAuth()),'login_$suffix',pushed:true);
      await render(SignupScreen(gateway:FakeAuth()),'signup_$suffix',pushed:true);
      await chat.open('one');
      await t.pumpWidget(app(ChatScreen(session:session,controller:chat)));await t.pumpAndSettle();
      await capturePreview(t,boundary,'../phase2c1/after_chat_header_$suffix');
      await t.tap(find.byKey(const Key('chat-menu')));await t.pumpAndSettle();await capturePreview(t,boundary,'../phase2c1/after_chat_drawer_$suffix');
      expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
      voice.reset();await render(VoiceScreen(session:session,controller:voice),'voice_$suffix');
    }
    t.view.physicalSize=const Size(393,852);
    for(final phase in VoicePhase.values) {
      voice.reset();voice.phase=phase;
      if(phase==VoicePhase.error)voice.error='Voice recognition could not connect. Check your connection and try again.';
      if([VoicePhase.listening,VoicePhase.processing,VoicePhase.speaking].contains(phase))voice.transcript='Help me make a little room for creativity.';
      await render(VoiceScreen(session:session,controller:voice),'voice_${phase.name}_393x852');
    }
    t.view.viewInsets=const FakeViewPadding(bottom:310);
    await render(SignupScreen(gateway:FakeAuth()),'signup_keyboard_393x852',pushed:true);
    t.view.resetViewInsets();
    await render(SignupScreen(gateway:FakeAuth()),'signup_text200_393x852',scale:2,pushed:true);
  });
  testWidgets('capture one complete flower animation cycle as actual Flutter frames',(t)async {
    t.view.devicePixelRatio=1;t.view.physicalSize=const Size(320,320);
    addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
    final boundary=GlobalKey();
    await t.pumpWidget(RepaintBoundary(key:boundary,child:const MaterialApp(debugShowCheckedModeBanner:false,home:Scaffold(
      backgroundColor:AppColors.canvas,body:Center(child:VoiceVisualization(phase:VoicePhase.listening,size:280))))));
    for(var i=0;i<36;i++) {
      await capturePreview(t,boundary,'../phase2c1/flower_frame_${i.toString().padLeft(2,'0')}');
      await t.pump(const Duration(milliseconds:150));
    }
    await t.pumpWidget(const SizedBox.shrink());await t.pump();expect(t.takeException(),isNull);
  });
}
