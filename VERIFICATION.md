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

## Remaining verification

Physical Samsung installation and remote controls; Samsung firmware and codecs; signing and WGT packaging; physical iOS playback; public hosting; App Store distribution; series resolution; full codec coverage; provider refresh. The browser and Samsung players do not support MKV/AVI; on Apple they depend on mpv. Hardware playback is not proven by mocked AVPlay tests or successful Apple builds.

Private-provider tests are deliberately manual, optional, and outside CI. Public demo streams can also become unavailable; automated tests must not depend on their availability.
