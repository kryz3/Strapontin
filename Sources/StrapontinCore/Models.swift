import Foundation

public enum MediaKind: String, Codable, Sendable {
    case movie, tv
}

public enum MatchState: String, Codable, Sendable {
    case pending, matched, notFound, manual
}

/// Un fichier vidéo trouvé sur le disque.
public struct MediaFile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var folder: String
    public var size: Int64
    public var mtime: Double
    public var added: Double

    public var isEpisode: Bool
    public var guessTitle: String
    public var guessYear: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?

    public var mediaKey: String?
    public var matchState: MatchState
    public var episodeTitle: String?
    public var episodeOverview: String?
    public var stillPath: String?

    public var position: Double
    public var duration: Double
    public var watched: Bool
    public var lastPlayed: Double?

    public init(path: String, folder: String, size: Int64, mtime: Double, parsed: ParsedName) {
        self.path = path
        self.folder = folder
        self.size = size
        self.mtime = mtime
        self.added = Date().timeIntervalSince1970
        self.isEpisode = parsed.isEpisode
        self.guessTitle = parsed.title
        self.guessYear = parsed.year
        self.season = parsed.season
        self.episode = parsed.episode
        self.quality = parsed.quality
        self.mediaKey = nil
        self.matchState = .pending
        self.episodeTitle = nil
        self.position = 0
        self.duration = 0
        self.watched = false
        self.lastPlayed = nil
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var kind: MediaKind { isEpisode ? .tv : .movie }
    public var inProgress: Bool { position > 0 && !watched }
}

/// Une fiche TMDb (film ou série).
public struct Media: Codable, Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String { "\(kind.rawValue):\(tmdbId)" }
    public var tmdbId: Int
    public var kind: MediaKind
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var imdbId: String?
    /// Séries : identifiant TheTVDB (recherche la plus fiable pour une série sur un indexeur).
    public var tvdbId: Int?
    public var rating: Double?
    public var imdbRating: String?
    public var genres: [String]
    public var runtime: Int?
    public var tagline: String?
    public var logoPath: String?
    public var cast: [CastMember]?
    public var certification: String?

    public init(tmdbId: Int, kind: MediaKind, title: String) {
        self.tmdbId = tmdbId
        self.kind = kind
        self.title = title
        self.genres = []
    }

    public static func key(_ kind: MediaKind, _ id: Int) -> String { "\(kind.rawValue):\(id)" }
}

public struct CastMember: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public init(id: Int, name: String, character: String?, profilePath: String?) {
        self.id = id; self.name = name; self.character = character; self.profilePath = profilePath
    }
}

public struct EpisodeInfo: Codable, Hashable, Sendable {
    public var name: String?
    public var overview: String?
    public var stillPath: String?
    /// « aaaa-mm-jj »
    public var airDate: String?
    public var runtime: Int?
    public var rating: Double?
    public var directors: [String]?
    public var writers: [String]?
    public init(name: String?, overview: String?, stillPath: String?) {
        self.name = name; self.overview = overview; self.stillPath = stillPath
    }
}

/// Une entrée de la bibliothèque : une fiche et ses fichiers, ou un groupe de fichiers non identifiés.
public struct LibraryItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var media: Media?
    public var files: [MediaFile]

    public var kind: MediaKind { media?.kind ?? (files.first?.kind ?? .movie) }
    public var title: String { media?.title ?? files.first?.guessTitle ?? "?" }
    public var year: Int? { media?.year ?? files.first?.guessYear }
    public var added: Double { files.map(\.added).max() ?? 0 }
    public var lastPlayed: Double { files.compactMap(\.lastPlayed).max() ?? 0 }
    public var allWatched: Bool { !files.isEmpty && files.allSatisfy(\.watched) }
    public var inProgress: Bool { files.contains(where: \.inProgress) }
    public var bestQuality: String? { files.compactMap(\.quality).max(by: { $0.count < $1.count }) }

    /// Prochain épisode à voir (ou le film).
    public var nextUp: MediaFile? { files.first(where: { !$0.watched }) ?? files.first }
    public var resumeTarget: MediaFile? {
        files.filter(\.inProgress).max(by: { ($0.lastPlayed ?? 0) < ($1.lastPlayed ?? 0) })
    }

    public static func build(files: [MediaFile], media: [String: Media]) -> [LibraryItem] {
        var groups: [String: [MediaFile]] = [:]
        for f in files {
            let key: String
            if let mk = f.mediaKey, media[mk] != nil {
                key = mk
            } else {
                let y = f.isEpisode ? "" : String(f.guessYear ?? 0)
                key = "u:\(f.kind.rawValue):\(f.guessTitle.lowercased()):\(y)"
            }
            groups[key, default: []].append(f)
        }
        return groups.map { key, fs in
            let sorted = fs.sorted {
                ($0.season ?? 0, $0.episode ?? 0, $0.path) < ($1.season ?? 0, $1.episode ?? 0, $1.path)
            }
            return LibraryItem(id: key, media: media[key], files: sorted)
        }
    }
}

extension LibraryItem {
    /// Entrées qui ont changé d'identifiant d'une construction à l'autre (fiche corrigée, fichier enfin identifié,
    /// téléchargement rattaché) : ancien id → nouvel id. Une page ouverte sur l'ancien id suit ainsi la nouvelle fiche
    /// au lieu d'afficher « introuvable ». Une entrée disparue sans successeur (supprimée) n'a pas de redirection.
    public static func redirects(from old: [LibraryItem], to new: [LibraryItem]) -> [String: String] {
        let newIds = Set(new.map(\.id))
        var owner: [String: String] = [:]
        for i in new { for f in i.files { owner[f.path] = i.id } }
        var out: [String: String] = [:]
        for i in old where !newIds.contains(i.id) {
            // le successeur le plus probable : celui qui a récupéré le plus de fichiers
            let counts = Dictionary(i.files.compactMap { owner[$0.path] }.map { ($0, 1) }, uniquingKeysWith: +)
            if let best = counts.max(by: { $0.value < $1.value })?.key { out[i.id] = best }
        }
        return out
    }
}
