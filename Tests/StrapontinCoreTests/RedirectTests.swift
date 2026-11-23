import XCTest
@testable import StrapontinCore

/// Page ouverte sur une entrée qui change d'identifiant : elle suit la nouvelle fiche.
final class RedirectTests: XCTestCase {
    private func file(_ path: String, key: String?) -> MediaFile {
        var f = MediaFile(path: path, folder: "/f", size: 1, mtime: 0,
                          parsed: ParsedName(isEpisode: false, title: "Zorglub", year: 2019, season: nil, episode: nil, quality: nil))
        f.mediaKey = key
        return f
    }

    func testCorrectionRedirectsToNewFiche() {
        let sintel = Media(tmdbId: 45745, kind: .movie, title: "Sintel")
        let before = LibraryItem.build(files: [file("/f/z.mkv", key: nil)], media: [:])
        XCTAssertEqual(before.first?.id, "u:movie:zorglub:2019")
        let after = LibraryItem.build(files: [file("/f/z.mkv", key: sintel.key)], media: [sintel.key: sintel])
        XCTAssertEqual(LibraryItem.redirects(from: before, to: after), ["u:movie:zorglub:2019": "movie:45745"])
    }

    func testDeletedHasNoRedirectAndUnchangedIgnored() {
        let m = Media(tmdbId: 1, kind: .movie, title: "A")
        let before = LibraryItem.build(files: [file("/f/a.mkv", key: m.key), file("/f/z.mkv", key: nil)], media: [m.key: m])
        let after = LibraryItem.build(files: [file("/f/a.mkv", key: m.key)], media: [m.key: m])
        XCTAssertTrue(LibraryItem.redirects(from: before, to: after).isEmpty)
    }

    func testSplitGoesToMajority() {
        let a = Media(tmdbId: 1, kind: .movie, title: "A"), b = Media(tmdbId: 2, kind: .movie, title: "B")
        let before = LibraryItem.build(files: [file("/f/1.mkv", key: nil), file("/f/2.mkv", key: nil), file("/f/3.mkv", key: nil)], media: [:])
        let after = LibraryItem.build(files: [file("/f/1.mkv", key: a.key), file("/f/2.mkv", key: b.key), file("/f/3.mkv", key: b.key)],
                                      media: [a.key: a, b.key: b])
        XCTAssertEqual(LibraryItem.redirects(from: before, to: after)["u:movie:zorglub:2019"], "movie:2")
    }
}
