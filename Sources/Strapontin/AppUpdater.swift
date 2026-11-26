import AppKit
import Combine
import Sparkle
import SwiftUI

/// Mises à jour intégrées (Sparkle 2). L'appcast est publié avec chaque release GitHub
/// (`…/releases/latest/download/appcast.xml`, renseigné dans l'Info.plist par `scripts/bundle.sh`) ; chaque archive
/// est signée EdDSA et Sparkle refuse toute archive dont la signature ne correspond pas à `SUPublicEDKey`.
/// Sans adresse d'appcast (compilation locale, `swift run`) le module reste éteint.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    static var available: Bool {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        return Bundle.main.bundlePath.hasSuffix(".app") && !feed.isEmpty && !key.isEmpty && !EssaiHarness.enabled
    }

    /// À appeler une fois au lancement (pas en mode ligne de commande).
    func start() {
        guard controller == nil, Self.available else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
        // à chaque lancement, une vérification discrète (pas seulement une fois par jour) : la fenêtre n'apparaît
        // que s'il y a une nouvelle version ; respecte « Rechercher automatiquement » s'il est décoché
        if c.updater.automaticallyChecksForUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.updater.checkForUpdatesInBackground() }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var currentVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    // Le moteur de téléchargement survit à la relance : la nouvelle version s'y rebranche.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { TorrentEngine.shared.survivesRelaunch = true }
    }
}

/// Section « Mises à jour » des réglages.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Section {
            if AppUpdater.available {
                Toggle("Rechercher automatiquement", isOn: Binding(get: { updater.automaticallyChecks },
                                                                  set: { updater.automaticallyChecks = $0 }))
                Button("Rechercher maintenant") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            } else {
                Text("Mises à jour intégrées désactivées dans cette copie (compilée sans appcast).").foregroundStyle(.secondary)
            }
        } header: {
            Text("Mises à jour")
        } footer: {
            Text("Version \(updater.currentVersion). Chaque mise à jour est vérifiée (signature EdDSA) avant d'être installée ; les téléchargements en cours continuent pendant la relance.")
                .foregroundStyle(.secondary)
        }
    }
}
