#if os(tvOS)
import SwiftUI
import AVKit
import MediaPlayer
import JavaScriptCore
import Security
import CryptoKit

// Airwave for Apple TV. tvOS has no WebKit, so this is a native ten-foot interface over the same pieces the other
// Apple apps use: the encrypted catalog store, the AVPlayer/mpv engines with one-time fallback, the artwork cache,
// and app/core.js (run in JavaScriptCore) for playlist parsing, Tidy names and spoken-title matching.
// Voice: every text field and the Search tab use the system keyboard, so holding the Siri Remote's mic dictates into
// them; while a title plays, Siri's playback requests (pause, skip ahead, next channel) reach the active engine.
@main
struct AirwaveTVApp: App {
    @StateObject private var library = TVLibrary()
    @StateObject private var player = TVPlayer()
    @Environment(\.scenePhase) private var scenePhase
    init() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environmentObject(library).environmentObject(player)
                .preferredColorScheme(.dark)
                .onAppear { player.library = library }
                .onChange(of: scenePhase) { _, phase in if phase == .background { player.stop() } }
        }
    }
}

// MARK: - Shared logic from app/core.js

// core.js runs unchanged; JavaScriptCore has no URL class, so Foundation resolves URLs for its httpUrl().
@MainActor final class SharedCore {
    static let shared = SharedCore()
    private let context = JSContext()
    private var failure: String?
    private init() {
        guard let context else { return }
        context.exceptionHandler = { [weak self] _, error in self?.failure = error?.toString() }
        let resolve: @convention(block) (String, JSValue) -> Any = { value, base in
            let relative = base.isString ? URL(string: base.toString()) : nil
            guard let url = URL(string: value.trimmingCharacters(in: .whitespaces), relativeTo: relative)?.absoluteURL, let scheme = url.scheme else { return NSNull() }
            return ["href": url.absoluteString, "protocol": scheme.lowercased() + ":"]
        }
        context.setObject(resolve, forKeyedSubscript: "__airwaveResolveURL" as NSString)
        context.evaluateScript("var URL=function(v,b){var r=__airwaveResolveURL(String(v),b===undefined||b===null?null:String(b));if(!r)throw new TypeError('Invalid URL');this.href=r.href;this.protocol=r.protocol;};")
        if let url = Bundle.main.url(forResource: "core", withExtension: "js", subdirectory: "app"), let source = try? String(contentsOf: url, encoding: .utf8) { context.evaluateScript(source, withSourceURL: url) }
        context.evaluateScript("""
        function __tidyAll(list){return list.map(function(x){var t=AirwaveCore.tidyName(x.name,{group:x.group,kind:x.kind});return [t.name,t.quality,t.tags];});}
        var __index=[];function __setIndex(list){__index=list;}
        function __search(q){var out=[];for(var i=0;i<__index.length;i++)if(AirwaveCore.matchesQuery(__index[i],q))out.push(i);return out;}
        function __match(list,phrase){var hit=AirwaveCore.matchSpoken(list,phrase,function(x){return x.shown;});return hit?list.indexOf(hit):-1;}
        """)
    }
    private func call(_ name: String, _ args: [Any]) throws -> JSValue? {
        failure = nil
        let value = context?.objectForKeyedSubscript(name)?.call(withArguments: args)
        if let failure { throw TVError(failure.replacingOccurrences(of: "Error: ", with: "")) }
        return value
    }
    func parseM3U(_ text: String, base: URL?) throws -> [[String: Any]] {
        failure = nil
        let core = context?.objectForKeyedSubscript("AirwaveCore")
        let value = core?.invokeMethod("parseM3U", withArguments: [text, base.map { $0.absoluteString as Any } ?? NSNull()])
        if let failure { throw TVError(failure.replacingOccurrences(of: "Error: ", with: "")) }
        return value?.toArray() as? [[String: Any]] ?? []
    }
    func tidy(_ items: [(name: String, group: String, kind: String)]) -> [(String, String, [String])] {
        let list = items.map { ["name": $0.name, "group": $0.group, "kind": $0.kind] }
        guard let rows = (try? call("__tidyAll", [list]))?.toArray() as? [[Any]], rows.count == items.count else { return items.map { ($0.name, "", []) } }
        return rows.map { ($0[0] as? String ?? "", $0[1] as? String ?? "", $0[2] as? [String] ?? []) }
    }
    func tidyGroups(_ groups: [String]) -> [String: String] {
        failure = nil
        return context?.objectForKeyedSubscript("AirwaveCore")?.invokeMethod("tidyGroups", withArguments: [groups])?.toDictionary() as? [String: String] ?? [:]
    }
    // Search text for each item is held in JavaScript once per library, so a keystroke costs one call.
    func index(_ texts: [String]) { _ = try? call("__setIndex", [texts]) }
    func search(_ query: String) -> [Int] { ((try? call("__search", [query]))?.toArray() ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    func match(_ items: [TVItem], _ phrase: String) -> TVItem? {
        let list = items.map { ["name": $0.name, "shown": $0.title] }
        guard let index = (try? call("__match", [list, phrase]))?.toInt32(), index >= 0, Int(index) < items.count else { return nil }
        return items[Int(index)]
    }
}
struct TVError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

// MARK: - Library

struct TVItem: Identifiable, Hashable {
    let id: String, name: String, url: URL, live: Bool, group: String, logo: URL?, tone: Int
    var title: String, quality: String, tags: [String]
    var badges: [String] { ([quality] + tags).filter { !$0.isEmpty } }
}
struct TVProgress: Codable { var time: Double, duration: Double, updated: Double }

// The source link (it can carry provider credentials) is kept in the Keychain; the catalog itself is AES-GCM encrypted.
enum SourceKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.airwave.library-source", kSecAttrAccount as String: "source"]
    static func read() -> String? {
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var insert = query; insert[kSecValueData as String] = Data(value.utf8); insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor final class TVLibrary: ObservableObject {
    @Published private(set) var items: [TVItem] = []
    @Published private(set) var name = "Demo library"
    @Published private(set) var isDemo = true
    @Published private(set) var loading = false
    @Published private(set) var groupNames: [String: String] = [:]
    @Published private(set) var favorites: [String] = []
    @Published private(set) var history: [String: TVProgress] = [:]
    @Published var tidy: Bool { didSet { defaults.set(tidy, forKey: "airwave.tidyNames"); relabel() } }
    @Published var notice: String?
    let artwork = ArtworkCache()
    private let store = PrivateCatalogStore()
    private let defaults = UserDefaults.standard
    private var raw: [[String: Any]] = []
    var hasSource: Bool { SourceKeychain.read() != nil }
    var live: [TVItem] { items.filter(\.live) }
    var movies: [TVItem] { items.filter { !$0.live } }
    var favoriteItems: [TVItem] { let set = Set(favorites); return items.filter { set.contains($0.id) } }
    var continueWatching: [TVItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return history.filter { resumable($0.key) }.sorted { $0.value.updated > $1.value.updated }.compactMap { byID[$0.key] }.filter { !$0.live }
    }
    var recent: [TVItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return history.sorted { $0.value.updated > $1.value.updated }.compactMap { byID[$0.key] }.prefix(12).map { $0 }
    }

    init() {
        tidy = defaults.object(forKey: "airwave.tidyNames") as? Bool ?? true
        favorites = defaults.stringArray(forKey: "airwave.favorites") ?? []
        if let data = defaults.data(forKey: "airwave.history"), let saved = try? JSONDecoder().decode([String: TVProgress].self, from: data) { history = saved }
        if let data = try? store.read(), (try? apply(data, demo: false)) != nil { return }
        apply(demo: true)
        // The system may purge Caches on Apple TV; a saved source brings the library back.
        if hasSource { Task { await reload() } }
    }

    // MARK: Loading
    private func apply(demo: Bool) { raw = TVLibrary.demos; name = "Demo library"; isDemo = true; relabel() }
    private func apply(_ data: Data, demo: Bool) throws {
        guard data.count <= 100_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["items"] as? [[String: Any]], !list.isEmpty, list.count <= 200_000 else { throw TVError("This is not an Airwave library file.") }
        let valid = list.filter { item in
            guard item["id"] is String, item["name"] is String, let rawURL = item["url"] as? String, let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            return ["live", "movie"].contains(item["kind"] as? String ?? "")
        }
        guard !valid.isEmpty else { throw TVError("This library has no playable HTTP or HTTPS titles.") }
        raw = valid; name = json["name"] as? String ?? "My library"; isDemo = demo
        // Favorites marked in the catalog are added once per library, as on the other platforms.
        let seed = name + ":" + String(valid.count)
        if defaults.string(forKey: "airwave.favoriteSeed") != seed {
            let marked = valid.filter { $0["favorite"] as? Bool == true }.compactMap { $0["id"] as? String }
            var seen = Set<String>(); favorites = (favorites + marked).filter { seen.insert($0).inserted }
            defaults.set(seed, forKey: "airwave.favoriteSeed"); defaults.set(favorites, forKey: "airwave.favorites")
        }
        relabel()
    }
    private func relabel() {
        let tidied = tidy ? SharedCore.shared.tidy(raw.map { ($0["name"] as? String ?? "", $0["group"] as? String ?? "", $0["kind"] as? String ?? "") }) : []
        items = raw.enumerated().compactMap { index, x in
            guard let id = x["id"] as? String, let name = x["name"] as? String, let url = URL(string: x["url"] as? String ?? "") else { return nil }
            let logo = (x["logo"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let color = x["color"] as? Int ?? Int(id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff })
            let label = tidy ? tidied[index] : (name, "", [])
            return TVItem(id: id, name: name, url: url, live: x["kind"] as? String == "live", group: x["group"] as? String ?? "", logo: logo, tone: abs(color) % 6,
                          title: label.0.isEmpty ? name : label.0, quality: label.1, tags: label.2)
        }
        var seen = Set<String>(), groups: [String] = []
        for item in items where !item.group.isEmpty && seen.insert(item.group).inserted { groups.append(item.group) }
        groupNames = tidy ? SharedCore.shared.tidyGroups(groups) : [:]
        SharedCore.shared.index(items.map { [$0.title, $0.name, $0.group, groupName($0.group)].joined(separator: " ") })
    }
    func groupName(_ group: String) -> String { groupNames[group] ?? group }
    func groups(of list: [TVItem]) -> [String] { var seen = Set<String>(); return list.compactMap { !$0.group.isEmpty && seen.insert($0.group).inserted ? $0.group : nil } }

    // Accepts an Airwave library JSON (version 2) or an M3U playlist; both are saved encrypted, the link in the Keychain.
    func add(source: String, name custom: String) async -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return "Enter a link that starts with http:// or https://." }
        loading = true; defer { loading = false }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TVError("The source answered with an error. Check the link.") }
            let catalog = try catalogData(data, base: http.url ?? url, name: custom)
            try apply(catalog, demo: false)
            try store.write(catalog); SourceKeychain.write(text)
            notice = "\(items.count.formatted()) titles loaded."
            return nil
        } catch let error as TVError { return error.message }
        catch { return "Could not reach the source. Check the link and your connection." }
    }
    func reload() async {
        guard let source = SourceKeychain.read() else { return }
        if let error = await add(source: source, name: isDemo ? "" : name) { notice = error }
    }
    private func catalogData(_ data: Data, base: URL, name custom: String) throws -> Data {
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("{") {
            guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TVError("This library file is not valid JSON.") }
            if !custom.isEmpty { json["name"] = custom }
            return try JSONSerialization.data(withJSONObject: json)
        }
        guard data.count <= 5 * 1024 * 1024 else { throw TVError("Playlist is too large. Use a playlist smaller than 5 MB.") }
        let entries = try SharedCore.shared.parseM3U(String(decoding: data, as: UTF8.self), base: base)
        return try JSONSerialization.data(withJSONObject: ["version": 2, "name": custom.isEmpty ? "My library" : custom, "items": entries])
    }
    func loadDemo() { store.clear(); SourceKeychain.clear(); apply(demo: true) }
    func reset() {
        favorites = []; history = [:]; tidy = true
        for key in ["airwave.favorites", "airwave.history", "airwave.tidyNames", "airwave.favoriteSeed"] { defaults.removeObject(forKey: key) }
        Task { await artwork.clear() }
        loadDemo()
    }

    // MARK: Favorites and progress (the same rules as the web interface)
    func isFavorite(_ item: TVItem) -> Bool { favorites.contains(item.id) }
    func toggleFavorite(_ item: TVItem) {
        if let index = favorites.firstIndex(of: item.id) { favorites.remove(at: index); notice = "Removed from favorites" } else { favorites.append(item.id); notice = "Added to favorites" }
        defaults.set(favorites, forKey: "airwave.favorites")
    }
    func resumable(_ id: String) -> Bool { guard let h = history[id] else { return false }; return h.duration > 0 && h.time > 30 && h.time < h.duration - 30 }
    func resumeTime(_ item: TVItem) -> Double { !item.live && resumable(item.id) ? history[item.id]?.time ?? 0 : 0 }
    func record(_ item: TVItem, time: Double, duration: Double) {
        history[item.id] = TVProgress(time: item.live ? 0 : time, duration: item.live ? 0 : duration, updated: Date().timeIntervalSince1970)
        // UserDefaults on Apple TV is small; keep the most recent entries.
        if history.count > 300 { for key in history.sorted(by: { $0.value.updated < $1.value.updated }).prefix(history.count - 300).map(\.key) { history[key] = nil } }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "airwave.history") }
    }
    func finished(_ item: TVItem) { history[item.id] = nil; if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "airwave.history") } }

    // MARK: Search: core.js matchesQuery over displayed name, playlist name and group (a substring, or every word starting a
    // word, spoken numbers included), the same rule as the web interface; a phrase that matches nothing falls back to the closest title.
    func search(_ query: String) -> [TVItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits = SharedCore.shared.search(q).filter { $0 < items.count }.map { items[$0] }
        if !hits.isEmpty { return hits }
        return SharedCore.shared.match(items, q).map { [$0] } ?? []
    }

    static let sample = "https://media.w3.org/2010/05/bunny/trailer.mp4", sintel = "https://media.w3.org/2010/05/sintel/trailer.mp4"
    static let demos: [[String: Any]] = [
        ["id": "demo-bunny", "name": "Big Buck Bunny", "kind": "movie", "group": "Open films", "url": sample, "color": 0],
        ["id": "demo-sintel", "name": "Sintel", "kind": "movie", "group": "Open films", "url": sintel, "color": 1],
    ] + ["Studio One", "Animation", "Cinema Club", "After Hours", "Discovery", "The Archive"].enumerated().map { i, name in
        ["id": "demo-station-\(i)", "name": name, "kind": "live", "group": "Sample channels", "url": i % 2 == 0 ? sample : sintel, "color": i]
    }
}

