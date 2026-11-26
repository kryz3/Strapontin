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

    /// Rangées par groupe (« FR | Cinéma » et « FRANCE Cinéma » ensemble), calculées une fois par pays.
    private var groups: [(String, [IPTVEntry])] { store.liveRows() }

    /// La chaîne en tête : celle qu'on regarde, sinon le premier favori, sinon la dernière regardée.
    private var featured: IPTVEntry? {
        if let c = PlayerController.current, c.isLive, let e = c.queue.first?.live?.entry { return e }
        return store.favoriteChannels.first ?? store.recentChannels.first ?? store.liveRows().first?.1.first
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
                    ForEach(store.liveRows().first { $0.0 == group }?.1 ?? []) { ChannelCard(channel: $0) }
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
        let nn = store.nowNext(channel)
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
                        Text((store.groupTitle[channel.id] ?? channel.group).uppercased()).font(.system(size: 11, weight: .heavy)).kerning(0.8)
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
        .task(id: channel.id) { await store.loadShortEPG(channel) }
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
        let nn = store.nowNext(channel)
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
                Text(nn.now?.title ?? store.groupTitle[channel.id] ?? channel.group).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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
            Text("Ajoute ta TV en streaming").font(.system(size: 22, weight: .bold))
            Text("Dans Réglages › TV et streaming, ajoute l'adresse de ta playlist ou ton compte (serveur, identifiant, mot de passe). Les chaînes arrivent ici ; les films et séries se regardent depuis leur fiche, « Lire · Streaming ».")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            SettingsButton(tab: .iptv) { SmallPill(title: "Ajouter une playlist", icon: "plus", filled: true) }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - Catalogue IPTV

/// Un titre IPTV trouvé par la recherche (souvent inconnu de TMDb) : même format que les affiches.
struct VODCard: View {
    let ref: VODRef
    @ObservedObject private var store = IPTVStore.shared
    @State private var hover = false

    var body: some View {
        NavigationLink(value: "vod:\(ref.id)") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                    if let poster = ref.poster, let url = URL(string: poster) {
                        RemoteImage(url: url)
                    } else {
                        GenericPoster(title: VODTitle.clean(ref.name), kind: ref.kind == .series ? .tv : .movie, subtitle: ref.year.map(String.init))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
                Text(VODTitle.clean(ref.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([ref.kind == .series ? "Série" : "Film", ref.year.map(String.init), IPTVVOD.sourceLabel(ref.name)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .onAppear { store.remember(ref) }
    }
}

/// Fiche d'un titre IPTV sans fiche TMDb : lecture et reprise, épisodes par saison pour une série.
struct VODDetailView: View {
    let itemId: String
    @ObservedObject private var store = IPTVStore.shared
    @State private var season: Int?

    var body: some View {
        ScrollView {
            if let r = store.remembered(itemId) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .bottom, spacing: 28) {
                        ZStack {
                            Color(white: 0.16)
                            if let poster = r.poster, let url = URL(string: poster) { RemoteImage(url: url) }
                            else { GenericPoster(title: VODTitle.clean(r.name), kind: r.kind == .series ? .tv : .movie, subtitle: nil) }
                        }
                        .frame(width: 200, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(VODTitle.clean(r.name)).font(.system(size: 40, weight: .bold))
                            Text([r.kind == .series ? "Série" : "Film", r.year.map(String.init), IPTVVOD.sourceLabel(r.name)]
                                .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            Text(r.name).font(.system(size: 11)).foregroundStyle(.tertiary)
                            if r.kind == .movie, let url = store.url(of: r) {
                                let p = store.progress["stream:" + r.id]
                                let resume = p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false
                                PlayPill(title: resume ? "Reprendre" : "Lire") {
                                    IPTVVOD.play(url: url, mediaKey: nil, title: VODTitle.clean(r.name), progressKey: "stream:" + r.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.margin).padding(.top, 110)
                    if r.kind == .series { episodes(r).padding(.horizontal, Theme.margin) }
                }
                .padding(.bottom, 40)
                .task { if r.kind == .series { await store.loadEpisodes(r) } }
            } else {
                ContentUnavailableView("Titre introuvable", systemImage: "questionmark.square.dashed").padding(.top, 160)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
    }

    @ViewBuilder private func episodes(_ r: VODRef) -> some View {
        let list = store.episodes[r.id] ?? []
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
            if store.episodes[r.id] == nil { Skeleton(corner: 10).frame(height: 80) }
            ForEach(list.filter { $0.season == shown }) { e in
                let key = "stream:\(r.id):\(e.season):\(e.episode)"
                Button {
                    IPTVVOD.play(url: e.url, mediaKey: nil, title: VODTitle.clean(r.name),
                                 subtitle: "Saison \(e.season), épisode \(e.episode) · \(e.title)", progressKey: key)
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Color(white: 0.16)
                            if let s = e.still, let url = URL(string: s) { RemoteImage(url: url) }
                            Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ÉPISODE \(e.episode)").font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
                            Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            if let plot = e.plot { Text(plot).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
                    Text("\(store.channels.count) chaînes · \(store.vodLookup.refs.lazy.filter { $0.kind == .movie }.count) films · \(store.vodLookup.refs.lazy.filter { $0.kind == .series && ($0.episode ?? 1) == 1 }.count) séries" + (store.vodLoading ? " · index en cours…" : ""))
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
                Text("L'adresse d'une playlist (.m3u) ou un fichier, ou bien un compte : serveur, identifiant et mot de passe donnés par ton fournisseur. Les chaînes vont dans « En direct » ; les films et séries s'ajoutent comme source « Streaming » sur leur fiche. Adresses et identifiants restent sur ce Mac, dans un fichier que toi seul peux lire.")
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
                Text("Adresse de la playlist ou fichier").tag(false)
                Text("Compte (serveur et identifiants)").tag(true)
            }
            .pickerStyle(.segmented)
            if xtream {
                TextField("Serveur", text: $server, prompt: Text("http://serveur:port"))
                TextField("Identifiant", text: $username)
                SecureField("Mot de passe", text: $password)
            } else {
            HStack {
                TextField("Adresse de la playlist ou fichier", text: $playlist.source, prompt: Text("https://… ou ~/Documents/liste.m3u"))
                Button("Fichier…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.init(filenameExtension: "m3u")!, .init(filenameExtension: "m3u8")!]
                    if panel.runModal() == .OK, let u = panel.url { playlist.source = u.path }
                }
            }
            }
            TextField("Guide des programmes (facultatif)", text: $playlist.guide, prompt: Text("Sinon celui annoncé par la playlist"))
            TextField("Avancé · nom de lecteur envoyé (facultatif)", text: $playlist.userAgent, prompt: Text("Par défaut : \(LiveOptions.defaultUserAgent)"))
            TextField("Avancé · page d'origine (facultatif)", text: $playlist.referer)
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
