import StrapontinCore
import SwiftUI

/// Films et séries des playlists IPTV, rapprochés de TMDb pour se fondre dans Films / Séries : un titre = une fiche,
/// avec « Regarder en streaming » à côté de « Lire » et « Télécharger ». Les titres non reconnus restent visibles
/// dans « Autres titres IPTV ».
///
/// Le rapprochement tourne en tâche de fond, quelques titres par seconde, et se garde en cache (aucune adresse dedans :
/// titre normalisé → fiche TMDb).
@MainActor
final class IPTVCatalog: ObservableObject {
    static let shared = IPTVCatalog()

    struct Match: Codable, Hashable {
        var id: Int            // 0 = pas reconnu
        var title: String
        var year: Int?
        var poster: String?
    }

    /// Clé de titre (VODMatch.key) → fiche TMDb.
    @Published private(set) var matches: [String: Match] = [:]
    /// Titres encore à rapprocher.
    @Published private(set) var pending = 0
    /// Fiche (Media.key) → sources IPTV de ce titre.
    @Published private(set) var sources: [String: [VODItem]] = [:]

    private var task: Task<Void, Never>?
    private let cacheURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin/IPTV")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("tmdb-rapprochements.json")
        if let d = try? Data(contentsOf: cacheURL), let m = try? JSONDecoder().decode([String: Match].self, from: d) { matches = m }
    }

    // MARK: titres

    /// Titre d'un élément du catalogue (séries de playlist : sans « S01 E02 »).
    static func baseTitle(_ v: VODItem) -> String {
        v.name.replacingOccurrences(of: #"(?i)\s*s\d{1,2}\s?e\d{1,3}.*$"#, with: "", options: .regularExpression)
    }

    static func titleKey(_ v: VODItem) -> String {
        VODMatch.key(kind: v.kind, title: baseTitle(v), year: v.year ?? VODTitle.year(v.name))
    }

    static func mediaKind(_ v: VODItem) -> MediaKind { v.kind == .series ? .tv : .movie }

    /// Ce qui distingue deux sources d'un même titre : qualité et langue (« 4K · MULTI »).
    static func sourceLabel(_ v: VODItem) -> String {
        let up = v.name.uppercased()
        var parts: [String] = []
        let q = ChannelName.parse(v.name).quality
        if q != .unknown { parts.append(q.label) }
        for tag in ["MULTI", "VOSTFR", "VF", "VO"] where up.range(of: "\\b\(tag)\\b", options: .regularExpression) != nil {
            parts.append(tag); break
        }
        return parts.isEmpty ? "Standard" : parts.joined(separator: " · ")
    }

    // MARK: rapprochement

    /// À chaque chargement des playlists : sources par fiche, puis rapprochement des titres nouveaux.
    func refresh() {
        rebuild()
        task?.cancel()
        let items = IPTVStore.shared.catalogItems
        var todo: [(String, VODItem)] = []
        var seen = Set<String>()
        for v in items {
            let k = Self.titleKey(v)
            if matches[k] == nil, seen.insert(k).inserted { todo.append((k, v)) }
        }
        pending = todo.count
        guard !todo.isEmpty else { return }
        let s = AppSettings.shared
        guard !s.effectiveTMDbKey.isEmpty else { pending = 0; return }
        let c = TMDbClient(key: s.effectiveTMDbKey, language: s.tmdbLanguage, omdbKey: s.omdbKey)
        task = Task { [weak self] in
            var done = 0
            for (k, v) in todo {
                if Task.isCancelled { return }
                let m = await Self.match(v, client: c)
                guard let self else { return }
                if let m { self.matches[k] = m }
                done += 1
                self.pending = todo.count - done
                if done % 40 == 0 { self.rebuild(); self.save() }
                try? await Task.sleep(for: .milliseconds(120))   // reste sous les limites de TMDb
            }
            self?.rebuild()
            self?.save()
        }
    }

    private static func match(_ v: VODItem, client c: TMDbClient) async -> Match? {
        let kind = mediaKind(v)
        if let id = v.tmdbId, id > 0 {
            guard let m = try? await c.details(kind, id: id) else { return nil }
            return Match(id: id, title: m.title, year: m.year, poster: m.posterPath)
        }
        let title = VODTitle.clean(baseTitle(v))
        let year = v.year ?? VODTitle.year(v.name)
        guard let res = try? await c.search(kind, title: title, year: year) else { return nil }   // réseau : on réessaiera
        var best = VODMatch.best(res, title: title, year: year)
        if best == nil, year != nil, let more = try? await c.search(kind, title: title, year: nil) {
            best = VODMatch.best(more, title: title, year: year)
        }
        guard let best else { return Match(id: 0, title: title, year: year, poster: nil) }
        return Match(id: best.id, title: best.title, year: best.year, poster: best.posterPath)
    }

    private func rebuild() {
        var out: [String: [VODItem]] = [:]
        for v in IPTVStore.shared.catalogItems {
            guard let m = matches[Self.titleKey(v)], m.id > 0 else { continue }
            out[Media.key(Self.mediaKind(v), m.id), default: []].append(v)
        }
        // meilleure qualité d'abord
        for (k, list) in out {
            out[k] = list.sorted { ChannelName.parse($0.name).quality > ChannelName.parse($1.name).quality }
        }
        sources = out
    }

    private func save() {
        if let d = try? JSONEncoder().encode(matches) {
            FileManager.default.createFile(atPath: cacheURL.path, contents: d, attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: pour les pages

    func sources(_ kind: MediaKind, _ tmdbId: Int) -> [VODItem] { sources[Media.key(kind, tmdbId)] ?? [] }
    func hasStream(_ mediaKey: String) -> Bool { sources[mediaKey] != nil }

    /// Titres reconnus, en rangées par catégorie du fournisseur (« Action », « Comédie »…), pays choisi seulement.
    func shelves(_ kind: MediaKind) -> [(String, [TMDbSearchResult])] {
        let store = IPTVStore.shared
        let applies = store.country.map { c in store.vodCountries.contains { $0.code == c } } ?? false
        var rows: [String: [TMDbSearchResult]] = [:]
        var order: [String] = []
        var seen = Set<String>()
        for v in store.catalogItems where Self.mediaKind(v) == kind && (!applies || store.inCountry(v)) {
            guard let m = matches[Self.titleKey(v)], m.id > 0, seen.insert("\(m.id)").inserted else { continue }
            let shelf = Self.shelfName(v.category, kind: kind)
            if rows[shelf] == nil { order.append(shelf) }
            rows[shelf, default: []].append(TMDbSearchResult(kind: kind, tmdbId: m.id, title: m.title, year: m.year,
                                                             posterPath: m.poster))
        }
        return order.map { ($0, rows[$0]!) }.sorted { $0.1.count > $1.1.count }
    }

    /// Titres non reconnus (ou pas encore rapprochés si TMDb n'est pas branché).
    func unmatched(_ kind: MediaKind) -> [VODItem] {
        let store = IPTVStore.shared
        let applies = store.country.map { c in store.vodCountries.contains { $0.code == c } } ?? false
        return store.catalogItems.filter { v in
            Self.mediaKind(v) == kind && (!applies || store.inCountry(v)) && (matches[Self.titleKey(v)]?.id ?? 0) == 0
        }
    }

    /// « VOD | FR | Action » → « Action » ; sans rien d'utile → « Films en streaming ».
    static func shelfName(_ category: String, kind: MediaKind) -> String {
        var rest = category
        for _ in 0..<3 {
            let (_, r) = IPTVCountry.stripPrefix(rest)
            let words = r.split(whereSeparator: { " |:-".contains($0) })
            let noise: Set<String> = ["VOD", "FILMS", "FILM", "MOVIES", "SERIES", "SÉRIES", "SERIE", "SÉRIE", "TV", "VIP", "4K"]
            let kept = words.drop { noise.contains($0.uppercased()) }
            let next = kept.joined(separator: " ")
            if next == rest { break }
            rest = next
        }
        let t = rest.trimmingCharacters(in: .whitespaces)
        let fallback = kind == .tv ? "Séries en streaming" : "Films en streaming"
        if t.isEmpty || IPTVCountry.detect(group: t, name: "") != nil && t.count <= 7 { return fallback }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: séries : épisodes

    /// Épisodes en streaming d'une série reconnue (chargés à la demande pour les comptes Xtream).
    func episodes(_ tmdbId: Int) -> [VODEpisode] {
        let store = IPTVStore.shared
        for v in sources(.tv, tmdbId) {
            let list = v.seriesId != nil ? (store.episodes[v.id] ?? []) : store.playlistEpisodes(of: v)
            if !list.isEmpty { return list }
        }
        return []
    }

    func loadEpisodes(_ tmdbId: Int) async {
        for v in sources(.tv, tmdbId) where v.seriesId != nil { await IPTVStore.shared.loadEpisodes(v) }
        objectWillChange.send()
    }

    func episode(_ tmdbId: Int, season: Int, episode: Int) -> VODEpisode? {
        episodes(tmdbId).first { $0.season == season && $0.episode == episode }
    }

    // MARK: lecture

    /// Lecture en streaming ; la reprise est commune avec la bibliothèque (le plus récent l'emporte).
    static func play(_ v: VODItem, url: String, mediaKey: String?, title: String, subtitle: String? = nil, progressKey: String,
                     libraryFile: MediaFile? = nil) {
        let store = IPTVStore.shared
        var start = 0.0
        if let p = store.progress[progressKey], p[0] > 30, p[0] < p[1] * 0.95 { start = p[0] }
        if let f = libraryFile, f.inProgress, let t = f.lastPlayed,
           t > (store.progress[progressKey].flatMap { $0.count > 2 ? $0[2] : nil } ?? 0) {
            start = f.position
        }
        store.noteStream(StreamRecord(key: progressKey, mediaKey: mediaKey, title: title, subtitle: subtitle, date: Date()))
        PlayerController.play([PlayItem(path: url, title: title, subtitle: subtitle, start: start, progressKey: progressKey)])
    }
}

/// Une lecture en streaming, pour l'historique et la reprise.
struct StreamRecord: Codable, Hashable, Identifiable {
    var key: String
    var mediaKey: String?
    var title: String
    var subtitle: String?
    var date: Date
    var id: String { key }
}

/// « Regarder en streaming » sur une fiche de film : la meilleure source d'un clic, les autres dans un menu.
struct StreamButton: View {
    let kind: MediaKind
    let tmdbId: Int
    let title: String
    var libraryFile: MediaFile? = nil
    @ObservedObject private var catalog = IPTVCatalog.shared
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        let list = catalog.sources(kind, tmdbId).filter { $0.url != nil }
        if kind == .movie, let best = list.first, let url = best.url {
            let key = Media.key(kind, tmdbId)
            let p = store.progress["stream:" + key]
            let resume = p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false
            HStack(spacing: 8) {
                PlayPill(title: resume ? "Reprendre en streaming" : "Regarder en streaming", icon: "play.tv") {
                    IPTVCatalog.play(best, url: url, mediaKey: key, title: title, progressKey: "stream:" + key, libraryFile: libraryFile)
                }
                .help(IPTVCatalog.sourceLabel(best))
                if list.count > 1 {
                    Menu {
                        ForEach(list, id: \.id) { v in
                            Button(IPTVCatalog.sourceLabel(v)) {
                                IPTVCatalog.play(v, url: v.url!, mediaKey: key, title: title, progressKey: "stream:" + key,
                                                 libraryFile: libraryFile)
                            }
                        }
                    } label: { Image(systemName: "dial.medium").font(.system(size: 15, weight: .bold)) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(CircleButtonStyle())
                    .fixedSize()
                    .help("Choisir la qualité")
                }
            }
        }
    }
}

/// Petit badge « IPTV » sur une affiche : le titre se regarde en streaming.
struct StreamBadge: View {
    let mediaKey: String
    @ObservedObject private var catalog = IPTVCatalog.shared

    var body: some View {
        if catalog.hasStream(mediaKey) {
            Image(systemName: "play.tv.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(5).background(.black.opacity(0.55), in: Circle())
                .padding(8)
                .help("À regarder en streaming (IPTV)")
        }
    }
}

/// Recherche : les titres IPTV que TMDb ne connaît pas (les autres apparaissent déjà dans les résultats du catalogue,
/// avec leur badge).
struct IPTVTitleSearchSection: View {
    let query: String
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var catalog = IPTVCatalog.shared
    @State private var found: [VODItem] = []

    var body: some View {
        Group {
            if !found.isEmpty {
                Shelf(title: "Autres titres IPTV") { ForEach(found, id: \.id) { VODCard(item: $0) } }
            }
        }
        .task(id: query) {
            let index = store.vodIndex, q = query
            let ids = await Task.detached(priority: .userInitiated) { index.search(q, kinds: [.movie, .series], limit: 60).map(\.id) }.value
            guard !Task.isCancelled else { return }
            let byId = Dictionary(store.catalogItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            found = ids.compactMap { byId[$0] }.filter { (catalog.matches[IPTVCatalog.titleKey($0)]?.id ?? 0) == 0 }
        }
    }
}
