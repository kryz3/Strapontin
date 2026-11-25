import XCTest
@testable import StrapontinCore

/// Qualité voulue (Réglages › Téléchargements), qualité gardée d'une série, taille maximale d'un épisode.
final class QualityTests: XCTestCase {
    func item(_ title: String, gb: Double = 2, seeders: Int = 20) -> TorznabItem {
        var it = TorznabItem(title: title, guid: title, size: Int64(gb * 1_073_741_824), categories: [5000])
        it.seeders = seeders
        return it
    }

    func pick(_ titles: [TorznabItem], _ prefs: GrabPreferences, style: SeriesStyle? = nil) -> String? {
        ReleasePicker.best(titles, prefs: prefs, style: style, where: { _ in true })?.0.title
    }

    let choices = [
        "Show.S01E01.MULTi.720p.WEB.H264-A",
        "Show.S01E01.MULTi.1080p.WEB.H264-B",
        "Show.S01E01.MULTi.1080p.BluRay.x264-C",
        "Show.S01E01.MULTi.2160p.WEB.H265-D",
    ]

    func testQualityChoiceDrivesResolution() {
        var p = GrabPreferences()
        let items = choices.map { item($0) }
        p.quality = .hd720
        XCTAssertEqual(pick(items, p), choices[0])
        p.quality = .fullHD                      // pas de 4K quand on veut du 1080p
        XCTAssertTrue(pick(items, p)?.contains("1080p") == true)
        p.quality = .uhdIfAvailable
        XCTAssertEqual(pick(items, p), choices[3])
        p.quality = .uhdIfAvailable              // 4K absente : la meilleure suivante
        XCTAssertTrue(pick(Array(items.prefix(3)), p)?.contains("1080p") == true)
    }

    func testSeriesKeepsItsQualityAndSource() {
        let style = SeriesStyle.from(names: ["Show.S01E01.1080p.BluRay.x264-C.mkv", "Show.S01E02.1080p.BluRay.x264-C.mkv"])
        XCTAssertEqual(style, SeriesStyle(resolution: 1080, source: "bluray"))
        var p = GrabPreferences()
        p.quality = .fullHD
        XCTAssertEqual(pick(choices.map { item($0) }, p, style: style), choices[2])   // BluRay, comme les autres
        p.matchExisting = false
        XCTAssertNotNil(pick(choices.map { item($0) }, p, style: style))
    }

    func testMaxEpisodeSizeSkipsBigEpisodesButNotPacks() {
        var p = GrabPreferences()
        p.maxEpisodeGB = 3
        XCTAssertNil(pick([item("Show.S01E01.MULTi.1080p.WEB.H264-B", gb: 5)], p))
        XCTAssertNotNil(pick([item("Show.S01.MULTi.1080p.WEB.H264-B", gb: 30)], p))
    }

    func testPerSeriesOverride() {
        let p = GrabPreferences()
        XCTAssertEqual(p.overriding(.uhdIfAvailable).maxResolution, 2160)
        XCTAssertEqual(p.overriding(nil).quality, .fullHD)
    }

    func testOldSavedPreferencesStillLoad() throws {
        let old = #"{"resolution":2160,"maxResolution":2160,"languages":["MULTi"],"minSeeders":3,"maxSizeGB":0,"avoidWords":["cam"]}"#
        let p = try JSONDecoder().decode(GrabPreferences.self, from: Data(old.utf8))
        XCTAssertEqual(p.quality, .uhdIfAvailable)
        XCTAssertEqual(p.minSeeders, 3)
        XCTAssertTrue(p.matchExisting)
    }

    func testSeriesQualityBeatsExistingEpisodes() {
        let media = Media(tmdbId: 7, kind: .tv, title: "Show")
        var f = Follow(media: media)
        let items = choices.map { t -> TorznabItem in var it = item(t); it.tmdbId = 7; return it }
        let style = SeriesStyle(resolution: 720, source: "web")
        func decided() -> String? {
            AutoGrab.decide(items: items, follows: [f], owned: [:], ownedMovies: [], history: [],
                            prefs: GrabPreferences(), styles: [f.id: style]).first?.item.title
        }
        XCTAssertEqual(decided(), choices[0])          // comme les épisodes déjà là : 720p WEB
        f.quality = .uhdIfAvailable
        XCTAssertEqual(decided(), choices[3])          // qualité choisie pour la série : 4K
    }
}
