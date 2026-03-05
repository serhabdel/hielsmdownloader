import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/download_item.dart';
import '../services/download_service.dart';
import '../services/foreground_service.dart';
import '../services/notification_service.dart';
import 'settings_provider.dart';

class DownloadProvider extends ChangeNotifier {
  static const _prefKey = 'download_history';

  final List<DownloadItem> _items = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _activeDownloads = {};
  SettingsProvider? _settingsProvider;
  int _activeCount = 0;
  bool _historyLoaded = false;

  // Download speed tracking: downloadId → sliding window of recent samples
  final Map<String, _SpeedTracker> _speedTrackers = {};

  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get activeItems =>
      _items.where((i) => i.status.isActive).toList();
  List<DownloadItem> get completedItems =>
      _items.where((i) => i.status == DownloadStatus.completed).toList();
  int get activeCount => _activeCount;

  void init(SettingsProvider settings) {
    _settingsProvider = settings;
    if (!_historyLoaded) {
      _historyLoaded = true;
      _loadHistory();
    }
  }

  // ─── Persistence ──────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null) return;
      final list = jsonDecode(raw) as List<dynamic>;
      final loaded = list
          .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
          .toList();
      _items.addAll(loaded);
      notifyListeners();
    } catch (_) {
      // Corrupted prefs — silently ignore and start fresh
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Only persist non-active items (completed / failed / cancelled)
      final toSave = _items
          .where((i) => !i.status.isActive)
          .map((i) => i.toJson())
          .toList();
      await prefs.setString(_prefKey, jsonEncode(toSave));
    } catch (_) {}
  }

  Future<void> addDownload(String url, VideoQuality quality) async {
    final id = const Uuid().v4();
    final platform = detectPlatform(url);

    final item = DownloadItem(
      id: id,
      url: url.trim(),
      platform: platform,
      quality: quality,
      status: DownloadStatus.fetchingInfo,
    );

    _items.insert(0, item);
    notifyListeners();

    _processDownload(item);
  }

  void _processDownload(DownloadItem item) async {
    final maxConcurrent = _settingsProvider?.concurrentDownloads ?? 2;

    if (_activeCount >= maxConcurrent) {
      _updateItem(item.id, item.copyWith(status: DownloadStatus.queued));
      return;
    }

    _activeCount++;
    _activeDownloads[item.id] = true;
    _startDownload(item);
  }

  void _startDownload(DownloadItem item) async {
    final cancelToken = CancelToken();
    _cancelTokens[item.id] = cancelToken;

    final setupResults = await Future.wait([
      NotificationService.showProgress(
        downloadId: item.id,
        title: item.title,
        progress: -1,
        receivedBytes: 0,
        totalBytes: 0,
      ),
      ForegroundService.start(text: 'Downloading "${item.title}"'),
      DownloadService.getDownloadsDir(_settingsProvider?.downloadPath),
    ]);
    final savePath = setupResults[2] as String;

    try {
      _updateItem(item.id, item.copyWith(status: DownloadStatus.fetchingInfo));

      if (item.platform == SupportedPlatform.youtube) {
        await _downloadYoutube(item, savePath, cancelToken);
      } else {
        await _downloadSocialMedia(item, savePath, cancelToken);
      }

      final finished = _getItem(item.id);
      if (finished != null && finished.status == DownloadStatus.completed) {
        await NotificationService.showCompleted(
          downloadId: item.id,
          title: finished.title,
        );
      } else {
        await NotificationService.cancel(item.id);
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        final current = _getItem(item.id);
        if (current != null) {
          _updateItem(
            item.id,
            current.copyWith(
              status: DownloadStatus.cancelled,
              errorMessage: 'Download cancelled',
            ),
          );
        }
        await NotificationService.cancel(item.id);
      } else {
        final msg = _friendlyDioError(e);
        final current = _getItem(item.id);
        if (current != null) {
          _updateItem(
            item.id,
            current.copyWith(status: DownloadStatus.failed, errorMessage: msg),
          );
        }
        await NotificationService.showFailed(
          downloadId: item.id,
          title: _getItem(item.id)?.title ?? 'Download',
          reason: msg,
        );
      }
    } catch (e) {
      final msg = e.toString().replaceAll('Exception: ', '');
      final current = _getItem(item.id);
      if (current != null) {
        _updateItem(
          item.id,
          current.copyWith(status: DownloadStatus.failed, errorMessage: msg),
        );
      }
      await NotificationService.showFailed(
        downloadId: item.id,
        title: _getItem(item.id)?.title ?? 'Download',
        reason: msg,
      );
    } finally {
      _cancelTokens.remove(item.id);
      _activeDownloads.remove(item.id);
      _lastNotificationUpdateById.remove(item.id);
      _lastUiUpdateById.remove(item.id);
      _speedTrackers.remove(item.id);
      _activeCount = (_activeCount - 1).clamp(0, 999);
      _processQueuedItems();
      if (_activeCount == 0) {
        await ForegroundService.stop();
      }
    }
  }

  // ─── Human-friendly error messages ─────────────────────────────────────────

  String _friendlyDioError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 403) {
      return 'Access denied (403) — the video may be private or age-restricted.';
    }
    if (status == 404) {
      return 'Video not found (404) — the URL may be invalid or the video deleted.';
    }
    if (status != null) {
      return 'HTTP error $status — please retry.';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out. Check your internet and retry.';
      case DioExceptionType.connectionError:
        return 'No internet connection. Please check your network.';
      default:
        return e.message ?? 'Network error — please retry.';
    }
  }

  // ─── Notification throttling ───────────────────────────────────────────────

  final Map<String, DateTime> _lastNotificationUpdateById = {};
  static const _notificationThrottleMs = 500;

  bool _shouldUpdateNotification(String downloadId) {
    final now = DateTime.now();
    final last = _lastNotificationUpdateById[downloadId];
    if (last == null ||
        now.difference(last).inMilliseconds > _notificationThrottleMs) {
      _lastNotificationUpdateById[downloadId] = now;
      return true;
    }
    return false;
  }

  // ─── UI-update throttling ─────────────────────────────────────────────────

  final Map<String, DateTime> _lastUiUpdateById = {};
  static const _uiThrottleMs = 200;

  bool _shouldUpdateUi(String downloadId) {
    final now = DateTime.now();
    final last = _lastUiUpdateById[downloadId];
    if (last == null ||
        now.difference(last).inMilliseconds > _uiThrottleMs) {
      _lastUiUpdateById[downloadId] = now;
      return true;
    }
    return false;
  }

  // ─── Download speed calculation ────────────────────────────────────────────

  /// Returns smoothed download speed in bytes/s using a sliding window.
  /// Automatically discards stale samples (e.g. after a resume gap).
  int? _calculateSpeed(String downloadId, int receivedBytes) {
    final tracker = _speedTrackers.putIfAbsent(
      downloadId,
      () => _SpeedTracker(),
    );
    return tracker.addSample(receivedBytes);
  }

  // ─── YouTube download ───────────────────────────────────────────────────────

  Future<void> _downloadYoutube(
    DownloadItem item,
    String savePath,
    CancelToken cancelToken,
  ) async {
    debugPrint('[DOWNLOAD] _downloadYoutube for ${item.url}');

    VideoInfo? info;
    try {
      info = await DownloadService.fetchYoutubeInfo(item.url);
      final current = _getItem(item.id);
      if (current != null) {
        _updateItem(
          item.id,
          current.copyWith(
            title: info.title,
            thumbnailUrl: info.thumbnailUrl,
            duration: info.duration,
            author: info.author,
            status: DownloadStatus.downloading,
          ),
        );
      }
    } catch (e) {
      debugPrint('[DOWNLOAD] fetchYoutubeInfo failed: $e — continuing without metadata');
      final current = _getItem(item.id);
      if (current != null) {
        _updateItem(item.id, current.copyWith(status: DownloadStatus.downloading));
      }
    }

    // Reuse the stream resolved during fetchYoutubeInfo to avoid a double manifest fetch.
    final preResolved = info?.streams
        .where((s) => item.quality == VideoQuality.audioOnly
            ? s.isAudioOnly
            : !s.isAudioOnly)
        .map((s) => s.streamInfo)
        .where((si) => si != null)
        .firstOrNull;

    // Stable filename based on item.id — ensures every retry for the same item
    // writes to the same path so HTTP Range resume can pick up where it left off.
    final stableFileName = 'dl_${item.id.replaceAll('-', '').substring(0, 16)}';

    void reportProgress(double progress, int received, int total) {
      final current = _getItem(item.id);
      if (current == null) return;

      final speedBps = _calculateSpeed(item.id, received);

      final updated = current.copyWith(
        progress: progress,
        downloadedBytes: received,
        fileSizeBytes: total > 0 ? total : null,
        speedBytesPerSec: speedBps,
      );

      if (_shouldUpdateUi(item.id)) {
        _updateItem(item.id, updated);
      } else {
        _updateItemSilent(item.id, updated);
      }

      if (_shouldUpdateNotification(item.id)) {
        final pct = (progress * 100).toInt();
        NotificationService.showProgress(
          downloadId: item.id,
          title: current.title,
          progress: pct,
          receivedBytes: received,
          totalBytes: total,
        );
        ForegroundService.update('${current.title} — $pct%');
      }
    }

    void onPartialPathKnown(String path) {
      final current = _getItem(item.id);
      if (current != null && current.partialFilePath != path) {
        _updateItemDirect(item.id, current.copyWith(partialFilePath: path));
      }
    }

    // First attempt with pre-resolved stream.
    String savedPath;
    try {
      savedPath = await DownloadService.downloadYoutube(
        url: item.url,
        quality: item.quality,
        savePath: savePath,
        cancelToken: cancelToken,
        preResolvedStream: preResolved,
        preResolvedTitle: info?.title,
        suggestedFileName: stableFileName,
        onPartialPathKnown: onPartialPathKnown,
        onProgress: reportProgress,
      );
    } catch (e) {
      if (cancelToken.isCancelled) rethrow;

      // Reset client to clear stale cached player JS then retry once more.
      debugPrint('[DOWNLOAD] First attempt failed: $e — resetting client and retrying...');
      DownloadService.resetYoutubeClient();
      await Future.delayed(const Duration(seconds: 2));

      savedPath = await DownloadService.downloadYoutube(
        url: item.url,
        quality: item.quality,
        savePath: savePath,
        cancelToken: cancelToken,
        // No pre-resolved stream on retry — fetch fresh
        suggestedFileName: stableFileName,
        onPartialPathKnown: onPartialPathKnown,
        onProgress: reportProgress,
      );
    }

    final current = _getItem(item.id);
    if (current != null && current.status != DownloadStatus.cancelled) {
      _updateItem(
        item.id,
        current.copyWith(
          status: DownloadStatus.completed,
          progress: 1.0,
          filePath: savedPath,
          partialFilePath: null,  // clear partial on success
          speedBytesPerSec: null,
        ),
      );
    }
  }

  // ─── Social media download ─────────────────────────────────────────────────

  Future<void> _downloadSocialMedia(
    DownloadItem item,
    String savePath,
    CancelToken cancelToken,
  ) async {
    final info = await DownloadService.resolveSocialUrl(item.url);

    if (info == null) {
      throw Exception(
        'Could not extract download URL for ${item.platform.displayName}. '
        'Make sure the URL is public and try again.',
      );
    }

    final resolvedTitle =
        info.title.isNotEmpty ? info.title : item.platform.displayName;
    final current = _getItem(item.id);
    if (current != null) {
      _updateItem(
        item.id,
        current.copyWith(
          title: resolvedTitle,
          thumbnailUrl: info.thumbnailUrl,
          status: DownloadStatus.downloading,
        ),
      );
    }

    final savedPath = await DownloadService.downloadViaHttp(
      directUrl: info.directUrl,
      title: resolvedTitle,
      savePath: savePath,
      audioOnly: item.quality == VideoQuality.audioOnly,
      cancelToken: cancelToken,
      // Stable filename so retries resume the same partial file
      suggestedFileName: 'dl_${item.id.replaceAll('-', '').substring(0, 16)}',
      onPartialPathKnown: (path) {
        final cur = _getItem(item.id);
        if (cur != null && cur.partialFilePath != path) {
          _updateItemDirect(item.id, cur.copyWith(partialFilePath: path));
        }
      },
      onProgress: (progress, received, total) {
        final cur = _getItem(item.id);
        if (cur == null) return;
        final speedBps = _calculateSpeed(item.id, received);
        final updated = cur.copyWith(
          progress: progress,
          downloadedBytes: received,
          fileSizeBytes: total > 0 ? total : null,
          speedBytesPerSec: speedBps,
        );
        if (_shouldUpdateUi(item.id)) {
          _updateItem(item.id, updated);
        } else {
          _updateItemSilent(item.id, updated);
        }
        if (_shouldUpdateNotification(item.id)) {
          final pct = (progress * 100).toInt();
          NotificationService.showProgress(
            downloadId: item.id,
            title: cur.title,
            progress: pct,
            receivedBytes: received,
            totalBytes: total,
          );
          ForegroundService.update('${cur.title} — $pct%');
        }
      },
    );

    final cur = _getItem(item.id);
    if (cur != null && cur.status != DownloadStatus.cancelled) {
      _updateItem(
        item.id,
        cur.copyWith(
          status: DownloadStatus.completed,
          progress: 1.0,
          filePath: savedPath,
          partialFilePath: null,  // clear partial on success
          speedBytesPerSec: null,
        ),
      );
    }
  }

  // ─── Queue management ──────────────────────────────────────────────────────

  void _processQueuedItems() {
    final maxConcurrent = _settingsProvider?.concurrentDownloads ?? 2;
    if (_activeCount >= maxConcurrent) return;

    final queued =
        _items.where((i) => i.status == DownloadStatus.queued).toList();
    if (queued.isEmpty) return;

    final next = queued.last; // last = earliest added (items are prepended)
    _activeCount++;
    _activeDownloads[next.id] = true;
    _startDownload(next);
  }

  // ─── Public actions ────────────────────────────────────────────────────────

  void cancelDownload(String id) {
    _cancelTokens[id]?.cancel('User cancelled');
    final item = _getItem(id);
    if (item != null) {
      _updateItem(
        id,
        item.copyWith(
          status: DownloadStatus.cancelled,
          errorMessage: 'Cancelled by user',
        ),
      );
    }
  }

  void retryDownload(String id) {
    final item = _getItem(id);
    if (item == null) return;
    // Preserve partialFilePath so the download service can resume from the
    // existing partial file using an HTTP Range request.
    final reset = DownloadItem(
      id: item.id,
      url: item.url,
      title: item.title.isNotEmpty && item.title != 'Fetching info...'
          ? item.title   // keep the known title so the card still looks right
          : 'Retrying...',
      thumbnailUrl: item.thumbnailUrl,
      duration: item.duration,
      author: item.author,
      platform: item.platform,
      quality: item.quality,
      status: DownloadStatus.fetchingInfo,
      partialFilePath: item.partialFilePath,  // <-- carry forward for resume
    );
    _updateItemDirect(id, reset);
    _processDownload(reset);
  }

  void removeDownload(String id) {
    // Dismiss any lingering notification (completed / failed / progress)
    NotificationService.cancel(id);
    cancelDownload(id);
    _items.removeWhere((i) => i.id == id);
    notifyListeners();
    _saveHistory();
  }

  void clearCompleted() {
    // Dismiss notifications for every item about to be removed
    for (final item in _items) {
      if (item.status == DownloadStatus.completed ||
          item.status == DownloadStatus.cancelled ||
          item.status == DownloadStatus.failed) {
        NotificationService.cancel(item.id);
      }
    }
    _items.removeWhere((i) =>
        i.status == DownloadStatus.completed ||
        i.status == DownloadStatus.cancelled ||
        i.status == DownloadStatus.failed);
    notifyListeners();
    _saveHistory();
  }

  // ─── Internal helpers ──────────────────────────────────────────────────────

  DownloadItem? _getItem(String id) {
    try {
      return _items.firstWhere((i) => i.id == id);
    } catch (_) {
      return null;
    }
  }

  void _updateItem(String id, DownloadItem updated) {
    final index = _items.indexWhere((i) => i.id == id);
    if (index != -1) {
      _items[index] = updated;
      notifyListeners();
      if (!updated.status.isActive) {
        _saveHistory();
      }
    }
  }

  void _updateItemDirect(String id, DownloadItem item) {
    final index = _items.indexWhere((i) => i.id == id);
    if (index != -1) {
      _items[index] = item;
      notifyListeners();
    }
  }

  /// Updates the item in the list WITHOUT calling notifyListeners().
  /// Used for throttled-out progress updates to keep internal state fresh.
  void _updateItemSilent(String id, DownloadItem updated) {
    final index = _items.indexWhere((i) => i.id == id);
    if (index != -1) {
      _items[index] = updated;
    }
  }
}

