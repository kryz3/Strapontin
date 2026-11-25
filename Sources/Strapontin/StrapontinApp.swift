import StrapontinCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var selftestPlayer: MPVPlayer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // pilote Vulkan (MoltenVK) embarqué dans l'app, pour le rendu gpu-next : sans Homebrew sur la machine
        if let icd = Bundle.main.path(forResource: "MoltenVK_icd", ofType: "json", inDirectory: "vulkan/icd.d") {
            setenv("VK_DRIVER_FILES", icd, 1)
            setenv("VK_ICD_FILENAMES", icd, 1)
        }
        // contrôles en ligne de commande : ni Dock, ni fenêtre, ni premier plan
        if CommandLine.arguments.contains(where: { ["--selftest", "--analyser", "--vignettes"].contains($0) }) {
            NSApp.setActivationPolicy(.prohibited)
        } else {
            MainActor.assumeIsolated { EssaiHarness.stayInBackground() }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        // moteur intégré : arrêté seulement si on ne veut pas continuer à partager
        MainActor.assumeIsolated { TorrentEngine.shared.appWillTerminate() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // « Strapontin --selftest fichier.mkv » : vérifie que libmpv embarqué ouvre bien une vidéo (utilisé par la CI)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            // pas de fenêtre donc pas de contexte de rendu : avec vo=libmpv, mpv abandonnerait la piste vidéo
            // et s'arrêterait avant de publier la durée. vo=null décode quand même la vidéo, sans l'afficher.
            let p = MPVPlayer(settings: AppSettings.shared, vo: "null")
            selftestPlayer = p
            p.onDuration = { d in
                p.get("video-codec") { codec in
                    p.get("video-params/pixelformat") { format in
                        print("SELFTEST OK durée=\(d)s codec=\(codec ?? "?") format=\(format ?? "?")")
                        exit(0)
                    }
                }
            }
            p.load(args[i + 1], start: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("SELFTEST ÉCHEC : délai dépassé"); exit(1) }
            return
        }
        // « Strapontin --analyser … » / « --vignettes … » : contrôles sans fenêtre
        if PlaybackCheck.run(args) { return }
        // lancé hors bundle (swift run) : on se comporte quand même comme une vraie app
        if ProcessInfo.processInfo.environment["STRAPONTIN_ESSAI"] == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        Task { @MainActor in
            AppUpdater.shared.start()
            Notifier.shared.start()
            LibraryStore.shared.start()
            DownloadsModel.shared.start()
            TrackerModel.shared.start()
        }
        // « Strapontin --play a.mkv [b.mkv…] » : ouvre directement la lecture (enchaînée si plusieurs fichiers)
        if let i = args.firstIndex(of: "--play") {
            let paths = args[(i + 1)...].prefix { !$0.hasPrefix("-") }
            PlayerController.play(paths.enumerated().map { n, path in
                PlayItem(path: path, title: (path as NSString).lastPathComponent, subtitle: nil, start: 0)
            })
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct StrapontinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = LibraryStore.shared
    @StateObject private var settings = AppSettings.shared

    init() {
        // avant tout accès aux dossiers de l'app : reprise de l'ancienne app « Lecteur » (une seule fois)
        if !CommandLine.arguments.contains(where: { ["--selftest", "--analyser", "--vignettes"].contains($0) }) {
            LegacyMigration.runIfNeeded()
        }
        // caches : réponses TMDb (fiches, recherches) et images, sur disque, dans ~/Library/Caches/Strapontin
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin")
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20,
                                   directory: caches.appendingPathComponent("Images"))
        Task { await TMDbCache.shared.setDirectory(caches.appendingPathComponent("TMDb")) }
    }

    var body: some Scene {
        WindowGroup("Strapontin", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 560)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateMenuItem()
            }
            // menu « Aller » : chaque page de la barre du haut, plus Stockage et Indexeur (sans bouton dédié)
            CommandMenu("Aller") {
                Button("Accueil") { GoTo.open(TopTab.home.rawValue) }.keyboardShortcut("1", modifiers: .command)
                Button("Films") { GoTo.open(TopTab.movies.rawValue) }.keyboardShortcut("2", modifiers: .command)
                Button("Séries") { GoTo.open(TopTab.shows.rawValue) }.keyboardShortcut("3", modifiers: .command)
                Button("Découvrir") { GoTo.open(TopTab.discover.rawValue) }.keyboardShortcut("4", modifiers: .command)
                Button("Recherche") { GoTo.open(TopTab.search.rawValue) }
                Divider()
                Button("Historique") { GoTo.open("history") }.keyboardShortcut("y", modifiers: .command)
                Button("Stockage") { GoTo.open("storage") }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Indexeur") { GoTo.open("tracker") }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Rescanner la bibliothèque") { store.rescan(retryNotFound: true) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                // ajout à la main (aussi : glisser-déposer sur la fenêtre) ; le téléchargement apparaît dans la bibliothèque
                Button("Télécharger un fichier .torrent…") { DownloadsModel.shared.showTorrentImporter = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Télécharger un lien magnet…") { DownloadsModel.shared.showMagnetSheet = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

/// « Rechercher les mises à jour… » dans le menu Strapontin (absent si les mises à jour intégrées sont éteintes).
private struct UpdateMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        if AppUpdater.available {
            Button("Rechercher les mises à jour…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
        }
    }
}
