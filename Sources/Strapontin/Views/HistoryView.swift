import StrapontinCore
import SwiftUI

/// Historique : ce qui a été regardé, du plus récent au plus ancien, groupé par jour, avec reprise et
/// « marquer comme non vu ». Construit à partir de la date de dernière lecture de chaque fichier.
struct HistoryView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var iptv = IPTVStore.shared

    /// Une lecture : un fichier de la bibliothèque, ou un film / épisode regardé en streaming (IPTV).
    private struct Entry: Identifiable {
        var id: String { stream?.key ?? file!.path }
        var file: MediaFile?
        var item: LibraryItem?
        var stream: StreamRecord?
        var date: Date
    }

    private var entries: [Entry] {
        var byPath: [String: LibraryItem] = [:]
        for i in store.items { for f in i.files { byPath[f.path] = i } }
        let files = store.files.compactMap { f -> Entry? in
            guard let t = f.lastPlayed, t > 0, let item = byPath[f.path] else { return nil }
            return Entry(file: f, item: item, date: Date(timeIntervalSince1970: t))
        }
        let streams = iptv.streams.map { Entry(stream: $0, date: $0.date) }
        // un titre n'apparaît qu'une fois, quelle que soit la source (la lecture la plus récente)
        var seen = Set<String>()
        return (files + streams).sorted { $0.date > $1.date }.filter { e in
            let title = e.file.flatMap(Watch.key(of:))?.id ?? e.stream.flatMap { Watch.title(fromStreamKey: $0.key)?.id }
            return title.map { seen.insert($0).inserted } ?? true
        }
    }

    private var groups: [(String, [Entry])] {
        let cal = Calendar.current
        var out: [(String, [Entry])] = []
        for e in entries {
            let label: String
            if cal.isDateInToday(e.date) { label = "Aujourd'hui" }
            else if cal.isDateInYesterday(e.date) { label = "Hier" }
            else if let d = cal.dateComponents([.day], from: e.date, to: Date()).day, d < 7 {
                label = e.date.formatted(.dateTime.weekday(.wide)).capitalized
            } else {
                label = e.date.formatted(.dateTime.day().month(.wide).year())
            }
            if out.last?.0 == label { out[out.count - 1].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Historique").font(.system(size: 30, weight: .bold))
                if entries.isEmpty {
                    ContentUnavailableView("Rien regardé pour l'instant", systemImage: "clock.arrow.circlepath",
                                           description: Text("Ce que tu regardes apparaît ici, du plus récent au plus ancien."))
                        .padding(.top, 80)
                }
                ForEach(groups, id: \.0) { label, list in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(label).font(.system(size: 17, weight: .bold)).foregroundStyle(.secondary)
                        ForEach(list) { row($0) }
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 96).padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.backdrop)
    }

    @ViewBuilder private func row(_ e: Entry) -> some View {
        if let r = e.stream { streamRow(r) } else if let f = e.file, let item = e.item { fileRow(f, item, e.date) }
    }

    private func streamRow(_ r: StreamRecord) -> some View {
        let p = iptv.progress[r.key]
        let media = r.mediaKey.flatMap { store.media[$0] }
        let done = p.map { $0[1] > 0 && $0[0] >= $0[1] * 0.95 } ?? false
        return HStack(spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.16)
                if let m = media { LocalImage(url: store.backdropURL(m)) }
                Image(systemName: "play.tv").font(.system(size: 22)).foregroundStyle(.white.opacity(media == nil ? 0.5 : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let p, p[1] > 0, p[0] > 0, !done {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, p[0] / p[1])) }
                        }
                        .padding(6)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(["En streaming", r.subtitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text((done ? "Vu · " : p.map { "Arrêté à \(formatTime($0[0])) · " } ?? "") + r.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let k = r.mediaKey {
                // reprendre avec la meilleure source (fichier s'il est arrivé depuis, sinon streaming), sinon la fiche
                Button {
                    Task {
                        let ok = await Watch.title(fromStreamKey: r.key).asyncMap { await Watch.playBest($0, title: r.title, year: nil) } ?? false
                        if !ok { GoTo.open(k) }
                    }
                } label: {
                    SmallPill(title: done ? "Revoir" : "Reprendre", icon: done ? "arrow.counterclockwise" : "play.fill", filled: !done)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
    }

    private func fileRow(_ f: MediaFile, _ item: LibraryItem, _ date: Date) -> some View {
        let e = (file: f, item: item, date: date)
        let episode = f.season.flatMap { s in f.episode.map { String(format: "S%d, É%d", s, $0) } }
        return HStack(spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.16)
                if let still = f.stillPath {
                    RemoteImage(url: TMDbClient.imageURL(still, size: "w300"))
                } else if let m = e.item.media {
                    LocalImage(url: store.backdropURL(m))
                }
                if f.duration > 0, f.position > 0, !f.watched {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, f.position / f.duration)) }
                        }
                        .padding(6)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(e.item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([episode, f.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(f.watched ? "Vu · " + e.date.formatted(date: .omitted, time: .shortened)
                               : "Arrêté à \(formatTime(f.position)) · " + e.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            SmallPill(title: f.watched ? "Revoir" : "Reprendre", icon: f.watched ? "arrow.counterclockwise" : "play.fill", filled: !f.watched)
                .onTapGesture { play(e.item, from: f, resume: !f.watched) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .contextMenu {
            Button(f.watched ? "Marquer comme non vu" : "Marquer comme vu") { store.setWatched([f.path], !f.watched) }
            NavigationLink(value: e.item.media.map { Media.key($0.kind, $0.tmdbId) } ?? e.item.id) { Text("Voir la fiche") }
        }
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let v = self else { return nil }
        return await f(v)
    }
}
