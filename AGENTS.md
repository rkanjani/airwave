# Working on Airwave

Airwave is an independent, MIT-licensed media player for user-supplied playlists. One bundled web interface serves web, Samsung TV, iOS, macOS and Android (phones, tablets and Android TV); playback and private storage have platform adapters. Roku can't run that interface, so `platforms/roku/` is a BrightScript/SceneGraph channel that follows the same catalog contract, IDs and screens. This is a development build, not a store release. No provider credentials or private catalogs ship with it.

Describe Airwave in its own terms. Keep competitor names, comparisons and inspiration attributions out of repository files and commit messages; preserve required third-party dependency and media license notices.

Read `docs/PROJECT.md` before changing platform boundaries, storage, packaging, or product scope; it holds the complete repo map, history and known limitations.

## Build every feature for every platform

Airwave ships to six targets: web, Samsung TV, macOS, iOS, Android (phone/tablet/TV) and Roku. A new feature or behavior change is built for all of them in the same change, not only for the platform you were asked about or are testing on:

- `app/` changes reach web, Samsung, Apple and Android together; give each native adapter (`platforms/apple/Airwave.swift`, `platforms/android/app/src/main/java/app/airwave/android/`) its side of any new bridge action or playback event.
- Roku doesn't run `app/`. Mirror screen, copy, parsing, storage and playback changes in `platforms/roku/`, and keep `tests/roku.test.cjs` parity with `app/core.js` passing.
- Native-only behavior (playback engines, encrypted storage, artwork, casting) gets the equivalent in each native adapter.
- If a platform genuinely can't support something, record it under "Platform gaps" in `docs/PROJECT.md` and in your report instead of skipping it silently.
- Build every target you touched and report per platform whether it was built, run on a simulator/emulator, or observed on hardware.

## How it works

1. `scripts/serve.cjs` serves `app/` on loopback; an optional `AIRWAVE_LIBRARY_PATH` loads a private catalog through `server/library.cjs`. With `ffmpeg` on PATH (or `AIRWAVE_FFMPEG`), `server/preview.cjs` grabs stills for live tiles. `AIRWAVE_CAST=1` adds a token-protected LAN listener (`server/cast.cjs`) for Cast receivers.
2. `app/index.html` loads HLS.js, then `platform.js`, `core.js`, `sports.js`, `player.js`, and `app.js`. `AirwavePlatform.loadLibrary()` selects the native bridge, local relay or demo fallback.
3. `app/app.js` owns navigation, imports, favorites and progress. `app/player.js` selects Apple native playback, Samsung AVPlay or browser video/HLS.js. In Chrome, `app/cast.js` hands the title to a Cast device and the same controls drive it.
4. `platforms/apple/Airwave.swift` bundles that same interface, owns the native catalog, and plays each title on one of two engines behind its `PlaybackEngine` protocol: AVPlayer (HLS, MP4/MOV/M4V, and anything while AirPlay is in use) or mpv from MPVKit (raw `.ts` live channels, MKV/AVI and other containers). A failed start, or a first mpv attempt with no frame by its deadline, retries once on the other engine.
5. `platforms/android/` is a Kotlin WebView shell: Gradle stages `app/` through `scripts/runtime-files.cjs` into its assets, serves it from `https://appassets.androidplatform.net/app/`, and answers the same bridge actions through an origin-restricted `AirwaveAndroid` web message listener. Media3 ExoPlayer plays each title over the web view (HLS, MP4/MOV, raw `.ts`, MKV, AVI); a failed first attempt retries once in the other form (progressive or HLS).
6. `platforms/roku/` is a separate SceneGraph channel: `source/core.brs` ports the M3U parser, ID hash and catalog v2 validation; a Task node fetches the library from a URL the user enters; a Video node plays HLS, MP4 and MKV.

## Where changes belong