// MARK: - Playback

// Picks an engine with PlaybackPolicy, retries once on the other engine (as AirwaveModel does for the web shell),
// records progress, and answers Siri and remote playback commands for whichever engine is playing.
@MainActor final class TVPlayer: ObservableObject {
    @Published private(set) var state: PlaybackState?
    @Published private(set) var item: TVItem?
    @Published private(set) var failure: String?
    @Published private(set) var loadingNote: String?
    weak var library: TVLibrary?
    private var request: PlayRequest?
    private var token = 0
    private var deadline: Task<Void, Never>?
    private var winners: [String: EngineKind] = [:]
    private var external = false
    private var channels: [TVItem] = []
    private var lastSave = 0.0
    private var commands: [(MPRemoteCommand, Any)] = []
    private var background: NSObjectProtocol?
    var presented: Bool { item != nil }
    // Leaving the app (Home, the TV switching off) ends playback and keeps a movie's position. Scene phase alone was not
    // enough: pressing Home in testing left the position unsaved.
    init() {
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func play(_ next: TVItem, channels list: [TVItem] = []) {
        let resume = library?.resumeTime(next) ?? 0
        PlaybackTiming.note(String(format: "tv play kind=%@ resume-s=%.1f saved-s=%.1f", next.live ? "live" : "movie", resume, library?.history[next.id]?.time ?? -1))
        if !list.isEmpty { channels = list.filter(\.live) } else if channels.firstIndex(of: next) == nil { channels = library?.live ?? [] }
        close(); item = next; failure = nil; loadingNote = nil; token += 1; lastSave = PlaybackTiming.now
        library?.record(next, time: resume, duration: library?.history[next.id]?.duration ?? 0)
        request = PlayRequest(key: next.id, url: next.url, live: next.live, resume: resume, token: token)
        begin(winners[next.id] ?? PlaybackPolicy.engine(for: request!, externalRoute: external), fallback: false)
    }
    func retry() { if let item { play(item) } }
    func surf(_ step: Int) {
        guard let item, item.live, channels.count > 1, let index = channels.firstIndex(of: item) else { return }
        play(channels[(index + step + channels.count) % channels.count])
    }
    func stop() { close(); item = nil; failure = nil }
    private func close() {
        if let item, let state, !item.live, state.started { library?.record(item, time: state.time, duration: state.duration) }
        deadline?.cancel(); deadline = nil; request = nil
        state?.close(); state = nil
        removeCommands()
    }
    private func begin(_ kind: EngineKind, fallback: Bool) {
        guard let request else { return }
        let engine: any PlaybackEngine = kind == .mpv ? MPVEngine() : AVPlayerEngine()
        let current: PlaybackState
        if fallback, let state { state.use(engine); current = state } else { current = PlaybackState(engine: engine, live: request.live); state = current }
        let began = PlaybackTiming.now, token = request.token
        current.forward = { [weak self] event in self?.handle(event, kind: kind, began: began, fallback: fallback, token: token) }
        deadline?.cancel()
        if !fallback, kind == .mpv {
            let limit: UInt64 = request.live ? 8 : 15
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: limit * 1_000_000_000)
                guard !Task.isCancelled, let self, self.token == token, self.state?.started == false else { return }
                self.swap(from: kind, result: "timeout", began: began)
            }
        }
        // AVPlayerViewController answers Siri and the remote for AVPlayer; mpv needs the remote command center.
        if kind == .mpv { addCommands() } else { removeCommands() }
        engine.load(request.url(for: kind), resume: request.resume)
    }
    private func handle(_ event: EngineEvent, kind: EngineKind, began: Double, fallback: Bool, token: Int) {
        guard self.token == token, let request, let item else { return }
        switch event {
        case .firstFrame:
            deadline?.cancel(); loadingNote = nil
            if fallback { winners[request.key] = kind }
            PlaybackTiming.record(kind, request, attempt: fallback ? 2 : 1, result: "first-frame", since: began)
            // A source that cannot seek (no HTTP range support) starts a resumed movie at 0; say so rather than restart silently.
            if request.resume > 30, let time = state?.engine.time, time < request.resume - 10 {
                let note = "This source can’t start partway through, so the movie is playing from the beginning."
                loadingNote = note
                Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: 6_000_000_000); if self?.loadingNote == note { self?.loadingNote = nil } }
            }
        case .failed(let reason):
            if state?.started == false, !fallback { return swap(from: kind, result: "failed", began: began, detail: reason) }
            PlaybackTiming.record(kind, request, attempt: fallback ? 2 : 1, result: "failed", since: began, detail: reason)
            deadline?.cancel(); state?.close(); state = nil; removeCommands()
            failure = "Airwave couldn’t play this. The source may be offline or busy, or it uses a format Apple TV can’t play. Try again in a moment, or choose another title."
        case .ended:
            // A finished movie forgets its position; the state goes first so closing does not save it again.
            deadline?.cancel(); state?.close(); state = nil
            library?.finished(item); stop()
        // Progress is saved every 15 seconds of playback and whenever a movie pauses, never from the first report at 0.
        case .time(let time, let duration):
            if !item.live, state?.started == true, PlaybackTiming.now - lastSave > 15 { lastSave = PlaybackTiming.now; library?.record(item, time: time, duration: duration) }
            nowPlaying()
        case .status(let playing, _):
            if !playing, !item.live, let state, state.started { lastSave = PlaybackTiming.now; library?.record(item, time: state.time, duration: state.duration) }
            nowPlaying()
        case .externalPlayback(let active): external = active
        }
    }
    private func swap(from kind: EngineKind, result: String, began: Double, detail: String? = nil) {
        guard let request else { return }
        PlaybackTiming.record(kind, request, attempt: 1, result: result, since: began, detail: detail)
        loadingNote = "Trying another player…"
        begin(kind.other, fallback: true)
    }
    // MARK: Siri and remote commands while mpv plays
    private func addCommands() {
        removeCommands()
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ run: @escaping (MPRemoteCommandEvent) -> Bool) { commands.append((command, command.addTarget { event in run(event) ? .success : .commandFailed })) }
        on(center.playCommand) { [weak self] _ in self?.state?.engine.play(); return self?.state != nil }
        on(center.pauseCommand) { [weak self] _ in self?.state?.engine.pause(); return self?.state != nil }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.state?.toggle(); return self?.state != nil }
        center.skipForwardCommand.preferredIntervals = [10]; center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipForwardCommand) { [weak self] event in self?.state?.seek(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 10); return self?.item?.live == false }
        on(center.skipBackwardCommand) { [weak self] event in self?.state?.seek(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? 10)); return self?.item?.live == false }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime, self?.item?.live == false else { return false }
            self?.state?.seek(to: position); return true
        }
        on(center.nextTrackCommand) { [weak self] _ in self?.surf(1); return self?.item?.live == true }
        on(center.previousTrackCommand) { [weak self] _ in self?.surf(-1); return self?.item?.live == true }
        nowPlaying()
    }
    private func removeCommands() {
        for (command, target) in commands { command.removeTarget(target) }
        commands = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func nowPlaying() {
        guard !commands.isEmpty, let item, let state else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: item.title, MPNowPlayingInfoPropertyIsLiveStream: item.live, MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0]
        if !item.live { info[MPMediaItemPropertyPlaybackDuration] = state.duration; info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.time }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Interface

enum TVTab: Hashable { case home, live, movies, favorites, search, settings }

struct TVRoot: View {
    @EnvironmentObject var library: TVLibrary
    @EnvironmentObject var player: TVPlayer
    @State private var tab = TVTab.home
    var body: some View { tabs
        .fullScreenCover(isPresented: Binding(get: { player.presented }, set: { if !$0 { player.stop() } })) { TVPlayerScreen().environmentObject(library).environmentObject(player) }
        .overlay(alignment: .bottom) { TVNotice() }
    }
    // Navigation sits in a sidebar on the left (tvOS 18 and later), as on the other TV surfaces; Left from the page opens it.
    // tvOS 17 has no sidebar tab style and keeps the tab bar along the top.
    @ViewBuilder private var tabs: some View {
        if #available(tvOS 18.0, *) {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house", value: TVTab.home) { TVHome(tab: $tab) }
                Tab("Live TV", systemImage: "dot.radiowaves.left.and.right", value: TVTab.live) { TVBrowse(kind: .live) }
                Tab("Movies", systemImage: "film", value: TVTab.movies) { TVBrowse(kind: .movies) }
                Tab("Favorites", systemImage: "heart", value: TVTab.favorites) { TVBrowse(kind: .favorites) }
                Tab("Search", systemImage: "magnifyingglass", value: TVTab.search) { TVSearch() }
                Tab("Settings", systemImage: "gearshape", value: TVTab.settings) { TVSettings() }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: $tab) {
                TVHome(tab: $tab).tabItem { Label("Home", systemImage: "house") }.tag(TVTab.home)
                TVBrowse(kind: .live).tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }.tag(TVTab.live)
                TVBrowse(kind: .movies).tabItem { Label("Movies", systemImage: "film") }.tag(TVTab.movies)
                TVBrowse(kind: .favorites).tabItem { Label("Favorites", systemImage: "heart") }.tag(TVTab.favorites)
                TVSearch().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(TVTab.search)
                TVSettings().tabItem { Label("Settings", systemImage: "gearshape") }.tag(TVTab.settings)
            }
        }
    }
}

