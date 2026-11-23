import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum TorznabError: LocalizedError {
    case noKey, unreachable(String), http(Int), api(Int, String), notTorznab, noDownload

    public var errorDescription: String? {
        switch self {
        case .noKey: return "Renseigne l'adresse et la clé API de ton indexeur dans les réglages."
        case .unreachable(let u): return "Indexeur injoignable (\(u)). Vérifie ta connexion, ou tes DNS si ton FAI bloque l'API."
        case .http(429): return "L'indexeur limite les requêtes : réessaie dans quelques secondes."
        case .http(let c): return "L'indexeur a répondu \(c)."
        // 100 à 102 : erreurs d'identifiants dans la spec Newznab/Torznab
        case .api(let c, let d) where (100...102).contains(c): return "Clé API refusée (\(d)). Il faut la clé API, pas la passkey."
        case .api(let c, let d): return "Indexeur : \(d) (code \(c))."
        case .notTorznab: return "La réponse n'est pas du Torznab : vérifie l'adresse et le chemin (/api)."
        case .noDownload: return "Ce résultat n'a ni lien .torrent ni magnet."
        }
    }
}

/// Un résultat de recherche ou du flux RSS.
public struct TorznabItem: Identifiable, Hashable, Sendable {
    public var id: String { guid.isEmpty ? (link ?? title) : guid }
    /// Nom de la release. Certains indexeurs y collent le titre français entre parenthèses à la fin :
    /// « The Bear S01 MULTi 1080p WEB H264-FW (The Bear : Sur place ou à emporter) ».
    public var title: String
    public var guid: String
    public var link: String?          // URL du .torrent (enclosure ou <link>)
    public var magnet: String?
    public var infoHash: String?
    public var detailsURL: String?    // page du torrent sur le site (<comments>)
    public var size: Int64
    public var seeders: Int?
    public var peers: Int?
    public var grabs: Int?
    public var categories: [Int]
    public var imdbId: String?
    public var tmdbId: Int?
    public var published: Date?
    /// 0 = freeleech, 1 = compte entièrement dans le ratio.
    public var downloadFactor: Double?

    public var leechers: Int?
    public var season: Int?

    public var isFreeleech: Bool { downloadFactor == 0 }

    /// Nom de release sans le titre ajouté entre parenthèses.
    public var releaseName: String { Self.split(title).release }
    /// Titre (souvent français) ajouté par l'indexeur entre parenthèses, s'il y en a un.
    public var siteTitle: String? { Self.split(title).extra }

    static func split(_ t: String) -> (release: String, extra: String?) {
        guard t.hasSuffix(")"), let open = t.range(of: " (", options: .backwards) else { return (t, nil) }
        let inner = String(t[open.upperBound..<t.index(before: t.endIndex)])
        // « (2024) » ou « (Jodorowsky's Dune) » : on ne retire que du texte, pas une année seule
        if Int(inner) != nil { return (t, nil) }
        return (String(t[..<open.lowerBound]), inner)
    }
}

public struct TorznabCategory: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var subcategories: [TorznabCategory]
}

/// Ce que l'indexeur déclare savoir faire (t=caps).
public struct TorznabCaps: Sendable {
    public var categories: [TorznabCategory] = []
    /// mode ("search", "tv-search", "movie-search") → paramètres acceptés
    public var searching: [String: Set<String>] = [:]

    public func supports(_ mode: String, _ param: String) -> Bool { searching[mode]?.contains(param) ?? false }
}

