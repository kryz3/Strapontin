import StrapontinCore
import SwiftUI

/// Films et séries des playlists IPTV, vus depuis les fiches TMDb : quand on ouvre une fiche, on cherche le titre dans
/// l'index local (identifiant TMDb donné par Xtream, sinon titre normalisé, titre original et année) et on propose
/// « Regarder en streaming ». Aucun rapprochement en masse, aucune requête par titre.
@MainActor
enum IPTVVOD {
    static func kind(_ k: MediaKind) -> IPTVKind { k == .tv ? .series : .movie }

    /// Versions IPTV d'un titre TMDb, la meilleure qualité d'abord.
    static func find(_ kind: MediaKind, tmdbId: Int, titles: [String], year: Int?) -> [VODRef] {
        IPTVStore.shared.vodLookup.find(kind: Self.kind(kind), tmdbId: tmdbId, titles: titles.filter { !$0.isEmpty }, year: year)
            .filter { $0.episode == nil || $0.episode == 1 }
            .sorted { ChannelName.parse($0.name).quality > ChannelName.parse($1.name).quality }
    }

    /// Ce qui distingue deux versions d'un même titre : qualité et langue (« 4K · MULTI »).
    static func sourceLabel(_ name: String) -> String {
        let up = " " + String(name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }) + " "
        var parts: [String] = []
        let q = ChannelName.parse(name).quality
        if q != .unknown { parts.append(q.label) }
        for tag in ["MULTI", "VOSTFR", "VFF", "VFQ", "VF", "VO", "TRUEFRENCH", "FRENCH"] where up.contains(" \(tag) ") {
            parts.append(tag == "TRUEFRENCH" || tag == "FRENCH" ? "VF" : tag); break
        }
        let (country, _) = IPTVCountry.stripPrefix(name)
        if parts.count < 2, let c = country { parts.append(IPTVCountry.flag(c)) }
        return parts.isEmpty ? "Standard" : parts.joined(separator: " · ")
    }

    /// Lecture en streaming ; la reprise est commune avec la bibliothèque (le plus récent l'emporte).
    static func play(url: String, mediaKey: String?, title: String, subtitle: String? = nil, progressKey: String,
                     libraryFile: MediaFile? = nil) {
        let store = IPTVStore.shared
        var start = 0.0
        if let p = store.progress[progressKey], p[0] > 30, p[0] < p[1] * 0.95 { start = p[0] }
        if let f = libraryFile, f.inProgress, let t = f.lastPlayed,
           t > (store.progress[progressKey].flatMap { $0.count > 2 ? $0[2] : nil } ?? 0) {
            start = f.position
        }
        store.noteStream(StreamRecord(key: progressKey, mediaKey: mediaKey, title: title, subtitle: subtitle, date: Date()))
        PlayerController.play([PlayItem(path: url, title: title, subtitle: subtitle, start: start, progressKey: progressKey)])
    }
}

/// Une lecture en streaming, pour l'historique et la reprise.
struct StreamRecord: Codable, Hashable, Identifiable {
    var key: String
    var mediaKey: String?
    var title: String
    var subtitle: String?
    var date: Date
    var id: String { key }
}

