import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Identity-keyed, non-gapless image: a previous account's pixels cannot remain
/// visible while the next account's photo is loading or fails.
class ProfileAvatar extends StatelessWidget {
  final String? uid, photoUrl;
  final String name;
  final double size;
  final ImageProvider Function(String)? imageProvider;
  const ProfileAvatar({super.key, required this.uid, required this.name,
    this.photoUrl, this.size = 44, this.imageProvider});
  static bool validUrl(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
  }
  @override Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '' : name.trim().characters.first.toUpperCase();
    final fallback = ColoredBox(color: AppColors.lavenderSurface, child: Center(
      child: uid == null || initial.isEmpty ? const Icon(Icons.person_outline_rounded, color: AppColors.purple)
        : Text(initial, style: TextStyle(color: AppColors.purple, fontSize: size * .4, fontWeight: FontWeight.w500))));
    return Semantics(label: uid == null ? 'Guest profile' : 'Your profile picture', image: true,
      child: ExcludeSemantics(child: ClipOval(child: SizedBox.square(dimension: size,
        child: uid != null && validUrl(photoUrl) ? Image(
          key: ValueKey('$uid:$photoUrl'), image: imageProvider?.call(photoUrl!) ?? NetworkImage(photoUrl!),
          fit: BoxFit.cover, gaplessPlayback: false,
          frameBuilder: (_, child, frame, synchronous) => synchronous || frame != null ? child : fallback,
          errorBuilder: (_, __, ___) => fallback) : fallback))));
  }
}
