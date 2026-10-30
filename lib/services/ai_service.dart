import 'dart:typed_data';

abstract interface class AiService {
  Stream<String> streamMessage(List<Map<String, dynamic>> messages,
      {String? systemPrompt});
  Future<String> analyzeImage(Uint8List imageBytes, String prompt,
      List<Map<String, dynamic>> history);
  void cancelPendingRequests();
}
