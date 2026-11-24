import XCTest
@testable import StrapontinCore

/// Lecture : chapitres, carte de fin, épisode suivant, pistes, détection d'intro sur des sons fabriqués.
final class PlaybackTests: XCTestCase {
    private let hour = 2700.0   // 45 min

    private func markers(_ chapters: [(String, Double)], detected: DetectedMarkers? = nil, d: Double = 2700) -> PlaybackMarkers {
        PlaybackMarkers(chapters: chapters.map { Chapter(title: $0.0, start: $0.1) }, detected: detected, duration: d)
    }

    // MARK: chapitres

    func testTitlesInSeveralLanguages() {
        for t in ["Intro", "Opening", "OP", "NCOP1", "Générique de début", "Générique d'ouverture", "Main Title", "Vorspann", "Abertura", "オープニング"] {
            XCTAssertEqual(ChapterTitle.role(t), .intro, t)
        }
        for t in ["End Credits", "Ending", "ED", "ED 2", "Outro", "Générique de fin", "Abspann", "Closing Credits", "Titoli di coda", "エンディング"] {
            XCTAssertEqual(ChapterTitle.role(t), .credits, t)
        }
        for t in ["Recap", "Previously on…", "Précédemment", "Résumé", "Résumé de l'épisode précédent", "Rückblick", "Resumen", "前回"] {
            XCTAssertEqual(ChapterTitle.role(t), .recap, t)
        }
        for t in ["Générique", "Credits"] { XCTAssertEqual(ChapterTitle.role(t), .theme, t) }
        for t in ["Épilogue", "Post-credits scene", "Scène post-générique"] { XCTAssertEqual(ChapterTitle.role(t), .story, t) }
        for t in ["Chapter 5", "Opération Phénix", "Fred", "Operation", "The Red Wedding", "00:41:12.000", "", "Introducing Mariko", "Part B"] {
            XCTAssertNil(ChapterTitle.role(t), t)
        }
    }

    func testIntroRecapAndNamedCredits() {
        let m = markers([("Recap", 0), ("Intro", 60), ("Chapter 1", 150), ("End Credits", 2500), ("Chapter 4", 2650)])
        XCTAssertEqual(m.recap?.span, MediaSpan(start: 0, end: 60))
        XCTAssertEqual(m.intro?.span, MediaSpan(start: 60, end: 150))
        XCTAssertEqual(m.credits?.span, MediaSpan(start: 2500, end: 2650))   // le nommé passe avant le dernier chapitre
        XCTAssertEqual(m.credits?.source, .namedChapter)
        XCTAssertEqual(m.skip(at: 10)?.kind, .recap)
        XCTAssertEqual(m.skip(at: 70), SkipOffer(kind: .intro, target: 150))
        XCTAssertNil(m.skip(at: 200))
    }

    func testGeneriqueDependsOnPosition() {
        let m = markers([("Film", 0), ("Générique", 40), ("Suite", 100), ("Générique", 2560)])
        XCTAssertEqual(m.intro?.span.start, 40)
        XCTAssertEqual(m.credits?.span.start, 2560)
    }

    func testShortLastChapterIsCredits() {
        let m = markers([("Chapter 1", 0), ("Chapter 2", 900), ("Chapter 3", 1700), ("Chapter 4", 2580)])
        XCTAssertEqual(m.credits, Marker(span: MediaSpan(start: 2580, end: 2700), source: .lastChapter))
    }

    func testLongLastChapterIsNot() {
        XCTAssertNil(markers([("Chapter 1", 0), ("Chapter 2", 900), ("Chapter 3", 2100)]).credits)
        // dans les 15 derniers %, mais 5 min ou plus
        XCTAssertNil(markers([("Chapter 1", 0), ("Chapter 2", 1000), ("Chapter 3", 2340)]).credits)
        // moins de 5 min, mais trop tôt dans un épisode court
        XCTAssertNil(markers([("Chapter 1", 0), ("Chapter 2", 400), ("Chapter 3", 1000)], d: 1260).credits)
    }

    func testEvenlySpacedChaptersAreNotCredits() {
        let every5 = stride(from: 0.0, to: 2640, by: 300).map { ("Chapter", $0) }
        XCTAssertNil(markers(every5, d: 2640).credits)
    }

    func testEpilogueAndSingleChapterAreNotCredits() {
        XCTAssertNil(markers([("A", 0), ("B", 700), ("Épilogue", 2600)]).credits)
        XCTAssertNil(markers([("Chapter 1", 0)]).credits)
    }

