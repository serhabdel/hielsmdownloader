import 'package:flutter/material.dart';

enum DownloadStatus {
  queued,
  fetchingInfo,
  downloading,
  converting,
  completed,
  failed,
  cancelled,
}

enum VideoQuality {
  best,    // highest available
  hd1080,
  hd720,
  sd480,
  sd360,
  audioOnly,
}

enum SupportedPlatform {
  youtube,
  instagram,
  tiktok,
  twitter,
  facebook,
  reddit,
  pinterest,
  vimeo,
  generic,
}

class DownloadItem {
  final String id;
  final String url;
  String title;
  String? thumbnailUrl;
  String? duration;
  String? author;
  SupportedPlatform platform;
  DownloadStatus status;
  double progress; // 0.0 - 1.0
  String? filePath;
  String? errorMessage;
  VideoQuality quality;
  int? fileSizeBytes;
  int? downloadedBytes;
  DateTime createdAt;

  DownloadItem({
    required this.id,
    required this.url,
    this.title = 'Fetching info...',
    this.thumbnailUrl,
    this.duration,
    this.author,
    this.platform = SupportedPlatform.generic,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.filePath,
    this.errorMessage,
    this.quality = VideoQuality.best,
    this.fileSizeBytes,
    this.downloadedBytes,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'thumbnailUrl': thumbnailUrl,
        'duration': duration,
        'author': author,
        'platform': platform.name,
        'status': status.name,
        'progress': progress,
        'filePath': filePath,
        'errorMessage': errorMessage,
        'quality': quality.name,
        'fileSizeBytes': fileSizeBytes,
        'downloadedBytes': downloadedBytes,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    DownloadStatus parsedStatus;
    try {
      parsedStatus = DownloadStatus.values.byName(json['status'] as String);
    } catch (_) {
      parsedStatus = DownloadStatus.failed;
    }
    // Mark in-progress items as failed since they were interrupted
    if (parsedStatus == DownloadStatus.downloading ||
        parsedStatus == DownloadStatus.fetchingInfo ||
        parsedStatus == DownloadStatus.converting ||
        parsedStatus == DownloadStatus.queued) {
      parsedStatus = DownloadStatus.failed;
    }

    SupportedPlatform parsedPlatform;
    try {
      parsedPlatform =
          SupportedPlatform.values.byName(json['platform'] as String);
    } catch (_) {
      parsedPlatform = SupportedPlatform.generic;
    }

    VideoQuality parsedQuality;
    try {
      parsedQuality = VideoQuality.values.byName(json['quality'] as String);
    } catch (_) {
      parsedQuality = VideoQuality.best;
    }

    return DownloadItem(
      id: json['id'] as String,
      url: json['url'] as String,
      title: json['title'] as String? ?? 'Unknown',
      thumbnailUrl: json['thumbnailUrl'] as String?,
      duration: json['duration'] as String?,
      author: json['author'] as String?,
      platform: parsedPlatform,
      status: parsedStatus,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      filePath: json['filePath'] as String?,
      errorMessage: parsedStatus == DownloadStatus.failed &&
              (json['errorMessage'] as String?) == null
          ? 'Interrupted — please retry'
          : json['errorMessage'] as String?,
      quality: parsedQuality,
      fileSizeBytes: json['fileSizeBytes'] as int?,
      downloadedBytes: json['downloadedBytes'] as int?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  DownloadItem copyWith({
    String? title,
    String? thumbnailUrl,
    String? duration,
    String? author,
    SupportedPlatform? platform,
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? errorMessage,
    VideoQuality? quality,
    int? fileSizeBytes,
    int? downloadedBytes,
  }) {
    return DownloadItem(
      id: id,
      url: url,
      title: title ?? this.title,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      author: author ?? this.author,
      platform: platform ?? this.platform,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      errorMessage: errorMessage ?? this.errorMessage,
      quality: quality ?? this.quality,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      createdAt: createdAt,
    );
  }
}

extension DownloadStatusX on DownloadStatus {
  String get label {
    switch (this) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.fetchingInfo:
        return 'Fetching info';
      case DownloadStatus.downloading:
        return 'Downloading';
      case DownloadStatus.converting:
        return 'Converting to MP3';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }

  bool get isActive =>
      this == DownloadStatus.queued ||
      this == DownloadStatus.fetchingInfo ||
      this == DownloadStatus.downloading ||
      this == DownloadStatus.converting;

  Color get color {
    switch (this) {
      case DownloadStatus.queued:
        return const Color(0xFF9E9E9E);
      case DownloadStatus.fetchingInfo:
        return const Color(0xFF42A5F5);
      case DownloadStatus.downloading:
        return const Color(0xFF6C63FF);
      case DownloadStatus.converting:
        return const Color(0xFF03DAC6);
      case DownloadStatus.completed:
        return const Color(0xFF4CAF50);
      case DownloadStatus.failed:
        return const Color(0xFFCF6679);
      case DownloadStatus.cancelled:
        return const Color(0xFF9E9E9E);
    }
  }
}

extension SupportedPlatformX on SupportedPlatform {
  String get displayName {
    switch (this) {
      case SupportedPlatform.youtube:
        return 'YouTube';
      case SupportedPlatform.instagram:
        return 'Instagram';
      case SupportedPlatform.tiktok:
        return 'TikTok';
      case SupportedPlatform.twitter:
        return 'Twitter/X';
      case SupportedPlatform.facebook:
        return 'Facebook';
      case SupportedPlatform.reddit:
        return 'Reddit';
      case SupportedPlatform.pinterest:
        return 'Pinterest';
      case SupportedPlatform.vimeo:
        return 'Vimeo';
      case SupportedPlatform.generic:
        return 'Video';
    }
  }

  Color get color {
    switch (this) {
      case SupportedPlatform.youtube:
        return const Color(0xFFFF0000);
      case SupportedPlatform.instagram:
        return const Color(0xFFE1306C);
      case SupportedPlatform.tiktok:
        return const Color(0xFF69C9D0);
      case SupportedPlatform.twitter:
        return const Color(0xFF1DA1F2);
      case SupportedPlatform.facebook:
        return const Color(0xFF1877F2);
      case SupportedPlatform.reddit:
        return const Color(0xFFFF4500);
      case SupportedPlatform.pinterest:
        return const Color(0xFFE60023);
      case SupportedPlatform.vimeo:
        return const Color(0xFF1AB7EA);
      case SupportedPlatform.generic:
        return const Color(0xFF6C63FF);
    }
  }

  IconData get icon {
    switch (this) {
      case SupportedPlatform.youtube:
        return Icons.play_circle_filled;
      case SupportedPlatform.instagram:
        return Icons.camera_alt;
      case SupportedPlatform.tiktok:
        return Icons.music_note;
      case SupportedPlatform.twitter:
        return Icons.flutter_dash;
      case SupportedPlatform.facebook:
        return Icons.facebook;
      case SupportedPlatform.reddit:
        return Icons.reddit;
      case SupportedPlatform.pinterest:
        return Icons.push_pin;
      case SupportedPlatform.vimeo:
        return Icons.videocam;
      case SupportedPlatform.generic:
        return Icons.video_file;
    }
  }
}

extension VideoQualityX on VideoQuality {
  String get label {
    switch (this) {
      case VideoQuality.best:
        return 'Best Quality';
      case VideoQuality.hd1080:
        return '1080p HD';
      case VideoQuality.hd720:
        return '720p HD';
      case VideoQuality.sd480:
        return '480p';
      case VideoQuality.sd360:
        return '360p';
      case VideoQuality.audioOnly:
        return 'Audio Only (MP3)';
    }
  }
}
