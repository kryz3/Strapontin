import StrapontinCore
import SwiftUI

/// Fiches de films et séries qu'on n'a pas : onglet « Découvrir », résultats TMDb de la recherche,
/// et fiche d'aperçu avec Télécharger / Suivre.
///
/// Navigation : la valeur "tmdb:movie:123" / "tmdb:tv:123" ouvre `PreviewDetailView`.
enum TMDbLink {
    static func value(_ kind: MediaKind, _ id: Int) -> String { "tmdb:\(kind.rawValue):\(id)" }
    static func parse(_ s: String) -> (MediaKind, Int)? {
        let p = s.split(separator: ":")
        guard p.count == 3, p[0] == "tmdb", let k = MediaKind(rawValue: String(p[1])), let id = Int(p[2]) else { return nil }
        return (k, id)
    }
    /// Clé de fiche (« movie:123 »).
    static func parseKey(_ s: String) -> (MediaKind, Int)? {
        let p = s.split(separator: ":")
        guard p.count == 2, let k = MediaKind(rawValue: String(p[0])), let id = Int(p[1]) else { return nil }
        return (k, id)
    }
}

/// La page d'une fiche, quelle que soit la porte d'entrée (affiche, recherche, téléchargement) : la fiche de la
/// bibliothèque si on l'a (y compris après une correction : elle suit la redirection), sinon l'aperçu avec
/// Télécharger. Quand un téléchargement arrive, ou qu'on supprime le film, la page bascule d'elle-même.
struct FicheView: View {
    let kind: MediaKind
    let tmdbId: Int
    @EnvironmentObject var store: LibraryStore
    /// On ne suit une redirection que si cette page montrait le titre : sinon, après une correction A → B,
    /// ouvrir A depuis la recherche afficherait B.
    @State private var wasOwned = false

    var body: some View {
        let key = Media.key(kind, tmdbId)
        let here = store.item(id: key)
        let shown = here ?? (wasOwned ? store.resolve(key) : nil)
        ZStack {
            if let shown, shown.id != key {
                DetailView(itemId: shown.id).transition(.opacity)
            } else if kind == .tv {
                // série : une seule page, possédée ou non (rien ne saute quand le premier épisode arrive)
                SeriesFicheView(tmdbId: tmdbId).id(key)
            } else if let shown {
                DetailView(itemId: shown.id).transition(.opacity)
            } else {
                PreviewDetailView(kind: kind, tmdbId: tmdbId).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: kind == .tv && (shown == nil || shown?.id == key) ? key : shown?.id)
        .onAppear { if here != nil { wasOwned = true } }
        .onChange(of: here != nil) { _, now in if now { wasOwned = true } }
    }
}

@MainActor
private func tmdbClient() -> TMDbClient? {
    let s = AppSettings.shared
    return s.effectiveTMDbKey.isEmpty ? nil : TMDbClient(key: s.effectiveTMDbKey, language: s.tmdbLanguage, omdbKey: s.omdbKey)
}

/// « Découvrir » : suivis, tendances et populaires du catalogue TMDb. La recherche est celle de la barre d'outils.
struct DiscoverView: View {
    @StateObject private var tracker = TrackerModel.shared
    @State private var rows: [(String, [TMDbSearchResult])] = []
    @State private var error: String?

