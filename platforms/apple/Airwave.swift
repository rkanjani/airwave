import SwiftUI
import Combine
import WebKit
import AVKit
import CryptoKit
import Security
import UniformTypeIdentifiers
import ImageIO
import os
import Libmpv
#if os(iOS)
import GoogleCast
#endif

@main
struct AirwaveApp: App {
    @StateObject private var model = AirwaveModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    init() {
        AirwaveCast.configure()
        // Video keeps its sound with the ring switch on silent, for both engines.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }
    #endif
    var body: some Scene {
        WindowGroup {
            ZStack {
                AirwaveWebView(model: model)
                if let playback = model.playback {
                    AirwavePlayerOverlay(state: playback, favorite: model.favorite, toggleFavorite: { model.toggleFavorite() }) { model.stop() }
                        .id(ObjectIdentifier(playback)).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.playback.map(ObjectIdentifier.init))
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
    @Published var playback: PlaybackState?
    @Published var favorite = false
    weak var webView: WKWebView?
    private var catalog: [String: Any]?
    private var media: [String: [String: Any]] = [:]
    private var playToken = 0
    private var request: PlayRequest?
    private var startDeadline: Task<Void, Never>?
    private var lastTimeEvent = 0.0
    // Titles whose first engine failed this session start straight on the engine that worked.
    private var winners: [String: EngineKind] = [:]
    private var externalPlayback = false
    private var documentDelegate: AnyObject?
    private let store = PrivateCatalogStore()
    private var networkTasks: [String: Task<Void, Never>] = [:]
    private var castItem: CastItem?
    let artwork = ArtworkSchemeHandler()

    func configure(_ view: WKWebView) {
        webView = view
        artwork.lookup = { [weak self] id in
            guard let raw = self?.media[id]?["logo"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
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
            let raw = media[key]?["url"] as? String ?? payload["url"] as? String ?? ""
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return reply(id, error: "Unsupported media URL.") }
            let next = PlayRequest(key: key, url: url, live: (media[key]?["kind"] as? String ?? payload["kind"] as? String) == "live",
                                   resume: payload["resume"] as? Double ?? 0, token: payload["token"] as? Int ?? 0)
            favorite = payload["favorite"] as? Bool ?? false
            // Cast receivers take HLS, so live channels go out in the form AVPlayer uses.
            castItem = CastItem(url: next.url(for: .avplayer), title: payload["title"] as? String ?? "Airwave", live: next.live)
            #if os(iOS)
            // With a Cast device already connected, the title plays there instead of on this screen.
            if let item = castItem, cast(item, from: next.resume) { reply(id, result: true); return emit("native-closed", token: next.token) }
            #endif
            start(next)
            reply(id, result: true)
        case "stop": stop(); reply(id, result: true)
        case "clearArtwork": artwork.clear(); reply(id, result: true)
        case "toggle": playback?.toggle(); reply(id, result: true)
        case "seek": playback?.seek(by: payload["delta"] as? Double ?? 0); reply(id, result: true)
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
    // Favorites live in the web interface's storage; the overlay flips its copy and reports the new state.
    func toggleFavorite() { favorite.toggle(); emit("favorite", favorite) }
    private func reply(_ id: String, result: Any = NSNull(), error: String? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id, result, error as Any? ?? NSNull()], options: [.fragmentsAllowed]), let args = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__airwaveNativeReply.apply(null,\(args))", completionHandler: nil)
    }
    private func emit(_ event: String, _ value: Any = NSNull(), token: Int? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [event, value, token ?? playToken], options: [.fragmentsAllowed]), let args = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__airwaveNativePlayback && window.__airwaveNativePlayback.apply(null,\(args))", completionHandler: nil)
    }
    private func start(_ next: PlayRequest) {
        stop(notify: false); playToken = next.token; request = next
        begin(winners[next.key] ?? PlaybackPolicy.engine(for: next, externalRoute: externalRouteActive), fallback: false)
    }
    private func begin(_ kind: EngineKind, fallback: Bool) {
        guard let request else { return }
        let engine: any PlaybackEngine = kind == .mpv ? MPVEngine() : AVPlayerEngine()
        let state: PlaybackState
        if fallback, let current = playback { current.use(engine); state = current } else { state = PlaybackState(engine: engine, live: request.live); playback = state }
        let began = PlaybackTiming.now, token = request.token
        state.forward = { [weak self] event in self?.handle(event, from: kind, began: began, fallback: fallback, token: token) }
        startDeadline?.cancel()
        // mpv starts a raw live channel in about a second, so a first mpv attempt that shows nothing for
        // a while hands over to AVPlayer. AVPlayer goes first only for HLS and Apple containers, where mpv
        // was measured slower on the same URL, so it gets no deadline; nor does any fallback.
        if !fallback, kind == .mpv {
            let limit: UInt64 = request.live ? 8 : 15
            startDeadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: limit * 1_000_000_000)
                guard !Task.isCancelled, let self, self.playToken == token, self.playback?.started == false else { return }
                self.retry(from: kind, result: "timeout", began: began)
            }
        }
        engine.load(request.url(for: kind), resume: request.resume)
    }
    private func handle(_ event: EngineEvent, from kind: EngineKind, began: Double, fallback: Bool, token: Int) {
        guard playToken == token, let request else { return }
        switch event {
        case .firstFrame:
            startDeadline?.cancel()
            if fallback { winners[request.key] = kind }
            PlaybackTiming.record(kind, request, attempt: fallback ? 2 : 1, result: "first-frame", since: began)
        case .failed(let reason):
            if playback?.started == false, !fallback { return retry(from: kind, result: "failed", began: began, detail: reason) }
            PlaybackTiming.record(kind, request, attempt: fallback ? 2 : 1, result: "failed", since: began, detail: reason)
            emit("error", "This stream or codec can't be played on this device.", token: token); stop(notify: false)
        case .ended: emit("ended", token: token); stop(notify: false)
        case .status(let playing, let waiting):
            emit(waiting ? "loading" : playing ? "playing" : "paused", waiting ? "Buffering…" as Any : NSNull(), token: token)
        case .time(let time, let duration):
            guard PlaybackTiming.now - lastTimeEvent >= 0.95 else { return }
            lastTimeEvent = PlaybackTiming.now
            emit("time", ["time": time, "duration": duration], token: token)
        case .externalPlayback(let active): externalPlayback = active
        }
    }
    private func retry(from kind: EngineKind, result: String, began: Double, detail: String? = nil) {
        guard let request else { return }
        PlaybackTiming.record(kind, request, attempt: 1, result: result, since: began, detail: detail)
        emit("loading", "Trying another player…", token: request.token)
        begin(kind.other, fallback: true)
    }
    // AirPlay needs AVPlayer: the route is in use, or the last AVPlayer title was playing on it.
    private var externalRouteActive: Bool {
        #if os(iOS)
        if AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) { return true }
        #endif
        return externalPlayback
    }
    func stop(notify: Bool = true) {
        let oldToken = playToken
        playToken = -1; request = nil
        startDeadline?.cancel(); startDeadline = nil
        playback?.close(); playback = nil
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
            // Artwork is optional. The web view gets an opaque artwork ID; provider URLs stay in native storage.
            safe["logo"] = artwork.lookup(id) != nil ? ArtworkSchemeHandler.address(id) : ""
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
            guard let item = self.castItem, let playback = self.playback else { return }
            if self.cast(item, from: playback.time) { self.stop() }
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

// Tile artwork for the web view: airwave-art://logo/<id> resolves to the catalog's image in native code.
// Images are downsampled once and kept in Caches; failures are remembered for a day.
@MainActor final class ArtworkSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "airwave-art"
    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func address(_ id: String) -> String { scheme + "://logo/" + (id.addingPercentEncoding(withAllowedCharacters: idCharacters) ?? "") }
    var lookup: (String) -> URL? = { _ in nil }
    private let cache = ArtworkCache()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard let url = task.request.url, url.host == "logo", case let id = String(url.path.dropFirst()), let source = lookup(id) else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        tasks[key] = Task { [weak self] in
            let image = await self?.cache.image(id: id, source: source)
            // A stopped task must not be answered.
            guard let self, self.tasks.removeValue(forKey: key) != nil else { return }
            guard let image else { return task.didFailWithError(URLError(.cannotDecodeContentData)) }
            task.didReceive(URLResponse(url: url, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil))
            task.didReceive(image.data)
            task.didFinish()
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel() }
    func clear() { Task { await cache.clear() } }
}
actor ArtworkCache {
    struct Image { let data: Data; let mime: String }
    private let maxSource = 4_000_000, maxFolder = 200_000_000, fresh: TimeInterval = 7 * 86_400, failFor: TimeInterval = 86_400
    private var pending: [String: Task<Image?, Never>] = [:]
    private var pruned = false
    private var folder: URL? { try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Airwave/Artwork", isDirectory: true) }
    func image(id: String, source: URL) async -> Image? {
        let name = SHA256.hash(data: Data((id + "\n" + source.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
        if let job = pending[name] { return await job.value }
        let job = Task { await load(name, source) }
        pending[name] = job
        let image = await job.value
        pending[name] = nil
        return image
    }
    func clear() { if let folder { try? FileManager.default.removeItem(at: folder) } }
    private func load(_ name: String, _ source: URL) async -> Image? {
        guard let folder else { return nil }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        if !pruned { pruned = true; prune(folder) }
        let png = folder.appendingPathComponent(name + ".png"), jpg = folder.appendingPathComponent(name + ".jpg"), miss = folder.appendingPathComponent(name + ".miss")
        let saved = [png, jpg].first { files.fileExists(atPath: $0.path) }.flatMap { url in (try? Data(contentsOf: url)).map { Image(data: $0, mime: url.pathExtension == "png" ? "image/png" : "image/jpeg") } }
        if let saved, let file = [png, jpg].first(where: { files.fileExists(atPath: $0.path) }), age(file) < fresh { return saved }
        if age(miss) < failFor { return saved }
        do {
            var request = URLRequest(url: source); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= maxSource, let image = Self.downsample(data) else { throw URLError(.cannotDecodeContentData) }
            for file in [png, jpg, miss] { try? files.removeItem(at: file) }
            try? image.data.write(to: image.mime == "image/png" ? png : jpg, options: .atomic)
            return image
        } catch {
            files.createFile(atPath: miss.path, contents: nil)
            return saved
        }
    }
    private func age(_ url: URL) -> TimeInterval { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity }
    // Tiles are at most about 480 px at 2x; logos with transparency stay PNG.
    private static func downsample(_ data: Data) -> Image? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, (alpha ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Image(data: out as Data, mime: alpha ? "image/png" : "image/jpeg")
    }
    // Keep the folder under its cap by dropping the least recently written images.
    private func prune(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        while total > maxFolder * 4 / 5, !entries.isEmpty { let (url, size, _) = entries.removeFirst(); try? FileManager.default.removeItem(at: url); total -= size }
    }
}

// Playback engines. AVPlayer plays what Apple decodes natively and can route to AirPlay; mpv (libmpv
// with FFmpeg, from MPVKit) plays raw MPEG-TS live channels and containers AVPlayer rejects.
// AirwaveModel and the controls see only this protocol, so the bridge contract is engine-agnostic.
enum EngineKind: String {
    case avplayer = "AVPlayer", mpv
    var other: EngineKind { self == .mpv ? .avplayer : .mpv }
}
enum EngineEvent {
    case status(playing: Bool, waiting: Bool), firstFrame, time(Double, Double), ended, failed(String), externalPlayback(Bool)
}
@MainActor protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    var onEvent: (EngineEvent) -> Void { get set }
    var time: Double { get }
    var duration: Double { get }
    var volume: Float { get set }
    var muted: Bool { get set }
    func load(_ url: URL, resume: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func close()
}
private func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

struct PlayRequest {
    let key: String, url: URL, live: Bool, resume: Double, token: Int
    let requested = PlaybackTiming.now
    // Live providers that serve raw MPEG-TS usually publish the same channel as HLS at .m3u8; AVPlayer needs that form.
    func url(for engine: EngineKind) -> URL {
        guard engine == .avplayer, live else { return url }
        var raw = url.absoluteString.replacingOccurrences(of: ".ts?", with: ".m3u8?")
        if raw.hasSuffix(".ts") { raw = String(raw.dropLast(3)) + ".m3u8" }
        return URL(string: raw) ?? url
    }
}

enum PlaybackPolicy {
    static let appleContainers: Set<String> = ["m3u8", "mp4", "m4v", "mov"]
    // HLS and Apple movie containers use AVPlayer (hardware decode, battery, AirPlay), as do finite .ts
    // movies, which it opens faster than mpv. AVPlayer refuses an unbounded MPEG-TS stream, so live
    // channels given as raw .ts or with no extension start on mpv, like MKV, AVI and other containers.
    static func engine(for request: PlayRequest, externalRoute: Bool) -> EngineKind {
        let ext = request.url.pathExtension.lowercased()
        if externalRoute || appleContainers.contains(ext) || (!request.live && ext == "ts") { return .avplayer }
        return .mpv
    }
}

// Opt-in start-up timing, from play request to first frame (playhead movement), per engine and attempt.
// Enable with the launch argument `-AirwavePlaybackTiming YES` (or `defaults write`), or AIRWAVE_PLAYBACK_TIMING=1,
// and read it with `log stream --predicate 'subsystem == "app.airwave"'`. Lines never contain URLs.
enum PlaybackTiming {
    static let enabled = UserDefaults.standard.bool(forKey: "AirwavePlaybackTiming") || ProcessInfo.processInfo.environment["AIRWAVE_PLAYBACK_TIMING"] == "1"
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static let log = Logger(subsystem: "app.airwave", category: "playback")
    static func container(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["m3u8", "ts", "mp4", "m4v", "mov", "mkv", "avi", "webm"].contains(ext) ? ext : ext.isEmpty ? "none" : "other"
    }
    static func record(_ engine: EngineKind, _ request: PlayRequest, attempt: Int, result: String, since began: Double, detail: String? = nil) {
        guard enabled else { return }
        var line = "engine=\(engine.rawValue) kind=\(request.live ? "live" : "movie") container=\(container(request.url(for: engine))) attempt=\(attempt) result=\(result)"
        line += String(format: " attempt-s=%.2f total-s=%.2f", now - began, now - request.requested)
        if let detail { line += " detail=\(detail)" }
        log.notice("\(line, privacy: .public)")
    }
}

@MainActor final class AVPlayerEngine: PlaybackEngine {
    let kind = EngineKind.avplayer
    let player = AVPlayer()
    var onEvent: (EngineEvent) -> Void = { _ in }
    private var observers: [NSKeyValueObservation] = []
    private var notices: [NSObjectProtocol] = []
    private var ticker: Any?
    private var probe: Any?
    private var baseline: Double?
    private var started = false
    private var resolving: Task<Void, Never>?
    var time: Double { finite(player.currentTime().seconds) }
    var duration: Double { finite(player.currentItem?.duration.seconds ?? 0) }
    var volume: Float { get { player.volume } set { player.volume = newValue } }
    var muted: Bool { get { player.isMuted } set { player.isMuted = newValue } }
    func load(_ url: URL, resume: Double) {
        resolving = Task { [weak self] in
            let source = await RedirectResolver.resolve(url)
            guard !Task.isCancelled, let self else { return }
            self.attach(source, resume: resume)
        }
    }
    private func attach(_ url: URL, resume: Double) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status, code = (item.error as NSError?)?.code ?? 0
                Task { @MainActor in self?.itemChanged(status, code: code, resume: resume) }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                let status = p.timeControlStatus
                Task { @MainActor in self?.onEvent(.status(playing: status != .paused, waiting: status == .waitingToPlayAtSpecifiedRate)) }
            },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
                let active = p.isExternalPlaybackActive
                Task { @MainActor in self?.onEvent(.externalPlayback(active)) }
            },
        ]
        notices = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onEvent(.ended) }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let code = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.code ?? 0
                Task { @MainActor in self?.onEvent(.failed("AVFoundation \(code)")) }
            },
        ]
        // Playhead movement marks the first frame: timeControlStatus can report .playing before anything is shown.
        probe = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 50), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.advance(seconds) }
        }
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { self.onEvent(.time(self.time, self.duration)) } }
        }
        if resume <= 0 { player.play() }
    }
    private func itemChanged(_ status: AVPlayerItem.Status, code: Int, resume: Double) {
        if status == .failed { return onEvent(.failed("AVFoundation \(code)")) }
        guard status == .readyToPlay, resume > 0 else { return }
        // Seek before starting so a resumed movie buffers once, at the saved position.
        guard duration > 0, resume < duration else { return player.play() }
        player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) { [weak self] _ in Task { @MainActor in self?.player.play() } }
    }
    private func advance(_ seconds: Double) {
        guard !started, seconds.isFinite, player.timeControlStatus == .playing else { return }
        guard let baseline else { baseline = seconds; return }
        guard seconds > baseline + 0.01 else { return }
        started = true
        if let probe { player.removeTimeObserver(probe); self.probe = nil }
        onEvent(.firstFrame)
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func close() {
        resolving?.cancel(); resolving = nil
        onEvent = { _ in }
        observers.forEach { $0.invalidate() }; observers = []
        notices.forEach { NotificationCenter.default.removeObserver($0) }; notices = []
        for observer in [probe, ticker].compactMap({ $0 }) { player.removeTimeObserver(observer) }
        probe = nil; ticker = nil
        player.pause(); player.replaceCurrentItem(with: nil)
    }
}

