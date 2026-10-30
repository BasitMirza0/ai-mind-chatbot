import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/services/sidebar_history_source.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/chat_sidebar.dart';
import 'package:ai_chatbot/widgets/profile_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_sidebar_source.dart';
import 'support/visual_capture.dart';

void main() {
  setUpAll(loadPreviewFonts);
  Future<(FakeSession, FakeSidebarSource, ChatController)> open(WidgetTester t,
      {Size size = const Size(393, 852), double scale = 1, bool guest = false}) async {
    t.view.devicePixelRatio = 1; t.view.physicalSize = size;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio); addTearDown(t.view.resetViewInsets);
    final session = FakeSession(user: guest ? null : 'alice');
    final source = FakeSidebarSource(); final repo = FakeRepository(); final ai = FakeAi();
    repo.records['a'] = [ChatMessage(id: 'message-a', role: 'bot', text: 'Owned saved answer', saved: true)];
    final chat = ChatController(ai: ai, repository: repo, currentUid: () => session.uid);
    addTearDown(() { chat.dispose(); session.dispose(); source.dispose(); ai.close(); });
    await t.pumpWidget(MaterialApp(theme: AppTheme.light,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(
        disableAnimations: true, textScaler: TextScaler.linear(scale)), child: child!),
      home: ChatScreen(session: session, controller: chat, sidebarSource: source)));
    await t.pump(); await t.tap(find.byKey(const Key('chat-menu'))); await t.pump(); await t.pump(const Duration(milliseconds: 400));
    return (session, source, chat);
  }

  testWidgets('search is local to sidebar, trims/case folds, clears and dismisses keyboard on selection', (t) async {
    final (_, source, chat) = await open(t);
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'Quiet ideas'), ConversationSummary('b', 'Weekend plan')]));
    await t.pumpAndSettle();
    final scaffold = t.widget<Scaffold>(find.byType(Scaffold).first);
    await t.enterText(find.byKey(const Key('drawer-search')), '  QUIET  ');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Weekend plan'), findsNothing); expect(find.text('Quiet ideas'), findsOneWidget);
    expect(identical(t.widget<Scaffold>(find.byType(Scaffold).first), scaffold), true);
    expect(source.watches, ['alice']); expect(source.loads, isEmpty);
    await t.tap(find.byTooltip('Clear search')); await t.pump(); expect(find.text('Weekend plan'), findsOneWidget);
    await t.enterText(find.byKey(const Key('drawer-search')), 'unmatched'); await t.pump(const Duration(milliseconds: 300));
    expect(find.text('No matching conversations.'), findsOneWidget);
    await t.tap(find.byTooltip('Clear search')); await t.pump();
    expect(t.testTextInput.isVisible, true);
    await t.tap(find.text('Quiet ideas')); await t.pumpAndSettle();
    expect(t.testTextInput.isVisible, false); expect(chat.conversation.id, 'a');
    expect(chat.conversation.messages.single.text, 'Owned saved answer');
    await t.tap(find.byKey(const Key('chat-menu'))); await t.pumpAndSettle();
    expect(t.widget<SidebarConversationRow>(find.byKey(const ValueKey('sidebar-a'))).selected, true);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search persists on reopen, account changes clear it and update profile identity', (t) async {
    final (session, source, _) = await open(t);
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'Alice title')])); await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('drawer-search')), 'alice'); await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byTooltip('Close history')); await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-menu'))); await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byKey(const Key('drawer-search'))).controller!.text, 'alice');
    expect(source.watches, ['alice']);
    session.displayName = 'Blair'; session.change('bob'); await t.pump();
    source.emit('bob', const SidebarPage([ConversationSummary('b', 'Bob title')])); await t.pumpAndSettle();
    expect(find.text('Alice title'), findsNothing); expect(find.text('Bob title'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('drawer-search'))).controller!.text, '');
    expect(t.widget<ProfileAvatar>(find.byType(ProfileAvatar)).uid, 'bob');
    expect(find.text('Blair'), findsOneWidget);
    session.change(null); await t.pumpAndSettle();
    expect(find.text('Bob title'), findsNothing); expect(find.text('Your conversations belong to you'), findsOneWidget);
    expect(t.widget<ProfileAvatar>(find.byType(ProfileAvatar)).uid, isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit load older, errors/retry, cached state and title scope are visible', (t) async {
    final (_, source, _) = await open(t);
    expect(find.bySemanticsLabel('Loading history'), findsOneWidget);
    source.streams['alice']!.addError(StateError('offline')); await t.pumpAndSettle();
    expect(find.text('History is unavailable'), findsOneWidget);
    await t.tap(find.text('Retry history')); await t.pump();
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'First title')], cursor: 'first', hasMore: true, isFromCache: true)); await t.pumpAndSettle();
    expect(find.textContaining('Showing cached history'), findsOneWidget);
    expect(find.text('Search covers loaded titles only.'), findsOneWidget);
    await t.tap(find.text('Load older conversations')); await t.pump();
    expect(source.loads, [('alice', 'first')]); expect(find.text('Loading older conversations…'), findsOneWidget);
    source.pending.last.completeError(StateError('offline')); await t.pumpAndSettle();
    await t.tap(find.text('Retry older conversations')); await t.pump();
    source.pending.last.complete(const SidebarPage([ConversationSummary('older', 'An older idea')])); await t.pumpAndSettle();
    expect(find.text('An older idea'), findsOneWidget); expect(find.text('Load older conversations'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('New chat preserves authenticated draft and saved list data', (t) async {
    final (_, source, chat) = await open(t);
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'Saved title')])); await t.pumpAndSettle();
    await t.tap(find.byTooltip('Close history')); await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('chat-input')), 'Keep this draft');
    final previous = chat.conversation.id;
    await t.tap(find.byKey(const Key('chat-menu'))); await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sidebar-new-chat'))); await t.pumpAndSettle();
    expect(chat.conversation.id, isNot(previous)); expect(chat.conversation.draft, '');
    await chat.open(previous); expect(chat.conversation.draft, 'Keep this draft');
    await t.pumpAndSettle(); await t.tap(find.byKey(const Key('chat-menu'))); await t.pumpAndSettle();
    expect(find.text('Saved title'), findsOneWidget); expect(source.watches, ['alice']);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('guest can start a new draft without querying private history', (t) async {
    final (_, source, chat) = await open(t, guest: true);
    expect(source.watches, isEmpty); expect(find.text('Sign in'), findsOneWidget);
    final previous = chat.conversation.id;
    await t.tap(find.byKey(const Key('sidebar-new-chat'))); await t.pumpAndSettle();
    expect(chat.conversation.id, isNot(previous)); expect(source.watches, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(320, 568), const Size(360, 800), const Size(393, 852), const Size(430, 932), const Size(852, 393)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('sidebar fits $size at text $scale; keyboard, scrolling and Back remain usable', (t) async {
        final (session, source, _) = await open(t, size: size, scale: scale);
        session.displayName = 'Alexandria Morgan with a long family name'; session.notifyListeners();
        source.emit('alice', SidebarPage(List.generate(80, (i) => ConversationSummary('item$i',
          'A thoughtful conversation with a long title number $i', updatedAt: DateTime.now().subtract(Duration(days: i))))));
        await t.pumpAndSettle(); expect(t.takeException(), isNull);
        // Lazy rows stay bounded to the viewport even when many pages are loaded.
        expect(find.byType(SidebarConversationRow).evaluate().length, lessThan(30));
        await t.ensureVisible(find.byKey(const Key('drawer-search')));
        await t.enterText(find.byKey(const Key('drawer-search')), 'number 7');
        t.view.viewInsets = FakeViewPadding(bottom: size.height < 500 ? 180 : 300);
        await t.pumpAndSettle();
        await t.ensureVisible(find.byKey(const Key('drawer-search'))); await t.pumpAndSettle();
        expect(find.byTooltip('Clear search').hitTestable(), findsOneWidget);
        expect(t.getRect(find.byKey(const Key('drawer-search'))).bottom, lessThanOrEqualTo(size.height - t.view.viewInsets.bottom + 1));
        await t.tap(find.byTooltip('Clear search')); await t.pumpAndSettle(); expect(t.takeException(), isNull);
        t.view.resetViewInsets(); await t.pumpAndSettle();
        await t.binding.handlePopRoute(); await t.pumpAndSettle();
        expect(find.byTooltip('Close history').hitTestable(), findsNothing); expect(find.byType(ChatScreen), findsOneWidget);
        expect(t.testTextInput.isVisible, false); expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('sidebar controls have accessible targets, labels and text contrast', (t) async {
    final semantics = t.ensureSemantics();
    final (_, source, _) = await open(t);
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'A saved idea')])); await t.pumpAndSettle();
    await expectLater(t, meetsGuideline(androidTapTargetGuideline));
    await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(t, meetsGuideline(textContrastGuideline));
    semantics.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });
}
