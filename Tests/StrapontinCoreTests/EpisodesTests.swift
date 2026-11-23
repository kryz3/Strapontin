import XCTest
@testable import StrapontinCore

/// Séries épisode par épisode : requête, filtrage, rattachement, état d'une ligne, boutons de saison.
final class EpisodesTests: XCTestCase {
    private let today = "2026-11-22"

    private func torrent(_ hash: String, _ name: String, progress: Double = 0.4, state: String = "downloading") -> Torrent {
        Torrent(hash: hash, name: name, progress: progress, state: state, dlspeed: 0, eta: 0, size: 100,
                savePath: "/d", contentPath: "/d/\(name)", addedOn: 0)
    }

    private func file(_ path: String) -> MediaFile {
        MediaFile(path: path, folder: "/s", size: 1, mtime: 0, parsed: FilenameParser.parse(URL(fileURLWithPath: path)))
    }

    private func item(_ title: String, tmdb: Int? = nil) -> TorznabItem {
        TorznabItem(title: title, guid: title, link: nil, magnet: nil, infoHash: nil, detailsURL: nil, size: 1,
                    seeders: 20, peers: 20, grabs: 0, categories: [5000], imdbId: nil, tmdbId: tmdb, published: nil, downloadFactor: 1)
    }

    private func status(_ e: Int, owned: Set<EpisodeKey> = [], transfers: [EpisodeTransfer] = [], sending: Bool = false,
                        versions: Int? = 3, pack: Bool = true, air: String? = "2026-01-01") -> EpisodeStatus {
        EpisodeRules.status(season: 1, episode: e, owned: owned, transfers: transfers, sending: sending,
                            versions: versions, hasPack: pack, airDate: air, today: today)
    }

    // MARK: noms de releases réels

    func testEpisodeVersusPack() {
        let e3 = ReleaseInfo.parse("Shogun.2024.S01E03.MULTi.1080p.WEB.H265-FW")
        XCTAssertTrue(e3.isRelease(season: 1, episode: 3))
        XCTAssertFalse(e3.isRelease(season: 1, episode: 4))
        XCTAssertFalse(e3.isRelease(season: 2, episode: 3))
        let pack = ReleaseInfo.parse("Shogun 2024 S01 MULTi 1080p WEB H264-FW")
        XCTAssertTrue(pack.isSeasonPack)
        XCTAssertNil(pack.episodes)
        XCTAssertFalse(pack.isRelease(season: 1, episode: 3))
    }

    func testFourDigitEpisodeIsNotTruncated() {
        let i = ReleaseInfo.parse("One Piece S01E1128 VOSTFR 1080p WEB x264 AAC -Tsundere-Raws (CR)")
        XCTAssertEqual(i.episode, 1128)
        XCTAssertFalse(i.isRelease(season: 1, episode: 112))
        XCTAssertEqual(file("/s/One.Piece.S01E1128.mkv").episode, 1128)
    }

    func testMultiEpisodeRanges() {
        for n in ["Serie.S01E01E02.MULTi.1080p", "Serie S01E01-E02 MULTi", "Serie.S01E01-02.MULTi", "Serie S01E01 & E02 MULTi"] {
            XCTAssertEqual(ReleaseInfo.parse(n).episodes, 1...2, n)
        }
        for n in ["Serie.S01E03-1080p.MULTi", "Serie.S01E03.1080p.x264-FW", "Serie.S01E03.5.1.MULTi", "Taratata.S26E03.2026.11.20.FRENCH"] {
            XCTAssertEqual(ReleaseInfo.parse(n).episodes, 3...3, n)
        }
    }

    func testYearAfterSeasonSeparatesHomonyms() {
        var m = Media(tmdbId: 126308, kind: .tv, title: "Shōgun")
        m.year = 2024
        let f = Follow(media: m)
        XCTAssertEqual(ReleaseInfo.parse("Shogun.S01.1980.MULTi.1080p.Bluray").year, 1980)
        XCTAssertFalse(AutoGrab.matches(item("Shogun.S01.1980.MULTi.1080p.Bluray"), f))
        XCTAssertTrue(AutoGrab.matches(item("Shogun.2024.S01.MULTi.1080p.WEB"), f))
        XCTAssertTrue(AutoGrab.matches(item("Shogun.S01.MULTi.1080p.WEB"), f))
    }

    func testRemakeIsNotOfferedForTheOriginal() {
        var anime = Media(tmdbId: 37854, kind: .tv, title: "One Piece")
        anime.year = 1999
        let f = Follow(media: anime)
        XCTAssertFalse(AutoGrab.matches(item("One.Piece.2023.S01E01.VOSTFR.WEB.1080p.DDP5.1.x264"), f))
        XCTAssertTrue(AutoGrab.matches(item("One.Piece.S01E01.MULTi.576p.DVDRip"), f))
        // saison 2 : l'année de diffusion de la saison tranche
        XCTAssertFalse(EpisodeRules.yearFits(2023, seriesYear: 1999, airDates: ["2001-03-21", "2001-12-30"]))
        XCTAssertTrue(EpisodeRules.yearFits(2026, seriesYear: 2021, airDates: ["2026-11-22"]))
        XCTAssertTrue(EpisodeRules.yearFits(2021, seriesYear: 2021, airDates: ["2026-11-22"]))
        XCTAssertTrue(EpisodeRules.yearFits(nil, seriesYear: 1999, airDates: ["2001-03-21"]))
        XCTAssertTrue(EpisodeRules.yearFits(2023, seriesYear: 1999, airDates: []))
    }

