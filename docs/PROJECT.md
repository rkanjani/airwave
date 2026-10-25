# Airwave project map

## Product and status

Airwave 0.2.0 is a development-stage player for people bringing their own media playlists.
It provides a library home, Live TV (a channel grid and an XMLTV guide), movie browsing,
favorites, search, M3U import and playback across a shared interface.
The implementation has an original interface and artwork.
See `NOTICE.md` for media and dependency attribution.

The original code/artwork are MIT licensed. HLS.js retains Apache-2.0 terms.
There are no payment gates, ads, Airwave accounts or analytics in the implementation.
There are no included provider subscriptions, private playlists or channel rights.
No public hosted service or store distribution has been established.
These status claims come from the initial development scope and the current source,
not from a published App Store or Samsung listing.

Supported development targets are browser, Samsung Tizen 6.0+, macOS 13+ and iOS 16+.
Browser and macOS real playback were observed in initial development.
iOS simulator builds succeeded; physical iOS and Samsung playback remain unverified.
Successful import is not proof that every stream/container/codec will play.

## Complete top-level map

| Path | Classification | Purpose |
| --- | --- | --- |
| `.github/` | Config | Read-only, SHA-pinned Check workflow; same check command as local work |
| `.gitignore` | Config | Excludes builds, dependencies, private data, signing keys and machine state |
| `AGENTS.md` | Docs | Operational guide for changes and verification |
| `CLAUDE.md` | Docs | Claude Code import of the shared guide |
| `LICENSE` | License | MIT terms for original work |
| `NOTICE.md` | Docs/license | Independence statement and third-party/media attribution |
| `README.md` | Docs | Public setup, platform support and limitations |
| `VERIFICATION.md` | Docs | Observed initial checks and unverified device/release behavior |
| `app/` | First-party + vendor | Runtime UI, original assets, Tizen config; `vendor/` contains pinned HLS.js and its license |
| `docs/` | Docs | This product, architecture, history and debt map |
| `package.json` | Config | Commands, Node engine, license and exact dependencies; private prevents accidental npm publication |
| `package-lock.json` | Generated/committed | Reproducible dependency resolution; update through npm |
| `platforms/` | First-party/config | Swift Apple shell, plist, app icon asset catalog and hand-authored Xcode project/shared schemes |
| `scripts/` | First-party tooling | Local server, unified checks, runtime allowlist, web release and Tizen packager |
| `server/` | First-party | Private library registry, HLS rewriting, safe upstream requests and the tile-artwork cache |
| `tests/` | Synthetic tests | Node tests for parsing, filtering, playback, native bridge, relay and release staging |

Ignored local directories include `node_modules/` (dependencies), `build/` (Apple builds),
`dist/` (packaged artifacts), `work/`/`private/` (local scratch/private data), and tool state.
Keep real catalogs outside this repository even though common private directories are ignored.
No fixture is a captured private provider response.

## Runtime connections

```text
Browser -> scripts/serve.cjs -> app/index.html -> platform/core/player/app
        -> /api/library -> server/library.cjs -> opaque library snapshot
        -> /api/media/<id> -> server/network.cjs -> user-selected provider
        -> cast.js -> Google Cast sender (gstatic) -> Cast device
           -> direct source URL, or POST /api/cast -> server/cast.cjs token
Cast device -> LAN listener (AIRWAVE_CAST=1) /cast/<token>/api/media/<id> -> provider

Apple -> Airwave.swift -> bundled app/index.html -> webkit airwave messages
      -> native encrypted catalog + Keychain -> PlaybackPolicy -> AVPlayer or mpv (MPVKit)
      -> user-selected provider
iOS   -> Google Cast iOS SDK -> Cast device -> user-selected provider

Samsung -> app/config.xml -> app/index.html -> player.js -> Samsung AVPlay
```

