import XCTest
@testable import StrapontinCore

/// Cas réel : la fiche de la série « Lanterns » disait « rien sur l'indexeur » alors qu'il y avait la saison 1.
/// L'indexeur donnait tmdbid et tvdbid pour ces releases, mais pas d'imdbid : la recherche par imdbid renvoyait 0 résultat.
/// Extrait réel de la réponse (clé retirée).
final class LanternsTests: XCTestCase {
    static let caps = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps><server version="1.0" title="Indexeur"/><limits max="100" default="50"/>
    <searching>
      <search available="yes" supportedParams="q,cat,limit,offset,apikey"/>
      <tv-search available="yes" supportedParams="q,season,ep,tvdbid,imdbid,cat,limit,offset,apikey"/>
      <movie-search available="yes" supportedParams="q,imdbid,tmdbid,cat,limit,offset,apikey"/>
    </searching>
    <categories><category id="5000" name="TV"/></categories></caps>
    """

    static let empty = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><title>Indexeur</title></channel></rss>
    """

    static let lanterns = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:torznab="http://torznab.com/schemas/2015/feed">
      <channel><title>Indexeur</title>
    <item>
      <title>Lanterns.S01E03.Mis.au.ban.MULTi.1080p.WEB.EAC3.5.1.H264-BYOR</title>
      <guid isPermaLink="true">https://indexeur.exemple/torrent/lanterns-s01e03-mis-au-ban-multi-1080p-web-eac3-5-1-h264-byor-46095696</guid>
      <link>https://indexeur.exemple/api/torrents/lanterns-s01e03-mis-au-ban-multi-1080p-web-eac3-5-1-h264-byor-46095696/download?apikey=CLE</link>
      <pubDate>Sat, 17 Oct 2026 12:59:49 +0000</pubDate>
      <torznab:attr name="category" value="5000"/>
      <torznab:attr name="size" value="2225886265"/>
      <torznab:attr name="seeders" value="33"/>
      <torznab:attr name="infohash" value="4609569600000000000000000000000000000001"/>
      <torznab:attr name="downloadvolumefactor" value="0"/>
      <torznab:attr name="tmdbid" value="95350"/>
      <torznab:attr name="tvdbid" value="376098"/>
      <torznab:attr name="season" value="1"/>
      <torznab:attr name="episode" value="3"/>
    </item>
    <item>
      <title>Lanterns.S01.MULTi.1080p.WEB.EAC3.5.1.H264-BYOR</title>
      <guid isPermaLink="true">https://indexeur.exemple/torrent/lanterns-s01-multi-1080p-web-eac3-5-1-h264-byor-b53a937b</guid>
      <link>https://indexeur.exemple/api/torrents/lanterns-s01-multi-1080p-web-eac3-5-1-h264-byor-b53a937b/download?apikey=CLE</link>
      <pubDate>Fri, 09 Oct 2026 02:28:08 +0000</pubDate>
      <torznab:attr name="category" value="5000"/>
      <torznab:attr name="size" value="18679130713"/>
      <torznab:attr name="seeders" value="50"/>
      <torznab:attr name="infohash" value="b53a937b00000000000000000000000000000002"/>
      <torznab:attr name="downloadvolumefactor" value="0"/>
      <torznab:attr name="tmdbid" value="95350"/>
      <torznab:attr name="tvdbid" value="376098"/>
      <torznab:attr name="season" value="1"/>
    </item>
    </channel></rss>
    """

    var lanternsMedia: Media {
        var m = Media(tmdbId: 95350, kind: .tv, title: "Lanterns")
        m.imdbId = "tt26545992"
        return m
    }

    override func setUp() { StubTorznab.queries = [] }

    /// Fiche déjà en bibliothèque (pas de tvdbid enregistré) : l'imdbid ne donne rien, le titre si.
    func testFallsBackToTitleWhenImdbIdFindsNothing() async throws {
        let c = TorznabClient(endpoint: "https://stub.test/api/torznab", apiKey: "x", protocolClasses: [StubTorznab.self])
        let items = try await c.searchTV(title: "Lanterns", season: 1, episode: nil, imdbId: "tt26545992")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(StubTorznab.queries.contains { $0["imdbid"] == "tt26545992" })
        XCTAssertTrue(StubTorznab.queries.contains { $0["q"] == "Lanterns" && $0["season"] == "1" })
        // et les deux sont bien gardés pour la fiche : bonne œuvre (tmdbid), saison 1, un pack et un épisode
        let f = Follow(media: lanternsMedia)
        XCTAssertTrue(items.allSatisfy { AutoGrab.matches($0, f) })
        XCTAssertEqual(items.map { ReleaseInfo.parse($0.releaseName).season }, [1, 1])
        XCTAssertTrue(ReleaseInfo.parse(items[1].releaseName).isSeasonPack)
        // même titre, autre œuvre : l'année du nom écarte la série de 1980 pour la fiche de 2024
        var shogun = Media(tmdbId: 126308, kind: .tv, title: "Shōgun")
        shogun.originalTitle = "Shōgun"
        shogun.year = 2024
        let old = TorznabItem(title: "Shogun.1980.S01.MULTi.1080p.BluRay.x264-OLD", guid: "a", size: 1, categories: [5000])
        let new = TorznabItem(title: "Shogun.2024.S01.MULTi.1080p.WEB.H264-FW", guid: "b", size: 1, categories: [5000])
        XCTAssertFalse(AutoGrab.matches(old, Follow(media: shogun)))
        XCTAssertTrue(AutoGrab.matches(new, Follow(media: shogun)))
        // pas de faux positif : une autre série ne les récupère pas
        XCTAssertFalse(items.contains { AutoGrab.matches($0, Follow(media: Media(tmdbId: 136315, kind: .tv, title: "The Bear"))) })
    }

    /// Avec le tvdbid : les trois recherches (tvdbid, imdbid, titre) sont faites et réunies sans doublon.
    func testAllSourcesMergedWithoutDuplicates() async throws {
        let c = TorznabClient(endpoint: "https://stub.test/api/torznab", apiKey: "x", protocolClasses: [StubTorznab.self])
        let items = try await c.searchTV(title: "Lanterns", season: 1, episode: nil, imdbId: "tt26545992", tvdbId: 376098)
        XCTAssertEqual(items.count, 2)   // les mêmes 2 releases via tvdbid et via le titre : pas en double
        let searches = StubTorznab.queries.filter { $0["t"] == "tvsearch" }
        XCTAssertEqual(searches.map { $0["tvdbid"] ?? $0["imdbid"] ?? $0["q"] ?? "" }, ["376098", "tt26545992", "Lanterns"])
    }
}

/// Simule l'indexeur : rien par imdbid (comme en vrai pour Lanterns), la saison 1 par tvdbid ou par titre.
final class StubTorznab: URLProtocol {
    nonisolated(unsafe) static var queries: [[String: String]] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        Self.queries.append(q)
        let body: String
        if q["t"] == "caps" { body = LanternsTests.caps }
        else if q["tvdbid"] == "376098" || q["q"] == "Lanterns" { body = LanternsTests.lanterns }
        else { body = LanternsTests.empty }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
