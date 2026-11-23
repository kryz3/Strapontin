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
