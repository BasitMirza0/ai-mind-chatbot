import 'package:ai_chatbot/widgets/chat_markdown.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  testWidgets(
    'wide prose tables wrap cells and scroll at narrow widths and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [320.0, 360.0, 393.0, 430.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: const TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: ChatMarkdown(
                      text:
                          '| Course | Schedule | Outcome |\n| --- | --- | --- |\n| A detailed description of the course and its prerequisites | Weekly reading and practice | A completed research project |',
                      onOpenLink: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final table = tester.widget<Table>(find.byType(Table));
        expect(table.defaultColumnWidth, isA<FixedColumnWidth>());
        expect(
          tester.getSize(find.byType(Table)).width,
          greaterThan(width - 36),
        );
        final horizontal = find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        );
        expect(horizontal, findsOneWidget);
        await tester.drag(horizontal, const Offset(-150, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'ordinary checklists remain prose and long fences offer bounded previews',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Widget app(String text) => MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: ChatMarkdown(text: text, onOpenLink: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        app('## Checklist\n\n- Choose a course\n- Make a plan'),
      );
      expect(find.byType(ChatCodeBlock), findsNothing);
      final source = List.generate(
        100,
        (i) => 'Item $i: a detailed checklist line',
      ).join('\n');
      await tester.pumpWidget(app('```text\n$source\n```'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ChatCodeBlock)).height, lessThan(340));
      expect(find.text('Show full block (101 lines)'), findsOneWidget);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.text('Copy code'));
      await tester.pump();
      expect(copied, '$source\n');
      await tester.tap(find.text('Show full block (101 lines)'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ChatCodeBlock)).height,
        greaterThan(340),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
