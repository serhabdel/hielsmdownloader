import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Wraps flutter_foreground_task to keep downloads alive in the background.
///
/// Usage:
///   - Call [init] once at app startup (before runApp).
///   - Call [start] when the first download begins.
///   - Call [stop] when no downloads are active.
///   - Call [update] to refresh the status-bar text while downloading.
class ForegroundService {
  ForegroundService._();

  // ─── Init (call once in main before runApp) ────────────────────────────────

  static void init() {
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'download_foreground',
        channelName: 'Background Downloads',
        channelDescription:
            'Keeps downloads running when the app is in the background',
        // HIGH importance keeps the notification visible at all times and
        // signals to Android that this is an active, user-visible workload.
        // DEFAULT/LOW allowed aggressive process suspension on some OEMs.
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Fire a keep-alive heartbeat every 3 s (shorter than 5 s) so the CPU
        // wake lock is re-acquired more frequently while downloads are active.
        eventAction: ForegroundTaskEventAction.repeat(3000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // ─── Start ────────────────────────────────────────────────────────────────

  static Future<void> start({String text = 'Downloading...'}) async {
    if (!Platform.isAndroid) return;

    // Ask Android to not kill us for battery optimisation
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    if (await FlutterForegroundTask.isRunningService) {
      // Already running — just update the text
      await FlutterForegroundTask.updateService(
        notificationTitle: 'HieL SmD',
        notificationText: text,
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'HieL SmD',
      notificationText: text,
      callback: _foregroundCallback,
    );
  }

  // ─── Stop ─────────────────────────────────────────────────────────────────

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  // ─── Update status text ───────────────────────────────────────────────────

  static Future<void> update(String text) async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'HieL SmD',
      notificationText: text,
    );
  }
}

// ─── Top-level foreground callback (required by flutter_foreground_task) ──────

/// Must be a top-level function annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void _foregroundCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class _DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Nothing needed — downloads run on the main isolate.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Heartbeat — keeps the service alive.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
