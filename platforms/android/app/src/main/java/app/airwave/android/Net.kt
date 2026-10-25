package app.airwave.android

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

// Bounded HTTP(S) reads for guide/playlist text and tile artwork. HttpURLConnection does not follow a
// redirect between http and https, which providers use often, so redirects are followed here.
object Net {
    fun isHttp(raw: String?): Boolean = raw != null && Regex("^https?://[^\\s]+", RegexOption.IGNORE_CASE).matches(raw.trim())

    fun get(raw: String, maxBytes: Int, timeoutMs: Int): ByteArray {
        var url = URL(raw)
        repeat(6) {
            if (url.protocol != "http" && url.protocol != "https") throw IOException("Unsupported scheme")
            val connection = url.openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = timeoutMs
                connection.readTimeout = timeoutMs
                connection.setRequestProperty("User-Agent", "Airwave/" + BuildConfig.VERSION_NAME)
                val status = connection.responseCode
                if (status in 300..399) {
                    url = URL(url, connection.getHeaderField("Location") ?: throw IOException("Redirect without location"))
                    return@repeat
                }
                if (status !in 200..299) throw IOException("HTTP $status")
                if (connection.contentLengthLong > maxBytes) throw IOException("Too large")
                connection.inputStream.use { input ->
                    val out = ByteArrayOutputStream()
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (out.size() + read > maxBytes) throw IOException("Too large")
                        out.write(buffer, 0, read)
                    }
                    return out.toByteArray()
                }
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Too many redirects")
    }
}

