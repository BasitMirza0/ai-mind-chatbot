import 'dart:async';
import 'package:ai_chatbot/services/sidebar_history_source.dart';

class FakeSidebarSource implements SidebarHistorySource {
  final streams = <String, StreamController<SidebarPage>>{};
  final watches = <String>[];
  final loads = <(String, Object)>[];
  final pending = <Completer<SidebarPage>>[];
  @override Stream<SidebarPage> watchRecent(String uid) {
    watches.add(uid);
    return streams.putIfAbsent(uid, () => StreamController<SidebarPage>.broadcast()).stream;
  }
  void emit(String uid, SidebarPage page) => streams[uid]!.add(page);
  @override Future<SidebarPage> loadOlder(String uid, Object cursor) {
    loads.add((uid, cursor));
    final result = Completer<SidebarPage>(); pending.add(result);
    return result.future;
  }
  void dispose() {
    for (final stream in streams.values) { unawaited(stream.close()); }
  }
}
