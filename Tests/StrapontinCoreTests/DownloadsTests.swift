import XCTest
@testable import StrapontinCore

/// Téléchargements en affiches : état, rattachement torrent → fiche, regroupement, persistance.
final class DownloadsTests: XCTestCase {
    private func torrent(_ hash: String, _ name: String, progress: Double = 0.5, state: String = "downloading",
                         size: Int64 = 100, speed: Int64 = 0, added: Double = 0) -> Torrent {
        Torrent(hash: hash, name: name, progress: progress, state: state, dlspeed: speed, eta: 60, size: size,
                savePath: "/d", contentPath: "/d/\(name)", addedOn: added)
    }

    private func media(_ kind: MediaKind, _ id: Int, _ title: String, year: Int? = nil) -> Media {
        var m = Media(tmdbId: id, kind: kind, title: title)
        m.year = year
        m.posterPath = "/p\(id).jpg"
        return m
    }

    func testPhases() {
        XCTAssertEqual(torrent("a", "x", state: "downloading").phase, .downloading)
        XCTAssertEqual(torrent("a", "x", state: "stalledDL").phase, .waiting)
        XCTAssertEqual(torrent("a", "x", progress: 0, state: "metaDL").phase, .metadata)
        XCTAssertEqual(torrent("a", "x", state: "stoppedDL").phase, .paused)
        XCTAssertEqual(torrent("a", "x", state: "pausedDL").phase, .paused)
        XCTAssertEqual(torrent("a", "x", state: "queuedDL").phase, .queued)
        XCTAssertEqual(torrent("a", "x", state: "checkingDL").phase, .checking)
        XCTAssertEqual(torrent("a", "x", state: "error").phase, .error)
        XCTAssertEqual(torrent("a", "x", state: "missingFiles").phase, .error)
        XCTAssertEqual(torrent("a", "x", progress: 1, state: "uploading").phase, .done)
        XCTAssertEqual(torrent("a", "x", progress: 1, state: "stoppedUP").phase, .done)
        // états Transmission traduits
        let s = TransmissionClient.state(status: 0, progress: 0.3, rate: 0, error: 0)
        XCTAssertEqual(torrent("a", "x", state: s).phase, .paused)
        XCTAssertEqual(torrent("a", "x", state: TransmissionClient.state(status: 4, progress: 0.3, rate: 0, error: 3)).phase, .error)
    }

    func testGuessFromTorrentName() {
        XCTAssertEqual(TorrentGuess.parse("Big Buck Bunny"), TorrentGuess(kind: .movie, title: "Big Buck Bunny", year: nil, season: nil, episode: nil))
        XCTAssertEqual(TorrentGuess.parse("Sintel.2010.1080p.mkv")?.title, "Sintel")
        XCTAssertEqual(TorrentGuess.parse("Sintel.2010.1080p.mkv")?.year, 2010)
        let s = TorrentGuess.parse("The.Bear.S02.MULTi.1080p.WEB.H264-FW")
        XCTAssertEqual(s?.kind, .tv)
        XCTAssertEqual(s?.season, 2)
        XCTAssertEqual(s?.title, "The Bear")
        let e = TorrentGuess.parse("Shogun.2024.S01E03.1080p.WEB")
        XCTAssertEqual(e?.kind, .tv)
        XCTAssertEqual(e?.episode, 3)
        // magnet sans métadonnées : le moteur montre l'empreinte en guise de nom
        XCTAssertNil(TorrentGuess.parse("dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"))
        XCTAssertNil(TorrentGuess.parse(""))
    }

    func testDisplayName() {
        XCTAssertEqual(TorrentPayload.magnet("magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fx").displayName,
                       "Big Buck Bunny")
        XCTAssertNil(TorrentPayload.magnet("magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c").displayName)
        // .torrent minimal dont info.name = « a.mkv »
        let t = Data(base64Encoded: "ZDg6YW5ub3VuY2UxNDp1ZHA6Ly94OjEvYW5ubzEwOmNyZWF0ZWQgYnkzOmxlYzQ6aW5mb2Q2Omxlbmd0aGkxMmU0Om5hbWU1OmEubWt2MTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6AQEBAQEBAQEBAQEBAQEBAQEBAQFlZQ==")!
        XCTAssertEqual(TorrentPayload.file(t, name: "autre.torrent").displayName, "a.mkv")
        XCTAssertEqual(TorrentPayload.file(Data("<html>".utf8), name: "Sintel.torrent").displayName, "Sintel")
    }

