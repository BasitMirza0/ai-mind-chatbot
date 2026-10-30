import 'dart:io';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/home_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(() async {
    await loadPreviewFonts();
    // Widget tests use Ahem for unregistered families. Load a local system
    // monospace for review rendering only; it is not copied into app assets.
    final candidates = ['/System/Library/Fonts/Menlo.ttc',
      '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'];
    final font = FontLoader('monospace');
    final available = candidates.where((path) => File(path).existsSync());
    if (available.isNotEmpty) {
      font.addFont(Future.value(ByteData.sublistView(File(available.first).readAsBytesSync())));
    } else {
      font.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    }
    await font.load();
  });
  testWidgets('render private Phase 2B review gallery with synthetic data', (tester) async {
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final session=FakeSession();final repository=FakeRepository()..summaries=[
      const ConversationSummary('one','A little room for creativity'),
      const ConversationSummary('two','Finding the right words'),
    ];
    final ai=FakeAi();final controller=ChatController(ai:ai,repository:repository,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    final boundary=GlobalKey();
    Widget app(Widget screen,{double scale=1,double keyboard=0})=>RepaintBoundary(key:boundary,child:MaterialApp(
      debugShowCheckedModeBanner:false,theme:AppTheme.legacy,builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(
        textScaler:TextScaler.linear(scale),disableAnimations:true,padding:const EdgeInsets.only(top:24,bottom:24),
        viewPadding:const EdgeInsets.only(top:24,bottom:24),viewInsets:EdgeInsets.only(bottom:keyboard)),child:child!),home:screen));
    for(final size in [const Size(360,800),const Size(393,852),const Size(430,932),const Size(852,393)]) {
      tester.view.physicalSize=size;
      final suffix='${size.width.toInt()}x${size.height.toInt()}';
      await tester.pumpWidget(app(HomeScreen(key:ValueKey('home-$suffix'),session:session,repository:repository)));
      await tester.pumpAndSettle();await capturePreview(tester,boundary,'../phase2b/after_home_$suffix');
      await tester.ensureVisible(find.text('Your conversations'));await tester.pumpAndSettle();
      await capturePreview(tester,boundary,'../phase2b/after_home_history_$suffix');
      controller.newConversation();
      await tester.pumpWidget(app(ChatScreen(key:ValueKey('empty-$suffix'),session:session,controller:controller)));
      await tester.runAsync(()=>precacheImage(const AssetImage('assets/images/robot.png'),boundary.currentContext!));
      await tester.pumpAndSettle();await capturePreview(tester,boundary,'../phase2b/after_chat_empty_$suffix');
      controller.conversation.messages.addAll([
        ChatMessage(id:'u-$suffix',role:'user',text:'I want to make more time for creative work. Where do I start?',saved:true),
        ChatMessage(id:'b-$suffix',role:'bot',text:'Start small enough that it feels inviting.\n\n### Make a little space\n\n1. **Choose one thing.** A sketch, a paragraph, a melody.\n2. **Give it 15 minutes.** Put it in your day, like a coffee break.\n3. **Leave a thread.** Note one idea to come back to tomorrow.\n\nYou don’t need a perfect routine. Just a place to begin.',saved:true),
      ]);
      await tester.pumpWidget(app(ChatScreen(key:ValueKey('chat-$suffix'),session:session,controller:controller)));
      await tester.pumpAndSettle();await capturePreview(tester,boundary,'../phase2b/after_chat_$suffix');
      expect(tester.takeException(),isNull);
    }
    tester.view.physicalSize=const Size(393,852);
    await tester.pumpWidget(app(ChatScreen(key:const Key('keyboard'),session:session,controller:controller),keyboard:310));
    await tester.pumpAndSettle();await capturePreview(tester,boundary,'../phase2b/after_chat_keyboard_393');
    await tester.pumpWidget(app(ChatScreen(key:const Key('large'),session:session,controller:controller),scale:2));
    await tester.pumpAndSettle();await capturePreview(tester,boundary,'../phase2b/after_chat_text200_393');
    controller.conversation.messages.last..state = ReplyState.failed..saved = false..text = 'Let’s find a small place to begin…';
    controller.conversation.error='Cannot reach the AI backend. Check your connection and backend address.';
    await tester.pumpWidget(app(ChatScreen(key:const Key('error'),session:session,controller:controller)));
    await tester.pumpAndSettle();await tester.ensureVisible(find.text('Response interrupted · partial text kept here'));await tester.pumpAndSettle();
    await capturePreview(tester,boundary,'../phase2b/after_chat_error_393');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.newConversation();
    controller.conversation.title = 'A small Dart example';
    controller.conversation.messages.addAll([
      ChatMessage(id:'code-u', role:'user', text:'Show me a simple Dart greeting.',saved:true),
      ChatMessage(id:'code-b', role:'bot', text:'### A small beginning\n\nUse a function to keep your greeting reusable.\n\n```dart\nString greet(String name) {\n  return "Hello, \$name!";\n}\n\nprint(greet("Alex"));\n```\n\n[Explore Dart](https://dart.dev) for more examples.',saved:true),
    ]);
    await tester.pumpWidget(app(ChatScreen(key:const Key('code'),session:session,controller:controller)));
    await tester.pumpAndSettle(); await capturePreview(tester,boundary,'../phase2b/after_chat_code_393');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.newConversation();
    final image = await rootBundle.load('assets/images/robot.png');
    controller.attach(image.buffer.asUint8List());
    controller.setDraft('What do you notice about this robot?');
    await tester.pumpWidget(app(ChatScreen(key:const Key('attachment'),session:session,controller:controller)));
    await tester.runAsync(() => precacheImage(MemoryImage(image.buffer.asUint8List()), boundary.currentContext!));
    await tester.pumpAndSettle(); await capturePreview(tester,boundary,'../phase2b/after_chat_attachment_393');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.newConversation(); controller.setDraft('Help me make a little room for creativity.');
    await tester.pumpWidget(app(ChatScreen(key:const Key('stream'),session:session,controller:controller)));
    await tester.pumpAndSettle();
    final request = controller.send(); await tester.pump(); await tester.pump();
    ai.streams.last.add('Start with a small invitation to yourself. Choose one thing you would enjoy creating, then give it fifteen minutes.');
    await tester.pump(); await tester.pump();
    await capturePreview(tester,boundary,'../phase2b/after_chat_streaming_393');
    controller.stop(); await request;
    await tester.pumpWidget(const SizedBox.shrink());
    session.change(null); controller.sessionChanged();
    await tester.pumpWidget(app(HomeScreen(key:const Key('guest-home'),session:session,repository:repository)));
    await tester.pumpAndSettle(); await capturePreview(tester,boundary,'../phase2b/after_home_guest_393x852');
    await tester.ensureVisible(find.text('Keep your thoughts together')); await tester.pumpAndSettle();
    await capturePreview(tester,boundary,'../phase2b/after_home_guest_history_393');
    await tester.pumpWidget(app(ChatScreen(key:const Key('guest-chat'),session:session,controller:controller)));
    await tester.pumpAndSettle(); await capturePreview(tester,boundary,'../phase2b/after_chat_guest_393x852');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
