import SwiftUI
import Combine
import WebKit
import AVKit
import CryptoKit
import Security
import UniformTypeIdentifiers
#if os(iOS)
import GoogleCast
#endif

@main
struct AirwaveApp: App {
    @StateObject private var model = AirwaveModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    init() { AirwaveCast.configure() }
    #endif
    var body: some Scene {
        WindowGroup {
            ZStack {
                AirwaveWebView(model: model)
                if let player = model.player {
                    AirwavePlayerOverlay(player: player) { model.stop() }
                        .id(ObjectIdentifier(player)).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.player.map(ObjectIdentifier.init))
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { phase in if phase == .background { model.stop() } }
            #if os(macOS)
            .frame(minWidth: 800, minHeight: 550)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}

// The web bundle is the only document permitted to call the native bridge.
// Provider credentials stay in the native catalog; JavaScript receives opaque media IDs.
@MainActor
final class AirwaveModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var player: AVPlayer?
    weak var webView: WKWebView?
    private var catalog: [String: Any]?
    private var media: [String: [String: Any]] = [:]
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var playToken = 0
    private var documentDelegate: AnyObject?
    private let store = PrivateCatalogStore()
    private var networkTasks: [String: Task<Void, Never>] = [:]
    private var castItem: CastItem?

    func configure(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self
        #if os(iOS)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        #endif
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "app") else { return }
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url?.isFileURL == true && action.request.url?.standardizedFileURL.path.hasPrefix(Bundle.main.bundleURL.path) == true
        decisionHandler(allowed ? .allow : .cancel)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let id = body["id"] as? String, let action = body["action"] as? String else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "library":
            do { if catalog == nil, let saved = try store.read() { try loadCatalog(saved) }; reply(id, result: catalog == nil ? NSNull() : snapshot()) }
            catch { reply(id, error: "The encrypted library could not be opened. Import it again from Settings.") }
        case "importLibrary": chooseLibrary(id)
        case "play":
            guard let key = payload["id"] as? String else { return reply(id, error: "Missing media identifier.") }
            var raw = media[key]?["url"] as? String ?? payload["url"] as? String ?? ""
            if media[key]?["kind"] as? String == "live" { raw = raw.replacingOccurrences(of: ".ts?", with: ".m3u8?"); if raw.hasSuffix(".ts") { raw = String(raw.dropLast(3)) + ".m3u8" } }
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return reply(id, error: "Unsupported media URL.") }
            let resume = payload["resume"] as? Double ?? 0, token = payload["token"] as? Int ?? 0
            castItem = CastItem(url: url, title: payload["title"] as? String ?? "Airwave", live: (media[key]?["kind"] as? String ?? payload["kind"] as? String) == "live")
            #if os(iOS)
            // With a Cast device already connected, the title plays there instead of on this screen.
            if let item = castItem, cast(item, from: resume) { reply(id, result: true); return emit("native-closed", token: token) }
            #endif
            start(url, resume: resume, token: token)
            reply(id, result: true)
        case "stop": stop(); reply(id, result: true)
        case "toggle": if player?.rate == 0 { player?.play() } else { player?.pause() }; reply(id, result: true)
        case "seek":
            if let p = player, let duration = p.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                let next = max(0, min(duration - 0.5, p.currentTime().seconds + (payload["delta"] as? Double ?? 0)))
                p.seek(to: CMTime(seconds: next, preferredTimescale: 600))
            }
            reply(id, result: true)
        case "fetchText":
            guard let raw = payload["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return reply(id, error: "Unsupported source URL.") }
            let maxBytes = min(payload["max"] as? Int ?? 5_242_880, 10_485_760)
            networkTasks[id] = Task { [weak self] in
                defer { self?.networkTasks.removeValue(forKey: id) }
                do {
                    var request = URLRequest(url: url); request.timeoutInterval = 20
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= maxBytes else { throw URLError(.badServerResponse) }
                    var data = Data(); for try await byte in bytes { if data.count >= maxBytes { throw URLError(.dataLengthExceedsMaximum) }; data.append(byte) }
                    self?.reply(id, result: String(decoding: data, as: UTF8.self))
                } catch { self?.reply(id, error: "The source could not be loaded. Check the URL, connection, and file size.") }
            }
        default: reply(id, error: "Unsupported native action.")
        }
    }
    private func reply(_ id: String, result: Any = NSNull(), error: String? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id, result, error as Any? ?? NSNull()], options: [.fragmentsAllowed]), let args = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__airwaveNativeReply.apply(null,\(args))", completionHandler: nil)
    }
    private func emit(_ event: String, _ value: Any = NSNull(), token: Int? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [event, value, token ?? playToken], options: [.fragmentsAllowed]), let args = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__airwaveNativePlayback && window.__airwaveNativePlayback.apply(null,\(args))", completionHandler: nil)
    }
    private func start(_ url: URL, resume: Double, token: Int) {
        stop(notify: false); playToken = token
        let item = AVPlayerItem(url: url), p = AVPlayer(playerItem: item)
        player = p
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, self.playToken == token, let item else { return }
                if item.status == .failed { self.emit("error", "This stream or codec cannot be played by Apple AVPlayer.", token: token); self.stop(notify: false) }
                else if item.status == .readyToPlay, resume > 0 {
                    // Seek before starting so a resumed movie buffers once, at the saved position.
                    guard item.duration.seconds.isFinite, resume < item.duration.seconds else { self.player?.play(); return }
                    self.player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) { [weak self] _ in
                        Task { @MainActor in if let self, self.playToken == token { self.player?.play() } }
                    }
                }
            }
        }
        playbackObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in guard let self, self.playToken == token else { return }; self.emit(status == .playing ? "playing" : status == .paused ? "paused" : "loading", status == .waitingToPlayAtSpecifiedRate ? "Buffering…" as Any : NSNull(), token: token) }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self, weak p] time in
            Task { @MainActor in
                guard let self, self.playToken == token else { return }
                let duration = p?.currentItem?.duration.seconds ?? 0
                self.emit("time", ["time": time.seconds.isFinite ? time.seconds : 0, "duration": duration.isFinite ? duration : 0], token: token)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playToken == token else { return }; self.emit("ended", token: token); self.stop(notify: false) } }
        if resume <= 0 { p.play() }
    }
    func stop(notify: Bool = true) {
        let oldToken = playToken
        playToken = -1
        if let observer = timeObserver, let p = player { p.removeTimeObserver(observer) }
        timeObserver = nil; statusObserver = nil; playbackObserver = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }; endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if notify { emit("native-closed", token: oldToken) }
    }
    private func loadCatalog(_ data: Data) throws {
        guard data.count <= 100_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["items"] as? [[String: Any]], !items.isEmpty, items.count <= 200_000 else { throw CocoaError(.fileReadCorruptFile) }
        var accepted: [String: [String: Any]] = [:]
        for item in items {
            guard let id = item["id"] as? String, let raw = item["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), item["name"] is String, ["live", "movie"].contains(item["kind"] as? String ?? "") else { continue }
            accepted[id] = item
        }
        guard !accepted.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        catalog = json; media = accepted
    }
    private func snapshot() -> [String: Any] {
        let order = catalog?["items"] as? [[String: Any]] ?? []
        let items = order.compactMap { item -> [String: Any]? in
            guard let id = item["id"] as? String, media[id] != nil else { return nil }
            var safe = item
            safe.removeValue(forKey: "source")
            safe["url"] = "airwave-native://" + id
            // Artwork is optional. Keep the provider URLs entirely in native storage.
            safe["logo"] = ""
            return safe
        }
        return ["version": 2, "private": true, "name": catalog?["name"] as? String ?? "My library", "items": items]
    }
    private func importFile(_ url: URL, replyID: String) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let previousCatalog = catalog, previousMedia = media
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe]); try loadCatalog(data); try store.write(data)
            reply(replyID, result: snapshot())
        } catch { catalog = previousCatalog; media = previousMedia; reply(replyID, error: "This library could not be imported or securely saved. Choose a valid Airwave library JSON file.") }
    }
    private func chooseLibrary(_ id: String) {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in Task { @MainActor in if response == .OK, let url = panel.url { self?.importFile(url, replyID: id) } else { self?.reply(id, error: "Import cancelled.") } } }
        #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        let delegate = ImportDelegate { [weak self] url in if let url { self?.importFile(url, replyID: id) } else { self?.reply(id, error: "Import cancelled.") }; self?.documentDelegate = nil }
        documentDelegate = delegate; picker.delegate = delegate
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return reply(id, error: "File picker unavailable.") }
        root.present(picker, animated: true)
        #endif
    }
}
struct CastItem { let url: URL; let title: String; let live: Bool }

