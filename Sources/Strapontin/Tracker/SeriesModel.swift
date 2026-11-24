import Foundation
import StrapontinCore

/// Une série, partagée par sa fiche et les fiches de ses épisodes : saisons, épisodes TMDb, versions sur l'indexeur.
/// L'état d'un épisode n'est jamais copié ici : il se calcule à chaque affichage depuis la bibliothèque,
/// le moteur et les envois en cours (une seule source de vérité).
@MainActor
final class SeriesModel: ObservableObject {
    private static var cache: [Int: SeriesModel] = [:]

    static func of(_ tmdbId: Int) -> SeriesModel {
        if let m = cache[tmdbId] { return m }
        let m = SeriesModel(tmdbId: tmdbId)
        cache[tmdbId] = m
        return m
    }

    let tmdbId: Int
    let key: String

    @Published private(set) var media: Media?
    @Published private(set) var loadFailed: String?
    @Published private(set) var tmdbSeasons: [Int] = []
    /// Saison affichée : gardée au retour d'une fiche d'épisode, et elle suit « Épisode suivant ».
    @Published var selected: Int?
    @Published private(set) var episodes: [Int: [Int: EpisodeInfo]] = [:]
    @Published private(set) var loadingEpisodes: Set<Int> = []
    /// Releases de la saison (épisodes et saisons complètes), la recommandée d'abord. Absent = pas encore cherché.
    @Published private(set) var releases: [Int: [RankedRelease]] = [:]
    @Published private(set) var loadingReleases: Set<Int> = []
    @Published private(set) var releaseErrors: [Int: String] = [:]
    @Published private(set) var searchingEpisodes: Set<EpisodeKey> = []

    private var releasesDate: [Int: Date] = [:]
    private var episodeDate: [EpisodeKey: Date] = [:]
    private var detailed = false
    private var loading: Task<Void, Never>?
    private static let freshness: TimeInterval = 300

    private var tracker: TrackerModel { TrackerModel.shared }
    private var downloads: DownloadsModel { DownloadsModel.shared }
    private var store: LibraryStore { LibraryStore.shared }

    private init(tmdbId: Int) {
        self.tmdbId = tmdbId
        key = Media.key(.tv, tmdbId)
        media = LibraryStore.shared.media[key]
    }

    private func tmdb() -> TMDbClient? {
        let s = AppSettings.shared
        return s.effectiveTMDbKey.isEmpty ? nil : TMDbClient(key: s.effectiveTMDbKey, language: s.tmdbLanguage, omdbKey: s.omdbKey)
    }

    // MARK: chargement (hors de la tâche de la vue : quitter la page ne doit pas afficher « injoignable »)

    func load() async {
        if detailed { return }
        if let loading { return await loading.value }
        let task = Task {
            loadFailed = nil
            guard let c = tmdb() else {
                if media == nil { loadFailed = "Ajoute ta clé TMDb dans Réglages › Fiches." }
                return
            }
            do {
                // toujours la fiche fraîche : une fiche enregistrée avant n'a pas forcément l'identifiant TheTVDB
                media = try await c.details(.tv, id: tmdbId)
                tmdbSeasons = await c.seasonNumbers(tvId: tmdbId)
                detailed = !tmdbSeasons.isEmpty
            } catch {
                if media == nil { loadFailed = error.localizedDescription }
            }
        }
        loading = task
        await task.value
        loading = nil
        if selected == nil { selected = initialSeason }
    }

    func show(season: Int) {
        Task {
            await load()
            await loadEpisodes(season)
            await loadReleases(season)
        }
    }

    /// Pour l'épisode suivant : TMDb seulement, pas de recherche sur l'indexeur à chaque lecture.
    func prepareNext(after season: Int) {
        Task {
            await load()
            await loadEpisodes(season)
            if let n = tmdbSeasons.first(where: { $0 > season }), season > 0 { await loadEpisodes(n) }
        }
    }

    func reloadEpisodes(_ season: Int) {
        Task { await loadEpisodes(season) }
    }

    private func loadEpisodes(_ season: Int) async {
        guard episodes[season]?.isEmpty ?? true, !loadingEpisodes.contains(season), let c = tmdb() else { return }
        loadingEpisodes.insert(season)
        episodes[season] = await c.seasonEpisodes(tvId: tmdbId, season: season)
        loadingEpisodes.remove(season)
    }

