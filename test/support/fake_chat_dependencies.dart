import 'dart:async';
import 'dart:typed_data';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/services/ai_service.dart';
import 'package:ai_chatbot/services/app_session.dart';
import 'package:ai_chatbot/services/conversation_repository.dart';
import 'package:ai_chatbot/services/sidebar_history_source.dart';

class FakeSession extends AppSession {
  String? user;
  String displayName;
  String? photo;
  @override String? get photoUrl => photo;
  FakeSession({this.user = 'alice', this.displayName = 'Alex Morgan'});
  @override String? get uid => user;
  @override String get name => displayName;
  void change(String? value) { user = value; notifyListeners(); }
  @override Future<void> signOut() async => change(null);
}
class FakeRepository implements ConversationRepository, SidebarHistorySource {
  int _next = 0;
  final Map<String, List<ChatMessage>> records = {};
  final List<(String, String, String)> writes = [];
  final List<String> created = [];
  final List<String> deleted = [];
  final List<(String, String, String)> renamed = [];
  final Map<String, Completer<List<ChatMessage>>> loads = {};
  Completer<void>? createGate, saveGate;
  bool failCreate = false, failSave = false, failLoad = false;
  bool failBotSave = false;
  List<ConversationSummary> summaries = [];
  Stream<List<ConversationSummary>>? history;
  @override Stream<SidebarPage> watchRecent(String uid) => watch(uid).map((items) => SidebarPage(items));
  @override Future<SidebarPage> loadOlder(String uid, Object cursor) async => const SidebarPage([]);
  @override String newId() => 'id-${++_next}';
  @override Stream<List<ConversationSummary>> watch(String uid) => history ?? Stream.value(summaries);
  @override Future<List<ChatMessage>> load(String uid, String chatId) async {
    if (loads.containsKey(chatId)) return loads[chatId]!.future;
    if (failLoad) throw StateError('offline');
    return records[chatId] ?? [];
  }
  @override Future<ConversationSummary?> summary(String uid, String chatId) async {
    for (final item in summaries) { if (item.id == chatId) return item; }
    return null;
  }
  @override Future<void> create(String uid, String chatId, String title, {String type = 'chat'}) async {
    if (createGate != null) await createGate!.future;
    if (failCreate) throw StateError('offline');
    if (!created.contains(chatId)) created.add(chatId);
  }
  @override Future<void> save(String uid, String chatId, ChatMessage message) async {
    if (saveGate != null) await saveGate!.future;
    if (failSave || (failBotSave && message.role == 'bot')) throw StateError('offline');
    if (!writes.any((w) => w.$1 == uid && w.$2 == chatId && w.$3 == message.id)) {
      writes.add((uid, chatId, message.id));
      records.putIfAbsent(chatId, () => []).add(ChatMessage(id: message.id,
        role: message.role, text: message.text, saved: true));
    }
  }
  @override Future<void> delete(String uid, String chatId) async { deleted.add(chatId); records.remove(chatId); }
  @override Future<void> rename(String uid, String chatId, String title) async { renamed.add((uid, chatId, title)); }
}
class FakeAi implements AiService {
  final List<StreamController<String>> streams = [];
  final List<List<Map<String, dynamic>>> histories = [];
  int cancellations = 0, imageCalls = 0;
  Completer<String>? imageGate;
  @override Stream<String> streamMessage(List<Map<String, dynamic>> messages, {String? systemPrompt}) {
    histories.add(messages);
    final stream = StreamController<String>(); streams.add(stream); return stream.stream;
  }
  @override Future<String> analyzeImage(Uint8List imageBytes, String prompt, List<Map<String, dynamic>> history) async {
    imageCalls++; return imageGate?.future ?? Future.value('An image description.');
  }
  @override void cancelPendingRequests() { cancellations++; }
  Future<void> close() async { for (final s in streams) { if (!s.isClosed) unawaited(s.close()); } }
}
Future<void> tick() => Future<void>.delayed(Duration.zero);
