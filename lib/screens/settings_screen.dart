import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/download_item.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(title: const Text('Settings')),
      body: Consumer<SettingsProvider>(
        builder: (ctx, settings, _) {
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _sectionTitle('Downloads'),
              const SizedBox(height: 12),

              // Save location
              _SettingsCard(
                icon: Icons.folder_rounded,
                iconColor: AppTheme.warning,
                title: 'Save Location',
                subtitle: settings.downloadPath.isEmpty
                    ? '/storage/emulated/0/Download/ReelsDownloader'
                    : settings.downloadPath,
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                onTap: () => _showPathDialog(ctx, settings),
              ),
              const SizedBox(height: 10),

              // Default quality
              _SettingsCard(
                icon: Icons.hd_rounded,
                iconColor: AppTheme.primary,
                title: 'Default Quality',
                subtitle: settings.defaultQuality.label,
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                onTap: () => _showQualityDialog(ctx, settings),
              ),
              const SizedBox(height: 10),

              // Concurrent downloads
              _SettingsCard(
                icon: Icons.multiple_stop_rounded,
                iconColor: AppTheme.secondary,
                title: 'Concurrent Downloads',
                subtitle: '${settings.concurrentDownloads} at a time',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline_rounded,
                          color: Colors.white38),
                      onPressed: () => settings
                          .setConcurrentDownloads(settings.concurrentDownloads - 1),
                    ),
                    Text(
                      '${settings.concurrentDownloads}',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded,
                          color: Colors.white38),
                      onPressed: () => settings
                          .setConcurrentDownloads(settings.concurrentDownloads + 1),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),
              _sectionTitle('About'),
              const SizedBox(height: 12),

              _SettingsCard(
                icon: Icons.info_outline_rounded,
                iconColor: Colors.white38,
                title: 'Version',
                subtitle: '1.0.2 — Built for personal use, no ads, no BS.',
              ),
              const SizedBox(height: 10),

              _SettingsCard(
                icon: Icons.privacy_tip_outlined,
                iconColor: Colors.white38,
                title: 'Privacy',
                subtitle:
                    'No data is collected. All downloads happen locally on your device.',
              ),
              const SizedBox(height: 10),

              _SettingsCard(
                icon: Icons.code_rounded,
                iconColor: Colors.white38,
                title: 'Powered by',
                subtitle:
                  'youtube_explode_dart (YouTube) · direct_link (social media)',
              ),

              const SizedBox(height: 28),
              _sectionTitle('Supported Platforms'),
              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _platformRow(
                      Icons.play_circle_filled,
                      const Color(0xFFFF0000),
                      'YouTube',
                      'Videos, Shorts — no API key, direct extraction',
                    ),
                    _platformRow(
                      Icons.camera_alt,
                      const Color(0xFFE1306C),
                      'Instagram',
                      'Reels, posts — via direct_link',
                    ),
                    _platformRow(
                      Icons.music_note,
                      const Color(0xFF69C9D0),
                      'TikTok',
                      'Videos — via direct_link',
                    ),
                    _platformRow(
                      Icons.flutter_dash,
                      const Color(0xFF1DA1F2),
                      'Twitter/X',
                      'Video tweets — via direct_link',
                    ),
                    _platformRow(
                      Icons.facebook,
                      const Color(0xFF1877F2),
                      'Facebook',
                      'Videos — via direct_link',
                    ),
                    _platformRow(
                      Icons.reddit,
                      const Color(0xFFFF4500),
                      'Reddit',
                      'Video posts — via direct_link',
                    ),
                    _platformRow(
                      Icons.videocam,
                      const Color(0xFF1AB7EA),
                      'Vimeo',
                      'Videos — via direct_link',
                      last: true,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        color: AppTheme.onSurface.withValues(alpha: 0.4),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _platformRow(
    IconData icon,
    Color color,
    String name,
    String desc, {
    bool last = false,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppTheme.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      desc,
                      style: TextStyle(
                        color: AppTheme.onSurface.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!last)
          Divider(
            color: Colors.white.withValues(alpha: 0.06),
            height: 1,
          ),
      ],
    );
  }

  void _showPathDialog(BuildContext ctx, SettingsProvider settings) {
    final controller = TextEditingController(text: settings.downloadPath);
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceVariant,
        title: const Text('Save Location',
            style: TextStyle(color: AppTheme.onBackground)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter a custom path or leave blank to use the default Downloads folder.',
              style: TextStyle(
                color: AppTheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: const TextStyle(color: AppTheme.onBackground, fontSize: 13),
              decoration: const InputDecoration(
                hintText: '/storage/emulated/0/Download/ReelsDownloader',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              settings.setDownloadPath('');
              Navigator.pop(ctx);
            },
            child:
                const Text('Reset', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              settings.setDownloadPath(controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showQualityDialog(BuildContext ctx, SettingsProvider settings) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceVariant,
        title: const Text('Default Quality',
            style: TextStyle(color: AppTheme.onBackground)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: VideoQuality.values.map((q) {
            final selected = settings.defaultQuality == q;
            return ListTile(
              dense: true,
              title: Text(
                q.label,
                style: TextStyle(
                  color: selected ? AppTheme.primary : AppTheme.onSurface,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: selected
                  ? const Icon(Icons.check_rounded, color: AppTheme.primary)
                  : null,
              onTap: () {
                settings.setDefaultQuality(q);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.onBackground,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.onSurface.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
