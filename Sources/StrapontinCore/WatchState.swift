import Foundation

/// Le titre regardé, quelle que soit la source (fichier, streaming, torrent) : un film, ou un épisode d'une série TMDb.
/// Progression, « vu », historique et « À suivre » s'y rattachent, jamais à la source.
public struct TitleKey: Hashable, Codable, Sendable {
    public var kind: MediaKind
    public var tmdbId: Int
    public var episode: EpisodeKey?

    public init(_ kind: MediaKind, _ tmdbId: Int, _ episode: EpisodeKey? = nil) {
        self.kind = kind; self.tmdbId = tmdbId; self.episode = kind == .tv ? episode : nil
    }

    /// « movie:603 », « tv:1399:2:5 ».
    public var id: String {
        let base = "\(kind.rawValue):\(tmdbId)"
        guard let e = episode else { return base }
        return "\(base):\(e.season):\(e.episode)"
    }
    /// La fiche (film ou série) : « tv:1399 ».
    public var mediaKey: String { "\(kind.rawValue):\(tmdbId)" }

    public init?(id: String) {
        let p = id.split(separator: ":")
        guard p.count >= 2, let kind = MediaKind(rawValue: String(p[0])), let t = Int(p[1]) else { return nil }
        if p.count == 4, let s = Int(p[2]), let e = Int(p[3]) { self.init(kind, t, EpisodeKey(s, e)) } else { self.init(kind, t) }
    }
}

/// Où en est un titre : position, durée, date (s depuis 1970), vu.
public struct WatchPoint: Codable, Equatable, Sendable {
    public var position: Double
    public var duration: Double
    public var date: Double
    public var watched: Bool

    public init(position: Double, duration: Double, date: Double, watched: Bool) {
        self.position = position; self.duration = duration; self.date = date; self.watched = watched
    }

    /// Commencé, pas fini : à reprendre.
    public var inProgress: Bool { !watched && position > 30 && (duration <= 0 || position < duration * 0.95) }
    public var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

public enum WatchMerge {
    /// Le point le plus récent, quelle que soit la source.
    public static func latest(_ points: WatchPoint?...) -> WatchPoint? {
        points.compactMap { $0 }.max { $0.date < $1.date }
    }

    /// Position de reprise : celle du point le plus récent, 0 s'il est vu ou à peine commencé.
    public static func resume(_ points: WatchPoint?...) -> Double {
        guard let p = points.compactMap({ $0 }).max(by: { $0.date < $1.date }), p.inProgress else { return 0 }
        return p.position
    }
}

/// Enchaînement d'épisodes d'une source à l'autre (S1E10 en fichier → S2E1 en streaming, E4 en streaming au milieu de
/// fichiers…). Par défaut la meilleure source : le fichier, puis le streaming ; sans source : à télécharger.
public enum CrossSource {
    public enum Source: Equatable, Sendable {
        case file(String)     // chemin
        case stream(String)   // adresse
    }

    /// Fusionne les sources d'un épisode : le fichier l'emporte.
    public static func sources(files: [EpisodeKey: String], streams: [EpisodeKey: String]) -> [EpisodeKey: Source] {
        var out: [EpisodeKey: Source] = streams.mapValues { .stream($0) }
        for (k, p) in files { out[k] = .file(p) }
        return out
    }

    /// L'épisode suivant : le premier après `current` parmi ceux qu'on connaît (TMDb, déjà diffusés) ou qu'une source a.
    /// Renvoie sa source, ou nil s'il faut le télécharger.
    public static func next(after current: EpisodeKey, known: [EpisodeKey], sources: [EpisodeKey: Source]) -> (EpisodeKey, Source?)? {
        let candidates = Set(known.filter { $0.season > 0 }).union(sources.keys.filter { $0.season > 0 })
        guard let k = candidates.filter({ $0 > current }).min() else { return nil }
        return (k, sources[k])
    }

    /// L'épisode d'avant qu'une source peut lire.
    public static func previous(before current: EpisodeKey, sources: [EpisodeKey: Source]) -> (EpisodeKey, Source)? {
        guard let k = sources.keys.filter({ $0 < current && $0.season > 0 }).max() else { return nil }
        return (k, sources[k]!)
    }

    /// « À suivre » d'une série : l'épisode commencé le plus récent, sinon le suivant du dernier vu.
    public static func upNext(watch: [EpisodeKey: WatchPoint], known: [EpisodeKey],
                              sources: [EpisodeKey: Source]) -> (EpisodeKey, resume: Double)? {
        guard let last = watch.max(by: { $0.value.date < $1.value.date }) else { return nil }
        if last.value.inProgress { return (last.key, last.value.position) }
        // à peine commencé (enchaîné automatiquement, puis fermé) : c'est encore celui-là
        if !last.value.watched { return (last.key, 0) }
        guard let n = next(after: last.key, known: known, sources: sources) else { return nil }
        if let p = watch[n.0], p.watched { return nil }
        return (n.0, 0)
    }
}