    // MARK: requête

    func testEpisodeSearchRequest() async throws {
        RecordingProtocol.queries = []
        let c = TorznabClient(endpoint: "https://exemple.invalid/api/torznab", apiKey: "k", protocolClasses: [RecordingProtocol.self])
        _ = try await c.searchTV(title: "Shogun", otherTitles: ["Shōgun"], season: 1, episode: 3, imdbId: "tt2788316", tvdbId: 392573)
        let searches = RecordingProtocol.queries.filter { $0["t"] == "tvsearch" }
        XCTAssertEqual(searches.count, 4)   // TVDB, IMDb, deux titres
        XCTAssertTrue(searches.allSatisfy { $0["season"] == "1" && $0["ep"] == "3" })
        XCTAssertEqual(searches.compactMap { $0["tvdbid"] }, ["392573"])
        XCTAssertEqual(searches.compactMap { $0["imdbid"] }, ["tt2788316"])
        XCTAssertEqual(Set(searches.compactMap { $0["q"] }), ["Shogun", "Shōgun"])
    }

    func testTMDbEpisodeFields() {
        let e = TMDbClient.episodes(["episodes": [[
            "episode_number": 3, "name": "Demain", "overview": "Résumé", "still_path": "/s.jpg", "air_date": "2024-03-05",
            "runtime": 57, "vote_average": 8.2,
            "crew": [["job": "Director", "name": "A"], ["job": "Writer", "name": "B"], ["job": "Teleplay", "name": "B"], ["job": "Editor", "name": "C"]],
        ]]])[3]
        XCTAssertEqual(e?.airDate, "2024-03-05")
        XCTAssertEqual(e?.runtime, 57)
        XCTAssertEqual(e?.rating, 8.2)
        XCTAssertEqual(e?.directors, ["A"])
        XCTAssertEqual(e?.writers, ["B"])
    }

    // MARK: rattachement

    func testLinkPlacesTorrentOnEpisodeAndSurvivesRestart() throws {
        var book = DownloadLinkBook()
        let m = Media(tmdbId: 126308, kind: .tv, title: "Shōgun")
        book.assign(hash: "AAA", media: m, season: 1, episode: 3)
        let back = try JSONDecoder().decode(DownloadLinkBook.self, from: JSONEncoder().encode(book))
        let t = try XCTUnwrap(EpisodeTransfer(torrent: torrent("aaa", "Big Buck Bunny"), link: back["aaa"]))
        XCTAssertTrue(t.covers(season: 1, episode: 3))
        XCTAssertFalse(t.covers(season: 1, episode: 4))
        let card = DownloadBoard.build(torrents: [torrent("aaa", "Big Buck Bunny")], book: back)[0]
        XCTAssertEqual(card.id, "tv:126308")
        XCTAssertEqual(card.seasonLabel, "S01E03")

        book.assign(hash: "AAA", media: Media(tmdbId: 10378, kind: .movie, title: "Big Buck Bunny"))
        XCTAssertNil(book["aaa"]?.episode)
    }

    func testTransferFromNameOnly() {
        XCTAssertEqual(EpisodeTransfer(torrent: torrent("a", "The.Bear.S02E05.MULTi.1080p"), link: nil)?.episodes, 5...5)
        XCTAssertEqual(EpisodeTransfer(torrent: torrent("a", "The.Bear.S02.MULTi.1080p"), link: nil)?.isPack, true)
        XCTAssertNil(EpisodeTransfer(torrent: torrent("a", "Big Buck Bunny"), link: nil))
    }

    func testFinishedFilesArePlacedOnEpisode() {
        let one = file("/s/Big Buck Bunny.mp4")
        XCTAssertEqual(EpisodeRules.placement(files: [one], season: 1, episode: 3), [one.path: EpisodeKey(1, 3)])
        let a = file("/s/Serie.S01E01.mkv"), b = file("/s/Serie.S01E02.mkv"), extra = file("/s/Bonus.mkv")
        XCTAssertEqual(EpisodeRules.placement(files: [a, b, extra], season: 1, episode: nil),
                       [a.path: EpisodeKey(1, 1), b.path: EpisodeKey(1, 2)])
    }

    func testOwnedCountsDoubleEpisodeFile() {
        XCTAssertEqual(EpisodeRules.owned([file("/s/Serie.S01E01E02.mkv"), file("/s/Serie.S01E05.mkv")]),
                       [EpisodeKey(1, 1), EpisodeKey(1, 2), EpisodeKey(1, 5)])
    }

    // MARK: état d'une ligne

