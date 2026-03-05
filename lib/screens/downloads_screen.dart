import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
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

  /// IDs that are "pending delete" â€” filtered from the visible list while the
  /// undo snackbar is visible.  Permanently removed once the snackbar closes
  /// without the user tapping Undo.
  final Set<String> _pendingDelete = {};

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
                onPressed: () => _confirmClearAll(ctx, provider),
                icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                label: const Text('Clear all'),
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
              _buildActiveList(ctx, provider),
              _buildCompletedList(ctx, provider),
            ],
          );
        },
      ),
    );
  }

  // â”€â”€â”€ Active list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildActiveList(BuildContext ctx, DownloadProvider provider) {
    final activeItems = provider.items
        .where((i) =>
            i.status == DownloadStatus.downloading ||
            i.status == DownloadStatus.fetchingInfo ||
            i.status == DownloadStatus.queued)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)); // earliest first

    if (activeItems.isEmpty) {
      return _buildEmptyState(
        icon: Icons.download_rounded,
        title: 'No active downloads',
        subtitle: 'Paste a video URL on the home tab to start downloading',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: activeItems.length,
      itemBuilder: (ctx, i) {
        final item = activeItems[i];
        return _DownloadCard(
          key: ValueKey(item.id),
          item: item,
          onLongPress: () => _showActionSheet(ctx, item, provider),
        );
      },
    );
  }

  // â”€â”€â”€ Completed list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildCompletedList(BuildContext ctx, DownloadProvider provider) {
    final completedItems = provider.items
        .where((i) =>
            (i.status == DownloadStatus.completed ||
                i.status == DownloadStatus.failed ||
                i.status == DownloadStatus.cancelled) &&
            !_pendingDelete.contains(i.id))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (completedItems.isEmpty) {
      return _buildEmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No completed downloads',
        subtitle: _pendingDelete.isNotEmpty
            ? 'All items deleted \u2014 tap Undo in the notification'
            : 'Finished downloads will appear here',
      );
    }

    // Group items by date for section headers
    final grouped = <String, List<DownloadItem>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final item in completedItems) {
      final d = DateTime(item.createdAt.year, item.createdAt.month, item.createdAt.day);
      String label;
      if (d == today) {
        label = 'Today';
      } else if (d == yesterday) {
        label = 'Yesterday';
      } else if (now.difference(d).inDays < 7) {
        label = DateFormat.EEEE().format(item.createdAt);
      } else {
        label = DateFormat.yMMMd().format(item.createdAt);
      }
      grouped.putIfAbsent(label, () => []).add(item);
    }

    final sectionKeys = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: completedItems.length + sectionKeys.length,
      itemBuilder: (ctx, i) {
        var offset = 0;
        for (final key in sectionKeys) {
          if (i == offset) {
            return _buildSectionHeader(key, grouped[key]!.length);
          }
          offset++;
          final items = grouped[key]!;
          if (i < offset + items.length) {
            final item = items[i - offset];
            return Dismissible(
              key: ValueKey('dismiss_${item.id}'),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) async {
                _handleSwipeDelete(ctx, item, provider);
                return false;
              },
              background: _buildDismissBackground(),
              child: _DownloadCard(
                key: ValueKey(item.id),
                item: item,
                showTimestamp: true,
                onLongPress: () => _showActionSheet(ctx, item, provider),
              ),
            );
          }
          offset += items.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildSectionHeader(String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(
              color: Colors.white.withValues(alpha: 0.06),
              thickness: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDismissBackground() {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.delete_outline_rounded, color: AppTheme.error, size: 24),
          const SizedBox(height: 4),
          Text(
            'Remove',
            style: TextStyle(
              color: AppTheme.error.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€ Swipe-to-delete with Undo snackbar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _handleSwipeDelete(
    BuildContext ctx,
    DownloadItem item,
    DownloadProvider provider,
  ) {
    setState(() => _pendingDelete.add(item.id));

    ScaffoldMessenger.of(ctx)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(
            content: Text(
              'Removed "${item.title}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            duration: const Duration(seconds: 4),
            backgroundColor: AppTheme.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            action: SnackBarAction(
              label: 'Undo',
              textColor: AppTheme.primary,
              onPressed: () {
                if (mounted) setState(() => _pendingDelete.remove(item.id));
              },
            ),
          ),
        )
        .closed
        .then((reason) {
      if (reason != SnackBarClosedReason.action) {
        // User didn't undo â€” permanently remove the item
        provider.removeDownload(item.id);
        if (mounted) setState(() => _pendingDelete.remove(item.id));
      }
    });
  }

  // â”€â”€â”€ Long-press action bottom sheet â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _showActionSheet(
    BuildContext ctx,
    DownloadItem item,
    DownloadProvider provider,
  ) {
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: AppTheme.surfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // â”€â”€ Drag handle â”€â”€â”€
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // â”€â”€ Title header â”€â”€â”€
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  if (item.thumbnailUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        item.thumbnailUrl!,
                        width: 52,
                        height: 36,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                          item.platform.icon,
                          color: item.platform.color,
                          size: 20,
                        ),
                      ),
                    )
                  else
                    Icon(item.platform.icon, color: item.platform.color, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
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
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 24),

            // â”€â”€ Actions â”€â”€â”€
            if (item.status == DownloadStatus.completed &&
                item.filePath != null) ...[
              _sheetTile(
                ctx,
                icon: Icons.play_circle_outline_rounded,
                label: 'Open file',
                color: AppTheme.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  OpenFilex.open(item.filePath!);
                },
              ),
              _sheetTile(
                ctx,
                icon: Icons.share_rounded,
                label: 'Share',
                color: AppTheme.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles([XFile(item.filePath!)]);
                },
              ),
            ],
            if (item.status == DownloadStatus.failed ||
                item.status == DownloadStatus.cancelled) ...[
              _sheetTile(
                ctx,
                icon: Icons.refresh_rounded,
                label: item.partialFilePath != null
                    ? 'Resume download'
                    : 'Retry download',
                color: AppTheme.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  provider.retryDownload(item.id);
                },
              ),
            ],
            if (item.status.isActive)
              _sheetTile(
                ctx,
                icon: Icons.stop_circle_outlined,
                label: 'Cancel download',
                color: AppTheme.error,
                onTap: () {
                  Navigator.pop(ctx);
                  provider.cancelDownload(item.id);
                },
              ),
            if (!item.status.isActive)
              _sheetTile(
                ctx,
                icon: Icons.delete_outline_rounded,
                label: 'Remove from list',
                color: AppTheme.error,
                onTap: () {
                  Navigator.pop(ctx);
                  provider.removeDownload(item.id);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _sheetTile(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 18),
      ),
      title: Text(label, style: const TextStyle(color: AppTheme.onSurface, fontSize: 14)),
      onTap: onTap,
      dense: true,
    );
  }

  // â”€â”€â”€ Empty state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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

  // â”€â”€â”€ Clear-all dialog â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _confirmClearAll(BuildContext ctx, DownloadProvider provider) {
    showDialog<void>(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceVariant,
        title: const Text(
          'Clear all finished',
          style: TextStyle(color: AppTheme.onBackground),
        ),
        content: const Text(
          'Remove all completed, failed, and cancelled downloads from the list? '
          'Files already saved to disk will NOT be deleted.',
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
              if (mounted) setState(() => _pendingDelete.clear());
              Navigator.pop(ctx);
            },
            child: const Text('Clear all', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// Download card widget
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _DownloadCard extends StatelessWidget {
  final DownloadItem item;
  /// Called when the card is long-pressed. Used to show the action sheet.
  final VoidCallback? onLongPress;
  /// When true, show the timestamp (time of day) below the status chip.
  final bool showTimestamp;

  const _DownloadCard({
    required this.item,
    this.onLongPress,
    this.showTimestamp = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: item.status == DownloadStatus.completed && item.filePath != null
          ? () => OpenFilex.open(item.filePath!)
          : null,
      onLongPress: onLongPress,
      child: Container(
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
                  Expanded(child: _buildInfo(context)),
                  _buildActions(context),
                ],
              ),
            ),
            if (item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.fetchingInfo)
              _buildProgressBar(),
          ],
        ),
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
                errorBuilder: (_, __, ___) => _platformIcon(),
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

  Widget _buildInfo(BuildContext context) {
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
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            PlatformBadge(platform: item.platform, showLabel: false),
            if (item.duration != null) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                ],
              ),
            ],
            _buildStatusChip(),
            // Show timestamp + file size for completed items
            if (showTimestamp) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_rounded,
                      size: 10, color: Colors.white.withValues(alpha: 0.28)),
                  const SizedBox(width: 2),
                  Text(
                    DateFormat.jm().format(item.createdAt),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.28),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              if (item.fileSizeBytes != null && item.fileSizeBytes! > 0)
                Text(
                  _fmtBytes(item.fileSizeBytes!),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.28),
                    fontSize: 10,
                  ),
                ),
            ],
          ],
        ),

        // Download speed + bytes row
        if (item.status == DownloadStatus.downloading &&
            item.fileSizeBytes != null &&
            item.fileSizeBytes! > 0) ...[
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                '${_fmtBytes(item.downloadedBytes ?? 0)} / ${_fmtBytes(item.fileSizeBytes!)}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                ),
              ),
              if (item.speedBytesPerSec != null &&
                  item.speedBytesPerSec! > 0)
                Text(
                  '${_fmtBytes(item.speedBytesPerSec!)}/s',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],

        // Resumable badge for failed/cancelled items with a partial file
        if (!item.status.isActive &&
            item.partialFilePath != null &&
            item.status != DownloadStatus.completed) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.download_for_offline_outlined,
                  size: 11, color: AppTheme.secondary.withValues(alpha: 0.8)),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  item.downloadedBytes != null && item.downloadedBytes! > 0
                      ? '${_fmtBytes(item.downloadedBytes!)} saved — resumable'
                      : 'Partial file saved — resumable',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.secondary.withValues(alpha: 0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],

        // Error message
        if (item.status == DownloadStatus.failed &&
            item.errorMessage != null) ...[
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

  Widget _buildStatusChip() {
    return Container(
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
    );
  }

  Widget _buildActions(BuildContext context) {
    final provider = context.read<DownloadProvider>();

    // Active downloads: show cancel button only
    if (item.status.isActive) {
      return IconButton(
        icon: const Icon(Icons.stop_circle_rounded, color: AppTheme.error, size: 22),
        onPressed: () => provider.cancelDownload(item.id),
        tooltip: 'Cancel',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      );
    }

    // Completed with a file: share + overflow
    if (item.status == DownloadStatus.completed && item.filePath != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.share_rounded, color: AppTheme.primary, size: 20),
            onPressed: () => Share.shareXFiles([XFile(item.filePath!)]),
            tooltip: 'Share',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          _buildOverflowMenu(context, provider),
        ],
      );
    }

    // Failed / cancelled: retry button + overflow
    if (item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.cancelled) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: item.partialFilePath != null
                ? 'Resume download'
                : 'Retry download',
            child: IconButton(
              icon: Icon(
                item.partialFilePath != null
                    ? Icons.download_for_offline_outlined
                    : Icons.refresh_rounded,
                color: AppTheme.secondary,
                size: 20,
              ),
              onPressed: () => provider.retryDownload(item.id),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          _buildOverflowMenu(context, provider),
        ],
      );
    }

    return _buildOverflowMenu(context, provider);
  }

  Widget _buildOverflowMenu(BuildContext context, DownloadProvider provider) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
      color: AppTheme.surfaceVariant,
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        if (item.status == DownloadStatus.completed && item.filePath != null)
          const PopupMenuItem(
            value: 'open',
            child: Row(
              children: [
                Icon(Icons.play_circle_outline_rounded,
                    color: AppTheme.primary, size: 18),
                SizedBox(width: 8),
                Text('Open file', style: TextStyle(color: AppTheme.onSurface)),
              ],
            ),
          ),
        if (item.status == DownloadStatus.failed ||
            item.status == DownloadStatus.cancelled)
          PopupMenuItem(
            value: 'retry',
            child: Row(
              children: [
                Icon(
                  item.partialFilePath != null
                      ? Icons.download_for_offline_outlined
                      : Icons.refresh_rounded,
                  color: AppTheme.secondary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  item.partialFilePath != null
                      ? 'Resume download'
                      : 'Retry download',
                  style: const TextStyle(color: AppTheme.onSurface),
                ),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  color: AppTheme.error, size: 18),
              SizedBox(width: 8),
              Text('Remove', style: TextStyle(color: AppTheme.onSurface)),
            ],
          ),
        ),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'open':
            if (item.filePath != null) await OpenFilex.open(item.filePath!);
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

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

