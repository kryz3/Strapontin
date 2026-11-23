import AppKit
import Foundation
import StrapontinCore
import SwiftUI

/// Le moteur de téléchargement : Transmission embarqué dans Strapontin (par défaut, rien à installer ni régler),
/// ou qBittorrent si on préfère le sien.
///
/// Le démon Transmission tourne sans fenêtre, écoute seulement 127.0.0.1, avec un mot de passe tiré au hasard
/// gardé dans un fichier lisible par l'utilisateur seul (pas le trousseau : avec une app signée ad hoc, macOS
/// redemanderait l'accès à chaque nouvelle version). Les fichiers en cours vont dans un dossier à part : la bibliothèque ne voit un film
/// qu'une fois complet. Par défaut il continue à partager quand Strapontin est fermé (bon pour le ratio).
@MainActor
final class TorrentEngine: ObservableObject {
    static let shared = TorrentEngine()

    enum Backend: String, CaseIterable, Identifiable {
        case builtin = "Intégré", qbittorrent = "qBittorrent"
        var id: String { rawValue }
    }

    @Published var backend: Backend { didSet { d.set(backend.rawValue, forKey: "torrentBackend"); cached = nil } }
    @Published var keepSeeding: Bool { didSet { d.set(keepSeeding, forKey: "keepSeeding") } }
    @Published private(set) var status = ""

    /// Port RPC local. Réglable (« -torrentPort 9393 » en argument) pour faire tourner une copie d'essai
    /// à côté de la vraie app, sans toucher à son moteur.
    var port: Int { d.integer(forKey: "torrentPort") > 0 ? d.integer(forKey: "torrentPort") : 9192 }
    /// Port d'écoute des pairs (0 = celui de Transmission), même usage.
    var peerPort: Int { d.integer(forKey: "torrentPeerPort") }
    private let d = UserDefaults.standard
    private var cached: (any TorrentClient)?
    private var starting: Task<TransmissionClient, Error>?

    let configDir: URL
    let incompleteDir: URL

    private init() {
        backend = Backend(rawValue: d.string(forKey: "torrentBackend") ?? "") ?? .builtin
        keepSeeding = d.object(forKey: "keepSeeding") == nil ? true : d.bool(forKey: "keepSeeding")   // bool() lit aussi « YES »/« NO »
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strapontin/Transmission", isDirectory: true)
        configDir = support
        incompleteDir = support.appendingPathComponent("En cours", isDirectory: true)
        try? FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
    }

    /// Prêt à télécharger ? (qBittorrent doit être branché dans ses réglages ; l'intégré l'est toujours)
    var available: Bool { backend == .builtin ? daemonBinary != nil : AppSettings.shared.qbitEnabled }

    /// Dossier par défaut des téléchargements : le premier dossier de la bibliothèque.
    var defaultDownloadDir: String { AppSettings.shared.folders.first ?? NSHomeDirectory() + "/Downloads" }

    /// Oublie le client : le prochain appel en recrée un (réglages qBittorrent modifiés, changement de moteur).
    func reset() { cached = nil }

    func client() async throws -> any TorrentClient {
        if let cached { return cached }
        switch backend {
        case .qbittorrent:
            let s = AppSettings.shared
            guard s.qbitEnabled else { throw EngineError.qbitOff }
            let c = QbitClient(url: s.qbitURL, username: s.qbitUser, password: s.qbitPassword)
            cached = c
            return c
        case .builtin:
            let c = try await startDaemon()
            cached = c
            return c
        }
    }

    /// Le binaire : embarqué dans l'app (Contents/MacOS), sinon celui de Homebrew (pendant le développement).
    var daemonBinary: URL? {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: "transmission-daemon"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/transmission-daemon"),
                          URL(fileURLWithPath: "/usr/local/bin/transmission-daemon")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func credentials() -> String {
        let url = configDir.appendingPathComponent("rpc-password")
        if let p = try? String(contentsOf: url, encoding: .utf8), !p.isEmpty { return p }
        let p = UUID().uuidString + UUID().uuidString
        SecretFile.write(p, to: url)
        return p
    }

    private var pidURL: URL { configDir.appendingPathComponent("daemon.pid") }

    /// Un démon d'avant répond mais refuse notre mot de passe (fichier effacé…) : on l'arrête pour en relancer un.
    private func killStaleDaemon() async {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        // le numéro a pu être réattribué à un autre programme : on ne tue que si c'est bien transmission-daemon
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name).hasPrefix("transmission") else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
    }

