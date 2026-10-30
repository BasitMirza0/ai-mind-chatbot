import 'package:ai_chatbot/controllers/sidebar_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/sidebar_history_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_sidebar_source.dart';

void main() {
  test('real timestamps sort deterministically; calendar groups handle boundaries and missing dates', () {
    final now = DateTime(2026, 10, 27, 14);
    expect(sidebarDateGroup(DateTime(2026, 10, 27), now), 'Today');
    expect(sidebarDateGroup(DateTime(2026, 10, 26, 23, 59), now), 'Yesterday');
    expect(sidebarDateGroup(DateTime(2026, 10, 20), now), 'Previous 7 days');
    expect(sidebarDateGroup(DateTime(2026, 10, 19, 23, 59), now), 'Older');
    expect(sidebarDateGroup(DateTime(2026, 10, 28), now), 'Future dates');
    expect(sidebarDateGroup(null, now), 'Date unavailable');
    expect(sidebarDateGroup(DateTime(2025, 12, 31), DateTime(2026, 1, 1)), 'Yesterday');
    final sorted = sortSidebarConversations([
      const ConversationSummary('missing', 'No timestamp'),
      ConversationSummary('a', 'Same date', updatedAt: now),
      ConversationSummary('b', 'Same date', updatedAt: now),
      ConversationSummary('old', 'Older', updatedAt: DateTime(2020)),
    ]);
    expect(sorted.map((c) => c.id), ['b', 'a', 'old', 'missing']);
  });

  testWidgets('search trims, ignores case, debounces, clears immediately and never fetches', (t) async {
    final source = FakeSidebarSource();
    final controller = SidebarController(source, 'alice');
    addTearDown(() { controller.dispose(); source.dispose(); });
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'A Quiet Idea')]));
    await t.pump();
    controller.setQuery('  QUI'); await t.pump(const Duration(milliseconds: 200));
    expect(controller.query, ''); expect(controller.searching, true);
    controller.setQuery('  QUIET  '); await t.pump(const Duration(milliseconds: 249));
    expect(controller.query, ''); await t.pump(const Duration(milliseconds: 1));
    expect(controller.query, 'quiet'); expect(controller.matches('A Quiet Idea'), true);
    expect(controller.matches('A plan'), false);
    controller.setQuery(''); expect(controller.query, ''); expect(controller.searching, false);
    controller.setQuery('   '); expect(controller.query, '');
    expect(source.watches, ['alice']); expect(source.loads, isEmpty);
  });

  testWidgets('pagination is explicit, rejects duplicate taps, deduplicates and recovers from errors', (t) async {
    final source = FakeSidebarSource(); final c = SidebarController(source, 'alice');
    addTearDown(() { c.dispose(); source.dispose(); });
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'Recent')], cursor: 'first', hasMore: true));
    await t.pump(); expect(source.loads, isEmpty);
    final first = c.loadMore(); await c.loadMore(); expect(source.loads, [('alice', 'first')]);
    source.pending.last.completeError(StateError('offline')); await first;
    expect(c.moreFailed, true); expect(c.loadingMore, false); expect(c.items.length, 1);
    final retry = c.loadMore();
    source.pending.last.complete(const SidebarPage([ConversationSummary('a', 'Duplicate'), ConversationSummary('b', 'Older')]));
    await retry; expect(c.items.length, 2); expect(c.items.firstWhere((c) => c.id == 'a').title, 'Recent');
    expect(c.hasMore, false); expect(c.moreFailed, false);
    await c.loadMore(); expect(source.loads.length, 2);
  });

  testWidgets('identity change clears search and ignores late pages and old stream events', (t) async {
    final source = FakeSidebarSource(); final c = SidebarController(source, 'alice');
    addTearDown(() { c.dispose(); source.dispose(); });
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'Private A')], cursor: 'a', hasMore: true));
    await t.pump(); c.setQuery('private'); final pending = c.loadMore();
    c.changeUser('bob'); expect(c.items, isEmpty); expect(c.rawQuery, '');
    source.pending.single.complete(const SidebarPage([ConversationSummary('late', 'Private late')]));
    await pending;
    source.emit('alice', const SidebarPage([ConversationSummary('late2', 'Old identity')]));
    source.emit('bob', const SidebarPage([ConversationSummary('b', 'Owned by B')]));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.items.map((c) => c.id), ['b']); expect(c.query, ''); expect(c.loading, false);
    c.changeUser(null); expect(c.items, isEmpty); expect(c.loading, false); expect(source.watches, ['alice', 'bob']);
  });

  testWidgets('new live window invalidates stale cursors but metadata-only updates keep older pages', (t) async {
    final source = FakeSidebarSource(); final c = SidebarController(source, 'alice');
    addTearDown(() { c.dispose(); source.dispose(); });
    const recent = [ConversationSummary('a', 'Recent')];
    source.emit('alice', const SidebarPage(recent, cursor: 'a', hasMore: true)); await t.pump();
    final old = c.loadMore(); source.pending.last.complete(const SidebarPage([ConversationSummary('b', 'Older')], cursor: 'b', hasMore: true, isFromCache: true));
    await old;
    source.emit('alice', const SidebarPage(recent, cursor: 'a', hasMore: true)); await t.pump();
    expect(c.items.length, 2); expect(c.isFromCache, true);
    final late = c.loadMore(); expect(source.loads.last.$2, 'b');
    source.emit('alice', const SidebarPage([ConversationSummary('new', 'New activity')], cursor: 'new', hasMore: true)); await t.pump();
    source.pending.last.complete(const SidebarPage([ConversationSummary('late', 'Obsolete window')])); await late;
    expect(c.items.map((c) => c.id), ['new']); expect(c.historyChanged, true); expect(c.loadingMore, false);
    final next = c.loadMore(); expect(source.loads.last.$2, 'new');
    source.pending.last.complete(const SidebarPage([])); await next;
  });

  testWidgets('loading, failure, cache, recovery and disposed callbacks remain safe', (t) async {
    final source = FakeSidebarSource(); final c = SidebarController(source, 'alice');
    expect(c.loading, true);
    source.streams['alice']!.addError(StateError('offline')); await t.pump();
    expect(c.failed, true); expect(c.loading, false);
    source.emit('alice', const SidebarPage([], isFromCache: true)); await t.pump();
    expect(c.failed, false); expect(c.isFromCache, true);
    c.refresh(); expect(c.loading, true);
    source.emit('alice', const SidebarPage([ConversationSummary('a', 'A')], cursor: 'a', hasMore: true)); await t.pump();
    final late = c.loadMore(); c.setQuery('pending'); c.dispose();
    source.pending.last.completeError(StateError('after dispose')); await late;
    await t.pump(const Duration(seconds: 1)); expect(t.takeException(), isNull); source.dispose();
  });
}
