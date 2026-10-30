import 'package:flutter/foundation.dart';

/// Public endpoint configuration only. Provider secrets never enter Flutter.
class BackendApiConfig {
  final String baseUrl;
  final bool allowLocalHttp;
  final Duration connectionTimeout;
  final Duration streamHeaderTimeout;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;

  const BackendApiConfig({
    this.baseUrl = const String.fromEnvironment('AI_MIND_BACKEND_URL'),
    this.allowLocalHttp = kDebugMode,
    this.connectionTimeout = const Duration(seconds: 25),
    // Allow the server's configurable 300s generation / 120s idle bounds
    // plus authentication and transport margin; never preempt its terminal event.
    this.streamHeaderTimeout = const Duration(seconds: 320),
    this.streamIdleTimeout = const Duration(seconds: 130),
    this.requestTimeout = const Duration(seconds: 330),
  });

  Uri endpoint(String path) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const BackendApiException(
        'backend_not_configured',
        'AI backend is not configured. Set AI_MIND_BACKEND_URL.',
      );
    }
    final localHttp =
        kDebugMode &&
        allowLocalHttp &&
        uri.scheme == 'http' &&
        const ['localhost', '127.0.0.1', '10.0.2.2', '::1'].contains(uri.host);
    if (uri.scheme != 'https' && !localHttp) {
      throw const BackendApiException(
        'unsafe_backend_url',
        'AI backend requires HTTPS. Local HTTP is available in debug builds only.',
      );
    }
    return uri.replace(path: path);
  }
}

class BackendApiException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  final String? requestId;

  const BackendApiException(
    this.code,
    this.message, {
    this.retryable = false,
    this.requestId,
  });

  @override
  String toString() => message;
}
