import StrapontinCore
import SwiftUI

/// « Pour toi » : quand on ne sait pas quoi regarder, un fil de programmes choisis d'après ses goûts.
///
/// Tout se calcule sur ce Mac, à partir de la bibliothèque, de ce qui a été regardé (et combien de temps), de
/// Ma liste et des réactions (J'aime, Pas pour moi, Déjà vu). Seules partent les requêtes TMDb habituelles
/// (recommandations, découverte), mises en cache.
@MainActor
final class ForYouModel: ObservableObject {
    static let shared = ForYouModel()

    @Published private(set) var cards: [TMDbPick] = []
    @Published private(set) var loading = false
    @Published private(set) var details: [String: Media] = [:]
    @Published private(set) var reactions: [String: Stored] = [:]
    /// Téléchargement lancé depuis une carte : « Envoi… », puis le résultat.
    @Published private(set) var downloadState: [String: String] = [:]
    @Published var error: String?

    struct Stored: Codable {
        var reaction: FeedReaction
        var kind: MediaKind
        var genreIds: [Int]
        var year: Int?
        var title: String
        var tmdbId: Int
        var date: Date
    }

    private let defaultsKey = "forYouReactions"
    private var genreMaps: [MediaKind: [String: Int]] = [:]
    private var page = 1
    private var shown = Set<String>()

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let r = try? JSONDecoder().decode([String: Stored].self, from: data) { reactions = r }
    }

    private func client() -> TMDbClient? {
        let s = AppSettings.shared
        return s.effectiveTMDbKey.isEmpty ? nil : TMDbClient(key: s.effectiveTMDbKey, language: s.tmdbLanguage, omdbKey: s.omdbKey)
    }

    // MARK: fil

    func loadIfNeeded() async { if cards.isEmpty && !loading { await rebuild() } }

    func rebuild() async {
        guard let c = client() else { error = MissingTMDbKey.message; return }
        loading = true
        defer { loading = false }
        error = nil
        page = 1
        shown = []
        let t0 = ContinuousClock.now
        await loadGenres(c)
        await loadStreamedDetails(c)
        let profile = currentProfile()
        var candidates: [TMDbPick] = []
        // titres aimés ou regardés récemment : leurs recommandations, en parallèle
        let seeds = seedTitles()
        await withTaskGroup(of: [TMDbPick].self) { group in
            for s in seeds {
                group.addTask { (try? await c.recommendations(s.kind, id: s.tmdbId, because: s.title)) ?? [] }
            }
            // découverte guidée par les genres préférés, films et séries
            for kind in [MediaKind.movie, .tv] {
                let top = topGenres(profile, kind: kind)
                group.addTask { (try? await c.discover(kind, genres: top)) ?? [] }
            }
            // démarrage à froid : les mieux notés
            if seeds.isEmpty {
                for kind in [MediaKind.movie, .tv] { group.addTask { (try? await c.topRated(kind)) ?? [] } }
            }
            for await list in group { candidates += list }
        }
        let ranked = Recommender.rank(candidates, profile: profile, exclude: excluded())
        cards = ranked
        shown = Set(ranked.map(\.id))
        Perf.log("pour toi : \(ranked.count) cartes", since: t0)
        if ranked.isEmpty { error = "Rien à proposer pour l'instant : réessaie dans un moment." }
        prefetch(around: ranked.first?.id)
    }

    /// Plus de cartes quand on arrive vers la fin du fil.
    func loadMore() async {
        guard !loading, let c = client() else { return }
        loading = true
        defer { loading = false }
        page += 1
        let profile = currentProfile()
        var more: [TMDbPick] = []
        for kind in [MediaKind.movie, .tv] {
            more += (try? await c.discover(kind, genres: topGenres(profile, kind: kind), page: page)) ?? []
        }
        let ranked = Recommender.rank(more, profile: profile, exclude: excluded().union(shown))
        cards += ranked
        shown.formUnion(ranked.map(\.id))
    }

    /// Fiche complète (distribution, durée, logo) de la carte affichée et des deux suivantes ; leurs grands fonds aussi.
    func prefetch(around id: String?) {
        guard let id, let i = cards.firstIndex(where: { $0.id == id }), let c = client() else { return }
        for card in cards[i..<min(cards.count, i + 3)] {
            RemoteImageLoader.shared.prefetch(TMDbClient.imageURL(card.backdropPath, size: "w1280"))
            guard details[card.id] == nil else { continue }
            let kind = card.kind, tmdbId = card.tmdbId, key = card.id
            Task {
                if let m = try? await c.details(kind, id: tmdbId) { details[key] = m }
            }
        }
        if i >= cards.count - 4 { Task { await loadMore() } }
    }

    // MARK: réactions (interface optimiste : la carte change tout de suite)

    func react(_ card: TMDbPick, _ r: FeedReaction) {
        if reactions[card.id]?.reaction == r, r == .like {
            reactions[card.id] = nil   // J'aime une deuxième fois : on retire
        } else {
            reactions[card.id] = Stored(reaction: r, kind: card.kind, genreIds: card.genreIds, year: card.year,
                                        title: card.title, tmdbId: card.tmdbId, date: Date())
        }
        save()
        if r != .like {
            withAnimation(.easeInOut(duration: 0.3)) { cards.removeAll { $0.id == card.id } }
        }
        // la suite du fil se réordonne avec les nouveaux goûts
        if let i = cards.firstIndex(where: { $0.id == card.id }) ?? Optional(0), i + 2 < cards.count {
            let rest = Recommender.rank(Array(cards[(i + 2)...]), profile: currentProfile(), exclude: excluded())
            cards = Array(cards[..<(i + 2)]) + rest
        }
    }

    func reaction(_ card: TMDbPick) -> FeedReaction? { reactions[card.id]?.reaction }

    /// Télécharger : un film prend sa meilleure version ; une série est suivie et téléchargée en entier.
    func download(_ card: TMDbPick) {
        let tracker = TrackerModel.shared
        guard let c = client() else { return }
        downloadState[card.id] = "Envoi…"
        Task {
            do {
                let m: Media
                if let known = details[card.id] { m = known } else { m = try await c.details(card.kind, id: card.tmdbId) }
                if card.kind == .tv {
                    tracker.follow(m, backfill: true)
                    downloadState[card.id] = "Suivie, téléchargement lancé"
                } else {
                    let versions = try await tracker.versions(for: m)
                    if let best = versions.first(where: { $0.score != nil }) {
                        tracker.grab(best, media: m)
                        downloadState[card.id] = "Ajouté aux téléchargements"
                    } else {
                        downloadState[card.id] = versions.isEmpty ? "Rien à télécharger pour l'instant" : "Aucune version selon tes réglages"
                    }
                }
            } catch {
                downloadState[card.id] = nil
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: goûts

    private func save() {
        if let data = try? JSONEncoder().encode(reactions) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func loadGenres(_ c: TMDbClient) async {
        for kind in [MediaKind.movie, .tv] where genreMaps[kind] == nil {
            genreMaps[kind] = (try? await c.genreIds(kind)) ?? [:]
        }
    }

    /// Titres regardés en streaming (IPTV) : leurs genres comptent dans les goûts comme ceux de la bibliothèque.
    private func streamedTitles() -> [(StreamRecord, Media)] {
        var seen = Set<String>()
        return IPTVStore.shared.streams.compactMap { r -> (StreamRecord, Media)? in
            guard let k = r.mediaKey, seen.insert(k).inserted,
                  let m = details[k] ?? LibraryStore.shared.media[k] else { return nil }
            return (r, m)
        }
    }

    private func loadStreamedDetails(_ c: TMDbClient) async {
        var seen = Set<String>()
        for r in IPTVStore.shared.streams.prefix(30) {
            guard let k = r.mediaKey, seen.insert(k).inserted, details[k] == nil, LibraryStore.shared.media[k] == nil,
                  let (kind, id) = TMDbLink.parseKey(k) else { continue }
            if let m = try? await c.details(kind, id: id) { details[k] = m }
        }
    }

    private func genreIds(_ m: Media) -> [Int] {
        let map = genreMaps[m.kind] ?? [:]
        return m.genres.compactMap { map[$0] }
    }

    /// Les signaux : bibliothèque, temps regardé, vus, Ma liste, réactions.
    private func currentProfile() -> TasteProfile {
        var signals: [TasteProfile.Signal] = []
        let now = Date().timeIntervalSince1970
        for item in LibraryStore.shared.items {
            guard let m = item.media else { continue }
            var w = 1.0
            if item.allWatched { w = 2 } else if item.inProgress { w = 1.5 }
            if item.lastPlayed > 0, now - item.lastPlayed < 30 * 86400 { w += 1 }   // regardé ce mois-ci
            signals.append(.init(kind: m.kind, genreIds: genreIds(m), year: m.year, weight: w))
        }
        let library = Set(LibraryStore.shared.items.compactMap { $0.media.map { Media.key($0.kind, $0.tmdbId) } })
        for (r, m) in streamedTitles() where !library.contains(Media.key(m.kind, m.tmdbId)) {
            var w = 1.5
            if now - r.date.timeIntervalSince1970 < 30 * 86400 { w += 1 }
            signals.append(.init(kind: m.kind, genreIds: genreIds(m), year: m.year, weight: w))
        }
        for f in TrackerModel.shared.follows where !library.contains(f.id) {
            if let m = LibraryStore.shared.media[f.id] { signals.append(.init(kind: m.kind, genreIds: genreIds(m), year: m.year, weight: 2)) }
        }
        for r in reactions.values {
            let w: Double = r.reaction == .like ? 3 : r.reaction == .dislike ? -3 : 0.5
            signals.append(.init(kind: r.kind, genreIds: r.genreIds, year: r.year, weight: w))
        }
        return TasteProfile.build(signals)
    }

    private func topGenres(_ p: TasteProfile, kind: MediaKind) -> [Int] {
        let valid = Set((genreMaps[kind] ?? [:]).values)
        return p.genres.filter { $0.value > 0 && (valid.isEmpty || valid.contains($0.key)) }
            .sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    /// Titres de départ : J'aime récents, puis ce qui a été regardé récemment, puis le reste de la bibliothèque.
    private func seedTitles() -> [(kind: MediaKind, tmdbId: Int, title: String)] {
        var out: [(MediaKind, Int, String)] = []
        var seen = Set<String>()
        for r in reactions.values.filter({ $0.reaction == .like }).sorted(by: { $0.date > $1.date }).prefix(4) {
            if seen.insert(Media.key(r.kind, r.tmdbId)).inserted { out.append((r.kind, r.tmdbId, r.title)) }
        }
        for (_, m) in streamedTitles().prefix(3) where out.count < 6 {
            if seen.insert(Media.key(m.kind, m.tmdbId)).inserted { out.append((m.kind, m.tmdbId, m.title)) }
        }
        let items = LibraryStore.shared.items.compactMap { i -> (LibraryItem, Media)? in i.media.map { (i, $0) } }
            .sorted { a, b in
                let wa = a.0.lastPlayed + (a.0.allWatched ? 86400 * 7 : 0), wb = b.0.lastPlayed + (b.0.allWatched ? 86400 * 7 : 0)
                return wa != wb ? wa > wb : a.0.added > b.0.added
            }
        for (_, m) in items where out.count < 8 {
            if seen.insert(Media.key(m.kind, m.tmdbId)).inserted { out.append((m.kind, m.tmdbId, m.title)) }
        }
        return out.map { (kind: $0.0, tmdbId: $0.1, title: $0.2) }
    }

    /// Ce qu'on ne propose pas : déjà là, déjà vu, refusé, suivi.
    private func excluded() -> Set<String> {
        var out = Set(LibraryStore.shared.media.keys)
        out.formUnion(reactions.filter { $0.value.reaction != .like }.keys)
        out.formUnion(TrackerModel.shared.follows.map(\.id))
        return out
    }
}

// MARK: - Vue

struct ForYouView: View {
    @StateObject private var model = ForYouModel.shared
    @State private var current: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let e = model.error, model.cards.isEmpty {
                if e == MissingTMDbKey.message { MissingTMDbKey().frame(maxHeight: .infinity) }
                else { ContentUnavailableView("Pour toi", systemImage: "sparkles", description: Text(e)) }
            } else if model.cards.isEmpty {
                ForYouSkeleton()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.cards) { card in
                            ForYouCard(card: card)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(card.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onAppear { focused = true }
            }
        }
        .background(Theme.background)
        .task { await model.loadIfNeeded() }
        .onChange(of: current) { _, id in model.prefetch(around: id) }
    }

    private func step(_ d: Int) {
        let ids = model.cards.map(\.id)
        let i = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        let j = min(max(0, i + d), ids.count - 1)
        withAnimation(.easeInOut(duration: 0.35)) { current = ids[j] }
    }
}

/// Une carte : grand fond, affiche, titre, infos, résumé, distribution, actions.
private struct ForYouCard: View {
    let card: TMDbPick
    @ObservedObject private var model = ForYouModel.shared
    @ObservedObject private var tracker = TrackerModel.shared

    private var media: Media? { model.details[card.id] }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.08)
                RemoteImage(url: TMDbClient.imageURL(media?.backdropPath ?? card.backdropPath, size: "w1280"))
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
                LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: Theme.background.opacity(0.9), location: 0.85),
                                       .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)

                HStack(alignment: .bottom, spacing: 28) {
                    ZStack {
                        Color(white: 0.16)
                        RemoteImage(url: TMDbClient.imageURL(card.posterPath, size: "w342"))
                    }
                    .frame(width: 190, height: 285)
                    .overlay(alignment: .bottomTrailing) { StreamBadge(kind: card.kind, tmdbId: card.tmdbId, title: card.title, year: card.year) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.because.map { "PARCE QUE TU AS AIMÉ « \($0.uppercased()) »" } ?? "À DÉCOUVRIR")
                            .font(.system(size: 11, weight: .heavy)).kerning(0.8).foregroundStyle(Theme.accentText)
                        LogoOrTitle(logoPath: media?.logoPath, title: card.title, maxWidth: 460, maxHeight: 120, fontSize: 40)
                        Text(meta).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        Text(media?.overview ?? card.overview).font(.system(size: 14)).foregroundStyle(.white.opacity(0.88))
                            .lineLimit(4).frame(maxWidth: 620, alignment: .leading)
                        if let cast = media?.cast, !cast.isEmpty { castRow(cast) }
                        actions.padding(.top, 4)
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 56)
            }
        }
    }

    private var meta: String {
        var parts: [String] = [card.kind == .tv ? "Série" : "Film"]
        if let y = card.year { parts.append(String(y)) }
        if card.kind == .tv, let n = media?.seasonCount { parts.append(n > 1 ? "\(n) saisons" : "1 saison") }
        else if let r = media?.runtime, r > 0 { parts.append(r >= 60 ? "\(r / 60) h \(String(format: "%02d", r % 60))" : "\(r) min") }
        if let g = media?.genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: ", ")) }
        if card.vote > 0 { parts.append(String(format: "★ %.1f", card.vote)) }
        return parts.joined(separator: " · ")
    }

    private func castRow(_ cast: [CastMember]) -> some View {
        HStack(spacing: 14) {
            ForEach(cast.prefix(6)) { c in
                NavigationLink(value: PersonLink.value(c.id)) {
                    VStack(spacing: 5) {
                        PersonPhoto(path: c.profilePath, name: c.name, size: 54)
                        Text(c.name).font(.system(size: 10, weight: .semibold)).lineLimit(1).frame(width: 70)
                    }
                }
                .buttonStyle(.plain)
                .help("Voir \(c.name)")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            StreamButton(kind: card.kind, tmdbId: card.tmdbId, titles: [card.title, media?.originalTitle ?? ""], year: card.year, compact: true)
            if let state = model.downloadState[card.id] {
                SmallPill(title: state, icon: "arrow.down.circle", filled: false)
            } else if tracker.configured {
                Button { model.download(card) } label: {
                    SmallPill(title: card.kind == .tv ? "Tout télécharger" : "Télécharger", icon: "arrow.down", filled: true)
                }
                .buttonStyle(.plain)
            }
            NavigationLink(value: card.id) {
                SmallPill(title: "Voir la fiche", icon: "info.circle", filled: !tracker.configured)
            }
            .buttonStyle(.plain)
            round(model.reaction(card) == .like ? "heart.fill" : "heart", help: "J'aime") { model.react(card, .like) }
            if tracker.configured {
                let followed = tracker.follows.contains { $0.id == card.id }
                round(followed ? "bell.fill" : "bell", help: followed ? "Dans Ma liste" : "Ajouter à Ma liste (suivre)") {
                    if !followed, let m = model.details[card.id] { tracker.follow(m, backfill: false) }
                }
            }
            round("eye", help: "Déjà vu") { model.react(card, .seen) }
            round("hand.thumbsdown", help: "Pas pour moi") { model.react(card, .dislike) }
        }
    }

    private func round(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 15, weight: .bold)) }
            .buttonStyle(CircleButtonStyle())
            .help(help)
    }
}

/// Pendant le premier chargement : la forme d'une carte.
private struct ForYouSkeleton: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Skeleton(corner: 0)
            HStack(alignment: .bottom, spacing: 28) {
                Skeleton().frame(width: 190, height: 285)
                VStack(alignment: .leading, spacing: 12) {
                    Skeleton(corner: 4).frame(width: 200, height: 10)
                    Skeleton(corner: 6).frame(width: 380, height: 40)
                    Skeleton(corner: 4).frame(width: 300, height: 12)
                    Skeleton(corner: 4).frame(width: 560, height: 60)
                }
            }
            .padding(.horizontal, Theme.margin).padding(.bottom, 56)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
