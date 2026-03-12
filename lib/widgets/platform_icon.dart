import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../models/download_item.dart';

/// Renders the correct icon widget for a [SupportedPlatform].
///
/// Brand icons (YouTube, Instagram, etc.) use [FaIcon] from font_awesome_flutter.
/// Generic / fallback icons use the standard Material [Icon].
class PlatformIcon extends StatelessWidget {
  final SupportedPlatform platform;
  final double size;
  final Color? color;

  const PlatformIcon({
    super.key,
    required this.platform,
    this.size = 20,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconData = platform.icon;
    final iconColor = color ?? platform.color;

    if (iconData is FaIconData) {
      return FaIcon(iconData, size: size, color: iconColor);
    }
    return Icon(iconData as IconData, size: size, color: iconColor);
  }
}
