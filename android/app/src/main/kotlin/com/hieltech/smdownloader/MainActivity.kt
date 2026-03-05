package com.hieltech.smdownloader

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request as NpRequest
import org.schabi.newpipe.extractor.downloader.Response as NpResponse
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamExtractor
import org.schabi.newpipe.extractor.exceptions.ExtractionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

// ─── OkHttp-backed Downloader for NewPipe Extractor ──────────────────────────

class OkHttpDownloader private constructor(private val client: OkHttpClient) : Downloader() {

    companion object {
        // Must match the official NewPipe DownloaderImpl User-Agent exactly.
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

        @Volatile private var instance: OkHttpDownloader? = null

        fun getInstance(): OkHttpDownloader = instance ?: synchronized(this) {
            instance ?: OkHttpDownloader(
                OkHttpClient.Builder()
                    .connectTimeout(30, TimeUnit.SECONDS)
                    .readTimeout(30, TimeUnit.SECONDS)
                    .writeTimeout(30, TimeUnit.SECONDS)
                    .followRedirects(true)
                    .build()
            ).also { instance = it }
        }
    }

    override fun execute(request: NpRequest): NpResponse {
        val httpMethod = request.httpMethod()
        val url       = request.url()
        val headers   = request.headers()
        val body      = request.dataToSend()

        val requestBuilder = Request.Builder()
            .url(url)
            // Match the exact User-Agent that the official NewPipe app uses.
            // YouTube's InnerTube API returns different (sometimes broken) responses
            // for unrecognized or missing User-Agents.
            .addHeader("User-Agent", USER_AGENT)

        // Merge headers from NewPipe Extractor's Request.
        // Remove-then-add avoids duplicates and lets the Extractor override
        // the default User-Agent when it needs to (e.g. for Android client).
        headers.forEach { (key, values) ->
            requestBuilder.removeHeader(key)
            values.forEach { value -> requestBuilder.addHeader(key, value) }
        }

        // Set method + body
        val okBody = if (body != null && body.isNotEmpty()) {
            val contentType = headers["Content-Type"]?.firstOrNull()
                ?: "application/x-www-form-urlencoded"
            body.toRequestBody(contentType.toMediaTypeOrNull())
        } else null

        when (httpMethod.uppercase()) {
            "GET"  -> requestBuilder.get()
            "POST" -> requestBuilder.post(okBody ?: ByteArray(0).toRequestBody(null))
            "HEAD" -> requestBuilder.head()
            else   -> requestBuilder.method(httpMethod, okBody)
        }

        val response = client.newCall(requestBuilder.build()).execute()

        val responseHeaders = mutableMapOf<String, MutableList<String>>()
        response.headers.forEach { (key, value) ->
            responseHeaders.getOrPut(key) { mutableListOf() }.add(value)
        }

        val responseBody = response.body?.string() ?: ""
        val statusCode   = response.code
        val statusMsg    = response.message
        val latestUrl    = response.request.url.toString()

        return NpResponse(statusCode, statusMsg, responseHeaders, responseBody, latestUrl)
    }
}

// ─── MainActivity ─────────────────────────────────────────────────────────────