#if os(iOS)
// Casting hands the receiver the item's real URL from native code; JavaScript only ever sees the opaque ID.
// The default media receiver fetches the source itself, so HLS needs the provider to allow cross-origin requests.
enum AirwaveCast {
    static func configure() {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
    }
    static func contentType(_ item: CastItem) -> String {
        if item.live { return "application/x-mpegurl" }
        return ["m3u8": "application/x-mpegurl", "mov": "video/quicktime", "webm": "video/webm", "mkv": "video/x-matroska", "ts": "video/mp2t"][item.url.pathExtension.lowercased()] ?? "video/mp4"
    }
}
struct AirwaveCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton { let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44)); button.tintColor = .white; return button }
    func updateUIView(_ view: GCKUICastButton, context: Context) {}
}
extension AirwaveModel: GCKSessionManagerListener {
    // Connecting while a title plays here moves it to the receiver at the same position.
    nonisolated func sessionManager(_ manager: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in
            guard let item = self.castItem, let p = self.player else { return }
            if self.cast(item, from: p.currentTime().seconds) { self.stop() }
        }
    }
    @discardableResult func cast(_ item: CastItem, from position: Double) -> Bool {
        guard let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient else { return false }
        let metadata = GCKMediaMetadata(metadataType: item.live ? .generic : .movie)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
        let info = GCKMediaInformationBuilder(contentURL: item.url)
        info.streamType = item.live ? .live : .buffered
        info.contentType = AirwaveCast.contentType(item)
        info.metadata = metadata
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = info.build(); request.autoplay = true
        request.startTime = item.live || !position.isFinite ? 0 : position
        client.loadMedia(with: request.build())
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
        return true
    }
}
@MainActor final class ImportDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (URL?) -> Void
    init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
}
#endif

