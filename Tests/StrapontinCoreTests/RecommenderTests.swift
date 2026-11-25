import XCTest
@testable import StrapontinCore

/// Classement de « Pour toi » : goûts, exclusions, diversité, découverte.
final class RecommenderTests: XCTestCase {
    func pick(_ id: Int, _ genres: [Int], vote: Double = 7.5, because: String? = nil, kind: MediaKind = .movie, year: Int = 2020) -> TMDbPick {
        TMDbPick(tmdbId: id, kind: kind, title: "T\(id)", year: year, overview: "", posterPath: nil, backdropPath: nil,
                 genreIds: genres, vote: vote, voteCount: 1000, popularity: 50, because: because)
    }

    let sf = 878, drama = 18, comedy = 35, horror = 27

    var lovesSF: TasteProfile {
        TasteProfile.build([.init(kind: .movie, genreIds: [878], year: 2015, weight: 3),
                            .init(kind: .movie, genreIds: [878, 18], year: 2018, weight: 2),
                            .init(kind: .movie, genreIds: [27], year: 2010, weight: -3)])
    }

    func testTasteAndSharedRecommendationsComeFirst() {
        let ranked = Recommender.rank([
            pick(1, [comedy]),
            pick(2, [sf], because: "Dune"),
            pick(2, [sf], because: "Interstellar"),        // proposé par deux titres aimés
            pick(3, [sf], because: "Dune"),
        ], profile: lovesSF, exclude: [], discovery: 0)
        XCTAssertEqual(ranked.first?.tmdbId, 2)
        XCTAssertEqual(ranked.last?.tmdbId, 1)
        XCTAssertEqual(ranked.count, 3)                      // doublon fusionné
    }

    func testRejectedGenresSinkAndExclusionsDisappear() {
        let ranked = Recommender.rank([pick(10, [horror]), pick(11, [drama]), pick(12, [sf])],
                                      profile: lovesSF, exclude: [Media.key(.movie, 12)], discovery: 0)
        XCTAssertFalse(ranked.contains { $0.tmdbId == 12 })   // déjà vu / possédé / refusé
        XCTAssertEqual(ranked.last?.tmdbId, 10)               // genre rejeté en dernier
    }

    func testDiversityAvoidsThreeOfTheSameGenreInARow() {
        let many = (1...6).map { pick($0, [sf], because: "Dune") } + [pick(50, [drama], vote: 6), pick(51, [comedy], vote: 6)]
        let ranked = Recommender.rank(many, profile: lovesSF, exclude: [], discovery: 0)
        let firsts = ranked.prefix(5).map { $0.genreIds.first! }
        for i in 2..<firsts.count { XCTAssertFalse(firsts[i] == firsts[i - 1] && firsts[i] == firsts[i - 2], "trois \(firsts[i]) d'affilée") }
    }

    func testDiscoveryCardShowsUpRegularly() {
        // genres principaux alternés : seule la règle « découverte » peut faire passer la comédie en 4ᵉ
        let many = (1...10).map { pick($0, $0 % 2 == 0 ? [sf, drama] : [drama, sf], because: "Dune") } + [pick(99, [comedy], vote: 8)]
        let ranked = Recommender.rank(many, profile: lovesSF, exclude: [], discovery: 4)
        XCTAssertEqual(ranked[3].tmdbId, 99)                  // 4ᵉ carte : hors des genres habituels
    }

    func testColdStartUsesQuality() {
        let ranked = Recommender.rank([pick(1, [comedy], vote: 6), pick(2, [drama], vote: 8.5)], profile: TasteProfile(), exclude: [], discovery: 0)
        XCTAssertEqual(ranked.first?.tmdbId, 2)
    }
}