    func testBookLinksAndIdentification() {
        var book = DownloadLinkBook()
        book.recordManual(hash: "AAA")
        let t = torrent("aaa", "Big Buck Bunny")
        XCTAssertTrue(book.needsIdentification(t))
        // rien trouvé : on ne réessaie pas le même nom…
        book.identified(hash: "aaa", name: "Big Buck Bunny", media: nil, season: nil, episode: nil)
        XCTAssertFalse(book.needsIdentification(t))
        // … mais un nouveau nom (métadonnées du magnet arrivées) relance l'identification
        XCTAssertTrue(book.needsIdentification(torrent("aaa", "Big.Buck.Bunny.2008.1080p")))
        book.identified(hash: "aaa", name: "Big.Buck.Bunny.2008.1080p", media: media(.movie, 10378, "Big Buck Bunny"), season: nil, episode: nil)
        XCTAssertEqual(book["AAA"]?.mediaKey, "movie:10378")
        XCTAssertFalse(book.needsIdentification(t))

        // rattachement à la main : prioritaire, jamais écrasé par l'automatique
        book.assign(hash: "aaa", media: media(.movie, 45745, "Sintel"))
        book.identified(hash: "aaa", name: "zzz", media: media(.movie, 1, "Autre"), season: nil, episode: nil)
        XCTAssertEqual(book["aaa"]?.mediaKey, "movie:45745")

        // envoi depuis une fiche de l'indexeur
        book.record(hash: "BBB", media: media(.tv, 136315, "The Bear"), mediaKey: nil, season: 2, episode: nil, source: .tracker)
        XCTAssertEqual(book["bbb"]?.mediaKey, "tv:136315")
        XCTAssertEqual(book["bbb"]?.season, 2)
        XCTAssertFalse(book.needsIdentification(torrent("bbb", "The.Bear.S02")))
    }

    func testSeedFromHistory() {
        var book = DownloadLinkBook()
        book.seed(from: [GrabRecord(followId: "movie:693134", season: nil, episode: nil, infoHash: "ABC", release: "Dune", date: Date()),
                         GrabRecord(followId: "", season: nil, episode: nil, infoHash: "def", release: "brut", date: Date())])
        XCTAssertEqual(book["abc"]?.mediaKey, "movie:693134")
        XCTAssertNil(book["def"])
        XCTAssertEqual(book.keysWithoutMedia, ["movie:693134"])
        book.fill(media(.movie, 693134, "Dune : Deuxième partie"))
        XCTAssertEqual(book["abc"]?.media?.title, "Dune : Deuxième partie")
        XCTAssertTrue(book.keysWithoutMedia.isEmpty)
    }

