import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_item.dart';

class SettingsProvider extends ChangeNotifier {
  static const _keyDownloadPath = 'download_path';
  static const _keyDefaultQuality = 'default_quality';
  static const _keyConcurrentDownloads = 'concurrent_downloads';

  String _downloadPath = '';
  VideoQuality _defaultQuality = VideoQuality.best;
  int _concurrentDownloads = 2;

  String get downloadPath => _downloadPath;
  VideoQuality get defaultQuality => _defaultQuality;
  int get concurrentDownloads => _concurrentDownloads;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _downloadPath = prefs.getString(_keyDownloadPath) ?? '';
    final qIndex = prefs.getInt(_keyDefaultQuality) ?? 0;
    _defaultQuality = VideoQuality.values[qIndex.clamp(0, VideoQuality.values.length - 1)];
    _concurrentDownloads = prefs.getInt(_keyConcurrentDownloads) ?? 2;
    notifyListeners();
  }

  Future<void> setDownloadPath(String path) async {
    _downloadPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDownloadPath, path);
    notifyListeners();
  }

  Future<void> setDefaultQuality(VideoQuality q) async {
    _defaultQuality = q;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyDefaultQuality, q.index);
    notifyListeners();
  }

  Future<void> setConcurrentDownloads(int count) async {
    _concurrentDownloads = count.clamp(1, 5);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyConcurrentDownloads, _concurrentDownloads);
    notifyListeners();
  }
}