    private func loadReleases(_ season: Int) async {
        guard tracker.configured, let media, !loadingReleases.contains(season) else { return }
        if let d = releasesDate[season], Date().timeIntervalSince(d) < Self.freshness { return }
        loadingReleases.insert(season)
        do {
            let found = sameShow(try await tracker.versions(for: media, season: season), season: season)
            releases[season] = found
            releaseErrors[season] = nil
            releasesDate[season] = Date()
            episodeDate = episodeDate.filter { $0.key.season != season }
        } catch { releaseErrors[season] = error.localizedDescription }
        loadingReleases.remove(season)
    }

    /// Fiche d'un épisode : recherche saison + épisode, versée dans la saison (la ligne et la fiche disent le même nombre).
    func show(season: Int, episode: Int) {
        Task {
            await load()
            await loadEpisodes(season)
            await loadReleases(season)
            let k = EpisodeKey(season, episode)
            guard tracker.configured, let media, !searchingEpisodes.contains(k) else { return }
            if let d = episodeDate[k], Date().timeIntervalSince(d) < Self.freshness { return }
            searchingEpisodes.insert(k)
            do {
                let found = sameShow(try await tracker.versions(for: media, season: season, episode: episode), season: season)
                var all = releases[season] ?? []
                var ids = Set(all.map(\.id))
                for r in found where ids.insert(r.id).inserted { all.append(r) }
                releases[season] = all.sorted(by: RankedRelease.better)
                releaseErrors[season] = nil
                episodeDate[k] = Date()
            } catch { releaseErrors[season] = error.localizedDescription }
            searchingEpisodes.remove(k)
        }
    }

    /// Retire les homonymes que seule l'année trahit (releases sans identifiant TMDb).
    private func sameShow(_ list: [RankedRelease], season: Int) -> [RankedRelease] {
        let dates = (episodes[season] ?? [:]).values.compactMap(\.airDate)
        return list.filter { r in
            r.item.tmdbId != nil || EpisodeRules.yearFits(r.info.year, seriesYear: media?.year, airDates: dates)
        }
    }

    // MARK: saisons et épisodes

    var files: [MediaFile] { store.files.filter { $0.mediaKey == key } }

    var seasons: [Int] {
        let owned = files.compactMap { $0.episode == nil ? nil : $0.season }
        let coming = downloads.allTransfers(for: key).map(\.season)
        return Set(tmdbSeasons + owned + coming).sorted()
    }

    /// À l'ouverture : la saison qu'on regarde, sinon celle qui télécharge, sinon la première.
    private var initialSeason: Int {
        if let item = store.item(id: key) {
            if let s = item.resumeTarget?.season ?? item.files.first(where: { !$0.watched })?.season { return s }
            let have = Set(item.files.compactMap(\.season))
            if let s = tmdbSeasons.first(where: { !have.contains($0) }) ?? tmdbSeasons.last { return s }
        }
        if let s = downloads.allTransfers(for: key).first(where: { !$0.torrent.isDone })?.season { return s }
        return seasons.first(where: { $0 > 0 }) ?? 1
    }

    func info(_ season: Int, _ episode: Int) -> EpisodeInfo? { episodes[season]?[episode] }

    func file(_ season: Int, _ episode: Int) -> MediaFile? {
        let mine = files.filter { EpisodeRules.owned([$0]).contains(EpisodeKey(season, episode)) }
        return mine.first(where: \.inProgress) ?? mine.first
    }

    // MARK: versions

    func versions(_ season: Int, _ episode: Int) -> [RankedRelease] {
        (releases[season] ?? []).filter { $0.info.isRelease(season: season, episode: episode) }
    }

    func packs(_ season: Int) -> [RankedRelease] {
        (releases[season] ?? []).filter { $0.info.isSeasonPack }
    }

    // MARK: état

    /// Tout ce qu'il faut pour dessiner une saison, calculé une fois par affichage.
    struct Snapshot {
        var season: Int
        var numbers: [Int]
        var statuses: [Int: EpisodeStatus]
        var files: [Int: MediaFile]
        var plan: SeasonPlan
        var packs: [RankedRelease]
        var busy: Bool
    }

