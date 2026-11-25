import XCTest
@testable import StrapontinCore

/// Suivi rattaché au titre, quelle que soit la source.
final class WatchStateTests: XCTestCase {
    func p(_ pos: Double, at date: Double, watched: Bool = false) -> WatchPoint {
        WatchPoint(position: pos, duration: 3000, date: date, watched: watched)
    }

    func testKeysAreTitlesNotSources() {
        XCTAssertEqual(TitleKey(.tv, 1399, EpisodeKey(2, 5)).id, "tv:1399:2:5")
        XCTAssertEqual(TitleKey(.movie, 603).id, "movie:603")
        XCTAssertEqual(TitleKey(id: "tv:1399:2:5"), TitleKey(.tv, 1399, EpisodeKey(2, 5)))
        XCTAssertEqual(TitleKey(.movie, 603, EpisodeKey(1, 1)).id, "movie:603")
    }

    func testResumeFromTheMostRecentSourceBothWays() {
        let file = p(600, at: 100), stream = p(1500, at: 200)
        XCTAssertEqual(WatchMerge.resume(file, stream), 1500)          // fichier → streaming
        XCTAssertEqual(WatchMerge.resume(p(2000, at: 300), stream), 2000) // streaming → fichier
        XCTAssertEqual(WatchMerge.resume(p(0, at: 400, watched: true), stream), 0)   // vu ailleurs : depuis le début
        XCTAssertEqual(WatchMerge.resume(p(10, at: 1)), 0)                 // à peine commencé
    }

    func testMixedSeasonChainsAcrossSources() {
        // S1 E1–E3 en fichiers, E4 en streaming, E5 fichier ; S2 seulement en streaming
        let files = [EpisodeKey(1, 1): "/a/1", EpisodeKey(1, 2): "/a/2", EpisodeKey(1, 3): "/a/3", EpisodeKey(1, 5): "/a/5"]
        let streams = [EpisodeKey(1, 4): "http://s/4", EpisodeKey(1, 5): "http://s/5", EpisodeKey(2, 1): "http://s/21"]
        let src = CrossSource.sources(files: files, streams: streams)
        let known = (1...6).map { EpisodeKey(1, $0) } + [EpisodeKey(2, 1), EpisodeKey(2, 2)]
        XCTAssertEqual(CrossSource.next(after: EpisodeKey(1, 3), known: known, sources: src)?.1, .stream("http://s/4"))
        XCTAssertEqual(CrossSource.next(after: EpisodeKey(1, 4), known: known, sources: src)?.1, .file("/a/5"))  // le fichier d'abord
        let six = CrossSource.next(after: EpisodeKey(1, 5), known: known, sources: src)
        XCTAssertEqual(six?.0, EpisodeKey(1, 6)); XCTAssertNil(six?.1)                                        // à télécharger
        XCTAssertEqual(CrossSource.next(after: EpisodeKey(1, 6), known: known, sources: src)?.1, .stream("http://s/21"))
        XCTAssertEqual(CrossSource.previous(before: EpisodeKey(2, 1), sources: src)?.0, EpisodeKey(1, 5))
        XCTAssertEqual(CrossSource.previous(before: EpisodeKey(1, 5), sources: src)?.1, .stream("http://s/4"))
        XCTAssertNil(CrossSource.previous(before: EpisodeKey(1, 1), sources: src))
    }

    func testUpNextUsesTheTitleWhateverTheSource() {
        let known = (1...10).map { EpisodeKey(1, $0) } + [EpisodeKey(2, 1)]
        let src = CrossSource.sources(files: [EpisodeKey(1, 10): "/s1e10"], streams: [EpisodeKey(2, 1): "http://s/21"])
        // S1E10 vu en fichier : à suivre, S2E1 (en streaming)
        let a = CrossSource.upNext(watch: [EpisodeKey(1, 10): p(0, at: 10, watched: true)], known: known, sources: src)
        XCTAssertEqual(a?.0, EpisodeKey(2, 1)); XCTAssertEqual(a?.resume, 0)
        // S2E1 commencé en streaming plus récemment : on le reprend à sa position
        let b = CrossSource.upNext(watch: [EpisodeKey(1, 10): p(0, at: 10, watched: true), EpisodeKey(2, 1): p(900, at: 20)],
                                   known: known, sources: src)
        XCTAssertEqual(b?.0, EpisodeKey(2, 1)); XCTAssertEqual(b?.resume, 900)
        XCTAssertNil(CrossSource.upNext(watch: [:], known: known, sources: src))
        // E4 vu en streaming, E5 lancé automatiquement puis fermé après 3 s : à suivre, E5 (pas E6)
        let c = CrossSource.upNext(watch: [EpisodeKey(1, 4): p(0, at: 10, watched: true), EpisodeKey(1, 5): p(3, at: 11)],
                                   known: known, sources: src)
        XCTAssertEqual(c?.0, EpisodeKey(1, 5)); XCTAssertEqual(c?.resume, 0)
    }
}
