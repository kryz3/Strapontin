import StrapontinCore
import SwiftUI

/// Le suivi d'un titre (film ou épisode TMDb), quelle que soit la source : fichier de la bibliothèque, streaming IPTV.
///
/// Un seul état par titre : la position la plus récente, d'où qu'elle vienne, sert à reprendre ; « vu » vaut pour
/// toutes les sources. Le streaming garde ses points dans IPTVStore (clé « stream:<titre> ») ; les fichiers dans la
/// bibliothèque ; chaque lecture met les deux à jour.
@MainActor
enum Watch {
    // MARK: clés

    static func key(of f: MediaFile) -> TitleKey? {
        guard let mk = f.mediaKey, let (kind, id) = TMDbLink.parseKey(mk) else { return nil }
        if kind == .tv {
            guard let s = f.season, let e = f.episode else { return nil }
            return TitleKey(.tv, id, EpisodeKey(s, e))
        }
        return TitleKey(.movie, id)
    }

    static func streamKey(_ k: TitleKey) -> String { "stream:" + k.id }

    static func title(fromStreamKey key: String) -> TitleKey? {
        guard key.hasPrefix("stream:") else { return nil }
        return TitleKey(id: String(key.dropFirst(7)))
    }

    // MARK: points

    static func filePoint(_ f: MediaFile) -> WatchPoint? {
        guard f.watched || (f.lastPlayed ?? 0) > 0 else { return nil }
        return WatchPoint(position: f.position, duration: f.duration, date: f.lastPlayed ?? 0, watched: f.watched)
    }

    static func streamPoint(_ k: TitleKey) -> WatchPoint? {
        guard let p = IPTVStore.shared.progress[streamKey(k)], p.count >= 2 else { return nil }
        let watched = p[1] > 0 && p[0] >= p[1] * 0.95
        return WatchPoint(position: watched ? 0 : p[0], duration: p[1], date: p.count > 2 ? p[2] : 0, watched: watched)
    }

    /// Fichiers de la bibliothèque pour ce titre.
    static func files(_ k: TitleKey) -> [MediaFile] {
        LibraryStore.shared.files.filter { f in
            guard f.mediaKey == k.mediaKey else { return false }
            guard let e = k.episode else { return true }
            return f.season == e.season && f.episode == e.episode
        }
    }

    static func point(_ k: TitleKey) -> WatchPoint? {
        files(k).compactMap(filePoint).reduce(streamPoint(k)) { WatchMerge.latest($0, $1) }
    }

    static func resume(_ k: TitleKey) -> Double { point(k).map { $0.inProgress ? $0.position : 0 } ?? 0 }

    // MARK: écrire

    /// Après une lecture (fichier ou streaming) : le titre est à jour pour toutes ses sources.
    /// `playedPath` : le fichier qui vient d'être lu (déjà enregistré par la bibliothèque).
    static func save(_ k: TitleKey, position: Double, duration: Double, finished: Bool, playedPath: String? = nil) {
        let watched = finished || (duration > 0 && position >= duration * 0.95)
        IPTVStore.shared.saveProgress(streamKey(k), position: watched ? max(duration, 1) : position, duration: max(duration, watched ? 1 : 0))
        for f in files(k) where f.path != playedPath {
            LibraryStore.shared.saveProgress(path: f.path, position: position, duration: duration > 0 ? duration : f.duration,
                                             finished: watched)
        }
    }

    static func setWatched(_ k: TitleKey, _ watched: Bool) {
        if watched {
            IPTVStore.shared.saveProgress(streamKey(k), position: 1, duration: 1)
        } else {
            IPTVStore.shared.clearProgress(streamKey(k))
        }
        let paths = files(k).map(\.path)
        if !paths.isEmpty { LibraryStore.shared.setWatched(paths, watched, mirror: false) }
    }

    // MARK: lire avec la meilleure source

    /// Fichier si on l'a, sinon streaming ; nil : il faut le télécharger (la fiche le propose).
    static func playBest(_ k: TitleKey, title: String, year: Int?) async -> Bool {
        if let f = files(k).first, let item = LibraryStore.shared.items.first(where: { $0.files.contains(f) }) {
            play(item, from: f, resume: true)
            return true
        }
        switch k.kind {
        case .movie:
            if let r = IPTVVOD.find(.movie, tmdbId: k.tmdbId, titles: [title], year: year).first, let u = IPTVStore.shared.url(of: r) {
                IPTVVOD.play(url: u, mediaKey: k.mediaKey, title: title, progressKey: streamKey(k))
                return true
            }
        case .tv:
            guard let e = k.episode else { return false }
            let streams = SeriesStreams.of(k.tmdbId)
            await streams.load(tmdbId: k.tmdbId, titles: [title], year: year)
            if let v = streams.episode(season: e.season, episode: e.episode) {
                IPTVVOD.play(url: v.url, mediaKey: k.mediaKey, title: title, subtitle: "Saison \(e.season), épisode \(e.episode)",
                             progressKey: streamKey(k))
                return true
            }
        }
        return false
    }
}

/// « À suivre » : un titre par fiche (film commencé, prochain épisode d'une série), toutes sources confondues.
struct ContinueEntry: Identifiable, Hashable {
    var key: TitleKey
    var title: String
    var year: Int?
    var fraction: Double
    var date: Double
    var backdrop: String?
    var id: String { key.mediaKey }
    var label: String? { key.episode.map { "S\($0.season) · É\($0.episode)" } }
}

