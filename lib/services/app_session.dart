import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';

abstract class AppSession extends ChangeNotifier {
  String? get uid;
  String get name;
  String? get photoUrl => null;
  Future<void> signOut();
}

class FirebaseAppSession extends AppSession {
  late final StreamSubscription<User?> _subscription;
  FirebaseAppSession() {
    _subscription = FirebaseAuth.instance.userChanges().listen((_) => notifyListeners());
  }
  User? get _user => FirebaseAuth.instance.currentUser;
  @override String? get uid => _user?.isAnonymous == false ? _user?.uid : null;
  @override String get name => _user?.displayName?.trim().isNotEmpty == true
      ? _user!.displayName!.trim() : _user?.email?.split('@').first ?? 'Guest';
  @override String? get photoUrl {
    final user = _user;
    if (user == null || user.isAnonymous) return null;
    if (user.photoURL?.trim().isNotEmpty == true) return user.photoURL;
    for (final provider in user.providerData) {
      if (provider.providerId == 'google.com' && provider.photoURL?.trim().isNotEmpty == true) return provider.photoURL;
    }
    return null;
  }
  @override Future<void> signOut() => AuthService().logout();
  @override void dispose() { unawaited(_subscription.cancel()); super.dispose(); }
}
