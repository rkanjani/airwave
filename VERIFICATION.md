# Verification

## Observed during initial development

- Browser HLS playback with decoded 1280×720 video and an advancing playback clock.
- Native macOS live playback through AVPlayerView; document-picker import and encrypted persistence across relaunch.
- Large private catalog loaded through opaque web-relay URLs. No private catalog or test-session screenshots are included in this repository.
- macOS and iOS simulator targets built for arm64 and x86_64 with Xcode 26.2. Deployment targets are macOS 13 and iOS 16.
- Phone layout visually checked at 390×700; desktop/TV layout at 1920×1080. These checks do not establish physical-device acceptance.
- Demo playback, favorites after reload, search, valid/invalid M3U imports, XMLTV matching and keyboard navigation exercised.
- Automated parser, guide, filtering, relay and mocked AVPlay lifecycle checks pass. Run `npm run check` to reproduce the current automated evidence.
- Local relay rejected unauthenticated and cross-origin library requests, and returned opaque media URLs to its authenticated local session.

## Casting (October 2026)

- Cast relay: token minting, rotation, revocation, 12-hour expiry, Host/method/path checks, CORS and playlist prefixing pass in `tests/cast.test.cjs`. A synthetic-library relay run returned 405 for GET `/api/cast`, 403 without the session cookie or cross-origin, a LAN URL with CORS for the active token, and 404 after `/api/cast/end`.
- Chrome sender: Google's Cast framework loaded from gstatic in the app's Chromium pane, which found no devices and kept the Cast button hidden. With a synthetic Cast framework, the player cast a demo title at its current position, drove seek and pause on the receiver, showed "Playing on …" at desktop and 375 px widths, and resumed locally at the receiver position after Disconnect.
- iOS: both Apple targets compile with the Google Cast SDK 4.8.6 package on iOS. On the iPhone 17 Pro simulator the app launched, the Cast button appeared beside Back in the native player, and tapping it opened the SDK's local-network prompt.
- Not verified: playback on a real Cast device, HTTP and private-library sources on a real receiver, provider CORS, and casting from a physical iPhone.

## Playback engines (October 2026)

Start-up was timed from play request to first frame, where first frame means the playhead moved (AVPlayer can report `.playing` before any frame). A scratch harness compiled the shipped `Airwave.swift` engines into a 960×540 macOS window on an Apple Silicon Mac (macOS 26, Xcode 26.2) and ran each sample five times, creating a new engine per run as the app does. The simulated provider is a local ffmpeg source (720p30 H.264/AAC, 2 s GOP) serving the same channel as a raw MPEG-TS relay that clients join mid-stream, as steady 6 s-segment HLS, and as HLS built only when a session first requests it. Public streams were fetched over the internet, so their times include network variance.

| Sample | AVPlayer median (min–max) s | mpv median (min–max) s | Airwave now picks |
|---|---|---|---|
| Apple bipbop HLS, TS segments | 0.33 (0.20–0.68) | 4.40 (4.08–4.52) | AVPlayer |
| Apple bipbop HLS, fMP4 | 0.50 (0.45–0.79) | 19.08 (18.87–19.99) | AVPlayer |
| Apple bipbop raw `.ts` file (finite) | 0.13 (0.13–0.52) | 0.73 (0.66–0.81) | AVPlayer (movie) |
| Big Buck Bunny MKV (test-videos.co.uk) | fails in 0.05–0.22 (-11828) | 0.42 (0.41–0.50) | mpv |
| Big Buck Bunny trailer MP4 (media.w3.org) | 0.21 (0.20–0.29) | 0.83 (0.81–0.98) | AVPlayer |
| Simulated live channel, raw `.ts` | fails in 0.03–0.05 (-11850) | 0.86 (0.85–1.43) | mpv |
| Simulated live channel, steady HLS | 0.12 (0.11–0.17) | 0.15 (0.14–0.21) | AVPlayer when the URL is `.m3u8` |
| Simulated live channel, HLS built on request | 5.69 (5.68–5.78) | 5.83 (5.82–5.89) | — |

