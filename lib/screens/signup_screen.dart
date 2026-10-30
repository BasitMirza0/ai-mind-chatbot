import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/auth_form.dart';
class SignupScreen extends StatelessWidget {
  final AuthGateway? gateway;
  final WidgetBuilder? homeBuilder;
  const SignupScreen({super.key, this.gateway, this.homeBuilder});
  @override Widget build(BuildContext context) => AuthForm(signUp: true, gateway: gateway, homeBuilder: homeBuilder);
}





