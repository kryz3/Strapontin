import XCTest
@testable import StrapontinCore

/// Bibliothèque sans images (0.1.1) : les affiches et fonds absents du disque doivent être retéléchargés.
final class ArtworkTests: XCTestCase {
    func url(_ kind: String, _ m: Media) -> URL { URL(fileURLWithPath: "/cache/\(kind)/\(m.key).jpg") }

    func testMissingFilesAreListedForDownload() {
        var a = Media(tmdbId: 1, kind: .movie, title: "A"); a.posterPath = "/a.jpg"; a.backdropPath = "/a-fond.jpg"
        var b = Media(tmdbId: 2, kind: .tv, title: "B"); b.posterPath = "/b.jpg"; b.backdropPath = "/b-fond.jpg"
        let present: Set<String> = ["/cache/posters/movie:1.jpg", "/cache/backdrops/movie:1.jpg", "/cache/posters/tv:2.jpg"]
        let todo = Artwork.missing([a, b], posterURL: { self.url("posters", $0) }, backdropURL: { self.url("backdrops", $0) },
                                   exists: { present.contains($0.path) })
        XCTAssertEqual(todo, [Artwork.Missing(path: "/b-fond.jpg", size: "w1280", destination: url("backdrops", b))])
    }

    func testNothingToFetchWithoutTMDbImage() {
        let m = Media(tmdbId: 3, kind: .movie, title: "Sans image")   // pas d'affiche ni de fond sur TMDb
        XCTAssertTrue(Artwork.missing([m], posterURL: { self.url("p", $0) }, backdropURL: { self.url("b", $0) }, exists: { _ in false }).isEmpty)
    }
}
