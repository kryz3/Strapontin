import Foundation

/// Une personne (acteur, réalisateur…) trouvée sur TMDb.
public struct TMDbPerson: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var profilePath: String?
    /// « Acting », « Directing »…
    public var department: String?
    /// Quelques titres connus, pour la recherche (« Dune, Wonka »).
    public var knownFor: [String]
    public var popularity: Double

    public init(id: Int, name: String, profilePath: String?, department: String?, knownFor: [String], popularity: Double) {
        self.id = id; self.name = name; self.profilePath = profilePath; self.department = department
        self.knownFor = knownFor; self.popularity = popularity
    }
}

/// La page d'une personne : biographie et filmographie (films et séries réunis).
public struct TMDbPersonDetails: Sendable {
    public var person: TMDbPerson
    public var biography: String
    public var birthday: String?
    public var placeOfBirth: String?
    /// Rôles, du plus récent au plus ancien ; un titre n'apparaît qu'une fois.
    public var credits: [TMDbSearchResult]
}

extension TMDbClient {
    public func searchPeople(_ query: String) async throws -> [TMDbPerson] {
        let d = try await get("/search/person", ["query": query, "include_adult": "false"])
        return Self.people(d["results"] as? [[String: Any]] ?? [])
    }

    public func person(_ id: Int) async throws -> TMDbPersonDetails {
        let d = try await get("/person/\(id)", ["append_to_response": "combined_credits"])
        let p = Self.people([d]).first ?? TMDbPerson(id: id, name: "?", profilePath: nil, department: nil, knownFor: [], popularity: 0)
        let cast = ((d["combined_credits"] as? [String: Any])?["cast"] as? [[String: Any]]) ?? []
        let crew = ((d["combined_credits"] as? [String: Any])?["crew"] as? [[String: Any]]) ?? []
        // un acteur : ses rôles ; un réalisateur ou un scénariste : ses films
        let list = cast.isEmpty ? crew : cast
        return TMDbPersonDetails(person: p, biography: d["biography"] as? String ?? "", birthday: d["birthday"] as? String,
                                 placeOfBirth: d["place_of_birth"] as? String, credits: Self.filmography(list))
    }

    static func people(_ list: [[String: Any]]) -> [TMDbPerson] {
        list.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            let known = (r["known_for"] as? [[String: Any]] ?? []).compactMap { ($0["title"] as? String) ?? ($0["name"] as? String) }
            return TMDbPerson(id: id, name: name, profilePath: r["profile_path"] as? String,
                              department: r["known_for_department"] as? String, knownFor: Array(known.prefix(3)),
                              popularity: r["popularity"] as? Double ?? 0)
        }
    }

    /// Films et séries, sans doublon (un rôle récurrent dans une série compte une fois), sans les apparitions dans
    /// des talk-shows et sans fiche sans affiche quand il y en a avec ; du plus récent au plus ancien, les titres
    /// à venir en tête.
    public static func filmography(_ list: [[String: Any]]) -> [TMDbSearchResult] {
        var seen = Set<String>()
        var out: [(TMDbSearchResult, String, Double)] = []
        for r in list {
            guard let id = r["id"] as? Int, let type = r["media_type"] as? String,
                  let kind = MediaKind(rawValue: type) else { continue }
            let genres = r["genre_ids"] as? [Int] ?? []
            if kind == .tv, !Set(genres).isDisjoint(with: [10767, 10763]) { continue }   // talk-show, actualités
            guard seen.insert("\(type):\(id)").inserted else { continue }
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            let item = TMDbSearchResult(id: id, kind: kind, title: (r["title"] as? String) ?? (r["name"] as? String) ?? "?",
                                        year: Int(date.prefix(4)), overview: r["overview"] as? String ?? "",
                                        posterPath: r["poster_path"] as? String)
            out.append((item, date, r["popularity"] as? Double ?? 0))
        }
        let withPoster = out.filter { $0.0.posterPath != nil }
        let kept = withPoster.count >= 4 ? withPoster : out
        return kept.sorted { a, b in
            if a.1.isEmpty != b.1.isEmpty { return a.1.isEmpty }   // sans date (à venir) en tête
            return a.1 > b.1
        }.map(\.0)
    }
}