    private var followed: [TMDbSearchResult] {
        tracker.follows.reversed().map {
            TMDbSearchResult(kind: $0.kind, tmdbId: $0.tmdbId, title: $0.title, year: $0.year, posterPath: $0.posterPath)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Découvrir").font(.system(size: 30, weight: .bold))
                    .padding(.horizontal, Theme.margin)
                if let error { Text(error).foregroundStyle(.orange).padding(.horizontal, Theme.margin) }
                TMDbShelf(title: "Suivis", results: followed)
                if rows.isEmpty && error == nil {
                    ForEach(["Films tendance", "Séries tendance", "Films populaires"], id: \.self) { SkeletonShelf(title: $0) }
                }
                ForEach(rows, id: \.0) { title, items in
                    TMDbShelf(title: title, results: items)
                }
            }
            .padding(.top, 70)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .task {
            guard rows.isEmpty, let c = tmdbClient() else { return }
            let t0 = ContinuousClock.now
            defer { Perf.log("découvrir", since: t0) }
            do {
                async let tm = c.trending(.movie)
                async let tt = c.trending(.tv)
                async let pm = c.popular(.movie)
                async let pt = c.popular(.tv)
                rows = [("Films tendance", try await tm), ("Séries tendance", try await tt),
                        ("Films populaires", try await pm), ("Séries populaires", try await pt)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// ⌘F (ou la loupe) : demande le curseur dans le champ de la page Recherche.
enum SearchFocus {
    static let name = Notification.Name("strapontin.search.focus")
    static func request() {
        // après le changement d'onglet : la page doit exister pour recevoir la demande
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NotificationCenter.default.post(name: name, object: nil) }
    }
}

/// Page Recherche, façon tvOS : un grand champ en haut (le seul de l'app), puis ce qu'on a déjà (bibliothèque,
/// téléchargements) et tout le catalogue TMDb en affiches, avec les pastilles de l'indexeur. Le texte est gardé par
/// ContentView : on retrouve ses résultats en revenant d'une fiche.
struct SearchPage: View {
    @Binding var search: String
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var downloads = DownloadsModel.shared
    @FocusState private var focused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if query.isEmpty {
                    Text("Cherche un film, une série, un acteur ou un genre : dans ta bibliothèque et dans tout le catalogue.")
                        .foregroundStyle(.secondary).padding(.horizontal, Theme.margin)
                } else {
                    libraryResults
                    TMDbSearchSections(query: query)
                }
            }
            .padding(.top, 172)   // sous le champ fixe (barre d'outils + champ + fondu)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        // le champ reste en haut, comme sur l'Apple TV : les résultats passent dessous, dans un fondu
        .overlay(alignment: .top) {
            field.padding(.horizontal, Theme.margin).padding(.top, 62).padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background, location: 0.8),
                                                   .init(color: Theme.background.opacity(0), location: 1)],
                                           startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top))
        }
        .onAppear { if query.isEmpty { focused = true } }
        .onReceive(NotificationCenter.default.publisher(for: SearchFocus.name)) { _ in focused = true }
    }

    @ViewBuilder private var libraryResults: some View {
        let mine = LibrarySearch.items(store, query)
        let dls = LibrarySearch.downloads(downloads, store, query)
        if !mine.isEmpty || !dls.isEmpty {
            Shelf(title: "Dans ta bibliothèque") {
                ForEach(dls) { DownloadPosterCard(entry: $0) }
                ForEach(mine) { PosterCard(item: $0) }
            }
        }
    }

    /// Grand champ arrondi, comme la recherche de l'app TV.
    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Films, séries, acteurs, genres…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 20, weight: .medium))
                .focused($focused)
                .onExitCommand { search = ""; focused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Effacer")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .frame(maxWidth: 720)
        // fond opaque : les affiches qui défilent dessous ne transparaissent pas dans le champ
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: focused ? 0.19 : 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(focused ? Theme.accentText.opacity(0.6) : .white.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Recherche dans ce qu'on a : la même pour la barre d'outils et Découvrir.
@MainActor
enum LibrarySearch {
    static func fold(_ s: String) -> String { CatalogSearch.fold(s) }

    static func items(_ store: LibraryStore, _ query: String) -> [LibraryItem] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        return store.items.filter { fold(searchText($0)).contains(q) }
    }

    /// Texte cherché pour une entrée : titres, genres, année, premiers acteurs.
    private static func searchText(_ i: LibraryItem) -> String {
        var parts: [String] = [i.title]
        if let m = i.media {
            parts.append(m.originalTitle ?? "")
            parts.append(m.genres.joined(separator: " "))
            let cast: [String] = (m.cast ?? []).prefix(5).map { $0.name }
            parts.append(cast.joined(separator: " "))
        }
        if let y = i.year { parts.append(String(y)) }
        return parts.joined(separator: " ")
    }

    static func rank(_ results: [TMDbSearchResult], _ query: String) -> [TMDbSearchResult] { CatalogSearch.rank(results, query) }

    /// Téléchargements pas encore dans la bibliothèque dont le titre correspond.
    static func downloads(_ downloads: DownloadsModel, _ store: LibraryStore, _ query: String) -> [DownloadEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let folded = fold(q)
        return downloads.visibleEntries(store: store).filter { e in
            if let key = e.mediaKey, store.item(id: key) != nil { return false }
            let text: String = [e.title, e.media?.originalTitle ?? "", e.torrents.first?.name ?? ""].joined(separator: " ")
            return fold(text).contains(folded)
        }
    }
}

/// Résultats TMDb de la recherche : une section Films et une section Séries, affichées tout de suite (squelettes),
/// remplies chacune dès que sa réponse arrive ; puis les pastilles de l'indexeur, sans bloquer les affiches.
/// Saisie « calmée » (300 ms) et requêtes annulées quand le texte change : une ancienne réponse n'écrase jamais
/// la nouvelle.
struct TMDbSearchSections: View {
    let query: String
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var tracker = TrackerModel.shared

    enum Phase: Equatable { case loading, done([TMDbSearchResult]), failed(String) }
    @State private var phases: [MediaKind: Phase] = [.movie: .loading, .tv: .loading]
    /// Acteurs, réalisateurs… (nil = en cours).
    @State private var people: [TMDbPerson]?
    @State private var availability: [String: Int] = [:]
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            // on cherche quelqu'un (« keanu », « villeneuve ») : ses fiches d'abord, puis les titres
            if peopleFirst { peopleSection }
            section(.movie, title: "Films")
            section(.tv, title: "Séries")
            if !peopleFirst { peopleSection }
        }
        // une tâche par texte cherché : la précédente est annulée, et une réponse n'est appliquée que si elle
        // correspond encore au texte affiché
        .onChange(of: query, initial: true) { _, q in
            job?.cancel()
            job = Task { await run(q) }
        }
        .onDisappear { job?.cancel() }
    }

    @State private var job: Task<Void, Never>?

    @ViewBuilder private func section(_ kind: MediaKind, title: String) -> some View {
        switch phases[kind] ?? .loading {
        case .loading:
            SkeletonShelf(title: title)
        case .failed(let message):
            SectionMessage(title: title, message: message, icon: "exclamationmark.triangle")
        case .done(let results) where results.isEmpty:
            SectionMessage(title: title, message: kind == .movie ? "Aucun film trouvé." : "Aucune série trouvée.")
        case .done(let results):
            VStack(alignment: .leading, spacing: 0) {
                TMDbShelf(title: title, results: results,
                          availability: availability.isEmpty ? nil : availability.merging(tracker.availabilityById) { _, f in f })
                if checking {
                    Label("Vérification sur l'indexeur…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.margin).padding(.top, 6)
                }
            }
        }
    }

    private func load(_ kind: MediaKind, client c: TMDbClient, query: String, since t0: ContinuousClock.Instant) async -> [TMDbSearchResult] {
        do {
            let list = try await c.search(kind, title: query, year: nil)
            guard !Task.isCancelled, query == self.query else { return [] }
            withAnimation(.easeOut(duration: 0.2)) { phases[kind] = .done(LibrarySearch.rank(list, query)) }
            Perf.log("recherche TMDb \(kind == .movie ? "films" : "séries") « \(query) »", since: t0)
            return list
        } catch {
            guard !Task.isCancelled, query == self.query else { return [] }
            phases[kind] = .failed("TMDb ne répond pas (\(error.localizedDescription)).")
            return []
        }
    }

    /// La recherche vise une personne : la première trouvée porte le texte tapé et est connue.
    private var peopleFirst: Bool {
        guard let first = people?.first else { return false }
        let q = CatalogSearch.fold(query.trimmingCharacters(in: .whitespaces))
        return q.count >= 3 && CatalogSearch.fold(first.name).contains(q) && first.popularity >= 3 && first.profilePath != nil
    }

    private func loadPeople(client c: TMDbClient, query: String) async {
        let found = (try? await c.searchPeople(query)) ?? []
        guard !Task.isCancelled, query == self.query else { return }
        // les personnes connues pour leurs rôles d'abord, sans les fiches vides
        withAnimation(.easeOut(duration: 0.2)) {
            people = found.filter { $0.profilePath != nil || !$0.knownFor.isEmpty }.prefix(20).map { $0 }
        }
    }

    @ViewBuilder private var peopleSection: some View {
        if people == nil, query.count >= 2 {
            Shelf(title: "Acteurs et équipe") {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(spacing: 8) { Skeleton(corner: 60).frame(width: 110, height: 110); Skeleton(corner: 4).frame(width: 80, height: 10) }
                }
            }
            .allowsHitTesting(false)
        } else if let people, !people.isEmpty {
            Shelf(title: "Acteurs et équipe") {
                ForEach(people) { PersonCard(person: $0) }
            }
        }
    }

    private func run(_ query: String) async {
        phases = [.movie: .loading, .tv: .loading]
        people = nil
        availability = [:]
        checking = false
        try? await Task.sleep(nanoseconds: 300_000_000)   // on attend que la frappe se calme
        guard !Task.isCancelled else { return }
        guard query.count >= 2 else { phases = [.movie: .done([]), .tv: .done([])]; return }
        guard let c = tmdbClient() else {
            phases = [.movie: .failed("Ajoute une clé TMDb dans les réglages."), .tv: .failed("Ajoute une clé TMDb dans les réglages.")]
            return
        }
        let t0 = ContinuousClock.now
        // films et séries en parallèle ; chaque section s'affiche dès que sa propre réponse arrive
        async let movies = load(.movie, client: c, query: query, since: t0)
        async let shows = load(.tv, client: c, query: query, since: t0)
        async let persons: Void = loadPeople(client: c, query: query)
        let all = await movies + shows
        _ = await persons
        guard !Task.isCancelled, query == self.query, tracker.configured else { return }
        let notOwned = all.filter { store.media[Media.key($0.kind, $0.id)] == nil }
        guard !notOwned.isEmpty else { return }
        checking = true
        let counts = await tracker.availability(query: query, for: notOwned)
        guard !Task.isCancelled else { return }
        withAnimation { availability = counts; checking = false }
    }
}

