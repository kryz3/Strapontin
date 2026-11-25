import XCTest
@testable import StrapontinCore

/// Playlists M3U, recherche des chaînes, guide XMLTV, surveillance du direct.
final class IPTVTests: XCTestCase {
    let playlist = """
    #EXTM3U url-tvg="https://guide.exemple/epg.xml"
    #EXTINF:-1 tvg-id="arte.fr" tvg-name="ARTE" tvg-logo="https://logo.exemple/arte.png" group-title="Généralistes" tvg-chno="7",ARTE HD
    https://live.exemple/arte.m3u8
    #EXTINF:-1 tvg-id="france5.fr" group-title="Généralistes, info",France 5
    https://live.exemple/f5.m3u8
    #EXTVLCOPT:http-user-agent=Truc
    #EXTINF:-1 tvg-id="arte.fr" group-title="Généralistes",ARTE (secours)
    https://backup.exemple/arte.m3u8
    #EXTINF:-1 tvg-name="Dune (2021)" group-title="VOD | Films",Dune (2021)
    https://srv.exemple/movie/u/p/123.mkv
    #EXTINF:-1 group-title="Séries TV",The Bear S01 E02
    https://srv.exemple/series/u/p/456.mp4
    #EXTINF:0,Sans attributs
    http://radio.exemple/stream
    """

    func testParsesAttributesKindsAndNumbers() {
        let r = M3UParser.parse(playlist, playlist: "p1")
        XCTAssertEqual(r.guideURL, "https://guide.exemple/epg.xml")
        XCTAssertEqual(r.entries.count, 6)
        let arte = r.entries[0]
        XCTAssertEqual(arte.name, "ARTE HD")
        XCTAssertEqual(arte.logo, "https://logo.exemple/arte.png")
        XCTAssertEqual(arte.number, 7)
        XCTAssertEqual(arte.kind, .live)
        XCTAssertEqual(r.entries[1].group, "Généralistes, info")          // virgule dans les guillemets
        XCTAssertNotEqual(r.entries[0].id, r.entries[2].id)                // même tvg-id : deux entrées distinctes
        XCTAssertEqual(r.entries[3].kind, .movie)
        XCTAssertEqual(r.entries[4].kind, .series)
        XCTAssertEqual(r.entries[5].group, "Autres")
    }