    func testAudioComesAfterChapters() {
        let found = DetectedMarkers(intro: MediaSpan(start: 30, end: 90), credits: MediaSpan(start: 2600, end: 2700))
        let none = markers([], detected: found)
        XCTAssertEqual(none.intro?.source, .audio)
        XCTAssertEqual(none.skip(at: 40)?.target ?? 0, 89.7, accuracy: 0.001)
        XCTAssertEqual(none.credits?.span.start, 2600)
        XCTAssertEqual(markers([("A", 0), ("B", 800), ("C", 2560)], detected: found).credits?.source, .lastChapter)
        XCTAssertEqual(markers([("A", 0), ("B", 2000)], detected: found).credits?.source, .audio)
    }

    func testWatched() {
        XCTAssertTrue(PlaybackMarkers.isWatched(position: 1100, duration: 1260, creditsStart: 1090))   // 87 %
        XCTAssertFalse(PlaybackMarkers.isWatched(position: 2550, duration: 2700, creditsStart: 2600))  // 94 %, avant le générique
        XCTAssertTrue(PlaybackMarkers.isWatched(position: 2550, duration: 2700, creditsStart: nil))
        XCTAssertFalse(PlaybackMarkers.isWatched(position: 10, duration: 0, creditsStart: nil))
    }

    // MARK: carte de fin

    private let credits = MediaSpan(start: 2580, end: 2700)

    /// Lecture continue de `from` à `to` ; renvoie le moment de l'enchaînement.
    private func play(_ card: inout EndCard, _ from: Double, _ to: Double, credits: MediaSpan?,
                      next: EndCard.Next = .ready, autoplay: Bool = true) -> Double? {
        for t in stride(from: from, through: to, by: 0.5) where card.update(position: t, duration: hour, credits: credits, next: next, autoplay: autoplay) {
            return t
        }
        return nil
    }