/// Client Torznab générique (Jackett, Prowlarr ou un indexeur qui expose directement l'API).
/// Adresse = l'URL complète de l'API (ex. https://indexeur.exemple/api), clé API personnelle (pas une passkey).
/// Limite courante : 100 résultats par page.
public actor TorznabClient {
    /// Catégories Newznab standard.
    public static let defaultMovieCategories = [2000]
    public static let defaultTVCategories = [5000]

    public nonisolated let movieCategories: [Int]
    public nonisolated let tvCategories: [Int]

    let endpoint: String
    let apiKey: String
    let session: URLSession
    var cachedCaps: TorznabCaps?

    /// `endpoint` : URL complète de l'API Torznab. `protocolClasses` : pour les tests (réponses simulées sans réseau).
    public init(endpoint: String, apiKey: String, movieCategories: [Int] = defaultMovieCategories,
                tvCategories: [Int] = defaultTVCategories, protocolClasses: [AnyClass]? = nil) {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while e.hasSuffix("/") { e.removeLast() }
        self.endpoint = e
        self.movieCategories = movieCategories.isEmpty ? Self.defaultMovieCategories : movieCategories
        self.tvCategories = tvCategories.isEmpty ? Self.defaultTVCategories : tvCategories
        // une espace collée avec la clé fait échouer l'authentification
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": "Strapontin/1.0"]
        if let protocolClasses { cfg.protocolClasses = protocolClasses + (cfg.protocolClasses ?? []) }
        self.session = URLSession(configuration: cfg)
    }

    // MARK: requêtes

    func get(_ params: [String: String]) async throws -> Data {
        guard !apiKey.isEmpty else { throw TorznabError.noKey }
        var comps = URLComponents(string: endpoint)!
        comps.queryItems = (params.merging(["apikey": apiKey]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(from: comps.url!)
        } catch {
            throw TorznabError.unreachable(endpoint)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // certains indexeurs renvoient <error> avec un code HTTP 4xx : on lit le corps d'abord
        if let err = TorznabParser.error(in: data) { throw TorznabError.api(err.0, err.1) }
        // mauvaise clé : certains indexeurs répondent 401 avec une page HTML, pas un <error> XML
        if code == 401 || code == 403 { throw TorznabError.api(100, "HTTP \(code)") }
        guard code < 400 else { throw TorznabError.http(code) }
        if let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), ct.contains("html") {
            throw TorznabError.notTorznab
        }
        return data
    }

    public func caps() async throws -> TorznabCaps {
        if let cachedCaps { return cachedCaps }
        let c = try TorznabParser.caps(try await get(["t": "caps"]))
        cachedCaps = c
        return c
    }

    /// Recherche libre. `query` vide = derniers ajouts (c'est ce que fait le « RSS » de Radarr/Sonarr).
    public func search(_ query: String, categories: [Int] = [], limit: Int = 100, offset: Int = 0) async throws -> [TorznabItem] {
        var p = ["t": "search", "limit": String(limit), "offset": String(offset)]
        if !query.isEmpty { p["q"] = query }
        if !categories.isEmpty { p["cat"] = categories.map(String.init).joined(separator: ",") }
        return try TorznabParser.items(try await get(p))
    }

    /// Recherche d'un film, par identifiant TMDb/IMDb si l'indexeur le gère, sinon par titre (+ année).
    public func searchMovie(title: String, year: Int?, tmdbId: Int?, imdbId: String?) async throws -> [TorznabItem] {
        let caps = try? await caps()
        let cat = movieCategories.map(String.init).joined(separator: ",")
        var ids: [[String: String]] = []
        if let tmdbId, caps?.supports("movie-search", "tmdbid") == true { ids.append(["tmdbid": String(tmdbId)]) }
        if let imdbId, caps?.supports("movie-search", "imdbid") == true { ids.append(["imdbid": imdbId]) }
        // un identifiant peut manquer sur l'indexeur (pas renseigné sur la fiche) : on passe au suivant, puis au titre
        for byId in ids {
            let items = try TorznabParser.items(try await get(byId.merging(["t": "movie", "cat": cat, "limit": "100"]) { a, _ in a }))
            if !items.isEmpty { return items }
        }
        let q = [title, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        return try await search(q, categories: movieCategories)
    }

    /// Recherche d'une série / saison / épisode : par TVDB, par IMDb et par titre, résultats réunis sans doublon.
    /// Sur beaucoup d'indexeurs, chaque identifiant n'est renseigné que sur une partie des releases (une série sans
    /// aucun imdbid : la recherche par imdbid seule renvoie 0 ; ailleurs 2 résultats par tvdbid, 3 par imdbid, 5 par
    /// titre). Le tri (bonne œuvre via tmdbid, bonne saison) se fait ensuite avec AutoGrab.matches.
    public func searchTV(title: String, otherTitles: [String] = [], season: Int?, episode: Int?,
                         imdbId: String?, tvdbId: Int? = nil) async throws -> [TorznabItem] {
        let caps = try? await caps()
        var base = ["t": "tvsearch", "cat": tvCategories.map(String.init).joined(separator: ",")]
        if let season { base["season"] = String(season) }
        if let episode { base["ep"] = String(episode) }
        var tries: [[String: String]] = []
        if let tvdbId, caps?.supports("tv-search", "tvdbid") != false { tries.append(["tvdbid": String(tvdbId)]) }
        if let imdbId, caps?.supports("tv-search", "imdbid") != false { tries.append(["imdbid": imdbId]) }
        var seen = Set<String>()
        for t in [title] + otherTitles where !t.isEmpty && seen.insert(t.lowercased()).inserted { tries.append(["q": t]) }
        var all: [TorznabItem] = [], ids = Set<String>()
        for t in tries {
            for it in try await pages(base.merging(t) { _, new in new }) where ids.insert(it.id).inserted { all.append(it) }
        }
        return all
    }

    /// Jusqu'à 3 pages de 100 (une série longue peut dépasser 100 épisodes et packs).
    func pages(_ p: [String: String], max: Int = 3) async throws -> [TorznabItem] {
        var all: [TorznabItem] = []
        for page in 0..<max {
            let items = try TorznabParser.items(try await get(p.merging(["limit": "100", "offset": String(page * 100)]) { _, new in new }))
            all += items
            if items.count < 100 { break }
        }
        return all
    }

    /// Récupère le .torrent (avec la clé dans l'URL fournie par l'indexeur).
    /// Si l'indexeur redirige vers un magnet, on le renvoie à la place.
    public func fetchTorrent(_ item: TorznabItem) async throws -> TorrentPayload {
        guard let link = item.link, let url = URL(string: link) else {
            if let m = item.magnet { return .magnet(m) }
            throw TorznabError.noDownload
        }
        let delegate = MagnetRedirectCatcher()
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(from: url, delegate: delegate)
        } catch {
            if let m = delegate.magnet ?? item.magnet { return .magnet(m) }
            throw TorznabError.unreachable(url.host ?? link)
        }
        if let m = delegate.magnet { return .magnet(m) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let err = TorznabParser.error(in: data) { throw TorznabError.api(err.0, err.1) }
        guard code < 400 else { throw TorznabError.http(code) }
        // un .torrent est un dictionnaire bencodé : il commence par « d »
        guard data.first == UInt8(ascii: "d") else {
            if let m = item.magnet { return .magnet(m) }
            throw TorznabError.http(code)
        }
        return .file(data, name: Self.fileName(for: item))
    }

    static func fileName(for item: TorznabItem) -> String {
        let safe = item.title.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        return safe + ".torrent"
    }
}

public enum TorrentPayload: Sendable {
    case file(Data, name: String)
    case magnet(String)
}

/// URLSession ne suit pas une redirection vers magnet: ; on la capte au passage.
final class MagnetRedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _magnet: String?
    var magnet: String? { lock.withLock { _magnet } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if let u = request.url, u.scheme == "magnet" {
            lock.withLock { _magnet = u.absoluteString }
            return nil
        }
        return request
    }
}

// MARK: - XML

enum TorznabParser {
    static func error(in data: Data) -> (Int, String)? {
        // réponse d'erreur : <error code="100" description="Incorrect user credentials"/>
        let head = String(decoding: data.prefix(600), as: UTF8.self)
        guard head.contains("<error") else { return nil }
        let h = Handler()
        _ = h.parse(data)
        return h.error
    }

    static func items(_ data: Data) throws -> [TorznabItem] {
        let h = Handler()
        guard h.parse(data), h.sawRSS else { throw TorznabError.notTorznab }
        return h.items
    }

    static func caps(_ data: Data) throws -> TorznabCaps {
        let h = Handler()
        guard h.parse(data), h.sawCaps else { throw TorznabError.notTorznab }
        return h.caps
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    final class Handler: NSObject, XMLParserDelegate {
        var items: [TorznabItem] = []
        var caps = TorznabCaps()
        var error: (Int, String)?
        var sawRSS = false, sawCaps = false

        private var cur: TorznabItem?
        private var text = ""
        private var catStack: [TorznabCategory] = []
        private var searchMode: String?

        func parse(_ data: Data) -> Bool {
            let p = XMLParser(data: data)
            p.delegate = self
            p.shouldProcessNamespaces = false
            return p.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            text = ""
            switch name {
            case "rss", "channel": sawRSS = true
            case "caps": sawCaps = true
            case "error": error = (Int(a["code"] ?? "") ?? 0, a["description"] ?? "erreur inconnue")
            case "item":
                cur = TorznabItem(title: "", guid: "", size: 0, categories: [])
            case "enclosure":
                if let u = a["url"] { cur?.link = u }
                if let l = a["length"].flatMap(Int64.init), cur?.size == 0 { cur?.size = l }
            case "torznab:attr", "newznab:attr", "attr":
                guard cur != nil, let n = a["name"], let v = a["value"] else { return }
                switch n {
                case "seeders": cur?.seeders = Int(v)
                case "peers": cur?.peers = Int(v)
                case "leechers": cur?.leechers = Int(v)
                case "season": cur?.season = Int(v)
                case "grabs": cur?.grabs = Int(v)
                case "size": if let s = Int64(v) { cur?.size = s }
                case "category": if let c = Int(v) { cur?.categories.append(c) }
                case "magneturl": cur?.magnet = v
                case "infohash": cur?.infoHash = v
                case "imdbid", "imdb": if !v.isEmpty { cur?.imdbId = v.hasPrefix("tt") ? v : "tt" + v }
                case "tmdbid": cur?.tmdbId = Int(v)
                case "downloadvolumefactor": cur?.downloadFactor = Double(v)
                default: break
                }
            case "category", "subcat":
                // dans t=caps uniquement (dans un <item>, <category> est un élément texte)
                guard cur == nil, let id = a["id"].flatMap(Int.init) else { return }
                catStack.append(TorznabCategory(id: id, name: a["name"] ?? "", subcategories: []))
            case "search", "tv-search", "movie-search", "music-search", "book-search":
                guard sawCaps else { return }
                searchMode = name
                if a["available"] == "yes" {
                    let ps = (a["supportedParams"] ?? "q").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    caps.searching[name] = Set(ps)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cur != nil {
                switch name {
                case "title": cur?.title = t
                case "guid": cur?.guid = t
                case "link": if cur?.link == nil, !t.isEmpty { cur?.link = t }
                case "comments": cur?.detailsURL = t
                case "size": if let s = Int64(t) { cur?.size = s }
                case "pubDate": cur?.published = TorznabParser.dateFormatter.date(from: t)
                case "item":
                    if var it = cur {
                        if it.link?.hasPrefix("magnet:") == true { it.magnet = it.magnet ?? it.link; it.link = nil }
                        items.append(it)
                    }
                    cur = nil
                default: break
                }
            } else if name == "category" || name == "subcat", let last = catStack.popLast() {
                if catStack.isEmpty { caps.categories.append(last) }
                else { catStack[catStack.count - 1].subcategories.append(last) }
            }
            text = ""
        }
    }
}
