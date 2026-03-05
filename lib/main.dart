import 'dart:async';
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
  // Global Flutter framework error handler (catches widget build errors etc.)
  // Must be set before ensureInitialized so it covers the init phase too.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[FLUTTER_ERROR] ${details.exceptionAsString()}');
  };

  // runZonedGuarded catches unhandled async errors that escape the framework.
  // ensureInitialized must be called INSIDE this zone so that runApp (which
  // is also inside this zone) doesn't trigger a "zone mismatch" assertion.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final startupStopwatch = Stopwatch()..start();
      debugPrint('[STARTUP] main() started');

      // Lock to portrait
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      debugPrint('[STARTUP] setPreferredOrientations: ${startupStopwatch.elapsedMilliseconds}ms');

      // Transparent status bar
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: AppTheme.surface,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );
      debugPrint('[STARTUP] setSystemUIOverlayStyle: ${startupStopwatch.elapsedMilliseconds}ms');

      // Load settings
      final settings = SettingsProvider();
      await settings.load();
      debugPrint('[STARTUP] settings.load(): ${startupStopwatch.elapsedMilliseconds}ms');

      // Init background services
      ForegroundService.init();
      debugPrint('[STARTUP] ForegroundService.init(): ${startupStopwatch.elapsedMilliseconds}ms');

      await NotificationService.init();
      debugPrint('[STARTUP] NotificationService.init(): ${startupStopwatch.elapsedMilliseconds}ms');

      debugPrint('[STARTUP] Total before runApp: ${startupStopwatch.elapsedMilliseconds}ms');
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
          child: const HielSmdApp(),
        ),
      );
    },
    (error, stack) {
      debugPrint('[ZONE_ERROR] $error\n$stack');
    },
  );
}

class HielSmdApp extends StatefulWidget {
  const HielSmdApp({super.key});

  @override
  State<HielSmdApp> createState() => _HielSmdAppState();
}

class _HielSmdAppState extends State<HielSmdApp> {
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
    // write directly to /storage/emulated/0/Download/HieLSmD
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
