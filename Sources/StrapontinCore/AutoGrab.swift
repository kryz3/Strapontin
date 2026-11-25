import Foundation

/// Une série ou un film que l'app surveille sur l'indexeur.
public struct Follow: Codable, Identifiable, Hashable, Sendable {
    public var id: String { Media.key(kind, tmdbId) }
    public var kind: MediaKind
    public var tmdbId: Int
    public var imdbId: String?
    public var tvdbId: Int?
    public var title: String               // titre TMDb (français)
    public var originalTitle: String?
    public var year: Int?
    public var posterPath: String?
    /// Séries : on ne prend que les épisodes à partir de cette saison (les nouveautés, pas tout l'historique).
    public var fromSeason: Int
    public var added: Date
    /// Qualité propre à ce suivi (nil = celle des réglages).
    public var quality: QualityChoice?

    public init(media: Media, fromSeason: Int = 1) {
        kind = media.kind; tmdbId = media.tmdbId; imdbId = media.imdbId; tvdbId = media.tvdbId
        title = media.title; originalTitle = media.originalTitle; year = media.year; posterPath = media.posterPath
        self.fromSeason = fromSeason; added = Date()
    }

    public var titles: [String] { [title, originalTitle].compactMap { $0 } }
}

/// Ce qu'on a déjà envoyé au moteur de téléchargement, pour ne pas le reprendre au prochain passage.
public struct GrabRecord: Codable, Hashable, Sendable {
    /// Fiche concernée (clé TMDb, « movie:123 »), suivie ou téléchargée depuis sa fiche ; vide si envoi depuis la recherche brute.
    public var followId: String
    public var season: Int?
    public var episode: Int?
    public var infoHash: String?
    public var release: String
    public var date: Date

    public init(followId: String, season: Int?, episode: Int?, infoHash: String?, release: String, date: Date) {
        self.followId = followId; self.season = season; self.episode = episode
        self.infoHash = infoHash; self.release = release; self.date = date
    }
}

public struct GrabDecision: Sendable {
    public var follow: Follow
    public var item: TorznabItem
    public var info: ReleaseInfo
}

/// Décide quoi télécharger dans un lot de résultats (flux des nouveautés ou recherche ciblée).
/// Fonction pure : pas de réseau, testable.
public enum AutoGrab {
    /// - owned : épisodes déjà sur le disque, par fiche → [(saison, épisode)]
    /// - ownedMovies : fiches de films déjà présentes
    public static func decide(items: [TorznabItem], follows: [Follow], owned: [String: Set<EpisodeKey>],
                              ownedMovies: Set<String>, history: [GrabRecord],
                              prefs globalPrefs: GrabPreferences, styles: [String: SeriesStyle] = [:]) -> [GrabDecision] {
        let grabbedHashes = Set(history.compactMap { $0.infoHash?.lowercased() })
        let candidates = items.filter { !grabbedHashes.contains(($0.infoHash ?? "").lowercased()) }
        var out: [GrabDecision] = []

        for f in follows {
            let mine = candidates.filter { matches($0, f) }
            guard !mine.isEmpty else { continue }
            let prefs = globalPrefs.overriding(f.quality)
            // une qualité choisie pour cette série passe avant celle de ses épisodes déjà là
            let style = f.quality == nil ? styles[f.id] : nil

            switch f.kind {
            case .movie:
                if ownedMovies.contains(f.id) || history.contains(where: { $0.followId == f.id }) { continue }
                if let b = ReleasePicker.best(mine, prefs: prefs, style: style, where: { $0.season == nil && yearOK($0.year, f.year) }) {
                    out.append(GrabDecision(follow: f, item: b.0, info: b.1))
                }

            case .tv:
                var have = owned[f.id] ?? []
                for h in history where h.followId == f.id {
                    if let s = h.season, let e = h.episode {
                        have.insert(EpisodeKey(s, e))
                        for x in ReleaseInfo.parse(h.release).episodes ?? e...e { have.insert(EpisodeKey(s, x)) }
                    }
                    if let s = h.season, h.episode == nil { have.insert(EpisodeKey(s, 0)) }   // saison complète prise
                }
                // épisodes, un par (saison, épisode)
                let wanted = Set(mine.compactMap { it -> EpisodeKey? in
                    let i = ReleaseInfo.parse(it.releaseName)
                    guard let s = i.season, let e = i.episode, s >= f.fromSeason else { return nil }
                    let k = EpisodeKey(s, e)
                    return have.contains(k) || have.contains(EpisodeKey(s, 0)) ? nil : k
                })
                var taken = Set<EpisodeKey>()
                for k in wanted.sorted() where !taken.contains(k) {
                    if let b = ReleasePicker.best(mine, prefs: prefs, style: style, where: { r in
                        r.season == k.season && r.episode == k.episode
                            // pas un groupe (E03E04) dont un épisode est déjà là ou en route
                            && (r.episodes ?? k.episode...k.episode).allSatisfy { !have.contains(EpisodeKey(k.season, $0)) }
                    }) {
                        out.append(GrabDecision(follow: f, item: b.0, info: b.1))
                        for x in b.1.episodes ?? k.episode...k.episode { taken.insert(EpisodeKey(k.season, x)) }
                    }
                }
                // saisons complètes : seulement si on n'a encore aucun épisode de cette saison
                let packSeasons = Set(mine.compactMap { it -> Int? in
                    let i = ReleaseInfo.parse(it.releaseName)
                    guard i.isSeasonPack, let s = i.season, s >= f.fromSeason,
                          !have.contains(where: { $0.season == s }), !wanted.contains(where: { $0.season == s }) else { return nil }
                    return s
                })
                for s in packSeasons.sorted() {
                    if let b = ReleasePicker.best(mine, prefs: prefs, style: style, where: { $0.isSeasonPack && $0.season == s }) {
                        out.append(GrabDecision(follow: f, item: b.0, info: b.1))
                    }
                }
            }
        }
        return out
    }

