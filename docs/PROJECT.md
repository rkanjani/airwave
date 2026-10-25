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
| `platforms/` | First-party/config | Swift Apple shell, plist and hand-authored Xcode project/shared schemes |
| `scripts/` | First-party tooling | Local server, unified checks, runtime allowlist, web release and Tizen packager |
| `server/` | First-party | Private library registry, HLS rewriting and safe upstream requests |
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
      -> native encrypted catalog + Keychain -> AVPlayer -> user-selected provider
iOS   -> Google Cast iOS SDK -> Cast device -> user-selected provider

Samsung -> app/config.xml -> app/index.html -> player.js -> Samsung AVPlay
```

`app/styles.css` switches between a labelled TV/desktop sidebar and, at 900px and below, a
top bar plus five-tab bottom bar; screens of 1700px and wider scale the same layout for TV distance.
The shared player shows a remote-scrubbable seek bar for movies and programme progress for live channels.
The UI is shared. macOS playback draws a compact SwiftUI control bar (auto-hiding, with an AirPlay
route picker) over AVPlayerView; iOS uses AVPlayerViewController controls; Samsung remote keys are registered
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
public W3C-hosted Blender demo trailers. Opening the player in Chrome loads Google's Cast
sender script from www.gstatic.com; the iOS build resolves the Google Cast SDK package from
GitHub. Dependency restoration contacts npm.
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
  are bounded at 10,000; original catalog resources remain registered.
- Apple snapshots expose `airwave-native://<id>` and omit source artwork URLs. The
  underlying catalog is AES-GCM encrypted in Application Support/Airwave; the key is
  stored in Keychain. This storage is separate from the browser view's preferences.
- Plain M3U import is limited to 5 MB/10,000 entries. Its optional remembered library
  uses local-storage version 1 and is unencrypted. XMLTV imports are limited to 10 MB
  and kept only for the session. Favorites/history are separate local-storage keys.
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
- Native Apple playback uses AVPlayerView/AVPlayerViewController; macOS hides the system bar
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
5. MKV/AVI and unsupported codecs need a different playback/remux/transcode strategy;
   imported-library count is not a compatibility metric. Native artwork uses placeholders.
6. Reset does not delete the external relay catalog or Apple encrypted file. The UI states
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
