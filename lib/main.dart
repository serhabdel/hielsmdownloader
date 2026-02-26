import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'providers/download_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';
import 'services/foreground_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Transparent status bar
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Load settings
  final settings = SettingsProvider();
  await settings.load();

  // Init background services
  ForegroundService.init();
  await NotificationService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProxyProvider<SettingsProvider, DownloadProvider>(
          create: (ctx) {
            final provider = DownloadProvider();
            provider.init(ctx.read<SettingsProvider>());
            return provider;
          },
          update: (ctx, settings, previous) {
            previous?.init(settings);
            return previous ?? DownloadProvider();
          },
        ),
      ],
      child: const ReelsDownloaderApp(),
    ),
  );
}

class ReelsDownloaderApp extends StatefulWidget {
  const ReelsDownloaderApp({super.key});

  @override
  State<ReelsDownloaderApp> createState() => _ReelsDownloaderAppState();
}

class _ReelsDownloaderAppState extends State<ReelsDownloaderApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissions();
    });
  }

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;

    // Android 11+ (API 30+): request MANAGE_EXTERNAL_STORAGE so we can
    // write directly to /storage/emulated/0/Download/ReelsDownloader
    final manageStatus = await Permission.manageExternalStorage.status;
    if (!manageStatus.isGranted) {
      await Permission.manageExternalStorage.request();
    }

    // Android 10 and below: legacy WRITE_EXTERNAL_STORAGE
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }

    // Android 13+ (API 33+): granular media permissions
    if (await Permission.videos.isDenied) {
      await Permission.videos.request();
    }

    // Notification permission for download progress (Android 13+)
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  @override
  Widget build(BuildContext context) {
    // WithForegroundTask binds the Flutter engine to the foreground service
    // lifecycle, preventing Android from killing the isolate mid-download.
    return WithForegroundTask(
      child: MaterialApp(
        title: 'HieL SmD',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
