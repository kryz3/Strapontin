import XCTest
@testable import StrapontinCore

/// Réponses réduites, sur le modèle de vraies réponses Torznab (adresses et clés remplacées).
final class TorznabTests: XCTestCase {
    let caps = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps><server version="1.0" title="Indexeur"/><limits max="100" default="50"/>
    <searching>
      <search available="yes" supportedParams="q,cat,limit,offset,apikey"/>
      <tv-search available="yes" supportedParams="q,season,ep,tvdbid,imdbid,cat,limit,offset,apikey"/>
      <movie-search available="yes" supportedParams="q,imdbid,tmdbid,cat,limit,offset,apikey"/>
    </searching>
    <categories>
      <category id="2000" name="Movies"><subcat id="2040" name="Movies/HD"/></category>
      <category id="5000" name="TV"><subcat id="5040" name="TV/HD"/><subcat id="5070" name="TV/Anime"/></category>
    </categories></caps>
    """

    let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><title>Indexeur</title>
    <item>
      <title>The Bear S01 MULTi 1080p WEB H264-FW (The Bear : Sur place ou à emporter)</title>
      <guid isPermaLink="true">https://indexeur.exemple/torrent/the-bear-s01</guid>
      <link>https://indexeur.exemple/api/torrents/the-bear-s01/download?apikey=X</link>
      <pubDate>Fri, 15 May 2026 00:03:39 +0000</pubDate>
      <enclosure url="https://indexeur.exemple/api/torrents/the-bear-s01/download?apikey=X" length="11172781629" type="application/x-bittorrent"/>
      <torznab:attr name="category" value="5000"/><torznab:attr name="seeders" value="34"/>
      <torznab:attr name="leechers" value="0"/><torznab:attr name="infohash" value="47714b98"/>
      <torznab:attr name="downloadvolumefactor" value="0"/><torznab:attr name="season" value="1"/>
    </item>
    <item>
      <title>Dune.Part.Two.2024.MULTI.VF2.1080p.WEBRip.AV1.Opus-H4KIG</title>
      <guid>https://indexeur.exemple/torrent/dune-part-two</guid>
      <link>https://indexeur.exemple/api/torrents/dune-part-two/download?apikey=X</link>
      <enclosure url="https://indexeur.exemple/api/torrents/dune-part-two/download?apikey=X" length="3598813640" type="application/x-bittorrent"/>
      <torznab:attr name="category" value="2000"/><torznab:attr name="seeders" value="19"/>
      <torznab:attr name="infohash" value="4add0db3"/><torznab:attr name="downloadvolumefactor" value="0"/>
      <torznab:attr name="imdb" value="tt15239678"/><torznab:attr name="imdbid" value="15239678"/><torznab:attr name="tmdbid" value="693134"/>
    </item>
    <item>
      <title>Jodorowskys Dune 2013 DOC VOSTFR 1080p WEB H265-FW (Jodorowsky's Dune)</title>
      <guid>https://indexeur.exemple/torrent/jodo</guid><link>https://indexeur.exemple/api/torrents/jodo/download?apikey=X</link>
      <torznab:attr name="size" value="1221579631"/><torznab:attr name="seeders" value="6"/>
    </item>
    </channel></rss>
    """

    func testCaps() throws {
        let c = try TorznabParser.caps(Data(caps.utf8))
        XCTAssertTrue(c.supports("movie-search", "tmdbid"))
        XCTAssertFalse(c.supports("tv-search", "tmdbid"))
        XCTAssertEqual(c.categories.map(\.id), [2000, 5000])
        XCTAssertEqual(c.categories[1].subcategories.map(\.id), [5040, 5070])
    }

    func testItems() throws {
        let items = try TorznabParser.items(Data(feed.utf8))
        XCTAssertEqual(items.count, 3)
        let bear = items[0]
        XCTAssertEqual(bear.releaseName, "The Bear S01 MULTi 1080p WEB H264-FW")
        XCTAssertEqual(bear.siteTitle, "The Bear : Sur place ou à emporter")
        XCTAssertEqual(bear.size, 11172781629)
        XCTAssertEqual(bear.seeders, 34)
        XCTAssertEqual(bear.season, 1)
        XCTAssertTrue(bear.isFreeleech)
        XCTAssertNotNil(bear.published)
        XCTAssertEqual(items[1].imdbId, "tt15239678")
        XCTAssertEqual(items[1].tmdbId, 693134)
        XCTAssertEqual(items[2].size, 1221579631)
    }

