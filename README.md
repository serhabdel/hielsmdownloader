# HieL SmD

> Social media video downloader for Android. No ads, no account required.

[![Release](https://img.shields.io/github/v/release/serhabdel/hielsmdownloader?style=flat-square)](https://github.com/serhabdel/hielsmdownloader/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-54C5F8?style=flat-square)](https://flutter.dev)

---

## Features

- **Share-to-download** — share any link from Instagram, TikTok, YouTube, Twitter/X, Facebook, Reddit, Pinterest, or Vimeo directly to this app
- **Auto-detection** — platform and quality detected automatically
- **Quality selector** — Best / 1080p / 720p / 480p / 360p / Audio Only
- **Background downloads** — foreground service keeps downloads alive when the app is minimised
- **Progress notifications** — per-download Android notifications with progress bar
- **Share & open** — share downloaded files to any app or open them directly
- **No ads, no login, no tracking**

## Supported Platforms

| Platform | Video | Audio |
|---|---|---|
| YouTube | ✓ | ✓ (Audio Only) |
| Instagram | ✓ | — |
| TikTok | ✓ | — |
| Twitter / X | ✓ | — |
| Facebook | ✓ | — |
| Reddit | ✓ | — |
| Pinterest | ✓ | — |
| Vimeo | ✓ | — |

## Download

Get the latest APK from [Releases](https://github.com/serhabdel/hielsmdownloader/releases/latest).

## Build

```bash
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

Output:

- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` → v8 (most modern devices)
- `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk` → v7 (older 32-bit devices)

## License

[MIT](LICENSE) © [serhabdel](https://github.com/serhabdel)
