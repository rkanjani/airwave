package app.airwave.android

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackPolicyTest {
    private fun request(url: String, live: Boolean) = PlayRequest("id", url, live, 0.0, 1, "Title", false)

    @Test fun playlistsStartAsHls() {
        assertEquals(Attempt("https://media.example/live/1.m3u8?token=x", true), PlaybackPolicy.first("https://media.example/live/1.m3u8?token=x"))
        assertEquals(Attempt("http://media.example/movie.MKV", false), PlaybackPolicy.first("http://media.example/movie.MKV"))
        assertEquals(Attempt("http://media.example/live/user/pass/7", false), PlaybackPolicy.first("http://media.example/live/user/pass/7"))
    }

    @Test fun rawLiveTsFallsBackToTheProviderHlsForm() {
        val live = request("http://media.example/live/user/pass/7.ts?x=1", true)
        assertEquals(Attempt("http://media.example/live/user/pass/7.m3u8?x=1", true), PlaybackPolicy.fallback(live, PlaybackPolicy.first(live.url)))
        assertEquals("http://media.example/a/7.m3u8", PlaybackPolicy.hlsForm("http://media.example/a/7.ts"))
    }

    @Test fun moviesAndHlsFallBackWithoutRewriting() {
        val movie = request("http://media.example/movie/9.ts", false)
        assertEquals(Attempt(movie.url, true), PlaybackPolicy.fallback(movie, PlaybackPolicy.first(movie.url)))
        val hls = request("https://media.example/x.m3u8", true)
        assertEquals(Attempt(hls.url, false), PlaybackPolicy.fallback(hls, PlaybackPolicy.first(hls.url)))
    }

    @Test fun extensionIgnoresQueryAndCase() {
        assertEquals("mp4", PlaybackPolicy.extension("https://media.example/a.b/Movie.MP4?sig=1.ts"))
        assertEquals("", PlaybackPolicy.extension("https://media.example/stream"))
    }
}
