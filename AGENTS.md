# Working on Airwave

Airwave is an independent, MIT-licensed media player for user-supplied playlists. One bundled web interface serves web, Samsung TV, iOS and macOS; playback and private storage have platform adapters. This is a development build, not a store release. No provider credentials or private catalogs ship with it.

Read `docs/PROJECT.md` before changing platform boundaries, storage, packaging, or product scope; it holds the complete repo map, history and known limitations.

## How it works

1. `scripts/serve.cjs` serves `app/` on loopback; an optional `AIRWAVE_LIBRARY_PATH` loads a private catalog through `server/library.cjs`.
2. `app/index.html` loads HLS.js, then `platform.js`, `core.js`, `player.js`, and `app.js`. `AirwavePlatform.loadLibrary()` selects the native bridge, local relay or demo fallback.
3. `app/app.js` owns navigation, imports, favorites and progress. `app/player.js` selects Apple native playback, Samsung AVPlay or browser video/HLS.js.
4. `platforms/apple/Airwave.swift` bundles that same interface, owns the native catalog, and presents AVPlayerView/AVPlayerViewController.

## Where changes belong

- `app/app.js`, `app/styles.css`: shared screens, copy, touch/remote/keyboard navigation.
- `app/core.js`: M3U/XMLTV parsing, time calculations and filtering; tests in `tests/core.test.cjs`.
- `app/platform.js`, `app/player.js`: JavaScript adapter contracts; tests in `tests/platform.test.cjs` and `tests/player.test.cjs`.
- `server/library.cjs`, `server/network.cjs`: opaque media registry, HLS rewriting and outbound request boundaries; tests in `tests/library.test.cjs`.
- `platforms/apple/`: two shared Xcode schemes, Swift shell and plist.
- `scripts/runtime-files.cjs`: explicit release allowlist; update this when adding a runtime asset. The vendor bundle and license remain unmodified.

## Contracts to preserve

- Shared UI changes apply to every surface. Differences in playback, native controls and storage are documented platform behavior, not full codec parity.
- Playback callbacks belong to their generation. Closing or switching invalidates old success, failure and time callbacks; cleanup releases the stream.
- Private catalog JSON is version 2 with `name` and `items`. Each item has a stable `id`, `name`, HTTP(S) `url`, `kind` (`live` or `movie`), and optional grouping, logo, EPG and favorite fields. Keep the raw file outside Git and app bundles.
- Web snapshots replace upstream URLs with `/api/media/` IDs; native snapshots use `airwave-native://` IDs. Provider credentials stay outside JavaScript for these two paths. Normal M3U Remember remains explicit opt-in, unencrypted local storage.
- `airwave.library` local-storage format is version 1. Favorites, history and favorite-seed keys are separate. Preserve existing IDs and storage readability when evolving imports.
- Apple bridge messages are `{id, action, payload}`; replies resolve by ID and playback events by token. The native catalog is AES-GCM encrypted with a Keychain-held key.
- The web relay is a local single-user process: loopback binding, Host/origin/session checks, registered upstream URLs and private-network rejection are part of its boundary. Public hosting requires a separate security design.
- Private provider data stays out of tests and CI. Use reserved `.example` hosts and synthetic credentials; validate real playback manually only when authorized.

## Commands

From the repo root, with Node 18+ (CI uses Node 22):

```sh
npm ci --ignore-scripts
npm run check                 # Run before calling a change done; same command as CI
npm test                      # Automated tests only
npm start                     # Demo at http://127.0.0.1:4317
AIRWAVE_PORT=4318 npm start    # Alternative when another local preview owns 4317
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
- Native artwork uses placeholders. Series/episodes, automatic provider refresh, broad MKV/AVI compatibility and cloud sync are not implemented.
- Reset clears browser preferences, not the relay's external catalog or the Apple encrypted file. Check the actual storage path before promising deletion.
- Apple uses an ATS HTTP-media exception. No certificate validation bypass is present. Review the exception for distribution.
- Mocked AVPlay tests and successful compilation do not prove device playback. See `VERIFICATION.md`.

## Releasing

`npm run release` creates only the static runtime plus license notices; it is not the private relay or an installable native app. Samsung packaging checks the repo, stages the same allowlist, and requires Tizen CLI and a configured signing profile. Apple distribution requires owner-selected identifiers, signing, assets and device acceptance. The maintainer authorizes uploads, store submissions, tags/releases and deployments; preparation alone is not authorization to publish. Branch protection is an owner decision.

Update this guide and `docs/PROJECT.md` in the same change when paths, commands, contracts or platform support change. Add commit-backed timeline entries for milestones.
