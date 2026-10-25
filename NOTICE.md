# Credits and independence

Airwave is an independent media player for user-supplied playlists.

The Airwave logo, landscape illustration, CSS, and application source were created for this project.

Demo streams are external trailers, not bundled films:

- **Big Buck Bunny**: © Blender Foundation, https://peach.blender.org/ ; Creative Commons Attribution 3.0, https://creativecommons.org/licenses/by/3.0/ . Trailer hosted at https://media.w3.org/2010/05/bunny/trailer.mp4 . Unmodified external playback.
- **Sintel**: © Blender Foundation, https://www.sintel.org/ ; Creative Commons Attribution 3.0, https://creativecommons.org/licenses/by/3.0/ . Trailer hosted at https://media.w3.org/2010/05/sintel/trailer.mp4 . Unmodified external playback.

The comparison stills in `docs/verification/` are crops of Big Buck Bunny (© Blender Foundation, Creative Commons Attribution 3.0), re-encoded at lower resolutions, overlaid with a fictional Airwave caption bar, and upscaled; they document picture quality and are not part of the app.

The landscape illustration is decorative Airwave artwork, not a frame or poster from either film. Sample channel names are fictional navigation examples and do not claim broadcast carriage.

Casting uses Google Cast SDKs, which are not included in the source: Chrome loads Google's Cast sender script from www.gstatic.com when the player first opens, and the iOS target resolves the Google Cast iOS SDK 4.8.6 (with gtm-session-fetcher) through Swift Package Manager from https://github.com/googlecast/google-cast-ios-sdk . The SDK binaries are distributed under Google's Cast SDK terms, https://developers.google.com/cast/docs/terms .

The Apple targets play part of the library with mpv through MPVKit 1.0.0, https://github.com/mpvkit/MPVKit , which Swift Package Manager resolves from GitHub; it is not included in the source. Airwave uses MPVKit's LGPL product (`MPVKit`), not `MPVKit-GPL`: libmpv 0.41.0 configured with `-Dgpl=false` (LGPL-2.1-or-later), FFmpeg n8.1.2 configured without `--enable-gpl` or `--enable-nonfree` and with `--enable-version3` (LGPL-3.0-or-later), and the libraries they need, among them libplacebo, libass, FreeType, HarfBuzz, FriBidi, GnuTLS, Nettle, GMP, OpenSSL, dav1d, libbluray, uchardet, MoltenVK and shaderc, and on macOS LuaJIT, each under its own license (see the MPVKit release and each upstream project). MPVKit's build scripts are LGPL-3.0. MPVKit delivers these as static libraries, so an Apple build of Airwave contains them. Airwave's complete source and Xcode project are public under MIT, so a recipient can rebuild the app against a modified MPVKit (for example by pointing the package at locally built xcframeworks, as MPVKit's README describes). Anyone distributing an Apple build must also pass on the LGPL license texts and the corresponding source of those libraries; LGPL-3.0 installation-information terms for consumer devices need review before any App Store distribution.

The Android app resolves AndroidX Media3 1.11.1 (ExoPlayer, HLS and UI), AndroidX Activity, Core and WebKit from Google's Maven repository at build time; they are not included in the source and remain under the Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0 . An Android build contains them. The Gradle wrapper (`platforms/android/gradle/wrapper/gradle-wrapper.jar`, Apache-2.0) is committed so the build is reproducible. The Roku channel is original BrightScript; its tests use the `brs-node` simulator and BrighterScript compiler (both MIT) as development dependencies, which are never part of the channel.

HLS.js 1.7.3 is bundled under the Apache License 2.0. See `app/vendor/HLS-LICENSE` and https://github.com/video-dev/hls.js . Imported provider artwork is loaded at runtime and is not included in the source package.

Original Airwave code and artwork are MIT licensed; see `LICENSE`. Third-party HLS.js retains its Apache-2.0 license, and MPVKit, mpv, FFmpeg and their libraries retain theirs. External media and provider artwork retain their respective owners' terms and are not relicensed by Airwave.