// A short confirmation at the bottom of the screen ("Added to favorites", "128 titles loaded").
struct TVNotice: View {
    @EnvironmentObject var library: TVLibrary
    var body: some View {
        if let text = library.notice {
            Text(text).font(.callout.weight(.medium)).foregroundStyle(.black).padding(.horizontal, 36).padding(.vertical, 18)
                .background(Capsule().fill(.white)).padding(.bottom, 60).transition(.opacity)
                .task(id: text) { try? await Task.sleep(nanoseconds: 3_500_000_000); library.notice = nil }
        }
    }
}

private let tones: [Color] = [Color(red: 0.11, green: 0.13, blue: 0.19), Color(red: 0.16, green: 0.12, blue: 0.10), Color(red: 0.11, green: 0.15, blue: 0.13),
                              Color(red: 0.16, green: 0.11, blue: 0.13), Color(red: 0.15, green: 0.14, blue: 0.09), Color(red: 0.11, green: 0.14, blue: 0.16)]

// Artwork from the shared cache (downsampled once, kept in Caches); the name stays on a flat tint until it arrives.
struct TVArtwork: View {
    @EnvironmentObject var library: TVLibrary
    let item: TVItem
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            tones[item.tone]
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding(item.live ? 28 : 0).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(item.title).font(.system(size: item.live ? 30 : 28, weight: .semibold)).foregroundStyle(.white).lineLimit(3).padding(20)
            }
            if !item.badges.isEmpty {
                HStack(spacing: 6) { ForEach(item.badges, id: \.self) { Text($0).font(.system(size: 18, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7))) } }
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .task(id: item.logo) {
            guard let logo = item.logo, let data = await library.artwork.image(id: item.id, source: logo)?.data else { return }
            image = UIImage(data: data)
        }
    }
}

