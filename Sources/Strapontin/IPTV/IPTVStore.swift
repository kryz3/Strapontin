import Darwin
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

/// Les chaînes, l'index des films et séries, le guide, les favoris et la reprise de lecture.
///
/// Chargement progressif, sans jamais figer l'interface : les chaînes d'abord (depuis le cache disque, puis l'API
/// Xtream si elles ont plus d'un jour), puis en fond l'index léger des films et séries. Une playlist sans API Xtream
/// est lue en entier, une fois par jour au plus.
@MainActor
final class IPTVStore: ObservableObject {
    static let shared = IPTVStore()

    @Published private(set) var playlists: [IPTVPlaylist] = []
    @Published private(set) var channels: [IPTVEntry] = []
    @Published private(set) var guide = ProgramGuide()
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var favorites: [String] = []
    @Published private(set) var recents: [String] = []
    /// Reprise des films et épisodes à la demande : clé → (position, durée, date).
    @Published private(set) var progress: [String: [Double]] = [:]
    /// Recherche des chaînes : index préparé en tâche de fond.
    private(set) var channelIndex = IPTVSearchIndex([])
    /// Films et séries : index léger (titre normalisé, année, id TMDb) pour la recherche depuis une fiche.
    @Published private(set) var vodLookup = VODLookup()
    @Published private(set) var vodLoading = false
    /// Épisodes déjà demandés (séries Xtream), par référence.
    @Published private(set) var episodes: [String: [VODEpisode]] = [:]
    /// Programme court (Xtream get_short_epg) des chaînes affichées.
    @Published private(set) var shortEPG: [String: [ProgramGuide.Program]] = [:]

    var configured: Bool { !playlists.isEmpty }

    // MARK: chaînes regroupées

    /// Variantes de chaque chaîne (4K, FHD, HD, SD, secours), la meilleure d'abord.
    private(set) var variants: [String: [ChannelVariant]] = [:]
    /// Entrée de la playlist → chaîne (pour retrouver d'anciens favoris).
    private var groupOf: [String: String] = [:]
    private var channelByID: [String: IPTVEntry] = [:]
    /// Entrées telles que la playlist les écrit (pour l'export des noms).
    private var rawChannels: [IPTVEntry] = []
    /// Nom de rangée de chaque chaîne (« EU | FRANCE SPORTS » → « Sports »), calculé une fois.
    private(set) var groupTitle: [String: String] = [:]
    /// Rangées d'« En direct » par pays, calculées une fois par pays.
    private var rowsCache: [String: [(String, [IPTVEntry])]] = [:]
    /// Qualité choisie par chaîne : identifiant de la variante.
    private var qualityChoice: [String: String] = UserDefaults.standard.dictionary(forKey: "iptvQuality") as? [String: String] ?? [:]

    func variants(of e: IPTVEntry) -> [ChannelVariant] { variants[e.id] ?? [] }

    /// La variante à ouvrir : celle choisie pour cette chaîne, sinon la meilleure.
    func preferredVariant(_ e: IPTVEntry) -> ChannelVariant? {
        let v = variants(of: e)
        return v.first { $0.id == qualityChoice[e.id] } ?? v.first
    }

    func chooseQuality(_ variantID: String, for e: IPTVEntry) {
        qualityChoice[e.id] = variantID
        UserDefaults.standard.set(qualityChoice, forKey: "iptvQuality")
    }

    /// Rangées d'« En direct » pour le pays choisi : (titre, chaînes), dans l'ordre de la playlist.
    func liveRows() -> [(String, [IPTVEntry])] {
        let key = country ?? "*"
        if let r = rowsCache[key] { return r }
        var order: [String] = [], rows: [String: [IPTVEntry]] = [:]
        for c in channels where inCountry(c) {
            let t = groupTitle[c.id] ?? c.group
            if rows[t] == nil { order.append(t) }
            rows[t, default: []].append(c)
        }
        let out = order.map { ($0, rows[$0]!) }
        rowsCache[key] = out
        return out
    }

    // MARK: pays

    /// Pays présents, avec leur nombre de chaînes ; « » = sans pays reconnu.
    @Published private(set) var channelCountries: [CountryCount] = []
    private(set) var countryOfChannel: [String: String] = [:]
    /// Pays choisi dans « En direct » (nil = tous).
    @Published var country: String? {
        didSet { UserDefaults.standard.set(country ?? "*", forKey: "iptvCountry") }
    }
    @Published private(set) var favoriteCountries: [String] = UserDefaults.standard.stringArray(forKey: "iptvFavoriteCountries") ?? []