`app/styles.css` switches between a labelled TV/desktop sidebar and, at 900px and below, a
top bar plus five-tab bottom bar; screens of 1700px and wider scale the same layout for TV distance.
The shared player shows a remote-scrubbable seek bar for movies and programme progress for live channels.
The UI is shared. Apple playback picks an engine per title (`PlaybackPolicy` in `Airwave.swift`):
AVPlayer for HLS and MP4/MOV/M4V, and for everything while AirPlay is in use; mpv (libmpv with FFmpeg,
from MPVKit) for live channels given as raw `.ts` or with no extension, MKV, AVI and other containers.
Live `.ts` channels now reach mpv as the raw URL; only AVPlayer gets the `.ts`→`.m3u8` provider rewrite.
If the chosen engine fails before its first frame, or a first mpv attempt shows no frame within 8 s
(live) or 15 s (movie), the title retries once on the other engine, and the engine that worked is
remembered for that title for the rest of the session. macOS draws a compact SwiftUI control bar
(auto-hiding; the AirPlay route picker appears only under AVPlayer) over either engine's surface;
iOS keeps AVPlayerViewController's controls for AVPlayer and shows the same compact bar, without volume
or AirPlay, for mpv. Both engines sit behind one `PlaybackEngine` protocol, so the bridge contract and
playback tokens are unchanged. mpv debands its output to smooth the stepped gradients of low-bitrate channels
(launch with `-AirwaveDeband NO` to compare) and upscales with its default lanczos; AVPlayer, the browser
and Samsung leave scaling to the system. An opt-in (`-AirwaveSuperResolution YES`, macOS/iOS 26 devices) runs
AVPlayer frames of up to 960×960 through VideoToolbox's low-latency super-resolution scaler and shows them on a
display layer over the player's own picture; larger, HDR and AirPlay titles keep the plain picture. Samsung remote keys are registered
when the corresponding APIs exist. Search results start playback directly. Browser playback uses native video or HLS.js.
Callbacks are guarded by playback generation so abandoned streams cannot restart.
In Chrome, `app/cast.js` adds a Cast button once a device is found; while casting, the same
controls drive the receiver and disconnecting resumes locally. iOS uses the Cast SDK's own
button and expanded controls from the native player. macOS and Samsung do not cast.

`AirwavePlatform` loads private catalogs through the Apple bridge or local web endpoint.
Static hosting with no `/api/library` endpoint falls back to ordinary demo/M3U use.
It remains subject to browser CORS and mixed-content rules; the tested private-source
Chromium path used the local relay.

External runtime destinations are user-configured stream/logo/guide hosts and the
public W3C-hosted Blender demo trailers. Following a sports league in Settings adds ESPN's public
scoreboard feed (site.api.espn.com) and its team logos (a.espncdn.com), loaded directly from every surface. Opening the player in Chrome loads Google's Cast
sender script from www.gstatic.com; the iOS build resolves the Google Cast SDK package from
GitHub, and both Apple builds resolve MPVKit's binary frameworks from its GitHub releases. Dependency restoration contacts npm.
CI runs on GitHub Actions. There is no analytics, cloud-sync or Airwave account service.

## Data contracts and ownership

- Private migration catalog: `{version: 2, name, items}`; optional source metadata stays
  in the private file. Items have stable `id`, `name`, HTTP(S) `url`, `kind: live|movie`,
  and optional `group`, `logo`, `epgId`, `favorite`, `color` fields. Native import accepts
  up to 100 MB/200,000 entries and validates the playable-item shape. These are declared
  contracts: current importers do not enforce the `version` value; Apple skips invalid
  entries and supplies a fallback name. Web input is assumed to be a trusted local export.
- The web relay strips upstream URLs from snapshots and rewrites HLS playlists, keys,
  initialization maps and segment URLs to registered opaque resources. Dynamic resources
  are bounded at 10,000; original catalog resources remain registered. Catalog images
  (`.img`) go through `server/artwork.cjs`: image content only, 2 MB each, a 64 MB in-memory
  LRU, one shared fetch per image and a one-day memory of failures.
- Tiles load artwork only near the viewport, six at a time, and show the name on a
  flat tint until an image arrives or when it fails. XMLTV `<icon>` on the current
  programme replaces a live tile's image, with the channel logo on a plate; those icon
  URLs load directly from the guide's host.