    func testBoardGroupsBySeriesAndShowsUnmatched() {
        var book = DownloadLinkBook()
        let bear = media(.tv, 136315, "The Bear")
        book.record(hash: "s1", media: bear, mediaKey: nil, season: 1, episode: nil, source: .tracker)
        book.record(hash: "s2", media: bear, mediaKey: nil, season: 2, episode: nil, source: .tracker)
        book.record(hash: "m", media: media(.movie, 10378, "Big Buck Bunny"), mediaKey: nil, season: nil, episode: nil, source: .manual)
        let ts = [
            torrent("s1", "The.Bear.S01", progress: 1, state: "uploading", size: 1000, added: 1),
            torrent("s2", "The.Bear.S02", progress: 0.25, state: "downloading", size: 400, speed: 10, added: 2),
            torrent("m", "Big Buck Bunny", progress: 0.5, state: "stoppedDL", added: 3),
            torrent("x", "Inconnu.Total.2031.1080p", progress: 0.1, state: "error", added: 4),
        ]
        let board = DownloadBoard.build(torrents: ts, book: book)
        XCTAssertEqual(board.count, 3)
        let bearCard = board.first { $0.id == "tv:136315" }!
        // la saison finie ne fausse pas la progression : on suit la saison en cours
        XCTAssertEqual(bearCard.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(bearCard.seasons, [2])
        XCTAssertEqual(bearCard.seasonLabel, "Saison 2")
        XCTAssertEqual(bearCard.phase, .downloading)
        XCTAssertEqual(bearCard.torrents.count, 2)
        XCTAssertEqual(bearCard.currentHashes, ["s2"])

        let bbb = board.first { $0.id == "movie:10378" }!
        XCTAssertEqual(bbb.phase, .paused)
        XCTAssertEqual(bbb.title, "Big Buck Bunny")

        // torrent sans fiche, en erreur : reste une carte (affiche générique), avec le titre deviné
        let unknown = board.first { $0.id == "dl:x" }!
        XCTAssertNil(unknown.mediaKey)
        XCTAssertEqual(unknown.phase, .error)
        XCTAssertEqual(unknown.title, "Inconnu Total")
        XCTAssertEqual(unknown.year, 2031)
        // les plus récents d'abord
        XCTAssertEqual(board.map(\.id), ["dl:x", "movie:10378", "tv:136315"])
    }

    func testBoardSizeWeightedAndDone() {
        var book = DownloadLinkBook()
        let m = media(.tv, 1, "Série")
        book.record(hash: "a", media: m, mediaKey: nil, season: 1, episode: 1, source: .tracker)
        book.record(hash: "b", media: m, mediaKey: nil, season: 1, episode: 2, source: .tracker)
        let ts = [torrent("a", "Serie.S01E01", progress: 1.0, state: "downloading", size: 300),
                  torrent("b", "Serie.S01E02", progress: 0.0, state: "downloading", size: 100)]
        let e = DownloadBoard.build(torrents: ts, book: book)[0]
        XCTAssertEqual(e.progress, 0.75, accuracy: 0.001)
        XCTAssertNil(e.episode)   // deux épisodes : pas de « S01E01 »
        XCTAssertEqual(e.seasonLabel, "Saison 1")

        let done = DownloadBoard.build(torrents: [torrent("a", "Serie.S01E01", progress: 1, state: "stalledUP")], book: book)[0]
        XCTAssertTrue(done.isDone)
        XCTAssertEqual(done.seasonLabel, "S01E01")
    }

    /// Le carnet survit au redémarrage : encodé puis relu à l'identique, et tolérant aux champs absents.
    func testPersistence() throws {
        var book = DownloadLinkBook()
        book.record(hash: "aaa", media: media(.movie, 10378, "Big Buck Bunny", year: 2008), mediaKey: nil, season: nil, episode: nil, source: .manual)
        book.recordManual(hash: "bbb")
        let data = try JSONEncoder().encode(book)
        let back = try JSONDecoder().decode(DownloadLinkBook.self, from: data)
        XCTAssertEqual(back, book)
        XCTAssertEqual(back["aaa"]?.media?.year, 2008)
        // fichier minimal (autre version) : se relit quand même
        let old = Data(#"{"links":{"ccc":{"hash":"ccc","mediaKey":"movie:5"}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DownloadLinkBook.self, from: old)["ccc"]?.mediaKey, "movie:5")
    }

    func testPrune() {
        var book = DownloadLinkBook()
        book.links["old"] = DownloadLink(hash: "old", added: Date(timeIntervalSinceNow: -30 * 86400))
        book.links["new"] = DownloadLink(hash: "new", added: Date())
        book.links["kept"] = DownloadLink(hash: "kept", added: Date(timeIntervalSinceNow: -30 * 86400))
        book.prune(present: ["kept"])
        XCTAssertEqual(Set(book.links.keys), ["new", "kept"])
    }

    func testTrackerAvailability() {
        func item(_ title: String, cat: Int, tmdb: Int? = nil) -> TorznabItem {
            var it = TorznabItem(title: title, guid: title, link: nil, magnet: nil, infoHash: nil, detailsURL: nil, size: 1,
                                 seeders: 5, peers: 5, grabs: 0, categories: [cat], imdbId: nil, tmdbId: tmdb, published: nil, downloadFactor: 1)
            it.tmdbId = tmdb
            return it
        }
        let items = [item("Dune.Part.Two.2024.MULTi.2160p", cat: 2000, tmdb: 693134),
                     item("Dune.Part.Two.2024.MULTi.1080p", cat: 2000, tmdb: 693134),
                     item("Dune.1984.1080p", cat: 2000, tmdb: 841),
                     item("Dune.Prophecy.S01.1080p", cat: 5000)]
        XCTAssertEqual(TrackerAvailability.count(items, kind: .movie, tmdbId: 693134, title: "Dune : Deuxième partie", year: 2024), 2)
        XCTAssertEqual(TrackerAvailability.count(items, kind: .movie, tmdbId: 841, title: "Dune", year: 1984), 1)
        XCTAssertEqual(TrackerAvailability.count(items, kind: .tv, tmdbId: 90228, title: "Dune: Prophecy", year: 2024), 1)
        XCTAssertEqual(TrackerAvailability.count(items, kind: .movie, tmdbId: 1, title: "Autre", year: 2000), 0)
    }
}