    struct CountryCount: Hashable, Identifiable {
        var code: String
        var count: Int
        var id: String { code }
        var label: String { code.isEmpty ? "Autres" : IPTVCountry.label(code) }
        var flag: String { code.isEmpty ? "🌐" : IPTVCountry.flag(code) }
    }

    func countryCode(of e: IPTVEntry) -> String { countryOfChannel[e.id] ?? "" }
    func inCountry(_ e: IPTVEntry) -> Bool { country == nil || countryCode(of: e) == country }

    func toggleFavoriteCountry(_ code: String) {
        if let i = favoriteCountries.firstIndex(of: code) { favoriteCountries.remove(at: i) } else { favoriteCountries.append(code) }
        UserDefaults.standard.set(favoriteCountries, forKey: "iptvFavoriteCountries")
        channelCountries = ordered(channelCountries)
    }

    /// Pays favoris d'abord, puis par nombre de chaînes ; « Autres » à la fin.
    private func ordered(_ list: [CountryCount]) -> [CountryCount] {
        let fav = favoriteCountries
        return list.sorted { a, b in
            let fa = fav.firstIndex(of: a.code) ?? Int.max, fb = fav.firstIndex(of: b.code) ?? Int.max
            if fa != fb { return fa < fb }
            if a.code.isEmpty != b.code.isEmpty { return b.code.isEmpty }
            return a.count != b.count ? a.count > b.count : a.label < b.label
        }
    }