struct PrivateCatalogStore {
    private let service = "app.airwave.private-catalog"
    private func key() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "encryption-key"]
        var result: CFTypeRef?
        var lookup = query; lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw CocoaError(.fileReadNoPermission) }
        let key = SymmetricKey(size: .bits256), data = key.withUnsafeBytes { Data($0) }
        var insert = query; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        return key
    }
    private var file: URL { get throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Airwave", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("library.encrypted")
    } }
    func read() throws -> Data? { let url = try file; guard FileManager.default.fileExists(atPath: url.path) else { return nil }; return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key()) }
    func write(_ data: Data) throws { let sealed = try AES.GCM.seal(data, using: key()); guard let bytes = sealed.combined else { throw CocoaError(.fileWriteUnknown) }; let url = try file; try bytes.write(to: url, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}

#if os(macOS)
struct AirwaveWebView: NSViewRepresentable {
    let model: AirwaveModel
    func makeNSView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.userContentController.add(model, name: "airwave"); let view = WKWebView(frame: .zero, configuration: configuration); model.configure(view); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct AirwaveWebView: UIViewRepresentable {
    let model: AirwaveModel
    func makeUIView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.allowsInlineMediaPlayback = true; configuration.userContentController.add(model, name: "airwave"); let view = WKWebView(frame: .zero, configuration: configuration); view.scrollView.contentInsetAdjustmentBehavior = .never; model.configure(view); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

#if os(macOS)
struct AirwaveVideoView: NSViewRepresentable {
    let player: AVPlayer
    // AirwavePlayerControls replaces the system bar, which has no option to drop its overflow button.
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.player = player; view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white.withAlphaComponent(0.9), for: .normal); view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active); view.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { if view.player !== player { view.player = player } }
}

// Mirrors one AVPlayer for the compact control bar. Commands go straight to the player;
// AirwaveModel's own observers keep reporting playback to the web interface.
@MainActor final class PlaybackState: ObservableObject {
    let player: AVPlayer
    @Published var playing = false
    @Published var ready = false
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var scrub: Double?
    @Published var volume: Float { didSet { player.volume = volume; if volume > 0, muted { muted = false } } }
    @Published var muted: Bool { didSet { player.isMuted = muted } }
    private var timeObserver: Any?
    private var observers: [NSKeyValueObservation] = []
    var live: Bool { !(duration.isFinite && duration > 0) }
    init(player: AVPlayer) {
        self.player = player; volume = player.volume; muted = player.isMuted
        observers.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.playing = playing }
        })
        observers.append(player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] p, _ in
            let ready = p.currentItem?.status == .readyToPlay, duration = p.currentItem?.duration.seconds ?? 0
            Task { @MainActor in self?.ready = ready; self?.duration = duration }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.duration = player.currentItem?.duration.seconds ?? 0
            }
        }
    }
    deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }
    func toggle() { if playing { player.pause() } else { player.play() } }
    func seek(by delta: Double) { if ready, !live { seek(to: time + delta) } }
    func seek(to target: Double) {
        let next = max(0, min(duration - 0.5, target)); time = next; scrub = nil
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600))
    }
}