    /// Le démon noté dans daemon.pid tourne-t-il encore (et est-ce bien transmission, pas un numéro réattribué) ?
    private func daemonAlive() -> Bool {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name).hasPrefix("transmission")
    }

    private func startDaemon() async throws -> TransmissionClient {
        if let starting { return try await starting.value }
        let task = Task<TransmissionClient, Error> {
            let password = credentials()
            let c = TransmissionClient(url: "http://127.0.0.1:\(port)/transmission/rpc", username: "lecteur", password: password)
            // déjà lancé (Strapontin relancé alors que le moteur partageait encore)
            do {
                _ = try await c.version()
                try await configure(c)
                return c
            } catch TransmissionError.badLogin {
                await killStaleDaemon()
            } catch {
                // Pas de réponse ne veut pas dire absent : un démon occupé (vérification d'un gros torrent…) répond
                // en retard. En relancer un second donnait des démons en double, incapables de prendre le port.
                if daemonAlive() || LocalPort.isListening(port) {
                    for _ in 0..<20 {
                        try await Task.sleep(nanoseconds: 500_000_000)
                        if (try? await c.version()) != nil { try await configure(c); return c }
                    }
                    throw EngineError.busy
                }
            }

            guard let bin = daemonBinary else { throw EngineError.missing }
            try writeSettings(password: password)
            status = "Démarrage du moteur…"
            let p = Process()
            p.executableURL = bin
            // au premier plan, sans fenêtre ; il survit à la fermeture de Strapontin (macOS ne tue pas les processus
            // enfants), ce qui permet de continuer à partager. Sinon appWillTerminate() l'arrête.
            p.arguments = ["--foreground", "--config-dir", configDir.path, "--logfile", configDir.appendingPathComponent("transmission.log").path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            try? String(p.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if (try? await c.version()) != nil { try await configure(c); status = ""; return c }
            }
            status = ""
            throw EngineError.noStart
        }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// settings.json n'est lu qu'au démarrage du démon (et réécrit par lui à l'arrêt) : on l'écrit avant de lancer.
    private func writeSettings(password: String) throws {
        let url = configDir.appendingPathComponent("settings.json")
        var s = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        let fixed: [String: Any] = [
            "rpc-enabled": true, "rpc-port": port, "rpc-bind-address": "127.0.0.1",
            "rpc-whitelist-enabled": true, "rpc-whitelist": "127.0.0.1",
            "rpc-authentication-required": true, "rpc-username": "lecteur", "rpc-password": password,
            "incomplete-dir": incompleteDir.path, "incomplete-dir-enabled": true, "rename-partial-files": true,
            "download-dir": defaultDownloadDir, "start-added-torrents": true,
            "ratio-limit-enabled": false, "idle-seeding-limit-enabled": false,
            "message-level": 2,
        ]
        s.merge(fixed) { _, new in new }
        if peerPort > 0 { s["peer-port"] = peerPort; s["peer-port-random-on-start"] = false }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted]).write(to: url, options: .atomic)
        // le mot de passe y est en clair jusqu'à ce que le démon le remplace par une empreinte : lisible par nous seuls
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Réglages qui peuvent changer pendant que le démon tourne (dossier de la bibliothèque déplacé, etc.).
    private func configure(_ c: TransmissionClient) async throws {
        try await c.setSession(["download-dir": defaultDownloadDir, "incomplete-dir": incompleteDir.path,
                                "incomplete-dir-enabled": true, "rename-partial-files": true])
    }

    /// À appeler dans applicationWillTerminate.
    /// Relance pour une mise à jour : le moteur continue, la nouvelle version s'y rebranche.
    var survivesRelaunch = false

    func appWillTerminate() {
        guard backend == .builtin, !keepSeeding, !survivesRelaunch, let c = cached as? TransmissionClient else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await c.shutdown(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    enum EngineError: LocalizedError {
        case missing, noStart, qbitOff, busy
        var errorDescription: String? {
            switch self {
            case .missing: return "Le moteur de téléchargement est absent de l'app. Réinstalle Strapontin, ou passe sur qBittorrent dans les réglages."
            case .noStart: return "Le moteur de téléchargement n'a pas démarré. Journal : ~/Library/Application Support/Strapontin/Transmission/transmission.log"
            case .busy: return "Le moteur de téléchargement est occupé et ne répond pas encore ; nouvel essai dans un instant."
            case .qbitOff: return "Branche qBittorrent dans les réglages, ou repasse sur le moteur intégré."
            }
        }
    }
}

/// Onglet de réglages « Téléchargements » : remplace l'onglet qBittorrent (dont les champs restent, en option).
struct EngineSettings<QbitFields: View>: View {
    @StateObject private var engine = TorrentEngine.shared
    @ViewBuilder var qbitFields: () -> QbitFields
    @State private var test: String?

    var body: some View {
        Form {
            Section {
                Picker("Moteur", selection: $engine.backend) {
                    Text("Intégré à Strapontin (recommandé)").tag(TorrentEngine.Backend.builtin)
                    Text("Mon qBittorrent").tag(TorrentEngine.Backend.qbittorrent)
                }
                if engine.backend == .builtin {
                    Toggle("Continuer à partager quand Strapontin est fermé", isOn: $engine.keepSeeding)
                }
                HStack {
                    Button("Tester") {
                        // client recréé : prend en compte des réglages qBittorrent modifiés depuis
                        engine.reset()
                        Task {
                            do { test = "✓ Prêt (version \(try await engine.client().version()))" } catch { test = error.localizedDescription }
                        }
                    }
                    if let test { Text(test).foregroundStyle(.secondary).lineLimit(2) }
                }
            } footer: {
                Text(engine.backend == .builtin
                     ? "Rien à installer ni à régler : Strapontin télécharge lui-même (moteur Transmission, sans fenêtre). Les fichiers en cours restent à part et n'arrivent dans la bibliothèque qu'une fois complets. Partager après coup aide ton ratio sur les trackers privés."
                     : "Strapontin pilote ton qBittorrent par son interface Web.")
                    .foregroundStyle(.secondary)
            }
            if engine.backend == .qbittorrent { qbitFields() }
        }
        .formStyle(.grouped)
    }
}

/// Petit secret local (clé API, mot de passe du moteur) : un fichier en 0600 dans Application Support.
enum SecretFile {
    static func write(_ value: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    }

    static func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
