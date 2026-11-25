import XCTest
@testable import StrapontinCore

/// Filmographie d'une personne (page acteur).
final class PeopleTests: XCTestCase {
    func credit(_ id: Int, _ type: String, _ title: String, _ date: String, poster: Bool = true, genres: [Int] = []) -> [String: Any] {
        var r: [String: Any] = ["id": id, "media_type": type, (type == "movie" ? "title" : "name"): title,
                                (type == "movie" ? "release_date" : "first_air_date"): date, "genre_ids": genres]
        if poster { r["poster_path"] = "/\(id).jpg" }
        return r
    }

    func testFilmographyDedupesSortsAndSkipsTalkShows() {
        let list = [
            credit(1, "movie", "Ancien", "2010-05-01"),
            credit(2, "tv", "Série", "2018-01-01"),
            credit(2, "tv", "Série", "2018-01-01"),          // rôle récurrent : une seule fois
            credit(3, "tv", "Talk-show", "2020-01-01", genres: [10767]),
            credit(4, "movie", "À venir", ""),
            credit(5, "movie", "Récent", "2024-03-01"),
            credit(6, "movie", "Sans affiche", "2015-01-01", poster: false),
        ]
        let f = TMDbClient.filmography(list)
        XCTAssertEqual(f.map(\.title), ["À venir", "Récent", "Série", "Ancien"])
        XCTAssertEqual(f.first { $0.title == "Série" }?.kind, .tv)
    }

    func testPeopleParsing() {
        let p = TMDbClient.people([["id": 9, "name": "Jane Doe", "profile_path": "/j.jpg", "known_for_department": "Acting",
                                     "known_for": [["title": "Film A"], ["name": "Série B"]], "popularity": 12.5]])
        XCTAssertEqual(p.first?.knownFor, ["Film A", "Série B"])
        XCTAssertEqual(p.first?.department, "Acting")
    }
}
