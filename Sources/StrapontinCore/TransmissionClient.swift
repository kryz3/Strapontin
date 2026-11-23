import Foundation

public enum TransmissionError: LocalizedError {
    case unreachable, badLogin, rpc(String)
    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Le moteur de téléchargement ne répond pas."
        case .badLogin: return "Le moteur de téléchargement a refusé la connexion."
        case .rpc(let r): return "Moteur de téléchargement : \(r)"
        }
    }
}

/// API RPC de Transmission (transmission-daemon), en local.
public actor TransmissionClient: TorrentClient {
    let url: URL
    let auth: String?
    let session: URLSession
    var sessionId: String?

    public init(url: String = "http://127.0.0.1:9192/transmission/rpc", username: String?, password: String?) {
        self.url = URL(string: url)!
        if let username, let password {
            auth = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        } else {
            auth = nil
        }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    /// Appel RPC. Transmission répond 409 au premier appel avec l'en-tête X-Transmission-Session-Id à renvoyer.
    func call(_ method: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        for _ in 0..<2 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
            if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id") }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": args])
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) } catch { throw TransmissionError.unreachable }
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 409:
                sessionId = http?.value(forHTTPHeaderField: "X-Transmission-Session-Id")
                continue
            case 401, 403:
                throw TransmissionError.badLogin
            case 200:
                let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let result = j["result"] as? String ?? "?"
                guard result == "success" else { throw TransmissionError.rpc(result) }
                return j["arguments"] as? [String: Any] ?? [:]
            case let c:
                throw TransmissionError.rpc("HTTP \(c)")
            }
        }
        throw TransmissionError.unreachable
    }

    public func version() async throws -> String {
        (try await call("session-get", ["fields": ["version"]])["version"] as? String) ?? "?"
    }

    public func setSession(_ args: [String: Any]) async throws { _ = try await call("session-set", args) }

    /// Ferme le démon proprement (il enregistre son état avant de partir).
    public func shutdown() async { _ = try? await call("session-close") }

    public func torrents() async throws -> [Torrent] {
        let fields = ["hashString", "name", "percentDone", "status", "rateDownload", "eta", "sizeWhenDone",
                      "downloadDir", "addedDate", "error", "isFinished"]
        let list = try await call("torrent-get", ["fields": fields])["torrents"] as? [[String: Any]] ?? []
        func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        return list.map { t in
            let progress = (t["percentDone"] as? NSNumber)?.doubleValue ?? 0
            let dir = t["downloadDir"] as? String ?? ""
            let name = t["name"] as? String ?? ""
            return Torrent(hash: (t["hashString"] as? String ?? "").lowercased(), name: name, progress: progress,
                           state: Self.state(status: Int(i64(t["status"])), progress: progress,
                                             rate: i64(t["rateDownload"]), error: Int(i64(t["error"]))),
                           dlspeed: i64(t["rateDownload"]), eta: max(0, i64(t["eta"])), size: i64(t["sizeWhenDone"]),
                           savePath: dir, contentPath: dir.isEmpty ? name : (dir as NSString).appendingPathComponent(name),
                           addedOn: (t["addedDate"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// États Transmission traduits dans le vocabulaire de qBittorrent, que `Torrent` sait déjà afficher.
    static func state(status: Int, progress: Double, rate: Int64, error: Int) -> String {
        if error == 3 { return "error" }   // 3 = erreur locale (disque plein, droits…)
        switch status {
        case 0: return progress >= 1 ? "stoppedUP" : "stoppedDL"
        case 1, 2: return "checkingDL"
        case 3: return "queuedDL"
        case 4: return progress == 0 && rate == 0 ? "metaDL" : (rate == 0 ? "stalledDL" : "downloading")
        case 5: return "queuedUP"
        case 6: return "uploading"
        default: return "\(status)"
        }
    }

    public func add(_ payload: TorrentPayload, savePath: String?, paused: Bool) async throws {
        var args: [String: Any] = ["paused": paused]
        if let savePath { args["download-dir"] = savePath }
        switch payload {
        case .file(let data, _): args["metainfo"] = data.base64EncodedString()
        case .magnet(let m): args["filename"] = m
        }
        _ = try await call("torrent-add", args)   // un doublon répond « torrent-duplicate » : rien à faire
    }

    public func pause(_ hashes: [String]) async throws { _ = try await call("torrent-stop", ["ids": hashes]) }
    public func resume(_ hashes: [String]) async throws { _ = try await call("torrent-start", ["ids": hashes]) }

    public func delete(_ hashes: [String], deleteFiles: Bool) async throws {
        _ = try await call("torrent-remove", ["ids": hashes, "delete-local-data": deleteFiles])
    }
}