@MainActor
enum ContinueWatching {
    private static let hiddenKey = "continueHidden"

    /// Retiré d'« À suivre » (jusqu'à la prochaine lecture de ce titre).
    static func hide(_ mediaKey: String) {
        var h = UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: Double] ?? [:]
        h[mediaKey] = Date().timeIntervalSince1970
        UserDefaults.standard.set(h, forKey: hiddenKey)
        IPTVStore.shared.objectWillChange.send()
    }

    static func entries(kind: MediaKind?) -> [ContinueEntry] {
        let lib = LibraryStore.shared, iptv = IPTVStore.shared
        let hidden = UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: Double] ?? [:]
        // les fiches touchées, par la bibliothèque ou le streaming
        var titles: [String: (title: String, year: Int?, backdrop: String?)] = [:]
        for i in lib.items { if let m = i.media { titles[m.key] = (m.title, m.year, m.backdropPath) } }
        for r in iptv.streams { if let k = r.mediaKey, titles[k] == nil { titles[k] = (r.title, nil, nil) } }
        var out: [ContinueEntry] = []
        for (mk, info) in titles {
            guard let (k, id) = TMDbLink.parseKey(mk), kind == nil || kind == k else { continue }
            if k == .movie {
                let t = TitleKey(.movie, id)
                guard let p = Watch.point(t), p.inProgress, p.date > hidden[mk] ?? 0 else { continue }
                out.append(ContinueEntry(key: t, title: info.title, year: info.year, fraction: p.fraction, date: p.date, backdrop: info.backdrop))
            } else {
                var watch: [EpisodeKey: WatchPoint] = [:]
                var files: [EpisodeKey: String] = [:]
                for f in lib.files where f.mediaKey == mk {
                    guard let s = f.season, let e = f.episode else { continue }
                    files[EpisodeKey(s, e)] = f.path
                    if let p = Watch.filePoint(f) { watch[EpisodeKey(s, e)] = p }
                }
                let prefix = "stream:\(mk):"
                for key in iptv.progress.keys where key.hasPrefix(prefix) {
                    guard let t = Watch.title(fromStreamKey: key), let e = t.episode, let p = Watch.streamPoint(t) else { continue }
                    watch[e] = WatchMerge.latest(watch[e], p)
                }
                guard let last = watch.values.map(\.date).max(), last > hidden[mk] ?? 0 else { continue }
                let series = SeriesModel.of(id)
                let known = series.episodes.flatMap { s, eps in eps.keys.map { EpisodeKey(s, $0) } }
                let streams = SeriesStreams.of(id)
                var streamURLs: [EpisodeKey: String] = [:]
                if let r = streams.ref { for e in iptv.episodes[r.id] ?? [] { streamURLs[EpisodeKey(e.season, e.episode)] = e.url } }
                guard let up = CrossSource.upNext(watch: watch, known: known, sources: CrossSource.sources(files: files, streams: streamURLs))
                else { continue }
                let p = watch[up.0]
                out.append(ContinueEntry(key: TitleKey(.tv, id, up.0), title: info.title, year: info.year,
                                         fraction: p?.inProgress == true ? p!.fraction : 0, date: last, backdrop: info.backdrop))
            }
        }
        return out.sorted { $0.date > $1.date }
    }
}

/// Une vignette d'« À suivre » : le titre, l'épisode, la progression ; un clic reprend avec la meilleure source.
struct ContinueCard: View {
    let entry: ContinueEntry
    @EnvironmentObject var store: LibraryStore
    @State private var hover = false

    var body: some View {
        Button {
            // pas de source pour l'instant : la fiche, qui propose de le télécharger
            Task { if !(await Watch.playBest(entry.key, title: entry.title, year: entry.year)) { GoTo.open(entry.key.mediaKey) } }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    Color(white: 0.15)
                    if let m = store.media[entry.key.mediaKey], m.backdropPath != nil {
                        LocalImage(url: store.backdropURL(m))
                    } else if let b = entry.backdrop {
                        RemoteImage(url: TMDbClient.imageURL(b, size: "w780"))
                    } else {
                        GenericPoster(title: entry.title, kind: entry.key.kind, subtitle: entry.label)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                            if let l = entry.label { Text(l).font(.system(size: 11, weight: .semibold)).opacity(0.8) }
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(.white, in: Circle())
                            .opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
                    }
                    .foregroundStyle(.white)
                    .padding(12).padding(.bottom, 6)
                    if entry.fraction > 0 {
                        GeometryReader { g in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.3))
                                    Capsule().fill(.white).frame(width: g.size.width * entry.fraction)
                                }
                                .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 7)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Sheen(active: hover) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 6, y: hover ? 10 : 3)
            }
            .frame(width: 300)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .contextMenu {
            NavigationLink(value: entry.key.mediaKey) { Text("Voir la fiche") }
            Button("Retirer d'« À suivre »") { ContinueWatching.hide(entry.key.mediaKey) }
            Button("Marquer comme vu") { Watch.setWatched(entry.key, true) }
        }
    }
}

/// La rangée « À suivre » : bibliothèque et streaming ensemble, une carte par titre.
struct ContinueShelf: View {
    var kind: MediaKind?
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var iptv = IPTVStore.shared

    var body: some View {
        let entries = ContinueWatching.entries(kind: kind)
        if !entries.isEmpty {
            Shelf(title: "À suivre") { ForEach(entries) { ContinueCard(entry: $0) } }
        }
    }
}
