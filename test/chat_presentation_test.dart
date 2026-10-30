import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/chat_markdown.dart';
import 'package:ai_chatbot/widgets/chat_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/visual_capture.dart';

const richReply = '''# A clear answer

A paragraph with **bold**, *italic*, and `inline code`.

## Next steps

1. First step
2. Second step
   - A nested idea
   - Another idea

> A useful reminder.

---

[Read the guide](https://example.com/guide)

```dart
final message = "A very long line that should scroll horizontally without changing its content or overflowing";
print(message);
```

| Choice | Time | Notes |
| :--- | ---: | --- |
| Sketch | 15 minutes | Start with one simple shape |
| Write | 20 minutes | Keep your first draft |
''';

Widget shell(Widget child, {double scale = 1, double keyboard = 0}) =>
    MaterialApp(
      theme: AppTheme.light,
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
      home: child,
    );

void viewport(WidgetTester tester, double width, {double height = 852}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

String visibleText(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.data ?? w.textSpan!.toPlainText())
    .join('\n');

void main() {
  setUpAll(loadPreviewFonts);
  test('streaming defers ambiguous syntax and never synthesizes content', () {
    for (final entry
        in <String, String>{
          '##': '',
          '## Heading': '## Heading',
          'Hello **bo': 'Hello ',
          'Hello **bold**': 'Hello **bold**',
          'Use `co': 'Use ',
          'Use `code`': 'Use `code`',
          'Use ` code `': 'Use ` code `',
          'Try *ital': 'Try ',
          'Try *italic*': 'Try *italic*',
          '[Guide](https://exa': '',
          '[Guide](https://example.com)': '[Guide](https://example.com)',
          '---': '',
          '---\n': '---\n',
          '```da': '',
          '```dart\nprint(1);': '```dart\nprint(1);',
          '```dart\nprint(1);\n```\n': '```dart\nprint(1);\n```\n',
          '~~~dart\nprint(1);\n~~~\n': '~~~dart\nprint(1);\n~~~\n',
          '```dart\nprint(1);\n``': '```dart\nprint(1);\n',
          '| Name | Time |\n| --': '',
          '| Name | Time |\n| --- | --- |\n':
              '| Name | Time |\n| --- | --- |\n',
          r'literal \* and snake_case': r'literal \* and snake_case',
        }.entries) {
      expect(
        streamingMarkdownPrefix(entry.key),
        entry.value,
        reason: entry.key,
      );
    }
    for (var i = 0; i <= richReply.length; i++) {
      final source = richReply.substring(0, i);
      expect(
        source.startsWith(streamingMarkdownPrefix(source)),
        isTrue,
        reason: 'Every preview must be an exact prefix at chunk $i',
      );
    }
  });

  for (final width in [320.0, 360.0, 393.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('rich reply, long text and URLs fit $width at $scale', (
        tester,
      ) async {
        viewport(tester, width);
        await tester.pumpWidget(
          shell(
            Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ChatMessageCard(
                    message: ChatMessage(
                      id: 'rich',
                      role: 'bot',
                      saved: true,
                      text:
                          '$richReply\n\n${'unbroken' * 100}\n\nhttps://example.com/${'longpath' * 100}',
                    ),
                  ),
                ),
              ),
            ),
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(Table), findsOneWidget);
        expect(find.byType(ChatCodeBlock), findsOneWidget);
        expect(visibleText(tester), contains('A clear answer'));
        expect(visibleText(tester), contains('A nested idea'));
        expect(visibleText(tester), isNot(contains('**bold**')));
        expect(visibleText(tester), isNot(contains('| Choice |')));
        final horizontal = tester
            .widgetList<SingleChildScrollView>(
              find.byType(SingleChildScrollView),
            )
            .where((w) => w.scrollDirection == Axis.horizontal);
        expect(horizontal.length, 2);
        await tester.ensureVisible(find.text('Copy code'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'streamed blocks format before completion and flush literal incomplete syntax on Stop',
    (tester) async {
      viewport(tester, 320);
      final stream = ValueNotifier('');
      addTearDown(stream.dispose);
      final message = ChatMessage(
        id: 'stream',
        role: 'bot',
        text: '',
        state: ReplyState.streaming,
      );
      Widget card() => shell(
        Scaffold(
          body: SingleChildScrollView(
            child: ChatMessageCard(
              message: message,
              streamingText:
                  message.state == ReplyState.streaming ? stream : null,
            ),
          ),
        ),
      );
      await tester.pumpWidget(card());
      for (final chunk in [
        '## A title\n\n**bo',
        'ld** and *italic*.\n\n',
        '| Name | Time |\n| --',
        '- | --- |\n',
        '| Sketch | 15 minutes |\n\n',
        '```dart\n',
        'print("hello");',
        '\n```\n\n',
        'Unclosed **literal',
      ]) {
        message.text += chunk;
        stream.value = message.text;
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(MarkdownBody), findsOneWidget);
      }
      expect(find.byType(Table), findsOneWidget);
      expect(find.byType(ChatCodeBlock), findsOneWidget);
      expect(visibleText(tester), contains('A title'));
      expect(visibleText(tester), isNot(contains('**literal')));
      final original = message.text;
      message.state = ReplyState.stopped;
      await tester.pumpWidget(card());
      await tester.pump();
      expect(visibleText(tester), contains('**literal'));
      expect(message.text, original);
      expect(find.byTooltip('Copy message'), findsOneWidget);
    },
  );

  testWidgets('code scroll and Markdown identity survive stream completion', (
    tester,
  ) async {
    viewport(tester, 320);
    final source = '```dart\n${'long line ' * 50}\n```\n';
    final stream = ValueNotifier(source);
    addTearDown(stream.dispose);
    final message = ChatMessage(
      id: 'stable',
      role: 'bot',
      text: source,
      state: ReplyState.streaming,
    );
    Widget page() => shell(
      Scaffold(
        body: ChatMessageCard(
          message: message,
          streamingText: message.state == ReplyState.streaming ? stream : null,
        ),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(MarkdownBody));
    final codeState = tester.state(find.byType(ChatCodeBlock));
    final scroll =
        tester
            .widget<SingleChildScrollView>(
              find
                  .descendant(
                    of: find.byType(ChatCodeBlock),
                    matching: find.byType(SingleChildScrollView),
                  )
                  .first,
            )
            .controller!;
    scroll.jumpTo(120);
    await tester.pump();
    message
      ..state = ReplyState.complete
      ..saved = true;
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(MarkdownBody)), same(element));
    expect(tester.state(find.byType(ChatCodeBlock)), same(codeState));
    expect(scroll.offset, 120);
  });

  testWidgets(
    'large text keeps ordered markers and the regenerate label on one line',
    (tester) async {
      viewport(tester, 320);
      await tester.pumpWidget(
        shell(
          Scaffold(
            body: SingleChildScrollView(
              child: ChatMessageCard(
                message: ChatMessage(
                  id: 'large',
                  role: 'bot',
                  saved: true,
                  text: '1. One item\n2. Second item\n3. Third item',
                ),
                onRegenerate: () {},
              ),
            ),
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final one = find.text('1.');
      expect(one, findsOneWidget);
      expect(tester.getSize(one).height, lessThanOrEqualTo(50));
      final label = tester.getRect(find.text('Regenerate'));
      final button = tester.getRect(
        find
            .ancestor(
              of: find.text('Regenerate'),
              matching: find.byWidgetPredicate((w) => w is TextButton),
            )
            .first,
      );
      expect(button.contains(label.topLeft), isTrue);
      expect(button.bottom, greaterThanOrEqualTo(label.bottom));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('response actions have accessible labels and touch targets', (
    tester,
  ) async {
    viewport(tester, 393);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      shell(
        Scaffold(
          body: ChatMessageCard(
            message: ChatMessage(
              id: 'accessible',
              role: 'bot',
              saved: true,
              text: '```dart\nprint(1);\n```',
            ),
            onRegenerate: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('code and message copy preserve original content', (
    tester,
  ) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const source = '```dart\nfinal x = "**literal** | <tag> & text";\n```';
    await tester.pumpWidget(
      shell(
        Scaffold(
          body: ChatMessageCard(
            message: ChatMessage(
              id: 'copy',
              role: 'bot',
              text: source,
              saved: true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy code'));
    await tester.pump();
    expect(copied.last, 'final x = "**literal** | <tag> & text";\n');
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(copied.last, source);
  });

  for (final width in [320.0, 360.0, 393.0, 430.0]) {
    testWidgets(
      'composer grows, scrolls drafts, and clears the keyboard at $width',
      (tester) async {
        viewport(tester, width);
        final session = FakeSession();
        final repo = FakeRepository();
        final ai = FakeAi();
        final chat = ChatController(
          ai: ai,
          repository: repo,
          currentUid: () => session.uid,
        );
        addTearDown(() {
          chat.dispose();
          session.dispose();
          ai.close();
        });
        Widget page({double scale = 1, double keyboard = 0}) => shell(
          ChatScreen(session: session, controller: chat),
          scale: scale,
          keyboard: keyboard,
        );
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        final composer = find.byKey(const Key('chat-composer'));
        final emptyHeight = tester.getSize(composer).height;
        expect(emptyHeight, lessThan(110));
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Send message',
                ),
              )
              .onPressed,
          isNull,
        );
        final draft = List.generate(30, (i) => 'Draft line $i').join('\n');
        await tester.enterText(find.byKey(const Key('chat-input')), draft);
        await tester.pump();
        expect(tester.getSize(composer).height, greaterThan(emptyHeight));
        expect(tester.getSize(composer).height, lessThan(210));
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(page(scale: scale, keyboard: 310));
          await tester.pumpAndSettle();
          expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(542));
          expect(tester.takeException(), isNull);
          final editable = tester.state<EditableTextState>(
            find.byType(EditableText).last,
          );
          expect(editable.renderEditable.offset.pixels, greaterThan(0));
        }
        final id = chat.conversation.id;
        chat.newConversation();
        await tester.pumpAndSettle();
        await chat.open(id);
        await tester.pumpAndSettle();
        expect(chat.conversation.draft, draft);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('chat-input')))
              .controller!
              .text,
          draft,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'stream follow, queued scroll cancellation, Stop and regenerate preserve content',
    (tester) async {
      viewport(tester, 393);
      final session = FakeSession();
      final repo = FakeRepository();
      final ai = FakeAi();
      final chat = ChatController(
        ai: ai,
        repository: repo,
        currentUid: () => session.uid,
      );
      addTearDown(() {
        chat.dispose();
        session.dispose();
        ai.close();
      });
      for (var i = 0; i < 12; i++) {
        chat.conversation.messages.add(
          ChatMessage(
            id: 'old$i',
            role: i.isEven ? 'user' : 'bot',
            text: 'Earlier $i. ${'A useful explanation. ' * 20}',
            saved: true,
          ),
        );
      }
      await tester.pumpWidget(
        shell(ChatScreen(session: session, controller: chat)),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const Key('chat-message-list'));
      final position =
          tester
              .state<ScrollableState>(
                find
                    .descendant(of: list, matching: find.byType(Scrollable))
                    .first,
              )
              .position;
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'A new question',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();
      await tester.pump();
      ai.streams.last.add(
        '## Formatted now\n\n${'A growing paragraph. ' * 50}',
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(position.extentAfter, lessThan(2));
      // Schedule a follow, then move before its post-frame callback executes.
      chat.streamingText.value += '\n\nAnother paragraph';
      position.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0);
      ai.streams.last.add('\n\nMore real content');
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0);
      final source = chat.conversation.messages.last.text;
      await tester.tap(find.byTooltip('Stop generating'));
      await tester.pumpAndSettle();
      expect(chat.busy, isFalse);
      expect(ai.cancellations, greaterThan(0));
      expect(chat.conversation.messages.last.text, source);
      ai.streams.last.add('LATE');
      await tester.pump();
      expect(chat.conversation.messages.last.text, source);
      final retry = chat.retry();
      await tester.pump();
      await tester.pump();
      ai.streams.last.add('Completed retry');
      await ai.streams.last.close();
      await retry;
      await tester.pumpAndSettle();
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Regenerate'));
      await tester.tap(find.text('Regenerate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Regenerate').last);
      await tester.pump();
      await tester.pump();
      ai.streams.last.add('Alternative answer');
      await ai.streams.last.close();
      await tester.pumpAndSettle();
      expect(
        chat.conversation.messages.where((m) => m.text == 'Completed retry'),
        hasLength(1),
      );
      expect(
        chat.conversation.messages.where((m) => m.text == 'Alternative answer'),
        hasLength(1),
      );
      expect(
        chat.conversation.messages.map((m) => m.id).toSet().length,
        chat.conversation.messages.length,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
