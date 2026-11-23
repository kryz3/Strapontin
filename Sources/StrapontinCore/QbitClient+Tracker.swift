import Foundation

extension QbitClient {
    /// Envoie un .torrent déjà téléchargé (en mémoire) ou un magnet, rangé dans une catégorie qBittorrent.
    /// On télécharge le .torrent côté app plutôt que de passer l'URL à qBittorrent : sa clé API reste
    /// dans Strapontin, et une erreur (clé, ratio, DNS) s'affiche chez nous au lieu de disparaître dans qBittorrent.
    /// `paused` : ajouté sans démarrer (« paused » pour qBittorrent 4, « stopped » pour qBittorrent 5).
    public func addTorrent(_ payload: TorrentPayload, savePath: String?, category: String? = "Strapontin", paused: Bool = false) async throws {
        switch payload {
        case .magnet(let m):
            var form = ["urls": m]
            if let savePath { form["savepath"] = savePath }
            if let category { form["category"] = category }
            if paused { form["paused"] = "true"; form["stopped"] = "true" }
            _ = try await ok(request("/api/v2/torrents/add", form: form))
        case .file(let data, let name):
            let boundary = "lecteur-\(UUID().uuidString)"
            var req = request("/api/v2/torrents/add")
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ k: String, _ v: String) {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
            }
            if let savePath { field("savepath", savePath) }
            if let category { field("category", category) }
            if paused { field("paused", "true"); field("stopped", "true") }
            let safeName = name.replacingOccurrences(of: "\"", with: "'")
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/x-bittorrent\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body
            let resp = try await ok(req)
            // qBittorrent répond « Fails. » (200) quand il refuse le fichier, par ex. un doublon
            if String(decoding: resp, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Fails." {
                throw QbitError.http(200, "torrent refusé (déjà présent ?)")
            }
        }
    }

    /// Fait ajouter « .!qB » aux fichiers pas finis : la bibliothèque ne les voit qu'une fois complets
    /// (sinon un film à moitié téléchargé apparaît dès le début du téléchargement).
    public func hideIncompleteFiles() async throws {
        _ = try await ok(request("/api/v2/app/setPreferences", form: ["json": #"{"incomplete_files_ext":true}"#]))
    }

    public func incompleteFilesHidden() async throws -> Bool {
        let d = try await ok(request("/api/v2/app/preferences"))
        return ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["incomplete_files_ext"] as? Bool) ?? false
    }
}

extension QbitClient: TorrentClient {
    public func add(_ payload: TorrentPayload, savePath: String?, paused: Bool) async throws {
        try await addTorrent(payload, savePath: savePath, category: "Strapontin", paused: paused)
    }
}