// Providers often answer a channel URL with a 302 to a session host, and AVPlayer requests an HLS playlist
// twice while starting, paying that redirect and a new connection each time; later refreshes already use the
// target. Following the redirect once here and handing AVPlayer the target saves one of those legs. Hosts that
// answered directly are remembered for the session so they skip the check. Any failure keeps the original URL.
@MainActor enum RedirectResolver {
    private static var direct: Set<String> = []
    private final class StopAtRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let session = URLSession(configuration: .ephemeral)
    static func resolve(_ url: URL) async -> URL {
        guard let host = url.host?.lowercased(), !direct.contains(host) else { return url }
        var request = URLRequest(url: url); request.timeoutInterval = 3
        guard let answer = try? await session.bytes(for: request, delegate: StopAtRedirect()) else { return url }
        answer.0.task.cancel()
        // One hop: checking the target for another redirect would cost the full request this saves.
        guard let http = answer.1 as? HTTPURLResponse, (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url)?.absoluteURL,
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { direct.insert(host); return url }
        return target
    }
}

// MoltenVK briefly shrinks the drawable to 1×1 to force a presentation; ignoring that avoids flicker (mpv-player/mpv#13651).
final class MPVLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}
// Carries mpv's wakeup callback to the main actor without retaining the engine.
private final class MPVRelay: @unchecked Sendable { weak var engine: MPVEngine? }

