import AppKit
import StrapontinCore
import SwiftUI

/// Pilotage d'une copie d'essai isolée (captures d'écran sans droit d'enregistrement de l'écran, sans prendre la main
/// sur le Mac). Inerte tant que la variable d'environnement STRAPONTIN_ESSAI n'est pas définie : la vraie app ne l'a jamais.
///
/// Commandes (notification distribuée « io.github.kryz3.strapontin.essai.cmd », objet = texte) :
///   tab:home|movies|shows|discover · open:<valeur de navigation> · back · search:<texte>
///   snap:<chemin.png> · add-file:<chemin.torrent> · add-magnet:<lien>
///   assign:<id entrée>|movie|<tmdb> · attach:<empreinte>|movie|<tmdb> · cancel:<empreinte> · delete-item:<id entrée>
@MainActor
final class EssaiHarness: ObservableObject {
    static let shared = EssaiHarness()
    static var enabled: Bool { ProcessInfo.processInfo.environment["STRAPONTIN_ESSAI"] != nil }

    /// Indexeur factice local (copie d'essai seulement, URL complète de son API Torznab) : les essais de
    /// « Télécharger » ne touchent jamais un vrai indexeur.
    nonisolated static var fakeTracker: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["STRAPONTIN_ESSAI"] != nil, let base = env["STRAPONTIN_ESSAI_TORZNAB"], base.hasPrefix("http://127.0.0.1:") else { return nil }
        return base
    }

    /// Essai du vrai rendu gpu-next ; sinon le lecteur d'essai n'a pas de fenêtre vidéo.
    nonisolated static var realRendering: Bool { ProcessInfo.processInfo.environment["STRAPONTIN_ESSAI_RENDU"] != nil }
    /// Ni son, ni Dock, ni premier plan.
    nonisolated static var playerOptions: [(String, String)] {
        [("ao", "null"), ("focus-on", "never"), ("macos-app-activation-policy", "accessory"), ("input-media-keys", "no")]
    }

    /// Fenêtre d'essai invisible et traversée par les clics : l'utilisateur n'est pas gêné et ne peut pas cliquer dedans.
    static func conceal(_ w: NSWindow) {
        if w.alphaValue != 0 { w.alphaValue = 0 }
        if !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
    }

    static func stayInBackground() {
        guard enabled else { return }
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(conceal) }
        }
    }

    enum Command: Equatable { case tab(TopTab), open(String), back, search(String), step(Int) }
    @Published var command: Command?
    @Published private(set) var serial = 0

    private init() {
        guard Self.enabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.kryz3.strapontin.essai.cmd"), object: nil, queue: .main) { n in
            guard let s = n.object as? String else { return }
            MainActor.assumeIsolated { EssaiHarness.shared.handle(s) }
        }
    }

    private func handle(_ s: String) {
        let (verb, arg) = s.firstIndex(of: ":").map { (String(s[..<$0]), String(s[s.index(after: $0)...])) } ?? (s, "")
        switch verb {
        case "tab":
            let map: [String: TopTab] = ["home": .home, "movies": .movies, "shows": .shows, "discover": .discover,
                                         "downloads": .downloads, "search": .search, "foryou": .forYou, "direct": .live, "catalogue": .iptvCatalog]
            if let t = map[arg] { send(.tab(t)) }
        case "open": send(.open(arg))
        case "back": send(.back)
        case "search": send(.search(arg))
        case "snap": snapshot(to: arg)
        case "dump-search":
            // diagnostic : où est le champ de recherche de la barre d'outils, et est-il visible ?
            for w in NSApp.windows {
                func walk(_ v: NSView) {
                    if v is NSSearchField { print("NSSearchField", w.title, v.frame, "hidden:", v.isHiddenOrHasHiddenAncestor, "window:", v.window != nil) }
                    v.subviews.forEach(walk)
                }
                if let root = w.contentView?.superview { walk(root) }
                print("fenêtre", w.title, "items barre d'outils:", w.toolbar?.items.map { "\($0.itemIdentifier.rawValue)" } ?? [],
                      "visibles:", w.toolbar?.visibleItems?.map { $0.itemIdentifier.rawValue } ?? [])
            }
            fflush(stdout)
        case "add-file": DownloadsModel.shared.add(files: [URL(fileURLWithPath: arg)], to: nil)
        case "add-magnet": DownloadsModel.shared.add(links: [arg], to: nil)
        // mêmes appels que les feuilles « Corriger la fiche », « Rattacher », « Annuler », « Supprimer »
        case "assign", "attach":
            let p = arg.split(separator: "|").map(String.init)
            guard p.count == 3, let k = MediaKind(rawValue: p[1]), let id = Int(p[2]) else { return }
            if verb == "attach" { DownloadsModel.shared.assign(hash: p[0], kind: k, tmdbId: id) }
            else if let item = LibraryStore.shared.item(id: p[0]) { Task { await LibraryStore.shared.assign(item, kind: k, tmdbId: id) } }
        case "cancel": DownloadsModel.shared.cancel([arg], deleteFiles: true)
        case "pause": DownloadsModel.shared.pause([arg])
        case "resume": DownloadsModel.shared.resume([arg])
        case "attach-episode":
            let p = arg.split(separator: "|").map(String.init)
            guard p.count == 4, let id = Int(p[1]), let s = Int(p[2]), let e = Int(p[3]) else { return }
            DownloadsModel.shared.assign(hash: p[0], kind: .tv, tmdbId: id, season: s, episode: e)
        case "season":
            let p = arg.split(separator: "|").compactMap { Int($0) }
            if p.count == 2 { SeriesModel.of(p[0]).selected = p[1] }
        case "step": if let n = Int(arg) { send(.step(n)) }
        case "scroll": scroll(by: CGFloat(Double(arg) ?? 0))
        // les boutons Télécharger, seulement avec l'indexeur factice : jamais un vrai indexeur
        case "grab-episode", "grab-season", "grab-missing", "follow-check":
            let p = arg.split(separator: "|").compactMap { Int($0) }
            guard Self.fakeTracker != nil, let id = p.first else { return }
            let series = SeriesModel.of(id)
            switch verb {
            case "grab-episode": if p.count == 3 { series.downloadEpisode(season: p[1], episode: p[2]) }
            case "grab-season": if p.count == 2 { series.downloadSeason(p[1]) }
            case "grab-missing": if p.count == 2 { series.downloadMissing(p[1]) }
            default:
                guard let m = series.media else { return }
                TrackerModel.shared.follow(m, backfill: false)
                Task { await TrackerModel.shared.checkNew() }
            }
        case "pourtoi":   // pourtoi:like|dislike|seen sur la première carte, ou pourtoi:etat
            let m = ForYouModel.shared
            if let r = FeedReaction(rawValue: arg), let first = m.cards.first { m.react(first, r) }
            print("ESSAI pourtoi", m.cards.prefix(8).map { "\($0.title) [\($0.genreIds.first ?? 0)] ← \($0.because ?? "découverte")" }.joined(separator: " | "))
            fflush(stdout)
        case "chaine":   // chaine:<nom exact> : comme un clic sur la chaîne
            if let e = IPTVStore.shared.channels.first(where: { $0.name == arg }) { PlayerController.playLive(e) }
        case "qualite":   // qualite:<clé de fiche>|<choix> : comme le menu de la cloche
            let p = arg.split(separator: "|").map(String.init)
            if p.count == 2 { TrackerModel.shared.setQuality(QualityChoice(rawValue: p[1]), for: p[0]) }
        case "lire", "reprendre":
            if let item = LibraryStore.shared.items.first(where: { i in i.files.contains { $0.fileName == arg } }),
               let f = item.files.first(where: { $0.fileName == arg }) {
                play(item, from: f, resume: verb == "reprendre")
            } else {
                print("ESSAI introuvable", arg); fflush(stdout)
            }
        case "player":
            PlayerController.current?.trial(arg)
        case "player-snap":
            PlayerController.current?.trialSnapshot(to: arg)
        case "delete-item":
            if let item = LibraryStore.shared.item(id: arg) { Task { _ = try? await MediaDeleter.delete(item.files, permanently: true) } }
        default: break
        }
    }

    private func send(_ c: Command) { command = c; serial += 1 }

    /// Fait défiler la page affichée (la plus grande zone qui défile verticalement).
    private func scroll(by dy: CGFloat) {
        guard let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.contentView else { return }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !s.isHiddenOrHasHiddenAncestor, let d = s.documentView,
               d.frame.height > s.contentView.bounds.height + 1 { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let s = found.last(where: { $0.frame.height > root.bounds.height / 2 }), let d = s.documentView else { return }
        let top = min(max(0, s.contentView.bounds.origin.y + dy), max(0, d.frame.height - s.contentView.bounds.height))
        s.contentView.scroll(to: NSPoint(x: 0, y: top))
        s.reflectScrolledClipView(s.contentView)
    }

    /// Image de la fenêtre principale (barre d'outils comprise), en 2x.
    private func snapshot(to path: String) {
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