/// « Regarder en streaming » sur une fiche de film : la meilleure version d'un clic, les autres dans un menu.
struct StreamButton: View {
    let kind: MediaKind
    let tmdbId: Int
    let titles: [String]
    let year: Int?
    var libraryFile: MediaFile? = nil
    /// Petit bouton (cartes « Pour toi ») plutôt que la grande pastille des fiches.
    var compact = false
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        let list = kind == .movie ? IPTVVOD.find(kind, tmdbId: tmdbId, titles: titles, year: year) : []
        if let best = list.first, let url = store.url(of: best) {
            let key = Media.key(kind, tmdbId)
            let title = titles.first ?? best.name
            let p = store.progress["stream:" + key]
            let resume = p.map { $0[0] > 30 && $0[0] < $0[1] * 0.95 } ?? false
            let label = resume ? "Reprendre en streaming" : "Regarder en streaming"
            let go = { (u: String) in IPTVVOD.play(url: u, mediaKey: key, title: title, progressKey: "stream:" + key, libraryFile: libraryFile) }
            HStack(spacing: 8) {
                if compact {
                    Button { go(url) } label: { SmallPill(title: label, icon: "play.tv", filled: true) }
                        .buttonStyle(.plain).help(IPTVVOD.sourceLabel(best.name))
                } else {
                    PlayPill(title: label, icon: "play.tv") { go(url) }.help(IPTVVOD.sourceLabel(best.name))
                }
                if list.count > 1, !compact {
                    Menu {
                        ForEach(list) { v in
                            if let u = store.url(of: v) { Button("\(IPTVVOD.sourceLabel(v.name)) — \(v.name)") { go(u) } }
                        }
                    } label: { Image(systemName: "dial.medium").font(.system(size: 15, weight: .bold)) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(CircleButtonStyle())
                    .fixedSize()
                    .help("Choisir la version (\(list.count))")
                }
            }
        }
    }
}

/// Petit badge sur une affiche : le titre se regarde en streaming (recherche locale, sans réseau).
struct StreamBadge: View {
    let kind: MediaKind
    let tmdbId: Int
    let title: String
    let year: Int?
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        if store.vodLookup.count > 0, !IPTVVOD.find(kind, tmdbId: tmdbId, titles: [title], year: year).isEmpty {
            Image(systemName: "play.tv.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(5).background(.black.opacity(0.55), in: Circle())
                .padding(8)
                .help("À regarder en streaming (IPTV)")
        }
    }
}

/// Recherche : les titres IPTV trouvés par leur nom (ceux que TMDb ne connaît pas s'y retrouvent).
struct IPTVTitleSearchSection: View {
    let query: String
    @ObservedObject private var store = IPTVStore.shared
    @State private var found: [VODRef] = []

    var body: some View {
        Group {
            if !found.isEmpty {
                Shelf(title: "Autres titres IPTV") { ForEach(found) { VODCard(ref: $0) } }
            }
        }
        .task(id: "\(query)|\(store.vodLookup.count)") {
            let lookup = store.vodLookup, q = query
            let r = await Task.detached(priority: .userInitiated) { lookup.search(q, limit: 30) }.value
            if !Task.isCancelled { found = r }
        }
    }
}

/// Épisodes en streaming d'une série TMDb : la série IPTV trouvée à l'ouverture de la fiche, puis ses épisodes.
@MainActor
final class SeriesStreams: ObservableObject {
    private static var cache: [Int: SeriesStreams] = [:]
    static func of(_ tmdbId: Int) -> SeriesStreams {
        if let s = cache[tmdbId] { return s }
        let s = SeriesStreams(); cache[tmdbId] = s; return s
    }
    @Published private(set) var ref: VODRef?
    /// Toutes les versions de la série chez le fournisseur (FR, VOSTFR, 4K…), la meilleure d'abord.
    @Published private(set) var refs: [VODRef] = []

    func load(tmdbId: Int, titles: [String], year: Int?) async {
        guard ref == nil else { return }
        let all = IPTVVOD.find(.tv, tmdbId: tmdbId, titles: titles, year: year)
        guard let r = all.first else { return }
        refs = all
        ref = r
        await IPTVStore.shared.loadEpisodes(r)
        objectWillChange.send()
    }

    /// Un épisode dans une version précise (ses épisodes sont demandés au besoin).
    func episode(season: Int, episode: Int, in r: VODRef) async -> VODEpisode? {
        await IPTVStore.shared.loadEpisodes(r)
        return IPTVStore.shared.episodes[r.id]?.first { $0.season == season && $0.episode == episode }
    }

    func episode(season: Int, episode: Int) -> VODEpisode? {
        guard let r = ref else { return nil }
        return IPTVStore.shared.episodes[r.id]?.first { $0.season == season && $0.episode == episode }
    }
}