- `app/app.js`, `app/styles.css`: shared screens, copy, touch/remote/keyboard navigation.
- `app/core.js`: M3U/XMLTV parsing, display-name tidying, time calculations and filtering; tests in `tests/core.test.cjs`.
- `app/sports.js`: the followed-league list, scoreboard parsing and game-to-channel matching for the Home scores strip; tests in `tests/sports.test.cjs`.
- `app/platform.js`, `app/player.js`, `app/cast.js`: JavaScript adapter contracts; tests in `tests/platform.test.cjs`, `tests/player.test.cjs` and `tests/sender.test.cjs`.
- `server/library.cjs`, `server/network.cjs`, `server/artwork.cjs`, `server/preview.cjs`: opaque media registry, HLS rewriting, outbound request boundaries, the tile-artwork cache and live tile stills; tests in `tests/library.test.cjs`. `server/cast.cjs`: cast tokens and the LAN listener; tests in `tests/cast.test.cjs`.
- `platforms/apple/`: two shared Xcode schemes, Swift shell, plist and the `AppIcon` asset catalog (rendered from `app/assets/icon.svg`: an inset tile for macOS, full-bleed for iOS). iOS-only casting stays in `#if os(iOS)` blocks; the Google Cast SDK is an exact-pinned Swift package on the iOS target only. MPVKit (exact 1.0.0, its LGPL `MPVKit` product, never `MPVKit-GPL`) is linked into both targets. Engine choice lives in `PlaybackPolicy`, fallback and timing in `AirwaveModel.begin`/`handle`, and the controls read `PlaybackState`, never an engine directly.
- `platforms/android/`: Gradle project (exact-pinned AGP, Media3, AndroidX; wrapper with a checksum-pinned distribution), Kotlin shell in `app/src/main/java/app/airwave/android/` (`MainActivity` bridge, `Catalog` + Keystore-sealed store, `Artwork`, `Playback` + `PlaybackPolicy`), JVM tests in `app/src/test/`. Launcher icon and TV banner are rendered from `app/assets/icon.svg`.
- `platforms/roku/`: manifest, `source/` (bootstrap and `core.brs`), `components/` (scene, loader Task, player), `images/`. Every file is listed in `rokuFiles` in `scripts/runtime-files.cjs`; `tests/roku.test.cjs` runs `core.brs` under `brs-node` against `app/core.js` and validates the channel with BrighterScript.
- `scripts/runtime-files.cjs`: explicit web/Tizen release allowlist (Android stages the same list) plus the Roku allowlist; update this when adding a runtime asset. Apple bundles the whole `app/` directory, whose contents the check verifies against that same list. The vendor bundle and license remain unmodified.

## Contracts to preserve

