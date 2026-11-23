import Foundation

public enum QbitError: LocalizedError {
    case unreachable(String), badLogin, banned, http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .unreachable(let u): return "qBittorrent injoignable à \(u). L'interface Web est-elle activée ?"
        case .badLogin: return "Identifiants qBittorrent refusés."
        case .banned: return "qBittorrent a bloqué l'adresse après trop d'échecs de connexion."
        case .http(let c, let t): return "qBittorrent a répondu \(c) : \(t)"
        }
    }
}

public struct Torrent: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var name: String
    public var progress: Double
    public var state: String
    public var dlspeed: Int64
    public var eta: Int64
    public var size: Int64
    public var savePath: String
    public var contentPath: String
    public var addedOn: Double

    public var isDone: Bool {
        progress >= 1 && ["uploading", "stalledUP", "pausedUP", "stoppedUP", "queuedUP", "forcedUP"].contains(state)
    }

    public var stateLabel: String {
        [
            "downloading": "Téléchargement", "stalledDL": "En attente de sources", "metaDL": "Métadonnées",
            "forcedDL": "Téléchargement", "pausedDL": "En pause", "stoppedDL": "En pause", "queuedDL": "En file",
            "checkingDL": "Vérification", "uploading": "Terminé · partage", "stalledUP": "Terminé",
            "pausedUP": "Terminé", "stoppedUP": "Terminé", "queuedUP": "Terminé", "forcedUP": "Terminé · partage",
            "checkingUP": "Vérification", "error": "Erreur", "missingFiles": "Fichiers manquants",
            "moving": "Déplacement",
        ][state] ?? state
    }
}

/// API Web de qBittorrent (v2). Gère le renommage pause→stop de qBittorrent 5.
public actor QbitClient {
    let base: String
    let username: String
    let password: String
    let session: URLSession
    var logged = false

    public init(url: String, username: String, password: String) {
        self.base = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.username = username
        self.password = password
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: cfg)
    }

    func request(_ path: String, form: [String: String]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.setValue(base, forHTTPHeaderField: "Referer")
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // encodage strict : les liens magnet contiennent des & et des =
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let body = form.map { k, v in
                "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }

    func send(_ req: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw QbitError.unreachable(base)
        }
    }

    public func login() async throws {
        let (code, data) = try await send(request("/api/v2/auth/login", form: ["username": username, "password": password]))
        if code == 403 { throw QbitError.banned }
        if code != 200 || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Fails." {
            throw QbitError.badLogin
        }
        logged = true
    }

    func call(_ req: URLRequest) async throws -> (Int, Data) {
        if !logged { try await login() }
        var (code, data) = try await send(req)
        if code == 403 {
            try await login()
            (code, data) = try await send(req)
        }
        return (code, data)
    }

    func ok(_ req: URLRequest) async throws -> Data {
        let (code, data) = try await call(req)
        guard code < 400 else { throw QbitError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        return data
    }

    public func version() async throws -> String {
        String(decoding: try await ok(request("/api/v2/app/version")), as: UTF8.self)
    }

    public func defaultSavePath() async throws -> String {
        String(decoding: try await ok(request("/api/v2/app/defaultSavePath")), as: UTF8.self)
    }

    public func torrents() async throws -> [Torrent] {
        let data = try await ok(request("/api/v2/torrents/info"))
        let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        return arr.map { t in
            Torrent(hash: t["hash"] as? String ?? "", name: t["name"] as? String ?? "",
                    progress: (t["progress"] as? NSNumber)?.doubleValue ?? 0, state: t["state"] as? String ?? "",
                    dlspeed: i64(t["dlspeed"]), eta: i64(t["eta"]), size: i64(t["size"]),
                    savePath: t["save_path"] as? String ?? "", contentPath: t["content_path"] as? String ?? "",
                    addedOn: (t["added_on"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    public func add(urls: [String], savePath: String?) async throws {
        var form = ["urls": urls.joined(separator: "\n")]
        if let savePath { form["savepath"] = savePath }
        _ = try await ok(request("/api/v2/torrents/add", form: form))
    }

    public func add(torrentFile: URL, savePath: String?) async throws {
        let boundary = "lecteur-\(UUID().uuidString)"
        var req = request("/api/v2/torrents/add")
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ s: String) { body.append(s.data(using: .utf8)!) }
        if let savePath {
            field("--\(boundary)\r\nContent-Disposition: form-data; name=\"savepath\"\r\n\r\n\(savePath)\r\n")
        }
        field("--\(boundary)\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"\(torrentFile.lastPathComponent)\"\r\n")
        field("Content-Type: application/x-bittorrent\r\n\r\n")
        body.append(try Data(contentsOf: torrentFile))
        field("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        _ = try await ok(req)
    }

    func action(_ new: String, _ old: String, _ hashes: [String]) async throws {
        let form = ["hashes": hashes.joined(separator: "|")]
        let (code, _) = try await call(request("/api/v2/torrents/\(new)", form: form))
        if code == 404 { _ = try await ok(request("/api/v2/torrents/\(old)", form: form)) }
    }

    public func pause(_ hashes: [String]) async throws { try await action("stop", "pause", hashes) }
    public func resume(_ hashes: [String]) async throws { try await action("start", "resume", hashes) }

    public func delete(_ hashes: [String], deleteFiles: Bool = false) async throws {
        _ = try await ok(request("/api/v2/torrents/delete",
                                 form: ["hashes": hashes.joined(separator: "|"), "deleteFiles": deleteFiles ? "true" : "false"]))
    }
}
