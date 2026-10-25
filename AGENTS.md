# Working on Airwave

Airwave is an independent, MIT-licensed media player for user-supplied playlists. One bundled web interface serves web, Samsung TV, iOS and macOS; playback and private storage have platform adapters. This is a development build, not a store release. No provider credentials or private catalogs ship with it.

Describe Airwave in its own terms. Keep competitor names, comparisons and inspiration attributions out of repository files and commit messages; preserve required third-party dependency and media license notices.

Read `docs/PROJECT.md` before changing platform boundaries, storage, packaging, or product scope; it holds the complete repo map, history and known limitations.

## How it works

1. `scripts/serve.cjs` serves `app/` on loopback; an optional `AIRWAVE_LIBRARY_PATH` loads a private catalog through `server/library.cjs`. `AIRWAVE_CAST=1` adds a token-protected LAN listener (`server/cast.cjs`) for Cast receivers.
2. `app/index.html` loads HLS.js, then `platform.js`, `core.js`, `player.js`, and `app.js`. `AirwavePlatform.loadLibrary()` selects the native bridge, local relay or demo fallback.
3. `app/app.js` owns navigation, imports, favorites and progress. `app/player.js` selects Apple native playback, Samsung AVPlay or browser video/HLS.js. In Chrome, `app/cast.js` hands the title to a Cast device and the same controls drive it.
4. `platforms/apple/Airwave.swift` bundles that same interface, owns the native catalog, and plays each title on one of two engines behind its `PlaybackEngine` protocol: AVPlayer (HLS, MP4/MOV/M4V, and anything while AirPlay is in use) or mpv from MPVKit (raw `.ts` live channels, MKV/AVI and other containers). A failed start, or a first mpv attempt with no frame by its deadline, retries once on the other engine.

## Where changes belong

- `app/app.js`, `app/styles.css`: shared screens, copy, touch/remote/keyboard navigation.
- `app/core.js`: M3U/XMLTV parsing, time calculations and filtering; tests in `tests/core.test.cjs`.
- `app/platform.js`, `app/player.js`, `app/cast.js`: JavaScript adapter contracts; tests in `tests/platform.test.cjs`, `tests/player.test.cjs` and `tests/sender.test.cjs`.
- `server/library.cjs`, `server/network.cjs`: opaque media registry, HLS rewriting and outbound request boundaries; tests in `tests/library.test.cjs`. `server/cast.cjs`: cast tokens and the LAN listener; tests in `tests/cast.test.cjs`.
- `platforms/apple/`: two shared Xcode schemes, Swift shell and plist. iOS-only casting stays in `#if os(iOS)` blocks; the Google Cast SDK is an exact-pinned Swift package on the iOS target only. MPVKit (exact 1.0.0, its LGPL `MPVKit` product, never `MPVKit-GPL`) is linked into both targets. Engine choice lives in `PlaybackPolicy`, fallback and timing in `AirwaveModel.begin`/`handle`, and the controls read `PlaybackState`, never an engine directly.
- `scripts/runtime-files.cjs`: explicit web/Tizen release allowlist; update this when adding a runtime asset. Apple bundles the whole `app/` directory, whose contents the check verifies against that same list. The vendor bundle and license remain unmodified.

## Contracts to preserve

