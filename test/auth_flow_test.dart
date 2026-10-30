import 'dart:async';
import 'support/fake_auth.dart';
import 'package:ai_chatbot/services/auth_service.dart';
import 'package:ai_chatbot/screens/login_screen.dart';
import 'package:ai_chatbot/screens/signup_screen.dart';
import 'package:ai_chatbot/widgets/auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> form(WidgetTester t,FakeAuth auth,{bool signup=false}) async {
    await t.pumpWidget(MaterialApp(home:Builder(builder:(ctx)=>Scaffold(body:TextButton(onPressed:()=>Navigator.push(ctx,
      MaterialPageRoute<void>(builder:(_)=>signup?SignupScreen(gateway:auth):LoginScreen(gateway:auth))),child:const Text('Existing Home'))))));
    await t.tap(find.text('Existing Home'));await t.pumpAndSettle();
  }
  testWidgets('login preserves password characters and returns to one existing Home', (t)async {
    final auth=FakeAuth();await form(t,auth);
    await t.enterText(find.byKey(const Key('auth-email')),' example@example.com ');
    await t.enterText(find.byKey(const Key('auth-password')),'  password with spaces  ');
    await t.ensureVisible(find.text('Sign in').last);await t.tap(find.text('Sign in').last);await t.pumpAndSettle();
    expect(auth.email,'example@example.com');expect(auth.password,'  password with spaces  ');
    expect(find.text('Existing Home'),findsOneWidget);expect(Navigator.of(t.element(find.text('Existing Home'))).canPop(),false);
  });
  testWidgets('signup validates confirmation, preserves password, and mode switch uses same route', (t)async {
    final auth=FakeAuth();await form(t,auth,signup:true);
    await t.enterText(find.byKey(const Key('auth-email')),'example@example.com');
    await t.enterText(find.byKey(const Key('auth-password')),' secret ');await t.enterText(find.byKey(const Key('auth-confirm')),'secret');
    await t.ensureVisible(find.text('Create account'));await t.tap(find.text('Create account'));await t.pumpAndSettle();
    expect(find.text('Passwords do not match.'),findsOneWidget);expect(auth.calls,0);
    await t.enterText(find.byKey(const Key('auth-confirm')),' secret ');await t.tap(find.text('Create account'));await t.pumpAndSettle();
    expect(auth.password,' secret ');expect(find.text('Existing Home'),findsOneWidget);
  });
  testWidgets('Google cancellation stays on form; success returns without extra Home', (t)async {
    final auth=FakeAuth()..result='Sign in cancelled';await form(t,auth);
    await t.tap(find.text('Continue with Google'));await t.pumpAndSettle();expect(find.text('Sign in cancelled'),findsOneWidget);
    auth.result=null;await t.tap(find.text('Continue with Google'));await t.pumpAndSettle();expect(find.text('Existing Home'),findsOneWidget);
    expect(auth.google,2);
  });
  testWidgets('pending authentication disables duplicate submits and disposal is safe', (t)async {
    final auth=FakeAuth()..gate=Completer();await form(t,auth);
    await t.tap(find.text('Continue with Google'));await t.pump();
    expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'Continue with Google')).onPressed,isNull);
    await t.pumpWidget(const SizedBox.shrink());auth.gate!.complete(null);await t.pump();expect(t.takeException(),isNull);expect(auth.google,1);
  });
  testWidgets('password reset is functional and its confirmation does not reveal account existence', (t)async {
    final auth=FakeAuth();await form(t,auth);await t.ensureVisible(find.text('Forgot password?'));await t.tap(find.text('Forgot password?'));await t.pumpAndSettle();
    await t.enterText(find.byType(TextField),'example@example.com');await t.tap(find.text('Send reset link'));await t.pumpAndSettle();
    expect(auth.reset,1);expect(find.text('If this email is registered, a password reset link will arrive shortly.'),findsOneWidget);
    await t.pageBack();await t.pumpAndSettle();expect(find.byType(AuthForm),findsOneWidget);
  });
  test('authentication errors do not expose account existence or raw provider messages',(){
    expect(AuthService.safeError('user-not-found'),AuthService.safeError('wrong-password'));
    expect(AuthService.safeError('email-already-in-use'),AuthService.safeError('invalid-credential'));
  });
}