// libmpv renders with gpu-next through MoltenVK into a CAMetalLayer and decodes with VideoToolbox when it can.
@MainActor final class MPVEngine: PlaybackEngine {
    let kind = EngineKind.mpv
    let layer = MPVLayer()
    var onEvent: (EngineEvent) -> Void = { _ in }
    private(set) var time = 0.0
    private(set) var duration = 0.0
    var volume: Float = 1 { didSet { set("volume", Double(volume) * 100) } }
    var muted = false { didSet { set("mute", muted) } }
    private var handle: OpaquePointer?
    private let relay = MPVRelay()
    private var paused = false, buffering = false, started = false
    private var baseline: Double?
    private var lastTick = 0.0
    // Start-up favours live channels: no config or ytdl probing, hardware decode, and a 0.5 s stream
    // analysis (median raw-TS start 1.00 s → 0.85 s in testing, with fewer slow joins).
    static var options: [(String, String)] = [
        ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"),
        ("config", "no"), ("ytdl", "no"), ("terminal", "no"), ("input-default-bindings", "no"), ("input-media-keys", "no"),
        ("idle", "yes"), ("keep-open", "no"), ("network-timeout", "20"), ("demuxer-lavf-analyzeduration", "0.5"),
        // mpv's built-in scripts are Lua, and LuaJIT writes executable memory, which the hardened runtime
        // kills (OS_REASON_CODESIGNING) in any signed build. Airwave draws its own controls, so none are needed.
        ("load-scripts", "no"), ("osc", "no"), ("load-stats-overlay", "no"), ("load-console", "no"), ("load-osd-console", "no"),
        ("load-auto-profiles", "no"), ("load-select", "no"), ("load-positioning", "no"), ("load-commands", "no"), ("load-context-menu", "no"),
    ]
    init() {
        // MoltenVK otherwise prints its device report to the console for every new player.
        setenv("MVK_CONFIG_LOG_LEVEL", "1", 0)
        layer.framebufferOnly = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        guard let h = mpv_create() else { return }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in Self.options { mpv_set_option_string(h, name, value) }
        guard mpv_initialize(h) >= 0 else { mpv_terminate_destroy(h); return }
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG)] {
            mpv_observe_property(h, 0, name, format)
        }
        handle = h; relay.engine = self
        mpv_set_wakeup_callback(h, { context in
            guard let context else { return }
            let relay = Unmanaged<MPVRelay>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in relay.engine?.drain() }
        }, Unmanaged.passRetained(relay).toOpaque())
    }
    func load(_ url: URL, resume: Double) {
        guard handle != nil else { return onEvent(.failed("mpv unavailable")) }
        command(["loadfile", url.absoluteString, "replace", "-1"] + (resume > 0 ? ["start=\(resume)"] : []))
        status()
    }
    func play() { set("pause", false) }
    func pause() { set("pause", true) }
    func seek(to seconds: Double) { command(["seek", String(seconds), "absolute"]) }
    func close() {
        onEvent = { _ in }
        guard let h = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(h, nil, nil)
        let relay = relay, layer = layer
        // Teardown waits for mpv's threads; the layer stays alive until its renderer is gone.
        DispatchQueue.global(qos: .utility).async {
            withExtendedLifetime(layer) { mpv_terminate_destroy(h) }
            Unmanaged.passUnretained(relay).release()
        }
    }
    fileprivate func drain() {
        while let h = handle, let event = mpv_wait_event(h, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee { update(String(cString: property.name), property) }
            case MPV_EVENT_END_FILE:
                guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { continue }
                if end.reason == MPV_END_FILE_REASON_ERROR { onEvent(.failed("mpv " + String(cString: mpv_error_string(end.error)))) }
                else if end.reason == MPV_END_FILE_REASON_EOF { onEvent(.ended) }
            default: continue
            }
        }
    }
    private func update(_ name: String, _ property: mpv_event_property) {
        let number = property.format == MPV_FORMAT_DOUBLE ? property.data?.assumingMemoryBound(to: Double.self).pointee : nil
        let flag = property.format == MPV_FORMAT_FLAG ? property.data?.assumingMemoryBound(to: Int32.self).pointee != 0 : nil
        switch name {
        case "time-pos":
            guard let number else { return }
            time = number
            // Same first-frame rule as AVPlayer: the playhead has moved past its first reported position.
            if !started, !paused {
                if let baseline { if number > baseline + 0.01 { started = true; onEvent(.firstFrame); status() } } else { baseline = number }
            }
            if PlaybackTiming.now - lastTick >= 0.25 { lastTick = PlaybackTiming.now; onEvent(.time(time, duration)) }
        case "duration": duration = finite(number ?? 0)
        case "pause": paused = flag ?? false; status()
        case "paused-for-cache": buffering = flag ?? false; status()
        default: break
        }
    }
    private func status() { onEvent(.status(playing: !paused, waiting: buffering || !started)) }
    private func command(_ args: [String]) {
        guard let handle else { return }
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(handle, &cargs)
    }
    private func set(_ name: String, _ value: Double) { guard let handle else { return }; var value = value; mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &value) }
    private func set(_ name: String, _ flag: Bool) { guard let handle else { return }; var value: Int32 = flag ? 1 : 0; mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value) }
}

