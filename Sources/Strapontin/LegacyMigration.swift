import AppKit
import Darwin
import StrapontinCore

/// L'app s'appelait « Lecteur » (identifiant en « ….lecteur »). Au premier lancement de Strapontin, on reprend
/// tout ce qu'elle avait sur ce Mac, sans rien perdre :
/// - les préférences (seulement les clés absentes ; l'ancien domaine n'est pas modifié) ;
/// - ~/Library/Application Support/Lecteur (bibliothèque, téléchargements, suivis, clés en 0600, moteur Transmission
///   avec ses torrents et leur progression), déplacé d'un bloc vers …/Strapontin. Un lien « Lecteur » → « Strapontin »
///   reste à l'ancienne place : les torrents en cours retrouvent leurs fichiers partiels, qui y sont référencés ;
/// - les caches (vignettes, intros).
/// Le moteur de l'ancienne app, s'il partage encore, est d'abord arrêté proprement (il enregistre l'état de chaque
/// torrent) ; le nouveau le relance ensuite depuis le nouveau dossier.
@MainActor
enum LegacyMigration {
    static let doneKey = "migratedFromLecteur"

    /// Domaine des anciennes préférences. Copie d'essai : un faux domaine, pour ne jamais lire celles de l'utilisateur.
    static var oldDomain: String {
        if EssaiHarness.enabled { return ProcessInfo.processInfo.environment["STRAPONTIN_ESSAI_ANCIEN_DOMAINE"] ?? "" }
        // le fichier de préférences « <identifiant>.lecteur.plist » qui contient des réglages de l'app
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".lecteur.plist") }
        for name in names.sorted() {
            let domain = String(name.dropLast(".plist".count))
            let keys = Set(UserDefaults.standard.persistentDomain(forName: domain)?.keys.map { $0 } ?? [])
            if !keys.isDisjoint(with: ["folders", "volume", "qbitEnabled", "torrentBackend", "keepSeeding", "tmdbLanguage",
                                       "autoplayNext", "hwdec", "audioLangs", "subLangs"]) { return domain }
        }
        return ""
    }

    static func runIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Lecteur", isDirectory: true)
        let new = support.appendingPathComponent("Strapontin", isDirectory: true)

        if !oldDomain.isEmpty, let prefs = d.persistentDomain(forName: oldDomain) {
            for (k, v) in prefs where d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[k] == nil {
                d.set(v, forKey: k)
            }
        }

        if isRealDirectory(old) {
            quitOldApp()
            stopOldEngine(configDir: old.appendingPathComponent("Transmission"), port: d.integer(forKey: "torrentPort"))
            if fm.fileExists(atPath: new.path) {
                // lancement d'avant interrompu : on complète sans écraser ce que Strapontin a déjà
                for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !fm.fileExists(atPath: new.appendingPathComponent(name).path) {
                    try? fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
                }
                if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fm.removeItem(at: old)
                }
            } else {
                try? fm.moveItem(at: old, to: new)
            }
            if !fm.fileExists(atPath: old.path) {
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
            }
        }

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let oldCache = caches.appendingPathComponent("Lecteur"), newCache = caches.appendingPathComponent("Strapontin")
        if isRealDirectory(oldCache), !fm.fileExists(atPath: newCache.path) { try? fm.moveItem(at: oldCache, to: newCache) }

        d.set(true, forKey: doneKey)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        return !isLink && FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// L'ancienne app encore ouverte : on lui demande de quitter (10 s au plus).
    private static func quitOldApp() {
        guard !oldDomain.isEmpty else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: oldDomain)
        apps.forEach { $0.terminate() }
        let limit = Date().addingTimeInterval(10)
        while apps.contains(where: { !$0.isTerminated }), Date() < limit { usleep(200_000) }
    }

    /// Arrête le démon Transmission de l'ancienne app : demande d'arrêt par RPC (« session-close », il enregistre
    /// alors l'état de chaque torrent), puis SIGTERM s'il tourne encore ; on attend qu'il soit vraiment parti.
    private static func stopOldEngine(configDir: URL, port: Int) {
        guard let s = try? String(contentsOf: configDir.appendingPathComponent("daemon.pid"), encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), isTransmission(pid) else { return }
        if let password = try? String(contentsOf: configDir.appendingPathComponent("rpc-password"), encoding: .utf8) {
            let c = TransmissionClient(url: "http://127.0.0.1:\(port > 0 ? port : 9192)/transmission/rpc", username: "lecteur",
                                       password: password.trimmingCharacters(in: .whitespacesAndNewlines))
            let done = DispatchSemaphore(value: 0)
            Task.detached { await c.shutdown(); done.signal() }
            _ = done.wait(timeout: .now() + 5)
        }
        if waitForExit(pid, seconds: 15) { return }
        kill(pid, SIGTERM)
        _ = waitForExit(pid, seconds: 15)
    }

    private static func isTransmission(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name).hasPrefix("transmission")
    }

    private static func waitForExit(_ pid: Int32, seconds: Double) -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while isTransmission(pid) {
            if Date() > limit { return false }
            usleep(200_000)
        }
        return true
    }
}
