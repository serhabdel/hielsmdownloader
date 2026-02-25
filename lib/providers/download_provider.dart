import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/download_item.dart';
import '../services/download_service.dart';
import 'settings_provider.dart';

class DownloadProvider extends ChangeNotifier {
  final List<DownloadItem> _items = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _activeDownloads = {};
  SettingsProvider? _settingsProvider;
  int _activeCount = 0;

  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get activeItems =>
      _items.where((i) => i.status.isActive).toList();
  List<DownloadItem> get completedItems =>
      _items.where((i) => i.status == DownloadStatus.completed).toList();
  int get activeCount => _activeCount;

  void init(SettingsProvider settings) {
    _settingsProvider = settings;
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
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          status: DownloadStatus.cancelled,
          errorMessage: 'Download cancelled',
        ));
      } else {
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          status: DownloadStatus.failed,
          errorMessage: e.message ?? 'Network error',
        ));
      }
    } catch (e) {
      _updateItem(item.id, _getItem(item.id)!.copyWith(
        status: DownloadStatus.failed,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      ));
    } finally {
      _cancelTokens.remove(item.id);
      _activeDownloads.remove(item.id);
      _activeCount = (_activeCount - 1).clamp(0, 999);
      _processQueuedItems();
    }
  }

  Future<void> _downloadYoutube(
    DownloadItem item,
    String savePath,
    CancelToken cancelToken,
  ) async {
    // Fetch info
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

    await DownloadService.downloadYoutube(
      url: item.url,
      quality: item.quality,
      savePath: savePath,
      cancelToken: cancelToken,
      onProgress: (progress, received, total) {
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          progress: progress,
          downloadedBytes: received,
          fileSizeBytes: total > 0 ? total : null,
        ));
      },
    );

    final current = _getItem(item.id);
    if (current != null && current.status != DownloadStatus.cancelled) {
      _updateItem(item.id, current.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
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

    await DownloadService.downloadViaHttp(
      directUrl: info.directUrl,
      title: info.title.isNotEmpty ? info.title : item.platform.displayName,
      savePath: savePath,
      cancelToken: cancelToken,
      onProgress: (progress, received, total) {
        _updateItem(item.id, _getItem(item.id)!.copyWith(
          progress: progress,
          downloadedBytes: received,
          fileSizeBytes: total > 0 ? total : null,
        ));
      },
    );

    final current = _getItem(item.id);
    if (current != null && current.status != DownloadStatus.cancelled) {
      _updateItem(item.id, current.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
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
  }

  void clearCompleted() {
    _items.removeWhere((i) =>
        i.status == DownloadStatus.completed ||
        i.status == DownloadStatus.cancelled ||
        i.status == DownloadStatus.failed);
    notifyListeners();
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
