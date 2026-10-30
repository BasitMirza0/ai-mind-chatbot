import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/conversation.dart';
import '../services/sidebar_history_source.dart';

/// Owned by the chat route, not the transient Drawer subtree. Search updates
/// notify only sidebar listeners, and reopening never re-listens to a stream.
class SidebarController extends ChangeNotifier {
  final SidebarHistorySource source;
  StreamSubscription<SidebarPage>? _subscription;
  Timer? _debounce;
  bool _disposed = false;
  int _generation = 0, _pageRevision = 0;
  String? uid;
  String rawQuery = '', query = '';
  bool loading = false, loadingMore = false, searching = false;
  bool failed = false, moreFailed = false, isFromCache = false;
  bool hasMore = false, historyChanged = false;
  bool _olderFromCache = false;
  Object? _cursor;
  List<ConversationSummary> _recent = [], _older = [];
  SidebarController(this.source, String? user) { changeUser(user); }

  List<ConversationSummary> get items {
    final unique = <String, ConversationSummary>{};
    for (final item in [..._recent, ..._older]) {
      unique.putIfAbsent(item.id, () => item);
    }
    return sortSidebarConversations(unique.values);
  }
  bool matches(String title) => title.toLowerCase().contains(query);
  void _notify() { if (!_disposed) notifyListeners(); }

  void changeUser(String? user) {
    uid = user;
    _debounce?.cancel();
    rawQuery = query = '';
    searching = false;
    refresh();
  }

  void refresh() {
    final generation = ++_generation;
    _pageRevision++;
    _subscription?.cancel();
    _subscription = null;
    _recent = []; _older = []; _cursor = null; _olderFromCache = false;
    failed = moreFailed = loadingMore = hasMore = isFromCache = historyChanged = false;
    final owner = uid;
    loading = owner != null;
    _notify();
    if (owner == null) return;
    try {
      _subscription = source.watchRecent(owner).listen((page) {
        if (_disposed || generation != _generation) return;
        final changed = !_same(_recent, page.items);
        if (changed) {
          historyChanged = _older.isNotEmpty || loadingMore;
          _older = []; _olderFromCache = false; loadingMore = moreFailed = false;
          _pageRevision++;
        }
        // Metadata-only updates must not reset a valid pagination window.
        if (changed || _older.isEmpty) {
          _cursor = page.cursor;
          hasMore = page.hasMore;
        }
        _recent = page.items;
        isFromCache = page.isFromCache || _olderFromCache;
        loading = failed = false;
        _notify();
      }, onError: (Object _) {
        if (_disposed || generation != _generation) return;
        loading = false; failed = true;
        _notify();
      });
    } catch (_) {
      loading = false; failed = true;
      _notify();
    }
  }

  void setQuery(String value) {
    rawQuery = value;
    _debounce?.cancel();
    final next = value.trim().toLowerCase();
    searching = next != query && next.isNotEmpty;
    if (!searching) {
      query = next;
    } else {
      _debounce = Timer(const Duration(milliseconds: 250), () {
        query = next; searching = false; _notify();
      });
    }
    _notify();
  }

  Future<void> loadMore() async {
    final owner = uid, cursor = _cursor;
    if (owner == null || cursor == null || !hasMore || loadingMore || loading || failed) return;
    final generation = _generation, revision = _pageRevision;
    loadingMore = true; moreFailed = false;
    _notify();
    try {
      final page = await source.loadOlder(owner, cursor);
      if (_disposed || generation != _generation || revision != _pageRevision) return;
      _older = [..._older, ...page.items];
      _cursor = page.cursor;
      hasMore = page.hasMore;
      _olderFromCache = _olderFromCache || page.isFromCache;
      isFromCache = isFromCache || _olderFromCache;
      historyChanged = false;
    } catch (_) {
      if (_disposed || generation != _generation || revision != _pageRevision) return;
      moreFailed = true;
    } finally {
      if (!_disposed && generation == _generation && revision == _pageRevision) {
        loadingMore = false; _notify();
      }
    }
  }

  static bool _same(List<ConversationSummary> a, List<ConversationSummary> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].title != b[i].title ||
          a[i].type != b[i].type || a[i].updatedAt != b[i].updatedAt) { return false; }
    }
    return true;
  }
  @override void dispose() {
    _disposed = true; _generation++;
    _debounce?.cancel(); _subscription?.cancel();
    super.dispose();
  }
}

List<ConversationSummary> sortSidebarConversations(Iterable<ConversationSummary> items) =>
  items.toList()..sort((a, b) {
    final x = a.updatedAt, y = b.updatedAt;
    if (x == null && y != null) return 1;
    if (y == null && x != null) return -1;
    final date = x == null ? 0 : y!.compareTo(x);
    return date == 0 ? b.id.compareTo(a.id) : date;
  });

/// Calendar boundaries, not 24-hour durations (which break around DST).
String sidebarDateGroup(DateTime? date, DateTime now) {
  if (date == null) return 'Date unavailable';
  final local = date.toLocal(), current = now.toLocal();
  final today = DateTime(current.year, current.month, current.day);
  final tomorrow = DateTime(current.year, current.month, current.day + 1);
  if (!local.isBefore(tomorrow)) return 'Future dates';
  if (!local.isBefore(today)) return 'Today';
  if (!local.isBefore(DateTime(current.year, current.month, current.day - 1))) return 'Yesterday';
  if (!local.isBefore(DateTime(current.year, current.month, current.day - 7))) return 'Previous 7 days';
  return 'Older';
}
