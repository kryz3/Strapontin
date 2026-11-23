import AppKit
import StrapontinCore
import SwiftUI

// Téléchargements dans la bibliothèque : affiches avec la progression, rangée « En téléchargement »,
// panneau de suivi sur les fiches, page d'un téléchargement non identifié.

extension DownloadPhase {
    var tint: Color {
        switch self {
        case .error: return .red
        case .paused: return Color(white: 0.6)
        case .waiting, .queued: return .orange
        case .done: return .green
        default: return Theme.accent
        }
    }

    var icon: String {
        switch self {
        case .downloading: return "arrow.down"
        case .waiting: return "antenna.radiowaves.left.and.right"
        case .metadata, .checking: return "hourglass"
        case .queued: return "clock"
        case .paused: return "pause.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark"
        }
    }

    /// Pastille sur l'affiche (rien quand ça télécharge normalement : l'anneau suffit).
    var badgeText: String? {
        switch self {
        case .paused: return "EN PAUSE"
        case .waiting: return "EN ATTENTE"
        case .queued: return "EN FILE"
        case .error: return "ERREUR"
        case .checking: return "VÉRIFICATION"
        case .metadata: return "PRÉPARATION"
        case .done: return "TERMINÉ"
        case .downloading: return nil
        }
    }
}

/// Anneau de progression façon Apple (téléchargement d'une app), avec l'icône d'état au centre.
struct ProgressRing: View {
    let progress: Double
    let phase: DownloadPhase
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Circle().stroke(.white.opacity(0.22), lineWidth: 3).padding(3)
            Circle().trim(from: 0, to: max(0.02, progress)).stroke(phase.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(3)
            Image(systemName: phase.icon).font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(phase.tint)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

/// Barre fine en bas de l'affiche, comme la progression de lecture.
struct DownloadStrip: View {
    let progress: Double
    let phase: DownloadPhase
    var body: some View {
        GeometryReader { g in
            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.5))
                    Capsule().fill(phase == .downloading ? Color.white : phase.tint).frame(width: g.size.width * min(1, progress))
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

/// Affiche d'un téléchargement : celle de la fiche, ou une affiche générique (nom du torrent) s'il n'est pas identifié.
struct DownloadPosterCard: View {
    let entry: DownloadEntry
    var fixedWidth: CGFloat? = 168
    @EnvironmentObject var store: LibraryStore
    @State private var hover = false
    @State private var cancelRequest = false
    @State private var attach = false

    var body: some View {
        NavigationLink(value: entry.destination(store)) {
            VStack(alignment: .leading, spacing: 9) {
                poster
                    .saturation(entry.phase == .paused || entry.phase == .error ? 0.35 : 1)
                    .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .overlay { Sheen(active: hover) }
                    .overlay(alignment: .bottom) { if !entry.isDone { DownloadStrip(progress: entry.progress, phase: entry.phase) } }
                    .overlay(alignment: .topTrailing) { ProgressRing(progress: entry.progress, phase: entry.phase).padding(8) }
                    .overlay(alignment: .topLeading) {
                        // empilées : à côté de l'anneau, deux pastilles ne tiennent pas sur la largeur d'une affiche
                        VStack(alignment: .leading, spacing: 4) {
                            if let b = entry.phase.badgeText { Badge(text: b, color: entry.phase == .error ? .red.opacity(0.9) : .black.opacity(0.65)) }
                            if !entry.isIdentified { Badge(text: "NON IDENTIFIÉ", color: .red.opacity(0.85)) }
                        }
                        .fixedSize()
                        .padding(8)
                    }
                    .shadow(color: .black.opacity(hover ? 0.7 : 0.35), radius: hover ? 22 : 8, y: hover ? 14 : 4)
                    .scaleEffect(hover ? 1.06 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([entry.seasonLabel, entry.statusLine].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(entry.phase == .error ? Color.red : .secondary).lineLimit(1)
                }
                .opacity(hover ? 1 : 0.85)
            }
            .frame(width: fixedWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .help(entry.torrents.map(\.name).joined(separator: "\n"))
        .contextMenu { DownloadMenu(entry: entry, cancelRequest: $cancelRequest, attach: $attach) }
        .cancelDownloadDialog(entry: entry, isPresented: $cancelRequest)
        .sheet(isPresented: $attach) { AttachSheet(entry: entry, isPresented: $attach) }
    }

    @ViewBuilder private var poster: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            if let m = entry.media, m.posterPath != nil {
                if store.media[m.key] != nil {
                    LocalImage(url: store.posterURL(m))
                } else {
                    RemoteImage(url: TMDbClient.imageURL(m.posterPath, size: "w342"))
                }
            } else {
                GenericPoster(title: entry.title, kind: entry.kind, subtitle: entry.year.map(String.init))
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
    }
}

/// Affiche sans image : icône, titre et année, pour un téléchargement qu'on n'a pas su rattacher.
struct GenericPoster: View {
    let title: String
    let kind: MediaKind
    var subtitle: String?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: kind == .tv ? "tv" : "film").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center).lineLimit(4)
                .foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 14)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
        }
    }
}

/// Menu contextuel commun (affiche, fiche).
struct DownloadMenu: View {
    let entry: DownloadEntry
    @Binding var cancelRequest: Bool
    @Binding var attach: Bool
    @ObservedObject private var downloads = DownloadsModel.shared

