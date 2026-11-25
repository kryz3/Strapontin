import StrapontinCore
import SwiftUI

/// Historique : ce qui a été regardé, du plus récent au plus ancien, groupé par jour, avec reprise et
/// « marquer comme non vu ». Construit à partir de la date de dernière lecture de chaque fichier.
struct HistoryView: View {
    @EnvironmentObject var store: LibraryStore

    private struct Entry: Identifiable {
        var id: String { file.path }
        var file: MediaFile
        var item: LibraryItem
        var date: Date
    }

    private var entries: [Entry] {
        var byPath: [String: LibraryItem] = [:]
        for i in store.items { for f in i.files { byPath[f.path] = i } }
        return store.files.compactMap { f -> Entry? in
            guard let t = f.lastPlayed, t > 0, let item = byPath[f.path] else { return nil }
            return Entry(file: f, item: item, date: Date(timeIntervalSince1970: t))
        }
        .sorted { $0.date > $1.date }
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

    private func row(_ e: Entry) -> some View {
        let f = e.file
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