- Apple snapshots expose `airwave-native://<id>` for media and `airwave-art://logo/<id>` for
  artwork; source artwork URLs stay native. A WKURLSchemeHandler fetches each image once,
  downsamples it to 512 px and keeps it in Caches/Airwave/Artwork (7-day refresh, failures
  retried after a day, folder trimmed past 200 MB). Reset clears that folder. The
  underlying catalog is AES-GCM encrypted in Application Support/Airwave; the key is
  stored in Keychain. This storage is separate from the browser view's preferences.
- Plain M3U import is limited to 5 MB/10,000 entries. Its optional remembered library
  uses local-storage version 1 and is unencrypted. XMLTV imports are limited to 10 MB
  and kept only for the session. Favorites/history are separate local-storage keys.
- Tidy names (`airwave.tidyNames`, on unless stored `false`; Reset clears it) changes only
  what is displayed. `AirwaveCore.tidyName` strips region prefixes, divider runs, styled Unicode
  letters and all-caps, and returns the resolution (8K/4K/FHD/HD/SD) plus HDR/HEVC tags for
  badges; RAW and frame-rate notes are dropped without a badge. `tidyGroups` keeps the region
  ("US · Sling") and falls back to tags, then the raw name, when two groups would read the same.
  Stored items, IDs, search and favorites still use playlist names; native and Cast playback
  receive the displayed title through the adapters' `title` option (`tests/core.test.cjs`).
- Sports scores (`airwave.sportsLeagues`, an array of league IDs, empty by default; Reset clears it).
  For each followed league Home fetches the public scoreboard while it is open, at most once a minute
  (every 30 s while a game is live), through `AirwavePlatform.fetchText` (4 MB cap), and redraws only
  the strip. `AirwaveSports.parseScoreboard` keeps teams, scores, status, start time and broadcaster
  names; logos must be HTTPS. Choosing a game plays the best-ranked live channel from
  `AirwaveSports.matchChannels`: a guide programme naming both teams near the game time, then a
  channel named for both teams, then a channel whose displayed name is the broadcaster (whole name
  over prefix; services ending in "+" never match). With no match a dialog says what was searched
  (`tests/sports.test.cjs`). Matching is heuristic and has only been exercised with synthetic playlists.
- Bridge request IDs correlate responses; playback tokens reject stale events. Default
  native timeout is 30 seconds, document picking 5 minutes (`tests/platform.test.cjs`).
- Casting a relay item mints one cast token through the cookie-guarded `POST /api/cast`
  (`/api/cast/end` revokes it). The token is 48 hex characters, rotates on every cast and expires
  after 12 hours; the LAN listener checks its own Host, serves only `/cast/<token>/api/media/<id>`
  for registered resources, rewrites playlists under the same prefix and adds CORS for receivers
  (`tests/cast.test.cjs`). The page receives only the LAN URL and content type, never upstream URLs.
- iOS casting passes the native item's provider URL to the receiver from Swift; it is not
  exposed to JavaScript. The bridge `play` payload now also carries the item `kind`.
- The player's top-right heart toggles the playing title's favorite. The bridge `play` payload
  carries its current `favorite` state; the native overlay reports taps as a `favorite` playback
  event, and JavaScript storage stays the only favorites store.
- There is no cross-device sync or provider refresh UI. IDs must remain stable to retain
  favorites and movie progress; changing storage shape needs an explicit migration.

## History with evidence

This repository starts from an already working local development snapshot. There is
no earlier Git history, tag, merged PR or removal record to reconstruct here.

