package app.airwave.android

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

// The web bundle is the only document permitted to call the native bridge.
// Provider credentials stay in the native catalog; JavaScript receives opaque media IDs.
class MainActivity : ComponentActivity() {
    private lateinit var web: WebView
    private lateinit var playback: Playback
    private val catalog by lazy { Catalog(CatalogStore(this)) }
    private val artwork by lazy { Artwork(cacheDir.resolve("artwork")) { id -> catalog.logo(id) } }
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private var importID: String? = null
    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> imported(uri) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = false
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        // The library sits inside the system bars and above the keyboard; video uses the whole screen.
        val content = FrameLayout(this)
        ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        web = WebView(this)
        content.addView(web, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        root.addView(content, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        playback = Playback(this, root, ::emit) { covered ->
            // While video covers the library, the remote must not move focus around the hidden page.
            web.descendantFocusability = if (covered) ViewGroup.FOCUS_BLOCK_DESCENDANTS else ViewGroup.FOCUS_AFTER_DESCENDANTS
            web.isFocusable = !covered
            if (!covered) web.requestFocus()
        }
        setContentView(root)
        configureWeb()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // Back leaves native video first; otherwise the web interface takes it like Escape.
                if (playback.active) playback.stop()
                else web.evaluateJavascript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))", null)
            }
        })
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWeb() {
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        web.setBackgroundColor(Color.BLACK)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            // Playlist logos and guide images are often plain HTTP; scripts and frames still need HTTPS.
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        }
        val loader = WebViewAssetLoader.Builder()
            .setDomain(Artwork.HOST)
            .addPathHandler("/app/") { path -> bundled(path) }
            .addPathHandler("/art/", artwork)
            .build()
        web.webViewClient = object : WebViewClientCompat() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? = loader.shouldInterceptRequest(request.url)
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = request.url.host != Artwork.HOST
        }
        // Native playback covers the web player; WebView would otherwise draw its grey placeholder behind an error.
        web.webChromeClient = object : WebChromeClient() {
            override fun getDefaultVideoPoster(): Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            web.loadData("<body style='background:#000;color:#fff;font-family:sans-serif;padding:2em'>Airwave needs a newer Android System WebView. Update it from the Play Store, then open Airwave again.</body>", "text/html", "utf-8")
            return
        }
        WebViewCompat.addWebMessageListener(web, "AirwaveAndroid", setOf("https://" + Artwork.HOST)) { _, message, origin, isMainFrame, _ ->
            if (isMainFrame && origin.host == Artwork.HOST) message.data?.let(::handle)
        }
        web.loadUrl("https://" + Artwork.HOST + "/app/index.html")
    }

    private fun bundled(path: String): WebResourceResponse? {
        if (path.split('/').any { it == ".." }) return null
        val type = when (path.substringAfterLast('.', "")) {
            "html" -> "text/html"; "css" -> "text/css"; "js" -> "text/javascript"; "svg" -> "image/svg+xml"
            "png" -> "image/png"; "xml" -> "application/xml"; else -> "text/plain"
        }
        return try { WebResourceResponse(type, if (type.startsWith("image/png")) null else "utf-8", assets.open("app/$path")) } catch (error: IOException) { null }
    }

    private fun handle(raw: String) {
        val body = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val id = body.optString("id").ifEmpty { return }
        val payload = body.optJSONObject("payload") ?: JSONObject()
        when (body.optString("action")) {
            "library" -> io.execute {
                val result = runCatching { catalog.open() }
                main.post { result.fold({ reply(id, it) }, { reply(id, error = "The encrypted library could not be opened. Import it again from Settings.") }) }
            }
            "importLibrary" -> {
                val types = arrayOf("application/json", "text/plain", "application/octet-stream")
                if (!hasPicker(types)) return reply(id, error = NO_PICKER)
                importID?.let { reply(it, error = "Import cancelled.") }
                importID = id
                try { picker.launch(types) } catch (error: ActivityNotFoundException) { importID = null; reply(id, error = NO_PICKER) }
            }
            "play" -> {
                val key = payload.optString("id").ifEmpty { return reply(id, error = "Missing media identifier.") }
                val url = catalog.url(key) ?: payload.optString("url")
                if (!Net.isHttp(url)) return reply(id, error = "Unsupported media URL.")
                val kind = catalog.kind(key) ?: payload.optString("kind")
                playback.start(PlayRequest(key, url, kind == "live", payload.optDouble("resume", 0.0).takeIf { it.isFinite() } ?: 0.0,
                    payload.optInt("token"), payload.optString("title").ifEmpty { "Airwave" }, payload.optBoolean("favorite")))
                reply(id, true)
            }
            "stop" -> { playback.stop(); reply(id, true) }
            "toggle" -> { playback.toggle(); reply(id, true) }
            "seek" -> { playback.seek(payload.optDouble("delta", 0.0)); reply(id, true) }
            "clearArtwork" -> { io.execute { artwork.clear() }; reply(id, true) }
            "exit" -> { reply(id, true); finish() }
            "fetchText" -> {
                val url = payload.optString("url")
                if (!Net.isHttp(url)) return reply(id, error = "Unsupported source URL.")
                val max = payload.optInt("max", 5_242_880).coerceIn(1, 10_485_760)
                io.execute {
                    val text = runCatching { String(Net.get(url, max, 20_000), Charsets.UTF_8) }
                    main.post { text.fold({ reply(id, it) }, { reply(id, error = "The source could not be loaded. Check the URL, connection, and file size.") }) }
                }
            }
            else -> reply(id, error = "Unsupported native action.")
        }
    }

    // Android TV images answer the document picker with a stub that closes at once.
    private fun hasPicker(types: Array<String>): Boolean {
        val target = ActivityResultContracts.OpenDocument().createIntent(this, types).resolveActivity(packageManager) ?: return false
        return target.packageName != "com.android.tv.frameworkpackagestubs"
    }

    private fun imported(uri: Uri?) {
        val id = importID ?: return
        importID = null
        if (uri == null) return reply(id, error = "Import cancelled.")
        io.execute {
            val result = runCatching {
                val data = contentResolver.openInputStream(uri)?.use { input ->
                    val out = ByteArrayOutputStream(); val buffer = ByteArray(256 * 1024)
                    while (true) { val read = input.read(buffer); if (read < 0) break; if (out.size() + read > 100_000_000) throw IOException("Too large"); out.write(buffer, 0, read) }
                    out.toByteArray()
                } ?: throw IOException("Unreadable")
                catalog.import(data)
            }
            main.post { result.fold({ reply(id, it) }, { reply(id, error = "This library could not be imported or securely saved. Choose a valid Airwave library JSON file.") }) }
        }
    }

    private fun reply(id: String, result: Any? = null, error: String? = null) {
        val args = JSONArray().put(id).put(result ?: JSONObject.NULL).put(error ?: JSONObject.NULL)
        web.evaluateJavascript("window.__airwaveNativeReply.apply(null,$args)", null)
    }

    private fun emit(event: String, value: Any?, token: Int) {
        val args = JSONArray().put(event).put(value ?: JSONObject.NULL).put(token)
        web.evaluateJavascript("window.__airwaveNativePlayback&&window.__airwaveNativePlayback.apply(null,$args)", null)
    }

    private companion object {
        const val NO_PICKER = "This device has no file picker, so a library file can't be chosen here. Add a playlist by URL instead."
    }

    // Like the Apple app, playback stops when Airwave leaves the screen.
    override fun onStop() {
        super.onStop()
        if (playback.active) playback.stop()
    }

    override fun onDestroy() {
        playback.stop(notify = false)
        io.shutdown()
        web.destroy()
        super.onDestroy()
    }
}
