import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:direct_link/direct_link.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
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

/// Detects which platform a URL belongs to
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

class DownloadService {
  static final _yt = yt.YoutubeExplode();
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
      const publicPath = '/storage/emulated/0/Download/ReelsDownloader';
      try {
        final hasManage =
            await Permission.manageExternalStorage.isGranted;
        final hasStorage = await Permission.storage.isGranted;

        if (hasManage || hasStorage) {
          final dir = Directory(publicPath);
          if (!await dir.exists()) await dir.create(recursive: true);
          return publicPath;
        }
      } catch (_) {}

      // Fallback: app-specific external storage (no permission needed,
      // visible in Files app under Android/data/…)
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final saveDir = Directory('${extDir.path}/ReelsDownloader');
          if (!await saveDir.exists()) await saveDir.create(recursive: true);
          return saveDir.path;
        }
      } catch (_) {}
    }

    // Last resort: internal documents dir
    final appDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${appDir.path}/ReelsDownloader');
    if (!await saveDir.exists()) await saveDir.create(recursive: true);
    return saveDir.path;
  }

  static String _sanitizeFilename(String name) {
    final sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Clamp using the sanitized string's own length, not the original
    return sanitized.substring(0, sanitized.length.clamp(0, 100));
  }

  // ─── YouTube ────────────────────────────────────────────────────────────────

  static Future<VideoInfo> fetchYoutubeInfo(String url) async {
    debugPrint('[YOUTUBE_INFO] Fetching info for: $url');
    final stopwatch = Stopwatch()..start();
    
    final video = await _yt.videos.get(url);
    debugPrint('[YOUTUBE_INFO] Got video: ${video.title} (${stopwatch.elapsedMilliseconds}ms)');
    
    final manifest = await _yt.videos.streams.getManifest(url);
    debugPrint('[YOUTUBE_INFO] Got manifest - muxed: ${manifest.muxed.length}, audioOnly: ${manifest.audioOnly.length}, videoOnly: ${manifest.videoOnly.length} (${stopwatch.elapsedMilliseconds}ms)');

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

    // Best audio-only
    if (manifest.audioOnly.isNotEmpty) {
      final best = manifest.audioOnly.withHighestBitrate();
      debugPrint('[YOUTUBE_INFO] Best audio stream: ${best.container.name}, bitrate: ${best.bitrate.bitsPerSecond}, size: ${best.size.totalBytes}');
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

    final durationStr = video.duration != null
        ? _formatDuration(video.duration!)
        : null;

    return VideoInfo(
      title: video.title,
      thumbnailUrl: video.thumbnails.highResUrl,
      duration: durationStr,
      author: video.author,
      streams: streams,
    );
  }

  static Future<String> downloadYoutube({
    required String url,
    required VideoQuality quality,
    required String savePath,
    required void Function(double progress, int received, int total) onProgress,
    void Function()? onConverting,
    CancelToken? cancelToken,
    /// Pass a pre-resolved [yt.StreamInfo] (typed as dynamic to avoid leaking
    /// the youtube_explode_dart import into callers) from a prior
    /// [fetchYoutubeInfo] call to avoid fetching the stream manifest a second time.
    dynamic preResolvedStream,
  }) async {
    debugPrint('[YOUTUBE_DL] Starting download - quality: $quality, url: $url');
    final stopwatch = Stopwatch()..start();
    
    final video = await _yt.videos.get(url);
    debugPrint('[YOUTUBE_DL] Got video info: ${video.title} (${stopwatch.elapsedMilliseconds}ms)');

    yt.StreamInfo streamInfo;

    if (preResolvedStream != null && preResolvedStream is yt.StreamInfo) {
      // Reuse the already-resolved stream info — no second manifest fetch needed.
      streamInfo = preResolvedStream;
      debugPrint('[YOUTUBE_DL] Using pre-resolved stream: ${streamInfo.container.name}');
    } else if (quality == VideoQuality.audioOnly) {
      debugPrint('[YOUTUBE_DL] Fetching audio-only manifest...');
      final manifest = await _yt.videos.streams.getManifest(url);
      debugPrint('[YOUTUBE_DL] Got manifest - audio streams: ${manifest.audioOnly.length} (${stopwatch.elapsedMilliseconds}ms)');
      if (manifest.audioOnly.isEmpty) {
        throw Exception('No audio stream available for this video.');
      }
      streamInfo = manifest.audioOnly.withHighestBitrate();
      debugPrint('[YOUTUBE_DL] Selected audio stream: ${streamInfo.container.name}, bitrate: ${streamInfo.bitrate.bitsPerSecond}, size: ${streamInfo.size.totalBytes} bytes');
    } else {
      debugPrint('[YOUTUBE_DL] Fetching video manifest for quality: $quality...');
      final manifest = await _yt.videos.streams.getManifest(url);
      // Try muxed streams first (they contain both audio and video)
      final muxed = manifest.muxed.sortByVideoQuality();
      if (muxed.isNotEmpty) {
        streamInfo = muxed.first;
        // Try to find best matching quality
        for (final s in muxed) {
          final h = s.videoResolution.height;
          if (_heightMatchesQuality(h, quality)) {
            streamInfo = s;
            break;
          }
        }
      } else {
        throw Exception('No suitable stream found for this video');
      }
    }

    final audioAlreadyMp3 =
      quality == VideoQuality.audioOnly && _isMp3AudioStream(streamInfo);

    // For audio-only, keep final user-facing extension as .mp3 whenever
    // possible. If source is not MP3, download to temp and convert.
    final ext = quality == VideoQuality.audioOnly
      ? (audioAlreadyMp3 ? 'mp3' : 'tmp')
      : streamInfo.container.name; // e.g. "webm" or "mp4"
    final title = _sanitizeFilename(video.title);
    final fileName = '${title}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final filePath = '$savePath/$fileName';

    // Audio-only streams are more reliable when downloaded via direct HTTP URL
    // (Dio) than the chunked youtube_explode stream iterator on some devices.
    if (quality == VideoQuality.audioOnly) {
      final directUrl = streamInfo.url.toString();
      try {
        await _dio.download(
          directUrl,
          filePath,
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
      } on DioException catch (e) {
        if (cancelToken?.isCancelled == true || CancelToken.isCancel(e)) {
          rethrow;
        }

        final status = e.response?.statusCode;
        debugPrint(
          '[YOUTUBE_DL] Direct audio HTTP failed (${status ?? 'no-status'}). Falling back to youtube_explode stream.',
        );

        await _downloadYoutubeStreamToFile(
          streamInfo: streamInfo,
          filePath: filePath,
          quality: quality,
          cancelToken: cancelToken,
          onProgress: onProgress,
          stopwatch: stopwatch,
        );
      }

      if (audioAlreadyMp3) {
        await scanFileToGallery(filePath);
        return filePath;
      }

      onConverting?.call();
      final outputPath = await _convertToMp3(filePath);
      await scanFileToGallery(outputPath);
      return outputPath;
    }

    debugPrint('[YOUTUBE_DL] Opening stream... (${stopwatch.elapsedMilliseconds}ms)');
    final stream = _yt.videos.streams.get(streamInfo);
    final file = File(filePath);
    final sink = file.openWrite();
    debugPrint('[YOUTUBE_DL] File opened for writing: $filePath');

    final totalBytes = streamInfo.size.totalBytes;
    int received = 0;
    int chunkCount = 0;
    DateTime? lastLog;

    try {
      debugPrint('[YOUTUBE_DL] Starting stream read loop - totalBytes: $totalBytes');
      
      // Use a stream timeout to detect stuck streams even when no chunks are
      // emitted. Audio-only streams may have longer initial latency.
      final chunkTimeout = quality == VideoQuality.audioOnly
          ? const Duration(seconds: 90)
          : const Duration(seconds: 45);

      await for (final chunk in stream.timeout(
        chunkTimeout,
        onTimeout: (eventSink) {
          eventSink.addError(
            TimeoutException(
              'Download stream timed out. The video may be restricted or the stream URL expired.',
            ),
          );
          eventSink.close();
        },
      )) {
        if (cancelToken?.isCancelled == true) {
          throw Exception('Download cancelled');
        }

        sink.add(chunk);
        received += chunk.length;
        chunkCount++;

        final now = DateTime.now();
        // Log every 100 chunks or every 5 seconds
        if (chunkCount % 100 == 0 || (lastLog == null || now.difference(lastLog).inSeconds > 5)) {
          debugPrint('[YOUTUBE_DL] Progress: $chunkCount chunks, $received / $totalBytes bytes (${(received/totalBytes*100).toStringAsFixed(1)}%)');
          lastLog = now;
        }
        
        onProgress(
          totalBytes > 0 ? received / totalBytes : 0,
          received,
          totalBytes,
        );
      }
      debugPrint('[YOUTUBE_DL] Stream completed - $chunkCount chunks, $received bytes total (${stopwatch.elapsedMilliseconds}ms)');
      await sink.flush();
      await sink.close();
      debugPrint('[YOUTUBE_DL] File saved successfully');
    } catch (e, stackTrace) {
      // Always close and remove the partial file on any error (including cancel).
      debugPrint('[YOUTUBE_DL] ERROR during download: $e');
      debugPrint('[YOUTUBE_DL] Stack trace: $stackTrace');
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }

    // Convert to real MP3 if audio-only was requested.
    final outputPath = quality == VideoQuality.audioOnly
        ? (() async {
            onConverting?.call();
            return _convertToMp3(filePath);
          })()
        : Future.value(filePath);

    final resolvedOutputPath = await outputPath;

    // Notify Android MediaStore so the file appears in Files/Music app.
    await scanFileToGallery(resolvedOutputPath);

    return resolvedOutputPath;
  }

  static Future<void> _downloadYoutubeStreamToFile({
    required yt.StreamInfo streamInfo,
    required String filePath,
    required VideoQuality quality,
    required void Function(double progress, int received, int total) onProgress,
    required Stopwatch stopwatch,
    CancelToken? cancelToken,
  }) async {
    debugPrint('[YOUTUBE_DL] Opening stream... (${stopwatch.elapsedMilliseconds}ms)');
    final stream = _yt.videos.streams.get(streamInfo);
    final file = File(filePath);
    final sink = file.openWrite();
    debugPrint('[YOUTUBE_DL] File opened for writing: $filePath');

    final totalBytes = streamInfo.size.totalBytes;
    int received = 0;
    int chunkCount = 0;
    DateTime? lastLog;

    try {
      debugPrint('[YOUTUBE_DL] Starting stream read loop - totalBytes: $totalBytes');

      final chunkTimeout = quality == VideoQuality.audioOnly
          ? const Duration(seconds: 90)
          : const Duration(seconds: 45);

      await for (final chunk in stream.timeout(
        chunkTimeout,
        onTimeout: (eventSink) {
          eventSink.addError(
            TimeoutException(
              'Download stream timed out. The video may be restricted or the stream URL expired.',
            ),
          );
          eventSink.close();
        },
      )) {
        if (cancelToken?.isCancelled == true) {
          throw Exception('Download cancelled');
        }

        sink.add(chunk);
        received += chunk.length;
        chunkCount++;

        final now = DateTime.now();
        if (chunkCount % 100 == 0 ||
            (lastLog == null || now.difference(lastLog).inSeconds > 5)) {
          debugPrint(
            '[YOUTUBE_DL] Progress: $chunkCount chunks, $received / $totalBytes bytes (${(received / totalBytes * 100).toStringAsFixed(1)}%)',
          );
          lastLog = now;
        }

        onProgress(
          totalBytes > 0 ? received / totalBytes : 0,
          received,
          totalBytes,
        );
      }
      debugPrint(
        '[YOUTUBE_DL] Stream completed - $chunkCount chunks, $received bytes total (${stopwatch.elapsedMilliseconds}ms)',
      );
      await sink.flush();
      await sink.close();
      debugPrint('[YOUTUBE_DL] File saved successfully');
    } catch (e, stackTrace) {
      debugPrint('[YOUTUBE_DL] ERROR during download: $e');
      debugPrint('[YOUTUBE_DL] Stack trace: $stackTrace');
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  // ─── Generic HTTP download (Instagram, TikTok via yt-dlp API, etc.) ────────

  static Future<VideoInfo> fetchGenericInfo(String url) async {
    // Use a free oembed/info endpoint or just return basic info
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

  // ─── Generic Social Media (direct_link) ─────────────────────────────────

  static final _directLink = DirectLink();

  /// Extracts the best download URL using the direct_link package.
  /// Works for Instagram, TikTok, Twitter/X, Facebook, Reddit, Vimeo, etc.
  static Future<SocialMediaInfo?> resolveSocialUrl(String url) async {
    try {
      final data = await _directLink.check(url);
      if (data == null || data.links == null || data.links!.isEmpty) {
        return null;
      }

      // Prefer video links, then any link
      final videoLinks = data.links!
          .where((l) => l.type?.toLowerCase().contains('video') == true ||
              l.quality.isNotEmpty)
          .toList();

      final bestLink = videoLinks.isNotEmpty ? videoLinks.first : data.links!.first;
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
  }) async {
    // Always download the raw stream as .mp4 (the actual container from the CDN).
    // If audio-only is requested, FFmpeg will extract and re-encode to real MP3.
    final tempFileName =
        '${_sanitizeFilename(title)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final tempFilePath = '$savePath/$tempFileName';

    await _dio.download(
      directUrl,
      tempFilePath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          onProgress(received / total, received, total);
        } else {
          onProgress(0, received, 0);
        }
      },
      options: Options(
        receiveTimeout: const Duration(minutes: 30),
        headers: {
          'Referer': directUrl,
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',
        },
      ),
    );

    // Convert to real MP3 if requested; otherwise keep the .mp4 as-is.
    final outputPath = audioOnly
        ? await _convertToMp3(tempFilePath)
        : tempFilePath;

    // Notify Android MediaStore so the file appears in Files/Music app.
    await scanFileToGallery(outputPath);

    return outputPath;
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  /// Converts any audio/video file at [inputPath] to a real MP3 using FFmpeg
  /// (lame encoder, 192 kbps, 44100 Hz, stereo).
  /// Deletes the intermediate [inputPath] file on success.
  /// Returns the path of the resulting .mp3 file.
  static Future<String> _convertToMp3(String inputPath) async {
    final outputPath = inputPath.replaceAll(RegExp(r'\.[^.]+$'), '.mp3');
    debugPrint('[FFmpeg] Converting "$inputPath" → "$outputPath"');

    final session = await FFmpegKit.execute(
      '-y -i "$inputPath" -vn -ar 44100 -ac 2 -b:a 192k "$outputPath"',
    );

    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getOutput();
      debugPrint('[FFmpeg] Conversion failed: $logs');
      throw Exception('Audio conversion to MP3 failed. Please try again.');
    }

    debugPrint('[FFmpeg] Conversion successful');

    // Remove the intermediate downloaded file.
    try {
      final tmp = File(inputPath);
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}

    return outputPath;
  }

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

  static bool _isMp3AudioStream(yt.StreamInfo streamInfo) {
    final container = streamInfo.container.name.toLowerCase();
    if (container == 'mp3') return true;

    final url = streamInfo.url.toString().toLowerCase();
    return url.contains('.mp3') || url.contains('mime=audio%2Fmpeg');
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