- Before this change every live `.ts` channel was rewritten to `.m3u8` for AVPlayer. Where a provider builds that HLS on request, start-up is bound by the first segment (5.7 s here with 6 s segments); the raw `.ts` URL now starts on mpv in 0.86 s. Where the provider's HLS is already running, both paths are fast. MKV, which failed before, now plays.
- mpv's `demuxer-lavf-analyzeduration=0.5` lowered the raw-TS median from 1.00 s to 0.85 s over 2 × 12 runs and cut the 2.5 s slow joins; it is the shipped setting. mpv's first run after launch is slower (about 1.4–2.6 s) while MoltenVK starts.
- iOS simulator (iPhone 17 Pro, timing log on): MKV started on mpv in 2.01 s (first mpv use after launch) with the compact bar; the simulated raw-TS channel on mpv in 1.47 s, showing pause and a Live tag on tap; a live `.ts` URL that 404s failed on mpv in 0.14 s and AVPlayer showed its `.m3u8` twin 0.90 s after the request; replaying it went straight to AVPlayer (0.58 s). The MKV played to its end and closed the player normally. Back and the Cast button stayed in place under both engines.
- macOS: both schemes build; the harness drove both engines through the shipped surfaces, and a live channel from the owner's own library played on mpv in the app (2.86 s to first frame, logged without its URL). The macOS control bar was not exercised under mpv by automation.
- Size: unsigned Release builds went from 9.8 MB to 42.6 MB for iOS (arm64; executable 0.7 MB to 34 MB) and from 1.9 MB to 84 MB for macOS (arm64 + x86_64).
- Not verified: physical iPhone/iPad decode, battery and thermal cost of mpv, HDR output, AirPlay handover, the 8 s/15 s mpv start deadlines on a real stalled stream, and provider channels beyond that one observation.

## mpv picture quality (October 2026)

A scratch harness ran the shipped `MPVEngine` in a 3024×1832 px window on an M3 Pro Mac (macOS 26), playing simulated raw-TS live channels from a local ffmpeg relay: Big Buck Bunny at 854×480 (1.2 Mbit/s) and 1280×720 (2.5 Mbit/s), and slow dark gradients at 854×480 (400 kbit/s). GPU time is the sum of libplacebo's average fresh-frame pass times (`vo-passes`); dropped frames were counted from 5 s after the first frame.

| mpv setting | GPU ms per frame (480p → 3024×1832) |
|---|---|
| Defaults (lanczos) | 7.7–9.6 |
| `deband=yes` (shipped) | 7.2–9.3 |
| `scale=spline36` | 8.4 |
| `scale=ewa_lanczos` | 16.1 |
| `scale=ewa_lanczossharp` | 16.4–17.1 |

- On the same paused frame, `ewa_lanczossharp` looked nearly identical to lanczos at 1:1 (slightly less ringing, no added detail), so it was not adopted. At 60 fps its cost would exceed the 16.7 ms frame budget on this Mac.
- Deband replaced the gradient channel's blocky steps with a smooth ramp and fine grain. On detailed content it slightly softens low-contrast texture. It had no measurable GPU or start-up cost, and dropped frames stayed at 0–2 per channel with or without it.
- Not verified: provider channels, the macOS and iOS apps themselves (both compile; the harness used the shipped engine code), physical iPhone/iPad GPU and battery cost, and Intel Macs.

## AVPlayer super-resolution (October 2026)

Verdict: not worth turning on by default. It ships as an opt-in (`-AirwaveSuperResolution YES`) that applies only to SD titles. VideoToolbox's low-latency super-resolution scaler is cheap and keeps up at 60 fps, but it accepts only sources up to 960×960, so HD channels get nothing. On SD the picture is visibly crisper, with halos on text and invented fine texture. MetalFX, the fallback for larger sources, costs 5–10 ms of GPU per frame and looked no better than AVPlayer's own scaling at 720p.

