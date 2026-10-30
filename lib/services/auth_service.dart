import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

abstract interface class AuthGateway {
  Future<String?> signUp(String email, String password);
  Future<String?> login(String email, String password);
  Future<String?> signInWithGoogle();
  Future<String?> resetPassword(String email);
  Future<void> logout();
}

class AuthService implements AuthGateway {
  final FirebaseAuth _auth;
  final GoogleSignIn _googleSignIn;
  AuthService({FirebaseAuth? auth, GoogleSignIn? googleSignIn})
      : _auth = auth ?? FirebaseAuth.instance,
        _googleSignIn = googleSignIn ?? GoogleSignIn();
  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  static String safeError(String code) => switch (code) {
    'network-request-failed' => 'Cannot connect. Check your connection and try again.',
    'too-many-requests' => 'Too many attempts. Please wait before trying again.',
    'weak-password' => 'Choose a stronger password with at least 6 characters.',
    'invalid-email' => 'Enter a valid email address.',
    _ => 'Could not sign in or create the account. Check your details and try again.',
  };
  @override Future<String?> signUp(String email, String password) async {
    try { await _auth.createUserWithEmailAndPassword(email: email, password: password); return null; }
    on FirebaseAuthException catch (e) { return safeError(e.code); }
    catch (_) { return 'Could not create the account. Please try again.'; }
  }
  @override Future<String?> login(String email, String password) async {
    try { await _auth.signInWithEmailAndPassword(email: email, password: password); return null; }
    on FirebaseAuthException catch (e) { return safeError(e.code); }
    catch (_) { return 'Could not sign in. Please try again.'; }
  }
  @override Future<String?> signInWithGoogle() async {
    try {
      await _googleSignIn.signOut();
      final account = await _googleSignIn.signIn();
      if (account == null) return 'Sign in cancelled';
      final authentication = await account.authentication;
      await _auth.signInWithCredential(GoogleAuthProvider.credential(
        accessToken: authentication.accessToken, idToken: authentication.idToken));
      return null;
    } on FirebaseAuthException catch (e) { return safeError(e.code); }
    catch (_) { return 'Google sign-in could not finish. Please try again.'; }
  }
  @override Future<String?> resetPassword(String email) async {
    try { await _auth.sendPasswordResetEmail(email: email); return null; }
    on FirebaseAuthException catch (e) {
      // Do not reveal whether an address is registered.
      if (e.code == 'user-not-found') return null;
      return safeError(e.code);
    } catch (_) { return 'Could not send the reset request. Check your connection.'; }
  }
  @override Future<void> logout() async {
    await Future.wait([_auth.signOut(), _googleSignIn.signOut()]);
  }
}
