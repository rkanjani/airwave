package app.airwave.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.webkit.WebResourceResponse
import androidx.webkit.WebViewAssetLoader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

// Tile artwork for the web view: /art/logo/<id> on the bundle's own origin resolves to the catalog's image
// in native code (WebView can't load images from a custom scheme). Images are downsampled once and kept in
// the cache folder; failures are remembered for a day. Runs on WebView's request threads.
class Artwork(private val folder: File, private val lookup: (String) -> String?) : WebViewAssetLoader.PathHandler {
    private val locks = ConcurrentHashMap<String, Any>()
    @Volatile private var pruned = false

    override fun handle(path: String): WebResourceResponse? {
        // The loader hands over the already-decoded path.
        val id = path.removePrefix("logo/").takeIf { path.startsWith("logo/") && it.isNotEmpty() } ?: return missing()
        val source = lookup(id) ?: return missing()
        val image = image(id, source) ?: return missing()
        return WebResourceResponse(image.second, null, ByteArrayInputStream(image.first)).apply {
            responseHeaders = mapOf("Cache-Control" to "max-age=86400")
        }
    }

    fun clear() { folder.deleteRecursively() }

    private fun missing() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun image(id: String, source: String): Pair<ByteArray, String>? {
        val name = MessageDigest.getInstance("SHA-256").digest("$id\n$source".toByteArray()).joinToString("") { "%02x".format(it) }
        synchronized(locks.computeIfAbsent(name) { Any() }) {
            try { return load(name, source) } finally { locks.remove(name) }
        }
    }

    private fun load(name: String, source: String): Pair<ByteArray, String>? {
        folder.mkdirs()
        if (!pruned) { pruned = true; prune() }
        val png = File(folder, "$name.png"); val jpg = File(folder, "$name.jpg"); val miss = File(folder, "$name.miss")
        val file = listOf(png, jpg).firstOrNull { it.exists() }
        val saved = file?.let { it.readBytes() to if (it == png) "image/png" else "image/jpeg" }
        if (file != null && age(file) < FRESH) return saved
        if (age(miss) < FAIL_FOR) return saved
        return try {
            val image = downsample(Net.get(source, MAX_SOURCE, 15_000)) ?: throw IllegalStateException("Not an image")
            listOf(png, jpg, miss).forEach { it.delete() }
            (if (image.second == "image/png") png else jpg).writeBytes(image.first)
            image
        } catch (error: Exception) {
            miss.writeBytes(ByteArray(0)); miss.setLastModified(System.currentTimeMillis())
            saved
        }
    }

    private fun age(file: File) = if (file.exists()) System.currentTimeMillis() - file.lastModified() else Long.MAX_VALUE

    // Tiles are at most about 480 px at 2x; logos with transparency stay PNG.
    private fun downsample(data: ByteArray): Pair<ByteArray, String>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= SIZE) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val scale = minOf(1f, SIZE.toFloat() / maxOf(decoded.width, decoded.height))
        val bitmap = if (scale < 1f) Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt().coerceAtLeast(1), (decoded.height * scale).toInt().coerceAtLeast(1), true) else decoded
        val out = ByteArrayOutputStream()
        val alpha = bitmap.hasAlpha()
        bitmap.compress(if (alpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 82, out)
        return out.toByteArray() to if (alpha) "image/png" else "image/jpeg"
    }

    // Keep the folder under its cap by dropping the least recently written images.
    private fun prune() {
        val files = folder.listFiles()?.sortedBy { it.lastModified() }?.toMutableList() ?: return
        var total = files.sumOf { it.length() }
        while (total > MAX_FOLDER * 4 / 5 && files.isNotEmpty()) { val file = files.removeAt(0); total -= file.length(); file.delete() }
    }

    companion object {
        private const val SIZE = 512
        private const val MAX_SOURCE = 4_000_000
        private const val MAX_FOLDER = 200_000_000L
        private const val FRESH = 7 * 86_400_000L
        private const val FAIL_FOR = 86_400_000L
        const val HOST = "appassets.androidplatform.net"
        fun address(id: String) = "https://$HOST/art/logo/" + Uri.encode(id)
    }
}
