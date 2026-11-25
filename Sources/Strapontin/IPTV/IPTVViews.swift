import StrapontinCore
import SwiftUI

// MARK: - En direct

/// Onglet « En direct », dans le langage des autres pages : une grande chaîne en tête avec son programme, puis des
/// rangées (Favoris, Récentes, un rang par groupe) de cartes au format des vignettes, la barre des pays, la recherche.
struct LiveTVView: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var query = ""
    @State private var results: [IPTVEntry] = []
    static let all = "Toutes"

    /// Chaînes du pays choisi.
    private var inCountry: [IPTVEntry] { store.country == nil ? store.channels : store.channels.filter(store.inCountry) }

    /// Rangées par groupe (« FR | Cinéma » et « FRANCE Cinéma » ensemble), dans l'ordre de la playlist.
    private var groups: [(String, [IPTVEntry])] {
        var order: [String] = [], rows: [String: [IPTVEntry]] = [:]
        for c in inCountry {
            let t = Self.groupTitle(c.group)
            if rows[t] == nil { order.append(t) }
            rows[t, default: []].append(c)
        }
        return order.map { ($0, rows[$0]!) }
    }

    /// La chaîne en tête : celle qu'on regarde, sinon le premier favori, sinon la dernière regardée.
    private var featured: IPTVEntry? {
        if let c = PlayerController.current, c.isLive, let e = c.queue.first?.live?.entry { return e }
        return store.favoriteChannels.first ?? store.recentChannels.first ?? inCountry.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if !store.configured {
                    header.padding(.top, 96)
                    IPTVSetupNotice()
                } else if store.channels.isEmpty, !store.loading, let e = store.error {
                    header.padding(.top, 96)
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Chaînes indisponibles").font(.system(size: 20, weight: .bold))
                        Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                        Button("Réessayer") { Task { await store.reload(force: true) } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if !query.isEmpty {
                    header.padding(.top, 96)
                    if !store.channelCountries.isEmpty { CountryBar(counts: store.channelCountries, total: store.channels.count) }
                    let found = results.filter(store.inCountry)
                    channelGrid(found, title: found.isEmpty ? "Aucune chaîne pour « \(query) »"
                                + (store.country.map { " en \(IPTVCountry.label($0))" } ?? "") : "Chaînes")
                } else {
                    if let f = featured { LiveHero(channel: f) } else { header.padding(.top, 96) }
                    HStack {
                        if !store.channelCountries.isEmpty {
                            CountryBar(counts: store.channelCountries, total: store.channels.count)
                        }
                        Spacer(minLength: 0)
                        IPTVSearchField(text: $query, prompt: "Chaîne, numéro, groupe…").padding(.trailing, Theme.margin)
                    }
                    if !store.favoriteChannels.isEmpty { channelRow("Favoris", store.favoriteChannels, reorder: true) }
                    if !store.recentChannels.isEmpty { channelRow("Récentes", Array(store.recentChannels.prefix(15))) }
                    if store.channels.isEmpty && store.loading {
                        SkeletonShelf(title: "Chaînes")
                    } else {
                        if let e = store.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                                .padding(.horizontal, Theme.margin)
                        }
                        LazyVStack(alignment: .leading, spacing: 36) {
                            ForEach(groups, id: \.0) { g, list in
                                Shelf(title: g) {
                                    ForEach(list.prefix(30)) { ChannelCard(channel: $0, width: 240) }
                                    if list.count > 30 {
                                        NavigationLink(value: "livegroup:" + g) { MoreCard(count: list.count) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.backdrop)
        .onReceive(NotificationCenter.default.publisher(for: .essaiLiveQuery)) { query = ($0.object as? String) ?? "" }
        .task(id: query) {
            // la frappe ne fige jamais l'interface : recherche hors du fil principal, annulée à chaque lettre
            let q = query, index = store.channelIndex
            let favs = Set(store.favorites), country = store.country
            guard !q.isEmpty else { results = []; return }
            let t0 = ContinuousClock.now
            let found = await Task.detached(priority: .userInitiated) {
                index.search(q, kinds: [.live], limit: 300, favorites: favs, country: country)
            }.value
            Perf.log("recherche chaînes \(q.count) lettres, \(found.count) trouvées", since: t0)
            if !Task.isCancelled { results = found }
        }
    }

    /// « FR | Sport » → « Sport » : le pays est déjà dans la barre.
    static func groupTitle(_ g: String) -> String { IPTVCountry.groupTitle(g) }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text("En direct").font(.system(size: 30, weight: .bold))
            if store.loading { ProgressView().controlSize(.small) }
            Spacer()
            if store.configured {
                IPTVSearchField(text: $query, prompt: "Chaîne, numéro, groupe…")
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func channelRow(_ title: String, _ list: [IPTVEntry], reorder: Bool = false) -> some View {
        Shelf(title: title) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                ChannelCard(channel: c, width: 240)
                    .contextMenu {
                        if reorder {
                            Button("Déplacer à gauche") { store.moveFavorite(from: IndexSet(integer: i), to: max(0, i - 1)) }.disabled(i == 0)
                            Button("Déplacer à droite") { store.moveFavorite(from: IndexSet(integer: i), to: min(list.count, i + 2)) }
                                .disabled(i == list.count - 1)
                        }
                    }
            }
        }
    }

    private func channelGrid(_ list: [IPTVEntry], title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 21, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 22)], alignment: .leading, spacing: 26) {
                ForEach(list) { ChannelCard(channel: $0) }
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

/// Toutes les chaînes d'un groupe (« Tout voir » au bout d'une rangée).
struct LiveGroupPage: View {
    let group: String
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(group).font(.system(size: 30, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 22)], alignment: .leading, spacing: 26) {
                    ForEach(store.channels.filter { LiveTVView.groupTitle($0.group) == group && store.inCountry($0) }) { ChannelCard(channel: $0) }
                }
            }
            .padding(.horizontal, Theme.margin).padding(.top, 96).padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
    }
}

/// Carte « Tout voir » au bout d'une rangée, au format des cartes de chaîne.
private struct MoreCard: View {
    let count: Int
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(.white.opacity(hover ? 0.12 : 0.07))
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .semibold))
                    Text("Tout voir").font(.system(size: 14, weight: .semibold))
                    Text("\(count) chaînes").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .scaleEffect(hover ? 1.04 : 1)
        }
        .frame(width: 240)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