Method: a scratch harness on an M3 Pro (macOS 26.0, Xcode 26.2) played local HLS (H.264, 2 s segments) in a 3008×1692 px window on the 120 Hz built-in display. The clip is Big Buck Bunny with a caption bar added, at 854×480 (1.5–2 Mbit/s) and 1280×720 (3–4.5 Mbit/s), each at 30 and 60 fps. It compared five paths:

- `AVPlayerLayer`, which is what ships.
- Frames from `AVPlayerItemVideoOutput` drawn to a `CAMetalLayer` with bilinear scaling, as a baseline for the pipeline itself.
- The same frames run through `VTLowLatencySuperResolutionScaler` (2×) and then drawn.
- The same frames run through `MTLFXSpatialScaler`, scaled straight to the window.
- VideoToolbox followed by MetalFX.

Each run measured 20 s after a 4 s warm-up, two interleaved runs per cell. Other work on the Mac kept system GPU utilisation at about 83 % before the harness started (seven booted simulators belonged to other tasks), so the table reports GPU time per command buffer and wall time per scaler call, not utilisation.

| Source | Path | GPU ms per frame, median (p95) | Scaler ms, median (p95) | Frames shown / due (two runs) |
|---|---|---|---|---|
| 480p30 | Metal bilinear | 1.0 (5.8) | — | 600/599, 600/599 |
| 480p30 | VideoToolbox 2× | 1.4 (6.2) | 1.7 (2.0) | 601/600, 600/599 |
| 480p30 | MetalFX | 10.4 (22.0) | — | 599/599, 600/599 |
| 480p30 | VideoToolbox + MetalFX | 11.0 (21.2) | 1.7 (2.3) | 600/599, 600/599 |
| 480p60 | Metal bilinear | 1.1 (4.5) | — | 1198/1199, 1189/1199 |
| 480p60 | VideoToolbox 2× | 1.0 (4.5) | 1.8 (2.7) | 1200/1199, 1192/1199 |
| 480p60 | MetalFX | 6.8 (13.9) | — | 1200/1199, 1192/1199 |
| 720p30 | MetalFX | 8.9 (18.8) | — | 599/600, 600/600 |
| 720p60 | Metal bilinear | 1.3 (5.8) | — | 1198/1200, 1186/1199 |
| 720p60 | MetalFX | 7.5 (15.4) | — | 1185/1199, 1194/1199 |

