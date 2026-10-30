import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'chat_diagnostics.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'backend_api_config.dart';
import 'backend_sse_decoder.dart';

export 'backend_api_config.dart' show BackendApiException;

class BackendAiService implements AiService, AiStreamDiagnostics {
  @override
  final ValueNotifier<ChatTrace> streamTrace = ValueNotifier(
    const ChatTrace('idle'),
  );
  final BackendApiConfig config;
  final http.Client Function() _clientFactory;
  final Future<String?> Function() _tokenProvider;
  final Set<http.Client> _clients = {};
  int _generation = 0;

  BackendAiService({
    this.config = const BackendApiConfig(),
    http.Client Function()? clientFactory,
    Future<String?> Function()? tokenProvider,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _tokenProvider = tokenProvider ?? _firebaseToken;

  static Future<String?> _firebaseToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) return null;
    try {
      // Firebase refreshes expired cached ID tokens. Revoked/disabled accounts
      // still fail backend verification; never silently retry an AI generation.
      final token = await user.getIdToken();
      if (FirebaseAuth.instance.currentUser?.uid != user.uid) return null;
      return token;
    } on FirebaseAuthException catch (error) {
      if (error.code == 'network-request-failed') {
        throw const BackendApiException(
          'auth_unavailable',
          'Could not verify your sign-in. Check your connection and retry.',
          retryable: true,
        );
      }
      throw const BackendApiException('invalid_token', 'Please sign in again.');
    }
  }

