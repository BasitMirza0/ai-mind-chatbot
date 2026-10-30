import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/auth_form.dart';
class LoginScreen extends StatelessWidget {
  final AuthGateway? gateway;
  final WidgetBuilder? homeBuilder;
  const LoginScreen({super.key, this.gateway, this.homeBuilder});
  @override Widget build(BuildContext context) => AuthForm(gateway: gateway, homeBuilder: homeBuilder);
}