    var body: some View {
        let active = entry.current.filter { !$0.isDone }.map(\.hash)
        if !active.isEmpty {
            if entry.phase == .paused { Button("Reprendre") { downloads.resume(active) } }
            else { Button("Mettre en pause") { downloads.pause(active) } }
        }
        if entry.phase == .error { Button("Réessayer") { downloads.resume(active.isEmpty ? entry.hashes : active) } }
        Button(entry.isIdentified ? "Changer de fiche…" : "Rattacher à une fiche…") { attach = true }
        if let t = entry.torrents.first, !t.contentPath.isEmpty {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.contentPath)]) }
        }
        Divider()
        Button(entry.isDone ? "Retirer des téléchargements…" : "Annuler le téléchargement…", role: .destructive) { cancelRequest = true }
    }
}

extension View {
    /// Confirmation avant d'annuler : garder ou effacer ce qui est déjà téléchargé.
    func cancelDownloadDialog(entry: DownloadEntry, isPresented: Binding<Bool>, hashes: [String]? = nil) -> some View {
        let ids = hashes ?? entry.hashes
        return confirmationDialog(entry.isDone ? "Retirer « \(entry.title) » des téléchargements ?" : "Annuler le téléchargement de « \(entry.title) » ?",
                                  isPresented: isPresented, titleVisibility: .visible) {
            if entry.isDone {
                Button("Retirer (garder le film dans la bibliothèque)") { DownloadsModel.shared.cancel(ids, deleteFiles: false) }
            } else {
                Button("Annuler et effacer ce qui est téléchargé", role: .destructive) { DownloadsModel.shared.cancel(ids, deleteFiles: true) }
                Button("Arrêter mais garder les fichiers") { DownloadsModel.shared.cancel(ids, deleteFiles: false) }
            }
            Button("Ne rien faire", role: .cancel) {}
        } message: {
            Text(entry.isDone ? "Le partage s'arrête ; les fichiers restent sur le disque."
                              : "Les fichiers effacés ne vont pas à la corbeille.")
        }
    }
}

/// Progression posée sur une affiche de la bibliothèque ou de la recherche (série qui télécharge une nouvelle saison,
/// film déjà présent qu'on retélécharge…). Isolé dans sa vue : seules ces vignettes suivent le moteur toutes les 2 s.
struct DownloadOverlay: View {
    let mediaKey: String
    @ObservedObject private var downloads = DownloadsModel.shared

    var body: some View {
        if let e = downloads.entry(for: mediaKey), !e.isDone {
            ZStack {
                DownloadStrip(progress: e.progress, phase: e.phase)
                VStack {
                    HStack {
                        Spacer()
                        ProgressRing(progress: e.progress, phase: e.phase, size: 30).padding(8)
                    }
                    Spacer()
                }
            }
            .allowsHitTesting(false)
            .help("\(e.seasonLabel.isEmpty ? "" : e.seasonLabel + " · ")\(e.statusLine)")
        }
    }
}

/// Rangée « En téléchargement », en tête de l'accueil, des films et des séries.
struct DownloadingShelf: View {
    var kind: MediaKind?
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var downloads = DownloadsModel.shared

