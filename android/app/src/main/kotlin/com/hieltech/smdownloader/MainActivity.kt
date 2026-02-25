package com.hieltech.smdownloader

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.hieltech.smdownloader/media_scanner"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARG", "path is required", null)
                        return@setMethodCallHandler
                    }
                    MediaScannerConnection.scanFile(
                        applicationContext,
                        arrayOf(path),
                        null,
                    ) { _, uri ->
                        // Callback runs on a background thread – result must be
                        // delivered on the platform thread, but MethodChannel
                        // handles that internally on recent Flutter versions.
                        runOnUiThread {
                            result.success(uri?.toString())
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