- Limits reported by this Mac: the scaler is supported, takes sources from 96×96 to 960×960, scales only by 2×, and takes only 8-bit 4:2:0 video-range frames. Its SDK header excludes the simulator, and it needs macOS/iOS 26. 480p and 576p qualify; 720p and 1080p do not. Starting a session (loading the model) took 190–735 ms. The non-low-latency `VTSuperResolutionScaler` offers only 4× and is built for offline processing.
- Cost: the VideoToolbox scaler added about 1.7 ms of wall time per 480p frame and no GPU time over the plain Metal draw, so its work runs mostly off the GPU (the engine was not attributed without root). The harness process used about 1–2 percentage points more CPU. The second run's 7–14 missing frames at 60 fps appeared on the plain bilinear path too, so they came from the shared machine, not the scaler. AVPlayer's own layer dropped no decoded frames in any run.
- Sync: frames pulled for the current display time and then scaled arrived after their due time 22 % of the time at 30 fps and 99 % at 60 fps. Pulling 50 ms ahead and queuing scaled frames on an `AVSampleBufferDisplayLayer` that follows the item's timebase gave 0 late frames in 1,349 at either frame rate, with about 50 ms to spare. The shipped opt-in uses that design, so the system keeps sound and picture together and does the final fit to the window with the same filter as `AVPlayerLayer`.
- Quality: `AVPlayerLayer` already scales noticeably sharper than a bilinear draw, so the system's own scaler is the bar to beat. In the app's surface at 480p (`docs/verification/super-resolution-480p.jpg`, AVPlayer on the left, super-resolution on the right, the same paused frame), caption text is crisper but gains a thin dark outline. Grass and roots look sharper, with a synthetic, wormy texture. At 360p doubled to 720p, the stills in `docs/verification/super-resolution-360p.jpg` are, from left to right, the 720p source, `AVPlayerLayer`, VideoToolbox and MetalFX. VideoToolbox recovers visibly more edge detail than `AVPlayerLayer`, but it is less faithful by the numbers: against the 720p source, bilinear scored 29.55 dB PSNR (SSIM 0.892), VideoToolbox 29.17 dB (0.884) and MetalFX 29.90 dB (0.896). `AVPlayerLayer` scored 27.78 dB (0.893), partly because its colour conversion differs from the harness shader. At 720p, MetalFX and `AVPlayerLayer` look the same (`docs/verification/metalfx-720p.jpg`).
- In the shipped code, a harness built from `Airwave.swift` played 480p30 HLS through `AVPlayerEngine` and `AVPlayerSurface`. With the flag on, super-resolution became active during playback and after a paused seek. The 720p rendition stayed on AVPlayer's own picture. Suspending it, as an AirPlay route does, brought back the player's picture with the same brightness as the plain path, and resuming started super-resolution again.
- What it gives up, and how the opt-in handles it:
  - AirPlay: the scaled picture is local only, so it hands back to the player's picture while external playback is active.
  - HDR: the scaler takes only 8-bit frames, so PQ and HLG sources are skipped.
  - Adaptive bitrate: a switch to a new frame size restarts the scaler, or hands back if the new size is too large.
  - Picture in picture: the app has none. A sample-buffer display layer could support it later; a Metal layer could not.
  - The simulator and systems older than macOS/iOS 26 never create it.
  - iOS keeps `AVPlayerViewController`'s controls, because the scaled picture is drawn in its content overlay.
- Not verified: provider SD channels (including interlaced 576i), iPhone and iPad (both build, but the scaler cannot run in the simulator), battery and thermal cost, Intel Macs (the scaler reported support only on this Apple silicon Mac), and an actual AirPlay handover.

## Subtitles (October 2026)

- Browser (Chromium 152 pane): an HLS movie with en/el/fr/pt-BR WebVTT renditions started with English showing; the popover listed Off, the four languages, Load a subtitle file… and the audio renditions; French and Off switched the text tracks. A loaded SRT replaced the stream track and drew from playback time. The popover opens above its button on desktop and as a bottom sheet at 375 px. A playlist without CORS fell back to the browser's own HLS and played without track choices.
- macOS (Debug build under a separate test bundle ID): an MKV with French then English (SDH) SRT tracks started on mpv with English drawn by libass; the popover switched to French and Off. An MP4 with French and English `mov_text` tracks started on AVPlayer with English; its forced-only copies are hidden. Both engines lifted stream subtitles above the control bar while it showed. A loaded SRT drew over AVPlayer. The Open panel itself was not driven (background automation could not reach it); the file was loaded through the same `PlaybackState.loadSubtitles` call.
- iOS: both targets compile; the iOS popover (compact adaptation on iOS 16.4+) and the top-row button for AVPlayer titles were not run.
- Not verified: Samsung AVPlay TEXT tracks on a TV, provider VOD with embedded subtitles, picture subtitles (PGS) on mpv, and right-to-left or non-Latin cue rendering.

## Remaining verification

Physical Samsung installation and remote controls; Samsung firmware and codecs; signing and WGT packaging; physical iOS playback; public hosting; App Store distribution; series resolution; full codec coverage; provider refresh. The browser and Samsung players do not support MKV/AVI; on Apple they depend on mpv. Hardware playback is not proven by mocked AVPlay tests or successful Apple builds.

Private-provider tests are deliberately manual, optional, and outside CI. Public demo streams can also become unavailable; automated tests must not depend on their availability.