    var body: some View {
        let list = downloads.visibleEntries(kind: kind, store: store)
        if !list.isEmpty {
            Shelf(title: "En téléchargement") { ForEach(list) { DownloadPosterCard(entry: $0) } }
        }
    }
}

/// Bloc « Téléchargement » d'une fiche : chaque torrent avec sa progression, pause / reprise / annuler.
struct DownloadPanel: View {
    let entryId: String
    /// Fiche de la bibliothèque : un torrent fini qui partage encore n'a rien à dire, on ne montre que l'actif.
    var showFinished = true
    /// Fiche d'un épisode : seulement ses torrents.
    var only: Set<String>? = nil
    @ObservedObject private var downloads = DownloadsModel.shared
    @State private var cancel: Torrent?

    var body: some View {
        if let e = downloads.entry(id: entryId), showFinished || !e.isDone {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(e.isDone ? "Téléchargé" : "Téléchargement").font(.system(size: 21, weight: .bold))
                    if !e.isDone, only == nil { Text(e.statusLine).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer()
                }
                VStack(spacing: 2) {
                    ForEach(e.torrents.filter { t in (showFinished || !t.isDone) && (only?.contains(t.hash) ?? true) }) { t in row(t, e) }
                }
                if let err = downloads.error { Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    private func row(_ t: Torrent, _ e: DownloadEntry) -> some View {
        HStack(spacing: 14) {
            ProgressRing(progress: t.progress, phase: t.phase, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if e.kind == .tv, let x = EpisodeTransfer(torrent: t, link: downloads.book[t.hash]) { SpecBadge(text: badge(x)) }
                    Text(t.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: t.progress).tint(t.phase.tint).controlSize(.small)
                Text(line(t)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(t.phase == .error ? Color.red : .secondary)
            }
            Spacer(minLength: 16)
            if !t.isDone {
                Button { t.phase == .paused ? downloads.resume([t.hash]) : downloads.pause([t.hash]) } label: {
                    Image(systemName: t.phase == .paused ? "play.fill" : "pause.fill").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle()).help(t.phase == .paused ? "Reprendre" : "Mettre en pause")
            }
            Button { cancel = t } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                .buttonStyle(CircleButtonStyle()).help(t.isDone ? "Retirer des téléchargements" : "Annuler le téléchargement")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
        .cancelDownloadDialog(entry: singleEntry(e, t), isPresented: Binding(get: { cancel?.hash == t.hash }, set: { if !$0 { cancel = nil } }),
                              hashes: [t.hash])
    }

    private func badge(_ x: EpisodeTransfer) -> String {
        guard let r = x.episodes else { return "SAISON \(x.season)" }
        let first = String(format: "S%02dE%02d", x.season, r.lowerBound)
        return r.count > 1 ? first + String(format: "–E%02d", r.upperBound) : first
    }

    private func singleEntry(_ e: DownloadEntry, _ t: Torrent) -> DownloadEntry {
        var x = e
        x.torrents = [t]
        x.current = [t]
        x.phase = t.phase
        return x
    }

    private func line(_ t: Torrent) -> String {
        let pct = "\(Int((t.progress * 100).rounded(.down))) %"
        var parts = [t.phase == .done ? "Terminé" : t.phase.label, pct, humanSize(t.size)]
        if t.phase == .downloading, t.dlspeed > 0 { parts += ["\(humanSize(t.dlspeed))/s", etaText(t.eta)] }
        if t.phase == .done { parts.remove(at: 1) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Page d'un téléchargement qu'on n'a pas su rattacher à une fiche (ou ouvert depuis son affiche générique).
struct DownloadDetailView: View {
    let entryId: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var downloads = DownloadsModel.shared
    @State private var attach = false
    @State private var cancelRequest = false

    var body: some View {
        if let e = downloads.entry(id: entryId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(alignment: .bottom, spacing: 32) {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                            GenericPoster(title: e.title, kind: e.kind, subtitle: e.year.map(String.init))
                        }
                        .aspectRatio(2 / 3, contentMode: .fit).frame(width: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .overlay(alignment: .topTrailing) { ProgressRing(progress: e.progress, phase: e.phase).padding(8) }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(e.title).font(.system(size: 40, weight: .heavy)).lineLimit(2)
                            Text("Strapontin n'a pas trouvé la fiche de ce téléchargement. Rattache-le pour avoir l'affiche, le résumé, puis « Lire » dans la bibliothèque.")
                                .font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading)
                            HStack(spacing: 12) {
                                PlayPill(title: "Rattacher à une fiche", icon: "link") { attach = true }
                                if let t = e.torrents.first, !t.contentPath.isEmpty {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.contentPath)]) } label: {
                                        Image(systemName: "folder").font(.system(size: 15, weight: .bold))
                                    }
                                    .buttonStyle(CircleButtonStyle()).help("Afficher dans le Finder")
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, 90)
                    DownloadPanel(entryId: entryId)
                }
                .padding(.bottom, 60)
            }
            .background(Theme.background)
            .sheet(isPresented: $attach) { AttachSheet(entry: e, isPresented: $attach) }
        } else if let key = downloads.book[String(entryId.dropFirst(3))]?.mediaKey, let (k, n) = TMDbLink.parseKey(key) {
            // rattaché à une fiche : la page devient cette fiche (pas de page morte dans la pile)
            FicheView(kind: k, tmdbId: n).transition(.opacity)
        } else {
            // annulé : on revient en arrière
            Theme.background.ignoresSafeArea().onAppear { dismiss() }
        }
    }
}

/// Choisir la fiche TMDb d'un téléchargement (recherche par titre, pré-remplie avec ce que le nom laisse deviner).
struct AttachSheet: View {
    let entry: DownloadEntry
    @Binding var isPresented: Bool
    @EnvironmentObject var settings: AppSettings
    @State private var query = ""
    @State private var kind: MediaKind = .movie
    @State private var results: [TMDbSearchResult] = []
    @State private var searching = false
    @State private var season = ""
    @State private var episode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rattacher à une fiche").font(.system(size: 19, weight: .bold))
            Text(entry.torrents.first?.name ?? entry.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("Titre", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Picker("", selection: $kind) { Text("Film").tag(MediaKind.movie); Text("Série").tag(MediaKind.tv) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Chercher", action: search).keyboardShortcut(.defaultAction)
            }
            if kind == .tv {
                HStack {
                    Text("Saison")
                    TextField("", text: $season).textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("Épisode")
                    TextField("toute", text: $episode).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("Épisode vide : la saison entière.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 16) {
                    ForEach(results) { r in
                        Button {
                            for h in entry.hashes { attach(h, to: r) }
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack {
                                    Color(white: 0.15)
                                    RemoteImage(url: TMDbClient.imageURL(r.posterPath, size: "w185"))
                                }
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(r.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(r.year.map(String.init) ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if searching { ProgressView().padding() }
            }
            HStack { Spacer(); Button("Annuler") { isPresented = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .background(Theme.background)
        .onAppear {
            let g = TorrentGuess.parse(entry.torrents.first?.name ?? "")
            query = entry.media?.title ?? g?.title ?? entry.title
            kind = entry.kind
            let link = DownloadsModel.shared.book[entry.torrents.first?.hash ?? ""]
            season = (link?.season ?? g?.season).map(String.init) ?? ""
            episode = (link?.episode ?? g?.episode).map(String.init) ?? ""
            search()
        }
    }

    /// Saison et épisode saisis : pour un seul torrent ; une carte qui en regroupe plusieurs garde les leurs.
    private func attach(_ hash: String, to r: TMDbSearchResult) {
        let one = r.kind == .tv && entry.hashes.count == 1
        DownloadsModel.shared.assign(hash: hash, kind: r.kind, tmdbId: r.id,
                                     season: one ? Int(season) : nil, episode: one ? Int(episode) : nil)
    }

    private func search() {
        guard !settings.effectiveTMDbKey.isEmpty, query.count >= 2 else { return }
        let c = TMDbClient(key: settings.effectiveTMDbKey, language: settings.tmdbLanguage, omdbKey: settings.omdbKey)
        let q = query, k = kind
        searching = true
        Task {
            results = (try? await c.search(k, title: q, year: nil)) ?? []
            searching = false
        }
    }
}