  Future<Map<String, String>> _headers() async {
    final token = await _tokenProvider();
    if (token == null || token.isEmpty) {
      throw const BackendApiException(
        'sign_in_required',
        'Sign in to use AI. Guest browsing remains available.',
      );
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  List<Map<String, String>> _history(List<Map<String, dynamic>> messages) =>
      messages
          .where((m) => (m['text'] as String? ?? '').isNotEmpty)
          .map(
            (m) => {
              'role': m['role'] == 'user' ? 'user' : 'assistant',
              'content': m['text'] as String,
            },
          )
          .toList();

  BackendApiException _error(Object? data) {
    if (data is Map && data['error'] is Map) {
      final detail = data['error'] as Map;
      if (detail['code'] is String &&
          detail['message'] is String &&
          (detail['message'] as String).length <= 300) {
        return BackendApiException(
          detail['code'] as String,
          detail['message'] as String,
          retryable: detail['retryable'] == true,
          requestId: safeRequestId(detail['request_id']),
        );
      }
    }
    return const BackendApiException(
      'backend_error',
      'AI backend could not process the request.',
      retryable: true,
    );
  }

  Future<String> _readBounded(http.StreamedResponse response, int limit) async {
    final bytes = BytesBuilder();
    await for (final chunk in response.stream.timeout(
      config.streamIdleTimeout,
    )) {
      if (bytes.length + chunk.length > limit) {
        throw const BackendApiException(
          'invalid_response',
          'AI backend returned an oversized response.',
        );
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<void> _checkStatus(http.StreamedResponse response) async {
    if (response.statusCode == 200) return;
    final body = await _readBounded(response, 65536);
    Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      /* Never display proxy HTML. */
    }
    throw _error(data);
  }

  @override
  Stream<String> streamMessage(
    List<Map<String, dynamic>> messages, {
    String? systemPrompt,
  }) async* {
    final generation = _generation;
    final client = _clientFactory();
    _clients.add(client);
    Timer? deadline;
    var timedOut = false;
    String? requestId;
    var outputCharacters = 0;
    var terminalReceived = false;
    void record(ChatTrace value) {
      if (_generation == generation) streamTrace.value = value;
      logChatTrace(value);
    }

    record(const ChatTrace('request_started'));
    try {
      final request = http.Request('POST', config.endpoint('/v1/chat/stream'));
      request.followRedirects = false;
      request.headers.addAll(
        await _headers().timeout(config.connectionTimeout),
      );
      if (_generation != generation) return;
      request.body = jsonEncode({
        'messages': _history(messages),
        // The server owns prompts; the legacy voice screen supplies systemPrompt.
        'mode': systemPrompt == null ? 'chat' : 'voice',
      });
      deadline = Timer(config.requestTimeout, () {
        timedOut = true;
        client.close();
      });
      final response = await client
          .send(request)
          .timeout(config.streamHeaderTimeout);
      requestId = safeRequestId(response.headers['x-request-id']);
      record(ChatTrace('response_headers', requestId: requestId));
      await _checkStatus(response);
      if (!(response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        throw const BackendApiException(
          'invalid_response',
          'AI backend returned an invalid stream.',
        );
      }
      var receivedText = false;

      await for (final frame in decodeBackendSse(
        response.stream.timeout(config.streamIdleTimeout),
      )) {
        if (_generation != generation) return;
        if (timedOut) throw TimeoutException('Request deadline');
        final event = frame.event;
        final payload = jsonDecode(frame.data);
        if (event == 'error') {
          terminalReceived = true;
          throw _error(payload);
        }
        if (event == 'done') {
          terminalReceived = true;
          if (payload is Map) {
            requestId ??= safeRequestId(payload['request_id']);
            final terminalId = safeRequestId(payload['request_id']);
            if (terminalId != null && requestId != terminalId) {
              throw const BackendApiException(
                'invalid_response',
                'AI returned a mismatched completion event.',
              );
            }
            final reason = payload['finish_reason'];
            record(
              ChatTrace(
                'terminal_received',
                requestId: requestId,
                finishReason: reason is String ? reason : 'unknown',
                characters: outputCharacters,
              ),
            );
            if (reason == 'length') {
              throw BackendApiException(
                'response_limit',
                'Response reached its length limit. Continue when you are ready.',
                requestId: requestId,
              );
            }
          }
          if (!receivedText ||
              payload is! Map ||
              payload['finish_reason'] != 'stop') {
            throw const BackendApiException(
              'incomplete_response',
              'AI did not complete its response. Please retry.',
              retryable: true,
            );
          }
          return;
        }
        if (event != 'delta' || payload is! Map || payload['text'] is! String) {
          throw const BackendApiException(
            'invalid_response',
            'AI backend returned an invalid event.',
          );
        }
        final text = payload['text'] as String;
        outputCharacters += text.runes.length;
        if (outputCharacters > 100000) {
          throw const BackendApiException(
            'invalid_response',
            'AI backend returned an oversized response.',
          );
        }
        if (text.isNotEmpty) {
          receivedText = receivedText || text.trim().isNotEmpty;
          yield text;
        }
      }
      if (_generation != generation) return;
      if (timedOut) throw TimeoutException('Request deadline');
      throw const BackendApiException(
        'incomplete_response',
        'AI connection ended before completion. Please retry.',
        retryable: true,
      );
    } on BackendApiException catch (error) {
      if (_generation != generation) return;
      record(
        ChatTrace(
          terminalReceived ? 'terminal_error' : 'request_error',
          requestId: error.requestId ?? requestId,
          category: error.code,
          characters: outputCharacters,
        ),
      );
      throw BackendApiException(
        error.code,
        error.message,
        retryable: error.retryable,
        requestId: error.requestId ?? requestId,
      );
    } on TimeoutException {
      if (_generation != generation) return;
      record(
        ChatTrace(
          'request_error',
          requestId: requestId,
          category: 'client_timeout',
          characters: outputCharacters,
        ),
      );
      throw BackendApiException(
        'backend_timeout',
        'AI backend timed out. Please retry.',
        retryable: true,
        requestId: requestId,
      );
    } on FormatException {
      if (_generation != generation) return;
      record(
        ChatTrace(
          'request_error',
          requestId: requestId,
          category: 'invalid_response',
          characters: outputCharacters,
        ),
      );
      throw BackendApiException(
        'invalid_response',
        'AI backend returned an invalid response.',
        requestId: requestId,
      );
    } catch (_) {
      if (_generation != generation) return;
      record(
        ChatTrace(
          'request_error',
          requestId: requestId,
          category: timedOut ? 'client_deadline' : 'network',
          characters: outputCharacters,
        ),
      );
      throw BackendApiException(
        timedOut ? 'backend_timeout' : 'backend_unavailable',
        timedOut
            ? 'AI backend timed out. Please retry.'
            : 'Cannot reach the AI backend. Check your connection and backend address.',
        retryable: true,
        requestId: requestId,
      );
    } finally {
      record(
        ChatTrace(
          _generation != generation ? 'cancelled' : 'transport_closed',
          requestId: requestId,
          category: terminalReceived ? 'terminal_received' : 'no_terminal',
          characters: outputCharacters,
        ),
      );
      deadline?.cancel();
      _clients.remove(client);
      client.close();
    }
  }

  @override
  Future<String> analyzeImage(
    Uint8List imageBytes,
    String prompt,
    List<Map<String, dynamic>> history,
  ) async {
    if (imageBytes.length > 5000000) {
      throw const BackendApiException(
        'image_too_large',
        'Choose an image smaller than 5 MB.',
      );
    }
    final generation = _generation;
    final client = _clientFactory();
    _clients.add(client);
    try {
      return await (() async {
        final request = http.Request(
          'POST',
          config.endpoint('/v1/images/analyze'),
        );
        request.followRedirects = false;
        request.headers.addAll(
          await _headers().timeout(config.connectionTimeout),
        );
        if (_generation != generation) {
          throw const BackendApiException('cancelled', 'Request cancelled.');
        }
        final turns = _history(history);
        if (turns.isNotEmpty &&
            turns.last['role'] == 'user' &&
            turns.last['content'] == prompt) {
          turns.removeLast();
        }
        request.body = jsonEncode({
          'image_base64': base64Encode(imageBytes),
          'mime_type': _mime(imageBytes),
          'prompt': prompt.isEmpty ? 'Describe this image.' : prompt,
          'history': turns,
        });
        // Image analysis sends its headers after the non-streaming result is ready.
        // The enclosing total deadline bounds this wait, not the short chat header timeout.
        final response = await client.send(request);
        await _checkStatus(response);
        final data = jsonDecode(await _readBounded(response, 1000000));
        if (_generation != generation) {
          throw const BackendApiException('cancelled', 'Request cancelled.');
        }
        if (data is! Map ||
            data['text'] is! String ||
            (data['text'] as String).trim().isEmpty) {
          throw const BackendApiException(
            'invalid_response',
            'AI backend returned an invalid image analysis response.',
          );
        }
        return data['text'] as String;
      })().timeout(config.requestTimeout);
    } on BackendApiException {
      rethrow;
    } on TimeoutException {
      throw const BackendApiException(
        'backend_timeout',
        'Image analysis timed out. Please retry.',
        retryable: true,
      );
    } on FormatException {
      throw const BackendApiException(
        'invalid_response',
        'AI backend returned an invalid response.',
      );
    } catch (_) {
      throw const BackendApiException(
        'backend_unavailable',
        'Cannot reach the AI backend. Check your connection and backend address.',
        retryable: true,
      );
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  String _mime(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    throw const BackendApiException(
      'invalid_image',
      'Choose a JPEG, PNG, or WebP image.',
    );
  }

  @override
  void cancelPendingRequests() {
    _generation++;
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
  }
}
