import StrapontinCore
import SwiftUI

/// La fiche d'une série, qu'on l'ait ou non : une seule page, pour que rien ne saute quand le premier épisode arrive.
/// En-tête, saisons, tous les épisodes avec leur état, saisons complètes, distribution.
struct SeriesFicheView: View {
    let tmdbId: Int
    @ObservedObject private var series: SeriesModel
    @ObservedObject private var tracker = TrackerModel.shared
    @ObservedObject private var downloads = DownloadsModel.shared
    @EnvironmentObject var store: LibraryStore
    @State private var showAllPacks = false

    init(tmdbId: Int) {
        self.tmdbId = tmdbId
        series = SeriesModel.of(tmdbId)
    }

    var body: some View {
        let item = store.item(id: series.key)
        ScrollView {
            if let m = series.media ?? item?.media {
                let season = series.selected ?? 1
                let snap = series.snapshot(season)
                VStack(alignment: .leading, spacing: 44) {
                    hero(m, item, snap)
                    DownloadPanel(entryId: series.key, showFinished: false)
                    episodeList(m, item, snap)
                    if let item { otherFiles(item) }
                    if tracker.configured { packs(m, snap) }
                    if let cast = m.cast, !cast.isEmpty { CastRow(cast: cast) }
                }
                .padding(.bottom, 60)
            } else if let e = series.loadFailed {
                ContentUnavailableView("Fiche indisponible", systemImage: "exclamationmark.triangle", description: Text(e))
                    .padding(.top, 120)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .task { await series.load() }
        .task(id: series.media?.title) {
            if let m = series.media ?? item?.media {
                await SeriesStreams.of(tmdbId).load(tmdbId: tmdbId, titles: [m.title, m.originalTitle ?? ""], year: m.year)
            }
        }
        .task(id: series.selected) {
            if let s = series.selected { series.show(season: s) }
        }
    }

    // MARK: en-tête

    private func hero(_ m: Media, _ item: LibraryItem?, _ snap: SeriesModel.Snapshot) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if m.backdropPath == nil {
                        LinearGradient(colors: [Color(white: 0.2), Theme.background], startPoint: .top, endPoint: .bottom)
                    } else if item != nil {
                        LocalImage(url: store.backdropURL(m))
                    } else {
                        RemoteImage(url: TMDbClient.imageURL(m.backdropPath, size: "w1280"))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height).clipped()
                HeroShade()

                VStack(alignment: .leading, spacing: 14) {
                    LogoOrTitle(logoPath: m.logoPath, title: m.title, maxWidth: 480, maxHeight: 160, fontSize: 52)
                    if let item {
                        MetaLine(item: item)
                    } else {
                        HStack(spacing: 8) {
                            Text((["Série", m.year.map(String.init)].compactMap { $0 } + m.genres.prefix(3)).joined(separator: " · "))
                            if let c = m.certification { SpecBadge(text: c) }
                            if let r = m.imdbRating ?? m.rating.map({ String(format: "%.1f", $0) }) { Text("★ \(r)") }
                        }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                    if let t = m.tagline, !t.isEmpty {
                        Text(t).font(.system(size: 14, weight: .medium).italic()).foregroundStyle(.white.opacity(0.7))
                    }
                    if let o = m.overview, !o.isEmpty {
                        Text(o).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(4).frame(maxWidth: 560, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        if let item {
                            LibraryItemButtons(item: item)
                        } else {
                            notOwnedActions(m, snap)
                        }
                    }
                    .padding(.top, 8)
                    if let e = tracker.grabErrors[series.key] {
                        Label("Téléchargement impossible : \(e)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 40)
            }
        }
        .frame(height: 620)
    }

    @ViewBuilder
    private func notOwnedActions(_ m: Media, _ snap: SeriesModel.Snapshot) -> some View {
        if let e = downloads.entry(for: series.key), !e.isDone {
            DownloadPill(progress: e.progress, label: [e.seasonLabel, e.statusLine].filter { !$0.isEmpty }.joined(separator: " · "))
        } else if tracker.pending.contains(series.key) {
            DownloadPill(progress: nil, label: "Envoi au téléchargement…")
        }
        if !tracker.configured {
            SettingsButton(tab: .indexer) {
                Label("Configurer les téléchargements", systemImage: "gearshape").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        } else {
            if series.loadingReleases.contains(snap.season), series.releases[snap.season] == nil {
                ProgressView().controlSize(.small)
            }
            SeasonActions(series: series, snap: snap, prominent: true)
            followButton(m)
        }
    }

    @ViewBuilder
    private func followButton(_ m: Media) -> some View {
        if tracker.isFollowed(m) {
            // suivie : qualité propre à la série, ou arrêter le suivi
            Menu {
                Picker("Qualité des nouveaux épisodes", selection: Binding(get: { tracker.quality(for: m.key) },
                                                                          set: { tracker.setQuality($0, for: m.key) })) {
                    Text("Comme dans les réglages (\(tracker.prefs.quality.rawValue))").tag(QualityChoice?.none)
                    ForEach(QualityChoice.allCases) { Text($0.rawValue).tag(QualityChoice?.some($0)) }
                }
                Divider()
                Button("Ne plus suivre") { tracker.unfollow(m.key) }
            } label: {
                Image(systemName: "bell.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Suivie : les nouveaux épisodes arrivent tout seuls")
        } else {
            Menu {
                Button("Suivre les nouveaux épisodes") { tracker.follow(m, backfill: false) }
                Button("Tout télécharger, puis suivre") { tracker.follow(m, backfill: true) }
            } label: {
                Image(systemName: "bell").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Suivre")
        }
    }

    // MARK: épisodes

    private func episodeList(_ m: Media, _ item: LibraryItem?, _ snap: SeriesModel.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(series.seasons, id: \.self) { s in
                        Button { series.selected = s } label: {
                            Text(s == 0 ? "Épisodes spéciaux" : "Saison \(s)")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(s == snap.season ? Color.white : Color.white.opacity(0.4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(s)
                    }
                }
                .padding(.horizontal, Theme.margin)
            }
            // beaucoup de saisons : celle qu'on regarde reste visible
            .onChange(of: snap.season) { _, s in withAnimation { proxy.scrollTo(s) } }
            .onAppear {
                let s = snap.season
                if series.seasons.count > 8 { DispatchQueue.main.async { proxy.scrollTo(s) } }
            }
            }

            // série possédée : « Lire » est le bouton principal, ceux de la saison vont ici
            if item != nil, tracker.configured, snap.plan.offerPack || !snap.plan.missing.isEmpty {
                HStack(spacing: 10) { SeasonActions(series: series, snap: snap, prominent: false) }
                    .padding(.horizontal, Theme.margin)
            }
            if let e = series.releaseErrors[snap.season] {
                HStack(spacing: 10) {
                    Label("Recherche des versions : \(e)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                    Button("Réessayer") { series.show(season: snap.season) }.buttonStyle(.link)
                }
                .font(.system(size: 13)).padding(.horizontal, Theme.margin)
            }

            if snap.numbers.isEmpty {
                HStack(spacing: 10) {
                    if series.episodes[snap.season] == nil || series.loadingEpisodes.contains(snap.season) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pas d'épisodes connus pour cette saison.").foregroundStyle(.secondary)
                        Button("Réessayer") { series.reloadEpisodes(snap.season) }.buttonStyle(.link)
                    }
                }
                .padding(.horizontal, Theme.margin)
            }
            LazyVStack(spacing: 4) {
                ForEach(snap.numbers, id: \.self) { e in
                    EpisodeRow(series: series, media: m, item: item, snap: snap, episode: e)
                }
            }
            .padding(.horizontal, Theme.margin - 12)
        }
    }

    /// Fichiers de la série sans numéro d'épisode : ils restent lisibles.
    @ViewBuilder
    private func otherFiles(_ item: LibraryItem) -> some View {
        let others = item.files.filter { $0.season == nil || $0.episode == nil }
        if !others.isEmpty {
            Shelf(title: "Autres fichiers") { ForEach(others) { EpisodeCard(item: item, file: $0) } }
        }
    }

    // MARK: saisons complètes

    private func packs(_ m: Media, _ snap: SeriesModel.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(snap.season == 0 ? "Spéciaux au complet" : "Saison \(snap.season) complète").font(.system(size: 21, weight: .bold))
                if !snap.packs.isEmpty {
                    Text("\(snap.packs.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                }
                if series.loadingReleases.contains(snap.season) { ProgressView().controlSize(.small) }
                Spacer()
                NavigationLink(value: "tracker") { Text("Chercher d'autres versions…").font(.system(size: 12)) }
                    .buttonStyle(.link)
                    .simultaneousGesture(TapGesture().onEnded { tracker.searchContext = m })
            }
            if series.releases[snap.season] != nil, snap.packs.isEmpty {
                Text("Pas de saison complète à télécharger.").foregroundStyle(.secondary)
            } else if snap.busy, !snap.packs.isEmpty {
                Text("Cette saison télécharge déjà : la reprendre en entier ferait des doublons.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Array(snap.packs.prefix(showAllPacks ? snap.packs.count : 4).enumerated()), id: \.element.id) { i, r in
                    ReleaseRow(release: r, recommended: i == 0 && r.score != nil, sent: tracker.isSent(r),
                               blocked: snap.busy ? "Cette saison est déjà en téléchargement." : nil) {
                        tracker.grab(r, media: m)
                    }
                }
            }
            if snap.packs.count > 4 {
                Button(showAllPacks ? "Moins de versions" : "Afficher les \(snap.packs.count) versions") {
                    withAnimation { showAllPacks.toggle() }
                }
                .buttonStyle(.link).font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

/// « Télécharger la saison » et « Télécharger les N épisodes manquants », dans l'ordre qui convient.
struct SeasonActions: View {
    @ObservedObject var series: SeriesModel
    let snap: SeriesModel.Snapshot
    /// true : l'action principale est la grosse pilule blanche de l'en-tête.
    let prominent: Bool

    var body: some View {
        if snap.plan.missingFirst {
            missing(first: true)
            pack(first: false)
        } else {
            pack(first: true)
            missing(first: !snap.plan.offerPack)
        }
    }

    @ViewBuilder private func pack(first: Bool) -> some View {
        if snap.plan.offerPack {
            button(snap.season == 0 ? "Télécharger les spéciaux" : "Télécharger la saison \(snap.season)", first: first,
                   help: snap.packs.first { $0.score != nil }?.item.releaseName ?? "") { series.downloadSeason(snap.season) }
        }
    }

    @ViewBuilder private func missing(first: Bool) -> some View {
        if !snap.plan.missing.isEmpty {
            let n = snap.plan.missing.count
            button(n > 1 ? "Télécharger les \(n) épisodes manquants" : "Télécharger l'épisode \(snap.plan.missing[0])", first: first,
                   help: "Épisodes " + snap.plan.missing.map(String.init).joined(separator: ", ")) { series.downloadMissing(snap.season) }
        }
    }

    @ViewBuilder
    private func button(_ title: String, first: Bool, help: String, action: @escaping () -> Void) -> some View {
        if prominent && first {
            PlayPill(title: title, icon: "arrow.down", action: action).help(help)
        } else {
            Button(action: action) { SmallPill(title: title, icon: "arrow.down", filled: first) }
                .buttonStyle(.plain).help(help)
        }
    }
}

/// Une ligne d'épisode : le clic ouvre sa fiche, le bouton de droite fait l'action de son état.
struct EpisodeRow: View {
    @ObservedObject var series: SeriesModel
    let media: Media
    let item: LibraryItem?
    let snap: SeriesModel.Snapshot
    let episode: Int
    @ObservedObject private var tracker = TrackerModel.shared
    @State private var hover = false

    @ObservedObject private var store = IPTVStore.shared
    private var status: EpisodeStatus { snap.statuses[episode] ?? .unknown }

    private func streamKey(_ v: VODEpisode) -> String { Watch.streamKey(titleKey) }
    private var titleKey: TitleKey { TitleKey(.tv, series.tmdbId, EpisodeKey(snap.season, episode)) }
    private var watchPoint: WatchPoint? { Watch.point(titleKey) }

    private func streamTitle(_ v: VODEpisode) -> String {
        let p = IPTVStore.shared.progress[streamKey(v)]
        return p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false ? "Reprendre en streaming" : "Streaming"
    }

    private func playStream(_ v: VODEpisode) {
        IPTVVOD.play(url: v.url, mediaKey: series.key, title: media.title,
                     subtitle: PlayItem(stream: v.url, title: media.title, key: titleKey).subtitle, progressKey: streamKey(v))
    }
    private var file: MediaFile? { snap.files[episode] }
    private var link: String { EpisodeLink.value(series.tmdbId, snap.season, episode) }

    var body: some View {
        HStack(spacing: 18) {
            NavigationLink(value: link) {
                HStack(spacing: 18) {
                    thumbnail
                    text
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 8) {
                trailing
                if case .owned = status {} else if SeriesStreams.of(series.tmdbId).episode(season: snap.season, episode: episode) != nil {
                    PlaySourceButton(key: titleKey, title: media.title, titles: [media.title, media.originalTitle ?? ""], year: media.year, compact: true)
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu {
            let sources = Sources.now(titleKey, titles: [media.title, media.originalTitle ?? ""], year: media.year)
            if !sources.isEmpty {
                Section("Lire depuis") {
                    ForEach(sources) { o in
                        Button { Sources.play(o, key: titleKey, title: media.title) } label: { Label(o.label, systemImage: o.icon) }
                    }
                }
            }
            let seen = watchPoint?.watched == true
            Button(seen ? "Marquer comme non vu" : "Marquer comme vu") { Watch.setWatched(titleKey, !seen) }
        }
    }

    private var thumbnail: some View {
        let info = series.info(snap.season, episode)
        let still = info?.stillPath ?? file?.stillPath
        return ZStack {
            Color(white: 0.15)
            if let still {
                RemoteImage(url: TMDbClient.imageURL(still, size: "w780"))
            } else if media.backdropPath != nil {
                RemoteImage(url: TMDbClient.imageURL(media.backdropPath, size: "w780")).opacity(0.35)
            }
        }
        .frame(width: 224, height: 126)
        .overlay {
            if case let .downloading(_, p, phase, _) = status {
                DownloadStrip(progress: p, phase: phase)
            } else if let w = watchPoint, w.inProgress {
                // la progression du titre, en fichier ou en streaming
                DownloadStrip(progress: w.fraction, phase: .downloading)
            }
        }
        .overlay(alignment: .topTrailing) {
            if watchPoint?.watched == true {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                    .foregroundStyle(.white, Color.black.opacity(0.55)).padding(7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var text: some View {
        let info = series.info(snap.season, episode)
        let meta = EpisodeText.meta(info)
        let overview = info?.overview ?? file?.episodeOverview ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "ÉPISODE \(episode)").font(.system(size: 10, weight: .heavy)).kerning(0.8).foregroundStyle(.secondary)
            Text(EpisodeText.title(info, file: file, episode: episode)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            if !meta.isEmpty { Text(meta).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            if !overview.isEmpty {
                Text(overview).font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .owned:
            PlaySourceButton(key: titleKey, title: media.title, titles: [media.title, media.originalTitle ?? ""], year: media.year, compact: true)
        case .sending:
            quiet("Envoi…", busy: true)
        case .arriving:
            quiet("Ajout à la bibliothèque…", busy: true)
        case let .downloading(hash, p, phase, inPack):
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(phase == .downloading ? "\(Int(p * 100)) %" : phase.label)
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(phase == .error ? Color.red : .white)
                    if inPack { Text("avec la saison").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Button {
                    let d = DownloadsModel.shared
                    phase == .paused || phase == .error ? d.resume([hash]) : d.pause([hash])
                } label: { ProgressRing(progress: p, phase: phase) }
                    .buttonStyle(.plain)
                    .help(phase == .paused || phase == .error ? "Reprendre" : "Mettre en pause")
            }
        case let .available(n):
            VStack(alignment: .trailing, spacing: 6) {
                if series.recommended(episode, snap) != nil {
                    Button { series.downloadEpisode(season: snap.season, episode: episode) } label: {
                        SmallPill(title: "Télécharger", icon: "arrow.down", filled: false)
                    }
                    .buttonStyle(.plain).help("La version recommandée")
                }
                NavigationLink(value: link) {
                    Text(series.recommended(episode, snap) == nil ? "Choisir parmi \(n) version\(n > 1 ? "s" : "")"
                                                                  : "\(n) version\(n > 1 ? "s" : "")")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).underline(hover)
                }
                .buttonStyle(.plain).help("Choisir une version")
            }
        case .inSeasonPack:
            quiet("Seulement en saison complète")
        case .upcoming:
            quiet(EpisodeText.date(series.info(snap.season, episode)?.airDate).map { "Diffusion le \($0)" } ?? "Pas encore diffusé")
        case .unavailable:
            quiet("Rien à télécharger")
        case .unknown:
            if !tracker.configured {
                quiet("")
            } else if series.releaseErrors[snap.season] != nil {
                quiet("Non vérifié")
            } else {
                quiet("", busy: true)
            }
        }
    }

    private func quiet(_ s: String, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(s).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

struct SmallPill: View {
    let title: String
    let icon: String
    let filled: Bool

    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(filled ? Theme.accent : Color.white.opacity(0.13), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Dégradés d'un en-tête : le bas fond dans la page, la gauche porte le texte.
struct HeroShade: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.background.opacity(0.9), location: 0.88),
                                   .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

@MainActor
enum EpisodeText {
    private static let input: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let output: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    static func date(_ iso: String?) -> String? {
        iso.flatMap { input.date(from: $0) }.map { output.string(from: $0) }
    }

    static func minutes(_ n: Int?) -> String? {
        n.map { $0 >= 60 ? "\($0 / 60) h \(String(format: "%02d", $0 % 60))" : "\($0) min" }
    }

    static func meta(_ info: EpisodeInfo?) -> String {
        [date(info?.airDate), minutes(info?.runtime)].compactMap { $0 }.joined(separator: " · ")
    }

    static func title(_ info: EpisodeInfo?, file: MediaFile?, episode: Int) -> String {
        for t in [info?.name, file?.episodeTitle] {
            if let t, !t.isEmpty { return t }
        }
        return "Épisode \(episode)"
    }
}
