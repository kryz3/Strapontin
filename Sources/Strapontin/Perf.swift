import Foundation

/// Chronométrage des chargements : écrit « PERF <étape> <ms> » sur la sortie standard si STRAPONTIN_PERF est défini.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["STRAPONTIN_PERF"] != nil
    /// Lancement de l'app (pour les temps « depuis le lancement »).
    static let launch = ContinuousClock.now
    nonisolated(unsafe) private static var once = Set<String>()

    static func log(_ label: String, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let ms = (ContinuousClock.now - start).components
        print("PERF \(label) \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000)")
        fflush(stdout)
    }

    /// Une seule fois par étape (ex. premier affichage de l'accueil).
    static func once(_ label: String, since start: ContinuousClock.Instant = launch) {
        guard enabled, !once.contains(label) else { return }
        once.insert(label)
        log(label, since: start)
    }
}
