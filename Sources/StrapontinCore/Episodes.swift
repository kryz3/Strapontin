import Foundation

// Séries épisode par épisode : quel torrent couvre quel épisode, état d'une ligne, quoi proposer pour la saison.
// Logique pure (testée), sans réseau ni interface.

extension ReleaseInfo {
    /// Épisodes contenus dans la release : « S01E03 » → 3...3, « S01E01E02 » → 1...2, saison complète → nil.
    public var episodes: ClosedRange<Int>? {
        guard let first = episode else { return nil }
        return first...max(first, episodeEnd ?? first)
    }

    /// Release d'épisode(s) contenant cet épisode (une saison complète n'en est pas une).
    public func isRelease(season s: Int, episode e: Int) -> Bool {
        season == s && episodes?.contains(e) == true
    }

    /// Fin d'un groupe d'épisodes : « S01E01E02 », « S01E01-E03 », « S01E01-03 ». Pas « S01E03-1080p ».
    static func episodeEnd(in name: String, first: Int) -> Int? {
        let pattern = #"(?i)\bs\d{1,2}\s?e\d{1,4}((?:[\s._&+-]{0,3}e\d{1,4}(?!\d))+|-\d{1,4}(?![\dp]))"#
        guard let tail = FilenameParser.firstMatch(pattern, in: name)?.groups.first,
              let last = tail.split(whereSeparator: { !$0.isNumber }).last.flatMap({ Int($0) }),
              last > first, last - first < 100 else { return nil }
        return last
    }
}

/// Ce qu'un torrent du moteur apporte à une série : un épisode, un groupe d'épisodes ou une saison entière.
public struct EpisodeTransfer: Hashable, Sendable {
    public var torrent: Torrent
    public var season: Int
    /// nil = saison complète.
    public var episodes: ClosedRange<Int>?

    public var isPack: Bool { episodes == nil }

    public func covers(season s: Int, episode e: Int) -> Bool {
        season == s && (episodes?.contains(e) ?? true)
    }

    /// Le lien gardé dans downloads.json fait foi ; le nom du torrent complète ce qui manque.
    public init?(torrent: Torrent, link: DownloadLink?) {
        let guess = TorrentGuess.parse(torrent.name)
        guard let season = link?.season ?? guess?.season else { return nil }
        self.torrent = torrent
        self.season = season
        if let first = link?.episode {
            episodes = first...max(first, link?.episodeEnd ?? first)
        } else if let first = guess?.episode {
            episodes = first...max(first, guess?.episodeEnd ?? first)
        } else {
            episodes = nil
        }
    }

    /// Pour le suivi automatique : ce que ces téléchargements occupent déjà (épisode 0 = saison complète).
    public static func occupied(_ transfers: [EpisodeTransfer]) -> Set<EpisodeKey> {
        Set(transfers.flatMap { t -> [EpisodeKey] in
            t.episodes.map { r in r.map { EpisodeKey(t.season, $0) } } ?? [EpisodeKey(t.season, 0)]
        })
    }
}

/// État d'une ligne d'épisode, du plus fort au plus faible.
public enum EpisodeStatus: Equatable, Sendable {
    case owned
    case sending
    case downloading(hash: String, progress: Double, phase: DownloadPhase, inPack: Bool)
    /// Téléchargé, pas encore vu par le scan.
    case arriving
    /// Nombre de versions de cet épisode seul.
    case available(Int)
    /// Pas de version à part, mais une saison complète le contient.
    case inSeasonPack
    case upcoming
    /// Diffusé, rien sur l'indexeur.
    case unavailable
    /// Indexeur pas (encore) consulté.
    case unknown

    public var isBusy: Bool {
        switch self {
        case .sending, .downloading, .arriving: return true
        default: return false
        }
    }
}

public enum EpisodeRules {
    /// - versions : releases de cet épisode seul ; nil = indexeur pas consulté.
    /// - airDate, today : « aaaa-mm-jj ».
    public static func status(season: Int, episode: Int, owned: Set<EpisodeKey>, transfers: [EpisodeTransfer],
                              sending: Bool, versions: Int?, hasPack: Bool, airDate: String?, today: String) -> EpisodeStatus {
        if owned.contains(EpisodeKey(season, episode)) { return .owned }
        let mine = transfers.filter { $0.covers(season: season, episode: episode) }
        if mine.contains(where: { $0.torrent.isDone }) { return .arriving }
        // le plus avancé ; un torrent en erreur ne s'affiche que s'il n'y a que lui
        if let t = mine.max(by: { rank($0) < rank($1) }) {
            return .downloading(hash: t.torrent.hash, progress: t.torrent.progress, phase: t.torrent.phase, inPack: t.isPack)
        }
        if sending { return .sending }
        // une version publiée passe avant la date (avant-premières, décalage horaire)
        if let versions, versions > 0 { return .available(versions) }
        if let airDate, !airDate.isEmpty, airDate > today { return .upcoming }
        guard versions != nil else { return .unknown }
        return hasPack ? .inSeasonPack : .unavailable
    }