    func testBigPlaylistParsesQuickly() {
        var text = "#EXTM3U\n"
        for i in 0..<30_000 { text += "#EXTINF:-1 tvg-id=\"c\(i)\" group-title=\"G\(i % 40)\",Chaîne \(i)\nhttp://x/\(i).ts\n" }
        let t0 = Date()
        let r = M3UParser.parse(text)
        XCTAssertEqual(r.entries.count, 30_000)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        let index = IPTVSearchIndex(r.entries)
        let t1 = Date()
        _ = index.search("chaine 2999")
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.5)
    }

    func testSearchToleratesAccentsPrefixesTyposAndNumbers() {
        let index = IPTVSearchIndex(M3UParser.parse(playlist).entries)
        XCTAssertEqual(index.search("arte").first?.name, "ARTE HD")
        XCTAssertEqual(index.search("FRANCE").first?.name, "France 5")
        XCTAssertEqual(index.search("fra").first?.name, "France 5")          // préfixe
        XCTAssertEqual(index.search("frnace 5").first?.name, "France 5")     // une faute
        XCTAssertEqual(index.search("7").first?.name, "ARTE HD")             // numéro de chaîne
        XCTAssertEqual(index.search("generalistes").count, 3)                // nom du groupe, sans accent
        XCTAssertEqual(index.search("dune", kinds: [.movie]).first?.kind, .movie)
    }

    func testXMLTVNowAndNext() {
        let xml = """
        <tv><programme start="20261125200000 +0000" stop="20261125210000 +0000" channel="ARTE.fr"><title>Avant</title></programme>
        <programme start="20261125210000 +0000" stop="20261125223000 +0000" channel="arte.fr"><title>Film du soir</title><desc>Un film.</desc></programme>
        <programme start="20261125223000 +0000" stop="20261125233000 +0000" channel="arte.fr"><title>Documentaire</title></programme></tv>
        """
        let at = ProgramGuide.date("20261125213000 +0000")!
        let g = ProgramGuide.parse(Data(xml.utf8), keepFrom: at.addingTimeInterval(-86400), until: at.addingTimeInterval(86400))
        let nn = g.nowNext("ARTE.fr", at: at)
        XCTAssertEqual(nn.now?.title, "Film du soir")
        XCTAssertEqual(nn.now?.detail, "Un film.")
        XCTAssertEqual(nn.next?.title, "Documentaire")
    }

    // MARK: surveillance du direct

    func run(_ w: inout LiveWatchdog, from: Double, to: Double, position: (Double) -> Double?,
             cache: Double = 0, failed: Bool = false) -> [(Double, LiveWatchdog.Action)] {
        var out: [(Double, LiveWatchdog.Action)] = []
        var t = from
        while t <= to {
            if let a = w.observe(.init(time: t, position: position(t), cacheSeconds: cache, failed: failed)) { out.append((t, a)) }
            t += 0.5
        }
        return out
    }

    func testHealthyStreamIsLeftAlone() {
        var w = LiveWatchdog()
        XCTAssertTrue(run(&w, from: 0, to: 60, position: { $0 }).isEmpty)
    }

    func testFreezeTriggersGradedRecoveryWithBackoff() {
        var w = LiveWatchdog()
        w.hasAlternate = true
        _ = run(&w, from: 0, to: 10, position: { $0 })
        // figé à 10 s, avec des données en réserve
        let actions = run(&w, from: 10.5, to: 40, position: { _ in 10 }, cache: 3)
        XCTAssertEqual(actions.map(\.1).prefix(4), [.seekToLive, .alternateSource, .reload, .alternateSource])
        XCTAssertEqual(actions.first!.0, 15.5, accuracy: 0.6)                // après 5 s sans progression
        XCTAssertGreaterThanOrEqual(actions[2].0 - actions[1].0, 2)          // les essais s'espacent
        XCTAssertTrue(w.isRecovering)
    }

    func testRecoveryIsMeasuredAndLadderResets() {
        var w = LiveWatchdog()
        _ = run(&w, from: 0, to: 10, position: { $0 })
        _ = run(&w, from: 10.5, to: 18, position: { _ in 10 })
        XCTAssertTrue(w.isRecovering)
        _ = run(&w, from: 18.5, to: 25, position: { $0 })                    // ça repart
        XCTAssertFalse(w.isRecovering)
        XCTAssertNotNil(w.lastRecovery)
    }

    func testErrorsSkipSeekAndGiveUpEventually() {
        var w = LiveWatchdog()
        w.maxAttempts = 4
        w.backoff = [0, 1, 1, 1]
        let actions = run(&w, from: 0, to: 30, position: { _ in nil }, failed: true)
        XCTAssertEqual(actions.first?.1, .reload)                            // erreur HTTP : rouvrir, pas se recaler
        XCTAssertEqual(actions.filter { $0.1 != .giveUp }.count, 4)
        XCTAssertEqual(actions.last?.1, .giveUp)
    }

    func testEndOfStreamWhilePausedIsRepaired() {
        // le lecteur se met en pause tout seul au bout du flux (erreur 503 sur la liste) : ce n'est pas une pause voulue
        var w = LiveWatchdog()
        _ = run(&w, from: 0, to: 10, position: { $0 })
        XCTAssertEqual(w.observe(.init(time: 10.5, position: 10, userPaused: false, ended: true)), .reload)
        w.opened(at: 10.5)
        var t = 11.0, next: LiveWatchdog.Action?
        while t < 30, next == nil { next = w.observe(.init(time: t, position: nil, failed: true)); t += 0.5 }
        XCTAssertEqual(next, .reload)
        XCTAssertLessThan(t, 13)                                              // pas d'attente de démarrage après une erreur
    }

    func testUserPauseIsNotAFreeze() {
        var w = LiveWatchdog()
        _ = run(&w, from: 0, to: 10, position: { $0 })
        var t = 10.5
        while t < 60 { XCTAssertNil(w.observe(.init(time: t, position: 10, userPaused: true))); t += 0.5 }
    }

    func testLiveOptionsCarryReconnectAndHeaders() {
        let o = Dictionary(LiveOptions.mpv(userAgent: "UA", referer: "https://r.exemple/").map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(o["stream-lavf-o"]!.contains("reconnect_streamed=1"))
        XCTAssertEqual(o["user-agent"], "UA")
        XCTAssertEqual(o["referrer"], "https://r.exemple/")
    }
}

/// Catalogue à la demande : comptes Xtream, réponses de l'API, titres bruités.
final class XtreamTests: XCTestCase {
    func testAccountFromPlaylistURL() {
        let a = XtreamAccount.from(playlistURL: "http://srv.exemple:8080/get.php?username=u1&password=p1&type=m3u_plus&output=ts")
        XCTAssertEqual(a, XtreamAccount(base: "http://srv.exemple:8080", username: "u1", password: "p1"))
        XCTAssertNil(XtreamAccount.from(playlistURL: "https://exemple/liste.m3u"))
        XCTAssertEqual(a?.movieURL(12, ext: "mkv"), "http://srv.exemple:8080/movie/u1/p1/12.mkv")
    }

