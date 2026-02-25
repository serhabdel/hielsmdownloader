import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import '../models/download_item.dart';
import '../providers/download_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/platform_badge.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('My Downloads'),
        actions: [
          Consumer<DownloadProvider>(
            builder: (ctx, provider, _) {
              final hasFinished = provider.items.any((i) =>
                  i.status == DownloadStatus.completed ||
                  i.status == DownloadStatus.failed ||
                  i.status == DownloadStatus.cancelled);
              if (!hasFinished) return const SizedBox.shrink();
              return TextButton.icon(
                onPressed: () => _confirmClear(ctx, provider),
                icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                ),
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: Colors.white38,
          indicatorColor: AppTheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Completed'),
          ],
        ),
      ),
      body: Consumer<DownloadProvider>(
        builder: (ctx, provider, _) {
          return TabBarView(
            controller: _tabController,
            children: [
              _buildActiveList(provider),
              _buildCompletedList(provider),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActiveList(DownloadProvider provider) {
    final activeItems = provider.items
        .where((i) =>
            i.status == DownloadStatus.downloading ||
            i.status == DownloadStatus.fetchingInfo ||
            i.status == DownloadStatus.queued)
        .toList();

    if (activeItems.isEmpty) {
      return _buildEmptyState(
        icon: Icons.download_rounded,
        title: 'No active downloads',
        subtitle: 'Paste a video URL on the home tab to start downloading',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: activeItems.length,
      itemBuilder: (ctx, i) => _DownloadCard(item: activeItems[i]),
    );
  }

  Widget _buildCompletedList(DownloadProvider provider) {
    final completedItems = provider.items
        .where((i) =>
            i.status == DownloadStatus.completed ||
            i.status == DownloadStatus.failed ||
            i.status == DownloadStatus.cancelled)
        .toList();

    if (completedItems.isEmpty) {
      return _buildEmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No completed downloads',
        subtitle: 'Finished downloads will appear here',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: completedItems.length,
      itemBuilder: (ctx, i) => _DownloadCard(item: completedItems[i]),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white12),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: AppTheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                color: AppTheme.onSurface.withValues(alpha: 0.4),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext ctx, DownloadProvider provider) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceVariant,
        title: const Text('Clear finished', style: TextStyle(color: AppTheme.onBackground)),
        content: const Text(
          'Remove all completed, failed, and cancelled downloads from the list? Files already saved will not be deleted.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              provider.clearCompleted();
              Navigator.pop(ctx);
            },
            child: const Text('Clear', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  final DownloadItem item;

  const _DownloadCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
                color: item.status.color.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildThumbnail(),
                const SizedBox(width: 12),
                Expanded(child: _buildInfo()),
                _buildActions(context),
              ],
            ),
          ),
          if (item.status == DownloadStatus.downloading ||
              item.status == DownloadStatus.fetchingInfo)
            _buildProgressBar(),
        ],
      ),
    );
  }

  Widget _buildThumbnail() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 72,
        height: 52,
        color: AppTheme.surfaceVariant,
        child: item.thumbnailUrl != null
            ? Image.network(
                item.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, e, s) => _platformIcon(),
              )
            : _platformIcon(),
      ),
    );
  }

  Widget _platformIcon() {
    return Center(
      child: Icon(
        item.platform.icon,
        color: item.platform.color,
        size: 24,
      ),
    );
  }

  Widget _buildInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.onBackground,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            PlatformBadge(platform: item.platform, showLabel: false),
            const SizedBox(width: 6),
            if (item.duration != null) ...[
              Icon(Icons.access_time_rounded,
                  size: 11, color: Colors.white.withValues(alpha: 0.35)),
              const SizedBox(width: 2),
              Text(
                item.duration!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
          color: item.status.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.status.label,
                style: TextStyle(
                  color: item.status.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (item.status == DownloadStatus.downloading &&
            item.fileSizeBytes != null &&
            item.fileSizeBytes! > 0) ...[
          const SizedBox(height: 4),
          Text(
            '${_formatBytes(item.downloadedBytes ?? 0)} / ${_formatBytes(item.fileSizeBytes!)}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
        if (item.status == DownloadStatus.failed && item.errorMessage != null) ...[
          const SizedBox(height: 4),
          Text(
            item.errorMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.error,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final provider = context.read<DownloadProvider>();

    if (item.status.isActive) {
      return IconButton(
        icon: const Icon(Icons.stop_circle_rounded, color: AppTheme.error, size: 22),
        onPressed: () => provider.cancelDownload(item.id),
        tooltip: 'Cancel',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      );
    }

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
      color: AppTheme.surfaceVariant,
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        if (item.status == DownloadStatus.completed && item.filePath != null)
          const PopupMenuItem(
            value: 'open',
            child: Row(
              children: [
                Icon(Icons.play_circle_outline_rounded, color: AppTheme.primary, size: 18),
                SizedBox(width: 8),
                Text('Open', style: TextStyle(color: AppTheme.onSurface)),
              ],
            ),
          ),
        if (item.status == DownloadStatus.failed || item.status == DownloadStatus.cancelled)
          const PopupMenuItem(
            value: 'retry',
            child: Row(
              children: [
                Icon(Icons.refresh_rounded, color: AppTheme.secondary, size: 18),
                SizedBox(width: 8),
                Text('Retry', style: TextStyle(color: AppTheme.onSurface)),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, color: AppTheme.error, size: 18),
              SizedBox(width: 8),
              Text('Remove', style: TextStyle(color: AppTheme.onSurface)),
            ],
          ),
        ),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'open':
            if (item.filePath != null) {
              await OpenFilex.open(item.filePath!);
            }
            break;
          case 'retry':
            provider.retryDownload(item.id);
            break;
          case 'remove':
            provider.removeDownload(item.id);
            break;
        }
      },
    );
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: item.status == DownloadStatus.fetchingInfo
                  ? null
                  : item.progress,
              backgroundColor: AppTheme.surfaceVariant,
              valueColor: AlwaysStoppedAnimation<Color>(
                item.status == DownloadStatus.fetchingInfo
                    ? AppTheme.secondary
                    : AppTheme.primary,
              ),
              minHeight: 4,
            ),
          ),
          if (item.status == DownloadStatus.downloading && item.progress > 0) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${(item.progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