    /// Le résultat concerne-t-il cette fiche ? Identifiant d'abord, sinon titre.
    public static func matches(_ it: TorznabItem, _ f: Follow) -> Bool {
        // beaucoup d'indexeurs donnent le tmdbid aussi pour les séries ; la catégorie dit s'il s'agit
        // d'un id de film ou de série (les deux numérotations se recouvrent)
        if let t = it.tmdbId, let k = kind(of: it) { return k == f.kind && t == f.tmdbId }
        if let t = it.tmdbId, f.kind == .movie { return t == f.tmdbId }
        if let i = it.imdbId, let fi = f.imdbId { return i == fi }
        let info = ReleaseInfo.parse(it.releaseName)
        if (info.season != nil) != (f.kind == .tv) { return false }
        // même titre mais autre œuvre (Shōgun de 1980 / de 2024…) : l'année dans le nom tranche.
        // Série : une saison récente peut porter une année plus tardive, jamais plus ancienne que la série.
        if let y = info.year, let fy = f.year {
            // saison 1 : l'année du nom est celle de la série (One Piece 2023 n'est pas One Piece 1999)
            if f.kind == .tv, info.season != 1 { if y < fy - 1 { return false } } else if !yearOK(y, fy) { return false }
        }
        let names = [info.title, it.siteTitle].compactMap { $0 }
        return names.contains { n in f.titles.contains { ReleasePicker.sameTitle(n, $0) } }
    }

    /// Film ou série d'après les catégories Torznab (2xxx films, 5xxx séries).
    static func kind(of it: TorznabItem) -> MediaKind? {
        if it.categories.contains(where: { (2000..<3000).contains($0) }) { return .movie }
        if it.categories.contains(where: { (5000..<6000).contains($0) }) { return .tv }
        return nil
    }

    static func yearOK(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }
}

public struct EpisodeKey: Hashable, Comparable, Codable, Sendable {
    public var season: Int
    public var episode: Int
    public init(_ s: Int, _ e: Int) { season = s; episode = e }
    public static func < (a: Self, b: Self) -> Bool { (a.season, a.episode) < (b.season, b.episode) }
}
