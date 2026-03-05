import 'package:flutter_test/flutter_test.dart';
import 'package:hielsmdownloader/services/download_service.dart';
import 'package:hielsmdownloader/models/download_item.dart';

void main() {
  group('detectPlatform', () {
    test('detects YouTube URLs', () {
      expect(detectPlatform('https://www.youtube.com/watch?v=abc123'),
          SupportedPlatform.youtube);
      expect(detectPlatform('https://youtu.be/abc123'),
          SupportedPlatform.youtube);
      expect(detectPlatform('https://youtube.com/shorts/abc123'),
          SupportedPlatform.youtube);
    });

    test('detects Instagram URLs', () {
      expect(detectPlatform('https://www.instagram.com/reel/abc123'),
          SupportedPlatform.instagram);
    });

    test('detects TikTok URLs', () {
      expect(detectPlatform('https://www.tiktok.com/@user/video/123'),
          SupportedPlatform.tiktok);
    });

    test('detects Twitter/X URLs', () {
      expect(detectPlatform('https://twitter.com/user/status/123'),
          SupportedPlatform.twitter);
      expect(detectPlatform('https://x.com/user/status/123'),
          SupportedPlatform.twitter);
    });

    test('detects Facebook URLs', () {
      expect(detectPlatform('https://www.facebook.com/video/123'),
          SupportedPlatform.facebook);
      expect(detectPlatform('https://fb.watch/abc'),
          SupportedPlatform.facebook);
    });

    test('detects Reddit URLs', () {
      expect(detectPlatform('https://www.reddit.com/r/sub/comments/abc'),
          SupportedPlatform.reddit);
      expect(
          detectPlatform('https://redd.it/abc'), SupportedPlatform.reddit);
    });

    test('detects Pinterest URLs', () {
      expect(detectPlatform('https://www.pinterest.com/pin/123'),
          SupportedPlatform.pinterest);
      expect(detectPlatform('https://pin.it/abc'), SupportedPlatform.pinterest);
    });

    test('detects Vimeo URLs', () {
      expect(detectPlatform('https://vimeo.com/123456'),
          SupportedPlatform.vimeo);
    });

    test('falls back to generic for unknown URLs', () {
      expect(detectPlatform('https://example.com/video.mp4'),
          SupportedPlatform.generic);
    });
  });

  group('isValidUrl', () {
    test('accepts valid http/https URLs', () {
      expect(isValidUrl('https://www.youtube.com/watch?v=abc'), isTrue);
      expect(isValidUrl('http://example.com'), isTrue);
    });

    test('rejects invalid URLs', () {
      expect(isValidUrl('not-a-url'), isFalse);
      expect(isValidUrl('ftp://example.com'), isFalse);
      expect(isValidUrl(''), isFalse);
    });

    test('handles URLs with whitespace', () {
      expect(isValidUrl('  https://youtu.be/abc  '), isTrue);
    });
  });
}