| Date | Milestone | Evidence |
| --- | --- | --- |
| 2026-10-24 | Imported the shared player, local relay and Apple targets at npm version 0.2.0; retained existing development limitations | `ffeb7ff` |
| 2026-10-24 | Added MIT terms and ignores for private data, signing artifacts and per-machine state | `ef62c8e` |
| 2026-10-24 | Added one local/CI check, native bridge characterization, a pending version-parity test and allowlisted packaging | `f07a459` |
| 2026-10-24 | Added the operational agent guide and product/history map | `8d00680` |
| 2026-10-24 | Redesigned the shared interface; merged Guide into Live TV; added movie seek/resume and live-programme player controls | `efef441` |
| 2026-10-24 | Added casting from Chrome and iOS, with an opt-in token-protected LAN cast listener for private-library items | `409c158` |
| 2026-10-24 | Replaced the macOS system player bar with compact Airwave controls; search results play directly | `4402043` |
| 2026-10-24 | Apple apps pick AVPlayer or mpv (MPVKit) per title, with one-time fallback, raw-TS live start-up and MKV/AVI playback | `532f99b` |
| 2026-10-24 | Replaced the signal-arc icon with the wave bands mark across favicon, Samsung icon and in-app brand | `6c74acf` |
| 2026-10-24 | Added Tidy names (on by default): cleaned channel and group names with resolution and HDR/HEVC badges | `b9d6c93` |
| 2026-10-24 | Apple playback no longer shows the web and native player screens together; focus returns to the row that started playback; search waits for a typing pause | `480afd1` |
| 2026-10-24 | AVPlayer starts follow a provider redirect once instead of on each of its two initial playlist requests | `76cdad6` |
| 2026-10-24 | Library tiles show catalog artwork and XMLTV programme images, with tinted fallbacks and viewport-limited loading | `69402e1` |
| 2026-10-25 | Measured AVPlayer super-resolution; added it as an SD-only opt-in (`-AirwaveSuperResolution YES`) | `270181a`, `0136ca6` |
| 2026-10-25 | macOS and iOS apps use the wave bands mark as their app icon | `8dea7f8` |
| 2026-10-25 | Home shows scores for sports leagues followed in Settings; choosing a game plays the matching channel | `53310bf` |

The initial import is evidence of the current implementation, not a claim that all its
features were originally written in that commit. Pre-import observations are recorded
in `VERIFICATION.md`; their private test data and screenshots are deliberately absent.

## Decisions still shaping the code

- One shared UI with explicit platform playback/storage adapters follows the requested
  cross-platform scope (initial implementation: `ffeb7ff`, `app/platform.js`, Apple shell).
- Private catalog credentials stay on the local server or in Apple native storage for
  those paths; ordinary M3U Remember is an explicit, documented exception.
- Casting private-library items from the web app uses an opt-in LAN listener (`AIRWAVE_CAST=1`)
  because receivers can't reach loopback, send the session cookie or rely on provider CORS.
  It widens the relay boundary to the local network for one tokenized cast at a time; the
  loopback app, Host/origin/session checks and private-network upstream rejection are unchanged.
- The relay is loopback-only and single-user. Turning it into a public multi-user service
  is a new authentication/storage/security project, not a host-binding tweak.
- Apple playback runs two engines rather than one. AVPlayer keeps hardware decode, battery life and
  AirPlay for what Apple handles; mpv covers raw MPEG-TS live streams, which AVPlayer refuses, and
  containers it rejects. MPVKit was chosen over VLCKit for its first-party Swift package with one LGPL
  product for macOS and iOS, a smaller FFmpeg-only stack, and mpv's tunable stream probing for live
  start-up; VLCKit needs a third-party SPM wrapper, links MobileVLCKit statically on iOS too, and adds
  VLC's network caching delay by default. The cost is size: unsigned Release builds grew from 9.8 MB
  to 42.6 MB on iOS (arm64) and from 1.9 MB to 84 MB on macOS (universal). MPVKit's libraries are
  static, so LGPL compliance relies on this public, relinkable source (see `NOTICE.md`).
- AVPlayer surfaces use AVPlayerView/AVPlayerViewController; macOS hides the system bar
  (`controlsStyle = .none`) because it cannot drop its overflow button. Initial development
  replaced a failing SwiftUI VideoPlayer integration before the baseline import; this
  pre-import observation is documented in the private development session, not Git history.
- Vendored HLS is intentionally committed to support offline native/TV bundles. The
  check compares it byte-for-byte with the exact npm version; edit/update both together.