// One tile: channels are 16:9, movies are posters. The card button style gives the system focus lift and parallax.
struct TVTile: View {
    @EnvironmentObject var library: TVLibrary
    @EnvironmentObject var player: TVPlayer
    let item: TVItem
    var channels: [TVItem] = []
    private var size: CGSize { item.live ? CGSize(width: 384, height: 216) : CGSize(width: 248, height: 372) }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Button { player.play(item, channels: channels) } label: {
                TVArtwork(item: item).frame(width: size.width, height: size.height)
                    .overlay(alignment: .bottom) { if let h = library.history[item.id], library.resumable(item.id) { ProgressView(value: h.time, total: h.duration).tint(Color(red: 0.89, green: 0.68, blue: 0.47)).padding(14) } }
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(library.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites") { library.toggleFavorite(item) }
                if library.resumable(item.id) { Button("Play from the beginning") { library.finished(item); player.play(item, channels: channels) } }
            }
            .accessibilityLabel(([item.title] + item.badges).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 4) {
                // Without artwork the tile already shows the name in large type; the caption keeps only the detail line.
                if item.logo != nil { Text(item.title).font(.system(size: 24, weight: .medium)).lineLimit(1) }
                Text(subtitle).font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: size.width, alignment: .leading)
        }
    }
    private var subtitle: String {
        if let h = library.history[item.id], library.resumable(item.id) { return TVClock.text(h.duration - h.time) + " left" }
        return library.groupName(item.group).isEmpty ? (item.live ? "Live channel" : "Movie") : library.groupName(item.group)
    }
}