- Shared UI changes apply to every surface. Differences in playback, native controls and storage are documented platform behavior, not full codec parity.
- Playback callbacks belong to their generation. Closing or switching invalidates old success, failure and time callbacks; cleanup releases the stream.
- Private catalog JSON is version 2 with `name` and `items`. Each item has a stable `id`, `name`, HTTP(S) `url`, `kind` (`live` or `movie`), and optional grouping, logo, EPG and favorite fields. Keep the raw file outside Git and app bundles.
- Web snapshots replace upstream URLs with `/api/media/` IDs and give live items an `/api/preview/<id>.jpg` still; native snapshots use `airwave-native://` media IDs, `airwave-art://logo/<id>` artwork IDs and `airwave-art://frame/<id>` stills. Provider credentials and image URLs stay outside JavaScript for these two paths. Normal M3U Remember remains explicit opt-in, unencrypted local storage.
- `airwave.library` local-storage format is version 1. Favorites, history, favorite-seed, the Tidy names preference and the followed sports leagues (`airwave.sportsLeagues`) keys are separate; tidied names are display-only, so stored items and search keep playlist names. Preserve existing IDs and storage readability when evolving imports.
- Native bridge messages are `{id, action, payload}` on Apple (WebKit message handler) and Android (`AirwaveAndroid.postMessage` with a JSON string, main frame and bundle origin only); replies resolve by ID and playback events by token, whichever engine plays. Android adds `exit` for the Leave dialog. The native catalog is AES-GCM encrypted with a Keychain-held key. Android seals its catalog with a random AES-GCM key wrapped by a non-exportable Android Keystore key, in no-backup storage, and serves artwork at `https://appassets.androidplatform.net/art/logo/<id>` (WebView can't load images from a custom scheme). Roku stores only the library address, favorites, progress and preferences in registry section `airwave` (unencrypted, capped well under its 16 KB limit) and says so in Settings; it downloads the library again at each launch. Engines receive provider URLs only from native code; the opt-in timing log (`-AirwavePlaybackTiming YES`) records engine, kind, container and seconds, never URLs.
- Live tile stills cost the provider a connection, so every layer limits them: the page asks only for tiles that stay on screen, one at a time and never while the player is open; the relay and `FrameGrabber` run one grab at a time with a gap, abort and requeue a grab when playback starts, wait 15 s after playback, keep stills 10 minutes and failures 30. ffmpeg (relay) and mpv (Apple) decode bytes the grabber fetched, never a URL.
- The web relay is a local single-user process: loopback binding, Host/origin/session checks, registered upstream URLs and private-network rejection are part of its boundary. Public hosting requires a separate security design. The opt-in cast listener is the only LAN-facing path: one rotating, expiring token, its own Host check, registered media only, never upstream URLs.
- Scores are fetched from ESPN's public scoreboard feed only while at least one league is followed and Home is open; the request carries no library or user data. Keep it that way.
- Private provider data stays out of tests and CI. Use reserved `.example` hosts and synthetic credentials; validate real playback manually only when authorized.

## Commands

From the repo root, with Node 18+ (CI uses Node 22):

```sh
npm ci --ignore-scripts
npm run check                 # Run before calling a change done; same command as CI
npm test                      # Automated tests only
npm start                     # Demo at http://127.0.0.1:4317
AIRWAVE_PORT=4318 npm start    # Alternative when another local preview owns 4317
AIRWAVE_CAST=1 AIRWAVE_LIBRARY_PATH=... npm start   # Also serve Cast receivers on the LAN (port+1, or AIRWAVE_CAST_PORT)
npm run release               # Checked, allowlisted static runtime in dist/
npm run roku                  # Checked Roku sideload zip in dist/
AIRWAVE_CERT_PROFILE='YourProfileName' npm run package
```

Use `AIRWAVE_LIBRARY_PATH` with an external private JSON file for the local relay. There is no provider account in the repo. `npm run check` checks owned JavaScript syntax, asset wiring, vendor integrity, CI permissions/pins, tracked-file hygiene and tests. There is no formatter, linter or static JS typechecker configured; match the surrounding source.

Android builds are separate and need JDK 17+, the Android SDK (platform 36) and Node on PATH; they produce a debug-signed APK, never a release build:

```sh
cd platforms/android && JAVA_HOME=/path/to/jdk17 ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug testDebugUnitTest
# -> platforms/android/app/build/outputs/apk/debug/app-debug.apk ; install with adb install -r
```

Apple builds are separate, require macOS/Xcode, and do not sign a distribution release:

```sh
xcodebuild -project platforms/apple/Airwave.xcodeproj -scheme Airwave-macOS -configuration Debug -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO
xcodebuild -project platforms/apple/Airwave.xcodeproj -scheme Airwave-iOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO
```

## Making the common change

The initial work centered on shared browsing and platform playback; there is not yet enough history to infer long-term churn. For a screen or adapter change:

1. Run `npm run check`; read the relevant existing tests and the map's open threads. Add a behavior test at the adapter boundary for logic changes.
2. Change the shared interface once; keep native-only code in its adapter. Avoid editing the HLS vendor bundle.
3. Run the check again. For UI work, inspect phone-width and desktop/TV layouts and exercise keyboard/remote focus; no browser automation framework is bundled.
4. Build every target the change reaches: both Apple schemes, the Android debug APK, and `npm run roku`. For playback changes, separately report what was observed in the browser, Apple runtime, Android emulator or device, Roku and actual Samsung hardware.

## Gotchas

- Android needs `compileSdk 37` because AndroidX Core 1.19 requires it; `targetSdk` stays 36. Gradle runs `node` to stage `app/`, so Node must be on PATH (Android Studio included). Emulator H.264 decoders reject some frame sizes (the 853-px demo trailer fails on both emulator decoders); test playback with the public bipbop HLS stream or a local ffmpeg source, and treat emulator decode failures as emulator limits until a device says otherwise.
- Android TV images have no document picker: a stub activity answers `OPEN_DOCUMENT` and closes at once. `MainActivity.hasPicker` detects the stub; private catalogs reach Android TV only through a playlist URL today.
- WebView draws a grey placeholder for an empty `<video>`; the Android shell blanks it with `getDefaultVideoPoster`. While native video covers the page, the web view must not hold focus or the remote moves through the hidden library.
- Roku: BrightScript can't run `app/core.js`, so `source/core.brs` is a port. `tests/roku.test.cjs` runs it in `brs-node` and compares IDs, URL normalization, parsing, catalog validation and tidy names with the JavaScript; change both together. `brs-node` writes case-sensitive associative arrays to JSON incorrectly, which is why some comparisons use pairs. BrighterScript validation runs inside the test.
- Roku plays HLS, MP4/MOV/M4V, MKV and DASH through the Video node; live `.ts` is rewritten to `.m3u8` (the provider HLS form) and AVI is refused with a message. There is no XMLTV guide on Roku yet. Typography is set in code (`components/Fonts.brs`) because the simulator lacks `font:` file references.
- The Samsung manifest is still 0.1.0 while npm and Apple are 0.2.0. The version-parity expectation is a deliberate pending test, not a passing assertion. Resolve it in release work.
- Tiles show catalog logos/posters and XMLTV programme icons when present, otherwise the name on a flat tint; there is no poster lookup for titles without catalog artwork. Series/episodes, automatic provider refresh and cloud sync are not implemented. MKV/AVI play on Apple through mpv; the browser and Samsung still cannot play them.
- mpv was measured slower than AVPlayer on multi-rendition HLS (11–23 s on Apple's bipbop), so keep HLS on AVPlayer. AVPlayer cannot open an unbounded raw MPEG-TS stream (it fails at once), which is why live `.ts` channels start on mpv. With AVPlayer, `automaticallyWaitsToMinimizeStalling = false` broke start-up in earlier testing, and `timeControlStatus == .playing` can arrive before a frame: first frame means the playhead moved.
- AVPlayer requests an HLS playlist twice while starting. `RedirectResolver` follows one provider redirect first so both go straight to the target. It checks one hop only, because checking the target costs the full request it saves. Use the completion-handler form of `willPerformHTTPRedirection`: the async form was not called for a per-task delegate in testing.
- WebKit does not focus a button on click, so `document.activeElement` cannot tell the web interface which row started playback; `play()` takes the button. While Apple's native player covers the screen, the web player keeps its controls hidden (`native-cover`) and shows them again only for an error and Retry.
- Signed Apple builds run with the hardened runtime, and LuaJIT in mpv's built-in scripts writes executable memory, which kills the app with `OS_REASON_CODESIGNING` as soon as mpv plays. `MPVEngine.options` turns every built-in script off. Linker-signed Debug builds (`CODE_SIGNING_ALLOWED=NO`) do not enforce this, so test mpv changes in a signed Release build.
- An unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) cannot save an imported library: the Keychain write fails. To exercise a synthetic catalog in the iOS simulator, build with `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` and put the JSON in the simulator's `group.com.apple.FileProvider.LocalStorage` app group (On My iPhone). A macOS Debug build shares the installed app's encrypted catalog and Keychain key, so it plays from the real provider.
- mpv debands by default (`-AirwaveDeband NO` disables it). Its `ewa_lanczossharp` upscaler was measured at twice the GPU time of the default lanczos (16 vs 8 ms per frame at 3024×1832 on an M3 Pro) with no visible gain, so it is not used. AVPlayer super-resolution is opt-in (`-AirwaveSuperResolution YES`): VideoToolbox's low-latency scaler only takes 8-bit SDR sources up to 960×960 at 2×, is missing from the simulator SDK (keep it behind `#if !targetEnvironment(simulator)`), and MetalFX spatial scaling was measured at 5–10 ms GPU per frame with no visible gain over AVPlayerLayer at 720p. MPVKit's FFmpeg has no image encoders, so mpv `screenshot-to-file` fails; use `screenshot-raw`.
- MPVKit ships static libraries. LGPL compliance for a distributed Apple build relies on this source being public and relinkable; see `NOTICE.md` before any store submission.
- Reset clears browser preferences and the Apple artwork cache, not the relay's external catalog or the Apple encrypted file. Check the actual storage path before promising deletion.
- Apple uses an ATS HTTP-media exception. No certificate validation bypass is present. Review the exception for distribution.
- Mocked AVPlay tests and successful compilation do not prove device playback. See `VERIFICATION.md`.
- The relay's 20-second upstream idle limit guards connecting, headers and playlist reads only. `pipeMedia` lifts it for media bodies, because a paused player or a Cast receiver with a full buffer stops reading a movie for longer than that.
- The Cast sender tests use a synthetic framework; real receiver playback needs a Cast device on the owner's network. The Cast SDK only loads in Chrome on a secure origin (`http://127.0.0.1` counts, `localhost` fails the relay's Host check), and the iOS target needs `@executable_path/Frameworks` to load the SDK.

## Releasing

`npm run release` creates only the static runtime plus license notices; it is not the private relay or an installable native app. `npm run roku` writes `dist/airwave-roku-<version>.zip` for developer-mode sideloading (`ROKU_HOST=<ip> ROKU_DEV_PASSWORD=… npm run roku -- --install` posts it; the owner types the password). Roku store packages need a device-generated signing key and are an owner action. The Android build is a debug APK; release signing (`~/.airwave-android-keys/`, never committed), an AAB and Play submission are owner-approved release work. Samsung packaging checks the repo, stages the same allowlist, and requires Tizen CLI and a configured signing profile. Apple distribution requires owner-selected identifiers, signing, assets and device acceptance. The maintainer authorizes uploads, store submissions, tags/releases and deployments; preparation alone is not authorization to publish. Branch protection is an owner decision.

Update this guide and `docs/PROJECT.md` in the same change when paths, commands, contracts or platform support change. Add commit-backed timeline entries for milestones.
