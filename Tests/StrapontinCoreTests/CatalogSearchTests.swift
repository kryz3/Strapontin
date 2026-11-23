import XCTest
@testable import StrapontinCore

final class CatalogSearchTests: XCTestCase {
    func testFoldIgnoresAccentsAndCase() {
        XCTAssertEqual(CatalogSearch.fold("Shōgun"), "shogun")
        XCTAssertTrue(CatalogSearch.fold("Le Fabuleux Destin d'Amélie Poulain").contains(CatalogSearch.fold("amelie")))
    }

    func testExactTitleFirst() {
        func r(_ id: Int, _ t: String, _ k: MediaKind) -> TMDbSearchResult { TMDbSearchResult(kind: k, tmdbId: id, title: t, year: nil, posterPath: nil) }
        let tmdb = [r(1, "Shogun Cop", .movie), r(2, "Baby Cart : Shogun", .movie), r(3, "Shōgun", .tv), r(4, "Shogun's Ninja", .movie)]
        XCTAssertEqual(CatalogSearch.rank(tmdb, "shogun").map(\.id), [3, 1, 4, 2])
    }
}
