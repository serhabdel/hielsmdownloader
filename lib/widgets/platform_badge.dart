import 'package:flutter/material.dart';
import '../models/download_item.dart';

class PlatformBadge extends StatelessWidget {
  final SupportedPlatform platform;
  final bool showLabel;

  const PlatformBadge({
    super.key,
    required this.platform,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: platform.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: platform.color.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            platform.icon,
            color: platform.color,
            size: 14,
          ),
          if (showLabel) ...[
            const SizedBox(width: 5),
            Text(
              platform.displayName,
              style: TextStyle(
                color: platform.color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
