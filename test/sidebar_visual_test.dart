import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/services/sidebar_history_source.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_sidebar_source.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  testWidgets('render sidebar comparisons and search/history states with synthetic profiles only', (t) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio); addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetViewInsets);
    final boundary = GlobalKey();
    Future<void> render(String name, Size size, {double scale = 1, String? query,
      bool guest = false, bool empty = false, bool error = false, bool loading = false,
      bool cached = false, bool keyboard = false, bool comparison = false}) async {
      t.view.physicalSize = size;
      final session = FakeSession(user: guest ? null : 'alice');
      final source = FakeSidebarSource(); final repo = FakeRepository(); final ai = FakeAi();
      final chat = ChatController(ai: ai, repository: repo, currentUid: () => session.uid);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final items = comparison ? [
        const ConversationSummary('one', 'A little room for creativity'),
        const ConversationSummary('two', 'Finding the right words'),
      ] : [
        ConversationSummary('one', 'A little room for creativity', updatedAt: today.add(const Duration(hours: 10))),
        ConversationSummary('two', 'Finding the right words', updatedAt: today.add(const Duration(hours: 8))),
        ConversationSummary('three', 'A calmer weekly routine', updatedAt: DateTime(now.year, now.month, now.day - 1, 18)),
        ConversationSummary('four', 'Notes from a voice conversation', type: 'voice', updatedAt: DateTime(now.year, now.month, now.day - 3)),
        ConversationSummary('five', 'Ideas for a small creative project', updatedAt: DateTime(now.year, now.month, now.day - 15)),
      ];
      repo.records['one'] = [ChatMessage(id: 'saved', role: 'user', text: 'Help me find more time for creative work.', saved: true)];
      if (!guest && !empty) await chat.open('one');
      await t.pumpWidget(RepaintBoundary(key: boundary, child: MaterialApp(debugShowCheckedModeBanner: false,
        theme: AppTheme.light, builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(
          disableAnimations: true, textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 24, bottom: 24), viewPadding: const EdgeInsets.only(top: 24, bottom: 24)), child: child!),
        home: ChatScreen(session: session, controller: chat, sidebarSource: source))));
      await t.pump();
      if (!guest && !loading) {
        if (error) { source.streams['alice']!.addError(StateError('offline')); }
        else { source.emit('alice', SidebarPage(empty ? [] : items, isFromCache: cached)); }
      }
      await t.pump(); await t.tap(find.byKey(const Key('chat-menu')));
      await t.pump(); await t.pump(const Duration(milliseconds: 500));
      if (query != null) {
        await t.enterText(find.byKey(const Key('drawer-search')), query);
        await t.pump(const Duration(milliseconds: 300));
      }
      if (keyboard) { t.view.viewInsets = const FakeViewPadding(bottom: 300); await t.pump(); }
      await capturePreview(t, boundary, '../phase2c2/after_sidebar_$name');
      expect(t.takeException(), isNull);
      t.view.resetViewInsets();
      await t.pumpWidget(const SizedBox.shrink()); await t.pump();
      chat.dispose(); session.dispose(); source.dispose(); await ai.close();
    }
    for (final size in [const Size(360, 800), const Size(393, 852), const Size(430, 932), const Size(852, 393)]) {
      await render('${size.width.toInt()}x${size.height.toInt()}', size, comparison: true);
    }
    const portrait = Size(393, 852);
    await render('grouped', portrait);
    await render('search', portrait, query: 'creative');
    await render('no_results', portrait, query: 'holiday');
    await render('empty', portrait, empty: true);
    await render('loading', portrait, loading: true);
    await render('error', portrait, error: true);
    await render('cached', portrait, cached: true);
    await render('guest', portrait, guest: true);
    await render('keyboard', portrait, query: 'creative', keyboard: true);
    await render('text200', portrait, scale: 2);
  });
}