    /// Choix de départ : celui d'avant, sinon la France si la playlist en a.
    private func restoreCountry() {
        let saved = UserDefaults.standard.string(forKey: "iptvCountry")
        let codes = Set(channelCountries.map(\.code))
        if saved == "*" { country = nil }
        else if let saved, codes.contains(saved) { country = saved }
        else if saved == nil, codes.contains("FR") { country = "FR" }
        else if let c = country, !codes.contains(c) { country = nil }
    }

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
            favorites = s.favorites; recents = s.recents; progress = s.progress; streams = s.streams ?? []
        }
    }

    private struct State: Codable {
        var favorites: [String]; var recents: [String]; var progress: [String: [Double]]
        var streams: [StreamRecord]?
    }
    /// Lectures en streaming (films et épisodes IPTV), les plus récentes d'abord : historique commun.
    @Published private(set) var streams: [StreamRecord] = []

    func noteStream(_ r: StreamRecord) {
        streams.removeAll { $0.key == r.key }
        streams.insert(r, at: 0)
        if streams.count > 200 { streams.removeLast(streams.count - 200) }
        saveState()
    }
    private struct LiveCache: Codable { var date: Date; var entries: [IPTVEntry]; var guideURL: String? }
    private struct VODCache: Codable { var date: Date; var refs: [VODRef] }

    // MARK: playlists

    func save(_ list: [IPTVPlaylist]) {
        playlists = list
        if let data = try? JSONEncoder().encode(list) {
            FileManager.default.createFile(atPath: configURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        Task { await reload(force: true) }
    }

    private func saveState() {
        let s = State(favorites: favorites, recents: Array(recents.prefix(30)), progress: progress, streams: streams)
        if let data = try? JSONEncoder().encode(s) {
            FileManager.default.createFile(atPath: stateURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Au lancement : le cache tout de suite, puis un rafraîchissement en fond si une playlist est trop ancienne.
    func start() {
        guard configured else { return }
        Task { await reload(force: false) }
    }

    private func cacheFile(_ p: IPTVPlaylist, _ part: String) -> URL { cacheDir.appendingPathComponent("\(p.id)-\(part).json") }

    private func stale(_ date: Date, _ p: IPTVPlaylist) -> Bool {
        Date().timeIntervalSince(date) > Double(max(6, p.refreshHours)) * 3600
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        autoreleasepool {
            if let data = try? JSONEncoder().encode(value) {
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private static func read<T: Decodable & Sendable>(_ type: T.Type, _ url: URL) async -> T? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        }.value
    }

    func reload(force: Bool) async {
        guard !playlists.isEmpty else { await applyChannels([]); vodLookup = VODLookup(); return }
        loading = true
        error = nil
        let t0 = ContinuousClock.now
        // ancien cache d'une version précédente (playlist complète, très lourd) : il ne sert plus
        for p in playlists { try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(p.id).json")) }

        // 1. les chaînes, du cache disque, tout de suite
        var live: [String: LiveCache] = [:]
        for p in playlists { live[p.id] = await Self.read(LiveCache.self, cacheFile(p, "live")) }
        if live.values.contains(where: { !$0.entries.isEmpty }) {
            await applyChannels(playlists.flatMap { live[$0.id]?.entries ?? [] })
            Perf.log("iptv : chaînes du cache (\(channels.count))", since: t0)
        }
        // 2. les chaînes à jour (API Xtream, ou playlist complète une fois par jour)
        var m3uVOD: [String: [VODRef]] = [:]
        var fetched = false
        for p in playlists where force || live[p.id].map({ stale($0.date, p) }) ?? true {
            do {
                let r = try await Self.fetchLive(p)
                live[p.id] = LiveCache(date: Date(), entries: r.entries, guideURL: r.guideURL)
                fetched = true
                Self.write(live[p.id]!, to: cacheFile(p, "live"))
                if let v = r.vod { m3uVOD[p.id] = v; Self.write(VODCache(date: Date(), refs: v), to: cacheFile(p, "vod")) }
            } catch {
                // pas de journal avec l'adresse : seulement le nom de la playlist
                self.error = "« \(p.name) » : \(Self.explain(error))"
                    + (live[p.id] != nil ? " En attendant, la dernière liste chargée reste utilisable." : "")
            }
        }
        if fetched || channels.isEmpty { await applyChannels(playlists.flatMap { live[$0.id]?.entries ?? [] }) }
        loading = false
        Perf.log("iptv : \(rawChannels.count) entrées → \(channels.count) chaînes", since: t0)
        let guides = playlists.compactMap { p in p.guide.isEmpty ? live[p.id]?.guideURL : p.guide }
        // 3. en fond : l'index des films et séries, puis le guide
        Task { await loadVOD(force: force, fresh: m3uVOD) }
        if let g = guides.first { await loadGuide(g, playlist: playlists.first) }
    }

    /// Les chaînes à l'écran : regroupées (variantes), pays, rangées, index de recherche, tout hors du fil principal.
    private func applyChannels(_ all: [IPTVEntry]) async {
        rawChannels = all
        let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedChannels in
            let grouped = ChannelGrouping.group(all)
            var cc: [String: String] = [:], cn: [String: Int] = [:], titles: [String: String] = [:]
            for e in grouped.channels {
                let c = e.country ?? IPTVCountry.detect(group: e.group, name: e.name, tvgId: e.tvgId) ?? ""
                cc[e.id] = c; cn[c, default: 0] += 1
                titles[e.id] = IPTVCountry.groupTitle(e.group)
            }
            return PreparedChannels(grouped: grouped, index: IPTVSearchIndex(grouped.channels, channelNames: true),
                                    countryOf: cc, counts: cn.map { CountryCount(code: $0.key, count: $0.value) }, titles: titles)
        }.value
        variants = prepared.grouped.variants
        groupOf = prepared.grouped.groupOf
        channelByID = Dictionary(prepared.grouped.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        countryOfChannel = prepared.countryOf
        groupTitle = prepared.titles
        channelIndex = prepared.index
        rowsCache = [:]
        // un seul « Autres » sans aucun pays reconnu : pas de barre de pays
        channelCountries = prepared.counts.contains(where: { !$0.code.isEmpty }) ? ordered(prepared.counts) : []
        channels = prepared.grouped.channels
        migrateIDs()
        restoreCountry()
    }

    private struct PreparedChannels: Sendable {
        var grouped: ChannelGrouping.Result
        var index: IPTVSearchIndex
        var countryOf: [String: String]
        var counts: [CountryCount]
        var titles: [String: String]
    }

    /// L'index des films et séries : du cache, puis à jour une fois par jour (API Xtream), en fond.
    private func loadVOD(force: Bool, fresh: [String: [VODRef]]) async {
        vodLoading = true
        defer { vodLoading = false }
        let t0 = ContinuousClock.now
        var refs: [String: [VODRef]] = fresh
        var stalePlaylists: [IPTVPlaylist] = []
        for p in playlists where refs[p.id] == nil {
            let c = await Self.read(VODCache.self, cacheFile(p, "vod"))
            if let c { refs[p.id] = c.refs }
            if force || c.map({ stale($0.date, p) }) ?? true { stalePlaylists.append(p) }
        }
        vodLookup = await Task.detached(priority: .utility) { VODLookup(refs.values.flatMap { $0 }) }.value
        Perf.log("iptv : index films/séries du cache (\(vodLookup.count))", since: t0)
        for p in stalePlaylists {
            guard let account = XtreamAccount.from(playlistURL: p.source) else { continue }   // sans API : déjà lu avec les chaînes
            guard let v = try? await Self.fetchVOD(account, p) else { continue }
            refs[p.id] = v
            Self.write(VODCache(date: Date(), refs: v), to: cacheFile(p, "vod"))
        }
        if !stalePlaylists.isEmpty {
            vodLookup = await Task.detached(priority: .utility) { VODLookup(refs.values.flatMap { $0 }) }.value
            Perf.log("iptv : index films/séries à jour (\(vodLookup.count))", since: t0)
        }
        // rendre au système la mémoire des réponses lues (sinon elle reste réservée jusqu'à la relance)
        malloc_zone_pressure_relief(nil, 0)
    }

    private struct LiveResult: Sendable { var entries: [IPTVEntry]; var guideURL: String?; var vod: [VODRef]? }

    /// Les chaînes : API Xtream (légère : chaînes seules), sinon la playlist complète (chaînes + films et séries).
    private static func fetchLive(_ p: IPTVPlaylist) async throws -> LiveResult {
        if let account = XtreamAccount.from(playlistURL: p.source) {
            async let cats = data(account.api("get_live_categories"), p)
            async let streams = data(account.api("get_live_streams"), p)
            let (c, s) = try await (cats, streams)
            let entries = await Task.detached(priority: .userInitiated) {
                XtreamParser.liveChannels(s, account: account, categories: XtreamParser.categories(c), playlist: p.id)
            }.value
            if !entries.isEmpty { return LiveResult(entries: entries, guideURL: nil, vod: nil) }
        }
        let text = try await load(p.source, p)
        return await Task.detached(priority: .userInitiated) {
            let parsed = M3UParser.parse(text, playlist: p.id)
            var live: [IPTVEntry] = [], vod: [VODRef] = []
            for e in parsed.entries {
                if e.kind == .live { live.append(e); continue }
                let ep = e.kind == .series ? VODMatch.episode(e.name) : nil
                vod.append(VODRef(id: e.id, kind: e.kind, name: e.name, url: e.url, season: ep?.season, episode: ep?.episode, poster: e.logo))
            }
            return LiveResult(entries: live, guideURL: parsed.guideURL, vod: vod)
        }.value
    }

    /// Films et séries d'un compte Xtream, catégorie par catégorie : chaque réponse est petite, lue puis libérée tout
    /// de suite (la liste complète d'un coup faisait monter l'app à 1,4 Go). Sans catégories : la liste entière.
    private static func fetchVOD(_ account: XtreamAccount, _ p: IPTVPlaylist) async throws -> [VODRef] {
        var out: [VODRef] = []
        for (kind, catAction, listAction) in [(IPTVKind.movie, "get_vod_categories", "get_vod_streams"),
                                              (.series, "get_series_categories", "get_series")] {
            let cats = Array(XtreamParser.categories(try await data(account.api(catAction), p)).keys)
            if cats.isEmpty {
                let d = try await data(account.api(listAction), p)
                out += await Task.detached(priority: .utility) { autoreleasepool { XtreamParser.vodRefs(d, kind: kind) } }.value
                continue
            }
            for c in cats {
                guard let d = try? await data(account.api(listAction, ["category_id": c]), p) else { continue }
                out += await Task.detached(priority: .utility) { autoreleasepool { XtreamParser.vodRefs(d, kind: kind) } }.value
            }
        }
        // un même titre peut être rangé dans plusieurs catégories
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    private static func load(_ source: String, _ p: IPTVPlaylist) async throws -> String {
        if source.hasPrefix("http") {
            let d = try await data(URL(string: source), p)
            return String(decoding: d, as: UTF8.self)
        }
        return try String(contentsOfFile: (source as NSString).expandingTildeInPath, encoding: .utf8)
    }

    /// Une erreur réseau en clair : injoignable (réseau qui bloque, serveur éteint), accès refusé, panne du serveur.
    static func explain(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                 .secureConnectionFailed, .cannotLoadFromNetwork, .internationalRoamingOff:
                return "serveur injoignable depuis ce réseau (bloqué par la connexion, ou serveur hors ligne). Réessaie plus tard ou sur une autre connexion."
            case .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "connexion non sécurisée refusée (certificat ou http). Mets à jour Strapontin, ou essaie l'adresse en https."
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return "identifiants refusés par le serveur."
            case .badURL, .unsupportedURL: return "adresse invalide : vérifie le serveur saisi."
            case .badServerResponse, .cannotParseResponse, .zeroByteResource:
                return "le serveur a répondu quelque chose d'illisible (identifiants refusés ou abonnement expiré ?)."
            default: return "chargement impossible (erreur réseau \(u.code.rawValue))."
            }
        }
        let ns = error as NSError
        if ns.domain == "IPTV" {
            switch ns.code {
            case 401, 403: return "accès refusé par le serveur (identifiants, abonnement expiré, ou réseau bloqué)."
            case 404: return "adresse introuvable sur le serveur."
            case 500...599: return "le serveur de streaming a un problème (\(ns.code)). Réessaie plus tard."
            default: return "le serveur a répondu \(ns.code)."
            }
        }
        return error.localizedDescription
    }

    static func data(_ url: URL?, _ p: IPTVPlaylist?) async throws -> Data {
        guard let url else { throw URLError(.badURL) }
        // délai d'inactivité : un serveur bloqué ne laisse pas un chargement sans fin
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue((p?.userAgent).flatMap { $0.isEmpty ? nil : $0 } ?? LiveOptions.defaultUserAgent, forHTTPHeaderField: "User-Agent")
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

    /// Fichier des noms seulement (type, groupe, nom), pour améliorer la reconnaissance des chaînes : aucune adresse,
    /// aucun identifiant. Dans Téléchargements.
    func exportNames() -> URL? {
        func clean(_ s: String) -> String {
            s.contains("://") ? "" : s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["type\tgroupe\tnom"]
        for c in rawChannels { lines.append("direct\t\(clean(c.group))\t\(clean(c.name))") }
        for v in vodLookup.refs where v.episode == nil || v.episode == 1 {
            lines.append("\(v.kind == .series ? "serie" : "film")\t\t\(clean(v.name))")
        }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("Strapontin-noms-des-chaines.tsv")
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    /// « Tester la connexion » : ce qui se passe quand on contacte le serveur, sans afficher l'adresse ni les identifiants.
    static func testConnection(_ p: IPTVPlaylist) async -> String {
        let ua = p.userAgent.isEmpty ? LiveOptions.defaultUserAgent : p.userAgent
        let target: URL?
        if let account = XtreamAccount.from(playlistURL: p.source) { target = account.api("get_server_info") ?? URL(string: p.source) }
        else { target = URL(string: p.source) }
        guard let url = target, url.scheme?.hasPrefix("http") == true else {
            return FileManager.default.fileExists(atPath: (p.source as NSString).expandingTildeInPath) ? "Fichier local : lisible." : "Ni une adresse ni un fichier existant."
        }
        let port = url.port.map { ":\($0)" } ?? (url.scheme == "https" ? " (443)" : " (80)")
        var lines = ["Serveur \(url.scheme ?? "")\(port) · User-Agent « \(ua) »"]
        let t0 = Date()
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            if !p.referer.isEmpty { req.setValue(p.referer, forHTTPHeaderField: "Referer") }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lines.append("Réponse HTTP \(code) en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file))")
            if XtreamAccount.from(playlistURL: p.source) != nil,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let info = j["user_info"] as? [String: Any] {
                let auth = "\(info["auth"] ?? "")" == "1"
                lines.append(auth ? "Compte reconnu · état : \(info["status"] ?? "?")" : "Identifiants refusés par le serveur")
            }
            lines.append((200..<300).contains(code) ? "✓ Connexion OK" : "✗ " + explain(NSError(domain: "IPTV", code: code)))
        } catch {
            lines.append("✗ " + explain(error))
        }
        return lines.joined(separator: "\n")
    }

    func channel(_ id: String) -> IPTVEntry? { channelByID[id] ?? groupOf[id].flatMap { channelByID[$0] } }

    /// Favoris et récentes enregistrés avec l'identifiant d'une entrée de playlist : ramenés à leur chaîne.
    private func migrateIDs() {
        func map(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.map { channelByID[$0] != nil ? $0 : (groupOf[$0] ?? $0) }.filter { seen.insert($0).inserted }
        }
        let f = map(favorites), r = map(recents)
        if f != favorites || r != recents { favorites = f; recents = r; saveState() }
    }
    var favoriteChannels: [IPTVEntry] { favorites.compactMap(channel) }
    var recentChannels: [IPTVEntry] { recents.compactMap(channel) }

    /// Autres adresses de la même chaîne (même tvg-id ou même nom) : sources de secours.
    func alternates(_ e: IPTVEntry) -> [String] {
        let chosen = preferredVariant(e)?.url ?? e.url
        var out = variants(of: e).map(\.url).filter { $0 != chosen }
        // même tvg-id sous un autre nom
        if let t = e.tvgId {
            for c in channels where c.id != e.id && c.tvgId == t { out += variants(of: c).map(\.url) }
        }
        return out
    }

    func playlist(of e: IPTVEntry) -> IPTVPlaylist? { playlists.first { $0.id == e.playlist } ?? playlists.first }

    func clearProgress(_ key: String) {
        progress[key] = nil
        saveState()
    }

    func saveProgress(_ key: String, position: Double, duration: Double) {
        progress[key] = [position, duration, Date().timeIntervalSince1970]
        if let i = streams.firstIndex(where: { $0.key == key }) { streams[i].date = Date() }
        saveState()
    }

    // MARK: films et séries

    /// Titres IPTV montrés dans la recherche : retrouvés par leur identifiant pour leur page.
    private var shownRefs: [String: VODRef] = [:]
    func remember(_ r: VODRef) { shownRefs[r.id] = r }
    func remembered(_ id: String) -> VODRef? { shownRefs[id] ?? vodLookup.refs.first { $0.id == id } }

    /// Adresse de lecture d'un film (ou d'un épisode de playlist sans API).
    func url(of r: VODRef) -> String? {
        if let u = r.url { return u }
        guard r.kind == .movie, let id = r.stream, let account = xtreamAccount else { return nil }
        return account.movieURL(id, ext: r.ext ?? "mp4")
    }

    private var xtreamAccount: XtreamAccount? { playlists.lazy.compactMap { XtreamAccount.from(playlistURL: $0.source) }.first }
    private var xtreamPlaylist: IPTVPlaylist? { playlists.first { XtreamAccount.from(playlistURL: $0.source) != nil } }

    /// Épisodes d'une série : get_series_info à l'ouverture (Xtream), sinon les lignes de la playlist.
    func loadEpisodes(_ r: VODRef) async {
        guard episodes[r.id] == nil else { return }
        if let sid = r.stream, r.kind == .series, let p = xtreamPlaylist, let account = xtreamAccount,
           let d = try? await Self.data(account.api("get_series_info", ["series_id": String(sid)]), p) {
            episodes[r.id] = XtreamParser.episodes(d, account: account)
            return
        }
        episodes[r.id] = vodLookup.episodes(of: r).compactMap { e in
            guard let u = e.url, let s = e.season, let n = e.episode else { return nil }
            return VODEpisode(id: e.id, season: s, episode: n, title: "Épisode \(n)", plot: nil, still: nil, duration: nil, url: u)
        }
    }

    // MARK: programme court (Xtream)

    /// Ce qui passe maintenant et ensuite : guide XMLTV s'il y en a un, sinon le programme court demandé au serveur.
    func nowNext(_ e: IPTVEntry) -> (now: ProgramGuide.Program?, next: ProgramGuide.Program?) {
        let g = guide.nowNext(e.tvgId)
        if g.now != nil || g.next != nil { return g }
        guard let list = shortEPG[e.id] else { return (nil, nil) }
        let now = Date()
        let i = list.firstIndex { $0.start <= now && now < $0.stop }
        return (i.map { list[$0] }, list.first { $0.start > now })
    }

    private var epgAsked: [String: Date] = [:]

    /// Programme court d'une chaîne affichée (en tête d'« En direct », dans le lecteur) : une requête, gardée 15 min.
    func loadShortEPG(_ e: IPTVEntry) async {
        guard guide.nowNext(e.tvgId).now == nil, let account = xtreamAccount, let p = xtreamPlaylist,
              Date().timeIntervalSince(epgAsked[e.id] ?? .distantPast) > 900 else { return }
        let raw = variants(of: e).first?.id ?? e.id
        guard let slash = raw.lastIndex(of: "/"), raw[raw.index(after: slash)...].first == "x",
              let sid = Int(raw[raw.index(raw.index(after: slash), offsetBy: 1)...]) else { return }
        epgAsked[e.id] = Date()
        if let d = try? await Self.data(account.api("get_short_epg", ["stream_id": String(sid), "limit": "4"]), p) {
            shortEPG[e.id] = XtreamParser.shortEPG(d)
        }
    }
}
