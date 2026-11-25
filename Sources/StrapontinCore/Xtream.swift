import Foundation

/// Fournisseurs « Xtream Codes » : la playlist M3U est une adresse `get.php?username=…&password=…` ; leur API donne le
/// catalogue à la demande proprement rangé (films, séries avec saisons et épisodes, catégories, résumés, affiches).
public struct XtreamAccount: Hashable, Sendable {
    public var base: String       // https://hote:port
    public var username: String
    public var password: String

    /// Reconnaît une adresse de playlist Xtream (`/get.php?username=…&password=…`).
    public static func from(playlistURL: String) -> XtreamAccount? {
        guard let c = URLComponents(string: playlistURL), c.path.hasSuffix("get.php") || c.path.hasSuffix("player_api.php"),
              let u = c.queryItems?.first(where: { $0.name == "username" })?.value,
              let p = c.queryItems?.first(where: { $0.name == "password" })?.value,
              let scheme = c.scheme, let host = c.host else { return nil }
        return XtreamAccount(base: "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? ""), username: u, password: p)
    }

    public func api(_ action: String, _ extra: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: base + "/player_api.php")
        c?.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password),
                         URLQueryItem(name: "action", value: action)] + extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    public func movieURL(_ id: Int, ext: String) -> String { "\(base)/movie/\(username)/\(password)/\(id).\(ext)" }
    public func episodeURL(_ id: String, ext: String) -> String { "\(base)/series/\(username)/\(password)/\(id).\(ext)" }
}

/// Un film ou une série du catalogue à la demande.
public struct VODItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: IPTVKind            // .movie ou .series
    public var name: String
    public var poster: String?
    public var category: String
    public var plot: String?
    public var rating: Double?
    public var year: Int?
    public var tmdbId: Int?
    /// Film : adresse à lire. Série : vide (épisodes à demander).
    public var url: String?
    /// Série Xtream : identifiant pour get_series_info.
    public var seriesId: Int?

    public init(id: String, kind: IPTVKind, name: String, poster: String?, category: String, plot: String?, rating: Double?,
                year: Int?, tmdbId: Int?, url: String?, seriesId: Int?) {
        self.id = id; self.kind = kind; self.name = name; self.poster = poster; self.category = category; self.plot = plot
        self.rating = rating; self.year = year; self.tmdbId = tmdbId; self.url = url; self.seriesId = seriesId
    }
}

public struct VODEpisode: Identifiable, Hashable, Sendable {
    public var id: String
    public var season: Int
    public var episode: Int
    public var title: String
    public var plot: String?
    public var still: String?
    public var duration: String?
    public var url: String

    public init(id: String, season: Int, episode: Int, title: String, plot: String?, still: String?, duration: String?, url: String) {
        self.id = id; self.season = season; self.episode = episode; self.title = title; self.plot = plot; self.still = still
        self.duration = duration; self.url = url
    }
}

public enum XtreamParser {
    static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } }
    static func double(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? String).flatMap { Double($0) } }

    public static func categories(_ data: Data) -> [String: String] {
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for c in list { if let id = c["category_id"].map({ "\($0)" }), let n = c["category_name"] as? String { out[id] = n } }
        return out
    }

    public static func movies(_ data: Data, account: XtreamAccount, categories: [String: String]) -> [VODItem] {
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard let id = int(m["stream_id"]), let name = m["name"] as? String else { return nil }
            let ext = (m["container_extension"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
            let cat = m["category_id"].map { "\($0)" }.flatMap { categories[$0] } ?? "Films"
            return VODItem(id: "xt-movie-\(id)", kind: .movie, name: name, poster: (m["stream_icon"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           category: cat, plot: m["plot"] as? String, rating: double(m["rating"]),
                           year: int(m["year"]) ?? VODTitle.year(name), tmdbId: int(m["tmdb"]) ?? int(m["tmdb_id"]),
                           url: account.movieURL(id, ext: ext), seriesId: nil)
        }
    }

    public static func series(_ data: Data, categories: [String: String]) -> [VODItem] {
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let id = int(s["series_id"]), let name = s["name"] as? String else { return nil }
            let cat = s["category_id"].map { "\($0)" }.flatMap { categories[$0] } ?? "Séries"
            return VODItem(id: "xt-series-\(id)", kind: .series, name: name, poster: (s["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           category: cat, plot: s["plot"] as? String, rating: double(s["rating"]),
                           year: (s["releaseDate"] as? String).flatMap { Int($0.prefix(4)) } ?? VODTitle.year(name),
                           tmdbId: int(s["tmdb"]) ?? int(s["tmdb_id"]), url: nil, seriesId: id)
        }
    }

    /// get_series_info : épisodes par saison.
    public static func episodes(_ data: Data, account: XtreamAccount) -> [VODEpisode] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bySeason = root["episodes"] as? [String: Any] else { return [] }
        var out: [VODEpisode] = []
        for (key, value) in bySeason {
            for e in value as? [[String: Any]] ?? [] {
                guard let id = e["id"].map({ "\($0)" }) else { continue }
                let info = e["info"] as? [String: Any] ?? [:]
                let ext = (e["container_extension"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
                let n = int(e["episode_num"]) ?? 0
                out.append(VODEpisode(id: id, season: int(e["season"]) ?? Int(key) ?? 1, episode: n,
                                      title: (e["title"] as? String) ?? "Épisode \(n)", plot: info["plot"] as? String,
                                      still: info["movie_image"] as? String, duration: info["duration"] as? String,
                                      url: account.episodeURL(id, ext: ext)))
            }
        }
        return out.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }
}

/// Titres du catalogue IPTV, souvent bruités (« FR | Dune (2021) [MULTI] 4K ») : le titre et l'année pour TMDb.
public enum VODTitle {
    public static func clean(_ name: String) -> String {
        var s = name
        // préfixes de langue ou de fournisseur : « FR | », « |FR| », « VF - »
        s = s.replacingOccurrences(of: #"^\s*(\|?[A-Z]{2,4}\|?\s*[|:\-]\s*)+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\[\(][^\]\)]*(multi|vf|vostfr|4k|uhd|hd|fhd|sd|1080p|720p|hdr)[^\]\)]*[\]\)]"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b(4K|UHD|FHD|HD|SD|HEVC|MULTI|VF|VOSTFR|1080p|720p|HDR)\b"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\(\s*(19|20)\d{2}\s*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+-\s*(19|20)\d{2}\s*$"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
    }

    public static func year(_ name: String) -> Int? {
        guard let r = name.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(name[r])
    }
}
