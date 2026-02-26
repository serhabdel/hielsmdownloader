import 'dart:io';
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
    final video = await _yt.videos.get(url);
    final manifest = await _yt.videos.streams.getManifest(url);

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
      streams.add(StreamOption(
        label: 'Audio Only (${best.container.name})',
        quality: VideoQuality.audioOnly,
        bitrate: best.bitrate.bitsPerSecond,
        container: best.container.name,
        isAudioOnly: true,
        streamInfo: best,
      ));
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
    CancelToken? cancelToken,
  }) async {
    final manifest = await _yt.videos.streams.getManifest(url);
    final video = await _yt.videos.get(url);

    yt.StreamInfo streamInfo;

    if (quality == VideoQuality.audioOnly) {
      streamInfo = manifest.audioOnly.withHighestBitrate();
    } else {
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

    final ext = streamInfo.container.name;
    final title = _sanitizeFilename(video.title);
    final fileName = '${title}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final filePath = '$savePath/$fileName';

    final stream = _yt.videos.streams.get(streamInfo);
    final file = File(filePath);
    final sink = file.openWrite();

    final totalBytes = streamInfo.size.totalBytes;
    int received = 0;

    await for (final chunk in stream) {
      if (cancelToken?.isCancelled == true) {
        await sink.close();
        await file.delete();
        throw Exception('Download cancelled');
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress(
        totalBytes > 0 ? received / totalBytes : 0,
        received,
        totalBytes,
      );
    }

    await sink.flush();
    await sink.close();

    // Notify Android MediaStore so the file appears in Gallery
    await scanFileToGallery(filePath);

    return filePath;
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
    // For social platforms we get a raw video stream — we save as-is.
    // Audio-only mode saves the same stream but as .mp3 (best-effort;
    // most platforms serve AAC/MP4 audio streams for reels/shorts).
    final ext = audioOnly ? 'mp3' : 'mp4';
    final fileName =
        '${_sanitizeFilename(title)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final filePath = '$savePath/$fileName';

    await _dio.download(
      directUrl,
      filePath,
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

    // Notify Android MediaStore so the file appears in Gallery
    await scanFileToGallery(filePath);

    return filePath;
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
