package app.airwave.android

import android.app.Activity
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import org.json.JSONObject
import java.net.URI

data class PlayRequest(val key: String, val url: String, val live: Boolean, val resume: Double, val token: Int, val title: String, val favorite: Boolean)
data class Attempt(val url: String, val hls: Boolean)

// ExoPlayer plays HLS and, through its own extractors, progressive MP4/MOV, raw MPEG-TS (including unbounded
// live channels), MKV, WebM and AVI. The extension picks the first attempt; one that fails before its first
// frame retries once in the other form, the way the Apple app retries on its other engine.
object PlaybackPolicy {
    fun extension(url: String): String =
        (runCatching { URI(url).path }.getOrNull() ?: "").substringAfterLast('/').substringAfterLast('.', "").lowercase()

    fun first(url: String): Attempt = Attempt(url, extension(url) == "m3u8")

    fun fallback(request: PlayRequest, first: Attempt): Attempt =
        if (first.hls) Attempt(request.url, false) else Attempt(if (request.live) hlsForm(request.url) else request.url, true)

    // Live providers that serve raw MPEG-TS usually publish the same channel as HLS at .m3u8.
    fun hlsForm(url: String): String {
        val raw = url.replace(".ts?", ".m3u8?")
        return if (raw.endsWith(".ts")) raw.dropLast(3) + ".m3u8" else raw
    }
}

// The native player covers the web view while a title plays. Events go back to the web interface by token,
// so a closed or replaced title can't report into the next one.
@OptIn(UnstableApi::class)
class Playback(private val activity: Activity, root: FrameLayout, private val emit: (String, Any?, Int) -> Unit, private val cover: (Boolean) -> Unit) {
    private val overlay = FrameLayout(activity)
    private val view = PlayerView(activity)
    private val title = TextView(activity)
    private val favoriteButton = ImageButton(activity)
    private val main = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var request: PlayRequest? = null
    private var token = -1
    private var started = false
    private var favorite = false
    private val ticker = object : Runnable {
        override fun run() {
            val p = player ?: return
            val duration = if (p.duration == C.TIME_UNSET) 0.0 else p.duration / 1000.0
            emit("time", JSONObject().put("time", p.currentPosition.coerceAtLeast(0) / 1000.0).put("duration", duration), token)
            main.postDelayed(this, 1000)
        }
    }

    val active get() = request != null

