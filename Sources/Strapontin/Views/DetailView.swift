import StrapontinCore
import SwiftUI

/// Fiche immersive façon Apple TV : fond plein cadre, logo, Lire, épisodes en vignettes, distribution.
struct DetailView: View {
    let itemId: String
    @EnvironmentObject var store: LibraryStore
    @State private var season: Int?
    @Environment(\.dismiss) private var dismiss

    init(itemId: String) { self.itemId = itemId }

    var body: some View {
        // resolve : après « Corriger la fiche » ou une identification, la page suit la nouvelle fiche
        if let item = store.resolve(itemId) {
            if let m = item.media, m.kind == .tv {
                SeriesFicheView(tmdbId: m.tmdbId).id(item.id)
            } else {
                content(item).id(item.id)
            }
        } else {
            // supprimé : on revient en arrière plutôt que de laisser une page morte
            Theme.background.ignoresSafeArea().onAppear { dismiss() }
        }
    }

    private func content(_ item: LibraryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                hero(item)
                // nouvelle saison, autre version… en cours de téléchargement pour cette fiche
                DownloadPanel(entryId: item.id, showFinished: false)
                if item.kind == .tv { episodes(item) } else { versions(item) }
                if let cast = item.media?.cast, !cast.isEmpty { CastRow(cast: cast) }
                about(item)
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
    }

    // MARK: - En-tête

    private func hero(_ item: LibraryItem) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let m = item.media, m.backdropPath != nil {
                    LocalImage(url: store.backdropURL(m)).frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    LinearGradient(colors: [Color(white: 0.2), Theme.background], startPoint: .top, endPoint: .bottom)
                }
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.background.opacity(0.9), location: 0.88),
                                       .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 14) {
                    TitleLogo(item: item, maxWidth: 480, maxHeight: 160, fontSize: 52)
                    MetaLine(item: item)
                    if let t = item.media?.tagline { Text(t).font(.system(size: 14, weight: .medium).italic()).foregroundStyle(.white.opacity(0.7)) }
                    if let o = item.media?.overview, !o.isEmpty {
                        Text(o).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(4).frame(maxWidth: 560, alignment: .leading)
                    }
                    if item.media == nil {
                        Text("Fiche introuvable automatiquement. Choisis-la avec « Corriger la fiche ».")
                            .font(.system(size: 13)).foregroundStyle(.orange)
                    }
                    HStack(spacing: 12) { LibraryItemButtons(item: item) }.padding(.top, 8)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 40)
            }
        }
        .frame(height: 620)
    }

    // MARK: - Épisodes

    private func episodes(_ item: LibraryItem) -> some View {
        let seasons = Array(Set(item.files.map { $0.season ?? 0 })).sorted()
        let current = season ?? item.resumeTarget?.season ?? item.nextUp?.season ?? seasons.first ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 22) {
                ForEach(seasons, id: \.self) { s in
                    Button { withAnimation { season = s } } label: {
                        Text(s == 0 ? "Autres" : "Saison \(s)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(s == current ? Color.white : Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(item.files.filter { ($0.season ?? 0) == current }) { f in
                        EpisodeCard(item: item, file: f)
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.vertical, 14)
            }
            .padding(.vertical, -14)
        }
    }

    private func versions(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.files.count > 1 ? "Versions" : "Fichier").font(.system(size: 21, weight: .bold))
            ForEach(item.files) { f in
                Button { play(item, from: f, resume: f.inProgress) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.fileName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text([f.quality, humanSize(f.size), f.duration > 0 ? formatTime(f.duration) : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 720)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - Distribution et infos

    private func about(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("À propos").font(.system(size: 21, weight: .bold))
            HStack(alignment: .top, spacing: 40) {
                if let o = item.media?.overview, !o.isEmpty {
                    Text(o).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: 520, alignment: .leading).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    info("Titre original", item.media?.originalTitle)
                    info("Genres", item.media?.genres.joined(separator: ", "))
                    info("Sortie", item.year.map(String.init))
                    info("Note TMDb", item.media?.rating.map { String(format: "%.1f / 10", $0) })
                    info("Note IMDb", item.media?.imdbRating)
                    info("Qualité", item.bestQuality)
                    info("Dossier", item.files.first.map { ($0.path as NSString).deletingLastPathComponent })
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).lineLimit(2).textSelection(.enabled)
            }
        }
    }
}

/// Boutons de l'en-tête d'une entrée de la bibliothèque (film ou série).
struct LibraryItemButtons: View {
    let item: LibraryItem
    @EnvironmentObject var store: LibraryStore
    @State private var showMatch = false
    @State private var deleteRequest: DeleteRequest?