    func testParsesMoviesSeriesAndEpisodes() {
        let account = XtreamAccount(base: "http://s", username: "u", password: "p")
        let cats = XtreamParser.categories(Data(#"[{"category_id":"3","category_name":"Films FR"}]"#.utf8))
        let movies = XtreamParser.movies(Data(#"[{"stream_id":12,"name":"FR | Dune (2021) [MULTI]","stream_icon":"http://i/d.jpg","category_id":"3","container_extension":"mkv","rating":"7.8","tmdb":"438631"}]"#.utf8),
                                         account: account, categories: cats)
        XCTAssertEqual(movies.first?.category, "Films FR")
        XCTAssertEqual(movies.first?.tmdbId, 438631)
        XCTAssertEqual(movies.first?.url, "http://s/movie/u/p/12.mkv")
        XCTAssertEqual(movies.first?.year, 2021)
        let eps = XtreamParser.episodes(Data(#"{"episodes":{"2":[{"id":"900","episode_num":3,"title":"Trois","container_extension":"mp4","info":{"plot":"…"}}],"1":[{"id":"800","episode_num":1,"title":"Un"}]}}"#.utf8),
                                        account: account)
        XCTAssertEqual(eps.map(\.title), ["Un", "Trois"])
        XCTAssertEqual(eps.last?.url, "http://s/series/u/p/900.mp4")
    }

    func testCleansNoisyTitles() {
        XCTAssertEqual(VODTitle.clean("FR | Dune (2021) [MULTI] 4K"), "Dune")
        XCTAssertEqual(VODTitle.clean("|VF| Le Comte de Monte-Cristo - 2024"), "Le Comte de Monte-Cristo")
        XCTAssertEqual(VODTitle.year("Oppenheimer (2023) HD"), 2023)
    }
}

final class IPTVCountryTests: XCTestCase {
    func d(_ group: String, _ name: String = "Chaîne", tvg: String? = nil, id: String? = nil) -> String? {
        IPTVCountry.detect(tvgCountry: tvg, group: group, name: name, tvgId: id)
    }

    func testProviderPrefixes() {
        XCTAssertEqual(d("FR | Sport"), "FR")
        XCTAssertEqual(d("|FR| Cinéma"), "FR")
        XCTAssertEqual(d("FR: Généraliste"), "FR")
        XCTAssertEqual(d("[FR] Info"), "FR")
        XCTAssertEqual(d("FR - Jeunesse"), "FR")
        XCTAssertEqual(d("FRANCE FHD"), "FR")
        XCTAssertEqual(d("VIP | FRANCE SPORT"), "FR")
        XCTAssertEqual(d("UK | Entertainment"), "GB")
        XCTAssertEqual(d("USA Network"), "US")
        XCTAssertEqual(d("DE: Sport"), "DE")
        XCTAssertEqual(d("Italia"), "IT")
        XCTAssertEqual(d("Belgique"), "BE")
        XCTAssertEqual(d("🇵🇹 Desporto"), "PT")
        XCTAssertEqual(d("VOD FRANCE Action"), "FR")
        XCTAssertEqual(d("VOD UK | Action"), "GB")
        XCTAssertEqual(d("VOD DE: Drame"), "DE")
        XCTAssertEqual(d("VIP |FR| Sport"), "FR")
    }

    func testRegions() {
        XCTAssertEqual(d("AR | MBC"), "ARAB")
        XCTAssertEqual(d("EX-YU | Sport"), "EXYU")
        XCTAssertEqual(d("LATINO | Deportes"), "LATAM")
        XCTAssertEqual(IPTVCountry.label("ARAB"), "Arabe")
        XCTAssertEqual(IPTVCountry.flag("FR"), "🇫🇷")
        XCTAssertEqual(IPTVCountry.label("FR"), "France")
    }

    func testNameTvgCountryAndTvgId() {
        XCTAssertEqual(d("Sport", "FR: beIN Sports 1"), "FR")
        XCTAssertEqual(d("Sport", "Sky", tvg: "gb"), "GB")
        XCTAssertEqual(d("Généraliste", "TF1", id: "TF1.fr"), "FR")
        XCTAssertEqual(d("Généraliste", "France 2"), "FR")
    }

    func testNoFalseCountries() {
        XCTAssertNil(d("Sport"))
        XCTAssertNil(d("Sport | TV"))
        XCTAssertNil(d("VOD | Films"))
        XCTAssertNil(d("Démos publiques", "Apple BipBop", id: "bipbop"))
        XCTAssertNil(d("Divers", "BE IN SPORT 1"))
        XCTAssertNil(d("Divers", "TF1 HD"))
        XCTAssertNil(d("Divers", "Canal+ Sport"))
        XCTAssertNil(d("Divers", "M6", id: "m6.tv"))
    }

    func testThemedLiveGroupsStayLive() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 group-title="FR | Cinéma",Canal+ Cinéma
        http://x/live/u/p/1.ts
        #EXTINF:-1 group-title="UK | Séries",Sky Showcase
        http://x/u/p/2
        #EXTINF:-1 group-title="FR | Films",Ciné+ Frisson
        http://x/hls/3.m3u8
        #EXTINF:-1 group-title="VOD | FR | Action",Film (2020)
        http://x/u/p/4
        """
        XCTAssertEqual(M3UParser.parse(m3u, playlist: "p").entries.map(\.kind), [.live, .live, .live, .movie])
    }

    func testParserFillsCountry() {
        let m3u = "#EXTM3U\n#EXTINF:-1 tvg-id=\"tf1.fr\" group-title=\"FR | Généraliste\",TF1\nhttp://x/1.ts\n"
        XCTAssertEqual(M3UParser.parse(m3u, playlist: "p").entries.first?.country, "FR")
    }
}
