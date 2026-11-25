import Foundation

/// Sous-titres en ligne (OpenSubtitles.com, API REST officielle, clé gratuite) : recherche par identifiant TMDb (film,
/// ou série + saison + épisode), sinon par titre ; téléchargement du fichier choisi.
public struct SubtitleResult: Identifiable, Hashable, Sendable {
    public var id: Int            // file_id
    public var language: String   // « fr », « en »…
    public var release: String
    public var downloads: Int
    public var hearingImpaired: Bool
    public var machineTranslated: Bool
}

public final class OpenSubtitlesClient: @unchecked Sendable {
    let apiKey: String
    let userAgent: String
    let session: URLSession
    static let base = "https://api.opensubtitles.com/api/v1"

    public init(apiKey: String, userAgent: String = "Strapontin v0.1", session: URLSession = .shared) {
        self.apiKey = apiKey; self.userAgent = userAgent; self.session = session
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    public enum Failure: Error, LocalizedError {
        case http(Int), quota, noLink
        public var errorDescription: String? {
            switch self {
            case .http(401), .http(403): return "clé OpenSubtitles refusée"
            case .http(let c): return "OpenSubtitles a répondu \(c)"
            case .quota: return "quota de téléchargements du jour atteint chez OpenSubtitles"
            case .noLink: return "OpenSubtitles n'a pas donné de fichier"
            }
        }
    }

    /// Recherche : `tmdbId` pour un film, `parentTmdbId` + saison + épisode pour un épisode, sinon `query`.
    public func search(tmdbId: Int? = nil, parentTmdbId: Int? = nil, season: Int? = nil, episode: Int? = nil,
                       query: String? = nil, languages: [String]) async throws -> [SubtitleResult] {
        var c = URLComponents(string: Self.base + "/subtitles")!
        var items = [URLQueryItem(name: "languages", value: languages.joined(separator: ","))]
        if let p = parentTmdbId {
            items.append(.init(name: "parent_tmdb_id", value: String(p)))
            if let s = season { items.append(.init(name: "season_number", value: String(s))) }
            if let e = episode { items.append(.init(name: "episode_number", value: String(e))) }
        } else if let t = tmdbId {
            items.append(.init(name: "tmdb_id", value: String(t)))
        } else if let q = query {
            items.append(.init(name: "query", value: q))
        }
        c.queryItems = items.sorted { $0.name < $1.name }   // l'API préfère les paramètres triés (cache)
        let (d, resp) = try await session.data(for: request(c.url!))
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.http(code) }
        return Self.rank(Self.parseSearch(d), languages: languages)
    }

    /// Le fichier choisi : son contenu (SRT le plus souvent) et son nom.
    public func download(fileId: Int) async throws -> (data: Data, fileName: String) {
        let body = try JSONSerialization.data(withJSONObject: ["file_id": fileId])
        let (d, resp) = try await session.data(for: request(URL(string: Self.base + "/download")!, method: "POST", body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 406 { throw Failure.quota }
        if code != 200 { throw Failure.http(code) }
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let link = (j["link"] as? String).flatMap(URL.init)
        else { throw Failure.noLink }
        let (file, _) = try await session.data(from: link)
        return (file, (j["file_name"] as? String) ?? "\(fileId).srt")
    }

    public static func parseSearch(_ data: Data) -> [SubtitleResult] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let a = item["attributes"] as? [String: Any],
                  let file = (a["files"] as? [[String: Any]])?.first, let id = file["file_id"] as? Int else { return nil }
            return SubtitleResult(id: id, language: (a["language"] as? String) ?? "?",
                                  release: (a["release"] as? String) ?? (file["file_name"] as? String) ?? "",
                                  downloads: (a["download_count"] as? Int) ?? 0,
                                  hearingImpaired: (a["hearing_impaired"] as? Bool) ?? false,
                                  machineTranslated: ((a["machine_translated"] as? Bool) ?? false) || ((a["ai_translated"] as? Bool) ?? false))
        }
    }

    /// Langue préférée d'abord, puis traductions humaines, puis les plus téléchargés.
    public static func rank(_ list: [SubtitleResult], languages: [String]) -> [SubtitleResult] {
        list.sorted { a, b in
            let la = languages.firstIndex(of: a.language) ?? Int.max, lb = languages.firstIndex(of: b.language) ?? Int.max
            if la != lb { return la < lb }
            if a.machineTranslated != b.machineTranslated { return !a.machineTranslated }
            return a.downloads > b.downloads
        }
    }
}