    func testHTMLIsNotTorznab() {
        XCTAssertThrowsError(try TorznabParser.items(Data("<!DOCTYPE html><html><title>Page introuvable</title></html>".utf8)))
    }

    func testReleaseInfo() {
        let pack = ReleaseInfo.parse("The Bear S01 MULTi 1080p WEB H264-FW")
        XCTAssertTrue(pack.isSeasonPack)
        XCTAssertEqual(pack.season, 1)
        XCTAssertEqual(pack.title, "The Bear")
        XCTAssertEqual(pack.language, .multi)
        XCTAssertEqual(pack.resolution, 1080)

        let ep = ReleaseInfo.parse("The.Bear.S03E02.VOSTFR.2160p.WEB.H265-XXX")
        XCTAssertFalse(ep.isSeasonPack)
        XCTAssertEqual(ep.episode, 2)
        XCTAssertEqual(ep.language, .vostfr)
        XCTAssertEqual(ep.resolution, 2160)

        let movie = ReleaseInfo.parse("Dune.Deuxieme.Partie.2024.MULTI.VFF.2160P.WEB-DL.DV.EAC3.HEVC-Psaro")
        XCTAssertNil(movie.season)
        XCTAssertEqual(movie.year, 2024)
        XCTAssertEqual(movie.resolution, 2160)

        // noms de releases réels, vus dans un flux Torznab
        XCTAssertEqual(ReleaseInfo.parse("Elles.deux.2024.VOF.1080p.HDTV.AAC.2.0.H264").language, .french)
        XCTAssertEqual(ReleaseInfo.parse("Trump.contre.la.loi.2025.MULTiVOF.1080p.WEB.H265").language, .multi)
        XCTAssertEqual(ReleaseInfo.parse("Franz.2025.VOSFR.1080p.EAC3.5.1.x264").language, .vostfr)
        XCTAssertEqual(ReleaseInfo.parse("Underworld.2003.MULTi.VF2.SD.BDRip.AAC.2.0.x264-Xavy").resolution, 480)
    }

    func testMatchesTVByTmdbId() {
        var bear = Media(tmdbId: 136315, kind: .tv, title: "The Bear : Sur place ou à emporter")
        bear.originalTitle = "The Bear"
        let f = Follow(media: bear)
        var it = TorznabItem(title: "Ours.S01E01.MULTi.1080p.WEB-GRP", guid: "x", size: 1, categories: [5000])
        it.tmdbId = 136315
        XCTAssertTrue(AutoGrab.matches(it, f))          // titre exotique, mais bon tmdbid de série
        it.categories = [2000]
        XCTAssertFalse(AutoGrab.matches(it, f))         // même numéro, mais c'est un film
    }

    func testAutoGrabPicksFollowedOnly() throws {
        let items = try TorznabParser.items(Data(feed.utf8))
        var dune = Media(tmdbId: 693134, kind: .movie, title: "Dune : Deuxième partie")
        dune.year = 2024
        var bear = Media(tmdbId: 136315, kind: .tv, title: "The Bear : Sur place ou à emporter")
        bear.originalTitle = "The Bear"
        let follows = [Follow(media: dune), Follow(media: bear)]

        let d = AutoGrab.decide(items: items, follows: follows, owned: [:], ownedMovies: [], history: [], prefs: GrabPreferences())
        XCTAssertEqual(Set(d.map(\.item.guid)), ["https://indexeur.exemple/torrent/dune-part-two", "https://indexeur.exemple/torrent/the-bear-s01"])

        // déjà un épisode de la saison 1 sur le disque : pas de pack S01
        let d2 = AutoGrab.decide(items: items, follows: follows, owned: [bear.key: [EpisodeKey(1, 3)]],
                                 ownedMovies: [dune.key], history: [], prefs: GrabPreferences())
        XCTAssertTrue(d2.isEmpty)
    }

    /// Indexeur générique : adresse complète de l'API (espaces et « / » final retirés), catégories réglables.
    func testGenericIndexerSettings() async {
        let c = TorznabClient(endpoint: "  https://indexeur.exemple/api/  ", apiKey: " k ", movieCategories: [2040], tvCategories: [])
        let e = await c.endpoint
        XCTAssertEqual(e, "https://indexeur.exemple/api")
        XCTAssertEqual(c.movieCategories, [2040])
        XCTAssertEqual(c.tvCategories, TorznabClient.defaultTVCategories)
    }
}
