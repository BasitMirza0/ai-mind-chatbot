import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/services/speech_output.dart';

class FakeSpeechDriver implements SpeechDriver {
  bool permitted = true;
  int initializations = 0, listens = 0, cancels = 0;
  String? locale;
  void Function(String)? status, error;
  void Function(SpeechText)? result;
  Completer<bool>? permissionGate;
  SpeechText? lastResult;
  bool finalOnStop = true;
  Object? initializationError;
  int finishes = 0;
  @override
  Future<bool> initialize({
    required void Function(String) onStatus,
    required void Function(String) onError,
  }) async {
    initializations++;
    status = onStatus;
    error = onError;
    if (initializationError != null) throw initializationError!;
    return permissionGate?.future ?? Future.value(permitted);
  }

  @override
  Future<void> listen({
    String? locale,
    required void Function(SpeechText) onResult,
  }) async {
    listens++;
    this.locale = locale;
    lastResult = null;
    result = (value) {
      lastResult = value;
      onResult(value);
    };
  }

  @override
  Future<void> stop() async {
    finishes++;
    if (finalOnStop) {
      result?.call(
        SpeechText(
          lastResult?.words ?? '',
          true,
          confidence: lastResult?.confidence,
        ),
      );
    }
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<List<SpeechLanguage>> languages() async => const [
    SpeechLanguage('en_US', 'English'),
    SpeechLanguage('ur_PK', 'Urdu'),
  ];
}

class FakeSpeechOutput implements SpeechOutput {
  final spoken = <String>[];
  final locales = <String?>[];
  Completer<void>? pending;
  int stops = 0;
  Object? owner;
  @override
  Future<void> speak(
    Object owner,
    String text, {
    String? locale,
    VoidCallback? onStart,
  }) async {
    this.owner = owner;
    spoken.add(text);
    locales.add(locale);
    pending = Completer();
    onStart?.call();
    await pending!.future;
  }

  @override
  Future<void> stop(Object owner) async {
    if (!identical(owner, this.owner)) return;
    stops++;
    this.owner = null;
    if (pending?.isCompleted == false) pending!.complete();
  }

  void complete() {
    if (pending?.isCompleted == false) pending!.complete();
  }
}
