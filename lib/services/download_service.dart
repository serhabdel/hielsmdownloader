import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:direct_link/direct_link.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import '../models/download_item.dart';

// ─── MediaStore Scanner ───────────────────────────────────────────────────────

/// Notifies Android's MediaStore about a newly written file so it appears in
/// the Gallery / Files app immediately. Works on API 21–37+.
Future<void> scanFileToGallery(String filePath) async {
  if (!Platform.isAndroid) return;
  try {
    const channel = MethodChannel('com.hieltech.smdownloader/media_scanner');
    await channel.invokeMethod<String>('scanFile', {'path': filePath});
  } catch (_) {
    // Non-fatal — file already exists on disk even if Gallery misses it.
  }
}

// ─── NewPipe native audio URL extraction ─────────────────────────────────────

/// Calls the native Kotlin channel to get a properly deobfuscated YouTube
/// audio stream URL via NewPipe Extractor + Mozilla Rhino JS engine.
///
/// Returns a map with keys: streamUrl, title, mimeType, bitrate, itag.
/// Throws [PlatformException] on extraction failure, or [MissingPluginException]
/// when not running on Android (e.g. in unit tests).
Future<Map<String, dynamic>> _getNativeAudioStreamUrl(String videoUrl) async {
  const channel = MethodChannel('com.hieltech.smdownloader/youtube_audio');
  final result = await channel.invokeMapMethod<String, dynamic>(
    'getAudioStreamUrl',
    {'url': videoUrl},
  );
  if (result == null) throw Exception('Native channel returned null.');
  return result;
}

/// Detects which platform a URL belongs to.
SupportedPlatform detectPlatform(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
    return SupportedPlatform.youtube;
  } else if (lower.contains('instagram.com')) {
    return SupportedPlatform.instagram;
  } else if (lower.contains('tiktok.com')) {
    return SupportedPlatform.tiktok;
  } else if (lower.contains('twitter.com') || lower.contains('x.com')) {
    return SupportedPlatform.twitter;
  } else if (lower.contains('facebook.com') || lower.contains('fb.watch')) {
    return SupportedPlatform.facebook;
  } else if (lower.contains('reddit.com') || lower.contains('redd.it')) {
    return SupportedPlatform.reddit;
  } else if (lower.contains('pinterest.com') || lower.contains('pin.it')) {
    return SupportedPlatform.pinterest;
  } else if (lower.contains('vimeo.com')) {
    return SupportedPlatform.vimeo;
  }
  return SupportedPlatform.generic;
}

bool isValidUrl(String url) {
  try {
    final uri = Uri.parse(url.trim());
    return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
  } catch (_) {
    return false;
  }
}

class VideoInfo {
  final String title;
  final String? thumbnailUrl;
  final String? duration;
  final String? author;
  final List<StreamOption> streams;

  VideoInfo({
    required this.title,
    this.thumbnailUrl,
    this.duration,
    this.author,
    required this.streams,
  });
}

class StreamOption {
  final String label;
  final VideoQuality quality;
  final int? bitrate;
  final String container;
  final bool isAudioOnly;
  final dynamic streamInfo; // youtube_explode StreamInfo

  StreamOption({
    required this.label,
    required this.quality,
    this.bitrate,
    required this.container,
    required this.isAudioOnly,
    this.streamInfo,
  });
}

class SocialMediaInfo {
  final String directUrl;
  final String title;
  final String? thumbnailUrl;

  SocialMediaInfo({
    required this.directUrl,
    required this.title,
    this.thumbnailUrl,
  });
}

// ─── Minimum valid file size (1 KB). Smaller means YouTube throttled us. ─────
const int _kMinValidFileBytes = 1024;

class DownloadService {
  // Not final — we reset this instance when the cached YouTube player JS
  // becomes stale (n-parameter decryption fails → silent 0-byte throttle).
  static yt.YoutubeExplode _yt = yt.YoutubeExplode();