enum TVClock {
    static func text(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0)), h = s / 3600, m = s / 60 % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
    }
}

struct TVShelf: View {
    let title: String
    let items: [TVItem]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.title3.weight(.semibold)).padding(.leading, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 48) { ForEach(items.prefix(30)) { TVTile(item: $0, channels: items) } }
                        .padding(.horizontal, 80).padding(.vertical, 30)
                }
            }
            .focusSection()
        }
    }
}

struct TVEmpty: View {
    let title: String, message: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1000)
            if let action { Button(action.0, action: action.1) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(80)
    }
}

struct TVHome: View {
    @EnvironmentObject var library: TVLibrary
    @Binding var tab: TVTab
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVShelf(title: "Continue watching", items: library.continueWatching)
                TVShelf(title: "Favorites", items: library.favoriteItems)
                TVShelf(title: library.isDemo ? "Sample channels" : "Channels", items: library.live)
                TVShelf(title: "Movies", items: library.movies)
                if library.isDemo {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Demo library: open films from the Blender Foundation. Sample channels play film previews, not live broadcasts.").foregroundStyle(.secondary)
                        Button("Add your library") { tab = .settings }
                    }.padding(.horizontal, 80).focusSection()
                }
            }.padding(.vertical, 40)
        }
    }
}

// Live TV, Movies and Favorites: a row of group filters above a grid.
struct TVBrowse: View {
    enum Kind { case live, movies, favorites }
    @EnvironmentObject var library: TVLibrary
    let kind: Kind
    @State private var group: String?
    private var all: [TVItem] { kind == .live ? library.live : kind == .movies ? library.movies : library.favoriteItems }
    private var shown: [TVItem] { group.map { g in all.filter { $0.group == g } } ?? all }
    var body: some View {
        let groups = library.groups(of: all)
        if all.isEmpty {
            TVEmpty(title: kind == .favorites ? "No favorites yet" : kind == .live ? "No live channels" : "No movies in this library",
                    message: kind == .favorites ? "Press and hold a channel or movie, then choose Add to Favorites." : "Add a library or playlist that includes them in Settings.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if groups.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 20) {
                                TVChip(title: "All", count: all.count, selected: group == nil) { group = nil }
                                ForEach(groups, id: \.self) { g in TVChip(title: library.groupName(g), count: all.filter { $0.group == g }.count, selected: group == g) { group = g } }
                            }.padding(.horizontal, 80).padding(.vertical, 20)
                        }.focusSection()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == .movies ? 248 : 384, maximum: kind == .movies ? 260 : 400), spacing: 48, alignment: .top)], alignment: .leading, spacing: 56) {
                        ForEach(shown) { TVTile(item: $0, channels: kind == .live ? shown : []) }
                    }.padding(.horizontal, 80).focusSection()
                }.padding(.vertical, 40)
            }
        }
    }
}

