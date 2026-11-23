import StrapontinCore
import SwiftUI
import UniformTypeIdentifiers

/// Onglets de la barre du haut, façon Apple TV (tvOS) : une pastille translucide qui flotte sur les images.
enum TopTab: String, Hashable, CaseIterable, Identifiable {
    // ni Bibliothèque (doublon de Films + Séries : ses filtres et tris sont dans « Tous les films » / « Toutes les
    // séries ») ; les téléchargements sont sur les affiches, et dans leur onglet tant qu'il y en a en cours
    case search = "Recherche", home = "Accueil", movies = "Films", shows = "Séries", discover = "Découvrir"
    case downloads = "En téléchargement"
    var id: String { rawValue }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Tout", inProgress = "En cours", unwatched = "Pas encore vus", unmatched = "Non identifiés", downloading = "En téléchargement"
    var id: String { rawValue }
    @MainActor func includes(_ i: LibraryItem) -> Bool {
        switch self {
        case .all: return true
        case .inProgress: return i.inProgress
        case .unwatched: return !i.allWatched
        case .unmatched: return i.media == nil
        case .downloading: return DownloadsModel.shared.entry(for: i.id).map { !$0.isDone } ?? false
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case added = "Ajoutés récemment", played = "Vus récemment", title = "Titre", year = "Année", rating = "Note"
    var id: String { rawValue }

    func sort(_ list: [LibraryItem]) -> [LibraryItem] {
        switch self {
        case .added: return list.sorted { $0.added > $1.added }
        case .played: return list.sorted { $0.lastPlayed > $1.lastPlayed }
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: return list.sorted { ($0.media?.rating ?? 0) > ($1.media?.rating ?? 0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var tab: TopTab = .home
    @State private var search = ""
    @State private var path = NavigationPath()
    /// La barre s'efface quand on descend dans une page et revient dès qu'on remonte.
    @State private var barHidden = false
    @ObservedObject private var downloads = DownloadsModel.shared
    @ObservedObject private var tracker = TrackerModel.shared

    var body: some View {
        NavigationStack(path: $path) {
            page(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.backdrop)
                .overlay(alignment: .top) { TopScrim() }
                .navigationDestination(for: String.self) { id in
                    // l'image va jusqu'au bord, sous la barre d'outils, comme à l'accueil
                    destination(id)
                        .toolbarBackground(.hidden, for: .windowToolbar)
                        .overlay(alignment: .top) { TopScrim() }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TopBar(tab: $tab, downloading: downloadingCount, showIndexer: tracker.configured,
                               open: { path = NavigationPath(); path.append($0) })
                            .opacity(barHidden ? 0 : 1)
                            .allowsHitTesting(!barHidden)
                            .animation(.easeInOut(duration: 0.25), value: barHidden)
                    }
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .background(ScrollDirectionWatcher { down in if barHidden != down { barHidden = down } })
        // ⌘F : la recherche, d'où qu'on soit
        .background(Button("") { path = NavigationPath(); tab = .search; SearchFocus.request() }
            .keyboardShortcut("f", modifiers: .command).hidden())
        .onChange(of: tab) { _, _ in path = NavigationPath(); barHidden = false }
        .onChange(of: path) { _, _ in barHidden = false }
        .onChange(of: downloadingCount) { _, n in if n == 0 && tab == .downloads { tab = .home } }
        // .torrent ou magnet déposé sur la fenêtre : il apparaît dans la bibliothèque, avec sa fiche si on la trouve
        .onDrop(of: [.fileURL, .url, .text], isTargeted: nil) { DownloadsModel.shared.handleDrop($0) }
        .modifier(ManualAddSheets())
        .overlay(alignment: .bottom) { StatusPill() }
        .onReceive(EssaiHarness.shared.$serial) { _ in
            // copie d'essai seulement (STRAPONTIN_ESSAI) : navigation pilotée pour les captures
            switch EssaiHarness.shared.command {
            case .tab(let t)?: tab = t
            case .open(let v)?: path.append(v)
            case .back?: if !path.isEmpty { path.removeLast() }
            case .search(let q)?: tab = .search; search = q
            case .step?: break   // pour la fiche d'épisode
            case nil: break
            }
        }
        .background(BackNavigation { if !path.isEmpty { path.removeLast(); return true }; return false })
    }

    private var downloadingCount: Int { downloads.visibleEntries(store: store).filter { !$0.isDone }.count }

    @ViewBuilder
    private func page(_ t: TopTab) -> some View {
        switch t {
        case .search: SearchPage(search: $search)
        case .home: HomeView()
        case .movies: CategoryPage(kind: .movie)
        case .shows: CategoryPage(kind: .tv)
        case .discover: DiscoverView()
        case .downloads: GridPage(title: "En téléchargement", items: [],
                                  downloads: downloads.visibleEntries(store: store).filter { !$0.isDone })
        }
    }

    @ViewBuilder
    private func destination(_ id: String) -> some View {
        if id.hasPrefix("all:") {
            LibraryPage(kind: id == "all:tv" ? .tv : .movie)
        } else if let ep = EpisodeLink.parse(id) {
            EpisodeView(tmdbId: ep.tmdbId, season: ep.season, episode: ep.episode)
        } else if let (k, tmdbId) = TMDbLink.parse(id) ?? TMDbLink.parseKey(id) {
            // une seule page par fiche : aperçu tant qu'on ne l'a pas, fiche de la bibliothèque dès qu'elle arrive
            FicheView(kind: k, tmdbId: tmdbId)
        } else if id.hasPrefix("dl:") {
            DownloadDetailView(entryId: id)
        } else if id == "tracker" {
            TrackerView()
        } else if id == "storage" {
            StorageView()
        } else {
            DetailView(itemId: id)
        }
    }

}

/// La barre du haut, façon tvOS : loupe, onglets, réglages, dans une pastille translucide.
private struct TopBar: View {
    @Binding var tab: TopTab
    let downloading: Int
    let showIndexer: Bool
    let open: (String) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            icon("magnifyingglass", .search, help: "Recherche (⌘F)")
            ForEach([TopTab.home, .movies, .shows, .discover]) { item($0) }
            if downloading > 0 { item(.downloads, count: downloading) }
            Menu {
                SettingsLink { Text("Réglages…") }
                Button("Stockage") { open("storage") }
                if showIndexer { Button("Indexeur") { open("tracker") } }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.white.opacity(0.85))
            .help("Réglages, stockage")
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tab)
    }

    private func item(_ t: TopTab, count: Int? = nil) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 5) {
                Text(t.rawValue)
                if let count {
                    Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                }
            }
            .font(.system(size: 13, weight: tab == t ? .semibold : .medium))
            .foregroundStyle(tab == t ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 26)
            .background {
                if tab == t { Capsule().fill(.white.opacity(0.92)).matchedGeometryEffect(id: "sel", in: selection) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ name: String, _ t: TopTab, help: String) -> some View {
        Button { tab = t } label: {
            Image(systemName: name).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tab == t ? Color.black : Color.white.opacity(0.85))
                .frame(width: 30, height: 26)
                .background {
                    if tab == t { Capsule().fill(.white.opacity(0.92)).matchedGeometryEffect(id: "sel", in: selection) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Défilement vers le bas (contenu qui monte) : `true` ; vers le haut : `false`. Molette ou trackpad.
private struct ScrollDirectionWatcher: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak c = context.coordinator] e in
            guard let c, e.window === c.view?.window, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) else { return e }
            c.accumulated += e.scrollingDeltaY
            if c.accumulated < -40 { c.accumulated = 0; c.onChange(true) }
            if c.accumulated > 20 { c.accumulated = 0; c.onChange(false) }
            return e
        }
        context.coordinator.onChange = onChange
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.onChange = onChange }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var accumulated: CGFloat = 0
        var onChange: (Bool) -> Void = { _ in }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Voile sombre sous la barre d'outils : onglets et bouton retour restent lisibles sur une image claire.
private struct TopScrim: View {
    var body: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 110).ignoresSafeArea(edges: .top).allowsHitTesting(false)
    }
}

/// Retour arrière comme dans le Finder ou Safari : ⌘[, ⌘←, Échap (hors saisie de texte), bouton « précédent » de la souris.
private struct BackNavigation: NSViewRepresentable {
    let back: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak c = context.coordinator] e in
            guard let c, let win = c.view?.window, e.window === win, win.attachedSheet == nil else { return e }
            // les flèches portent aussi « fn » et « pavé numérique » : on ne garde que ⌘ ⌥ ⌃ ⇧
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let wants: Bool
            switch e.type {
            case .otherMouseDown: wants = e.buttonNumber == 3
            case .keyDown:
                let editing = win.firstResponder is NSText
                wants = (flags == .command && (e.charactersIgnoringModifiers == "[" || e.keyCode == 123))
                    || (flags.isEmpty && e.keyCode == 53 && !editing)
            default: wants = false
            }
            return wants && c.back() ? nil : e
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { context.coordinator.back = back }
    func makeCoordinator() -> Coordinator { Coordinator(back: back) }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    final class Coordinator {
        var back: () -> Bool
        weak var view: NSView?
        var monitor: Any?
        init(back: @escaping () -> Bool) { self.back = back }
    }
}

struct GenreRow: Identifiable {
    var id: String
    var items: [LibraryItem]

    static func rows(_ items: [LibraryItem]) -> [GenreRow] {
        var byGenre: [String: [LibraryItem]] = [:]
        for i in items { for g in i.media?.genres ?? [] { byGenre[g, default: []].append(i) } }
        return byGenre.filter { $0.value.count >= 2 }
            .map { GenreRow(id: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }
}

struct StatusPill: View {
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        Group {
            if !store.status.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.status.isEmpty)
    }
}

/// Page Films ou Séries : un grand visuel puis des rangées par genre, comme l'app TV.
struct CategoryPage: View {
    let kind: MediaKind
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let items = store.items.filter { $0.kind == kind }
        let genres = GenreRow.rows(items)
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if items.isEmpty {
                    // bibliothèque vide mais quelque chose arrive : on le montre quand même
                    DownloadingShelf(kind: kind).padding(.top, 90)
                    EmptyLibrary(kind: kind, compact: !DownloadsModel.shared.visibleEntries(kind: kind, store: store).isEmpty)
                } else {
                    HeroCarousel(items: Array(items.filter { $0.media?.backdropPath != nil }
                        .sorted { ($0.media?.rating ?? 0) > ($1.media?.rating ?? 0) }.prefix(6)))
                    DownloadingShelf(kind: kind)
                    let upNext = items.filter(\.inProgress).sorted { $0.lastPlayed > $1.lastPlayed }
                    if !upNext.isEmpty { Shelf(title: "À suivre") { ForEach(upNext) { LandscapeCard(item: $0) } } }
                    Shelf(title: "Ajoutés récemment") {
                        ForEach(SortOrder.added.sort(items).prefix(20)) { PosterCard(item: $0) }
                    }
                    ForEach(genres.prefix(8)) { g in
                        Shelf(title: g.id) { ForEach(g.items) { PosterCard(item: $0) } }
                    }
                    let unmatched = items.filter { $0.media == nil }
                    if !unmatched.isEmpty {
                        Shelf(title: "À identifier") { ForEach(unmatched) { PosterCard(item: $0) } }
                    }
                    NavigationLink(value: "all:\(kind.rawValue)") {
                        Label(kind == .movie ? "Tous les films" : "Toutes les séries", systemImage: "square.grid.3x3")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal, Theme.margin)
                }
            }
            .padding(.bottom, 50)
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// « Tous les films » / « Toutes les séries » : grille filtrable et triable (ancien onglet Bibliothèque, par type),
/// avec en tête les téléchargements qui n'ont pas encore d'entrée (en cours, non identifiés, en erreur).
struct LibraryPage: View {
    let kind: MediaKind
    @EnvironmentObject var store: LibraryStore
    @State private var filter: LibraryFilter = .all
    @State private var sort: SortOrder = .title
    @ObservedObject private var downloads = DownloadsModel.shared

    /// Téléchargements sans entrée dans la bibliothèque (pas encore arrivés, non identifiés, en erreur) : en tête de grille.
    private var pending: [DownloadEntry] {
        guard filter == .all || filter == .downloading || filter == .unmatched else { return [] }
        return downloads.visibleEntries(kind: kind, store: store).filter { e in
            (e.mediaKey.map { store.item(id: $0) == nil } ?? true) && (filter != .unmatched || !e.isIdentified)
        }
    }

    var body: some View {
        GridPage(title: kind == .tv ? "Toutes les séries" : "Tous les films",
                 items: sort.sort(store.items.filter { $0.kind == kind && filter.includes($0) }), downloads: pending) {
            Picker("Filtre", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Picker("Tri", selection: $sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
        }
        .background(Theme.background)
    }
}

struct GridPage<Controls: View>: View {
    let title: String
    let items: [LibraryItem]
    /// Téléchargements affichés avant les entrées de la bibliothèque.
    var downloads: [DownloadEntry] = []
    @ViewBuilder var controls: () -> Controls
    /// Contenu sous la grille, dans le même défilement (ex. rangée « Sur TMDb » de la recherche).
    var footer: AnyView?
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 28)]

    init(title: String, items: [LibraryItem], downloads: [DownloadEntry] = [], footer: AnyView? = nil,
         @ViewBuilder controls: @escaping () -> Controls) {
        self.title = title
        self.items = items
        self.downloads = downloads
        self.footer = footer
        self.controls = controls
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    if !(items.isEmpty && downloads.isEmpty && footer != nil) {
                        Text("\(items.count + downloads.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls()
                }
                if items.isEmpty && downloads.isEmpty {
                    // recherche : sans résultat dans la bibliothèque, on passe directement au catalogue (pied de page)
                    if footer == nil {
                        ContentUnavailableView("Rien ici", systemImage: "film.stack").padding(.top, 80)
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                    ForEach(downloads) { DownloadPosterCard(entry: $0, fixedWidth: nil) }
                    ForEach(items) { PosterCard(item: $0, fixedWidth: nil) }
                }
                if let footer { footer.padding(.top, items.isEmpty && downloads.isEmpty ? -12 : 12) }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 28)
        }
    }
}

extension GridPage where Controls == EmptyView {
    init(title: String, items: [LibraryItem], downloads: [DownloadEntry] = []) {
        self.init(title: title, items: items, downloads: downloads) { EmptyView() }
    }
}

struct EmptyLibrary: View {
    var kind: MediaKind?
    /// Sous une rangée « En téléchargement » : moins d'espace au-dessus.
    var compact = false
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: kind == nil ? "chair.fill" : "play.tv").font(.system(size: 60, weight: .thin))
                .foregroundStyle(kind == nil ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
            Text(kind == .tv ? "Aucune série pour l'instant" : kind == .movie ? "Aucun film pour l'instant" : "Installez-vous")
                .font(.system(size: 24, weight: .bold))
            Text("Dépose tes films dans Documents › Films et tes séries dans Documents › Séries :\nils apparaissent ici tout seuls, avec leur fiche.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if store.isScanning { ProgressView().padding(.top, 6) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 30 : 180)
    }
}