struct AirwavePlayerControls: View {
    @StateObject private var state: PlaybackState
    @Binding var hovering: Bool
    init(player: AVPlayer, hovering: Binding<Bool>) { _state = StateObject(wrappedValue: PlaybackState(player: player)); _hovering = hovering }
    private var shown: Double { state.scrub ?? state.time }
    private var volumeSymbol: String { state.muted || state.volume == 0 ? "speaker.slash.fill" : state.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill" }
    var body: some View {
        HStack(spacing: 4) {
            ControlButton(symbol: state.playing ? "pause.fill" : "play.fill", label: state.playing ? "Pause" : "Play") { state.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            if state.ready, !state.live {
                ControlButton(symbol: "gobackward.10", label: "Back 10 seconds") { state.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [])
                ControlButton(symbol: "goforward.10", label: "Forward 10 seconds") { state.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [])
                Text(clock(shown)).frame(minWidth: 44, alignment: .trailing)
                ThinTrack(value: shown / state.duration, label: "Position", text: clock(shown),
                          change: { state.scrub = $0 * state.duration }, commit: { state.seek(to: $0 * state.duration) },
                          step: { state.seek(by: $0 * 10) })
                    .frame(width: 220).padding(.horizontal, 6)
                Text("-" + clock(max(0, state.duration - shown))).frame(minWidth: 48, alignment: .leading)
            } else if state.ready {
                HStack(spacing: 6) { Circle().fill(Color.red).frame(width: 6, height: 6); Text("Live") }.padding(.horizontal, 8)
            }
            ControlButton(symbol: volumeSymbol, label: state.muted ? "Unmute" : "Mute") { state.muted.toggle() }
            ThinTrack(value: state.muted ? 0 : Double(state.volume), label: "Volume", text: "\(Int((state.muted ? 0 : state.volume) * 100)) percent",
                      change: { state.volume = Float($0) }, commit: { state.volume = Float($0) },
                      step: { state.volume = max(0, min(1, state.volume + Float($0) * 0.1)) })
                .frame(width: 56).padding(.trailing, 4)
            AirPlayButton(player: state.player).frame(width: 28, height: 28).help("AirPlay").accessibilityLabel("AirPlay")
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .onHover { hovering = $0 }
    }
    private func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0)), h = s / 3600, m = s / 60 % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
    }
}

