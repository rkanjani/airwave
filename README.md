# Airwave 0.2

Independent media player with an original interface and artwork, and no payment gates. One HTML/CSS/JavaScript interface serves web, Samsung TV, iOS and macOS; playback and private storage use platform adapters.

## Verified status

Development version 0.2.0. Browser HLS playback and native macOS playback have been exercised with a private user-provided catalog. The iOS simulator and macOS targets compile. This is not a store release or certification of every stream or codec.

Samsung target is Tizen 6.0+. Physical iOS and Samsung TV playback remain unverified. No playlists, provider accounts, credentials or channel subscriptions are included.

## Architecture

| Layer | Responsibility |
|---|---|
| `app/core.js` | Shared playlist parsing, filters, programme times |
| `app/app.js`, `styles.css` | Shared library, search, favorites, guide, details; phone bottom navigation, desktop/TV side navigation |
| `app/player.js` | Generation-scoped playback lifecycle; browser video/HLS.js, Samsung AVPlay, Apple bridge |
| `app/platform.js` | Private library and text import adapters |
| `server/` + `scripts/serve.cjs` | Local web relay: provider URLs stay server-side, same-origin opaque media URLs, HLS rewriting and Range support |
| `platforms/apple/Airwave.swift` | iOS/macOS SwiftUI shell, bundled WKWebView, native AVPlayer controls, document picker, AES-GCM catalog storage with Keychain key |
| `app/config.xml` | Samsung TV packaging and privileges |

Apple apps bundle the interface and connect directly to the provider; they do not depend on the local web server. Native catalog credentials never enter the web view. Native artwork currently uses original placeholder artwork. The web relay keeps provider credentials out of the browser library payload. Web and Apple catalogs are private, device-local copies; there is no cloud synchronization.

## Run the web app

Requires Node 18+. HLS.js is bundled with its license. `npm ci` restores the pinned development dependency.

```sh
npm start
```

Open `http://127.0.0.1:4317`. To load your private catalog, point the server at the file stored outside the source project:

```sh
AIRWAVE_LIBRARY_PATH='/absolute/path/to/private/library.json' npm start
```

Keep private catalog JSON outside this checkout. It can contain provider credentials. Never publish it or bundle it with an app. See `docs/PROJECT.md` for the catalog contract.
The relay binds to loopback only, validates Host and Origin, uses an HttpOnly SameSite cookie, and accepts only registered upstream resources. It rejects private-network upstream destinations and revalidates redirects. It is a **single-user local web app**, not a public hosted service. Public hosting needs real user authentication, per-user encrypted catalog storage, HTTPS, rate limits, and provider-compatible deployment before exposing a relay.

Static hosting of `app/` also runs the interface and direct-source player, subject to provider CORS and HTTPS/mixed-content restrictions. The private local relay is required for the tested provider setup in Chromium.

## Apple apps

Open `platforms/apple/Airwave.xcodeproj`. Shared schemes:

- `Airwave-macOS`: macOS 13+, universal Intel/Apple Silicon.
- `Airwave-iOS`: iPhone/iPad, iOS 16+.

Select a development team and your own bundle identifiers for device distribution. Local builds:

```sh
xcodebuild -project platforms/apple/Airwave.xcodeproj -scheme Airwave-macOS -configuration Debug -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO
xcodebuild -project platforms/apple/Airwave.xcodeproj -scheme Airwave-iOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO
```

In the native app, Settings → Choose library file imports the private JSON catalog. It is encrypted into Application Support/Airwave/library.encrypted; the AES key is in Keychain. Move a private catalog to an iPhone only through a transfer method you trust, then use its file picker. This is a development app, not an App Store release. Store assets, privacy declarations, signing/provisioning, device testing, and distribution are separate release work.

HTTP IPTV support currently uses an ATS exception in the Apple plist. A release must document this user-provided media use case or narrow the exception as provider support allows. No certificate validation bypass is implemented.

## Samsung Frame TV

1. Install official Tizen Studio, Samsung TV extension and Samsung Certificate Extension.
2. Create a Samsung certificate profile including the TV's DUID when required.
3. Enable TV Developer Mode, enter the development computer's IP, reboot and connect through Device Manager.
4. Import `app/` as a Tizen web application; use Run As → Tizen Web Application.
5. Alternatively, with a configured Tizen CLI:

```sh
AIRWAVE_CERT_PROFILE='YourProfileName' npm run package
```

This produces a signed widget in `dist/`. Source ZIPs are not installable widgets. Samsung packaging and installation have not been verified. Import a provider M3U through the TV interface; the Mac's loopback web relay is not reachable from the TV.

## Features and boundaries

- Library browsing, title/group search, favorites, movie progress, details, M3U and XMLTV import, remote/keyboard navigation.
- Phone layout uses touch-sized controls and safe-area spacing. Apple native playback uses system video controls.
- Browser HLS.js is pinned to 1.7.3; Safari/native HLS and Samsung AVPlay are separate adapters. MKV/AVI and some codecs in the imported collection will not play on Apple/browser engines without remuxing/transcoding. That service is not implemented.
- Series listings require episode resolution rather than direct playable stream URLs. Series/episode browsing is not implemented.
- No guide schedules were extracted. Import matching XMLTV to populate the guide. No Xtream login/automatic catalog refresh UI, catch-up, DVR, multiview, DRM or cloud sync.
- Imported large catalogs render in pages of 48. M3U text import retains its 5 MB/10,000-entry limit; the private JSON path supports the larger migrated library.
- Ordinary M3U “Remember” is explicit opt-in and uses unencrypted browser/TV local storage. The native JSON path uses encrypted storage. Reset clears browser preferences; it does not delete the native encrypted file or the relay's source catalog.

## Verification

Run `npm run check` before calling a change done. See `VERIFICATION.md` for observed results and remaining device checks.

## References

- [Samsung AVPlay](https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html)
- [Samsung TV setup](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html)
- [HLS.js](https://github.com/video-dev/hls.js)
- [Apple AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)

Provider subscriptions remain with their providers.
