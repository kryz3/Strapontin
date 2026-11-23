import Foundation

public enum TMDbError: LocalizedError {
    case badKey, http(Int), rateLimited
    public var errorDescription: String? {
        switch self {
        case .badKey: return "Clé TMDb refusée. Vérifie-la dans les réglages."
        case .http(let c): return "TMDb a répondu \(c)."
        case .rateLimited: return "TMDb limite les requêtes, réessaie plus tard."
        }
    }
}

public struct TMDbSearchResult: Identifiable, Hashable, Sendable {
    public var id: Int
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    public var overview: String
    public var posterPath: String?
}

/// Client TMDb. IMDb n'a pas d'API publique : l'identifiant IMDb vient de TMDb,
/// la note IMDb d'OMDb si une clé est fournie.
public final class TMDbClient: @unchecked Sendable {
    let key: String
    let language: String
    let omdbKey: String
    let session: URLSession

    public init(key: String, language: String = "fr-FR", omdbKey: String = "") {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.omdbKey = omdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = Self.sharedSession
    }

    /// Une seule session pour toute l'app : connexions réutilisées (HTTP/2) au lieu d'une nouvelle poignée de main
    /// à chaque client créé, et cache HTTP des images.
    public static let sharedSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Durée de vie en cache d'une réponse selon la requête : fiches et saisons longtemps, recherches et tendances moins.
    static func ttl(_ path: String) -> TimeInterval {
        if path.hasPrefix("/search") { return 30 * 60 }
        if path.hasPrefix("/trending") || path.hasSuffix("/popular") { return 3 * 3600 }
        if path == "/configuration" { return 0 }
        return 24 * 3600
    }