struct ControlButton: View {
    let symbol: String, label: String, action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0))).contentShape(Circle())
        }
        .buttonStyle(PressStyle()).help(label).accessibilityLabel(label)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// A slim scrubber: the track thickens under the pointer and follows drags from any point.
struct ThinTrack: View {
    let value: Double, label: String, text: String
    let change: (Double) -> Void, commit: (Double) -> Void, step: (Double) -> Void
    @State private var hovering = false
    var body: some View {
        GeometryReader { geo in
            let fraction = { (x: CGFloat) in Double(max(0, min(1, x / max(geo.size.width, 1)))) }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule().fill(.white).frame(width: geo.size.width * max(0, min(1, value.isFinite ? value : 0)))
            }
            .frame(height: hovering ? 6 : 4).frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { change(fraction($0.location.x)) }.onEnded { commit(fraction($0.location.x)) })
        }
        .frame(height: 24)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(text)
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
    }
}
#else
struct AirwaveVideoView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let view = AVPlayerViewController(); view.player = player; return view }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) { if view.player !== player { view.player = player } }
}
#endif

// Video plus Airwave's own chrome. On macOS the chrome hides after a few idle seconds of
// playback and returns on pointer movement; iOS keeps AVPlayerViewController's controls.
struct AirwavePlayerOverlay: View {
    let player: AVPlayer
    let close: () -> Void
    @State private var appeared = false
    @State private var active = true
    @State private var hoveringControls = false
    @State private var started = false
    @State private var waiting = false
    @State private var idle: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let shown = appeared && active
        ZStack {
            Color.black.ignoresSafeArea()
            AirwaveVideoView(player: player).ignoresSafeArea()
            #if os(macOS)
            Color.clear.contentShape(Rectangle()).onTapGesture { wake() }
            if !started || waiting { ProgressView().controlSize(.large).transition(.opacity).allowsHitTesting(false) }
            AirwavePlayerControls(player: player, hovering: $hoveringControls)
                .opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 10).allowsHitTesting(shown)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 24)
            #endif
            HStack(spacing: 12) {
                BackButton(action: close)
                #if os(iOS)
                AirwaveCastButton().frame(width: 44, height: 44)
                #endif
            }
                .opacity(shown ? 1 : 0).offset(x: shown || reduceMotion ? 0 : -10).allowsHitTesting(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        }
        .animation(.easeOut(duration: 0.22), value: shown)
        .onAppear { appeared = true; wake() }
        .onDisappear { idle?.cancel() }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active: wake()
            case .ended: hoveringControls = false; wake(hideAfter: 0.6, hidingCursor: false)
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) { status in
            if status == .playing { started = true }
            waiting = status == .waitingToPlayAtSpecifiedRate; wake()
        }
        #endif
    }
    // A pointer leaving the player hides the chrome sooner than idling over it, and leaves the cursor alone.
    private func wake(hideAfter delay: Double = 2.5, hidingCursor: Bool = true) {
        #if os(macOS)
        active = true; idle?.cancel()
        idle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !hoveringControls, player.timeControlStatus != .paused else { return }
            active = false; if hidingCursor { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        #endif
    }
}

struct BackButton: View {
    let action: () -> Void
    @State private var hovering = false
    #if os(macOS)
    private let size: CGFloat = 36
    #else
    private let size: CGFloat = 44
    #endif
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Circle().fill(Color.black.opacity(hovering ? 0.82 : 0.62))).contentShape(Circle())
        }
        .buttonStyle(PressStyle()).accessibilityLabel("Back to Airwave")
        #if os(macOS)
        .help("Back to Airwave").keyboardShortcut(.cancelAction)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        #endif
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