class MainActivity : FlutterActivity() {
    companion object {
        private const val MEDIA_SCANNER_CHANNEL = "com.hieltech.smdownloader/media_scanner"
        private const val YOUTUBE_AUDIO_CHANNEL  = "com.hieltech.smdownloader/youtube_audio"

        // Single-thread executor so NewPipe calls never block the UI thread
        private val bgExecutor = Executors.newCachedThreadPool()

        @Volatile private var newPipeInitialized = false

        private fun ensureNewPipeInitialized() {
            if (newPipeInitialized) return
            synchronized(this) {
                if (!newPipeInitialized) {
                    NewPipe.init(OkHttpDownloader.getInstance())
                    newPipeInitialized = true
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupMediaScannerChannel(flutterEngine)
        setupYoutubeAudioChannel(flutterEngine)
    }

    // ── Media Scanner channel (unchanged) ────────────────────────────────────

    private fun setupMediaScannerChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_SCANNER_CHANNEL,
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
                        runOnUiThread { result.success(uri?.toString()) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── YouTube Audio channel ─────────────────────────────────────────────────
    //
    // Method: getAudioStreamUrl(url: String) -> Map<String, Any?>
    //   Returns: { "streamUrl": String, "title": String, "mimeType": String,
    //              "bitrate": Int, "itag": Int }
    //   On failure throws: PlatformException with code "EXTRACTION_FAILED"

    private fun setupYoutubeAudioChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            YOUTUBE_AUDIO_CHANNEL,
        )

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioStreamUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("INVALID_ARG", "url is required", null)
                        return@setMethodCallHandler
                    }

                    bgExecutor.execute {
                        try {
                            val info = extractAudioStreamUrl(url)
                            runOnUiThread { result.success(info) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "EXTRACTION_FAILED",
                                    e.message ?: "Unknown extraction error",
                                    e.javaClass.simpleName,
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Uses NewPipe Extractor to fetch a properly deobfuscated audio stream URL.
     * NewPipe runs Mozilla Rhino to execute YouTube's obfuscated JavaScript and
     * compute the correct `n` parameter value, which is what prevents 403s.
     *
     * Only PROGRESSIVE_HTTP streams are returned — DASH/HLS manifests cannot be
     * directly downloaded by Dio and would cause silent failures or corrupt files.
     *
     * Must be called on a background thread (blocking network I/O).
     */
    private fun extractAudioStreamUrl(videoUrl: String): Map<String, Any?> {
        // Re-initialize NewPipe on extraction failures (stale extractor state).
        // We try twice: once with cached init, once after a forced re-init.
        var lastError: Exception? = null
        for (attempt in 0..1) {
            try {
                if (attempt == 1) {
                    // Force re-init to flush any stale JavaScript cache
                    android.util.Log.w("NewPipe", "Re-initializing NewPipe after attempt 0 failure")
                    synchronized(Companion) {
                        newPipeInitialized = false
                    }
                }
                ensureNewPipeInitialized()
                return doExtractAudioStreamUrl(videoUrl)
            } catch (e: ExtractionException) {
                lastError = e
                android.util.Log.e("NewPipe", "Extraction attempt $attempt failed: ${e.message}", e)
            } catch (e: Exception) {
                lastError = e
                android.util.Log.e("NewPipe", "Attempt $attempt failed: ${e.message}", e)
                // Always retry once — NPE, MalformedURL, 403, sign errors, etc.
                if (attempt == 0) continue
                throw e
            }
        }
        throw lastError ?: Exception("Audio extraction failed after 2 attempts.")
    }

    /**
     * Inner extraction logic. Separated so the retry wrapper above can re-call it
     * cleanly after a forced NewPipe re-initialization.
     */
    private fun doExtractAudioStreamUrl(videoUrl: String): Map<String, Any?> {
        val youtubeService = ServiceList.YouTube

        // Normalize short youtu.be URLs to full youtube.com format.
        // NewPipe's link handler can throw NPE on some short-URL variants.
        val normalizedUrl = normalizeYoutubeUrl(videoUrl)
        android.util.Log.d("NewPipe", "Extracting from URL: $normalizedUrl (original: $videoUrl)")
        val linkHandler = youtubeService.getStreamLHFactory().fromUrl(normalizedUrl)
        val extractor: StreamExtractor = youtubeService
            .getStreamExtractor(linkHandler)
            .also { it.fetchPage() }

        val allAudioStreams: List<AudioStream> = extractor.audioStreams

        if (allAudioStreams.isEmpty()) {
            throw ExtractionException("No audio streams found for: $videoUrl")
        }

        // ── Filter to streams with a direct CDN URL ────────────────────────────
        // YouTube labels most audio-only streams as DASH delivery, but they still
        // have perfectly valid direct-download googlevideo.com CDN URLs. Instead of
        // filtering by DeliveryMethod, keep any stream whose `content` is a real
        // URL and reject only actual manifest files (.m3u8 / .mpd).
        val downloadableStreams = allAudioStreams.filter { stream ->
            val url = stream.content
            !url.isNullOrBlank() &&
                !url.contains(".m3u8") &&
                !url.contains(".mpd")
        }

        if (downloadableStreams.isEmpty()) {
            android.util.Log.w(
                "NewPipe",
                "No downloadable audio streams found (total=${allAudioStreams.size}). " +
                "All streams had blank URLs or manifest URLs (.m3u8/.mpd).",
            )
            throw ExtractionException(
                "No direct-download audio streams available for this video. " +
                "All streams are HLS/DASH manifests or have no URL.",
            )
        }

        android.util.Log.d(
            "NewPipe",
            "Found ${downloadableStreams.size} downloadable streams " +
            "(filtered from ${allAudioStreams.size} total).",
        )

        // ── Prefer m4a (AAC) over webm/opus ───────────────────────────────────
        // m4a streams (itag 140 / 141) are more reliably processed by FFmpeg and
        // work with more media players than webm/opus.
        val m4aStreams = downloadableStreams.filter { stream ->
            val mime = stream.getFormat()?.mimeType ?: ""
            mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac")
        }

        val bestStream: AudioStream = if (m4aStreams.isNotEmpty()) {
            m4aStreams.maxByOrNull { it.averageBitrate } ?: m4aStreams.first()
        } else {
            // Falls to opus/webm — still downloadable, worse compatibility
            downloadableStreams.maxByOrNull { it.averageBitrate } ?: downloadableStreams.first()
        }

        val streamUrl = bestStream.content
            ?: throw ExtractionException(
                "NewPipe returned a null content URL for stream: " +
                "delivery=${bestStream.deliveryMethod}, " +
                "format=${bestStream.getFormat()?.mimeType}, " +
                "itag=${bestStream.itag}. " +
                "Video may be restricted or unavailable.",
            )

        // Sanity check: make sure this looks like a direct CDN URL, not a manifest
        if (streamUrl.contains(".m3u8") || streamUrl.contains(".mpd")) {
            throw ExtractionException(
                "NewPipe returned a manifest URL ($streamUrl) instead of a direct " +
                "stream URL despite content-based filtering. Unexpected state.",
            )
        }

        android.util.Log.d(
            "NewPipe",
            "Selected stream — itag=${bestStream.itag}, " +
            "bitrate=${bestStream.averageBitrate}, " +
            "mime=${bestStream.getFormat()?.mimeType}, " +
            "urlLength=${streamUrl.length}",
        )

        return mapOf(
            "streamUrl" to streamUrl,
            "title"     to (extractor.name ?: "YouTube Audio"),
            "mimeType"  to (bestStream.getFormat()?.mimeType ?: "audio/mp4"),
            "bitrate"   to bestStream.averageBitrate,
            "itag"      to bestStream.itag,
        )
    }

    /**
     * Converts youtu.be short URLs and other variants to a canonical
     * `https://www.youtube.com/watch?v=ID` format that NewPipe handles reliably.
     */
    private fun normalizeYoutubeUrl(url: String): String {
        // youtu.be/VIDEO_ID or youtu.be/VIDEO_ID?params
        val shortRegex = Regex("""youtu\.be/([A-Za-z0-9_-]+)""")
        shortRegex.find(url)?.let { match ->
            return "https://www.youtube.com/watch?v=${match.groupValues[1]}"
        }

        // youtube.com/shorts/VIDEO_ID
        val shortsRegex = Regex("""youtube\.com/shorts/([A-Za-z0-9_-]+)""")
        shortsRegex.find(url)?.let { match ->
            return "https://www.youtube.com/watch?v=${match.groupValues[1]}"
        }

        // youtube.com/embed/VIDEO_ID
        val embedRegex = Regex("""youtube\.com/embed/([A-Za-z0-9_-]+)""")
        embedRegex.find(url)?.let { match ->
            return "https://www.youtube.com/watch?v=${match.groupValues[1]}"
        }

        return url
    }
}