struct TVChip: View {
    let title: String, count: Int, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if selected { Image(systemName: "checkmark") }
                Text(title); Text(count.formatted()).foregroundStyle(.secondary)
            }.font(.system(size: 24, weight: selected ? .semibold : .regular))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// Search uses the system search keyboard: hold the Siri Remote's mic to speak, or type with the remote or an iPhone.
struct TVSearch: View {
    @EnvironmentObject var library: TVLibrary
    @State private var query = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                let results = library.search(query)
                VStack(alignment: .leading, spacing: 40) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        TVShelf(title: "Recently played", items: library.recent)
                        Text("Hold the mic button on your Siri Remote and say a channel, movie or group.").foregroundStyle(.secondary).padding(.horizontal, 80)
                    } else if results.isEmpty {
                        TVEmpty(title: "No matches for “\(query)”", message: "Try another name, or say part of it.")
                    } else {
                        TVShelf(title: "Channels", items: results.filter(\.live))
                        TVShelf(title: "Movies", items: results.filter { !$0.live })
                    }
                }.padding(.vertical, 40)
            }
            .searchable(text: $query, prompt: "Channels, movies or groups")
        }
    }
}

struct TVSettings: View {
    @EnvironmentObject var library: TVLibrary
    @State private var adding = false
    @State private var confirmReset = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                TVSetting(title: "Library", detail: "\(library.name) · \(library.items.count.formatted()) titles", note: library.isDemo ? "Demo library" : "Saved encrypted on this Apple TV") {
                    Button("Add library or playlist") { adding = true }
                    if library.hasSource { Button(library.loading ? "Loading…" : "Reload from source") { Task { await library.reload() } }.disabled(library.loading) }
                }
                TVSetting(title: "Tidy names", detail: library.tidy ? "Names are tidied" : "Showing names as written in the playlist",
                          note: "Removes region prefixes, divider symbols, styled letters and all capitals. Quality tags such as 4K and HD become badges.") {
                    Button(library.tidy ? "Show original names" : "Tidy names") { library.tidy.toggle() }
                }
                TVSetting(title: "Demo library", detail: "2 films · 6 sample channels", note: "Open films and sample channels for trying Airwave.") {
                    Button("Load demo") { library.loadDemo() }
                }
                TVSetting(title: "Reset", detail: "Start again from the demo library", note: "Clears favorites, viewing progress, saved artwork, the saved library and its link on this Apple TV.") {
                    Button("Reset Airwave") { confirmReset = true }
                }
                Text("Airwave 0.2 · Independent media player · No ads, payment gates or analytics. Demo films © Blender Foundation, CC BY 3.0.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(80)
        }
        .sheet(isPresented: $adding) { TVAddLibrary().environmentObject(library) }
        .confirmationDialog("Reset Airwave?", isPresented: $confirmReset) { Button("Reset Airwave", role: .destructive) { library.reset() } }
    }
}