  static final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',
    },
  ));

  static Future<String> getDownloadsDir(String? customPath) async {
    if (customPath != null && customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      return customPath;
    }

    if (Platform.isAndroid) {
      // Try the public Downloads folder (needs MANAGE_EXTERNAL_STORAGE on API 30+)
      const publicPath = '/storage/emulated/0/Download/HieLSmD';
      try {
        final permResults = await Future.wait([
          Permission.manageExternalStorage.isGranted,
          Permission.storage.isGranted,
        ]);
        final hasManage = permResults[0];
        final hasStorage = permResults[1];

        if (hasManage || hasStorage) {
          final dir = Directory(publicPath);
          if (!await dir.exists()) await dir.create(recursive: true);
          return publicPath;
        }
      } catch (_) {}

      // Fallback: app-specific external storage (no permission needed)
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final saveDir = Directory('${extDir.path}/HieLSmD');
          if (!await saveDir.exists()) await saveDir.create(recursive: true);
          return saveDir.path;
        }
      } catch (_) {}
    }

    // Last resort: internal documents dir
    final appDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${appDir.path}/HieLSmD');
    if (!await saveDir.exists()) await saveDir.create(recursive: true);
    return saveDir.path;
  }

  // ─── YouTube client management ─────────────────────────────────────────────

  /// Disposes the current [YoutubeExplode] instance and creates a fresh one.
  /// Call this when n-parameter decryption appears stale (0-byte downloads).
  static void resetYoutubeClient() {
    try {
      _yt.close();
    } catch (_) {}
    _yt = yt.YoutubeExplode();
    debugPrint('[YOUTUBE] Client reset — fresh instance ready.');
  }

  static String _sanitizeFilename(String name) {
    final sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return sanitized.substring(0, sanitized.length.clamp(0, 100));
  }

  // ─── File validation ────────────────────────────────────────────────────────

  /// Validates that the downloaded file at [path] is not corrupt / throttled.
  /// Throws a descriptive exception if the file is too small.
  static Future<void> _validateDownloadedFile(
    String path, {
    bool isAudio = false,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Download failed — file was not created. Please retry.');
    }
    final size = await file.length();
    if (size < _kMinValidFileBytes) {
      // Clean up the useless stub file
      try {
        await file.delete();
      } catch (_) {}
      if (isAudio) {
        throw Exception(
          'YouTube audio download was throttled (received $size bytes).\n'
          'This is a known YouTube limitation. Please retry — the app will '
          'use a different download strategy.',
        );
      } else {
        throw Exception(
          'Download appears corrupt (only $size bytes received). Please retry.',
        );
      }
    }
    debugPrint('[VALIDATE] File OK: $path ($size bytes)');
  }

  // ─── YouTube ────────────────────────────────────────────────────────────────

  static Future<VideoInfo> fetchYoutubeInfo(String url) async {
    debugPrint('[YOUTUBE_INFO] Fetching info for: $url');
    final stopwatch = Stopwatch()..start();

    // Fetch video metadata and stream manifest in parallel.
    final results = await Future.wait([
      _yt.videos.get(url),
      _yt.videos.streams.getManifest(url),
    ]);
    final video = results[0] as yt.Video;
    final manifest = results[1] as yt.StreamManifest;
    debugPrint(
      '[YOUTUBE_INFO] Got video+manifest in ${stopwatch.elapsedMilliseconds}ms '
      '— muxed: ${manifest.muxed.length}, audio: ${manifest.audioOnly.length}',
    );

    final streams = <StreamOption>[];

    // Muxed streams (video + audio, up to 360p)
    for (final s in manifest.muxed.sortByVideoQuality()) {
      streams.add(StreamOption(
        label: '${s.videoResolution.height}p (${s.container.name})',
        quality: _heightToQuality(s.videoResolution.height),
        container: s.container.name,
        isAudioOnly: false,
        streamInfo: s,
      ));
    }

    // Best audio-only — prefer m4a (mp4 container) over webm.
    // YouTube throttles webm audio streams far more aggressively than m4a.
    if (manifest.audioOnly.isNotEmpty) {
      final allAudio = manifest.audioOnly.toList();
      final m4aStreams = allAudio
          .where((s) =>
              s.container.name.toLowerCase() == 'mp4' ||
              s.container.name.toLowerCase() == 'm4a')
          .toList();
      final best = m4aStreams.isNotEmpty
          ? (m4aStreams
                ..sort((a, b) =>
                    b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond)))
              .first
          : manifest.audioOnly.withHighestBitrate();
      debugPrint(
        '[YOUTUBE_INFO] Best audio: ${best.container.name}, '
        '${best.bitrate.bitsPerSecond} bps, ${best.size.totalBytes} bytes '
        '(m4a preferred: ${m4aStreams.isNotEmpty})',
      );
      streams.add(StreamOption(
        label: 'Audio Only (${best.container.name})',
        quality: VideoQuality.audioOnly,
        bitrate: best.bitrate.bitsPerSecond,
        container: best.container.name,
        isAudioOnly: true,
        streamInfo: best,
      ));
    } else {
      debugPrint('[YOUTUBE_INFO] WARNING: No audio-only streams available!');
    }

    final durationStr =
        video.duration != null ? _formatDuration(video.duration!) : null;

    return VideoInfo(
      title: video.title,
      thumbnailUrl: video.thumbnails.highResUrl,
      duration: durationStr,
      author: video.author,
      streams: streams,
    );
  }

  /// Downloads a YouTube video or audio stream.
  ///
  /// [suggestedFileName] (without extension) is used when provided so that
  /// retries for the same [DownloadItem] write to the same file path, enabling
  /// HTTP Range resume.  If omitted a timestamp-based name is generated.
  ///
  /// [onPartialPathKnown] is called with the resolved file path as soon as the
  /// filename is decided (before any bytes are downloaded).  The provider uses
  /// this to persist the partial path so retries can resume.
  ///
  /// Strategy (audio-only):
  ///   0. NewPipe native extraction → Dio download
  ///   1. youtube_explode fresh manifest → Dio download
  ///   2. youtube_explode stream iterator (reset client, fresh manifest,
  ///      chunked download with 30 s per-chunk timeout)
  ///   All attempts include post-download size validation to catch throttled
  ///   0-byte responses before FFmpeg is invoked.
  ///
  /// Strategy (video):
  ///   1. youtube_explode stream iterator (chunked, 30 s per-chunk timeout)
  static Future<String> downloadYoutube({
    required String url,
    required VideoQuality quality,
    required String savePath,
    required void Function(double progress, int received, int total) onProgress,
    CancelToken? cancelToken,
    dynamic preResolvedStream,
    String? preResolvedTitle,
    /// If provided, file is saved as `$savePath/$suggestedFileName.$ext` so
    /// that repeated retries hit the same path for HTTP Range resume.
    String? suggestedFileName,
    /// Called with the resolved file path before any data is written.
    void Function(String path)? onPartialPathKnown,
  }) async {
    debugPrint('[YOUTUBE_DL] Starting — quality: $quality');
    final stopwatch = Stopwatch()..start();

    // Resolve video title (skip network call if already known).
    late final String videoTitle;
    if (preResolvedTitle != null && preResolvedTitle.isNotEmpty) {
      videoTitle = preResolvedTitle;
    } else {
      final video = await _yt.videos.get(url);
      videoTitle = video.title;
    }

    yt.StreamInfo streamInfo;
    if (preResolvedStream != null && preResolvedStream is yt.StreamInfo) {
      streamInfo = preResolvedStream;
    } else if (quality == VideoQuality.audioOnly) {
      final manifest = await _yt.videos.streams.getManifest(url);
      if (manifest.audioOnly.isEmpty) {
        throw Exception('No audio stream available for this video.');
      }
      streamInfo = manifest.audioOnly.withHighestBitrate();
    } else {
      final manifest = await _yt.videos.streams.getManifest(url);
      final muxed = manifest.muxed.sortByVideoQuality();
      if (muxed.isEmpty) {
        throw Exception('No suitable video stream found.');
      }
      streamInfo = muxed.first;
      for (final s in muxed) {
        if (_heightMatchesQuality(s.videoResolution.height, quality)) {
          streamInfo = s;
          break;
        }
      }
    }

    final ext = streamInfo.container.name;
    final title = _sanitizeFilename(videoTitle);
    // Use suggestedFileName when provided so that retries reuse the same path
    // for HTTP Range resume.  Fall back to timestamp-based name on first run.
    final baseName = suggestedFileName?.isNotEmpty == true
        ? suggestedFileName!
        : '${title}_${DateTime.now().millisecondsSinceEpoch}';
    final fileName = '$baseName.$ext';
    final filePath = '$savePath/$fileName';

    // Notify the provider early so it can store the partial path for retries
    onPartialPathKnown?.call(filePath);

    // ── Audio-only path ──────────────────────────────────────────────────────
    if (quality == VideoQuality.audioOnly) {
      await _downloadAudioWithFallbacks(
        url: url,
        streamInfo: streamInfo,
        filePath: filePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
        stopwatch: stopwatch,
      );

      // Validate the audio stream
      await _validateDownloadedFile(filePath, isAudio: true);

      await scanFileToGallery(filePath);
      return filePath;
    }

    // ── Video path ───────────────────────────────────────────────────────────
    debugPrint('[YOUTUBE_DL] Downloading video stream...');
    await _downloadStreamToFile(
      streamInfo: streamInfo,
      filePath: filePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
      stopwatch: stopwatch,
    );

    await _validateDownloadedFile(filePath, isAudio: false);
    await scanFileToGallery(filePath);

    debugPrint('[YOUTUBE_DL] Done in ${stopwatch.elapsedMilliseconds}ms');
    return filePath;
  }

  // ─── Audio download with ordered fallbacks ──────────────────────────────────

  static Future<void> _downloadAudioWithFallbacks({
    required String url,
    required yt.StreamInfo streamInfo,
    required String filePath,
    required void Function(double, int, int) onProgress,
    required Stopwatch stopwatch,
    CancelToken? cancelToken,
  }) async {
    bool cancelCheck() => cancelToken?.isCancelled == true;

    // Helper to delete partial file between retries
    Future<void> deletePartial() async {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    // ── Attempt 0: NewPipe Extractor via native Kotlin channel ───────────────
    // NewPipe runs Mozilla Rhino to properly deobfuscate YouTube's n-parameter,
    // producing a valid CDN URL that Dio can download without 403s.
    debugPrint('[YOUTUBE_DL] Attempt 0: NewPipe native extraction...');
    try {
      final nativeInfo = await _getNativeAudioStreamUrl(url)
          .timeout(const Duration(seconds: 60));
      final nativeUrl = nativeInfo['streamUrl'] as String?;
      if (nativeUrl != null && nativeUrl.isNotEmpty) {
        debugPrint('[YOUTUBE_DL] Attempt 0: got native URL, downloading via Dio...');

        // Retry loop for transient connection drops (e.g. app backgrounded).
        // _dioDownload automatically resumes from the partial file via Range
        // headers, so progress is never lost between retries.
        const maxDioRetries = 3;
        DioException? lastDioError;
        for (var retry = 0; retry < maxDioRetries; retry++) {
          try {
            await _dioDownload(
              directUrl: nativeUrl,
              filePath: filePath,
              onProgress: onProgress,
              cancelToken: cancelToken,
            );
            lastDioError = null;
            break;
          } on DioException catch (e) {
            if (cancelCheck() || CancelToken.isCancel(e)) rethrow;
            lastDioError = e;
            // null statusCode = socket reset / connection drop (not an HTTP error)
            final isConnectionDrop = e.response?.statusCode == null;
            if (isConnectionDrop && retry < maxDioRetries - 1) {
              debugPrint(
                '[YOUTUBE_DL] Attempt 0 connection dropped '
                '(retry ${retry + 1}/$maxDioRetries), resuming in 2s...',
              );
              // Keep partial file so _dioDownload resumes via Range header
              await Future.delayed(const Duration(seconds: 2));
              continue;
            }
            break; // non-recoverable HTTP error or retries exhausted
          }
        }

        if (lastDioError != null) {
          debugPrint(
            '[YOUTUBE_DL] Attempt 0 Dio failed after retries '
            '(${lastDioError.response?.statusCode}): ${lastDioError.message}',
          );
          await deletePartial();
        } else {
          final sz = await File(filePath).length();
          if (sz >= _kMinValidFileBytes) {
            debugPrint('[YOUTUBE_DL] Attempt 0 succeeded ($sz bytes) via NewPipe.');
            return;
          }
          debugPrint('[YOUTUBE_DL] Attempt 0: file too small ($sz bytes), falling back...');
          await deletePartial();
        }
      }
    } catch (e) {
      if (cancelCheck()) rethrow;
      // PlatformException, MissingPluginException, timeout, etc. — non-fatal
      debugPrint('[YOUTUBE_DL] Attempt 0 native extraction failed: $e');
      await deletePartial();
    }

    // ── Attempt 1: Fresh manifest + Dio download ──────────────────────────────
    debugPrint('[YOUTUBE_DL] Attempt 1: fresh manifest + Dio...');
    try {
      final freshStream = await _fetchBestAudioStream(url);
      if (cancelCheck()) throw Exception('Download cancelled');
      await _dioDownload(
        directUrl: freshStream.url.toString(),
        filePath: filePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      final sz = await File(filePath).length();
      if (sz >= _kMinValidFileBytes) {
        debugPrint('[YOUTUBE_DL] Attempt 1 succeeded ($sz bytes).');
        return;
      }
      debugPrint('[YOUTUBE_DL] Attempt 1: file too small ($sz bytes), continuing...');
      await deletePartial();
    } on DioException catch (e) {
      if (cancelCheck() || CancelToken.isCancel(e)) rethrow;
      debugPrint(
        '[YOUTUBE_DL] Attempt 1 Dio error (${e.response?.statusCode}): ${e.message}',
      );
      await deletePartial();
    } catch (e) {
      if (cancelCheck()) rethrow;
      debugPrint('[YOUTUBE_DL] Attempt 1 failed: $e');
      await deletePartial();
    }

    // ── Attempt 2: Reset client + stream iterator (last resort) ──────────────
    debugPrint('[YOUTUBE_DL] Attempt 2: resetting client for stream iterator...');
    resetYoutubeClient();
    await deletePartial();

    yt.StreamInfo iteratorStream;
    try {
      iteratorStream = await _fetchBestAudioStream(url)
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      if (cancelCheck()) rethrow;
      debugPrint('[YOUTUBE_DL] Attempt 2 manifest fetch failed: $e');
      throw Exception(
        'All download attempts failed. YouTube may be temporarily blocking '
        'this video — please wait a moment and retry.',
      );
    }

    debugPrint('[YOUTUBE_DL] Attempt 2: starting stream iterator...');
    await _downloadStreamToFile(
      streamInfo: iteratorStream,
      filePath: filePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
      stopwatch: stopwatch,
    );
    // _validateDownloadedFile is called by the caller after this returns.
  }

  // ─── Fetch best audio stream from a fresh manifest ─────────────────────────

  static Future<yt.StreamInfo> _fetchBestAudioStream(String url) async {
    final manifest = await _yt.videos.streams.getManifest(url);
    final allAudio = manifest.audioOnly.toList();
    if (allAudio.isEmpty) throw Exception('No audio stream available.');
    final m4a = allAudio
        .where((s) =>
            s.container.name.toLowerCase() == 'mp4' ||
            s.container.name.toLowerCase() == 'm4a')
        .toList();
    if (m4a.isNotEmpty) {
      m4a.sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      return m4a.first;
    }
    return manifest.audioOnly.withHighestBitrate();
  }

  // ─── Dio direct download helper (with HTTP Range / resume support) ──────────

  /// Downloads [directUrl] to [filePath].
  ///
  /// **Resume behaviour**: if a partial file already exists at [filePath] that
  /// is larger than [_kMinValidFileBytes], the method sends a `Range: bytes=N-`
  /// header and appends the new data to the existing file.  If the server
  /// returns `200` (no range support) the partial file is discarded and a full
  /// download is started.  Partial files are always kept on error so that the
  /// next retry can resume seamlessly.
  static Future<void> _dioDownload({
    required String directUrl,
    required String filePath,
    required void Function(double, int, int) onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(filePath);
    int startByte = 0;

    // ── Check for an existing partial file ────────────────────────────────────
    if (await file.exists()) {
      final partialSize = await file.length();
      if (partialSize >= _kMinValidFileBytes) {
        startByte = partialSize;
        debugPrint('[DIO_DOWNLOAD] Resuming from byte $startByte ($filePath)');
      } else {
        // Too small to be a valid partial — wipe and start fresh
        try { await file.delete(); } catch (_) {}
      }
    }

    // ── Resume path (Range request + append) ──────────────────────────────────
    if (startByte > 0) {
      Response<ResponseBody>? rangeResponse;
      try {
        rangeResponse = await _dio.get<ResponseBody>(
          directUrl,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(minutes: 30),
            validateStatus: (s) => s != null && s >= 200 && s < 300,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
                      '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',
              'Referer': 'https://www.youtube.com/',
              'Range': 'bytes=$startByte-',
            },
          ),
        );
      } on DioException {
        rethrow;
      }

      if (rangeResponse.statusCode == 206) {
        // ── Server supports ranges — append and track progress ────────────────
        int totalBytes = 0;
        final contentRange = rangeResponse.headers.value('content-range');
        if (contentRange != null) {
          final totalStr = contentRange.split('/').lastOrNull?.trim();
          totalBytes = int.tryParse(totalStr ?? '') ?? 0;
        }
        if (totalBytes == 0) {
          final cl = rangeResponse.headers.value('content-length');
          totalBytes = startByte + (int.tryParse(cl ?? '') ?? 0);
        }

        final sink = file.openWrite(mode: FileMode.append);
        int received = startByte;
        final completer = Completer<void>();

        (rangeResponse.data as ResponseBody).stream.listen(
          (chunk) {
            if (cancelToken?.isCancelled == true) {
              sink.close().ignore();
              if (!completer.isCompleted) {
                completer.completeError(
                  DioException(
                    requestOptions: RequestOptions(path: directUrl),
                    type: DioExceptionType.cancel,
                  ),
                );
              }
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            onProgress(
              totalBytes > 0 ? received / totalBytes : 0,
              received,
              totalBytes,
            );
          },
          onDone: () { if (!completer.isCompleted) completer.complete(); },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
          cancelOnError: true,
        );
        try {
          await completer.future;
          await sink.flush();
          await sink.close();
          debugPrint('[DIO_DOWNLOAD] Resume complete — $received bytes total.');
          return;
        } catch (e) {
          await sink.close().catchError((_) {});
          rethrow;
        }
      } else {
        // Server returned 200 (no range support) — discard partial & restart
        debugPrint(
          '[DIO_DOWNLOAD] Server rejected Range header '
          '(${rangeResponse.statusCode}), restarting from zero.',
        );
        try { await file.delete(); } catch (_) {}
        startByte = 0;
      }
    }

    // ── Normal (non-resume) download ──────────────────────────────────────────
    // deleteOnError: false ensures the partial file is kept so the next retry
    // can resume from where this one left off.
    await _dio.download(
      directUrl,
      filePath,
      deleteOnError: false,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        onProgress(total > 0 ? received / total : 0, received, total);
      },
      options: Options(
        receiveTimeout: const Duration(minutes: 30),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',
          'Referer': 'https://www.youtube.com/',
        },
      ),
    );
    debugPrint('[DIO_DOWNLOAD] Download complete.');
  }

  // ─── youtube_explode stream iterator download ────────────────────────────────

  static Future<void> _downloadStreamToFile({
    required yt.StreamInfo streamInfo,
    required String filePath,
    required void Function(double progress, int received, int total) onProgress,
    required Stopwatch stopwatch,
    CancelToken? cancelToken,
  }) async {
    debugPrint('[YOUTUBE_DL] Opening stream... (${stopwatch.elapsedMilliseconds}ms)');
    final stream = _yt.videos.streams.get(streamInfo);
    final file = File(filePath);
    final sink = file.openWrite();

    final totalBytes = streamInfo.size.totalBytes;
    int received = 0;
    int chunkCount = 0;
    DateTime? lastLog;

    // We use a manual StreamSubscription instead of `await for` so that a
    // Timer can complete the Completer with an error even when the stream
    // generator is stuck awaiting an internal HTTP call (which `await for`
    // with Stream.timeout() cannot interrupt).
    final completer = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? timeoutTimer;

    // Starts (or resets) a timeout.  If it fires before being cancelled it
    // cancels the subscription and fails the completer, unblocking the caller.
    void armTimeout(Duration duration, String reason) {
      timeoutTimer?.cancel();
      timeoutTimer = Timer(duration, () {
        if (completer.isCompleted) return;
        subscription?.cancel();
        sink.close();
        try {
          file.deleteSync();
        } catch (_) {}
        completer.completeError(TimeoutException(reason));
      });
    }

    // 45 s to receive the very first chunk (DNS + TCP + TLS + HTTP headers +
    // first bytes).  Generous enough for slow connections; short enough to
    // surface hangs that would otherwise last forever.
    armTimeout(
      const Duration(seconds: 45),
      'YouTube audio stream timed out — no data received in 45 s. '
      'The stream URL may have expired or YouTube is throttling. Retry.',
    );

    subscription = stream.listen(
      (chunk) {
        // Check for user cancellation on every chunk
        if (cancelToken?.isCancelled == true) {
          timeoutTimer?.cancel();
          subscription?.cancel();
          sink.close();
          try { file.deleteSync(); } catch (_) {}
          if (!completer.isCompleted) {
            completer.completeError(Exception('Download cancelled'));
          }
          return;
        }

        if (chunkCount == 0) {
          debugPrint(
            '[YOUTUBE_DL] First chunk received (${stopwatch.elapsedMilliseconds}ms)',
          );
        }

        sink.add(chunk);
        received += chunk.length;
        chunkCount++;

        // Reset to the inter-chunk timeout after every chunk
        armTimeout(
          const Duration(seconds: 30),
          chunkCount < 5
              ? 'YouTube audio stream stalled after $chunkCount chunks '
                  '($received bytes). Possible n-param throttle.'
              : 'YouTube audio stream stalled after $received bytes. '
                  'Stream URL may have expired.',
        );

        // Throttled progress logging: first chunk, every 100 chunks, or every 3 s
        final now = DateTime.now();
        if (chunkCount == 1 ||
            chunkCount % 100 == 0 ||
            (lastLog != null && now.difference(lastLog!).inSeconds > 3)) {
          debugPrint(
            '[YOUTUBE_DL] $chunkCount chunks, $received/$totalBytes bytes '
            '(${totalBytes > 0 ? (received / totalBytes * 100).toStringAsFixed(1) : "?"}%)',
          );
          lastLog = now;
        }

        onProgress(
          totalBytes > 0 ? received / totalBytes : 0,
          received,
          totalBytes,
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        timeoutTimer?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
      onDone: () {
        timeoutTimer?.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
      await sink.flush();
      await sink.close();
      debugPrint(
        '[YOUTUBE_DL] Stream complete — $chunkCount chunks, $received bytes '
        '(${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e, st) {
      timeoutTimer?.cancel();
      await subscription.cancel();
      debugPrint('[YOUTUBE_DL] Stream error: $e\n$st');
      // sink may already be closed by the timeout handler; ignore errors here
      try { await sink.close(); } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  // ─── Generic HTTP download (Instagram, TikTok, etc.) ──────────────────────

  static Future<VideoInfo> fetchGenericInfo(String url) async {
    final platform = detectPlatform(url);
    return VideoInfo(
      title: '${platform.displayName} Video',
      streams: [
        StreamOption(
          label: 'Default Quality',
          quality: VideoQuality.best,
          container: 'mp4',
          isAudioOnly: false,
        ),
      ],
    );
  }

  static final _directLink = DirectLink();

  static Future<SocialMediaInfo?> resolveSocialUrl(String url) async {
    try {
      final data = await _directLink.check(url);
      if (data == null || data.links == null || data.links!.isEmpty) {
        return null;
      }

      final videoLinks = data.links!
          .where((l) =>
              l.type?.toLowerCase().contains('video') == true ||
              l.quality.isNotEmpty)
          .toList();

      final bestLink =
          videoLinks.isNotEmpty ? videoLinks.first : data.links!.first;
      final directUrl = bestLink.link;
      if (directUrl.isEmpty) return null;

      return SocialMediaInfo(
        directUrl: directUrl,
        title: data.title ?? '',
        thumbnailUrl: data.thumbnail,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String> downloadViaHttp({
    required String directUrl,
    required String title,
    required String savePath,
    required void Function(double progress, int received, int total) onProgress,
    CancelToken? cancelToken,
    bool audioOnly = false,
    String? suggestedFileName,
    void Function(String path)? onPartialPathKnown,
  }) async {
    final baseName = suggestedFileName?.isNotEmpty == true
        ? suggestedFileName!
        : '${_sanitizeFilename(title)}_${DateTime.now().millisecondsSinceEpoch}';
    final tempFilePath = '$savePath/$baseName.mp4';

    onPartialPathKnown?.call(tempFilePath);

    // Use _dioDownload for resume support (checks for partial file, Range header)
    await _dioDownload(
      directUrl: directUrl,
      filePath: tempFilePath,
      onProgress: (progress, received, total) {
        onProgress(progress, received, total);
      },
      cancelToken: cancelToken,
    );

    // Validate the downloaded file
    await _validateDownloadedFile(tempFilePath, isAudio: audioOnly);

    await scanFileToGallery(tempFilePath);
    return tempFilePath;
  }



  // ─── Helpers ─────────────────────────────────────────────────────────────

  static VideoQuality _heightToQuality(int height) {
    if (height >= 1080) return VideoQuality.hd1080;
    if (height >= 720) return VideoQuality.hd720;
    if (height >= 480) return VideoQuality.sd480;
    return VideoQuality.sd360;
  }

  static bool _heightMatchesQuality(int height, VideoQuality quality) {
    switch (quality) {
      case VideoQuality.best:
        return true;
      case VideoQuality.hd1080:
        return height >= 1080;
      case VideoQuality.hd720:
        return height >= 720 && height < 1080;
      case VideoQuality.sd480:
        return height >= 480 && height < 720;
      case VideoQuality.sd360:
        return height <= 480;
      default:
        return false;
    }
  }



  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  static void dispose() {
    _yt.close();
    _dio.close();
  }
}
