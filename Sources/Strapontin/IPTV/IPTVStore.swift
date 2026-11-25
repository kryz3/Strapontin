import Foundation
import StrapontinCore
import SwiftUI

/// Une playlist IPTV configurée par l'utilisateur. Adresses et identifiants restent sur ce Mac (fichier 0600),
/// jamais dans le dépôt ni dans les journaux.
struct IPTVPlaylist: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Adresse http(s) ou chemin d'un fichier .m3u / .m3u8.
    var source: String
    /// Guide XMLTV (facultatif ; sinon celui annoncé par la playlist).
    var guide: String = ""
    var userAgent: String = ""
    var referer: String = ""
    /// Rafraîchissement automatique (heures).
    var refreshHours: Int = 12
}

/// Les chaînes, le catalogue à la demande, le guide, les favoris et la reprise de lecture.
@MainActor
final class IPTVStore: ObservableObject {
    static let shared = IPTVStore()

    @Published private(set) var playlists: [IPTVPlaylist] = []
    @Published private(set) var channels: [IPTVEntry] = []
    @Published private(set) var vod: [VODItem] = []
    @Published private(set) var guide = ProgramGuide()
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var favorites: [String] = []
    @Published private(set) var recents: [String] = []
    /// Reprise des films et épisodes à la demande : clé → (position, durée).
    @Published private(set) var progress: [String: [Double]] = [:]
    /// Recherche : index préparé en tâche de fond.
    private(set) var channelIndex = IPTVSearchIndex([])
    private(set) var vodIndex = IPTVSearchIndex([])
    /// Épisodes déjà demandés (séries Xtream).
    @Published private(set) var episodes: [String: [VODEpisode]] = [:]

    var configured: Bool { !playlists.isEmpty }

    private let dir: URL
    private let cacheDir: URL
    private var configURL: URL { dir.appendingPathComponent("iptv.json") }
    private var stateURL: URL { dir.appendingPathComponent("iptv-state.json") }

