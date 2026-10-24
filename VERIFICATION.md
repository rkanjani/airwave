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

## Remaining verification

Physical Samsung installation and remote controls; Samsung firmware and codecs; signing and WGT packaging; physical iOS playback; public hosting; App Store distribution; series resolution; full codec coverage; provider refresh. Native and browser players do not support all MKV/AVI content. Hardware playback is not proven by mocked AVPlay tests or successful Apple builds.

Private-provider tests are deliberately manual, optional, and outside CI. Public demo streams can also become unavailable; automated tests must not depend on their availability.
