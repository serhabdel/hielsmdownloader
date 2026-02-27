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

    // Queue if too many active
    if (_activeCount >= maxConcurrent) {
      _updateItem(item.id, item.copyWith(status: DownloadStatus.queued));
      // Will be picked up when another download finishes
      return;
    }

    _activeCount++;
    _activeDownloads[item.id] = true;
    _startDownload(item);
  }

  void _startDownload(DownloadItem item) async {
    final cancelToken = CancelToken();
    _cancelTokens[item.id] = cancelToken;

    // Show an indeterminate "fetching info" notification immediately
    await NotificationService.showProgress(
      downloadId: item.id,
      title: item.title,
      progress: -1,
      receivedBytes: 0,
      totalBytes: 0,
    );

    // Start the Android foreground service so the download survives backgrounding
    await ForegroundService.start(text: 'Downloading "${item.title}"');

    try {
      final savePath = await DownloadService.getDownloadsDir(
        _settingsProvider?.downloadPath,
      );

      // Step 1: fetch info
      _updateItem(item.id, item.copyWith(status: DownloadStatus.fetchingInfo));

      if (item.platform == SupportedPlatform.youtube) {
        await _downloadYoutube(item, savePath, cancelToken);
      } else {
        await _downloadSocialMedia(item, savePath, cancelToken);
      }

      // Completion notification
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
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          status: DownloadStatus.cancelled,
          errorMessage: 'Download cancelled',
        ));
        await NotificationService.cancel(item.id);
      } else {
        final msg = e.message ?? 'Network error';
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          status: DownloadStatus.failed,
          errorMessage: msg,
        ));
        await NotificationService.showFailed(
          downloadId: item.id,
          title: _getItem(item.id)?.title ?? 'Download',
          reason: msg,
        );
      }
    } catch (e) {
      final msg = e.toString().replaceAll('Exception: ', '');
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        status: DownloadStatus.failed,
        errorMessage: msg,
      ));
      await NotificationService.showFailed(
        downloadId: item.id,
        title: _getItem(item.id)?.title ?? 'Download',
        reason: msg,
      );
    } finally {
      _cancelTokens.remove(item.id);
      _activeDownloads.remove(item.id);
      _activeCount = (_activeCount - 1).clamp(0, 999);
      _processQueuedItems();
      // Stop foreground service when no more active downloads
      if (_activeCount == 0) {
        await ForegroundService.stop();
      }
    }
  }

  Future<void> _downloadYoutube(
    DownloadItem item,
    String savePath,
    CancelToken cancelToken,
  ) async {
    // Fetch info (also resolves the stream manifest once up-front).
    VideoInfo? info;
    try {
      info = await DownloadService.fetchYoutubeInfo(item.url);
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        title: info.title,
        thumbnailUrl: info.thumbnailUrl,
        duration: info.duration,
        author: info.author,
        status: DownloadStatus.downloading,
      ));
    } catch (_) {
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        status: DownloadStatus.downloading,
      ));
    }

    // Reuse the stream info that was already resolved during fetchYoutubeInfo so
    // we don't need to fetch the manifest a second time inside downloadYoutube.
    final preResolved = info?.streams
        .where((s) => item.quality == VideoQuality.audioOnly
            ? s.isAudioOnly
            : !s.isAudioOnly)
        .map((s) => s.streamInfo)
        .where((si) => si != null)
        .firstOrNull;

    void reportProgress(double progress, int received, int total) {
      final current = _getItem(item.id);
      if (current == null) return;
      _updateItem(item.id, current.copyWith(
        progress: progress,
        downloadedBytes: received,
        fileSizeBytes: total > 0 ? total : null,
      ));
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

    String savedPath;
    try {
      savedPath = await DownloadService.downloadYoutube(
        url: item.url,
        quality: item.quality,
        savePath: savePath,
        cancelToken: cancelToken,
        preResolvedStream: preResolved,
        onProgress: reportProgress,
      );
    } catch (e) {
      // Do not retry if the user cancelled.
      if (cancelToken.isCancelled) rethrow;
      // One retry with a fresh manifest fetch (no pre-resolved stream) in case
      // the CDN URL expired between info-fetch and download start.
      await Future.delayed(const Duration(seconds: 2));
      savedPath = await DownloadService.downloadYoutube(
        url: item.url,
        quality: item.quality,
        savePath: savePath,
        cancelToken: cancelToken,
        onProgress: reportProgress,
      );
    }

    final current = _getItem(item.id);
    if (current != null && current.status != DownloadStatus.cancelled) {
      _updateItem(item.id, current.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        filePath: savedPath,
      ));
    }
  }

  Future<void> _downloadSocialMedia(
    DownloadItem item,
    String savePath,
    CancelToken cancelToken,
  ) async {
    // Use direct_link package to extract the real download URL
    final info = await DownloadService.resolveSocialUrl(item.url);

    if (info == null) {
      throw Exception(
        'Could not extract download URL for ${item.platform.displayName}. '
        'Make sure the URL is public and try again.',
      );
    }

    // Update title/thumbnail from the extracted info
    if (info.title.isNotEmpty || info.thumbnailUrl != null) {
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        title: info.title.isNotEmpty ? info.title : item.platform.displayName,
        thumbnailUrl: info.thumbnailUrl,
        status: DownloadStatus.downloading,
      ));
    } else {
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        status: DownloadStatus.downloading,
      ));
    }

    final savedPath = await DownloadService.downloadViaHttp(
      directUrl: info.directUrl,
      title: info.title.isNotEmpty ? info.title : item.platform.displayName,
      savePath: savePath,
      audioOnly: item.quality == VideoQuality.audioOnly,
      cancelToken: cancelToken,
      onProgress: (progress, received, total) {
        final current = _getItem(item.id);
        if (current == null) return;
        _updateItem(item.id, current.copyWith(
          progress: progress,
          downloadedBytes: received,
          fileSizeBytes: total > 0 ? total : null,
        ));
        final pct = (progress * 100).toInt();
        NotificationService.showProgress(
          downloadId: item.id,
          title: current.title,
          progress: pct,
          receivedBytes: received,
          totalBytes: total,
        );
        ForegroundService.update('${current.title} — $pct%');
      },
    );

    final current = _getItem(item.id);
    if (current != null && current.status != DownloadStatus.cancelled) {
      _updateItem(item.id, current.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        filePath: savedPath,
      ));
    }
  }

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

  void cancelDownload(String id) {
    _cancelTokens[id]?.cancel('User cancelled');
    final item = _getItem(id);
    if (item != null) {
      _updateItem(id, item.copyWith(
        status: DownloadStatus.cancelled,
        errorMessage: 'Cancelled by user',
      ));
    }
  }

  void retryDownload(String id) {
    final item = _getItem(id);
    if (item == null) return;
    final reset = DownloadItem(
      id: item.id,
      url: item.url,
      title: 'Retrying...',
      platform: item.platform,
      quality: item.quality,
      status: DownloadStatus.fetchingInfo,
    );
    _updateItemDirect(id, reset);
    _processDownload(reset);
  }

  void removeDownload(String id) {
    cancelDownload(id);
    _items.removeWhere((i) => i.id == id);
    notifyListeners();
    _saveHistory();
  }

  void clearCompleted() {
    _items.removeWhere((i) =>
        i.status == DownloadStatus.completed ||
        i.status == DownloadStatus.cancelled ||
        i.status == DownloadStatus.failed);
    notifyListeners();
    _saveHistory();
  }

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
      // Persist whenever a download reaches a terminal state
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
}