- CI does not call real media providers, use credentials or require Apple/Samsung SDKs.
  Hardware acceptance remains separate from the fast Node check.

## Removed and abandoned

The interface redesign removed `app/assets/horizon.svg` (decorative placeholder artwork) and
folded the separate Guide destination into Live TV as a Channels / Guide switch. No other
tracked files or shipped features have been removed.
Two AVPlayer start-up ideas were measured and dropped in `76cdad6`: serving the first playlist from a single
fetch through a resource loader (no faster against a live-style test stream) and disabling
`automaticallyWaitsToMinimizeStalling` (playback reported playing and never advanced).
The pre-import SwiftUI VideoPlayer approach was replaced with native view wrappers;
no earlier source revision is present here. The public repository never included private
catalogs, device exports, user-specific verification details or credential-bearing screenshots.

## Debt and open threads

1. **Pending test:** Tizen widget version 0.1.0 disagrees with npm/Apple 0.2.0. The bootstrap
   intentionally leaves it visible in `tests/release.test.cjs`; align versions during release work.
2. Samsung AVPlay initialization assumes `window.webapis` exists. `app/index.html` does
   not explicitly load Samsung's Web APIs script; verify the on-device loading path before
   claiming native Samsung playback. This is a source-derived risk, not a reproduced device failure.
3. Physical Samsung/iPhone playback, remote behavior, certificates and store distribution
   remain unverified. The Apple build commands compile without signing; no CI Apple job exists.
4. Series episode resolution, provider refresh/login UI, automatic provider guide population, catch-up, DVR,
   multiview, DRM integration and cloud sync are not implemented.
5. Apple targets play MKV/AVI and raw MPEG-TS through mpv (MPVKit 1.0.0); the browser and Samsung
   still need a remux/transcode strategy for those, and imported-library count is not a compatibility
   metric. mpv playback has been timed on public samples and a simulated provider on macOS and the iOS
   simulator only: provider channels, physical iPhone/iPad decode and battery cost, and HDR output are
   unmeasured. Super-resolution is opt-in, SD-only and measured on one Mac (see `VERIFICATION.md`); it is
   off by default because its gain over AVPlayer's own scaling is modest and it adds edge halos. mpv has no AirPlay or picture-in-picture (the app stops playback in the background, so
   neither engine offers PiP). App Store distribution of the static LGPL libraries needs a licensing
   review.
   Titles without catalog or guide artwork have no poster source yet (a provider VOD-info or
   opt-in metadata lookup would be next).
6. Reset clears the Apple artwork cache but does not delete the external relay catalog or Apple encrypted file. The UI states
   this boundary. A full remove-library flow would need its own implementation and tests.
7. ATS permits HTTP media. Distribution needs a documented exception or narrower policy.
8. First-party JS is compact and has no formatter/linter/typechecker. Current checks cover
   syntax, wiring, hygiene and behavior tests, not exhaustive static analysis or accessibility.
9. Casting is verified only against a synthetic Cast framework, the relay's token tests and the
   iOS simulator's Cast prompt. Real receiver playback, HTTP sources on the HTTPS receiver page,
   provider CORS and the iOS local-network prompt on hardware are unverified. A custom receiver
   or an iOS-side relay would be needed for HLS providers without CORS when casting from iOS.
10. The iOS target links the Google Cast SDK (exact 4.8.6). Its Bluetooth/local-network usage and
   App Store privacy declarations need review before distribution.

## Release ownership

The maintainer authorizes publishing, GitHub releases/tags, deployment and store submission.
`npm run release` builds `dist/airwave-web-0.2.0.tar.gz` from the explicit runtime allowlist
plus MIT/third-party notices. It runs the same check first and excludes server code and catalogs.
Apple bundles the entire `app/` directory; the check enforces that this directory contains
exactly the allowlisted files, including vendor assets.
`npm run package` stages that allowlist for Tizen and requires a certificate profile/CLI.
Apple builds use the two Xcode schemes; signing identifiers, assets and store declarations
must be prepared and approved for a particular release. No automated publishing exists.
Branch protection and required-check settings are owner choices, not configured by these files.