    func snapshot(_ season: Int) -> Snapshot {
        let mine = files
        var byEpisode: [Int: MediaFile] = [:]
        for f in mine where f.season == season {
            for k in EpisodeRules.owned([f]) {
                if byEpisode[k.episode] == nil || f.inProgress { byEpisode[k.episode] = f }
            }
        }
        let transfers = downloads.transfers(for: key, files: mine).filter { $0.season == season }
        let owned = Set(byEpisode.keys.map { EpisodeKey(season, $0) })
        let found = releases[season]
        var count: [Int: Int] = [:]
        var downloadable = Set<Int>()
        for r in found ?? [] {
            guard let eps = r.info.episodes else { continue }
            for e in eps {
                count[e, default: 0] += 1
                if r.score != nil { downloadable.insert(e) }
            }
        }
        let infos = episodes[season] ?? [:]
        var numbers = Set(infos.keys).union(byEpisode.keys)
        for t in transfers { numbers.formUnion(t.episodes.map { Array($0) } ?? []) }
        // TMDb muet : au moins les épisodes que l'indexeur connaît
        if infos.isEmpty { numbers.formUnion(count.keys) }
        let packs = self.packs(season)
        let today = Self.today()
        var statuses: [Int: EpisodeStatus] = [:]
        for e in numbers {
            statuses[e] = EpisodeRules.status(season: season, episode: e, owned: owned, transfers: transfers,
                                              sending: tracker.isSending(key, season: season, episode: e),
                                              versions: found == nil ? nil : count[e, default: 0],
                                              hasPack: !packs.isEmpty, airDate: infos[e]?.airDate, today: today)
        }
        let busy = !transfers.isEmpty || tracker.isSendingSeason(key, season)
        let plan = SeasonPlan(statuses: statuses, hasPack: packs.contains { $0.score != nil }, seasonBusy: busy, downloadable: downloadable)
        return Snapshot(season: season, numbers: numbers.sorted(), statuses: statuses, files: byEpisode, plan: plan, packs: packs, busy: busy)
    }

    static func today() -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Un groupe « E01E02 » dont un des épisodes est déjà en route ne se propose pas.
    func overlapsBusy(_ r: RankedRelease, _ snap: Snapshot) -> Bool {
        guard let eps = r.info.episodes else { return snap.busy }
        return eps.contains { snap.statuses[$0]?.isBusy == true }
    }

    // MARK: actions

    func recommended(_ episode: Int, _ snap: Snapshot) -> RankedRelease? {
        versions(snap.season, episode).first { $0.score != nil && !overlapsBusy($0, snap) }
    }

    func downloadEpisode(season: Int, episode: Int) {
        let snap = snapshot(season)
        guard let media, case .available = snap.statuses[episode], let best = recommended(episode, snap) else { return }
        tracker.grab(best, media: media)
    }

    func downloadSeason(_ season: Int) {
        let snap = snapshot(season)
        guard let media, snap.plan.offerPack, let best = snap.packs.first(where: { $0.score != nil }) else { return }
        tracker.grab(best, media: media)
    }

    func downloadMissing(_ season: Int) {
        let snap = snapshot(season)
        guard let media else { return }
        let candidates = (releases[season] ?? []).filter { r in
            guard r.score != nil, let eps = r.info.episodes else { return false }
            // rien qui recouvre un épisode déjà là ou déjà en route
            return eps.allSatisfy { e in
                let s = snap.statuses[e]
                return s != .owned && s?.isBusy != true
            }
        }
        tracker.grab(SeasonPlan.picks(snap.plan.missing, candidates: candidates) { $0.info.episodes }, media: media)
    }
}

/// Navigation : « ep:126308:1:3 » ouvre la fiche de l'épisode.
enum EpisodeLink {
    static func value(_ tmdbId: Int, _ season: Int, _ episode: Int) -> String { "ep:\(tmdbId):\(season):\(episode)" }

    static func parse(_ s: String) -> (tmdbId: Int, season: Int, episode: Int)? {
        let p = s.split(separator: ":")
        guard p.count == 4, p[0] == "ep", let id = Int(p[1]), let season = Int(p[2]), let e = Int(p[3]) else { return nil }
        return (id, season, e)
    }
}
