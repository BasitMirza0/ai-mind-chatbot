import 'dart:async';

import 'package:ai_chatbot/services/onboarding_store.dart';

class FakeOnboardingStore implements OnboardingStore {
  bool complete;
  bool failRead;
  bool failWrite;
  int reads = 0;
  int writes = 0;
  Completer<bool>? readGate;
  Completer<void>? writeGate;

  FakeOnboardingStore({this.complete = false, this.failRead = false, this.failWrite = false});

  @override
  Future<bool> isComplete() async {
    reads++;
    if (failRead) throw StateError('Test storage unavailable');
    return readGate == null ? complete : await readGate!.future;
  }

  @override
  Future<void> markComplete() async {
    writes++;
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError('Test storage unavailable');
    complete = true;
  }
}