    func get(_ path: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        let ttl = Self.ttl(path)
        let cacheKey = path + "?" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") + "&language=" + language
        let data: Data
        if ttl > 0 {
            data = try await TMDbCache.shared.data(for: cacheKey, ttl: ttl) { [self] in try await fetch(path, params) }
        } else {
            data = try await fetch(path, params)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func fetch(_ path: String, _ params: [String: String]) async throws -> Data {
        var comps = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        var req = URLRequest(url: comps.url!)
        if key.hasPrefix("eyJ") {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")   // jeton v4
        } else {
            items.append(URLQueryItem(name: "api_key", value: key))
        }
        comps.queryItems = items
        req.url = comps.url
        for _ in 0..<4 {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            if code == 401 { throw TMDbError.badKey }
            guard (200..<300).contains(code) else { throw TMDbError.http(code) }
            return data
        }
        throw TMDbError.rateLimited
    }

    public func check() async throws { _ = try await get("/configuration") }

    public func search(_ kind: MediaKind, title: String, year: Int?) async throws -> [TMDbSearchResult] {
        var params = ["query": title, "include_adult": "false"]
        if let year { params[kind == .movie ? "year" : "first_air_date_year"] = String(year) }
        var res = try await get("/search/\(kind.rawValue)", params)["results"] as? [[String: Any]] ?? []
        if res.isEmpty, year != nil {
            res = try await get("/search/\(kind.rawValue)", ["query": title, "include_adult": "false"])["results"] as? [[String: Any]] ?? []
        }
        return res.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            return TMDbSearchResult(id: id, kind: kind, title: (r["title"] as? String) ?? (r["name"] as? String) ?? "?",
                                    year: Int(date.prefix(4)), overview: r["overview"] as? String ?? "",
                                    posterPath: r["poster_path"] as? String)
        }
    }

    public func bestMatch(_ kind: MediaKind, title: String, year: Int?) async throws -> TMDbSearchResult? {
        let res = try await search(kind, title: title, year: year)
        if let year, let exact = res.prefix(5).first(where: { $0.year == year }) { return exact }
        return res.first
    }

    public func details(_ kind: MediaKind, id: Int) async throws -> Media {
        let d = try await get("/\(kind.rawValue)/\(id)", [
            "append_to_response": "external_ids,credits,images,release_dates,content_ratings",
            "include_image_language": "\(language.prefix(2)),en,null",
        ])
        var m = Media(tmdbId: id, kind: kind, title: (d["title"] as? String) ?? (d["name"] as? String) ?? "?")
        m.originalTitle = (d["original_title"] as? String) ?? (d["original_name"] as? String)
        let date = (d["release_date"] as? String) ?? (d["first_air_date"] as? String) ?? ""
        m.year = Int(date.prefix(4))
        m.overview = d["overview"] as? String
        m.posterPath = d["poster_path"] as? String
        m.backdropPath = d["backdrop_path"] as? String
        m.imdbId = (d["imdb_id"] as? String) ?? ((d["external_ids"] as? [String: Any])?["imdb_id"] as? String)
        m.tvdbId = (d["external_ids"] as? [String: Any])?["tvdb_id"] as? Int
        m.rating = d["vote_average"] as? Double
        m.genres = (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        m.runtime = (d["runtime"] as? Int) ?? (d["episode_run_time"] as? [Int])?.first
        m.tagline = (d["tagline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // logo du titre (comme sur Apple TV), dans la langue choisie de préférence
        // pas les .svg : l'app ne sait pas les afficher (le titre disparaissait de la fiche)
        let logos = ((d["images"] as? [String: Any])?["logos"] as? [[String: Any]] ?? [])
            .filter { !(($0["file_path"] as? String)?.lowercased().hasSuffix(".svg") ?? true) }
        let lang = String(language.prefix(2))
        m.logoPath = (logos.first { $0["iso_639_1"] as? String == lang } ?? logos.first { $0["iso_639_1"] as? String == "en" }
                      ?? logos.first)?["file_path"] as? String
        let cast = ((d["credits"] as? [String: Any])?["cast"] as? [[String: Any]] ?? []).prefix(15)
        m.cast = cast.compactMap { c in
            guard let id = c["id"] as? Int, let name = c["name"] as? String else { return nil }
            return CastMember(id: id, name: name, character: c["character"] as? String, profilePath: c["profile_path"] as? String)
        }
        m.certification = certification(d, kind: kind, country: String(language.suffix(2)))
        if let imdb = m.imdbId, !omdbKey.isEmpty { m.imdbRating = await imdbRating(imdb) }
        return m
    }

    func certification(_ d: [String: Any], kind: MediaKind, country: String) -> String? {
        if kind == .movie {
            let results = (d["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            for c in [country, "US"] {
                let dates = results.first { $0["iso_3166_1"] as? String == c }?["release_dates"] as? [[String: Any]] ?? []
                if let cert = dates.compactMap({ $0["certification"] as? String }).first(where: { !$0.isEmpty }) { return cert }
            }
        } else {
            let results = (d["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            for c in [country, "US"] {
                if let r = results.first(where: { $0["iso_3166_1"] as? String == c })?["rating"] as? String, !r.isEmpty { return r }
            }
        }
        return nil
    }

    public func seasonEpisodes(tvId: Int, season: Int) async -> [Int: EpisodeInfo] {
        guard let d = try? await get("/tv/\(tvId)/season/\(season)") else { return [:] }
        return Self.episodes(d)
    }

    static func episodes(_ d: [String: Any]) -> [Int: EpisodeInfo] {
        var out: [Int: EpisodeInfo] = [:]
        for e in d["episodes"] as? [[String: Any]] ?? [] {
            guard let n = e["episode_number"] as? Int else { continue }
            var info = EpisodeInfo(name: e["name"] as? String, overview: e["overview"] as? String,
                                   stillPath: e["still_path"] as? String)
            info.airDate = (e["air_date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            info.runtime = (e["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            if let v = e["vote_average"] as? Double, v > 0 { info.rating = v }
            let crew = e["crew"] as? [[String: Any]] ?? []
            func names(_ jobs: Set<String>) -> [String]? {
                var seen = Set<String>()
                let l = crew.filter { jobs.contains($0["job"] as? String ?? "") }.compactMap { $0["name"] as? String }
                    .filter { seen.insert($0).inserted }
                return l.isEmpty ? nil : l
            }
            info.directors = names(["Director"])
            info.writers = names(["Writer", "Screenplay", "Teleplay", "Story"])
            out[n] = info
        }
        return out
    }

    public static func imageURL(_ path: String?, size: String = "w780") -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(size)\($0)") }
    }

    func imdbRating(_ imdbId: String) async -> String? {
        var c = URLComponents(string: "https://www.omdbapi.com/")!
        c.queryItems = [URLQueryItem(name: "i", value: imdbId), URLQueryItem(name: "apikey", value: omdbKey)]
        guard let (data, _) = try? await session.data(from: c.url!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = j["imdbRating"] as? String, r != "N/A" else { return nil }
        return r
    }

    /// Télécharge une image TMDb dans le cache si elle n'y est pas déjà.
    public func downloadImage(_ path: String?, size: String, to dest: URL) async -> Bool {
        guard let path else { return false }
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let url = URL(string: "https://image.tmdb.org/t/p/\(size)\(path)"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: dest)) != nil
    }
}
