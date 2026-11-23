import Foundation

// Téléchargements présentés comme le reste de la bibliothèque : une affiche par fiche, avec la progression.
// Ici la logique pure (testée) : état d'un torrent, lien torrent ↔ fiche, regroupement en cartes.

/// État simplifié d'un téléchargement, pour l'affiche et la fiche.
public enum DownloadPhase: String, Codable, Sendable, CaseIterable {
    case downloading, waiting, metadata, checking, queued, paused, error, done

    /// Libellé court (pastille sur l'affiche).
    public var label: String {
        switch self {
        case .downloading: return "Téléchargement"
        case .waiting: return "En attente de sources"
        case .metadata: return "Préparation"
        case .checking: return "Vérification"
        case .queued: return "En file d'attente"
        case .paused: return "En pause"
        case .error: return "Erreur"
        case .done: return "Terminé"
        }
    }

    /// Pour une carte qui regroupe plusieurs torrents : l'état le plus parlant l'emporte.
    var priority: Int {
        switch self {
        case .error: return 0
        case .downloading: return 1
        case .checking: return 2
        case .metadata: return 3
        case .waiting: return 4
        case .queued: return 5
        case .paused: return 6
        case .done: return 7
        }
    }
}

extension Torrent {
    public var phase: DownloadPhase {
        if isDone { return .done }
        switch state {
        case "downloading", "forcedDL": return .downloading
        case "stalledDL": return .waiting
        case "metaDL": return .metadata
        case "checkingDL", "checkingUP", "checkingResumeData", "moving": return .checking
        case "queuedDL": return .queued
        case "pausedDL", "stoppedDL": return .paused
        case "error", "missingFiles": return .error
        default: return progress >= 1 ? .done : .downloading
        }
    }
}

/// D'où vient un téléchargement.
public enum DownloadSource: String, Codable, Sendable {
    case tracker, manual
}

/// Lien persistant entre un torrent (son empreinte) et une fiche TMDb.
/// Tous les champs sauf l'empreinte sont optionnels : un fichier écrit par une autre version se relit toujours.
public struct DownloadLink: Codable, Hashable, Sendable {
    public var hash: String
    /// Clé de fiche (« movie:123 », « tv:456 ») ; nil = pas (encore) identifié.
    public var mediaKey: String?
    /// Copie de la fiche (titre, affiche…) : la carte s'affiche même si le film n'est pas encore dans la bibliothèque.
    public var media: Media?
    public var season: Int?
    public var episode: Int?
    /// Dernier épisode si le torrent en contient plusieurs.
    public var episodeEnd: Int?
    public var source: DownloadSource?
    /// Nom pour lequel l'identification automatique a déjà été tentée (on ne réessaie pas toutes les 2 s).
    public var triedName: String?
    /// Rattaché à la main : l'identification automatique ne le touche plus.
    public var manual: Bool?
    public var added: Date?

    public init(hash: String, mediaKey: String? = nil, media: Media? = nil, season: Int? = nil, episode: Int? = nil,
                source: DownloadSource? = nil, added: Date? = Date()) {
        self.hash = hash.lowercased()
        self.mediaKey = mediaKey ?? media?.key
        self.media = media
        self.season = season
        self.episode = episode
        self.source = source
        self.added = added
    }
}

/// Carnet des liens, enregistré dans downloads.json.
public struct DownloadLinkBook: Codable, Sendable, Equatable {
    public var links: [String: DownloadLink] = [:]

    public init(links: [String: DownloadLink] = [:]) { self.links = links }

    public subscript(hash: String) -> DownloadLink? { links[hash.lowercased()] }

    /// Envoi depuis une fiche (ou suivi) : la fiche est connue, elle remplace une identification automatique.
    public mutating func record(hash: String, media: Media?, mediaKey: String?, season: Int?, episode: Int?, episodeEnd: Int? = nil, source: DownloadSource) {
        let h = hash.lowercased()
        var l = links[h] ?? DownloadLink(hash: h)
        if let key = mediaKey ?? media?.key, !key.isEmpty {
            l.mediaKey = key
            if let media { l.media = media } else if l.media?.key != key { l.media = nil }
        }
        l.season = season ?? l.season
        l.episode = episode ?? l.episode
        l.episodeEnd = episodeEnd ?? l.episodeEnd
        l.source = source
        links[h] = l
    }

    /// Ajout à la main (glisser-déposer, magnet) : on note l'empreinte, l'identification viendra ensuite.
    public mutating func recordManual(hash: String) {
        let h = hash.lowercased()
        guard links[h] == nil else { return }
        links[h] = DownloadLink(hash: h, source: .manual)
    }

    /// Rattachement choisi par l'utilisateur.
    public mutating func assign(hash: String, media: Media, season: Int? = nil, episode: Int? = nil) {
        let h = hash.lowercased()
        var l = links[h] ?? DownloadLink(hash: h, source: .manual)
        if media.kind == .movie {
            l.season = nil; l.episode = nil; l.episodeEnd = nil
        } else if let season {
            l.season = season; l.episode = episode; l.episodeEnd = nil
        }
        l.mediaKey = media.key
        l.media = media
        l.manual = true
        links[h] = l
    }

