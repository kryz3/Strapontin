import StrapontinCore
import SwiftUI

/// D'où peut venir la vidéo d'un titre : un fichier téléchargé, ou une version en streaming. Toujours dans cet
/// ordre (la meilleure d'abord) ; la reprise est celle du titre, quelle que soit la source choisie.
struct SourceOption: Identifiable, Hashable {
    enum Kind: Hashable { case file(String), stream(String) }
    var kind: Kind
    /// « Fichier téléchargé · Full HD · MULTI », « Streaming · VOSTFR ».
    var label: String
    var id: String { switch kind { case .file(let p): "f:" + p; case .stream(let u): "s:" + u } }
    var isFile: Bool { if case .file = kind { return true }; return false }
    /// Le mot du bouton : « Fichier » ou « Streaming ».
    var short: String { isFile ? "Fichier" : "Streaming" }
    var icon: String { isFile ? "internaldrive" : "play.tv" }
}

@MainActor
enum Sources {
    /// « Full HD · MULTI » d'après un nom de fichier ou de version (rien si on ne sait pas).
    static func detail(_ name: String) -> String {
        let d = IPTVVOD.sourceLabel(name)
        return d == "Standard" ? "" : d
    }

    /// Les sources connues tout de suite (sans réseau) : fichiers, versions en streaming déjà chargées.
    static func now(_ k: TitleKey, titles: [String], year: Int?) -> [SourceOption] {
        var out: [SourceOption] = Watch.files(k).map { f in
            let d = detail(f.fileName)
            return SourceOption(kind: .file(f.path), label: "Fichier téléchargé" + (d.isEmpty ? "" : " · \(d)"))
        }
        switch k.kind {
        case .movie:
            for r in IPTVVOD.find(.movie, tmdbId: k.tmdbId, titles: titles, year: year) {
                if let u = IPTVStore.shared.url(of: r) { out.append(SourceOption(kind: .stream(u), label: streamLabel(r.name))) }
            }
        case .tv:
            guard let e = k.episode else { break }
            let s = SeriesStreams.of(k.tmdbId)
            for r in s.refs {
                if let ep = IPTVStore.shared.episodes[r.id]?.first(where: { $0.season == e.season && $0.episode == e.episode }) {
                    out.append(SourceOption(kind: .stream(ep.url), label: streamLabel(r.name)))
                }
            }
        }
        return dedupe(out)
    }

    /// Toutes les sources, en chargeant au besoin les épisodes de chaque version de la série.
    static func all(_ k: TitleKey, titles: [String], year: Int?) async -> [SourceOption] {
        if k.kind == .tv, let e = k.episode {
            let s = SeriesStreams.of(k.tmdbId)
            await s.load(tmdbId: k.tmdbId, titles: titles, year: year)
            for r in s.refs { _ = await s.episode(season: e.season, episode: e.episode, in: r) }
        }
        return now(k, titles: titles, year: year)
    }

    static func streamLabel(_ name: String) -> String {
        let d = detail(name)
        return "Streaming" + (d.isEmpty ? "" : " · \(d)")
    }

    private static func dedupe(_ list: [SourceOption]) -> [SourceOption] {
        var seen = Set<String>()
        // deux versions au même libellé : le nom du fournisseur ne dit rien à l'utilisateur, on numérote
        var count: [String: Int] = [:]
        return list.filter { seen.insert($0.id).inserted }.map { o in
            count[o.label, default: 0] += 1
            var o = o
            if count[o.label]! > 1 { o.label += " (\(count[o.label]!))" }
            return o
        }
    }

    /// Lire ce titre depuis cette source, à la position du titre.
    static func play(_ o: SourceOption, key k: TitleKey, title: String) {
        switch o.kind {
        case .file(let path):
            guard let item = LibraryStore.shared.items.first(where: { $0.files.contains { $0.path == path } }),
                  let f = item.files.first(where: { $0.path == path }) else { return }
            StrapontinApp_play(item, f)
        case .stream(let url):
            IPTVVOD.play(url: url, mediaKey: k.mediaKey, title: title,
                         subtitle: k.episode == nil ? nil : PlayItem(stream: url, title: title, key: k).subtitle,
                         progressKey: Watch.streamKey(k))
        }
    }
}

/// Lecture d'un fichier de la bibliothèque à la position du titre (fonction globale `play` des vues).
@MainActor
private func StrapontinApp_play(_ item: LibraryItem, _ f: MediaFile) { play(item, from: f, resume: true) }

/// Le bouton « Lire » d'une fiche ou d'un épisode : la meilleure source d'un clic (le libellé dit laquelle), les
/// autres dans le menu à côté. Reprise au même endroit quelle que soit la source.
struct PlaySourceButton: View {
    let key: TitleKey
    let title: String
    var titles: [String] = []
    var year: Int?
    /// Petit bouton (liste d'épisodes) plutôt que la grande pastille des fiches.
    var compact = false
    @ObservedObject private var store = IPTVStore.shared
    @State private var options: [SourceOption] = []

    var body: some View {
        let list = options.isEmpty ? Sources.now(key, titles: titles.isEmpty ? [title] : titles, year: year) : options
        if let best = list.first {
            let p = Watch.point(key)
            let verb = p?.inProgress == true ? "Reprendre" : (p?.watched == true ? "Revoir" : "Lire")
            HStack(spacing: compact ? 4 : 8) {
                if compact {
                    Button { Sources.play(best, key: key, title: title) } label: {
                        SmallPill(title: "\(verb) · \(best.short)", icon: p?.watched == true ? "arrow.counterclockwise" : "play.fill", filled: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    PlayPill(title: "\(verb) · \(best.short)") { Sources.play(best, key: key, title: title) }
                        .help(best.label)
                }
                if list.count > 1 {
                    Menu {
                        Section("Lire depuis") {
                            ForEach(list) { o in
                                Button { Sources.play(o, key: key, title: title) } label: { Label(o.label, systemImage: o.icon) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: compact ? 10 : 13, weight: .bold))
                    }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(CircleButtonStyle())
                    .fixedSize()
                    .help("Choisir la source (\(list.count))")
                }
            }
            .task(id: key.id) { options = await Sources.all(key, titles: titles.isEmpty ? [title] : titles, year: year) }
        }
    }
}