/// En tête d'« En direct » : la chaîne, ce qui passe et ensuite, comme le grand visuel des autres pages.
struct LiveHero: View {
    let channel: IPTVEntry
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        let nn = store.guide.nowNext(channel.tvgId)
        ZStack(alignment: .bottomLeading) {
            // le logo en grand, flouté, comme fond ; puis le même dégradé que les fiches
            ChannelLogo(logo: channel.logo, name: "", fontSize: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity).scaleEffect(1.6).blur(radius: 60).opacity(0.55)
            LinearGradient(colors: [Color(white: 0.16), Theme.background], startPoint: .top, endPoint: .bottom).opacity(0.75)
            HeroShade()
            HStack(alignment: .bottom, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text("EN DIRECT").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                        if let n = channel.number { Text("\(n)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.7)) }
                        Text(LiveTVView.groupTitle(channel.group).uppercased()).font(.system(size: 11, weight: .heavy)).kerning(0.8)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(channel.name).font(.system(size: 46, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    if let now = nn.now {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(now.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                            ProgressView(value: min(1, max(0, Date().timeIntervalSince(now.start) / now.stop.timeIntervalSince(now.start))))
                                .tint(Theme.accent).frame(maxWidth: 360)
                            if let next = nn.next {
                                Text("Ensuite : \(next.title) · \(next.start.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        PlayPill(title: "Regarder") { PlayerController.playLive(channel) }
                        Button { store.toggleFavorite(channel) } label: {
                            Image(systemName: store.isFavorite(channel) ? "star.fill" : "star").font(.system(size: 15, weight: .bold))
                                .foregroundStyle(store.isFavorite(channel) ? Color.yellow : Color.white)
                        }
                        .buttonStyle(CircleButtonStyle())
                        .help(store.isFavorite(channel) ? "Retirer des favoris" : "Ajouter aux favoris")
                    }
                    .padding(.top, 6)
                }
                Spacer()
                ChannelLogo(logo: channel.logo, name: channel.name, collapsedSize: CGSize(width: 300, height: 170))
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 40)
        }
        .frame(height: 400)
        .clipped()
    }
}

/// Une chaîne : logo, numéro, nom, programme en cours ; étoile des favoris ; un clic la lance.
struct ChannelCard: View {
    let channel: IPTVEntry
    /// Largeur fixe dans les rangées ; libre dans les grilles.
    var width: CGFloat? = nil
    @ObservedObject private var store = IPTVStore.shared
    @State private var hover = false

    var body: some View {
        let nn = store.guide.nowNext(channel.tvgId)
        let variants = store.variants(of: channel)
        Button { PlayerController.playLive(channel) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(white: 0.21), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    ChannelLogo(logo: channel.logo, name: channel.name, fontSize: 18)
                        .padding(.horizontal, 30).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        if let n = channel.number {
                            Text("\(n)").font(.system(size: 11, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule())
                        }
                        Spacer()
                        // même bouton que les vignettes « À suivre »
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(.white, in: Circle())
                            .opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
                    }
                    .padding(10)
                    if let now = nn.now {
                        GeometryReader { g in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.3))
                                    Capsule().fill(Theme.accent)
                                        .frame(width: g.size.width * min(1, max(0, Date().timeIntervalSince(now.start) / now.stop.timeIntervalSince(now.start))))
                                }
                                .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 4)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Sheen(active: hover) }
                .overlay(alignment: .topTrailing) {
                    if store.isFavorite(channel) {
                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow).padding(9)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
                Text(channel.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(nn.now?.title ?? LiveTVView.groupTitle(channel.group)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width)
            .frame(minWidth: width == nil ? 200 : nil, maxWidth: width == nil ? 260 : nil)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        // les noms bruts de la playlist, au survol prolongé
        .help(variants.map { "\($0.label) — \($0.rawName)" }.joined(separator: "\n"))
        .contextMenu {
            Button(store.isFavorite(channel) ? "Retirer des favoris" : "Ajouter aux favoris") { store.toggleFavorite(channel) }
            if variants.count > 1 {
                Menu("Qualité par défaut") {
                    ForEach(variants) { v in
                        Button((store.preferredVariant(channel)?.id == v.id ? "✓ " : "") + v.label) { store.chooseQuality(v.id, for: channel) }
                    }
                }
            }
        }
    }
}

/// Champ de recherche compact des onglets IPTV.
struct IPTVSearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 320)
        .background(Color(white: 0.15), in: Capsule())
    }
}

/// Aucune playlist : comment en ajouter une.
struct IPTVSetupNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.and.mediabox").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accentText)
            Text("Ajoute une playlist IPTV").font(.system(size: 22, weight: .bold))
            Text("Colle l'adresse de ta playlist M3U (ou choisis un fichier) dans Réglages › IPTV. Les chaînes arrivent ici, les films et séries dans le Catalogue IPTV.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            SettingsButton(tab: .iptv) { SmallPill(title: "Ajouter une playlist", icon: "plus", filled: true) }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - Catalogue IPTV

/// Fiches TMDb des titres du catalogue IPTV : cherchées à l'affichage, gardées en mémoire.
@MainActor
final class VODMatcher: ObservableObject {
    static let shared = VODMatcher()
    @Published private(set) var media: [String: Media] = [:]
    private var asked = Set<String>()

    func match(_ v: VODItem) {
        guard asked.insert(v.id).inserted else { return }
        let s = AppSettings.shared
        guard !s.effectiveTMDbKey.isEmpty else { return }
        let c = TMDbClient(key: s.effectiveTMDbKey, language: s.tmdbLanguage, omdbKey: s.omdbKey)
        let kind: MediaKind = v.kind == .series ? .tv : .movie
        Task {
            var id = v.tmdbId
            if id == nil { id = try? await c.bestMatch(kind, title: VODTitle.clean(v.name), year: v.year)?.id }
            if let id, let m = try? await c.details(kind, id: id) { media[v.id] = m }
        }
    }
}

struct VODCard: View {
    let item: VODItem
    @ObservedObject private var matcher = VODMatcher.shared
    @ObservedObject private var store = IPTVStore.shared
    @State private var hover = false

    var body: some View {
        let m = matcher.media[item.id]
        NavigationLink(value: "vod:\(item.id)") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                    if let p = m?.posterPath {
                        RemoteImage(url: TMDbClient.imageURL(p, size: "w342"))
                    } else if let poster = item.poster, let url = URL(string: poster) {
                        RemoteImage(url: url)
                    } else {
                        GenericPoster(title: VODTitle.clean(item.name), kind: item.kind == .series ? .tv : .movie, subtitle: item.year.map(String.init))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let p = store.progress[item.id], p[1] > 0, p[0] > 0, p[0] < p[1] * 0.95 {
                        GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * p[0] / p[1], height: 3) }
                            .frame(height: 3).padding(8)
                    }
                }
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
                Text(m?.title ?? VODTitle.clean(item.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([item.kind == .series ? "Série" : "Film", (m?.year ?? item.year).map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .onAppear { matcher.match(item) }
    }
}

/// Fiche d'un film ou d'une série du catalogue IPTV : grand visuel TMDb, résumé, distribution, lecture et reprise.
struct VODDetailView: View {
    let itemId: String
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var matcher = VODMatcher.shared
    @State private var season: Int?

    private var item: VODItem? { store.vod.first { $0.id == itemId } }

    var body: some View {
        ScrollView {
            if let item {
                let m = matcher.media[item.id]
                VStack(alignment: .leading, spacing: 30) {
                    ZStack(alignment: .bottomLeading) {
                        Color(white: 0.08)
                        if let b = m?.backdropPath { RemoteImage(url: TMDbClient.imageURL(b, size: "w1280")) }
                        LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))
                        LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.background.opacity(0.9), location: 0.88),
                                               .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 12) {
                            LogoOrTitle(logoPath: m?.logoPath, title: m?.title ?? VODTitle.clean(item.name), maxWidth: 480, maxHeight: 140, fontSize: 44)
                            Text([item.kind == .series ? "Série" : "Film", (m?.year ?? item.year).map(String.init),
                                  m?.genres.prefix(3).joined(separator: ", "), (m?.rating ?? item.rating).map { String(format: "★ %.1f", $0) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            if let o = m?.overview ?? item.plot, !o.isEmpty {
                                Text(o).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85)).lineLimit(4).frame(maxWidth: 620, alignment: .leading)
                            }
                            if item.kind == .movie, let url = item.url { playButton(item, url: url) }
                        }
                        .padding(.horizontal, Theme.margin).padding(.bottom, 40)
                    }
                    .frame(height: 560)
                    if item.kind == .series { episodes(item) }
                    if let cast = m?.cast, !cast.isEmpty { CastRow(cast: cast) }
                }
                .padding(.bottom, 40)
                .task { matcher.match(item); if item.seriesId != nil { await store.loadEpisodes(item) } }
            } else {
                ContentUnavailableView("Titre introuvable", systemImage: "questionmark.square.dashed").padding(.top, 160)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
    }

    private func playButton(_ item: VODItem, url: String) -> some View {
        let p = store.progress[item.id]
        let resume = p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false
        return PlayPill(title: resume ? "Reprendre" : "Lire") {
            PlayerController.play([PlayItem(path: url, title: VODTitle.clean(item.name), subtitle: nil,
                                            start: resume ? p![0] : 0, progressKey: item.id)])
        }
    }

    @ViewBuilder private func episodes(_ item: VODItem) -> some View {
        let list = item.seriesId != nil ? (store.episodes[item.id] ?? []) : store.playlistEpisodes(of: item)
        let seasons = Array(Set(list.map(\.season))).sorted()
        let shown = season ?? seasons.first ?? 1
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(seasons, id: \.self) { s in
                    Button { season = s } label: {
                        Text("Saison \(s)").font(.system(size: 18, weight: .bold)).foregroundStyle(s == shown ? .white : .white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            if list.isEmpty { Skeleton(corner: 10).frame(height: 80) }
            ForEach(list.filter { $0.season == shown }) { e in
                let p = store.progress[e.id]
                Button {
                    let resume = p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false
                    PlayerController.play([PlayItem(path: e.url, title: VODTitle.clean(item.name), subtitle: "Saison \(e.season), épisode \(e.episode) · \(e.title)",
                                                    start: resume ? p![0] : 0, progressKey: e.id)])
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Color(white: 0.16)
                            if let s = e.still, let url = URL(string: s) { RemoteImage(url: url) }
                            Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(e.episode). \(e.title)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            if let plot = e.plot, !plot.isEmpty { Text(plot).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                            if let p, p[1] > 0, p[0] > 0 {
                                ProgressView(value: min(1, p[0] / p[1])).tint(Theme.accent).frame(width: 160)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

// MARK: - Réglages

struct IPTVSettings: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var editing: IPTVPlaylist?
    @State private var testing: String?
    @State private var diagnostics: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(store.playlists) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 13, weight: .semibold))
                            Text(p.source.hasPrefix("http") ? "Adresse (gardée sur ce Mac)" : (p.source as NSString).lastPathComponent)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(testing == p.id ? "Test…" : "Tester la connexion") {
                            testing = p.id
                            Task { diagnostics[p.id] = await IPTVStore.testConnection(p); testing = nil }
                        }
                        .disabled(testing != nil)
                        Button("Modifier") { editing = p }
                        Button(role: .destructive) { store.save(store.playlists.filter { $0.id != p.id }) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    if let d = diagnostics[p.id] {
                        Text(d).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Ajouter une playlist…") { editing = IPTVPlaylist(name: "Ma playlist", source: "") }
                    Spacer()
                    if store.configured {
                        Button("Recharger maintenant") { Task { await store.reload(force: true) } }.disabled(store.loading)
                    }
                }
                if store.configured {
                    Text("\(store.channels.count) chaînes · \(store.vod.filter { $0.kind == .movie }.count) films · \(store.catalogItems.filter { $0.kind == .series }.count) séries")
                        .foregroundStyle(.secondary)
                }
                if let e = store.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if store.configured {
                    HStack {
                        Button("Exporter les noms des chaînes…") {
                            if let url = store.exportNames() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Text("Noms, groupes et catégories seulement : aucune adresse ni identifiant.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                Text("Une adresse M3U / M3U8 ou un fichier. Les fournisseurs « Xtream Codes » (adresse en get.php?username=…) donnent aussi leur catalogue de films et séries. Les adresses et identifiants restent sur ce Mac, dans un fichier que toi seul peux lire.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { p in
            PlaylistEditor(playlist: p) { updated in
                var list = store.playlists
                if let i = list.firstIndex(where: { $0.id == updated.id }) { list[i] = updated } else { list.append(updated) }
                store.save(list)
            }
        }
    }
}

private struct PlaylistEditor: View {
    @State var playlist: IPTVPlaylist
    let save: (IPTVPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var xtream = false
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    init(playlist: IPTVPlaylist, save: @escaping (IPTVPlaylist) -> Void) {
        _playlist = State(initialValue: playlist)
        self.save = save
        // compte Xtream déjà enregistré : les trois champs plutôt que l'adresse complète
        if let c = URLComponents(string: playlist.source), c.path.hasSuffix("get.php"),
           let u = c.queryItems?.first(where: { $0.name == "username" })?.value,
           let pw = c.queryItems?.first(where: { $0.name == "password" })?.value {
            var base = c; base.path = String(c.path.dropLast("/get.php".count)); base.query = nil
            _xtream = State(initialValue: true)
            _server = State(initialValue: base.string ?? "")
            _username = State(initialValue: u)
            _password = State(initialValue: pw)
        }
    }

    /// Adresse de playlist d'un compte Xtream (get.php), identifiants encodés.
    private var xtreamSource: String? {
        var s = server.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard var c = URLComponents(string: s + "/get.php") else { return nil }
        c.queryItems = [.init(name: "username", value: username), .init(name: "password", value: password),
                        .init(name: "type", value: "m3u_plus"), .init(name: "output", value: "ts")]
        return c.url?.absoluteString
    }

    var body: some View {
        Form {
            TextField("Nom", text: $playlist.name)
            Picker("Type", selection: $xtream) {
                Text("Adresse M3U ou fichier").tag(false)
                Text("Compte Xtream").tag(true)
            }
            .pickerStyle(.segmented)
            if xtream {
                TextField("Serveur", text: $server, prompt: Text("http://serveur:port"))
                TextField("Identifiant", text: $username)
                SecureField("Mot de passe", text: $password)
            } else {
            HStack {
                TextField("Adresse M3U ou fichier", text: $playlist.source, prompt: Text("https://… ou ~/Documents/liste.m3u"))
                Button("Fichier…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.init(filenameExtension: "m3u")!, .init(filenameExtension: "m3u8")!]
                    if panel.runModal() == .OK, let u = panel.url { playlist.source = u.path }
                }
            }
            }
            TextField("Guide XMLTV (facultatif)", text: $playlist.guide, prompt: Text("Sinon celui annoncé par la playlist"))
            TextField("User-Agent (facultatif)", text: $playlist.userAgent, prompt: Text("Par défaut : \(LiveOptions.defaultUserAgent)"))
            TextField("Referer (facultatif)", text: $playlist.referer)
            Stepper("Rafraîchir toutes les \(playlist.refreshHours) h", value: $playlist.refreshHours, in: 1...72)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") {
                    if xtream, let src = xtreamSource { playlist.source = src }
                    save(playlist); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(xtream ? xtreamSource == nil : playlist.source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

/// Le logo de la chaîne, ou son nom écrit s'il n'y en a pas ou s'il ne se charge pas.
struct ChannelLogo: View {
    let logo: String?
    let name: String
    var fontSize: CGFloat = 13
    /// Taille fixe, et rien du tout (pas même la place) si l'image ne vient pas : le nom est déjà écrit à côté.
    var collapsedSize: CGSize?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: collapsedSize?.width, height: collapsedSize?.height)
            } else if collapsedSize == nil {
                Text(name).font(.system(size: fontSize, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: logo) {
            guard let logo, let url = URL(string: logo) else { image = nil; return }
            if let hit = RemoteImageLoader.shared.cached(url) { image = hit; return }
            image = await RemoteImageLoader.shared.image(url)
        }
    }
}

/// Barre des pays : drapeau, nom, nombre ; « Tous » d'abord, pays épinglés en tête (clic droit).
struct CountryBar: View {
    @ObservedObject private var store = IPTVStore.shared
    let counts: [IPTVStore.CountryCount]
    let total: Int
    /// Faux quand le pays choisi n'existe pas ici (le catalogue montre alors tout).
    var applies = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(flag: "🌐", label: "Tous", count: total, selected: store.country == nil || !applies) { store.country = nil }
                Divider().frame(height: 18).padding(.horizontal, 2)
                ForEach(counts) { c in
                    chip(flag: c.flag, label: c.label, count: c.count, selected: applies && store.country == c.code,
                         pinned: store.favoriteCountries.contains(c.code)) { store.country = c.code }
                        .contextMenu {
                            Button(store.favoriteCountries.contains(c.code) ? "Ne plus épingler en tête" : "Épingler en tête") {
                                store.toggleFavoriteCountry(c.code)
                            }
                        }
                        .help("Clic droit : épingler ce pays en tête")
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    private func chip(flag: String, label: String, count: Int, selected: Bool, pinned: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { action() } } label: {
            HStack(spacing: 6) {
                if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).opacity(0.7) }
                Text(flag).font(.system(size: 14))
                Text(label).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                Text(count.formatted()).font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.55)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(selected ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}