    private init() {
        let fm = FileManager.default
        dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin")
        cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin/IPTV")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL), let p = try? JSONDecoder().decode([IPTVPlaylist].self, from: data) { playlists = p }
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            favorites = s.favorites; recents = s.recents; progress = s.progress
        }
    }

    private struct State: Codable { var favorites: [String]; var recents: [String]; var progress: [String: [Double]] }
    private struct Cache: Codable { var date: Date; var entries: [IPTVEntry]; var guideURL: String?; var vod: [CachedVOD] }
    private struct CachedVOD: Codable {
        var id: String, kind: IPTVKind, name: String, poster: String?, category: String, plot: String?, rating: Double?
        var year: Int?, tmdbId: Int?, url: String?, seriesId: Int?
        init(_ v: VODItem) {
            id = v.id; kind = v.kind; name = v.name; poster = v.poster; category = v.category; plot = v.plot; rating = v.rating
            year = v.year; tmdbId = v.tmdbId; url = v.url; seriesId = v.seriesId
        }
        var item: VODItem {
            VODItem(id: id, kind: kind, name: name, poster: poster, category: category, plot: plot, rating: rating, year: year,
                    tmdbId: tmdbId, url: url, seriesId: seriesId)
        }
    }

    // MARK: playlists

    func save(_ list: [IPTVPlaylist]) {
        playlists = list
        if let data = try? JSONEncoder().encode(list) {
            FileManager.default.createFile(atPath: configURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        Task { await reload(force: true) }
    }

    private func saveState() {
        let s = State(favorites: favorites, recents: Array(recents.prefix(30)), progress: progress)
        if let data = try? JSONEncoder().encode(s) {
            FileManager.default.createFile(atPath: stateURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Au lancement : le cache tout de suite, puis un rafraîchissement si une playlist est trop ancienne.
    func start() {
        guard configured else { return }
        Task { await reload(force: false) }
    }

    func reload(force: Bool) async {
        guard !playlists.isEmpty else { channels = []; vod = []; rebuildIndexes(); return }
        loading = true
        defer { loading = false }
        error = nil
        var allChannels: [IPTVEntry] = []
        var allVOD: [VODItem] = []
        var guides: [String] = []
        let t0 = ContinuousClock.now
        for p in playlists {
            let cacheFile = cacheDir.appendingPathComponent("\(p.id).json")
            let cached = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            var result = cached
            if force || cached == nil || Date().timeIntervalSince(cached!.date) > Double(p.refreshHours) * 3600 {
                do {
                    result = try await Self.fetch(p)
                    if let data = try? JSONEncoder().encode(result) {
                        FileManager.default.createFile(atPath: cacheFile.path, contents: data, attributes: [.posixPermissions: 0o600])
                    }
                } catch {
                    // pas de journal avec l'adresse : seulement le nom de la playlist
                    self.error = "« \(p.name) » n'a pas pu être chargée : \(error.localizedDescription)"
                }
            }
            guard let r = result else { continue }
            allChannels += r.entries.filter { $0.kind == .live }
            allVOD += r.vod.map(\.item)
            if !p.guide.isEmpty { guides.append(p.guide) } else if let g = r.guideURL { guides.append(g) }
        }
        channels = allChannels
        vod = allVOD
        rebuildIndexes()
        Perf.log("iptv : \(allChannels.count) chaînes, \(allVOD.count) titres", since: t0)
        if let g = guides.first { await loadGuide(g, playlist: playlists.first) }
    }

    private func rebuildIndexes() {
        let ch = channels
        let v = vod.map { IPTVEntry(id: $0.id, name: $0.name, url: $0.url ?? "", tvgId: nil, logo: $0.poster, group: $0.category,
                                    number: nil, kind: $0.kind, playlist: "") }
        Task.detached(priority: .userInitiated) {
            let a = IPTVSearchIndex(ch), b = IPTVSearchIndex(v)
            await MainActor.run { self.channelIndex = a; self.vodIndex = b; self.objectWillChange.send() }
        }
    }

    /// Télécharge et lit une playlist (et, pour un fournisseur Xtream, son catalogue à la demande), hors du fil principal.
    private static func fetch(_ p: IPTVPlaylist) async throws -> Cache {
        let text = try await load(p.source, p)
        let parsed = await Task.detached(priority: .userInitiated) { M3UParser.parse(text, playlist: p.id) }.value
        var vod: [VODItem] = parsed.entries.filter { $0.kind != .live }.map {
            VODItem(id: $0.id, kind: $0.kind, name: $0.name, poster: $0.logo, category: $0.group, plot: nil, rating: nil,
                    year: VODTitle.year($0.name), tmdbId: nil, url: $0.url, seriesId: nil)
        }
        if let account = XtreamAccount.from(playlistURL: p.source) {
            // le catalogue de l'API, mieux rangé que les entrées de la playlist
            async let vc = data(account.api("get_vod_categories"), p)
            async let vs = data(account.api("get_vod_streams"), p)
            async let sc = data(account.api("get_series_categories"), p)
            async let ss = data(account.api("get_series"), p)
            let (vcats, vstreams, scats, series) = try await (vc, vs, sc, ss)
            let movies = XtreamParser.movies(vstreams, account: account, categories: XtreamParser.categories(vcats))
            let shows = XtreamParser.series(series, categories: XtreamParser.categories(scats))
            if !movies.isEmpty || !shows.isEmpty { vod = movies + shows }
        }
        return Cache(date: Date(), entries: parsed.entries, guideURL: parsed.guideURL, vod: vod.map(CachedVOD.init))
    }

    private static func load(_ source: String, _ p: IPTVPlaylist) async throws -> String {
        if source.hasPrefix("http") {
            let d = try await data(URL(string: source), p)
            return String(decoding: d, as: UTF8.self)
        }
        return try String(contentsOfFile: (source as NSString).expandingTildeInPath, encoding: .utf8)
    }

    static func data(_ url: URL?, _ p: IPTVPlaylist?) async throws -> Data {
        guard let url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        if let ua = p?.userAgent, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let r = p?.referer, !r.isEmpty { req.setValue(r, forHTTPHeaderField: "Referer") }
        let (d, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            throw NSError(domain: "IPTV", code: code, userInfo: [NSLocalizedDescriptionKey: "le serveur a répondu \(code)"])
        }
        return d
    }

    private func loadGuide(_ source: String, playlist: IPTVPlaylist?) async {
        let cacheFile = cacheDir.appendingPathComponent("guide.xml")
        var data = try? Data(contentsOf: cacheFile)
        let age = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
        if data == nil || age > 6 * 3600 {
            if let d = try? await (source.hasPrefix("http") ? Self.data(URL(string: source), playlist)
                                   : Data(contentsOf: URL(fileURLWithPath: (source as NSString).expandingTildeInPath))) {
                data = Self.gunzip(d) ?? d
                try? data?.write(to: cacheFile, options: .atomic)
            }
        }
        guard let data else { return }
        guide = await Task.detached(priority: .utility) { ProgramGuide.parse(data) }.value
    }

    /// Guides souvent fournis en .xml.gz.
    static func gunzip(_ d: Data) -> Data? {
        guard d.count > 18, d[0] == 0x1f, d[1] == 0x8b else { return nil }
        var header = 10
        let flags = d[3]
        if flags & 4 != 0 { header += 2 + Int(d[10]) + Int(d[11]) << 8 }
        if flags & 8 != 0 { while header < d.count, d[header] != 0 { header += 1 }; header += 1 }
        if flags & 16 != 0 { while header < d.count, d[header] != 0 { header += 1 }; header += 1 }
        if flags & 2 != 0 { header += 2 }
        return try? (d.subdata(in: header..<(d.count - 8)) as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: favoris, récentes, reprise

    func isFavorite(_ e: IPTVEntry) -> Bool { favorites.contains(e.id) }

    func toggleFavorite(_ e: IPTVEntry) {
        if let i = favorites.firstIndex(of: e.id) { favorites.remove(at: i) } else { favorites.append(e.id) }
        saveState()
    }

    func moveFavorite(from: IndexSet, to: Int) {
        favorites.move(fromOffsets: from, toOffset: to)
        saveState()
    }

    func played(_ e: IPTVEntry) {
        recents.removeAll { $0 == e.id }
        recents.insert(e.id, at: 0)
        saveState()
    }

    func channel(_ id: String) -> IPTVEntry? { channels.first { $0.id == id } }
    var favoriteChannels: [IPTVEntry] { favorites.compactMap(channel) }
    var recentChannels: [IPTVEntry] { recents.compactMap(channel) }

    /// Autres adresses de la même chaîne (même tvg-id ou même nom) : sources de secours.
    func alternates(_ e: IPTVEntry) -> [String] {
        let name = CatalogFold.fold(e.name)
        return channels.filter { $0.id != e.id && (($0.tvgId != nil && $0.tvgId == e.tvgId) || CatalogFold.fold($0.name) == name) }.map(\.url)
    }

    func playlist(of e: IPTVEntry) -> IPTVPlaylist? { playlists.first { $0.id == e.playlist } ?? playlists.first }

    func saveProgress(_ key: String, position: Double, duration: Double) {
        progress[key] = [position, duration]
        saveState()
    }

    // MARK: séries Xtream

    func loadEpisodes(_ item: VODItem) async {
        guard episodes[item.id] == nil, let sid = item.seriesId,
              let p = playlists.first(where: { XtreamAccount.from(playlistURL: $0.source) != nil }),
              let account = XtreamAccount.from(playlistURL: p.source),
              let d = try? await Self.data(account.api("get_series_info", ["series_id": String(sid)]), p) else { return }
        episodes[item.id] = XtreamParser.episodes(d, account: account)
    }

    /// Séries de la playlist sans API : épisodes regroupés d'après les noms (« The Bear S01 E02 »).
    func playlistEpisodes(of item: VODItem) -> [VODEpisode] {
        let base = CatalogFold.fold(VODTitle.clean(item.name.replacingOccurrences(of: #"(?i)\s*s\d{1,2}\s?e\d{1,3}.*$"#, with: "", options: .regularExpression)))
        return vod.filter { $0.kind == .series && $0.url != nil }.compactMap { v -> VODEpisode? in
            let name = v.name
            guard let r = name.range(of: #"(?i)s(\d{1,2})\s?e(\d{1,3})"#, options: .regularExpression) else { return nil }
            let head = CatalogFold.fold(VODTitle.clean(String(name[..<r.lowerBound])))
            guard head == base else { return nil }
            let tag = name[r].lowercased()
            let nums = tag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 2, let url = v.url else { return nil }
            return VODEpisode(id: v.id, season: nums[0], episode: nums[1], title: "Épisode \(nums[1])", plot: nil, still: nil,
                              duration: nil, url: url)
        }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    /// Le catalogue d'une playlist sans API : une série n'apparaît qu'une fois (pas une carte par épisode).
    var catalogItems: [VODItem] {
        var seen = Set<String>()
        return vod.filter { v in
            guard v.kind == .series, v.seriesId == nil else { return true }
            let base = CatalogFold.fold(VODTitle.clean(v.name.replacingOccurrences(of: #"(?i)\s*s\d{1,2}\s?e\d{1,3}.*$"#, with: "", options: .regularExpression)))
            return seen.insert(base).inserted
        }
    }
}