    init {
        overlay.setBackgroundColor(Color.BLACK)
        overlay.visibility = View.GONE
        overlay.isClickable = true
        overlay.isFocusable = false
        view.setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
        view.setShowNextButton(false)
        view.setShowPreviousButton(false)
        view.controllerShowTimeoutMs = 4000
        view.keepScreenOn = true
        // The remote drives the player only while it holds focus; the first D-pad press shows the controls.
        view.isFocusable = true
        view.isFocusableInTouchMode = false
        overlay.addView(view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        val dp = { value: Int -> TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), activity.resources.displayMetrics).toInt() }
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.top_scrim)
            setPadding(dp(16), dp(16), dp(16), dp(32))
        }
        fun round(icon: Int, label: String, action: () -> Unit) = ImageButton(activity).apply {
            setImageResource(icon); contentDescription = label; setBackgroundResource(R.drawable.control)
            isFocusable = true; setOnClickListener { action() }
        }
        bar.addView(round(R.drawable.ic_back, "Back") { stop() }, LinearLayout.LayoutParams(dp(48), dp(48)))
        title.setTextColor(Color.WHITE)
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        title.maxLines = 1
        title.ellipsize = TextUtils.TruncateAt.END
        title.setPadding(dp(12), 0, dp(12), 0)
        bar.addView(title, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        favoriteButton.setBackgroundResource(R.drawable.control)
        favoriteButton.isFocusable = true
        favoriteButton.setOnClickListener {
            favorite = !favorite; showFavorite()
            emit("favorite", favorite, token)
        }
        bar.addView(favoriteButton, LinearLayout.LayoutParams(dp(48), dp(48)))
        overlay.addView(bar, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP))
        // The title bar shows and hides with the playback controls.
        view.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility -> bar.visibility = visibility })
        root.addView(overlay, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
    }

    fun start(next: PlayRequest) {
        stop(notify = false)
        token = next.token; request = next; favorite = next.favorite
        title.text = next.title; showFavorite()
        overlay.visibility = View.VISIBLE
        cover(true)
        bars(false)
        begin(PlaybackPolicy.first(next.url), fallback = false)
        view.post { view.requestFocus() }
    }

    fun toggle() { player?.let { it.playWhenReady = !it.playWhenReady } }
    fun seek(delta: Double) { player?.let { it.seekTo((it.currentPosition + (delta * 1000).toLong()).coerceAtLeast(0)) } }

    fun stop(notify: Boolean = true) {
        val old = token
        token = -1; request = null; started = false
        main.removeCallbacks(ticker)
        player?.release(); player = null
        view.player = null
        if (overlay.visibility == View.VISIBLE) { overlay.visibility = View.GONE; bars(true); cover(false) }
        if (notify) emit("native-closed", null, old)
    }

    private fun begin(attempt: Attempt, fallback: Boolean) {
        val request = request ?: return
        player?.release()
        started = false
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("Airwave/" + BuildConfig.VERSION_NAME)
            .setConnectTimeoutMs(20_000)
            .setReadTimeoutMs(20_000)
        // A decoder that refuses a stream (some reject odd frame sizes) hands over to the next one, often software.
        val next = ExoPlayer.Builder(activity, DefaultRenderersFactory(activity).setEnableDecoderFallback(true))
            .setMediaSourceFactory(DefaultMediaSourceFactory(http))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .build()
        player = next
        view.player = next
        view.setShowFastForwardButton(!request.live)
        view.setShowRewindButton(!request.live)
        val token = request.token
        next.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() { if (this@Playback.token == token) started = true }
            override fun onPlaybackStateChanged(state: Int) {
                if (this@Playback.token != token) return
                if (state == Player.STATE_BUFFERING) emit("loading", "Buffering…", token)
                if (state == Player.STATE_ENDED) { emit("ended", null, token); stop(notify = false) }
            }
            override fun onIsPlayingChanged(playing: Boolean) {
                if (this@Playback.token != token) return
                if (playing) emit("playing", null, token) else if (next.playbackState == Player.STATE_READY) emit("paused", null, token)
            }
            override fun onPlayerError(error: PlaybackException) {
                if (this@Playback.token != token) return
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) { next.seekToDefaultPosition(); next.prepare(); return }
                if (!started && !fallback) {
                    emit("loading", "Trying another stream format…", token)
                    main.post { if (this@Playback.token == token) begin(PlaybackPolicy.fallback(request, attempt), fallback = true) }
                    return
                }
                emit("error", "This stream or codec can't be played on this device.", token)
                stop(notify = false)
            }
        })
        val item = MediaItem.Builder().setUri(attempt.url).apply { if (attempt.hls) setMimeType(MimeTypes.APPLICATION_M3U8) }.build()
        if (!request.live && request.resume > 0) next.setMediaItem(item, (request.resume * 1000).toLong()) else next.setMediaItem(item)
        next.prepare()
        next.playWhenReady = true
        main.removeCallbacks(ticker)
        main.postDelayed(ticker, 1000)
    }

    private fun showFavorite() {
        favoriteButton.setImageResource(if (favorite) R.drawable.ic_favorite_on else R.drawable.ic_favorite)
        favoriteButton.contentDescription = if (favorite) "Remove from favorites" else "Add to favorites"
    }

    // Video fills the screen; the system bars come back with the library.
    private fun bars(show: Boolean) {
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (show) controller.show(WindowInsetsCompat.Type.systemBars()) else controller.hide(WindowInsetsCompat.Type.systemBars())
    }
}
