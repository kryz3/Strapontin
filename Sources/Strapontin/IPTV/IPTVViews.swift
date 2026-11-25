import StrapontinCore
import SwiftUI

// MARK: - En direct

/// Onglet « En direct » : favoris et récentes en tête, puis les chaînes par groupe, recherche instantanée.
struct LiveTVView: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var query = ""
    @State private var results: [IPTVEntry] = []
    @State private var group: String = LiveTVView.all
    static let all = "Toutes"

    private var groups: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in store.channels where seen.insert(c.group).inserted { out.append(c.group) }
        return out
    }

    private var shown: [IPTVEntry] {
        group == Self.all ? store.channels : store.channels.filter { $0.group == group }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !store.configured {
                    IPTVSetupNotice()
                } else if !query.isEmpty {
                    channelGrid(results, title: results.isEmpty ? "Aucune chaîne pour « \(query) »" : "Chaînes")
                } else {
                    if !store.favoriteChannels.isEmpty { channelRow("Favoris", store.favoriteChannels, reorder: true) }
                    if !store.recentChannels.isEmpty { channelRow("Récentes", Array(store.recentChannels.prefix(15))) }
                    groupPicker
                    if store.channels.isEmpty && store.loading {
                        SkeletonShelf(title: "Chaînes")
                    } else {
                        channelGrid(shown, title: group == Self.all ? "Toutes les chaînes" : group)
                    }
                }
            }
            .padding(.top, 96).padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.backdrop)
        .task(id: query) {
            // la frappe ne fige jamais l'interface : recherche hors du fil principal, annulée à chaque lettre
            let q = query, index = store.channelIndex
            guard !q.isEmpty else { results = []; return }
            let found = await Task.detached(priority: .userInitiated) { index.search(q, kinds: [.live], limit: 300) }.value
            if !Task.isCancelled { results = found }
        }
    }

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

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([Self.all] + groups, id: \.self) { g in
                    Button { withAnimation(.easeOut(duration: 0.15)) { group = g } } label: {
                        Text(g).font(.system(size: 13, weight: group == g ? .semibold : .medium)).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(group == g ? Color.white.opacity(0.92) : Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(group == g ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    private func channelRow(_ title: String, _ list: [IPTVEntry], reorder: Bool = false) -> some View {
        Shelf(title: title) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                ChannelCard(channel: c)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 22)], alignment: .leading, spacing: 24) {
                ForEach(list) { ChannelCard(channel: $0) }
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

/// Une chaîne : logo, numéro, nom, programme en cours ; étoile des favoris ; un clic la lance.
struct ChannelCard: View {
    let channel: IPTVEntry
    @ObservedObject private var store = IPTVStore.shared
    @State private var hover = false

    var body: some View {
        let nn = store.guide.nowNext(channel.tvgId)
        Button { PlayerController.playLive(channel) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    ChannelLogo(logo: channel.logo, name: channel.name, fontSize: 17).padding(22)
                    HStack {
                        if let n = channel.number {
                            Text("\(n)").font(.system(size: 11, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule())
                        }
                        Spacer()
                        if store.isFavorite(channel) { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
                    }
                    .padding(8)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let now = nn.now {
                        GeometryReader { g in
                            Capsule().fill(Theme.accent)
                                .frame(width: g.size.width * min(1, max(0, Date().timeIntervalSince(now.start) / now.stop.timeIntervalSince(now.start))), height: 3)
                        }
                        .frame(height: 3).padding(.horizontal, 8).padding(.bottom, 6)
                    }
                }
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.45 : 0.2), radius: hover ? 14 : 5, y: 4)
                Text(channel.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(nn.now?.title ?? channel.group).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 200, maxWidth: 240)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu {
            Button(store.isFavorite(channel) ? "Retirer des favoris" : "Ajouter aux favoris") { store.toggleFavorite(channel) }
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

/// Onglet « Catalogue IPTV » : les films et séries à la demande des playlists, avec les fiches TMDb quand le titre est reconnu.
struct IPTVCatalogView: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var kind: IPTVKind = .movie
    @State private var category = LiveTVView.all
    @State private var query = ""
    @State private var results: [VODItem] = []

    private var items: [VODItem] { store.catalogItems.filter { $0.kind == kind } }
    private var categories: [String] {
        var seen = Set<String>(), out: [String] = []
        for v in items where seen.insert(v.category).inserted { out.append(v.category) }
        return out
    }
    private var shown: [VODItem] { category == LiveTVView.all ? items : items.filter { $0.category == category } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text("Catalogue IPTV").font(.system(size: 30, weight: .bold))
                    if store.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    if store.configured { IPTVSearchField(text: $query, prompt: "Film, série…") }
                }
                .padding(.horizontal, Theme.margin)
                if !store.configured {
                    IPTVSetupNotice()
                } else {
                    Picker("", selection: $kind) {
                        Text("Films").tag(IPTVKind.movie)
                        Text("Séries").tag(IPTVKind.series)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.horizontal, Theme.margin)
                    if query.isEmpty {
                        categoryPicker
                        grid(shown)
                    } else {
                        grid(results)
                    }
                    if items.isEmpty && !store.loading {
                        Text(kind == .movie ? "Pas de films dans tes playlists." : "Pas de séries dans tes playlists.")
                            .foregroundStyle(.secondary).padding(.horizontal, Theme.margin)
                    }
                }
            }
            .padding(.top, 96).padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.backdrop)
        .onChange(of: kind) { _, _ in category = LiveTVView.all }
        .task(id: "\(query)|\(kind.rawValue)") {
            let q = query, index = store.vodIndex, k = kind
            guard !q.isEmpty else { results = []; return }
            let ids = await Task.detached(priority: .userInitiated) { index.search(q, kinds: [k], limit: 300).map(\.id) }.value
            guard !Task.isCancelled else { return }
            let byId = Dictionary(store.vod.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            results = ids.compactMap { byId[$0] }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([LiveTVView.all] + categories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.system(size: 13, weight: category == c ? .semibold : .medium)).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(category == c ? Color.white.opacity(0.92) : Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(category == c ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    private func grid(_ list: [VODItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 24)], alignment: .leading, spacing: 30) {
            ForEach(list) { VODCard(item: $0) }
        }
        .padding(.horizontal, Theme.margin)
    }
}

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
                        Button("Modifier") { editing = p }
                        Button(role: .destructive) { store.save(store.playlists.filter { $0.id != p.id }) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
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

    var body: some View {
        Form {
            TextField("Nom", text: $playlist.name)
            HStack {
                TextField("Adresse M3U ou fichier", text: $playlist.source, prompt: Text("https://… ou ~/Documents/liste.m3u"))
                Button("Fichier…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.init(filenameExtension: "m3u")!, .init(filenameExtension: "m3u8")!]
                    if panel.runModal() == .OK, let u = panel.url { playlist.source = u.path }
                }
            }
            TextField("Guide XMLTV (facultatif)", text: $playlist.guide, prompt: Text("Sinon celui annoncé par la playlist"))
            TextField("User-Agent (facultatif)", text: $playlist.userAgent)
            TextField("Referer (facultatif)", text: $playlist.referer)
            Stepper("Rafraîchir toutes les \(playlist.refreshHours) h", value: $playlist.refreshHours, in: 1...72)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") { save(playlist); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(playlist.source.trimmingCharacters(in: .whitespaces).isEmpty)
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