struct TMDbShelf: View {
    let title: String
    let results: [TMDbSearchResult]
    var grid = false
    var availability: [String: Int]? = nil

    var body: some View {
        if !results.isEmpty, grid {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 21, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 26)], alignment: .leading, spacing: 30) {
                    ForEach(results) { r in
                        TMDbPosterCard(result: r, versions: availability?[Media.key(r.kind, r.id)])
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
        } else if !results.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 21, weight: .bold)).padding(.horizontal, Theme.margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(results) { r in
                            TMDbPosterCard(result: r, versions: availability?[Media.key(r.kind, r.id)])
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
            }
        }
    }
}

struct TMDbPosterCard: View {
    let result: TMDbSearchResult
    /// Versions trouvées sur l'indexeur (nil = pas vérifié) : pastille sous l'affiche.
    var versions: Int? = nil
    @EnvironmentObject var store: LibraryStore
    @State private var hover = false

    var owned: Bool { store.media[Media.key(result.kind, result.id)] != nil }

    var body: some View {
        // même page pour tout le monde (FicheView choisit la fiche de la bibliothèque ou l'aperçu)
        NavigationLink(value: Media.key(result.kind, result.id)) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                    if result.posterPath == nil {
                        // pas d'affiche sur TMDb : titre et année plutôt qu'un rectangle vide
                        GenericPoster(title: result.title, kind: result.kind, subtitle: result.year.map(String.init))
                    } else {
                        RemoteImage(url: TMDbClient.imageURL(result.posterPath, size: "w342"))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if owned {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                            .foregroundStyle(.white, Color.black.opacity(0.55)).padding(8).help("Déjà dans ta bibliothèque")
                    }
                }
                .overlay { DownloadOverlay(mediaKey: Media.key(result.kind, result.id)) }
                .overlay(alignment: .bottomLeading) {
                    if !owned, let n = versions {
                        Badge(text: n > 0 ? "\(n) VERSION\(n > 1 ? "S" : "")" : "INDISPONIBLE",
                              color: n > 0 ? Theme.accent : .black.opacity(0.6))
                            .padding(8)
                            .help(n > 0 ? "Disponible : ouvre la fiche pour télécharger" : "Pas encore sur l'indexeur (la fiche permet de suivre sa sortie)")
                    }
                }
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
                Text(result.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([result.kind == .tv ? "Série" : "Film", result.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.18)) { hover = h }
            // survol : la fiche et son grand visuel sont chargés d'avance, l'ouverture est immédiate
            if h, !owned, let c = tmdbClient() {
                let kind = result.kind, id = result.id
                Task.detached(priority: .utility) {
                    if let m = try? await c.details(kind, id: id) {
                        await RemoteImageLoader.shared.prefetch(TMDbClient.imageURL(m.backdropPath, size: "w1280"))
                    }
                }
            }
        }
    }
}