- Shared UI changes apply to every surface. Differences in playback, native controls and storage are documented platform behavior, not full codec parity.
- Playback callbacks belong to their generation. Closing or switching invalidates old success, failure and time callbacks; cleanup releases the stream.
- Private catalog JSON is version 2 with `name` and `items`. Each item has a stable `id`, `name`, HTTP(S) `url`, `kind` (`live` or `movie`), and optional grouping, logo, EPG and favorite fields. Keep the raw file outside Git and app bundles.
- Web snapshots replace upstream URLs with `/api/media/` IDs; native snapshots use `airwave-native://` IDs. Provider credentials stay outside JavaScript for these two paths. Normal M3U Remember remains explicit opt-in, unencrypted local storage.
- `airwave.library` local-storage format is version 1. Favorites, history and favorite-seed keys are separate. Preserve existing IDs and storage readability when evolving imports.
- Apple bridge messages are `{id, action, payload}`; replies resolve by ID and playback events by token, whichever engine plays. The native catalog is AES-GCM encrypted with a Keychain-held key. Engines receive provider URLs only from native code; the opt-in timing log (`-AirwavePlaybackTiming YES`) records engine, kind, container and seconds, never URLs.
- The web relay is a local single-user process: loopback binding, Host/origin/session checks, registered upstream URLs and private-network rejection are part of its boundary. Public hosting requires a separate security design. The opt-in cast listener is the only LAN-facing path: one rotating, expiring token, its own Host check, registered media only, never upstream URLs.
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
AIRWAVE_CERT_PROFILE='YourProfileName' npm run package
```

Use `AIRWAVE_LIBRARY_PATH` with an external private JSON file for the local relay. There is no provider account in the repo. `npm run check` checks owned JavaScript syntax, asset wiring, vendor integrity, CI permissions/pins, tracked-file hygiene and tests. There is no formatter, linter or static JS typechecker configured; match the surrounding source.

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
4. For Apple changes, compile both targets. For playback changes, separately report what was observed in the browser, Apple runtime and actual Samsung hardware.

## Gotchas

- The Samsung manifest is still 0.1.0 while npm and Apple are 0.2.0. The version-parity expectation is a deliberate pending test, not a passing assertion. Resolve it in release work.
- Native artwork uses placeholders. Series/episodes, automatic provider refresh and cloud sync are not implemented. MKV/AVI play on Apple through mpv; the browser and Samsung still cannot play them.
- mpv was measured slower than AVPlayer on multi-rendition HLS (11–23 s on Apple's bipbop), so keep HLS on AVPlayer. AVPlayer cannot open an unbounded raw MPEG-TS stream (it fails at once), which is why live `.ts` channels start on mpv. With AVPlayer, `automaticallyWaitsToMinimizeStalling = false` broke start-up in earlier testing, and `timeControlStatus == .playing` can arrive before a frame: first frame means the playhead moved.
- Signed Apple builds run with the hardened runtime, and LuaJIT in mpv's built-in scripts writes executable memory, which kills the app with `OS_REASON_CODESIGNING` as soon as mpv plays. `MPVEngine.options` turns every built-in script off. Linker-signed Debug builds (`CODE_SIGNING_ALLOWED=NO`) do not enforce this, so test mpv changes in a signed build (an ad-hoc `codesign --options runtime` signature is enough).
- MPVKit ships static libraries. LGPL compliance for a distributed Apple build relies on this source being public and relinkable; see `NOTICE.md` before any store submission.
- Reset clears browser preferences, not the relay's external catalog or the Apple encrypted file. Check the actual storage path before promising deletion.
- Apple uses an ATS HTTP-media exception. No certificate validation bypass is present. Review the exception for distribution.
- Mocked AVPlay tests and successful compilation do not prove device playback. See `VERIFICATION.md`.
- The Cast sender tests use a synthetic framework; real receiver playback needs a Cast device on the owner's network. The Cast SDK only loads in Chrome on a secure origin (`http://127.0.0.1` counts, `localhost` fails the relay's Host check), and the iOS target needs `@executable_path/Frameworks` to load the SDK.

## Releasing

`npm run release` creates only the static runtime plus license notices; it is not the private relay or an installable native app. Samsung packaging checks the repo, stages the same allowlist, and requires Tizen CLI and a configured signing profile. Apple distribution requires owner-selected identifiers, signing, assets and device acceptance. The maintainer authorizes uploads, store submissions, tags/releases and deployments; preparation alone is not authorization to publish. Branch protection is an owner decision.

Update this guide and `docs/PROJECT.md` in the same change when paths, commands, contracts or platform support change. Add commit-backed timeline entries for milestones.
