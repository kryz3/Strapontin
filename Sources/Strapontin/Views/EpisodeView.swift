import AppKit
import StrapontinCore
import SwiftUI

/// La fiche d'un épisode. Une seule page : Télécharger → progression → Lire, d'elle-même.
/// Précédent / suivant changent le contenu de la page, le retour ramène à la série, sur la même saison.
struct EpisodeView: View {
    @ObservedObject private var series: SeriesModel
    @ObservedObject private var tracker = TrackerModel.shared
    @ObservedObject private var downloads = DownloadsModel.shared
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: EpisodeKey
    @State private var showAll = false
    /// Passage à la saison voisine en attente de la liste de ses épisodes : +1 ou -1.
    @State private var entering: Int?

    init(tmdbId: Int, season: Int, episode: Int) {
        series = SeriesModel.of(tmdbId)
        _current = State(initialValue: EpisodeKey(season, episode))
    }

    private var info: EpisodeInfo? { series.info(current.season, current.episode) }

    var body: some View {
        let snap = series.snapshot(current.season)
        let status = snap.statuses[current.episode] ?? .unknown
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                hero(snap, status)
                downloadPanel
                if tracker.configured { versions(snap, status) }
                neighbours(snap)
            }
            .padding(.bottom, 60)
        }
        .id(current)   // épisode suivant : la page repart du haut
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .task(id: current) {
            showAll = false
            series.selected = current.season
            series.show(season: current.season, episode: current.episode)
        }
        .onChange(of: series.episodes) { _, all in
            guard let d = entering, let list = all[current.season]?.keys.sorted(),
                  let e = d > 0 ? list.first : list.last else { return }
            entering = nil
            current = EpisodeKey(current.season, e)
        }
        .onReceive(EssaiHarness.shared.$serial.dropFirst()) { _ in
            // copie d'essai seulement : « Épisode suivant » piloté pour les captures
            if case let .step(d)? = EssaiHarness.shared.command, let to = neighbour(d, series.snapshot(current.season)) { go(to, d) }
        }
    }

    // MARK: en-tête

    private func hero(_ snap: SeriesModel.Snapshot, _ status: EpisodeStatus) -> some View {
        let file = snap.files[current.episode]
        let image = info?.stillPath ?? file?.stillPath ?? series.media?.backdropPath
        let overview = info?.overview ?? file?.episodeOverview ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 190)
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text(verbatim: "\(series.media?.title ?? "Série") · \(current.season == 0 ? "Épisodes spéciaux" : "Saison \(current.season)") · Épisode \(current.episode)")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.8)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Revenir à la série")
            Text(EpisodeText.title(info, file: file, episode: current.episode))
                .font(.system(size: 46, weight: .heavy)).lineLimit(2).shadow(color: .black.opacity(0.5), radius: 12)
                .frame(maxWidth: 760, alignment: .leading)
            HStack(spacing: 8) {
                Text(([EpisodeText.meta(info)] + [info?.rating.map { "★ " + String(format: "%.1f", $0) } ?? ""])
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                if status == .owned, file?.quality?.hasPrefix("4K") == true { SpecBadge(text: "4K") }
            }
            if !overview.isEmpty {
                Text(overview).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                    .textSelection(.enabled)
            }
            credits
            HStack(spacing: 12) { actions(snap, status, file) }.padding(.top, 8)
            if let e = tracker.grabErrors[series.key] {
                Label("Téléchargement impossible : \(e)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, minHeight: 620, alignment: .bottomLeading)
        .background {
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Theme.background], startPoint: .top, endPoint: .bottom)
                Color.clear.overlay { RemoteImage(url: TMDbClient.imageURL(image, size: "original")) }.clipped()
                HeroShade()
            }
        }
    }

    @ViewBuilder private var credits: some View {
        let directors = info?.directors ?? [], writers = info?.writers ?? []
        if !directors.isEmpty || !writers.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                if !directors.isEmpty {
                    GridRow {
                        Text("Réalisation").foregroundStyle(.white.opacity(0.55))
                        Text(directors.joined(separator: ", "))
                    }
                }
                if !writers.isEmpty {
                    GridRow {
                        Text("Scénario").foregroundStyle(.white.opacity(0.55))
                        Text(writers.joined(separator: ", "))
                    }
                }
            }
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.88))
        }
    }

    @ViewBuilder
    private func actions(_ snap: SeriesModel.Snapshot, _ status: EpisodeStatus, _ file: MediaFile?) -> some View {
        switch status {
        case .owned:
            if let f = file, let item = store.item(id: series.key) {
                PlayPill(title: f.inProgress ? "Reprendre" : "Lire") { play(item, from: f, resume: f.inProgress) }
                if f.inProgress {
                    Button { play(item, from: f, resume: false) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(CircleButtonStyle()).help("Lire depuis le début")
                }
                Button { store.setWatched([f.path], !f.watched) } label: {
                    Image(systemName: f.watched ? "checkmark" : "plus").font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle()).help(f.watched ? "Marquer comme non vu" : "Marquer comme vu")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: {
                    Image(systemName: "folder").font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle()).help("Afficher dans le Finder")
            }
        case .sending:
            DownloadPill(progress: nil, label: "Envoi au téléchargement…")
        case .arriving:
            DownloadPill(progress: nil, label: "Ajout à la bibliothèque…")
        case let .downloading(hash, p, phase, inPack):
            DownloadPill(progress: p, label: pillLabel(hash, p, phase) + (inPack ? " · avec la saison" : ""))
            let stopped = phase == .paused || phase == .error
            Button { stopped ? downloads.resume([hash]) : downloads.pause([hash]) } label: {
                Image(systemName: stopped ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(CircleButtonStyle()).help(stopped ? "Reprendre" : "Mettre en pause")
        case .available:
            if let best = series.recommended(current.episode, snap) {
                PlayPill(title: "Télécharger", icon: "arrow.down") {
                    series.downloadEpisode(season: current.season, episode: current.episode)
                }
                .help(best.item.releaseName)
            } else {
                note("Aucune version ne correspond à tes préférences : choisis-en une plus bas.")
            }
        case .inSeasonPack:
            if snap.plan.offerPack {
                PlayPill(title: "Télécharger la saison \(current.season)", icon: "arrow.down") { series.downloadSeason(current.season) }
                    .help("Cet épisode n'existe qu'en saison complète")
            } else {
                note("Seulement en saison complète")
            }
        case .upcoming:
            note(EpisodeText.date(info?.airDate).map { "Diffusion le \($0)" } ?? "Pas encore diffusé")
        case .unavailable:
            note("Rien sur l'indexeur pour l'instant")
        case .unknown:
            if !tracker.configured {
                SettingsLink { SmallPill(title: "Brancher un indexeur pour télécharger", icon: "gearshape", filled: false) }.buttonStyle(.plain)
            } else if series.releaseErrors[current.season] != nil {
                note("L'indexeur n'a pas pu être consulté")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func pillLabel(_ hash: String, _ p: Double, _ phase: DownloadPhase) -> String {
        let pct = "\(Int(p * 100)) %"
        guard phase == .downloading, let t = downloads.torrents.first(where: { $0.hash == hash }), t.dlspeed > 0 else {
            return phase == .downloading ? pct : "\(phase.label) · \(pct)"
        }
        return [pct, "\(humanSize(t.dlspeed))/s", etaText(t.eta)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var downloadPanel: some View {
        let hashes = Set(downloads.allTransfers(for: series.key)
            .filter { !$0.torrent.isDone && $0.covers(season: current.season, episode: current.episode) }
            .map(\.torrent.hash))
        if !hashes.isEmpty { DownloadPanel(entryId: series.key, showFinished: false, only: hashes) }
    }

    // MARK: versions

    private func versions(_ snap: SeriesModel.Snapshot, _ status: EpisodeStatus) -> some View {
        let list = series.versions(current.season, current.episode)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(status == .owned ? "Autres versions de cet épisode" : "Versions de cet épisode").font(.system(size: 21, weight: .bold))
                if !list.isEmpty {
                    Text("\(list.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                }
                if series.loadingReleases.contains(current.season) || series.searchingEpisodes.contains(current) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let e = series.releaseErrors[current.season] {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            } else if status.isBusy {
                Text("Cet épisode est déjà en téléchargement : annule-le pour prendre une autre version.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else if series.releases[current.season] != nil, list.isEmpty {
                Text(snap.packs.isEmpty ? "Aucune version sur l'indexeur."
                                        : "Pas de version de cet épisode seul : il est dans la saison complète.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Array(list.prefix(showAll ? list.count : 8).enumerated()), id: \.element.id) { i, r in
                    ReleaseRow(release: r, recommended: i == 0 && r.score != nil, sent: tracker.isSent(r),
                               blocked: series.overlapsBusy(r, snap) ? "Un épisode de cette version est déjà en téléchargement." : nil) {
                        if let m = series.media { tracker.grab(r, media: m) }
                    }
                }
            }
            if list.count > 8 {
                Button(showAll ? "Moins de versions" : "Afficher les \(list.count) versions") { withAnimation { showAll.toggle() } }
                    .buttonStyle(.link).font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: précédent / suivant

    /// L'épisode voisin. Saison voisine pas encore chargée : épisode 1 en attendant sa liste.
    private func neighbour(_ d: Int, _ snap: SeriesModel.Snapshot) -> EpisodeKey? {
        let next = d > 0 ? snap.numbers.first { $0 > current.episode } : snap.numbers.last { $0 < current.episode }
        if let next { return EpisodeKey(current.season, next) }
        let seasons = series.seasons.filter { $0 > 0 }
        guard !snap.numbers.isEmpty, current.season > 0,
              let s = d > 0 ? seasons.first(where: { $0 > current.season }) : seasons.last(where: { $0 < current.season }) else { return nil }
        let list = series.episodes[s]?.keys.sorted() ?? []
        return EpisodeKey(s, (d > 0 ? list.first : list.last) ?? 1)
    }

    private func go(_ to: EpisodeKey, _ d: Int) {
        entering = to.season != current.season && (series.episodes[to.season]?.isEmpty ?? true) ? d : nil
        current = to
    }

    private func neighbours(_ snap: SeriesModel.Snapshot) -> some View {
        HStack(spacing: 16) {
            if let p = neighbour(-1, snap) { neighbourCard(p, -1) }
            Spacer(minLength: 0)
            if let n = neighbour(1, snap) { neighbourCard(n, 1) }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func neighbourCard(_ k: EpisodeKey, _ d: Int) -> some View {
        let i = series.info(k.season, k.episode)
        let otherSeason = k.season != current.season
        // saison précédente pas encore chargée : on ne connaît pas le numéro de son dernier épisode
        let detail = otherSeason && i == nil ? "Saison \(k.season)"
            : (otherSeason ? "Saison \(k.season) · " : "") + "\(k.episode). " + EpisodeText.title(i, file: nil, episode: k.episode)
        return Button { go(k, d) } label: {
            HStack(spacing: 14) {
                if d < 0 { Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)) }
                ZStack {
                    Color(white: 0.16)
                    RemoteImage(url: TMDbClient.imageURL(i?.stillPath ?? series.media?.backdropPath, size: "w780"))
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(d < 0 ? "ÉPISODE PRÉCÉDENT" : "ÉPISODE SUIVANT")
                        .font(.system(size: 10, weight: .heavy)).kerning(0.8).foregroundStyle(.secondary)
                    Text(detail).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
                if d > 0 { Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