/// Fiche d'un film qu'on n'a pas (séries : SeriesFicheView) : même mise en page que DetailView,
/// avec « Télécharger » (la meilleure version d'un clic), la progression, puis « Lire » quand c'est arrivé.
struct PreviewDetailView: View {
    let kind: MediaKind
    let tmdbId: Int
    @EnvironmentObject var store: LibraryStore
    @StateObject private var tracker = TrackerModel.shared
    @StateObject private var downloads = DownloadsModel.shared
    @State private var media: Media?
    @State private var error: String?
    @State private var versions: [RankedRelease] = []
    @State private var loadingVersions = false
    @State private var versionsError: String?

    private var key: String { Media.key(kind, tmdbId) }
    @State private var scrollToVersions = false
    @State private var showAllVersions = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let m = media {
                    VStack(alignment: .leading, spacing: 44) {
                        hero(m)
                        DownloadPanel(entryId: key)
                        if tracker.configured { versionsSection(m).id("versions") }
                    }
                    .padding(.bottom, 60)
                    .onChange(of: scrollToVersions) { _, go in
                        if go { withAnimation { proxy.scrollTo("versions", anchor: .top) }; scrollToVersions = false }
                    }
                } else if let error {
                    ContentUnavailableView("Fiche indisponible", systemImage: "exclamationmark.triangle", description: Text(error))
                        .padding(.top, 120)
                } else {
                    FicheSkeleton()
                }
            }
            .ignoresSafeArea(edges: .top)
            .background(Theme.background)
            .task {
                guard media == nil, let c = tmdbClient() else { return }
                let t0 = ContinuousClock.now
                do {
                    let m = try await c.details(kind, id: tmdbId)
                    media = m
                    Perf.log("fiche \(kind.rawValue):\(tmdbId)", since: t0)
                    await loadVersions(m)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    // MARK: en-tête

    private func hero(_ m: Media) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if m.backdropPath != nil {
                    RemoteImage(url: TMDbClient.imageURL(m.backdropPath, size: "w1280"))
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    LinearGradient(colors: [Color(white: 0.2), Theme.background], startPoint: .top, endPoint: .bottom)
                }
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.background.opacity(0.9), location: 0.88),
                                       .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))

                VStack(alignment: .leading, spacing: 14) {
                    LogoOrTitle(logoPath: m.logoPath, title: m.title, maxWidth: 480, maxHeight: 160, fontSize: 52)
                    HStack(spacing: 8) {
                        Text((["Film", m.year.map(String.init)].compactMap { $0 } + m.genres.prefix(3))
                            .joined(separator: " · "))
                        if let c = m.certification { SpecBadge(text: c) }
                        if let r = m.imdbRating ?? m.rating.map({ String(format: "%.1f", $0) }) { Text("★ \(r)") }
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    if let t = m.tagline, !t.isEmpty { Text(t).font(.system(size: 14, weight: .medium).italic()).foregroundStyle(.white.opacity(0.7)) }
                    if let o = m.overview, !o.isEmpty {
                        Text(o).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(4).frame(maxWidth: 560, alignment: .leading)
                    }
                    primaryActions(m).padding(.top, 8)
                    if let e = tracker.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange) }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 40)
            }
        }
        .frame(height: 620)
    }

    /// Le bouton principal change selon l'état : Télécharger → 42 % → Lire.
    @ViewBuilder
    private func primaryActions(_ m: Media) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) { primaryButtons(m) }
            if let e = tracker.grabErrors[key] {
                Label("Téléchargement impossible : \(e)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func primaryButtons(_ m: Media) -> some View {
            if let item = store.item(id: key) {
                // arrivé dans la bibliothèque (la page bascule aussi d'elle-même sur la fiche complète)
                PlayPill(title: "Lire") { play(item, resume: false) }
            } else if let t = activeTorrent {
                DownloadPill(progress: t.progress, label: t.isDone ? "Ajout à la bibliothèque…" : pillLabel(t))
                    .help(t.name)
                if !t.isDone {
                    Button { t.phase == .paused ? downloads.resume([t.hash]) : downloads.pause([t.hash]) } label: {
                        Image(systemName: t.phase == .paused ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(CircleButtonStyle()).help(t.phase == .paused ? "Reprendre" : "Mettre en pause")
                }
            } else if tracker.pending.contains(key) {
                DownloadPill(progress: nil, label: "Envoi au téléchargement…")
            } else if !tracker.configured {
                SettingsLink {
                    Label("Brancher un indexeur pour télécharger", systemImage: "gearshape").font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Renseigne ton indexeur dans Réglages › Indexeur")
            } else if let best = versions.first(where: { $0.score != nil }) {
                PlayPill(title: "Télécharger", icon: "arrow.down") {
                    tracker.grab(best, media: m)
                }
                .help(best.item.releaseName)
            } else if !versions.isEmpty {
                // des versions existent mais aucune ne colle aux préférences : on mène à la liste plutôt que rien
                PlayPill(title: "Choisir une version", icon: "list.bullet") { scrollToVersions = true }
                    .help("Aucune version ne correspond à tes préférences (langue, qualité, sources). Choisis-en une dans la liste.")
            } else if loadingVersions {
                ProgressView().controlSize(.small)
            }
            if tracker.configured { followButton(m) }
    }

    @ViewBuilder
    private func followButton(_ m: Media) -> some View {
        let followed = tracker.isFollowed(m)
        if followed {
            Button { tracker.unfollow(m.key) } label: { Image(systemName: "bell.fill").font(.system(size: 15, weight: .bold)) }
                .buttonStyle(CircleButtonStyle()).help("Suivi : touche pour ne plus suivre")
        } else {
            Button { tracker.follow(m, backfill: true) } label: { Image(systemName: "bell").font(.system(size: 15, weight: .bold)) }
                .buttonStyle(CircleButtonStyle()).help("Télécharger tout seul dès qu'une bonne version sort")
        }
    }

    /// « 42 % · 3,2 Mo/s · 5 min » pendant le téléchargement, sinon l'état (« En pause », « En attente de sources »…).
    private func pillLabel(_ t: Torrent) -> String {
        let pct = "\(Int(t.progress * 100)) %"
        guard t.dlspeed > 0 else { return "\(pct) · \(t.stateLabel)" }
        return ([pct, "\(humanSize(t.dlspeed))/s", etaText(t.eta)].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    /// Torrent de cette fiche chez le moteur : rattaché à la fiche (envoyé d'ici, glissé-déposé et reconnu…),
    /// ou une des versions listées. Les torrents en cours passent avant ceux qui sont finis.
    private var activeTorrent: Torrent? {
        let linked = downloads.torrents(for: key)
        if let t = linked.first(where: { !$0.isDone }) ?? linked.first { return t }
        let mine = tracker.hashes(for: key)
        if let t = mine.lazy.compactMap({ h in downloads.torrents.first { $0.hash.lowercased() == h } }).first { return t }
        let hashes = Set(versions.compactMap { $0.item.infoHash?.lowercased() })
        return downloads.torrents.first { hashes.contains($0.hash.lowercased()) }
    }

    // MARK: versions

    private func versionsSection(_ m: Media) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Versions disponibles").font(.system(size: 21, weight: .bold))
                if !versions.isEmpty {
                    Text("\(versions.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                }
                if loadingVersions { ProgressView().controlSize(.small) }
                Spacer()
                // dépannage seulement : la fiche cherche déjà toute seule
                NavigationLink(value: "tracker") { Text("Chercher autrement sur l'indexeur…").font(.system(size: 12)) }
                    .buttonStyle(.link)
                    .simultaneousGesture(TapGesture().onEnded { tracker.searchContext = m })
            }
            if let versionsError {
                Label(versionsError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if !loadingVersions && versions.isEmpty {
                Text("Rien sur l'indexeur pour l'instant. Active le suivi (cloche) pour le récupérer dès sa sortie.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Array(versions.prefix(showAllVersions ? versions.count : 8).enumerated()), id: \.element.id) { i, r in
                    ReleaseRow(release: r, recommended: i == 0 && r.score != nil, sent: tracker.isSent(r)) {
                        tracker.grab(r, media: m)
                    }
                }
            }
            if versions.count > 8 {
                Button(showAllVersions ? "Moins de versions" : "Afficher les \(versions.count) versions") {
                    withAnimation { showAllVersions.toggle() }
                }
                .buttonStyle(.link).font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func loadVersions(_ m: Media) async {
        loadingVersions = true
        versionsError = nil
        do { versions = try await tracker.versions(for: m) }
        catch { versionsError = error.localizedDescription; versions = [] }
        loadingVersions = false
    }
}

/// Une version trouvée sur l'indexeur, présentée comme les « Versions » de DetailView : badges, taille, sources.
struct ReleaseRow: View {
    let release: RankedRelease
    let recommended: Bool
    let sent: Bool
    /// Raison de ne pas la proposer (épisode déjà en route…).
    var blocked: String? = nil
    let download: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: download) {
            HStack(spacing: 14) {
                Image(systemName: sent ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(sent ? Color.green : .white.opacity(release.score == nil ? 0.4 : 0.9))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if recommended { Badge(text: "RECOMMANDÉ", color: Theme.accent) }
                        ForEach(badges, id: \.self) { SpecBadge(text: $0) }
                        if release.info.isSeasonPack { SpecBadge(text: "SAISON COMPLÈTE") }
                        else if let r = release.info.episodes {
                            SpecBadge(text: r.count > 1 ? "ÉPISODES \(r.lowerBound) À \(r.upperBound)" : "ÉPISODE \(r.lowerBound)")
                        }
                    }
                    Text(release.item.releaseName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(humanSize(release.item.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    HStack(spacing: 4) {
                        Circle().fill(seedColor).frame(width: 6, height: 6)
                        Text("\(release.item.seeders ?? 0) source\((release.item.seeders ?? 0) > 1 ? "s" : "")").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sent || blocked != nil)
        .opacity(blocked != nil && !sent ? 0.45 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(blocked ?? (release.score == nil ? "Ne correspond pas à tes préférences (langue, qualité ou sources), mais tu peux la prendre quand même." : "Télécharger cette version"))
        .contextMenu {
            if !sent, blocked == nil { Button("Télécharger") { download() } }
            if let u = release.item.detailsURL.flatMap(URL.init(string:)) { Link("Voir sur l'indexeur", destination: u) }
        }
    }

    private var badges: [String] {
        var b: [String] = []
        switch release.info.resolution { case 2160?: b.append("4K"); case 1080?: b.append("HD 1080p"); case 720?: b.append("720p"); default: break }
        let q = release.item.releaseName.lowercased()
        if q.range(of: #"\bdv\b|dolby.?vision|\bdovi\b"#, options: .regularExpression) != nil { b.append("DOLBY VISION") }
        else if q.contains("hdr") { b.append("HDR") }
        if q.contains("atmos") { b.append("ATMOS") }
        if q.contains("remux") { b.append("REMUX") }
        if let l = release.info.language { b.append(l.rawValue.uppercased()) }
        return b
    }

    private var seedColor: Color {
        switch release.item.seeders ?? 0 { case 0: return .red; case 1...4: return .orange; default: return .green }
    }
}

/// Pilule de progression à la place de « Télécharger ».
struct DownloadPill: View {
    /// nil : pas encore de pourcentage (envoi en cours)
    let progress: Double?
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(.white)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
            Text(label).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }
}

/// Même liste de versions, en feuille, pour les fiches de la bibliothèque (autre qualité, épisodes manquants).
struct TrackerResultsSheet: View {
    let media: Media
    @Binding var isPresented: Bool
    @StateObject private var tracker = TrackerModel.shared
    @State private var versions: [RankedRelease] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Versions disponibles").font(.system(size: 19, weight: .bold))
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Fermer") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            if let e = tracker.error ?? tracker.grabErrors[media.key] { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if !loading && versions.isEmpty { Text("Rien trouvé sur l'indexeur.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { i, r in
                        ReleaseRow(release: r, recommended: i == 0 && r.score != nil, sent: tracker.isSent(r)) {
                            tracker.grab(r, media: media)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .background(Theme.background)
        .task {
            do { versions = try await tracker.versions(for: media) } catch { tracker.error = error.localizedDescription }
            loading = false
        }
    }
}

/// Fiche en cours de chargement : la forme de la page (grand visuel, titre, boutons), sans sablier.
struct FicheSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Skeleton(corner: 0).frame(height: 520)
            VStack(alignment: .leading, spacing: 12) {
                Skeleton(corner: 6).frame(width: 340, height: 34)
                Skeleton(corner: 4).frame(width: 260, height: 12)
                HStack(spacing: 12) {
                    Skeleton(corner: 20).frame(width: 110, height: 40)
                    Skeleton(corner: 20).frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
        .allowsHitTesting(false)
    }
}

/// Une personne dans la recherche : photo ronde, nom, et un ou deux titres connus.
struct PersonCard: View {
    let person: TMDbPerson
    @State private var hover = false

    var body: some View {
        NavigationLink(value: PersonLink.value(person.id)) {
            VStack(spacing: 8) {
                PersonPhoto(path: person.profilePath, name: person.name, size: 110)
                    .scaleEffect(hover ? 1.05 : 1)
                    .shadow(color: .black.opacity(hover ? 0.45 : 0.2), radius: hover ? 12 : 5, y: 4)
                Text(person.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(person.knownFor.prefix(2).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 130)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Photo ronde d'une personne, ou ses initiales.
struct PersonPhoto: View {
    let path: String?
    let name: String
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.18))
            Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.system(size: size * 0.23, weight: .semibold)).foregroundStyle(.secondary)
            RemoteImage(url: TMDbClient.imageURL(path, size: size > 140 ? "h632" : "w185")).clipShape(Circle())
        }
        .frame(width: size, height: size)
    }
}

enum PersonLink {
    static func value(_ id: Int) -> String { "person:\(id)" }
    static func parse(_ s: String) -> Int? {
        guard s.hasPrefix("person:") else { return nil }
        return Int(s.dropFirst("person:".count))
    }
}

/// Page d'une personne : photo, biographie, filmographie (films et séries, ceux de la bibliothèque cochés).
struct PersonView: View {
    let personId: Int
    @State private var details: TMDbPersonDetails?
    @State private var error: String?
    @State private var showBio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if let d = details {
                    header(d)
                    TMDbShelf(title: "Filmographie", results: d.credits, grid: true)
                } else if let error {
                    ContentUnavailableView("Fiche indisponible", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text(error)).padding(.top, 140)
                } else {
                    HStack(alignment: .top, spacing: 30) {
                        Skeleton(corner: 110).frame(width: 220, height: 220)
                        VStack(alignment: .leading, spacing: 12) {
                            Skeleton(corner: 6).frame(width: 300, height: 34)
                            Skeleton(corner: 4).frame(width: 220, height: 12)
                            Skeleton(corner: 4).frame(maxWidth: 560).frame(height: 70)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                    SkeletonShelf(title: "Filmographie")
                }
            }
            .padding(.top, 96).padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.backdrop)
        .task(id: personId) {
            guard details == nil else { return }
            guard let c = tmdbClient() else { error = "Ajoute une clé TMDb dans les réglages."; return }
            do { details = try await c.person(personId) } catch { self.error = error.localizedDescription }
        }
    }

    private func header(_ d: TMDbPersonDetails) -> some View {
        HStack(alignment: .top, spacing: 30) {
            PersonPhoto(path: d.person.profilePath, name: d.person.name, size: 220)
            VStack(alignment: .leading, spacing: 10) {
                Text(d.person.name).font(.system(size: 36, weight: .bold))
                let facts = [Self.department(d.person.department), Self.birth(d.birthday, d.placeOfBirth)].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if !d.biography.isEmpty {
                    Text(d.biography).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(showBio ? nil : 6).frame(maxWidth: 640, alignment: .leading)
                    Button(showBio ? "Moins" : "Lire la suite") { withAnimation { showBio.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                }
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    static func department(_ d: String?) -> String? {
        switch d {
        case "Acting": return "Acteur, actrice"
        case "Directing": return "Réalisation"
        case "Writing": return "Scénario"
        case "Production": return "Production"
        case nil: return nil
        default: return d
        }
    }

    static func birth(_ date: String?, _ place: String?) -> String? {
        guard let date, !date.isEmpty else { return place }
        let y = date.prefix(4)
        return place.map { "Né(e) en \(y) · \($0)" } ?? "Né(e) en \(y)"
    }
}
