import Foundation

/// Fiches TMDb pour ce qu'on n'a pas encore : tendances et recherche.
extension TMDbClient {
    /// Tendances de la semaine (films ou séries).
    public func trending(_ kind: MediaKind) async throws -> [TMDbSearchResult] {
        results(try await get("/trending/\(kind.rawValue)/week"), kind: kind)
    }

    /// Films / séries populaires en ce moment.
    public func popular(_ kind: MediaKind) async throws -> [TMDbSearchResult] {
        results(try await get("/\(kind.rawValue)/popular"), kind: kind)
    }

    /// Numéros des saisons d'une série (sans les « spéciaux », saison 0).
    public func seasonNumbers(tvId: Int) async -> [Int] {
        guard let d = try? await get("/tv/\(tvId)") else { return [] }
        return (d["seasons"] as? [[String: Any]] ?? []).compactMap { $0["season_number"] as? Int }.filter { $0 > 0 }.sorted()
    }

    func results(_ d: [String: Any], kind: MediaKind) -> [TMDbSearchResult] {
        (d["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            return TMDbSearchResult(id: id, kind: kind, title: (r["title"] as? String) ?? (r["name"] as? String) ?? "?",
                                    year: Int(date.prefix(4)), overview: r["overview"] as? String ?? "",
                                    posterPath: r["poster_path"] as? String)
        }
    }
}

extension TMDbSearchResult {
    /// Pour afficher une fiche connue (un suivi, par ex.) avec les mêmes cartes que les résultats TMDb.
    public init(kind: MediaKind, tmdbId: Int, title: String, year: Int?, posterPath: String?) {
        self.init(id: tmdbId, kind: kind, title: title, year: year, overview: "", posterPath: posterPath)
    }
}

// MARK: « Pour toi »

extension TMDbClient {
    /// Recommandations TMDb à partir d'un titre (« Parce que tu as aimé … »).
    public func recommendations(_ kind: MediaKind, id: Int, because: String?) async throws -> [TMDbPick] {
        Self.picks(try await get("/\(kind.rawValue)/\(id)/recommendations"), kind: kind, because: because)
    }

    /// Découverte guidée par les genres préférés (« | » = l'un ou l'autre), titres bien notés et assez votés.
    public func discover(_ kind: MediaKind, genres: [Int], page: Int = 1) async throws -> [TMDbPick] {
        var p = ["sort_by": "popularity.desc", "vote_count.gte": "200", "vote_average.gte": "6.5",
                 "include_adult": "false", "page": String(page)]
        if !genres.isEmpty { p["with_genres"] = genres.map(String.init).joined(separator: "|") }
        return Self.picks(try await get("/discover/\(kind.rawValue)", p), kind: kind, because: nil)
    }

    /// Démarrage à froid : les mieux notés.
    public func topRated(_ kind: MediaKind) async throws -> [TMDbPick] {
        Self.picks(try await get("/\(kind.rawValue)/top_rated"), kind: kind, because: nil)
    }

    /// Genres de TMDb dans la langue choisie : nom → identifiant.
    public func genreIds(_ kind: MediaKind) async throws -> [String: Int] {
        let list = try await get("/genre/\(kind.rawValue)/list")["genres"] as? [[String: Any]] ?? []
        var out: [String: Int] = [:]
        for g in list { if let id = g["id"] as? Int, let name = g["name"] as? String { out[name] = id } }
        return out
    }

    static func picks(_ d: [String: Any], kind: MediaKind, because: String?) -> [TMDbPick] {
        (d["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            return TMDbPick(tmdbId: id, kind: kind, title: (r["title"] as? String) ?? (r["name"] as? String) ?? "?",
                            year: Int(date.prefix(4)), overview: r["overview"] as? String ?? "",
                            posterPath: r["poster_path"] as? String, backdropPath: r["backdrop_path"] as? String,
                            genreIds: r["genre_ids"] as? [Int] ?? [], vote: r["vote_average"] as? Double ?? 0,
                            voteCount: r["vote_count"] as? Int ?? 0, popularity: r["popularity"] as? Double ?? 0,
                            because: because)
        }
    }
}
