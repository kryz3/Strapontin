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

    func testGroupTitles() {
        for g in ["FR | Cinéma", "|FR| Cinéma", "FRANCE Cinéma", "FR: Cinéma", "VIP FRANCE | Cinéma"] {
            XCTAssertEqual(IPTVCountry.groupTitle(g), "Cinéma", g)
        }
        XCTAssertEqual(IPTVCountry.groupTitle("Sport"), "Sport")
        XCTAssertEqual(IPTVCountry.groupTitle("France 2 Régions"), "France 2 Régions")
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

final class ChannelNameTests: XCTestCase {
    func p(_ s: String) -> ChannelName.Parsed { ChannelName.parse(s) }

    func testCanalPlusSpellingsShareOneKey() {
        let raws = ["FR| CANAL+ SPORT HD", "Canal Plus Sport FHD", "CANAL+SPORT", "FR: C+ Sport", "|FR| Canal + Sport ᴴᴰ",
                    "[FR] CANAL+ SPORT (backup)", "FR - Canal+ Sport 4K", "canal+ sport"]
        for r in raws { XCTAssertEqual(p(r).key, "canal plus sport", r) }
        XCTAssertEqual(p("FR| CANAL+ SPORT HD").display, "Canal+ Sport")
        XCTAssertEqual(ChannelName.searchKey("canal + sport"), "canal plus sport")
        XCTAssertEqual(ChannelName.searchKey("canal plus"), "canal plus")
    }

    func testRelatedChannelsStayApart() {
        let keys = Set(["Canal+", "Canal+ Sport", "Canal+ Sport 360", "beIN Sports 1", "beIN Sports 2", "France 3",
                        "France 3 Alpes"].map { p($0).key })
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(p("CANAL+SPORT 360").display, "Canal+ Sport 360")
    }

    func testQualityAndBackup() {
        XCTAssertEqual(p("FR| TF1 FHD").quality, .fhd)
        XCTAssertEqual(p("TF1ᴴᴰ").quality, .hd)
        XCTAssertEqual(p("TF1ᴴᴰ").key, "tf1")
        XCTAssertEqual(p("M6HD").key, "m6")
        XCTAssertEqual(p("UK: Sky Sports F1 UHD").quality, .uhd)
        XCTAssertEqual(p("TF1 4K HEVC").quality, .uhd)
        XCTAssertTrue(p("FR: TF1 (backup)").backup)
        XCTAssertEqual(p("FR: TF1 (backup)").key, "tf1")
        XCTAssertEqual(p("FR| TF1 SD").quality, .sd)
        XCTAssertEqual(p("TF1").quality, .unknown)
    }

    func testNumbersAndAliases() {
        XCTAssertEqual(p("beIN Sports One").key, "bein sports 1")
        XCTAssertEqual(p("BEIN SPORT 1 HD").key, "bein sports 1")
        XCTAssertEqual(p("BEIN SPORT 1 HD").display, "beIN Sports 1")
        XCTAssertEqual(p("TF 1").key, "tf1")
        XCTAssertEqual(p("France 2").key, "france 2")
        XCTAssertEqual(p("FRANCE 2 FHD").display, "France 2")
        XCTAssertEqual(p("France Info").key, "franceinfo")
        XCTAssertEqual(p("Rocky II").key, "rocky 2")
        XCTAssertEqual(p("BFMTV").display, "BFM TV")
        XCTAssertEqual(p("L'ÉQUIPE HD").display, "L'Équipe")
        XCTAssertEqual(p("Arts & Culture").key, "arts et culture")
    }

    func testCountryPrefixIsStrippedButNotFrance2() {
        XCTAssertEqual(p("FR| TF1").country, "FR")
        XCTAssertEqual(p("VIP | UK | BBC ONE HD").display, "BBC One")
        XCTAssertEqual(p("VIP | UK | BBC ONE HD").country, "GB")
        XCTAssertEqual(p("France 2").display, "France 2")
        XCTAssertNil(p("France 2").country)
        XCTAssertEqual(p("⭐ FR ⭐ | M6").key, "m6")
        XCTAssertEqual(p("Canal+ Sport-Live").key, "canal plus sport live")
    }

    func testDecorativeUnicodeAndCase() {
        XCTAssertEqual(p("🔴 FR: CNEWS ᶠᴴᴰ").display, "CNews")
        XCTAssertEqual(p("🔴 FR: CNEWS ᶠᴴᴰ").quality, .fhd)
        XCTAssertEqual(p("ＴＦ１").key, "tf1")
        XCTAssertEqual(p("FR| MON CHANNEL SPORT").display, "Mon Channel Sport")
        XCTAssertEqual(p("Chaîne de test (seule)").display, "Chaîne de test (seule)")
        XCTAssertEqual(p("Chaîne de test (seule)").key, "chaine de test seule")
        XCTAssertEqual(p("FR: TF1 [FHD]").display, "TF1")
        XCTAssertEqual(p("FR: TF1 [FHD]").quality, .fhd)
        XCTAssertEqual(p("France 24 Live").display, "France 24 Live")
    }
}

final class ChannelGroupingTests: XCTestCase {
    func e(_ id: String, _ name: String, group: String = "FR | Sport") -> IPTVEntry {
        IPTVEntry(id: id, name: name, url: "http://x/\(id).ts", tvgId: nil, logo: nil, group: group, number: nil, kind: .live,
                  playlist: "p", country: IPTVCountry.detect(group: group, name: name))
    }

    func testVariantsAreGroupedBestFirst() {
        let r = ChannelGrouping.group([
            e("1", "FR| CANAL+ SPORT HD"), e("2", "FR| CANAL+ SPORT 4K"), e("3", "FR| CANAL+ SPORT (backup)"),
            e("4", "FR| CANAL+ SPORT SD"), e("5", "FR| CANAL+ SPORT 360 FHD"), e("6", "FR| CANAL+"),
            e("7", "UK| Sky Sports F1 HD", group: "UK | Sport"), e("8", "UK: Sky Sports F1 FHD", group: "UK | Sport"),
        ])
        XCTAssertEqual(r.channels.map(\.name), ["Canal+ Sport", "Canal+ Sport 360", "Canal+", "Sky Sports F1"])
        let v = r.variants[r.channels[0].id]!
        XCTAssertEqual(v.map(\.id), ["2", "1", "4", "3"])
        XCTAssertEqual(v.map(\.label), ["4K", "HD", "SD", "Secours"])
        XCTAssertEqual(r.channels[0].url, "http://x/2.ts")
        XCTAssertEqual(r.groupOf["3"], r.channels[0].id)
        XCTAssertEqual(r.variants[r.channels[3].id]?.count, 2)
    }

    func testSameNameDifferentCountriesStayApart() {
        let r = ChannelGrouping.group([e("1", "FR| Eurosport 1"), e("2", "DE: Eurosport 1", group: "DE | Sport")])
        XCTAssertEqual(r.channels.count, 2)
    }
}

final class ChannelSearchTests: XCTestCase {
    func testNormalizedSearchRanksExactThenPrefix() {
        let raws = ["FR| CANAL+ SPORT 360", "FR| CANAL+ SPORT", "FR| CANAL+", "FR| C8", "FR| Canal Plus Cinéma"]
        let g = ChannelGrouping.group(raws.enumerated().map {
            IPTVEntry(id: "\($0.offset)", name: $0.element, url: "u", tvgId: nil, logo: nil, group: "FR | TV", number: nil,
                      kind: .live, playlist: "p", country: "FR")
        })
        let idx = IPTVSearchIndex(g.channels, channelNames: true)
        XCTAssertEqual(idx.search("canal + sport").map(\.name).prefix(2), ["Canal+ Sport", "Canal+ Sport 360"])
        XCTAssertEqual(idx.search("canal plus").first?.name, "Canal+")
        XCTAssertEqual(idx.search("c+ sport").first?.name, "Canal+ Sport")
        XCTAssertEqual(idx.search("canalplus cinema").first?.name, "Canal+ Cinéma")
    }

    func testFavoritesAndCountryRiseWithinATie() {
        let list = [("a", "Eurosport 1", "DE"), ("b", "Eurosport 1", "FR")].map {
            IPTVEntry(id: $0.0, name: $0.1, url: "u", tvgId: nil, logo: nil, group: "Sport", number: nil, kind: .live,
                      playlist: "p", country: $0.2)
        }
        let idx = IPTVSearchIndex(list, channelNames: true)
        XCTAssertEqual(idx.search("eurosport", country: "FR").first?.id, "b")
        XCTAssertEqual(idx.search("eurosport", favorites: ["a"]).first?.id, "a")
    }
}

final class VODMatchTests: XCTestCase {
    func r(_ id: Int, _ title: String, _ year: Int?) -> TMDbSearchResult {
        TMDbSearchResult(id: id, kind: .movie, title: title, year: year, overview: "", posterPath: nil)
    }

    func testSameFilmUnderProviderSpellingsHasOneKey() {
        let k = Set(["FR | Dune (2021) [MULTI]", "|FR| DUNE 4K (2021)", "VF - Dune - 2021", "Dune (2021) FHD"].map {
            VODMatch.key(kind: .movie, title: $0, year: VODTitle.year($0))
        })
        XCTAssertEqual(k.count, 1)
        XCTAssertNotEqual(VODMatch.key(kind: .movie, title: "Dune", year: 1984), VODMatch.key(kind: .movie, title: "Dune", year: 2021))
    }

    func testPicksTheRightYearAndTitle() {
        let res = [r(1, "Dune", 1984), r(2, "Dune", 2021), r(3, "Dune : Deuxième partie", 2024)]
        XCTAssertEqual(VODMatch.best(res, title: "FR | Dune (2021)", year: 2021)?.id, 2)
        XCTAssertEqual(VODMatch.best(res, title: "Dune", year: 1984)?.id, 1)
        XCTAssertEqual(VODMatch.best([r(9, "Rocky II", 1979)], title: "Rocky 2", year: 1979)?.id, 9)
        XCTAssertEqual(VODMatch.best([r(4, "Le Parrain", 1972)], title: "Le Parrain", year: nil)?.id, 4)
        XCTAssertEqual(VODMatch.best([r(5, "Fast & Furious", 2009)], title: "Fast and Furious", year: 2009)?.id, nil)
        XCTAssertEqual(VODMatch.best([r(5, "Fast & Furious", 2009)], title: "Fast et Furious", year: 2009)?.id, 5)
    }

    func testRefusesWhenUnsure() {
        XCTAssertNil(VODMatch.best([r(1, "Dune", 1984)], title: "Dune", year: 2021))           // mauvaise année
        XCTAssertNil(VODMatch.best([r(1, "Avatar", 2009)], title: "Avatar Legends", year: nil))   // titre seulement voisin
        XCTAssertNil(VODMatch.best([r(1, "Mon voisin Totoro", 1988)], title: "Totoro", year: 1988))
        XCTAssertEqual(VODMatch.best([r(1, "Avatar", 2009)], title: "Avatar Extended", year: 2009)?.id, 1)
        XCTAssertEqual(VODMatch.best([r(7, "Dune", 2021)], title: "Dune", year: 2021, originalTitles: [:])?.id, 7)
        XCTAssertEqual(VODMatch.best([r(8, "La Cité de la peur", 1994)], title: "The City of Fear", year: 1994,
                                     originalTitles: [8: "The City of Fear"])?.id, 8)
    }
}