    /// Résultat de l'identification automatique d'un nom de torrent (nil = rien trouvé, on ne réessaie pas ce nom).
    public mutating func identified(hash: String, name: String, media: Media?, season: Int?, episode: Int?) {
        let h = hash.lowercased()
        var l = links[h] ?? DownloadLink(hash: h, source: .manual)
        l.triedName = name
        if l.manual != true, l.mediaKey == nil, let media {
            l.mediaKey = media.key
            l.media = media
            l.season = l.season ?? season
            l.episode = l.episode ?? episode
        }
        links[h] = l
    }

    /// Torrents envoyés avant l'existence du carnet : l'historique de l'indexeur donne déjà empreinte ↔ fiche.
    public mutating func seed(from history: [GrabRecord]) {
        for r in history {
            guard let h = r.infoHash?.lowercased(), !h.isEmpty, !r.followId.isEmpty, links[h]?.mediaKey == nil else { continue }
            var l = links[h] ?? DownloadLink(hash: h, source: .tracker, added: r.date)
            l.mediaKey = r.followId
            l.season = r.season
            l.episode = r.episode
            links[h] = l
        }
    }

    /// Faut-il tenter d'identifier ce torrent ? (pas de fiche, nom réel connu, pas déjà essayé avec ce nom)
    public func needsIdentification(_ t: Torrent) -> Bool {
        let l = links[t.hash.lowercased()]
        if l?.mediaKey != nil || l?.manual == true { return false }
        guard TorrentGuess.parse(t.name) != nil else { return false }
        return l?.triedName != t.name
    }

    /// Fiches connues par leur clé mais sans copie (liens issus de l'historique) : à compléter par TMDb.
    public var keysWithoutMedia: [String] {
        Array(Set(links.values.filter { $0.media == nil }.compactMap(\.mediaKey))).sorted()
    }

    public mutating func fill(_ media: Media) {
        for (h, l) in links where l.mediaKey == media.key && l.media == nil { links[h]?.media = media }
    }

    /// Oublie les liens des torrents retirés du moteur depuis plus d'une semaine (le carnet ne grossit pas sans fin).
    public mutating func prune(present: Set<String>, now: Date = Date()) {
        links = links.filter { h, l in present.contains(h) || now.timeIntervalSince(l.added ?? now) < 7 * 86400 }
    }
}

/// Ce qu'on devine d'un nom de torrent pour chercher sa fiche.
public struct TorrentGuess: Equatable, Sendable {
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeEnd: Int? = nil

    /// nil si le nom n'apprend rien (vide, ou juste l'empreinte tant que le magnet n'a pas ses métadonnées).
    public static func parse(_ rawName: String) -> TorrentGuess? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.range(of: #"^[0-9a-fA-F]{40}$|^[A-Za-z2-7]{32}$"#, options: .regularExpression) != nil { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        if FilenameParser.videoExtensions.contains(ext) || ext == "torrent" { name = (name as NSString).deletingPathExtension }
        let info = ReleaseInfo.parse(name)
        let title = info.title.trimmingCharacters(in: .whitespaces)
        guard title.count >= 2 else { return nil }
        return TorrentGuess(kind: info.season != nil ? .tv : .movie, title: title, year: info.year,
                            season: info.season, episode: info.episode, episodeEnd: info.episodeEnd)
    }
}

extension TorrentPayload {
    /// Nom lisible avant même que le moteur l'ait : « dn » du magnet, ou « name » du .torrent.
    public var displayName: String? {
        switch self {
        case .magnet(let m):
            guard let c = URLComponents(string: m), let dn = c.queryItems?.first(where: { $0.name == "dn" })?.value,
                  !dn.isEmpty else { return nil }
            return dn.replacingOccurrences(of: "+", with: " ")   // magnets : « + » pour les espaces
        case .file(let data, let name):
            return Self.infoName(torrent: data) ?? ((name as NSString).deletingPathExtension as String?)
        }
    }

    static func infoName(torrent data: Data) -> String? {
        let b = [UInt8](data)
        guard b.first == UInt8(ascii: "d") else { return nil }
        var i = 1
        while i < b.count, b[i] != UInt8(ascii: "e") {
            guard let key = Bencode.string(b, &i) else { return nil }
            if key == Array("info".utf8), i < b.count, b[i] == UInt8(ascii: "d") {
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "e") {
                    guard let k = Bencode.string(b, &i) else { return nil }
                    if k == Array("name".utf8) {
                        guard let v = Bencode.string(b, &i) else { return nil }
                        return String(decoding: v, as: UTF8.self)
                    }
                    guard Bencode.skip(b, &i) else { return nil }
                }
                return nil
            }
            guard Bencode.skip(b, &i) else { return nil }
        }
        return nil
    }
}

