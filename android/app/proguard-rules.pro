# ── Mozilla Rhino (JavaScript engine used by NewPipe Extractor) ───────────────
# Rhino uses reflection and dynamic class loading internally; stripping any of
# these classes causes NoClassDefFoundError / ClassCastException at runtime.
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.** { *; }
-dontwarn org.mozilla.javascript.**
-dontwarn org.mozilla.classfile.**

# ── NewPipe Extractor ─────────────────────────────────────────────────────────
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

# ── OkHttp / Okio ────────────────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ── jsoup optional re2j dependency (not bundled, safe to ignore) ──────────────
-dontwarn com.google.re2j.Matcher
-dontwarn com.google.re2j.Pattern

# ── Kotlin coroutines (used transitively) ────────────────────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# ── General Android / Flutter safety rules ───────────────────────────────────
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