// One playback session for the overlay and controls. It mirrors the active engine, keeps volume
// across a fallback swap, and forwards every event to AirwaveModel for the web interface.
@MainActor final class PlaybackState: ObservableObject {
    @Published private(set) var engine: any PlaybackEngine
    @Published private(set) var playing = false
    @Published private(set) var waiting = false
    @Published private(set) var started = false
    @Published private(set) var time = 0.0
    @Published private(set) var duration = 0.0
    @Published var scrub: Double?
    @Published var volume: Float = 1 { didSet { engine.volume = volume; if volume > 0, muted { muted = false } } }
    @Published var muted = false { didSet { engine.muted = muted } }
    var forward: (EngineEvent) -> Void = { _ in }
    private let liveHint: Bool
    var live: Bool { liveHint || !(duration.isFinite && duration > 0) }
    init(engine: any PlaybackEngine, live: Bool) { self.engine = engine; liveHint = live; attach() }
    func use(_ next: any PlaybackEngine) {
        engine.close(); engine = next
        playing = false; waiting = false; started = false; time = 0; duration = 0; scrub = nil
        attach()
    }
    private func attach() {
        engine.volume = volume; engine.muted = muted
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }
    private func handle(_ event: EngineEvent) {
        switch event {
        case .status(let playing, let waiting): self.playing = playing; self.waiting = waiting
        case .firstFrame: started = true
        case .time(let time, let duration): self.time = time; self.duration = duration
        default: break
        }
        forward(event)
    }
    func toggle() { if playing { engine.pause() } else { engine.play() } }
    func seek(by delta: Double) { if started, !live { seek(to: time + delta) } }
    func seek(to target: Double) {
        let next = max(0, min(duration - 0.5, target)); time = next; scrub = nil
        engine.seek(to: next)
    }
    func close() { forward = { _ in }; engine.close() }
}