    func testRowGoesFromDownloadToPlay() throws {
        var link = DownloadLink(hash: "h", mediaKey: "tv:1", season: 1)
        link.episode = 3
        let running = try XCTUnwrap(EpisodeTransfer(torrent: torrent("h", "x", progress: 0.4), link: link))
        let done = try XCTUnwrap(EpisodeTransfer(torrent: torrent("h", "x", progress: 1, state: "uploading"), link: link))
        XCTAssertEqual(status(3), .available(3))
        XCTAssertEqual(status(3, sending: true), .sending)
        XCTAssertEqual(status(3, transfers: [running]), .downloading(hash: "h", progress: 0.4, phase: .downloading, inPack: false))
        XCTAssertEqual(status(4, transfers: [running]), .available(3))
        XCTAssertEqual(status(3, transfers: [done]), .arriving)
        XCTAssertEqual(status(3, owned: [EpisodeKey(1, 3)], transfers: [done]), .owned)
        XCTAssertEqual(status(3, transfers: []), .available(3))   // annulé : Télécharger revient
    }

    func testPackCoversEveryEpisodeOfItsSeason() throws {
        let pack = try XCTUnwrap(EpisodeTransfer(torrent: torrent("p", "Serie.S01.MULTi.1080p"), link: nil))
        XCTAssertEqual(status(7, transfers: [pack]), .downloading(hash: "p", progress: 0.4, phase: .downloading, inPack: true))
        XCTAssertEqual(EpisodeTransfer.occupied([pack]), [EpisodeKey(1, 0)])
    }

    func testQuietStates() {
        XCTAssertEqual(status(1, versions: 0, air: "2026-12-24"), .upcoming)
        XCTAssertEqual(status(1, versions: 2, air: "2026-11-23"), .available(2))
        XCTAssertEqual(status(1, versions: 0), .inSeasonPack)
        XCTAssertEqual(status(1, versions: 0, pack: false), .unavailable)
        XCTAssertEqual(status(1, versions: nil), .unknown)
    }

    // MARK: saison

    func testSeasonPlan() {
        let none = SeasonPlan(statuses: [1: .available(2), 2: .available(2)], hasPack: true, seasonBusy: false, downloadable: [1, 2])
        XCTAssertTrue(none.offerPack)
        XCTAssertEqual(none.missing, [])

        let noPack = SeasonPlan(statuses: [1: .available(2), 2: .available(1), 3: .upcoming], hasPack: false, seasonBusy: false, downloadable: [1, 2])
        XCTAssertEqual(noPack.missing, [1, 2])
        XCTAssertTrue(noPack.missingFirst)

        let few = SeasonPlan(statuses: [1: .owned, 2: .owned, 3: .available(4)], hasPack: true, seasonBusy: false, downloadable: [3])
        XCTAssertTrue(few.missingFirst)

        var many: [Int: EpisodeStatus] = [1: .owned]
        for e in 2...10 { many[e] = .available(2) }
        let m = SeasonPlan(statuses: many, hasPack: true, seasonBusy: false, downloadable: Set(2...10))
        XCTAssertTrue(m.offerPack)
        XCTAssertFalse(m.missingFirst)
        XCTAssertEqual(m.missing, Array(2...10))

        let busy = SeasonPlan(statuses: [1: .downloading(hash: "h", progress: 0, phase: .downloading, inPack: false), 2: .available(1)],
                              hasPack: true, seasonBusy: true, downloadable: [2])
        XCTAssertFalse(busy.offerPack)
        XCTAssertEqual(busy.missing, [2])
    }

    func testPicksDoNotOverlap() {
        XCTAssertEqual(SeasonPlan.picks([1, 2, 3], candidates: [1...2, 1...1, 2...3, 3...3]) { $0 }, [1...2, 3...3])
    }

    // MARK: suivi automatique

    func testAutoGrabSkipsWhatIsAlreadyDownloading() {
        let f = Follow(media: Media(tmdbId: 7, kind: .tv, title: "Serie"))
        let items = ["Serie.S01E02.MULTi.1080p", "Serie.S01E03E04.MULTi.1080p", "Serie.S01E03.MULTi.720p", "Serie.S01E05.MULTi.1080p"].map { item($0, tmdb: 7) }
        let moving = [torrent("a", "Serie.S01E02.VOSTFR.720p"), torrent("b", "Serie.S01E04.VOSTFR.720p")]
            .compactMap { EpisodeTransfer(torrent: $0, link: nil) }
        let d = AutoGrab.decide(items: items, follows: [f], owned: [f.id: EpisodeTransfer.occupied(moving)], ownedMovies: [],
                                history: [], prefs: GrabPreferences())
        XCTAssertEqual(d.map(\.info.episode), [3, 5])
        XCTAssertEqual(d.first?.info.episodes, 3...3)
    }
}

/// Réseau simulé : note les paramètres des requêtes.
private final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var queries: [[String: String]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var q: [String: String] = [:]
        for i in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value }
        Self.queries.append(q)
        let xml = q["t"] == "caps"
            ? #"<?xml version="1.0"?><caps><searching><tv-search available="yes" supportedParams="q,season,ep,tvdbid,imdbid"/></searching></caps>"#
            : #"<?xml version="1.0"?><rss version="2.0"><channel></channel></rss>"#
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