    var body: some View {
        HStack(spacing: 12) {
            if let r = item.resumeTarget {
                PlayPill(title: "Reprendre \(tag(r))") { play(item, resume: true) }
                    .help("Reprendre à \(formatTime(r.position))")
                Button { play(item, resume: false) } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .bold)) }
                    .buttonStyle(CircleButtonStyle())
                    .help("Lire depuis le début")
            } else {
                PlayPill(title: item.kind == .tv ? "Lire \(item.nextUp.map(tag) ?? "")" : "Lire") { play(item, resume: false) }
            }
            if item.kind == .movie, let m = item.media {
                StreamButton(kind: .movie, tmdbId: m.tmdbId, title: m.title, libraryFile: item.files.first)
            }
            Button { store.setWatched(item.files.map(\.path), !item.allWatched) } label: {
                Image(systemName: item.allWatched ? "checkmark.circle.fill" : "checkmark.circle").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(CircleButtonStyle())
            .help(item.allWatched ? "Marquer comme non vu" : "Marquer comme vu")
            if let m = item.media { TrackerButtons(media: m) }
            Menu {
                Button("Corriger la fiche…") { showMatch = true }
                if let imdb = item.media?.imdbId, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
                    Link("Voir sur IMDb", destination: url)
                }
                if let f = item.files.first {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                }
                Divider()
                Button("Supprimer…", role: .destructive) { deleteRequest = .item(item) }
                if item.kind == .tv, item.files.contains(where: \.watched) {
                    Button("Supprimer les épisodes vus…", role: .destructive) { deleteRequest = .watched(item) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background {
            // une seule feuille et une seule confirmation pour toute la rangée de boutons
            Color.clear
                .sheet(isPresented: $showMatch) { MatchSheet(item: item) }
                .deleteConfirmation($deleteRequest)
        }
    }

    private func tag(_ f: MediaFile) -> String {
        guard let s = f.season, let e = f.episode else { return "" }
        return "S\(s), É\(e)"
    }
}

/// Rangée « Distribution ».
struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Distribution").font(.system(size: 21, weight: .bold)).padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(cast) { c in
                        // chaque acteur ouvre sa page (photo, biographie, filmographie)
                        NavigationLink(value: PersonLink.value(c.id)) {
                            VStack(spacing: 8) {
                                PersonPhoto(path: c.profilePath, name: c.name, size: 96)
                                Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                if let ch = c.character, !ch.isEmpty {
                                    Text(ch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 110)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Voir \(c.name)")
                    }
                }
                .padding(.horizontal, Theme.margin)
            }
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// Vignette d'épisode : photo 16:9, numéro, titre, résumé, progression.
struct EpisodeCard: View {
    let item: LibraryItem
    let file: MediaFile
    @EnvironmentObject var store: LibraryStore
    @State private var hover = false

    init(item: LibraryItem, file: MediaFile) {
        self.item = item
        self.file = file
    }

    var body: some View {
        Button { play(item, from: file, resume: file.inProgress) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Color(white: 0.15)
                    if let s = file.stillPath {
                        RemoteImage(url: TMDbClient.imageURL(s, size: "w780"))
                    } else if let m = item.media, m.backdropPath != nil {
                        LocalImage(url: store.backdropURL(m)).opacity(0.5)
                    }
                    if file.inProgress, file.duration > 0 {
                        GeometryReader { g in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.5))
                                    Capsule().fill(.white).frame(width: g.size.width * min(1, file.position / file.duration))
                                }
                                .frame(height: 3)
                            }
                        }
                        .padding(10)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 36, height: 36).background(.white, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
                    if file.watched {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Sheen(active: hover) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .shadow(color: .black.opacity(hover ? 0.7 : 0.3), radius: hover ? 20 : 6, y: hover ? 12 : 3)
                .scaleEffect(hover ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "ÉPISODE \(file.episode ?? 0)").font(.system(size: 10, weight: .heavy)).kerning(0.8).foregroundStyle(.secondary)
                    Text(file.episodeTitle ?? file.fileName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let o = file.episodeOverview, !o.isEmpty {
                        Text(o).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if file.duration > 0 {
                        Text(file.inProgress ? "Reste \(formatTime(file.duration - file.position))" : formatTime(file.duration))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 300)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .contextMenu {
            Button("Lire depuis le début") { play(item, from: file, resume: false) }
            Button(file.watched ? "Marquer comme non vu" : "Marquer comme vu") { store.setWatched([file.path], !file.watched) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
        }
    }
}

struct MatchSheet: View {
    let item: LibraryItem
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var year = ""
    @State private var kind: MediaKind = .movie
    @State private var results: [TMDbSearchResult] = []
    @State private var error: String?
    @State private var selection: Int?

    init(item: LibraryItem) { self.item = item }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Corriger la fiche").font(.title2.bold())
            HStack {
                TextField("Titre", text: $query).onSubmit(search)
                TextField("Année", text: $year).frame(width: 70).onSubmit(search)
                Picker("", selection: $kind) {
                    Text("Film").tag(MediaKind.movie)
                    Text("Série").tag(MediaKind.tv)
                }
                .pickerStyle(.segmented).frame(width: 140)
                Button("Chercher", action: search)
            }
            if let error { Text(error).foregroundStyle(.red) }
            List(results, selection: $selection) { r in
                HStack(spacing: 12) {
                    RemoteImage(url: TMDbClient.imageURL(r.posterPath, size: "w92"))
                        .frame(width: 40, height: 60).background(Color(white: 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(r.title) (\(r.year.map(String.init) ?? "?"))").font(.headline)
                        Text(r.overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
                .tag(r.id)
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Choisir") {
                    guard let id = selection else { return }
                    let k = kind
                    let preview = results.first { $0.id == id }
                    Task { await store.assign(item, kind: k, tmdbId: id, preview: preview) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
        .onAppear {
            query = item.title
            year = item.year.map(String.init) ?? ""
            kind = item.kind
            search()
        }
    }

    private func search() {
        error = nil
        let client = TMDbClient(key: settings.effectiveTMDbKey, language: settings.tmdbLanguage)
        let q = query, y = Int(year), k = kind
        Task {
            do { results = try await client.search(k, title: q, year: y) } catch { self.error = error.localizedDescription }
        }
    }
}
