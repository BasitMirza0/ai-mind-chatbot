import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';

/// Reacts to auth state changes automatically so it clears on sign-out.
class UserAvatar extends StatelessWidget {
  final double size;

  const UserAvatar({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        final photoUrl = user?.photoURL;

        if (photoUrl != null && photoUrl.isNotEmpty) {
          return ClipOval(
            child: Image.network(
              photoUrl,
              key: ValueKey(photoUrl),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _initialsCircle(user, size),
            ),
          );
        }
        return _initialsCircle(user, size);
      },
    );
  }
}

Widget _initialsCircle(User? user, double size) {
  final raw = user?.displayName ?? user?.email ?? '';
  final initial =
      raw.isEmpty ? 'G' : raw[0].toUpperCase();

  return Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: [AppColors.accentBlue, AppColors.accent],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: size * 0.40,
        ),
      ),
    ),
  );
}
