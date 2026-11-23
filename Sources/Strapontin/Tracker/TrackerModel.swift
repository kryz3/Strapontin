import Foundation
import StrapontinCore

/// L'indexeur Torznab dans Strapontin : recherche, envoi au moteur de téléchargement et suivi automatique des films / séries.
@MainActor
final class TrackerModel: ObservableObject {
    static let shared = TrackerModel()

    @Published var apiKey: String {
        didSet {
            let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if k.isEmpty { try? FileManager.default.removeItem(at: Self.keyURL) } else { SecretFile.write(k, to: Self.keyURL) }
            client = nil
            fromBuild = false
        }
    }
    /// URL complète de l'API Torznab de l'indexeur (Jackett, Prowlarr ou l'indexeur lui-même).
    @Published var endpoint: String { didSet { d.set(endpoint, forKey: "indexerURL"); client = nil; fromBuild = false } }
    /// Indexeur venu de la configuration de build (.env), tant qu'on n'a pas touché aux réglages.
    @Published private(set) var fromBuild: Bool { didSet { d.set(fromBuild, forKey: "indexerFromBuild") } }
    /// Catégories Newznab, séparées par des virgules (vide = 2000 pour les films, 5000 pour les séries).
    @Published var movieCategories: String { didSet { d.set(movieCategories, forKey: "indexerMovieCategories"); client = nil } }
    @Published var tvCategories: String { didSet { d.set(tvCategories, forKey: "indexerTVCategories"); client = nil } }
    @Published var autoEnabled: Bool { didSet { d.set(autoEnabled, forKey: "trackerAuto"); restartLoop() } }
    @Published var checkMinutes: Int { didSet { d.set(checkMinutes, forKey: "trackerMinutes"); restartLoop() } }
    @Published var prefs: GrabPreferences { didSet { saveState() } }
    @Published private(set) var follows: [Follow] = []
    @Published private(set) var history: [GrabRecord] = []

    @Published var results: [TorznabItem] = []
    @Published var searching = false
    @Published var error: String?
    @Published var lastCheck: Date?
    @Published var log: [String] = []

    private let d = UserDefaults.standard
    private var client: TorznabClient?
    private var incompleteChecked = false
    private var loop: Task<Void, Never>?
    private let stateURL: URL

