import XCTest
@testable import StrapontinCore

final class FilenameParserTests: XCTestCase {
    func p(_ path: String, root: String? = nil) -> ParsedName {
        FilenameParser.parse(URL(fileURLWithPath: path), root: root.map { URL(fileURLWithPath: $0) })
    }

    func testMovieRelease() {
        let r = p("/Films/Inception.2010.1080p.BluRay.x265-GRP.mkv")
        XCTAssertFalse(r.isEpisode)
        XCTAssertEqual(r.title, "Inception")
        XCTAssertEqual(r.year, 2010)
        XCTAssertEqual(r.quality, "1080p · Blu-ray · HEVC")
    }

    func testMovieWithSpacesAndParens() {
        let r = p("/Films/Le Fabuleux Destin d'Amélie Poulain (2001).mkv")
        XCTAssertEqual(r.title, "Le Fabuleux Destin d'Amélie Poulain")
        XCTAssertEqual(r.year, 2001)
    }

    func testYearInTitle() {
        XCTAssertEqual(p("/Films/1917.2019.2160p.mkv").title, "1917")
        XCTAssertEqual(p("/Films/1917.2019.2160p.mkv").year, 2019)
        XCTAssertEqual(p("/Films/2001.A.Space.Odyssey.1968.mkv").title, "2001 A Space Odyssey")
    }

    func testMovieWithoutYear() {
        let r = p("/Films/Amelie.MULTi.1080p.WEB-DL.mkv")
        XCTAssertEqual(r.title, "Amelie")
        XCTAssertNil(r.year)
    }

    func testHDRRemux() {
        let q = p("/Films/Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.Atmos-GRP.mkv").quality ?? ""
        XCTAssertTrue(q.contains("4K"))
        XCTAssertTrue(q.contains("Remux"))
        XCTAssertTrue(q.contains("HDR"))
    }

    func testEpisode() {
        let r = p("/Séries/The Bear/Saison 2/The.Bear.S02E03.1080p.WEB.mkv", root: "/Séries")
        XCTAssertTrue(r.isEpisode)
        XCTAssertEqual(r.title, "The Bear")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 3)
    }

    func testEpisodeNamedOnlyByNumber() {
        let r = p("/Séries/Breaking Bad/Season 1/E05.mkv", root: "/Séries")
        XCTAssertTrue(r.isEpisode)
        XCTAssertEqual(r.title, "Breaking Bad")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 5)
    }

    func testEpisodeWithoutShowInName() {
        let r = p("/Séries/Severance/S01E01.mkv", root: "/Séries")
        XCTAssertEqual(r.title, "Severance")
        XCTAssertEqual(r.episode, 1)
    }

    func testSamplesIgnored() {
        XCTAssertFalse(FilenameParser.isVideo(URL(fileURLWithPath: "/x/Movie.2020.sample.mkv"), size: 1000))
        XCTAssertTrue(FilenameParser.isVideo(URL(fileURLWithPath: "/x/Movie.2020.mkv"), size: 1000))
        XCTAssertFalse(FilenameParser.isVideo(URL(fileURLWithPath: "/x/Movie.2020.nfo")))
    }

    func testGrouping() {
        let a = MediaFile(path: "/S/A/S01E01.mkv", folder: "/S", size: 1, mtime: 0, parsed: p("/S/Show/S01E01.mkv", root: "/S"))
        let b = MediaFile(path: "/S/A/S01E02.mkv", folder: "/S", size: 1, mtime: 0, parsed: p("/S/Show/S01E02.mkv", root: "/S"))
        let items = LibraryItem.build(files: [b, a], media: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].files.map(\.episode), [1, 2])
    }
}
