import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Manages per-download progress notifications in the Android status bar.
///
/// Each active download gets its own notification (keyed by an int id derived
/// from the first 8 chars of the download UUID so it stays stable across
/// progress updates).
class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _channelId = 'download_progress';
  static const _channelName = 'Download Progress';
  static const _channelDesc = 'Shows progress for active video downloads';

  // ─── Init ──────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;
    _initialized = true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    // Create the notification channel (Android 8+)
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.low, // silent — no sound/vibration
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /// Converts a download UUID to a stable small int notification id.
  static int _idFor(String downloadId) =>
      downloadId.substring(0, 8).hashCode.abs() % 10000 + 1;

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Show or update a progress notification for an active download.
  static Future<void> showProgress({
    required String downloadId,
    required String title,
    required int progress, // 0-100; use -1 for indeterminate
    required int receivedBytes,
    required int totalBytes,
  }) async {
    if (!Platform.isAndroid) return;
    await init();

    final body = totalBytes > 0
        ? '${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}'
        : _formatBytes(receivedBytes);

    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: 100,
      progress: progress < 0 ? 0 : progress,
      indeterminate: progress < 0,
      playSound: false,
      enableVibration: false,
      category: AndroidNotificationCategory.progress,
    );

    await _plugin.show(
      _idFor(downloadId),
      title,
      body,
      NotificationDetails(android: details),
    );
  }

  /// Replace progress notification with a "Completed" one (auto-cancels after
  /// a few seconds via [autoCancel] = true).
  static Future<void> showCompleted({
    required String downloadId,
    required String title,
  }) async {
    if (!Platform.isAndroid) return;
    await init();

    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      playSound: false,
      enableVibration: false,
    );

    await _plugin.show(
      _idFor(downloadId),
      'Download complete',
      title,
      NotificationDetails(android: details),
    );
  }

  /// Replace progress notification with a "Failed" one.
  static Future<void> showFailed({
    required String downloadId,
    required String title,
    String? reason,
  }) async {
    if (!Platform.isAndroid) return;
    await init();

    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      playSound: false,
      enableVibration: false,
    );

    await _plugin.show(
      _idFor(downloadId),
      'Download failed',
      reason ?? title,
      NotificationDetails(android: details),
    );
  }

  /// Cancel (dismiss) a download's notification.
  static Future<void> cancel(String downloadId) async {
    if (!Platform.isAndroid) return;
    await _plugin.cancel(_idFor(downloadId));
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