#if os(macOS)
struct AirwaveWebView: NSViewRepresentable {
    let model: AirwaveModel
    func makeNSView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.setURLSchemeHandler(model.artwork, forURLScheme: ArtworkSchemeHandler.scheme); configuration.userContentController.add(model, name: "airwave"); let view = WKWebView(frame: .zero, configuration: configuration); model.configure(view); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct AirwaveWebView: UIViewRepresentable {
    let model: AirwaveModel
    func makeUIView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.allowsInlineMediaPlayback = true; configuration.setURLSchemeHandler(model.artwork, forURLScheme: ArtworkSchemeHandler.scheme); configuration.userContentController.add(model, name: "airwave"); let view = WKWebView(frame: .zero, configuration: configuration); view.scrollView.contentInsetAdjustmentBehavior = .never; model.configure(view); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

// The surface for whichever engine is active: the AVPlayer view, or mpv's Metal layer.
struct AirwaveVideoView: View {
    let engine: any PlaybackEngine
    var body: some View {
        if let av = engine as? AVPlayerEngine { AVPlayerSurface(player: av.player) }
        else if let mpv = engine as? MPVEngine { MetalSurface(layer: mpv.layer) }
    }
}

#if os(macOS)
struct AVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    // AirwavePlayerControls replaces the system bar, which has no option to drop its overflow button.
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
final class MetalHostView: NSView {
    private let metal: CAMetalLayer
    init(_ layer: CAMetalLayer) { metal = layer; super.init(frame: .zero); self.layer = layer; wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
}
struct MetalSurface: NSViewRepresentable {
    let layer: CAMetalLayer
    func makeNSView(context: Context) -> MetalHostView { MetalHostView(layer) }
    func updateNSView(_ view: MetalHostView, context: Context) {}
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
#else
struct AVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let view = AVPlayerViewController(); view.player = player; return view }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) { if view.player !== player { view.player = player } }
}
final class MetalHostView: UIView {
    private let metal: CAMetalLayer
    init(_ layer: CAMetalLayer) { metal = layer; super.init(frame: .zero); backgroundColor = .black; self.layer.addSublayer(layer) }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? 3
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metal.frame = bounds; metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}
struct MetalSurface: UIViewRepresentable {
    let layer: CAMetalLayer
    func makeUIView(context: Context) -> MetalHostView { MetalHostView(layer) }
    func updateUIView(_ view: MetalHostView, context: Context) {}
}
#endif

#if os(macOS)
private let chromeButton: CGFloat = 28, chromeBar: CGFloat = 40
#else
private let chromeButton: CGFloat = 44, chromeBar: CGFloat = 52
#endif

// Compact control bar, driven through PlaybackState for either engine. macOS always uses it; on iOS
// it stands in for AVPlayerViewController's controls while mpv plays, without volume (the hardware
// buttons set it) or AirPlay (an AVPlayer feature).
struct AirwavePlayerControls: View {
    @ObservedObject var state: PlaybackState
    @Binding var hovering: Bool
    private var shown: Double { state.scrub ?? state.time }
    private var volumeSymbol: String { state.muted || state.volume == 0 ? "speaker.slash.fill" : state.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill" }
    var body: some View {
        HStack(spacing: 4) {
            ControlButton(symbol: state.playing ? "pause.fill" : "play.fill", label: state.playing ? "Pause" : "Play") { state.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            if state.started, !state.live {
                ControlButton(symbol: "gobackward.10", label: "Back 10 seconds") { state.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [])
                ControlButton(symbol: "goforward.10", label: "Forward 10 seconds") { state.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [])
                Text(clock(shown)).frame(minWidth: 44, alignment: .trailing)
                ThinTrack(value: shown / state.duration, label: "Position", text: clock(shown),
                          change: { state.scrub = $0 * state.duration }, commit: { state.seek(to: $0 * state.duration) },
                          step: { state.seek(by: $0 * 10) })
                    #if os(macOS)
                    .frame(width: 220)
                    #else
                    .frame(maxWidth: .infinity)
                    #endif
                    .padding(.horizontal, 6)
                Text("-" + clock(max(0, state.duration - shown))).frame(minWidth: 48, alignment: .leading)
            } else if state.started {
                HStack(spacing: 6) { Circle().fill(Color.red).frame(width: 6, height: 6); Text("Live") }.padding(.horizontal, 8)
            }
            #if os(macOS)
            ControlButton(symbol: volumeSymbol, label: state.muted ? "Unmute" : "Mute") { state.muted.toggle() }
            ThinTrack(value: state.muted ? 0 : Double(state.volume), label: "Volume", text: "\(Int((state.muted ? 0 : state.volume) * 100)) percent",
                      change: { state.volume = Float($0) }, commit: { state.volume = Float($0) },
                      step: { state.volume = max(0, min(1, state.volume + Float($0) * 0.1)) })
                .frame(width: 56).padding(.trailing, 4)
            if let av = state.engine as? AVPlayerEngine {
                AirPlayButton(player: av.player).frame(width: 28, height: 28).help("AirPlay").accessibilityLabel("AirPlay")
            }
            #endif
        }
        #if os(macOS)
        .font(.system(size: 12, weight: .medium))
        #else
        .font(.system(size: 14, weight: .medium))
        #endif
        .monospacedDigit().foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: chromeBar)
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
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: chromeButton, height: chromeButton)
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
        .frame(height: max(24, chromeButton))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(text)
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
    }
}

// Video plus Airwave's own chrome. With Airwave's controls (macOS, and mpv on iOS) the chrome hides
// after a few idle seconds of playback and returns on pointer movement or a tap; iOS AVPlayer titles
// keep AVPlayerViewController's controls.
struct AirwavePlayerOverlay: View {
    @ObservedObject var state: PlaybackState
    let favorite: Bool
    let toggleFavorite: () -> Void
    let close: () -> Void
    @State private var appeared = false
    @State private var active = true
    @State private var hoveringControls = false
    @State private var idle: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ownControls: Bool {
        #if os(macOS)
        true
        #else
        !(state.engine is AVPlayerEngine)
        #endif
    }
    var body: some View {
        let shown = appeared && active
        ZStack {
            Color.black.ignoresSafeArea()
            AirwaveVideoView(engine: state.engine).id(ObjectIdentifier(state.engine)).ignoresSafeArea()
            if ownControls {
                Color.clear.contentShape(Rectangle()).onTapGesture { tapped() }
                if !state.started || state.waiting { ProgressView().controlSize(.large).tint(.white).transition(.opacity).allowsHitTesting(false) }
                AirwavePlayerControls(state: state, hovering: $hoveringControls)
                    #if os(iOS)
                    .frame(maxWidth: 560).padding(.horizontal, 16)
                    #endif
                    .opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 10).allowsHitTesting(shown)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 24)
            }
            HStack(spacing: 12) {
                OverlayButton(symbol: "chevron.left", label: "Back to Airwave", action: close)
                    #if os(macOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
                #if os(iOS)
                AirwaveCastButton().frame(width: 44, height: 44)
                #endif
                Spacer()
                OverlayButton(symbol: favorite ? "heart.fill" : "heart", label: favorite ? "Remove from favorites" : "Add to favorites", action: toggleFavorite)
            }
                .opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : -8).allowsHitTesting(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(20)
        }
        .animation(.easeOut(duration: 0.22), value: shown)
        .onAppear { appeared = true; wake() }
        .onDisappear { idle?.cancel() }
        .onChange(of: state.playing) { _ in wake() }
        .onChange(of: state.waiting) { _ in wake() }
        .onChange(of: state.started) { _ in wake() }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active: wake()
            case .ended: hoveringControls = false; wake(hideAfter: 0.6, hidingCursor: false)
            }
        }
        #endif
    }
    private func tapped() {
        #if os(iOS)
        if active, state.playing { idle?.cancel(); active = false; return }
        #endif
        wake()
    }
    // A pointer leaving the player hides the chrome sooner than idling over it, and leaves the cursor alone.
    private func wake(hideAfter delay: Double = 2.5, hidingCursor: Bool = true) {
        active = true; idle?.cancel()
        guard ownControls else { return }
        idle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !hoveringControls, state.playing, state.started else { return }
            active = false
            #if os(macOS)
            if hidingCursor { NSCursor.setHiddenUntilMouseMoves(true) }
            #endif
        }
    }
}

struct OverlayButton: View {
    let symbol: String, label: String, action: () -> Void
    @State private var hovering = false
    #if os(macOS)
    private let size: CGFloat = 36
    #else
    private let size: CGFloat = 44
    #endif
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Circle().fill(Color.black.opacity(hovering ? 0.82 : 0.62))).contentShape(Circle())
        }
        .buttonStyle(PressStyle()).accessibilityLabel(label)
        #if os(macOS)
        .help(label)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        #endif
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
