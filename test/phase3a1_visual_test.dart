import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(() async {
    await loadPreviewFonts();
    final font = FontLoader('monospace');
    final candidates = [
      '/System/Library/Fonts/Menlo.ttc',
      '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    ];
    final available = candidates.where((path) => File(path).existsSync());
    if (available.isNotEmpty) {
      font.addFont(
        Future.value(
          ByteData.sublistView(File(available.first).readAsBytesSync()),
        ),
      );
    } else {
      font.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    }
    await font.load();
  });
  testWidgets('Phase 3A.1 synthetic conversation review gallery', (
    tester,
  ) async {
    const stage = String.fromEnvironment('CHAT_CAPTURE', defaultValue: 'after');
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final session = FakeSession();
    final repository = FakeRepository();
    final ai = FakeAi();
    final chat = ChatController(
      ai: ai,
      repository: repository,
      currentUid: () => session.uid,
    );
    addTearDown(() {
      chat.dispose();
      session.dispose();
      ai.close();
    });
    chat.conversation.title = 'Make room for a good idea';
    chat.conversation.messages.addAll([
      ChatMessage(
        id: 'user',
        role: 'user',
        text: 'How can I make time for a creative project?',
        saved: true,
      ),
      ChatMessage(
        id: 'reply',
        role: 'bot',
        saved: true,
        text:
            'Start with a small, repeatable moment. You don’t need a perfect routine.\n\n## Make a little space\n\n1. **Choose one thing.** A sketch, a paragraph, a melody.\n2. **Give it 15 minutes.** Put it in your day, like a coffee break.\n3. **Leave a thread.** Note one idea for tomorrow.\n\n> Make it easy to begin again.',
      ),
    ]);
    final boundary = GlobalKey();
    Widget app({double scale = 1, double keyboard = 0}) => RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        builder:
            (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(top: 24, bottom: 24),
                viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: child!,
            ),
        home: ChatScreen(session: session, controller: chat),
      ),
    );
    for (final width in [320, 360, 393, 430]) {
      tester.view.physicalSize = Size(width.toDouble(), 852);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await capturePreview(
        tester,
        boundary,
        '../phase3a1/${stage}_conversation_$width',
      );
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(393, 852);
    await tester.pumpWidget(app(keyboard: 310));
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, '../phase3a1/${stage}_keyboard_393');
    await tester.pumpWidget(app(scale: 2));
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, '../phase3a1/${stage}_text200_393');
    await tester.pumpWidget(const SizedBox.shrink());
    chat.newConversation();
    chat.conversation.title = 'A small, useful example';
    chat.conversation.messages.addAll([
      ChatMessage(
        id: 'code-user',
        role: 'user',
        text: 'Show me a simple example and a plan.',
        saved: true,
      ),
      ChatMessage(
        id: 'code-bot',
        role: 'bot',
        saved: true,
        text:
            '## Start with a greeting\n\nKeep the first step small and reusable.\n\n```dart\nString greet(String name) {\n  return "Hello, \$name!";\n}\n```\n\n| Step | Time |\n| --- | --- |\n| Write one function | 10 minutes |\n| Try it out | 5 minutes |',
      ),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, '../phase3a1/${stage}_markdown_393');
    await tester.pumpWidget(const SizedBox.shrink());
    chat.newConversation();
    chat.setDraft('Help me make a little room for creativity.');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final request = chat.send();
    await tester.pump();
    await tester.pump();
    ai.streams.last.add(
      '## Begin with something small\n\nGive yourself **15 minutes** and one simple goal.\n\n- Pick a project you enjoy.\n- Keep a note for tomorrow.\n\n| Idea | Time |\n| --',
    );
    await tester.pump();
    await tester.pump();
    await capturePreview(
      tester,
      boundary,
      '../phase3a1/${stage}_streaming_393',
    );
    chat.stop();
    await request;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
