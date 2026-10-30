import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_history_screen.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/home_screen.dart';
import 'package:ai_chatbot/screens/login_screen.dart';
import 'package:ai_chatbot/screens/signup_screen.dart';
import 'package:ai_chatbot/screens/voice_screen.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_auth.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_voice_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  testWidgets('render Phase 2C screens using synthetic identities and local assets only', (t) async {
    t.view.devicePixelRatio=1;
    addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetViewInsets);
    final session=FakeSession();final repo=FakeRepository()..summaries=[
      const ConversationSummary('one','A little room for creativity'),const ConversationSummary('two','Finding the right words')];
    final ai=FakeAi();final chat=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);
    final driver=FakeSpeechDriver();final output=FakeSpeechOutput();final voiceChat=ChatController(ai:FakeAi(),repository:repo,currentUid:()=>session.uid);
    final voice=VoiceController(chat:voiceChat,speech:SpeechCoordinator(driver),output:output,currentUid:()=>session.uid);
    addTearDown((){voice.dispose();voiceChat.dispose();chat.dispose();session.dispose();ai.close();});
    final boundary=GlobalKey();
    Widget app(Widget screen,{double scale=1})=>RepaintBoundary(key:boundary,child:MaterialApp(
      debugShowCheckedModeBanner:false,theme:AppTheme.light,builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(
        disableAnimations:true,textScaler:TextScaler.linear(scale),padding:const EdgeInsets.only(top:24,bottom:24),viewPadding:const EdgeInsets.only(top:24,bottom:24)),child:child!),home:screen));
    Future<void> render(Widget screen,String name,{double scale=1}) async {
      await t.pumpWidget(app(screen is ChatHistoryScreen?const Scaffold():screen,scale:scale));await t.pumpAndSettle();
      if(screen is ChatHistoryScreen) {
        Navigator.of(t.element(find.byType(Scaffold))).push(MaterialPageRoute<void>(builder:(_)=>screen));
        await t.pumpAndSettle();
      }
      await capturePreview(t,boundary,'../phase2c/after_$name');expect(t.takeException(),isNull);
      await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
    }
    for(final size in [const Size(360,800),const Size(393,852),const Size(430,932),const Size(852,393)]) {
      t.view.physicalSize=size;final suffix='${size.width.toInt()}x${size.height.toInt()}';
      await render(HomeScreen(session:session,repository:repo),'home_$suffix');
      await render(LoginScreen(gateway:FakeAuth()),'login_$suffix');
      await render(SignupScreen(gateway:FakeAuth()),'signup_$suffix');
      await render(ChatHistoryScreen(session:session,repository:repo),'history_$suffix');
      voice.reset();await render(VoiceScreen(session:session,controller:voice),'voice_$suffix');
      await t.pumpWidget(app(ChatScreen(session:session,controller:chat)));
      await t.runAsync(()=>precacheImage(const AssetImage('assets/images/robot.png'),boundary.currentContext!));
      await t.pumpAndSettle();await capturePreview(t,boundary,'../phase2c/after_chat_empty_$suffix');
      await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
    }
    t.view.physicalSize=const Size(393,852);
    await t.pumpWidget(app(ChatScreen(session:session,controller:chat)));await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open conversation menu'));await t.pumpAndSettle();
    await capturePreview(t,boundary,'../phase2c/after_chat_history_393x852');
    await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
    t.view.viewInsets=const FakeViewPadding(bottom:310);
    chat.setDraft('A thought I want to keep\nwhile the keyboard is open.');
    await render(ChatScreen(session:session,controller:chat),'chat_keyboard_393x852');
    t.view.resetViewInsets();
    await render(HomeScreen(session:session,repository:repo),'home_text200_393x852',scale:2);
    await render(LoginScreen(gateway:FakeAuth()),'login_text200_393x852',scale:2);
    await render(VoiceScreen(session:session,controller:voice),'voice_text200_393x852',scale:2);
    await t.pumpWidget(app(VoiceScreen(session:session,controller:voice)));await t.pumpAndSettle();
    await t.tap(find.text('Start talking'));await t.pumpAndSettle();driver.result!(const SpeechText('Help me find a little time to be creative.',false));await t.pump();
    await capturePreview(t,boundary,'../phase2c/after_voice_listening_393x852');
    voice.pause();await t.pumpAndSettle();await capturePreview(t,boundary,'../phase2c/after_voice_paused_393x852');
    await t.pumpWidget(const SizedBox.shrink());await t.pumpAndSettle();
    final errorDriver=FakeSpeechDriver()..permitted=false;
    final errorVoice=VoiceController(chat:voiceChat,speech:SpeechCoordinator(errorDriver),output:output,currentUid:()=>session.uid);
    await errorVoice.begin();await render(VoiceScreen(session:session,controller:errorVoice),'voice_permission_393x852');errorVoice.dispose();
  });
}