struct TVSetting<Actions: View>: View {
    let title: String, detail: String, note: String
    @ViewBuilder let actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail)
                Text(note).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 30) { actions }
        }.focusSection()
    }
}

// Typing a long link with a remote is slow: the field accepts dictation (hold the mic) and the iPhone keyboard prompt.
struct TVAddLibrary: View {
    @EnvironmentObject var library: TVLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case load }
    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("Add a library or playlist").font(.title2.weight(.semibold))
            Text("Enter the link to an Airwave library file (JSON) or an M3U playlist. It replaces the current library and is saved encrypted on this Apple TV. Hold the mic button to dictate, or type on your iPhone when it offers the keyboard.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://your-provider.example/playlist.m3u", text: $source).textContentType(.URL).keyboardType(.URL).autocorrectionDisabled()
            TextField("Library name (optional)", text: $name)
            if let error { Text(error).foregroundStyle(Color(red: 1, green: 0.54, blue: 0.6)) }
            HStack(spacing: 30) {
                Button(library.loading ? "Loading…" : "Load") {
                    Task { error = await library.add(source: source, name: name.trimmingCharacters(in: .whitespaces)); if error == nil { dismiss() } }
                }.disabled(library.loading || source.trimmingCharacters(in: .whitespaces).isEmpty).focused($focus, equals: .load)
                Button("Cancel", role: .cancel) { dismiss() }
            }.focusSection().defaultFocus($focus, .load)
        }.padding(80).frame(maxWidth: 1400)
    }
}

