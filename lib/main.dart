import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/app_splash_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  // Synchronous after Firebase init — no extra await needed.
  final isLoggedIn = FirebaseAuth.instance.currentUser != null;
  await AppTheme.configurePlatformAppearance();
  SystemChrome.setSystemUIOverlayStyle(AppTheme.lightSystemUi);
  runApp(MyApp(isLoggedIn: isLoggedIn,
    isSignedIn: () => FirebaseAuth.instance.currentUser != null));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;
  final ValueGetter<bool>? isSignedIn;
  const MyApp({super.key, required this.isLoggedIn, this.isSignedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Mind',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.legacy,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.legacySystemUi, child: child!),
      home: AppSplashScreen(isLoggedIn: isLoggedIn, isSignedIn: isSignedIn),
    );
  }
}