/// Une carte « en téléchargement » : une fiche (tous ses torrents), ou un torrent qu'on n'a pas su rattacher.
public struct DownloadEntry: Identifiable, Hashable, Sendable {
    /// Clé de fiche, ou « dl:<empreinte> » pour un torrent non identifié.
    public var id: String
    public var mediaKey: String?
    public var media: Media?
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    /// Tous les torrents de la fiche, les actifs d'abord.
    public var torrents: [Torrent]
    /// Torrents pris en compte pour la progression : ceux encore en cours, sinon tous.
    public var current: [Torrent]
    public var seasons: [Int]
    public var episode: Int?
    public var progress: Double
    public var phase: DownloadPhase
    public var dlspeed: Int64
    public var eta: Int64
    public var addedOn: Double

    public var isDone: Bool { phase == .done }
    public var hashes: [String] { torrents.map(\.hash) }
    public var currentHashes: [String] { current.map(\.hash) }
    public var isIdentified: Bool { mediaKey != nil }

    /// « Saison 2 », « Saisons 1 et 2 », « S02E05 » ; vide pour un film.
    public var seasonLabel: String {
        guard kind == .tv, !seasons.isEmpty else { return "" }
        if seasons.count == 1, let e = episode { return String(format: "S%02dE%02d", seasons[0], e) }
        if seasons.count == 1 { return "Saison \(seasons[0])" }
        return "Saisons " + seasons.dropLast().map(String.init).joined(separator: ", ") + " et \(seasons.last!)"
    }
}

public enum DownloadBoard {
    /// Regroupe les torrents du moteur en cartes : une par fiche, en cours d'abord (du plus récent au plus ancien).
    public static func build(torrents: [Torrent], book: DownloadLinkBook) -> [DownloadEntry] {
        var groups: [String: [Torrent]] = [:]
        var order: [String] = []
        for t in torrents {
            let key = book[t.hash]?.mediaKey ?? "dl:\(t.hash.lowercased())"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        let entries = order.map { key -> DownloadEntry in
            let ts = groups[key]!.sorted { ($0.isDone ? 1 : 0, -$0.addedOn) < ($1.isDone ? 1 : 0, -$1.addedOn) }
            let active = ts.filter { !$0.isDone }
            let current = active.isEmpty ? ts : active
            let link = ts.lazy.compactMap { book[$0.hash] }.first { $0.media != nil } ?? book[ts[0].hash]
            let guess = TorrentGuess.parse(ts[0].name)
            let mediaKey = key.hasPrefix("dl:") ? nil : key
            let kind = link?.media?.kind ?? mediaKey.flatMap(kindOf) ?? guess?.kind ?? .movie
            let seasons = Set(current.compactMap { t in book[t.hash]?.season ?? TorrentGuess.parse(t.name)?.season }).sorted()
            let episodes = current.compactMap { t in book[t.hash]?.episode ?? TorrentGuess.parse(t.name)?.episode }
            let total = current.reduce(Int64(0)) { $0 + max(0, $1.size) }
            let progress = total > 0
                ? current.reduce(0.0) { $0 + $1.progress * Double(max(0, $1.size)) } / Double(total)
                : current.map(\.progress).reduce(0, +) / Double(max(1, current.count))
            let phase = current.map(\.phase).min { $0.priority < $1.priority } ?? .done
            return DownloadEntry(
                id: key, mediaKey: mediaKey, media: link?.media, kind: kind,
                title: link?.media?.title ?? guess?.title ?? ts[0].name,
                year: link?.media?.year ?? guess?.year,
                torrents: ts, current: current, seasons: seasons,
                episode: current.count == 1 && episodes.count == 1 && EpisodeTransfer(torrent: current[0], link: book[current[0].hash])?.episodes?.count == 1
                    ? episodes[0] : nil,
                progress: min(1, max(0, progress)), phase: phase,
                dlspeed: current.reduce(0) { $0 + $1.dlspeed }, eta: current.map(\.eta).max() ?? 0,
                addedOn: ts.map(\.addedOn).max() ?? 0)
        }
        return entries.sorted { ($0.isDone ? 1 : 0, -$0.addedOn) < ($1.isDone ? 1 : 0, -$1.addedOn) }
    }

    static func kindOf(_ key: String) -> MediaKind? {
        key.split(separator: ":").first.flatMap { MediaKind(rawValue: String($0)) }
    }
}

extension Follow {
    /// Fiche minimale tirée d'un suivi (titre, année, affiche) pour la carte de téléchargement.
    public var asMedia: Media {
        var m = Media(tmdbId: tmdbId, kind: kind, title: title)
        m.originalTitle = originalTitle
        m.year = year
        m.posterPath = posterPath
        m.imdbId = imdbId
        m.tvdbId = tvdbId
        return m
    }
}

/// Résultats de l'indexeur pour une recherche, comptés par fiche (pastille « 12 versions » sur les affiches de la recherche).
public enum TrackerAvailability {
    public static func count(_ items: [TorznabItem], kind: MediaKind, tmdbId: Int, title: String,
                             originalTitle: String? = nil, year: Int?) -> Int {
        var m = Media(tmdbId: tmdbId, kind: kind, title: title)
        m.originalTitle = originalTitle
        m.year = year
        let f = Follow(media: m)
        return items.filter { AutoGrab.matches($0, f) }.count
    }
}