    func testCountdownFromCreditsStart() {
        var c = EndCard()
        XCTAssertNil(play(&c, 2570, 2579.5, credits: credits))
        XCTAssertFalse(c.visible)
        XCTAssertNil(play(&c, 2580, 2580, credits: credits))
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.secondsLeft, 10)
        XCTAssertEqual(play(&c, 2580.5, 2600, credits: credits), 2590)
    }

    func testPauseHoldsCountdown() {
        var c = EndCard()
        _ = play(&c, 2580, 2584, credits: credits)
        for _ in 0..<50 { XCTAssertFalse(c.update(position: 2584, duration: hour, credits: credits, next: .ready, autoplay: true)) }
        XCTAssertEqual(c.secondsLeft, 6)
    }

    func testUnknownCreditsNeverCutTheEpisode() {
        var c = EndCard()
        XCTAssertNil(play(&c, 2660, 2699.5, credits: nil))
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.secondsLeft, 1)
        XCTAssertEqual(c.reachedEnd(next: .ready, autoplay: true), .playNext)
        XCTAssertEqual(EndCard.start(duration: hour, credits: nil), 2670)
    }

    func testDismissWatchesCreditsWithoutChaining() {
        var c = EndCard()
        _ = play(&c, 2580, 2583, credits: credits)
        c.dismiss()
        XCTAssertNil(play(&c, 2583.5, 2699, credits: credits))
        XCTAssertFalse(c.visible)
        XCTAssertEqual(c.reachedEnd(next: .ready, autoplay: true), .stay)
        // revenir avant le générique (mpv quitte la fin) efface le refus
        c.leftEnd()
        _ = play(&c, 2000, 2000, credits: credits)
        XCTAssertFalse(c.dismissed)
    }

    func testAutoplayOffAndNotOwnedNeverChain() {
        var off = EndCard()
        XCTAssertNil(play(&off, 2580, 2699, credits: credits, autoplay: false))
        XCTAssertTrue(off.visible)
        XCTAssertNil(off.secondsLeft)
        XCTAssertEqual(off.reachedEnd(next: .ready, autoplay: false), .stay)

        var missing = EndCard()
        XCTAssertNil(play(&missing, 2580, 2699, credits: credits, next: .notOwned))
        XCTAssertTrue(missing.visible)
        XCTAssertNil(missing.secondsLeft)
        XCTAssertEqual(missing.reachedEnd(next: .notOwned, autoplay: true), .stay)

        var last = EndCard()
        _ = play(&last, 2580, 2600, credits: credits, next: .none)
        XCTAssertFalse(last.visible)
        XCTAssertEqual(last.reachedEnd(next: .none, autoplay: true), .close)
    }

    func testSceneAfterCreditsIsNotSkipped() {
        var c = EndCard()
        let middle = MediaSpan(start: 2500, end: 2600)
        XCTAssertNil(play(&c, 2500, 2699, credits: middle))
        XCTAssertTrue(c.visible)
        XCTAssertTrue(c.compact)
        var d = EndCard()
        _ = d.update(position: 2510, duration: hour, credits: middle, next: .ready, autoplay: true)
        XCTAssertEqual(d.sceneAfter, 2600)
        XCTAssertFalse(d.compact)
        XCTAssertEqual(c.reachedEnd(next: .ready, autoplay: true), .playNext)
    }

    /// Sitcom : 5 s de scène après un générique entendu. Rien n'est coupé, même pas ces 5 s.
    func testSitcomTagAfterCreditsIsWatched() {
        var c = EndCard()
        let heard = MediaSpan(start: 2655, end: 2695)
        XCTAssertNil(play(&c, 2655, 2699.5, credits: heard))
        XCTAssertEqual(c.sceneAfter, nil)   // la scène est déjà là
        XCTAssertTrue(c.compact)
        XCTAssertEqual(c.reachedEnd(next: .ready, autoplay: true), .playNext)
    }

    func testOnlyCertainCreditsAreCut() {
        let named = Marker(span: MediaSpan(start: 2600, end: 2700), source: .namedChapter)
        let heard = Marker(span: MediaSpan(start: 2600, end: 2698.5), source: .audio)
        let heardEarly = Marker(span: MediaSpan(start: 2600, end: 2690), source: .audio)
        let lastChapter = Marker(span: MediaSpan(start: 2600, end: 2700), source: .lastChapter)
        XCTAssertTrue(EndCard.endsWithCredits(named, duration: hour))
        XCTAssertTrue(EndCard.endsWithCredits(heard, duration: hour))
        XCTAssertFalse(EndCard.endsWithCredits(heardEarly, duration: hour))
        XCTAssertFalse(EndCard.endsWithCredits(lastChapter, duration: hour))
        XCTAssertFalse(EndCard.endsWithCredits(nil, duration: hour))
    }

    /// Dernier chapitre « plausible » : la carte paraît à son début, mais on attend la vraie fin.
    func testPlausibleLastChapterWaitsForTheEnd() {
        var c = EndCard()
        let last = MediaSpan(start: 2580, end: 2700)
        for t in stride(from: 2580.0, through: 2699.5, by: 0.5) {
            XCTAssertFalse(c.update(position: t, duration: hour, credits: last, certain: false, next: .ready, autoplay: true))
        }
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.secondsLeft, 1)
        var early = EndCard()
        _ = early.update(position: 2581, duration: hour, credits: last, certain: false, next: .ready, autoplay: true)
        XCTAssertTrue(early.visible)
        XCTAssertNil(early.secondsLeft)   // compte affiché dans les 30 dernières secondes seulement
        XCTAssertEqual(c.reachedEnd(next: .ready, autoplay: true), .playNext)
    }

    func testEndSurvivesTheLastFrameAndClearsOnSeekBack() {
        var c = EndCard()
        _ = play(&c, 2690, 2699.5, credits: credits, next: .notOwned)
        XCTAssertEqual(c.reachedEnd(next: .notOwned, autoplay: true), .stay)
        _ = play(&c, 2695, 2695, credits: credits, next: .notOwned)   // la dernière image est un peu avant
        XCTAssertTrue(c.ended)
        c.leftEnd()
        XCTAssertFalse(c.ended)
    }

    func testSeekIntoCreditsRestartsCountdown() {
        var c = EndCard()
        _ = play(&c, 2580, 2586, credits: credits)
        XCTAssertFalse(c.update(position: 2650, duration: hour, credits: credits, next: .ready, autoplay: true))
        XCTAssertEqual(c.secondsLeft, 10)
    }

    func testEpisodeArrivingDuringCreditsStartsAFreshCountdown() {
        var c = EndCard()
        XCTAssertNil(play(&c, 2580, 2640, credits: credits, next: .notOwned))
        XCTAssertFalse(c.update(position: 2640.5, duration: hour, credits: credits, next: .ready, autoplay: true))
        XCTAssertEqual(c.secondsLeft, 10)
    }

    // MARK: épisode précédent

    func testPreviousEpisodeWithinSeasonAndAcrossSeasons() {
        let s1e9 = file("Show.S01E09"), s1e10 = file("Show.S01E10"), s2e1 = file("Show.S02E01"), s2e3 = file("Show.S02E03")
        let all = [s1e9, s1e10, s2e1, s2e3]
        XCTAssertEqual(PreviousEpisode.before(s2e3, files: all)?.path, s2e1.path)    // trou : le plus proche avant
        XCTAssertEqual(PreviousEpisode.before(s2e1, files: all)?.path, s1e10.path)   // saison d'avant
        XCTAssertNil(PreviousEpisode.before(s1e9, files: all))                       // premier épisode
    }

    func testPreviousEpisodeSkipsSpecialsAndDoubleEpisodes() {
        let special = file("Show.S00E01"), s1e1 = file("Show.S01E01"), double = file("Show.S01E02E03"), s1e4 = file("Show.S01E04")
        let all = [special, s1e1, double, s1e4]
        XCTAssertEqual(PreviousEpisode.before(s1e4, files: all)?.path, double.path)
        XCTAssertEqual(PreviousEpisode.before(double, files: all)?.path, s1e1.path)
        XCTAssertNil(PreviousEpisode.before(s1e1, files: all))                       // pas les spéciaux
    }

    // MARK: épisode suivant

    private func file(_ name: String) -> MediaFile {
        var f = MediaFile(path: "/s/\(name).mkv", folder: "/s", size: 1, mtime: 0, parsed: FilenameParser.parse(URL(fileURLWithPath: "/s/\(name).mkv")))
        f.added = 0
        return f
    }

    private func info(_ air: String?) -> EpisodeInfo {
        var i = EpisodeInfo(name: nil, overview: nil, stillPath: nil)
        i.airDate = air
        return i
    }

    private var tmdb: [Int: [Int: EpisodeInfo]] {
        [1: [1: info("2025-01-01"), 2: info("2025-01-08"), 3: info("2025-01-15")],
         2: [1: info("2026-01-01"), 2: info("2026-12-25")]]
    }

    private func next(_ current: String, _ others: [String], online: Bool = true) -> NextEpisode {
        let n = NextEpisode.after(file(current), files: ([current] + others).map(file), seasons: online ? [1, 2] : [],
                          episodes: online ? tmdb : [:], today: "2026-11-22")
        // à l'heure d'ajout près
        if case .inLibrary(var f) = n { f.added = 0; return .inLibrary(f) }
        return n
    }

    func testNextEpisode() {
        XCTAssertEqual(next("X.S01E01", ["X.S01E02"]), .inLibrary(file("X.S01E02")))
        XCTAssertEqual(next("X.S01E01", ["X.S01E03"]), .missing(EpisodeKey(1, 2)))
        XCTAssertEqual(next("X.S01E03", ["X.S02E01"]), .inLibrary(file("X.S02E01")))
        XCTAssertEqual(next("X.S01E03", []), .missing(EpisodeKey(2, 1)))
        XCTAssertEqual(next("X.S02E01", []), .none)   // pas encore diffusé
        XCTAssertEqual(next("X.S01E01E02", ["X.S01E03"]), .inLibrary(file("X.S01E03")))
        // deux versions du même épisode ne s'enchaînent pas
        XCTAssertEqual(next("X.S01E01.720p", ["X.S01E01.1080p", "X.S01E02"]), .inLibrary(file("X.S01E02")))
        XCTAssertEqual(next("X.S01E01.720p", ["X.S01E02.1080p", "X.S01E02.720p"]), .inLibrary(file("X.S01E02.720p")))
    }

    func testNextEpisodeOffline() {
        XCTAssertEqual(next("X.S01E01", ["X.S01E03"], online: false), .missing(EpisodeKey(1, 2)))
        XCTAssertEqual(next("X.S01E03", ["X.S02E01"], online: false), .inLibrary(file("X.S02E01")))
        XCTAssertEqual(next("X.S01E03", [], online: false), .none)
    }

    // MARK: pistes

    func testTracksFollowLanguageNotNumber() {
        let vo = TrackTraits(id: 2, language: "eng", title: "VO", channels: 6)
        let next = [TrackTraits(id: 1, language: "en", title: "VO", channels: 6), TrackTraits(id: 2, language: "fre", title: "VFF", channels: 6)]
        XCTAssertEqual(TrackChoice.matching(vo, in: next, subtitles: false), .track(1))

        let quebec = TrackTraits(id: 1, language: "fre", title: "VFQ")
        let french = [TrackTraits(id: 1, language: "fra", title: "VFF"), TrackTraits(id: 2, language: "fra", title: "VFQ 5.1")]
        XCTAssertEqual(TrackChoice.matching(quebec, in: french, subtitles: false), .track(2))

        let forced = TrackTraits(id: 1, language: "fre", title: "Forced", forced: true)
        let full = TrackTraits(id: 1, language: "fr", title: "Complets")
        XCTAssertEqual(TrackChoice.matching(forced, in: [full], subtitles: true), .off)
        XCTAssertEqual(TrackChoice.matching(full, in: [forced, TrackTraits(id: 3, language: "fre", title: "Full")], subtitles: true), .track(3))
        XCTAssertEqual(TrackChoice.matching(nil, in: [full], subtitles: true), .off)
        XCTAssertEqual(TrackChoice.matching(vo, in: [full], subtitles: false), .automatic)
    }

    // MARK: empreinte audio, sur des sons fabriqués

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// « Musique » non périodique : trois notes tirées au hasard toutes les 0,3 s.
    private func music(seconds: Double, seed: UInt64) -> [Float] {
        var r = Seeded(state: seed)
        var out = [Float]()
        let note = Int(0.3 * 8000), total = Int(seconds * 8000)
        out.reserveCapacity(total + note)
        while out.count < total {
            let f = (0..<3).map { _ in Float.random(in: 300...2000, using: &r) }
            for i in 0..<note {
                let t = Float(i) / 8000
                var v: Float = 0
                for x in f { v += sin(2 * .pi * x * t) }
                out.append(v * 0.12 + Float.random(in: -0.02...0.02, using: &r))
            }
        }
        return Array(out.prefix(total))
    }

    private func episode(_ n: Int, introAt: Double?, sameCredits: Bool = true, gain: Float = 1) -> EpisodeAudio {
        var head = music(seconds: 75, seed: UInt64(1000 + n))
        if let at = introAt {
            let intro = music(seconds: 20, seed: 7).map { $0 * gain }, start = Int(at * 8000)
            head.replaceSubrange(start..<start + intro.count, with: intro)
        }
        let tail = music(seconds: 35, seed: UInt64(2000 + n)) + music(seconds: 25, seed: sameCredits ? 9 : UInt64(3000 + n))
        return EpisodeAudio(id: "e\(n)", episode: n, duration: 150,
                            head: AudioFingerprint(samples: head), tail: AudioFingerprint(samples: tail))
    }

    func testDetectsSharedIntroAtDifferentOffsets() {
        let eps = [episode(1, introAt: 5), episode(2, introAt: 23.04, gain: 0.5), episode(3, introAt: 41.37),
                   episode(4, introAt: nil, sameCredits: false)]
        let found = SeasonAudioDetector.detect(eps)
        for (id, at) in [("e1", 5.0), ("e2", 23.04), ("e3", 41.37)] {
            XCTAssertEqual(found[id]?.intro?.start ?? -99, at, accuracy: 1.0, id)
            XCTAssertEqual(found[id]?.intro?.end ?? -99, at + 20, accuracy: 1.0, id)
            // fin analysée : 60 dernières secondes, le générique commence 35 s dedans
            XCTAssertEqual(found[id]?.credits?.start ?? -99, 125, accuracy: 1.2, id)
            XCTAssertEqual(found[id]?.credits?.end ?? -99, 150, accuracy: 0.1, id)
        }
        XCTAssertNil(found["e4"]?.intro)
        XCTAssertNil(found["e4"]?.credits)
    }

    func testNothingInCommonMeansNoButton() {
        let found = SeasonAudioDetector.detect([episode(1, introAt: nil, sameCredits: false), episode(2, introAt: nil, sameCredits: false)])
        XCTAssertNil(found["e1"]?.intro)
        XCTAssertNil(found["e1"]?.credits)
    }

    func testSameEpisodeTwiceIsNeverCompared() {
        var copy = episode(1, introAt: 5)
        copy.id = "copie"
        let found = SeasonAudioDetector.detect([episode(1, introAt: 5), copy])
        XCTAssertNil(found["e1"]?.intro)
        XCTAssertNil(found["copie"]?.credits)
    }

    func testSilenceIsNotAMatch() {
        let quiet = AudioFingerprint(samples: [Float](repeating: 0, count: 8000 * 40))
        XCTAssertNil(AudioFingerprint.commonSpan(quiet, quiet, length: SeasonAudioDetector.introLength))
    }

    func testFingerprintRoundTrip() {
        let f = AudioFingerprint(samples: music(seconds: 3, seed: 1))
        XCTAssertEqual(AudioFingerprint(data: f.data), f)
    }
}