    /// Clé API : un fichier en 0600 dans Application Support (pas le trousseau, voir SecretFile).
    static var keyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strapontin/indexer-key")
    }

    /// Versions d'avant l'indexeur générique : un seul indexeur, clé dans « Strapontin/<nom>-key ». Elle est recopiée
    /// (l'ancien fichier reste, pour une ancienne version de l'app) ; l'adresse de l'API est à saisir une fois.
    private static func migrateLegacyKey() {
        guard SecretFile.read(keyURL) == nil else { return }
        let dir = keyURL.deletingLastPathComponent()
        let legacy = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix("-key") && $0 != keyURL.lastPathComponent }.sorted() ?? []
        if legacy.count == 1, let k = SecretFile.read(dir.appendingPathComponent(legacy[0])), !k.isEmpty {
            SecretFile.write(k, to: keyURL)
        }
    }

    /// Indexeur fourni à la compilation (.env de celui qui compile, jamais en CI : voir scripts/bundle.sh) ou, pendant
    /// le développement, par les variables d'environnement INDEXER_URL / INDEXER_API_KEY. Il ne remplit que des
    /// réglages vides, puis il est recopié dans les réglages : une mise à jour compilée sans .env le garde.
    private static func adoptBuiltInIndexer() {
        func value(_ plist: String, _ env: String) -> String? {
            let v = (Bundle.main.object(forInfoDictionaryKey: plist) as? String) ?? ProcessInfo.processInfo.environment[env]
            let t = v?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        let d = UserDefaults.standard
        if (d.string(forKey: "indexerURL") ?? "").isEmpty, let url = value("StrapontinIndexerURL", "INDEXER_URL") {
            let path = value("StrapontinIndexerPath", "INDEXER_API_PATH") ?? ""
            d.set(Self.join(url, path), forKey: "indexerURL")
            d.set(true, forKey: "indexerFromBuild")
        }
        if SecretFile.read(keyURL) == nil, let key = value("StrapontinIndexerKey", "INDEXER_API_KEY") {
            SecretFile.write(key, to: keyURL)
            d.set(true, forKey: "indexerFromBuild")
        }
    }

    /// Adresse de base + chemin de l'API (« https://x » + « /api » ; un chemin vide garde l'adresse telle quelle).
    static func join(_ base: String, _ path: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        let p = path.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? b : b + (p.hasPrefix("/") ? p : "/" + p)
    }

    private init() {
        Self.migrateLegacyKey()
        Self.adoptBuiltInIndexer()
        // STRAPONTIN_INDEXER_KEY : essais dans une copie isolée de l'app, sans recopier la clé (rien n'est écrit : pas de didSet dans init)
        apiKey = ProcessInfo.processInfo.environment["STRAPONTIN_INDEXER_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? SecretFile.read(Self.keyURL) ?? ""
        endpoint = d.string(forKey: "indexerURL") ?? ""
        fromBuild = d.bool(forKey: "indexerFromBuild")
        movieCategories = d.string(forKey: "indexerMovieCategories") ?? ""
        tvCategories = d.string(forKey: "indexerTVCategories") ?? ""
        autoEnabled = d.object(forKey: "trackerAuto") == nil ? true : d.bool(forKey: "trackerAuto")
        checkMinutes = d.object(forKey: "trackerMinutes") as? Int ?? 15
        prefs = GrabPreferences()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strapontin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("tracker.json")
        loadState()
    }

    var configured: Bool {
        (!apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            || EssaiHarness.fakeTracker != nil
    }

    static func categories(_ s: String) -> [Int] {
        s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
    }

    /// Client pour l'adresse et la clé données (bouton « Tester » des réglages compris).
    func makeClient(endpoint: String? = nil, apiKey: String? = nil) -> TorznabClient {
        TorznabClient(endpoint: endpoint ?? self.endpoint, apiKey: apiKey ?? self.apiKey,
                      movieCategories: Self.categories(movieCategories), tvCategories: Self.categories(tvCategories))
    }

    private func tracker() throws -> TorznabClient {
        guard configured else { throw TorznabError.noKey }
        if let client { return client }
        // copie d'essai : indexeur factice local (torrents publics), sans la clé
        let c = EssaiHarness.fakeTracker.map { TorznabClient(endpoint: $0, apiKey: "essai") } ?? makeClient()
        client = c
        return c
    }

    // MARK: recherche manuelle

    func search(_ q: String, kind: MediaKind?) {
        // « Tout » = films + séries : sans catégorie, un indexeur renvoie aussi le reste (livres, musique…)
        run { [self] in
            let t = try tracker()
            let cats = kind == .movie ? t.movieCategories : kind == .tv ? t.tvCategories : t.movieCategories + t.tvCategories
            results = try await t.search(q, categories: cats)
        }
    }

    /// Tous les résultats pour une fiche (bouton « Chercher » de la fiche de la fiche).
    func search(for media: Media, season: Int? = nil) {
        run { [self] in
            let t = try tracker()
            results = media.kind == .movie
                ? try await t.searchMovie(title: media.originalTitle ?? media.title, year: media.year, tmdbId: media.tmdbId, imdbId: media.imdbId)
                : try await t.searchTV(title: media.originalTitle ?? media.title, otherTitles: [media.title], season: season,
                                       episode: nil, imdbId: media.imdbId, tvdbId: media.tvdbId)
        }
    }

    /// Pastilles de la recherche : une seule recherche texte sur l'indexeur pour toute la requête, comptée fiche par fiche
    /// (identifiant TMDb, sinon titre et année). Les premiers films sans résultat sont revérifiés par leur identifiant
    /// TMDb (titre français tapé, release au titre anglais). Mis en cache pour la session.
    func availability(query: String, for results: [TMDbSearchResult]) async -> [String: Int] {
        guard configured, !results.isEmpty, let t = try? tracker() else { return [:] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var items = availabilityCache[q]
        if items == nil {
            items = try? await t.search(q, categories: t.movieCategories + t.tvCategories)
            if let items { availabilityCache[q] = items }
        }
        guard let items else { return [:] }
        var out: [String: Int] = [:]
        for r in results {
            out[Media.key(r.kind, r.id)] = TrackerAvailability.count(items, kind: r.kind, tmdbId: r.id, title: r.title, year: r.year)
        }
        // une fiche déjà ouverte fait foi : même nombre sur l'affiche de la recherche et dans la fiche
        for (k, n) in availabilityById where out[k] != nil { out[k] = n }
        for r in results.prefix(4) where r.kind == .movie && out[Media.key(r.kind, r.id)] == 0 {
            if Task.isCancelled { break }
            let k = Media.key(r.kind, r.id)
            if let n = availabilityById[k] { out[k] = n; continue }
            guard let found = try? await t.searchMovie(title: r.title, year: r.year, tmdbId: r.id, imdbId: nil) else { continue }
            let n = TrackerAvailability.count(found, kind: .movie, tmdbId: r.id, title: r.title, year: r.year)
            availabilityById[k] = n
            out[k] = n
        }
        return out
    }
    private var availabilityCache: [String: [TorznabItem]] = [:]
    /// Nombre de versions par fiche (film), observé par les pastilles : la fiche et la recherche disent la même chose.
    @Published private(set) var availabilityById: [String: Int] = [:]

    /// Nombre de versions trouvées par la fiche d'un film (source de vérité pour la pastille de la recherche).
    func noteVersions(_ count: Int, for key: String) { availabilityById[key] = count }

    private func run(_ op: @escaping () async throws -> Void) {
        searching = true
        error = nil
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
            searching = false
        }
    }

    /// Versions dispo pour une fiche, la recommandée en premier (nil = ne passe pas les préférences).
    /// Avec `episode` : recherche tvsearch saison + épisode, sans les saisons complètes.
    func versions(for media: Media, season: Int? = nil, episode: Int? = nil) async throws -> [RankedRelease] {
        let t = try tracker()
        let items = media.kind == .movie
            ? try await t.searchMovie(title: media.originalTitle ?? media.title, year: media.year, tmdbId: media.tmdbId, imdbId: media.imdbId)
            : try await t.searchTV(title: media.originalTitle ?? media.title, otherTitles: [media.title], season: season,
                                   episode: episode, imdbId: media.imdbId, tvdbId: media.tvdbId)
        let f = Follow(media: media)
        let ranked = items.compactMap { it -> RankedRelease? in
            let info = ReleaseInfo.parse(it.releaseName)
            // la recherche par titre ramène parfois d'autres œuvres : on ne garde que celle-ci
            guard AutoGrab.matches(it, f) else { return nil }
            if media.kind == .tv, let season, info.season != season { return nil }
            if media.kind == .tv, let season, let episode, !info.isRelease(season: season, episode: episode) { return nil }
            return RankedRelease(item: it, info: info, score: ReleasePicker.score(it, info, prefs: prefs))
        }
        .sorted(by: RankedRelease.better)
        if media.kind == .movie { noteVersions(ranked.count, for: media.key) }
        return ranked
    }

    /// Hashs envoyés au moteur de téléchargement pendant cette session (pour afficher « Envoyé »).
    @Published private(set) var sent: Set<String> = []

    struct Sending {
        var mediaKey: String
        var info: ReleaseInfo
    }
    /// Envois en cours, par release : une série peut en avoir plusieurs à la fois (un par épisode).
    @Published private(set) var sending: [String: Sending] = [:]
    /// Fiches (clé TMDb) dont un envoi est en cours : la fiche affiche « Envoi… » tout de suite.
    var pending: Set<String> { Set(sending.values.map(\.mediaKey)) }

    func isSending(_ mediaKey: String, season: Int, episode: Int) -> Bool {
        sending.values.contains { $0.mediaKey == mediaKey && $0.info.season == season && ($0.info.episodes?.contains(episode) ?? true) }
    }

    func isSendingSeason(_ mediaKey: String, _ season: Int) -> Bool {
        sending.values.contains { $0.mediaKey == mediaKey && $0.info.season == season }
    }

    /// Déjà chez le moteur ? D'après l'empreinte quand on l'a : un téléchargement annulé peut être repris.
    func isSent(_ r: RankedRelease) -> Bool {
        if sending[r.id] != nil { return true }
        guard let h = r.item.infoHash?.lowercased() else { return sent.contains(r.id) }
        return DownloadsModel.shared.torrents.contains { $0.hash.lowercased() == h }
    }
    /// Dernière erreur d'envoi, par fiche, affichée sur la fiche elle-même.
    @Published var grabErrors: [String: String] = [:]

    /// Torrents envoyés pour une fiche (et une saison), du plus récent au plus ancien.
    func hashes(for mediaKey: String, season: Int? = nil) -> [String] {
        history.reversed().filter { $0.followId == mediaKey && (season == nil || $0.season == nil || $0.season == season) }
            .compactMap { $0.infoHash?.lowercased() }
    }

    // MARK: envoi au moteur de téléchargement

    /// Dossier où ranger : « Séries » pour les séries, le premier dossier de la bibliothèque pour le reste.
    func destination(for kind: MediaKind?) -> String? {
        let folders = AppSettings.shared.folders
        if kind == .tv, let s = folders.first(where: { $0.localizedCaseInsensitiveContains("série") || $0.localizedCaseInsensitiveContains("serie") }) {
            return s
        }
        return folders.first { !$0.localizedCaseInsensitiveContains("série") } ?? folders.first
    }

    func grab(_ item: TorznabItem, to dest: String?, follow: Follow? = nil, media: Media? = nil) async throws {
        let engine = try await TorrentEngine.shared.client()
        let info = ReleaseInfo.parse(item.releaseName)
        if let h = item.infoHash?.lowercased(), try await engine.knownHashes().contains(h) {
            // déjà chez le moteur (glissé-déposé…) : rien à renvoyer, mais il prend cette fiche et cet épisode
            if let m = media ?? follow?.asMedia {
                DownloadsModel.shared.link(hash: h, media: m, mediaKey: m.key, season: info.season, episode: info.episode,
                                           episodeEnd: info.episodeEnd, source: .tracker)
            }
            return
        }
        // une fois pour toutes : qBittorrent marque les fichiers incomplets, la bibliothèque les ignore jusqu'à la fin
        // (le moteur intégré les range déjà dans un dossier à part)
        if !incompleteChecked, let qbit = engine as? QbitClient {
            if (try? await qbit.incompleteFilesHidden()) == false { try? await qbit.hideIncompleteFiles() }
            incompleteChecked = true
        }
        let payload = try await tracker().fetchTorrent(item)
        try await send(payload, release: item.releaseName, media: media ?? follow?.asMedia, season: info.season,
                       episode: info.episode, episodeEnd: info.episodeEnd, infoHash: item.infoHash, to: dest, engine: engine)
        sent.insert(item.id)
    }

    /// Envoi au moteur + historique. L'empreinte vient de l'indexeur, sinon du .torrent lui-même :
    /// c'est elle qui relie le téléchargement à sa fiche (progression affichée sur la fiche).
    func send(_ payload: TorrentPayload, release: String, media: Media?, season: Int?, episode: Int?, episodeEnd: Int?,
              infoHash: String?, to dest: String?, engine: any TorrentClient) async throws {
        let hash = (infoHash ?? payload.infoHash)?.lowercased()
        // lien torrent ↔ fiche noté avant l'envoi : l'affiche porte la bonne fiche dès le premier passage
        if let hash {
            DownloadsModel.shared.link(hash: hash, media: media, mediaKey: media?.key, season: season, episode: episode,
                                       episodeEnd: episodeEnd, source: media == nil ? .manual : .tracker)
            // l'affiche apparaît tout de suite dans « En téléchargement », sans attendre le moteur
            DownloadsModel.shared.showStarting(hash: hash, name: release, savePath: dest)
        }
        do {
            try await engine.add(payload, savePath: dest)
        } catch {
            if let hash { DownloadsModel.shared.dropStarting(hash: hash) }
            throw error
        }
        history.append(GrabRecord(followId: media?.key ?? "", season: season, episode: episode,
                                  infoHash: hash, release: release, date: Date()))
        note("↓ \(release)")
        saveState()
        DownloadsModel.shared.refreshSoon()
    }

    /// Fiche d'où l'on a ouvert la recherche « autrement » sur l'indexeur : ce qu'on y prend lui est rattaché.
    @Published var searchContext: Media?

    func grabManually(_ item: TorznabItem, to dest: String?) {
        let media = searchContext
        Task {
            do { error = nil; try await grab(item, to: dest ?? destination(for: media?.kind), media: media) } catch { self.error = error.localizedDescription }
        }
    }

    /// Depuis une fiche : l'état (envoi en cours, erreur) s'affiche sur la fiche.
    func grab(_ r: RankedRelease, media: Media) { grab([r], media: media) }

    /// Une ou plusieurs releases (« les épisodes manquants ») : toutes marquées « Envoi… » tout de suite, envoyées l'une après l'autre.
    func grab(_ releases: [RankedRelease], media: Media) {
        let key = media.key
        var todo: [RankedRelease] = []
        for r in releases where sending[r.id] == nil {
            // film : un envoi à la fois ; série : pas deux fois le même épisode
            if media.kind == .movie, pending.contains(key) { continue }
            if media.kind == .tv, let s = r.info.season {
                let busy = r.info.episodes.map { $0.contains { isSending(key, season: s, episode: $0) } } ?? isSendingSeason(key, s)
                if busy { continue }
            }
            sending[r.id] = Sending(mediaKey: key, info: r.info)
            todo.append(r)
        }
        guard !todo.isEmpty else { return }
        grabErrors[key] = nil
        Task {
            for r in todo {
                do {
                    try await grab(r.item, to: destination(for: media.kind), media: media)
                    // avant d'enlever « Envoi… », sinon « Télécharger » réapparaît un instant
                    await DownloadsModel.shared.refresh()
                } catch { grabErrors[key] = error.localizedDescription }
                sending[r.id] = nil
            }
        }
    }

    // MARK: suivi

    func isFollowed(_ m: Media) -> Bool { follows.contains { $0.id == m.key } }

    /// backfill : cherche tout de suite (film, ou toutes les saisons manquantes d'une série).
    /// Sans backfill, une série ne prend que ce qui sort, à partir de la dernière saison qu'on a sur le disque.
    func follow(_ m: Media, backfill doBackfill: Bool) {
        guard !isFollowed(m) else { return }
        let lastOwned = LibraryStore.shared.files.filter { $0.mediaKey == m.key }.compactMap(\.season).max()
        let f = Follow(media: m, fromSeason: doBackfill ? 1 : (lastOwned ?? 1))
        follows.append(f)
        saveState()
        if doBackfill { Task { await backfill(f) } }
    }

    func unfollow(_ id: String) {
        follows.removeAll { $0.id == id }
        saveState()
    }

    func start() { restartLoop() }

    private func restartLoop() {
        loop?.cancel()
        guard autoEnabled else { loop = nil; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNew()
                let m = max(5, self?.checkMinutes ?? 15)   // les indexeurs demandent de rester raisonnable
                try? await Task.sleep(nanoseconds: UInt64(m) * 60_000_000_000)
            }
        }
    }

    /// Passage périodique : les 100 derniers films + séries publiés, comparés à la liste de suivi.
    func checkNew() async {
        guard configured, TorrentEngine.shared.available, !follows.isEmpty else { return }
        do {
            let t = try tracker()
            let items = try await t.search("", categories: t.movieCategories + t.tvCategories, limit: 100)
            lastCheck = Date()
            await apply(items, follows: follows)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func backfill(_ f: Follow) async {
        do {
            let t = try tracker()
            let items = f.kind == .movie
                ? try await t.searchMovie(title: f.originalTitle ?? f.title, year: f.year, tmdbId: f.tmdbId, imdbId: f.imdbId)
                : try await t.searchTV(title: f.originalTitle ?? f.title, otherTitles: [f.title], season: nil, episode: nil,
                                       imdbId: f.imdbId, tvdbId: f.tvdbId)
            await apply(items, follows: [f])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ items: [TorznabItem], follows: [Follow]) async {
        let store = LibraryStore.shared
        var owned: [String: Set<EpisodeKey>] = [:]
        var ownedMovies = Set<String>()
        for file in store.files {
            guard let k = file.mediaKey else { continue }
            if let s = file.season, let e = file.episode { owned[k, default: []].insert(EpisodeKey(s, e)) }
            else if !file.isEpisode { ownedMovies.insert(k) }
        }
        // ce qui est déjà chez le moteur compte aussi (choisi à la main, glissé-déposé) : pas de doublon
        await DownloadsModel.shared.refresh()
        for f in follows where f.kind == .tv {
            owned[f.id, default: []].formUnion(EpisodeRules.owned(store.files.filter { $0.mediaKey == f.id }))
            owned[f.id, default: []].formUnion(EpisodeTransfer.occupied(DownloadsModel.shared.allTransfers(for: f.id)))
            for s in sending.values where s.mediaKey == f.id {
                guard let n = s.info.season else { continue }
                for e in s.info.episodes ?? 0...0 { owned[f.id, default: []].insert(EpisodeKey(n, e)) }
            }
        }
        let decisions = AutoGrab.decide(items: items, follows: follows, owned: owned, ownedMovies: ownedMovies,
                                        history: history, prefs: prefs)
        for dec in decisions {
            // pris à la main pendant ce passage
            if dec.follow.kind == .tv, let s = dec.info.season, let e = dec.info.episode,
               isSending(dec.follow.id, season: s, episode: e)
                || DownloadsModel.shared.allTransfers(for: dec.follow.id).contains(where: { $0.covers(season: s, episode: e) }) { continue }
            do {
                try await grab(dec.item, to: destination(for: dec.follow.kind), follow: dec.follow)
            } catch {
                note("✗ \(dec.item.releaseName) : \(error.localizedDescription)")
            }
        }
    }

    private func note(_ s: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(s)", at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    // MARK: persistance (la clé API est dans son propre fichier, indexer-key, pas ici)

    private struct State: Codable { var follows: [Follow]; var history: [GrabRecord]; var prefs: GrabPreferences }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        follows = s.follows
        history = s.history
        prefs = s.prefs
    }

    private func saveState() {
        let s = State(follows: follows, history: Array(history.suffix(2000)), prefs: prefs)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }
}

struct RankedRelease: Identifiable {
    var id: String { item.id }
    var item: TorznabItem
    var info: ReleaseInfo
    var score: Double?

    static func better(_ a: RankedRelease, _ b: RankedRelease) -> Bool {
        (a.score ?? -1, a.item.seeders ?? 0) > (b.score ?? -1, b.item.seeders ?? 0)
    }
}
