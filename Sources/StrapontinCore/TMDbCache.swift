import CryptoKit
import Foundation

/// Cache des réponses TMDb, partagé par tous les clients : en mémoire, sur disque (si un dossier est donné), avec une
/// durée de vie par type de requête, et une seule requête en vol pour une même adresse (deux pages qui demandent la
/// même fiche au même moment n'en font qu'une). La clé API ne fait pas partie de la clé du cache et n'est jamais écrite.
public actor TMDbCache {
    public static let shared = TMDbCache()

    /// Dossier du cache disque (Caches de l'app). nil = mémoire seulement (tests).
    public var directory: URL?
    private var memory: [String: (expires: Date, data: Data)] = [:]
    private var inflight: [String: Task<Data, Error>] = [:]

    public func setDirectory(_ url: URL?) {
        directory = url
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    public func clear() {
        memory = [:]
        if let directory { try? FileManager.default.removeItem(at: directory); setDirectory(directory) }
    }

    /// La réponse pour `key`, depuis le cache si elle est encore fraîche, sinon via `fetch` (une seule fois en vol).
    public func data(for key: String, ttl: TimeInterval, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let now = Date()
        if let hit = memory[key], hit.expires > now { return hit.data }
        if let file = fileURL(key), let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date, modified.addingTimeInterval(ttl) > now,
           let data = try? Data(contentsOf: file) {
            memory[key] = (modified.addingTimeInterval(ttl), data)
            return data
        }
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await fetch() }
        inflight[key] = task
        defer { inflight[key] = nil }
        let data = try await task.value
        memory[key] = (now.addingTimeInterval(ttl), data)
        if memory.count > 600 { memory = memory.filter { $0.value.expires > now } }
        if let file = fileURL(key) { try? data.write(to: file, options: .atomic) }
        return data
    }

    private func fileURL(_ key: String) -> URL? {
        guard let directory else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