/// Sliding-window speed tracker.
///
/// Keeps the last [_windowMs] milliseconds of (bytes, timestamp) samples and
/// returns an averaged speed, which is much smoother than a two-point
/// instantaneous calculation.  Stale samples (gap > 3 s) are automatically
/// discarded so that resume pauses don't pollute the result.
class _SpeedTracker {
  static const int _windowMs = 3000; // 3-second sliding window
  static const int _staleMs = 3000; // discard samples older than this gap
  static const int _minIntervalMs = 200; // ignore samples closer than this

  final _samples = <_SpeedSample>[];

  /// Add a new received-bytes sample and return the smoothed speed (bytes/s),
  /// or `null` if there aren't enough data points yet.
  int? addSample(int receivedBytes) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // If the last sample is too old (e.g. download was paused/resumed),
    // discard the entire history so we start fresh.
    if (_samples.isNotEmpty && (now - _samples.last.ts) > _staleMs) {
      _samples.clear();
    }

    // Throttle: skip if too close to the last sample
    if (_samples.isNotEmpty && (now - _samples.last.ts) < _minIntervalMs) {
      // Return the last known speed
      return _lastSpeed;
    }

    _samples.add(_SpeedSample(receivedBytes, now));

    // Trim samples outside the window
    final cutoff = now - _windowMs;
    _samples.removeWhere((s) => s.ts < cutoff);

    if (_samples.length < 2) return null;

    final oldest = _samples.first;
    final newest = _samples.last;
    final elapsedMs = newest.ts - oldest.ts;
    if (elapsedMs <= 0) return null;

    final bytesDelta = newest.bytes - oldest.bytes;
    if (bytesDelta <= 0) return null;

    _lastSpeed = (bytesDelta * 1000 / elapsedMs).round();
    return _lastSpeed;
  }

  int? _lastSpeed;
}

class _SpeedSample {
  final int bytes;
  final int ts; // millisecondsSinceEpoch
  const _SpeedSample(this.bytes, this.ts);
}