// MARK: - Player screen

struct TVPlayerScreen: View {
    @EnvironmentObject var player: TVPlayer
    @EnvironmentObject var library: TVLibrary
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let state = player.state, let item = player.item {
                if let av = state.engine as? AVPlayerEngine {
                    TVSystemPlayer(engine: av, item: item, favorite: library.isFavorite(item), toggleFavorite: { library.toggleFavorite(item) }, surf: player.surf)
                        .id(ObjectIdentifier(av)).ignoresSafeArea()
                } else {
                    TVMPVScreen(state: state, item: item).id(ObjectIdentifier(state.engine))
                }
                if let note = player.loadingNote { Text(note).font(.headline).padding(30).background(Capsule().fill(.black.opacity(0.7))) }
            } else if let failure = player.failure {
                VStack(spacing: 40) {
                    Text(player.item?.title ?? "").font(.title2.weight(.semibold))
                    Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1100)
                    HStack(spacing: 30) { Button("Try again") { player.retry() }; Button("Back") { player.stop() } }
                }
            }
        }
        .onExitCommand { player.stop() }
    }
}

// AVPlayer titles use the system player: Siri Remote scrubbing, Siri "skip ahead", subtitles and audio menus come free.
// Live channels add previous and next channel to the transport bar; every title gets a favorite button there.
struct TVSystemPlayer: UIViewControllerRepresentable {
    let engine: AVPlayerEngine, item: TVItem, favorite: Bool, toggleFavorite: () -> Void, surf: (Int) -> Void
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = engine.player
        context.coordinator.title(engine.player, item.title)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== engine.player { controller.player = engine.player }
        var menu: [UIMenuElement] = [UIAction(title: favorite ? "Remove from Favorites" : "Add to Favorites", image: UIImage(systemName: favorite ? "heart.fill" : "heart")) { _ in toggleFavorite() }]
        if item.live {
            menu.insert(UIAction(title: "Previous channel", image: UIImage(systemName: "chevron.down")) { _ in surf(-1) }, at: 0)
            menu.insert(UIAction(title: "Next channel", image: UIImage(systemName: "chevron.up")) { _ in surf(1) }, at: 1)
        }
        controller.transportBarCustomMenuItems = menu
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    // The engine creates its AVPlayerItem after resolving a redirect, so the title is attached when the item appears.
    final class Coordinator {
        private var observation: NSKeyValueObservation?
        func title(_ player: AVPlayer, _ text: String) {
            let apply: (AVPlayerItem?) -> Void = { item in
                guard let item else { return }
                let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = text as NSString; title.extendedLanguageTag = "und"
                item.externalMetadata = [title]
            }
            apply(player.currentItem)
            observation = player.observe(\.currentItem, options: [.new]) { player, _ in DispatchQueue.main.async { apply(player.currentItem) } }
        }
    }
}

// mpv titles (raw MPEG-TS live channels, MKV, AVI): Airwave's own overlay. Play/Pause toggles, left and right skip
// 10 seconds in a movie, up and down change channel on live TV, and Menu returns to the library.
struct TVMPVScreen: View {
    @EnvironmentObject var player: TVPlayer
    @ObservedObject var state: PlaybackState
    let item: TVItem
    @State private var shown = true
    @State private var hide: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AirwaveVideoView(engine: state.engine).ignoresSafeArea()
            if !state.started || state.waiting { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Text(item.title).font(.title2.weight(.semibold))
                    ForEach(item.badges, id: \.self) { Text($0).font(.caption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5))) }
                }
                if item.live {
                    HStack(spacing: 12) { Circle().fill(Color(red: 0.89, green: 0.68, blue: 0.47)).frame(width: 12, height: 12); Text("Live · press up or down to change channel") }.foregroundStyle(.secondary)
                } else if state.duration > 0 {
                    ProgressView(value: min(state.time, state.duration), total: state.duration).tint(Color(red: 0.89, green: 0.68, blue: 0.47))
                    HStack { Text(TVClock.text(state.time)); Spacer(); Text("-" + TVClock.text(state.duration - state.time)) }.font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 90).padding(.vertical, 70)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .opacity(shown ? 1 : 0)
        }
        .focusable()
        .onPlayPauseCommand { state.toggle(); wake() }
        .onMoveCommand { direction in
            switch direction {
            case .left: if !item.live { state.seek(by: -10) }
            case .right: if !item.live { state.seek(by: 10) }
            case .up: if item.live { player.surf(1) }
            case .down: if item.live { player.surf(-1) }
            @unknown default: break
            }
            wake()
        }
        .onAppear { wake() }
        .onChange(of: state.playing) { wake() }
        .animation(.easeOut(duration: 0.25), value: shown)
    }
    private func wake() {
        shown = true; hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, state.playing, state.started { shown = false }
        }
    }
}
#endif
