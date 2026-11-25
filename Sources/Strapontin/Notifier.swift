import AppKit
import StrapontinCore
import UserNotifications

/// Notification macOS quand un téléchargement est terminé ; un clic ouvre sa fiche.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var asked = false

    func start() {
        guard Bundle.main.bundleIdentifier != nil, !EssaiHarness.enabled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// « Dune : Deuxième partie est prêt », « The Bear · S02E03 est prêt ».
    func downloadFinished(title: String, detail: String?, mediaKey: String?) {
        if EssaiHarness.enabled {   // copie d'essai : rien sur l'écran de l'utilisateur, une ligne dans le journal
            print("ESSAI notification « \(title) » \(detail ?? "") → \(mediaKey ?? "-")"); fflush(stdout)
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let c = UNMutableNotificationContent()
            c.title = "\(title) est prêt"
            c.body = detail.map { "\($0) · prêt à regarder" } ?? "Prêt à regarder"
            c.sound = .default
            if let mediaKey { c.userInfo = ["mediaKey": mediaKey] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if asked { post(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async(execute: post) }
        }
    }

    // clic sur la notification : l'app au premier plan, sur la fiche du titre
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["mediaKey"] as? String
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
            if let key { GoTo.open(key) }
            done()
        }
    }

    // affichée même quand l'app est au premier plan
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
