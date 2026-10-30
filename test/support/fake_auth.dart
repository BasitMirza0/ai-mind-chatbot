import 'dart:async';
import 'package:ai_chatbot/services/auth_service.dart';

class FakeAuth implements AuthGateway {
  String? email,password,result;
  int calls=0,google=0,reset=0;
  Completer<String?>? gate;
  @override Future<String?> login(String email,String password) async {this.email=email;this.password=password;calls++;return gate?.future??Future.value(result);}
  @override Future<String?> signUp(String email,String password)=>login(email,password);
  @override Future<String?> signInWithGoogle() async {google++;return gate?.future??Future.value(result);}
  @override Future<String?> resetPassword(String email) async {reset++;return result;}
  @override Future<void> logout() async {}
}
