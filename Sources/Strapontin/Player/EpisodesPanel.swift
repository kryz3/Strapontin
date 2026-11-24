import StrapontinCore
import SwiftUI

/// Panneau « Épisodes » du lecteur, façon Netflix : toute la saison par-dessus la vidéo (qui continue derrière),
/// avec image, numéro, titre, durée, résumé, progression et disponibilité de chaque épisode.
/// Clic : lire tout de suite s'il est là, sinon lancer le téléchargement (l'état change aussitôt).
struct EpisodesPanel: View {
    @ObservedObject var series: SeriesModel
    let current: EpisodeKey?
    let actions: PlayerActions
    @ObservedObject private var downloads = DownloadsModel.shared
    @ObservedObject private var tracker = TrackerModel.shared
    @State private var season: Int?

    private var seasons: [Int] {
        let owned = Set(series.files.compactMap(\.season))
        let list = Set(series.tmdbSeasons).union(owned).filter { $0 > 0 }
        return list.isEmpty ? Array(owned).sorted() : list.sorted()
    }

    private var shown: Int { season ?? current?.season ?? seasons.first ?? 1 }

    var body: some View {
        let snap = series.snapshot(shown)
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(snap.numbers, id: \.self) { n in
                            row(n, snap: snap).id(n)
                        }
                        if snap.numbers.isEmpty {
                            if series.loadingEpisodes.contains(shown) {
                                ForEach(0..<4, id: \.self) { _ in Skeleton(corner: 10).frame(height: 96) }
                            } else {
                                Text("Aucun épisode connu pour cette saison.").foregroundStyle(.secondary).padding(20)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 24)
                }
                .onAppear {
                    // l'épisode en cours est visible dès l'ouverture
                    if let c = current, c.season == shown { proxy.scrollTo(c.episode, anchor: .center) }
                }
                .onChange(of: snap.numbers) { _, _ in
                    if let c = current, c.season == shown { proxy.scrollTo(c.episode, anchor: .center) }
                }
            }
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.35))
        .environment(\.colorScheme, .dark)
        .onChange(of: shown, initial: true) { _, s in series.show(season: s) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(series.media?.title ?? "Épisodes").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("Épisodes").font(.system(size: 24, weight: .bold))
            }
            Spacer()
            if seasons.count > 1 {
                Picker("", selection: Binding(get: { shown }, set: { season = $0 })) {
                    ForEach(seasons, id: \.self) { Text("Saison \($0)").tag($0) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text("Saison \(shown)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
            Button(action: actions.toggleEpisodes) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(GlassCircle(size: 30))
            .help("Fermer (Échap)")
        }
        .padding(.horizontal, 22).padding(.top, 54).padding(.bottom, 14)
    }

    private func row(_ n: Int, snap: SeriesModel.Snapshot) -> some View {
        let info = series.info(shown, n)
        let file = snap.files[n]
        let status = snap.statuses[n] ?? .unknown
        let isCurrent = current == EpisodeKey(shown, n)
        return Button {
            if let file {
                if !isCurrent { actions.playEpisode(file) } else { actions.toggleEpisodes() }
            } else if case .available = status {
                series.downloadEpisode(season: shown, episode: n)
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    Color(white: 0.16)
                    if let still = info?.stillPath ?? file?.stillPath {
                        RemoteImage(url: TMDbClient.imageURL(still, size: "w300"))
                    }
                    if let file, file.duration > 0, file.position > 0, !file.watched {
                        Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, file.position / file.duration))
                                }
                            }
                            .padding(6)
                    }
                    if isCurrent {
                        Label("En cours", systemImage: "play.fill").font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule()).padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(n). \(EpisodeText.title(info, file: file, episode: n))")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let m = EpisodeText.minutes(info?.runtime) {
                            Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let o = info?.overview, !o.isEmpty {
                        Text(o).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stateLine(status, file: file)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? Theme.accentText.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(file == nil && !isActionable(status))
    }

    private func isActionable(_ s: EpisodeStatus) -> Bool {
        if case .available = s { return true }
        return false
    }

    @ViewBuilder private func stateLine(_ status: EpisodeStatus, file: MediaFile?) -> some View {
        Group {
            switch status {
            case .owned:
                if file?.watched == true { Label("Vu", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                else if file?.inProgress == true { Label("Reprendre", systemImage: "play.fill").foregroundStyle(.white) }
                else { Label("Lire", systemImage: "play.fill").foregroundStyle(.white) }
            case .sending:
                Label("Envoi…", systemImage: "arrow.down.circle").foregroundStyle(Theme.accentText)
            case .downloading(_, let progress, let phase, _):
                Label("\(phase.label) · \(Int(progress * 100)) %", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accentText)
            case .arriving:
                Label("Arrive dans la bibliothèque…", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accentText)
            case .available(let n):
                Label("Télécharger · \(n) version\(n > 1 ? "s" : "")", systemImage: "arrow.down").foregroundStyle(Theme.accentText)
            case .inSeasonPack:
                Label("Seulement en saison complète", systemImage: "shippingbox").foregroundStyle(.secondary)
            case .upcoming:
                Label("Pas encore diffusé", systemImage: "calendar").foregroundStyle(.secondary)
            case .unavailable:
                Label(tracker.configured ? "Rien sur l'indexeur" : "Pas dans la bibliothèque", systemImage: "minus.circle").foregroundStyle(.secondary)
            case .unknown:
                Label(tracker.configured ? "Recherche des versions…" : "Pas dans la bibliothèque", systemImage: "ellipsis").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }
}