    private static func rank(_ t: EpisodeTransfer) -> Double {
        t.torrent.phase == .error ? -1 : t.torrent.progress
    }

    /// Épisodes présents d'après les fichiers (un fichier « S01E01E02 » en apporte deux).
    public static func owned(_ files: [MediaFile]) -> Set<EpisodeKey> {
        var out = Set<EpisodeKey>()
        for f in files {
            guard let s = f.season, let e = f.episode else { continue }
            out.insert(EpisodeKey(s, e))
            let info = ReleaseInfo.parse((f.fileName as NSString).deletingPathExtension)
            if info.season == s, info.episode == e, let r = info.episodes {
                for x in r { out.insert(EpisodeKey(s, x)) }
            }
        }
        return out
    }

    /// Homonymes sans identifiant (« One.Piece.2023.S02 » pour la série de 1999) : l'année du nom doit être celle de la
    /// série ou celle où la saison a été diffusée. Rien à comparer → on garde.
    public static func yearFits(_ year: Int?, seriesYear: Int?, airDates: [String]) -> Bool {
        guard let year, let seriesYear, abs(year - seriesYear) > 1 else { return true }
        let aired = airDates.compactMap { Int($0.prefix(4)) }
        guard let first = aired.min(), let last = aired.max() else { return true }
        return (first - 1...last + 1).contains(year)
    }

    /// Fichiers d'un téléchargement fini → leur épisode. Un torrent d'un seul épisode et d'un seul fichier prend
    /// l'épisode du lien (le nom du fichier peut ne rien dire) ; sinon chaque fichier garde son numéro.
    public static func placement(files: [MediaFile], season: Int?, episode: Int?) -> [String: EpisodeKey] {
        var out: [String: EpisodeKey] = [:]
        for f in files {
            if let season, let episode, files.count == 1 {
                out[f.path] = EpisodeKey(season, episode)
            } else if let e = f.episode, let s = f.season ?? season {
                out[f.path] = EpisodeKey(s, e)
            }
        }
        return out
    }
}

/// Boutons de téléchargement d'une saison.
public struct SeasonPlan: Equatable, Sendable {
    /// « Télécharger la saison » : un pack, et rien de la saison en route (ce serait en double).
    public var offerPack: Bool
    /// « Télécharger les épisodes manquants » : ceux qu'on peut prendre un par un.
    public var missing: [Int]
    /// Peu de manques, ou pas de pack : les épisodes manquants sont l'action principale.
    public var missingFirst: Bool

    /// - downloadable : épisodes qui ont une version recommandée.
    public init(statuses: [Int: EpisodeStatus], hasPack: Bool, seasonBusy: Bool, downloadable: Set<Int>) {
        var gaps = 0, present = 0
        var takeable: [Int] = []
        for (e, s) in statuses {
            switch s {
            case .owned, .sending, .downloading, .arriving: present += 1
            case .available:
                gaps += 1
                if downloadable.contains(e) { takeable.append(e) }
            case .inSeasonPack, .unavailable, .unknown: gaps += 1
            case .upcoming: break
            }
        }
        offerPack = hasPack && !seasonBusy && (statuses.isEmpty || gaps > 0)
        // rien de la saison et un pack : la saison suffit
        missing = present == 0 && offerPack ? [] : takeable.sorted()
        missingFirst = !missing.isEmpty && (!offerPack || gaps <= 3)
    }

    /// Une release par épisode manquant, sans reprendre un épisode déjà couvert par la précédente (E01E02).
    /// `candidates` est trié, la recommandée d'abord.
    public static func picks<T>(_ missing: [Int], candidates: [T], episodes: (T) -> ClosedRange<Int>?) -> [T] {
        var covered = Set<Int>(), out: [T] = []
        for e in missing.sorted() where !covered.contains(e) {
            guard let c = candidates.first(where: { c in
                guard let r = episodes(c), r.contains(e) else { return false }
                return covered.isDisjoint(with: r)
            }), let r = episodes(c) else { continue }
            covered.formUnion(r)
            out.append(c)
        }
        return out
    }
}
