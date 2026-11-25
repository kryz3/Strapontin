import StrapontinCore
import SwiftUI
import UniformTypeIdentifiers

/// Les téléchargements du moteur, rattachés à leurs fiches : affichés sur les affiches de la bibliothèque
/// (plus d'onglet à part). Le lien torrent ↔ fiche est gardé dans downloads.json, il survit au redémarrage.
@MainActor
final class DownloadsModel: ObservableObject {
    static let shared = DownloadsModel()
    @Published private(set) var torrents: [Torrent] = []
    @Published private(set) var entries: [DownloadEntry] = []
    @Published private(set) var book = DownloadLinkBook()
    @Published var error: String?

    // ajout à la main : glisser-déposer, menu Fichier
    @Published var pendingLinks: [String] = []
    @Published var pendingFiles: [URL] = []
    @Published var showMagnetSheet = false
    @Published var showTorrentImporter = false

    private var lastProgress: [String: Double] = [:]
    // Interface optimiste : chaque action se voit tout de suite, avant la réponse du moteur, puis se réconcilie
    // (ou revient en arrière avec un message si le moteur refuse).
    /// Téléchargements lancés que le moteur ne liste pas encore : affiche « Préparation » en attendant.
    private var starting: [String: Torrent] = [:]
    /// État affiché en attendant la confirmation (pause / reprise).
    private var stateOverride: [String: String] = [:]
    /// Retirés de l'affichage tout de suite (annulation).
    private var hidden: Set<String> = []
    /// Quand chaque torrent a été vu se terminer, pour « Ajout à la bibliothèque… » (le temps du scan seulement).
    private var finishedAt: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    private var configKey = ""
    private var identifying = false
    private var fillingMedia = false
    private var listedOnce = false
    private let bookURL: URL

    var settings: AppSettings { AppSettings.shared }
    var engine: TorrentEngine { TorrentEngine.shared }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strapontin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        bookURL = dir.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: bookURL), let b = try? JSONDecoder().decode(DownloadLinkBook.self, from: data) {
            book = b
        }
    }

    func start() {
        guard loop == nil else { return }
        // torrents envoyés par une version d'avant (historique de l'indexeur) : rattachés à leur fiche
        var b = book
        b.seed(from: TrackerModel.shared.history)
        if b != book { book = b; saveBook() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: lecture pour l'interface

    /// Carte d'une fiche (nil si rien chez le moteur pour elle).
    func entry(for mediaKey: String) -> DownloadEntry? { entries.first { $0.mediaKey == mediaKey } }
    func entry(id: String) -> DownloadEntry? { entries.first { $0.id == id } }

    /// Torrents d'une fiche, éventuellement d'une saison (les autres saisons restent sur la carte, pas ici).
    func torrents(for mediaKey: String, season: Int? = nil) -> [Torrent] {
        guard let e = entry(for: mediaKey) else { return [] }
        guard let season else { return e.torrents }
        return e.torrents.filter { t in
            let s = book[t.hash]?.season ?? TorrentGuess.parse(t.name)?.season
            return s == nil || s == season
        }
    }

    /// Tout ce que le moteur a pour cette série, partage compris (suivi automatique : pas de doublon).
    func allTransfers(for mediaKey: String) -> [EpisodeTransfer] {
        torrents.filter { book[$0.hash]?.mediaKey == mediaKey }.compactMap { EpisodeTransfer(torrent: $0, link: book[$0.hash]) }
    }

    /// Ce qui est en route vers la bibliothèque, pour l'état des épisodes. Un torrent fini ne compte que tant que
    /// le scan ne l'a pas rangé : un épisode supprimé, ou absent d'un pack, redevient téléchargeable.
    func transfers(for mediaKey: String, files: [MediaFile]) -> [EpisodeTransfer] {
        allTransfers(for: mediaKey).filter { x in
            guard x.torrent.isDone else { return true }
            // sans limite de temps, un torrent sans vidéo (archive) ou rangé hors bibliothèque bloquerait l'épisode pour de bon
            guard let t = finishedAt[x.torrent.hash], Date().timeIntervalSince(t) < 120 else { return false }
            let p = x.torrent.contentPath
            return p.isEmpty || !files.contains { $0.path == p || $0.path.hasPrefix(p + "/") }
        }
    }

    /// Le téléchargement rattaché d'où vient ce fichier : le scan lui donne cette fiche, sans deviner d'après le nom.
    func origin(of path: String) -> (media: Media, path: String, link: DownloadLink)? {
        for t in torrents where !t.contentPath.isEmpty && (path == t.contentPath || path.hasPrefix(t.contentPath + "/")) {
            if let l = book[t.hash], let m = l.media { return (m, t.contentPath, l) }
        }
        return nil
    }

    /// Ce qui doit apparaître dans la bibliothèque : en cours, ou fini mais pas encore arrivé dans la bibliothèque.
    func visibleEntries(kind: MediaKind? = nil, store: LibraryStore) -> [DownloadEntry] {
        entries.filter { e in
            (kind == nil || e.kind == kind) && (!e.isDone || e.mediaKey.map { store.item(id: $0) == nil } ?? true)
        }
    }

    // MARK: moteur

    /// Le client du moteur (gardé par TorrentEngine, recréé quand on change de moteur ou de réglages qBittorrent).
    private func currentClient() async throws -> (any TorrentClient)? {
        guard engine.available else { return nil }
        let key = "\(engine.backend.rawValue)|\(settings.qbitURL)|\(settings.qbitUser)|\(settings.qbitPassword)"
        if key != configKey {
            engine.reset()
            configKey = key
            lastProgress = [:]
        }
        return try await engine.client()
    }

    /// Juste après un envoi : sans attendre le prochain passage, la fiche affiche la progression tout de suite.
    func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        do {
            guard let c = try await currentClient() else { torrents = []; rebuild(); return }
            let list = try await c.torrents()
            error = nil
            for t in list {
                // un téléchargement vient de se terminer : on rescanne la bibliothèque
                if let prev = lastProgress[t.hash], prev < 1, t.isDone {
                    finishedAt[t.hash] = Date()
                    LibraryStore.shared.rescan()
                    let link = book[t.hash]
                    let ep = link.flatMap { l in l.season.map { s in String(format: "S%02d", s) + (l.episode.map { String(format: "E%02d", $0) } ?? "") } }
                    Notifier.shared.downloadFinished(title: link?.media?.title ?? t.name, detail: ep, mediaKey: link?.mediaKey)
                }
                lastProgress[t.hash] = t.isDone ? 1 : t.progress
            }
            torrents = list
            if !listedOnce {
                listedOnce = true
                var b = book
                b.prune(present: Set(list.map { $0.hash.lowercased() }))
                if b != book { book = b; saveBook() }
            }
            rebuild()
            claimFinished()
            identifyNew()
            fillMissingMedia()
        } catch {
            // moteur intégré arrêté entre-temps : le prochain passage le relance
            if case TransmissionError.unreachable = error { engine.reset() }
            self.error = error.localizedDescription
        }
    }

    /// Ce que l'interface montre : la liste du moteur corrigée par les actions en cours.
    private var shownTorrents: [Torrent] {
        var list = torrents.filter { !hidden.contains($0.hash.lowercased()) }.map { t -> Torrent in
            guard let st = stateOverride[t.hash.lowercased()], !t.isDone else { return t }
            var t = t; t.state = st; if st != "pausedDL" { t.dlspeed = max(t.dlspeed, 0) } else { t.dlspeed = 0 }
            return t
        }
        let present = Set(torrents.map { $0.hash.lowercased() })
        list += starting.values.filter { !present.contains($0.hash) && !hidden.contains($0.hash) }
        return list
    }

    /// Lancement : l'affiche apparaît tout de suite dans « En téléchargement », en « Préparation ».
    func showStarting(hash: String, name: String, savePath: String?) {
        let h = hash.lowercased()
        guard !torrents.contains(where: { $0.hash.lowercased() == h }) else { return }
        starting[h] = Torrent(hash: h, name: name, progress: 0, state: "metaDL", dlspeed: 0, eta: 0, size: 0,
                              savePath: savePath ?? "", contentPath: "", addedOn: Date().timeIntervalSince1970)
        rebuild()
    }

    /// Lancement refusé par le moteur : l'affiche provisoire disparaît.
    func dropStarting(hash: String) {
        if starting.removeValue(forKey: hash.lowercased()) != nil { rebuild() }
    }

    private func rebuild() {
        // ce que le moteur confirme n'a plus besoin d'être simulé
        let present = Set(torrents.map { $0.hash.lowercased() })
        starting = starting.filter { !present.contains($0.key) && Date().timeIntervalSince1970 - $0.value.addedOn < 120 }
        hidden = hidden.filter { present.contains($0) }
        let e = DownloadBoard.build(torrents: shownTorrents, book: book)
        if e != entries { entries = e }
    }

    private func saveBook() {
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: bookURL, options: .atomic) }
    }

    /// Fini : les fichiers arrivés dans la bibliothèque prennent la fiche du téléchargement
    /// (le scan identifie par le nom de fichier, qui peut se tromper ou ne rien trouver).
    private func claimFinished() {
        for e in entries {
            guard let m = e.media else { continue }
            for t in e.torrents where t.isDone && !t.contentPath.isEmpty {
                let link = book[t.hash]
                LibraryStore.shared.claim(pathPrefix: t.contentPath, media: m, season: link?.season, episode: link?.episode)
            }
        }
    }

    // MARK: rattachement aux fiches

    private func tmdb() -> TMDbClient? {
        settings.effectiveTMDbKey.isEmpty ? nil : TMDbClient(key: settings.effectiveTMDbKey, language: settings.tmdbLanguage, omdbKey: settings.omdbKey)
    }

    /// Torrents ajoutés à la main (ou ailleurs) : on cherche leur fiche d'après leur nom, une fois par nom.
    private func identifyNew() {
        guard !identifying, let client = tmdb() else { return }
        let todo = torrents.filter { book.needsIdentification($0) }
        guard !todo.isEmpty else { return }
        identifying = true
        Task {
            for t in todo {
                guard let g = TorrentGuess.parse(t.name) else { continue }
                var media: Media?
                do {
                    var hit = try await client.bestMatch(g.kind, title: g.title, year: g.year)
                    if hit == nil, g.kind == .movie, g.year == nil { hit = try await client.bestMatch(.tv, title: g.title, year: nil) }
                    if let hit { media = try await client.details(hit.kind, id: hit.id) }
                } catch {
                    continue   // réseau : on réessaiera au prochain passage
                }
                book.identified(hash: t.hash, name: t.name, media: media, season: g.season, episode: g.episode)
            }
            saveBook()
            rebuild()
            identifying = false
        }
    }

    /// Liens connus par la clé seule (historique de l'indexeur) : la fiche vient de la bibliothèque, d'un suivi, sinon de TMDb.
    private func fillMissingMedia() {
        let keys = book.keysWithoutMedia
        guard !keys.isEmpty, !fillingMedia else { return }
        fillingMedia = true
        Task {
            for key in keys {
                if let m = LibraryStore.shared.media[key] { book.fill(m); continue }
                if let f = TrackerModel.shared.follows.first(where: { $0.id == key }) { book.fill(f.asMedia); continue }
                let p = key.split(separator: ":")
                guard p.count == 2, let k = MediaKind(rawValue: String(p[0])), let id = Int(p[1]),
                      let m = try? await tmdb()?.details(k, id: id) else { continue }
                book.fill(m)
            }
            saveBook()
            rebuild()
            fillingMedia = false
        }
    }

    /// Envoi depuis une fiche ou un suivi : la carte porte tout de suite la bonne affiche.
    func link(hash: String, media: Media?, mediaKey: String?, season: Int?, episode: Int?,
              episodeEnd: Int? = nil, source: DownloadSource) {
        book.record(hash: hash, media: media, mediaKey: mediaKey, season: season, episode: episode, episodeEnd: episodeEnd, source: source)
        saveBook()
        rebuild()
    }

    /// « Rattacher à une fiche… » sur une affiche générique.
    func assign(hash: String, kind: MediaKind, tmdbId: Int, season: Int? = nil, episode: Int? = nil) {
        Task {
            guard let c = tmdb() else { return }
            do {
                let m = try await c.details(kind, id: tmdbId)
                book.assign(hash: hash, media: m, season: season, episode: episode)
                saveBook()
                rebuild()
                claimFinished()
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: actions

    /// Action envoyée au moteur. `rollback` défait ce que l'interface a montré d'avance si le moteur refuse.
    func run(_ op: @escaping (any TorrentClient) async throws -> Void, rollback: (() -> Void)? = nil, label: String = "action") {
        let t0 = ContinuousClock.now
        Task {
            defer { Perf.log("\(label) : confirmation du moteur", since: t0) }
            do {
                guard let c = try await currentClient() else {
                    rollback?(); rebuild()
                    error = "Choisis un moteur de téléchargement dans les réglages."
                    return
                }
                try await op(c)
                await refresh()
            } catch {
                rollback?(); rebuild()
                self.error = error.localizedDescription
            }
        }
    }

    func pause(_ hashes: [String]) { setState(hashes, "pausedDL") { try await $0.pause(hashes) } }
    func resume(_ hashes: [String]) { setState(hashes, "downloading") { try await $0.resume(hashes) } }

    /// Pause / reprise : l'état change à l'écran tout de suite, la réponse du moteur le confirme ou le défait.
    private func setState(_ hashes: [String], _ state: String, _ op: @escaping (any TorrentClient) async throws -> Void) {
        let keys = hashes.map { $0.lowercased() }
        let t0 = ContinuousClock.now
        for k in keys { stateOverride[k] = state }
        rebuild()
        let label = state == "pausedDL" ? "pause" : "reprise"
        Perf.log("\(label) : affiché", since: t0)
        run({ c in
            try await op(c)
        }, rollback: { [weak self] in keys.forEach { self?.stateOverride[$0] = nil } }, label: label)
        // après la confirmation (ou l'échec), le moteur fait foi
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); keys.forEach { self.stateOverride[$0] = nil }; self.rebuild() }
    }

    /// Annulation : l'affiche disparaît tout de suite ; elle revient si le moteur refuse.
    func cancel(_ hashes: [String], deleteFiles: Bool) {
        let keys = hashes.map { $0.lowercased() }
        let t0 = ContinuousClock.now
        keys.forEach { hidden.insert($0); starting[$0] = nil }
        rebuild()
        Perf.log("annulation : affiché", since: t0)
        run({ try await $0.delete(hashes, deleteFiles: deleteFiles) },
            rollback: { [weak self] in keys.forEach { self?.hidden.remove($0) } }, label: "annulation")
        if deleteFiles { LibraryStore.shared.rescan() }
    }

    /// Ajout à la main : l'empreinte est notée tout de suite, l'affiche apparaît en « Préparation », la fiche est
    /// cherchée d'après le nom.
    func add(_ payloads: [TorrentPayload], to dest: String?) {
        let t0 = ContinuousClock.now
        let hashes = payloads.compactMap { $0.infoHash?.lowercased() }
        for p in payloads {
            guard let h = p.infoHash else { continue }
            book.recordManual(hash: h)
            showStarting(hash: h, name: p.displayName ?? "Téléchargement", savePath: dest)
        }
        saveBook()
        Perf.log("lancement : affiché", since: t0)
        run({ c in for p in payloads { try await c.add(p, savePath: dest) } },
            rollback: { [weak self] in hashes.forEach { self?.starting[$0] = nil } }, label: "lancement")
    }

    func add(links: [String], to dest: String?) { add(links.map { TorrentPayload.magnet($0) }, to: dest) }
    func add(files: [URL], to dest: String?) {
        add(files.compactMap { u in (try? Data(contentsOf: u)).map { TorrentPayload.file($0, name: u.lastPathComponent) } }, to: dest)
    }

    /// Glisser-déposer d'un .torrent ou d'un lien magnet n'importe où dans la fenêtre.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                any = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL, url.pathExtension.lowercased() == "torrent" { self.pendingFiles.append(url) }
                        else if url.scheme == "magnet" { self.pendingLinks.append(url.absoluteString) }
                    }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                any = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    let links = (s ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.hasPrefix("magnet:") }
                    Task { @MainActor in self.pendingLinks += links }
                }
            }
        }
        return any
    }
}

/// Ajout à la main (menu Fichier, glisser-déposer) : feuilles « lien magnet » et « où télécharger ? ».
struct ManualAddSheets: ViewModifier {
    @StateObject private var model = DownloadsModel.shared
    @EnvironmentObject var settings: AppSettings
    @State private var magnetText = ""
    @State private var destination = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showMagnetSheet) { magnetSheet }
            .fileImporter(isPresented: $model.showTorrentImporter, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
                          allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { model.pendingFiles += urls }
            }
            .sheet(isPresented: Binding(get: { !model.pendingFiles.isEmpty || (!model.pendingLinks.isEmpty && !model.showMagnetSheet) },
                                        set: { if !$0 { model.pendingFiles = []; model.pendingLinks = [] } })) {
                destinationSheet
            }
    }

    private var magnetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajouter des liens magnet").font(.headline)
            Text("Un lien par ligne. Le téléchargement apparaît dans la bibliothèque, avec sa fiche quand Strapontin la reconnaît.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $magnetText).font(.system(.body, design: .monospaced)).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Annuler") { model.showMagnetSheet = false }.keyboardShortcut(.cancelAction)
                Button("Continuer") {
                    let links = magnetText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.hasPrefix("magnet:") }
                    magnetText = ""
                    model.showMagnetSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.pendingLinks += links }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }

    private var destinationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Où télécharger ?").font(.headline)
            Text("\(model.pendingFiles.count + model.pendingLinks.count) élément(s)").foregroundStyle(.secondary)
            Picker("Dossier", selection: $destination) {
                Text("Dossier par défaut").tag("")
                ForEach(settings.folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
            }
            HStack {
                Spacer()
                Button("Annuler") { model.pendingFiles = []; model.pendingLinks = [] }.keyboardShortcut(.cancelAction)
                Button("Télécharger") {
                    let dest = destination.isEmpty ? nil : destination
                    if !model.pendingLinks.isEmpty { model.add(links: model.pendingLinks, to: dest) }
                    if !model.pendingFiles.isEmpty { model.add(files: model.pendingFiles, to: dest) }
                    model.pendingFiles = []
                    model.pendingLinks = []
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { if destination.isEmpty { destination = settings.folders.first ?? "" } }
    }
}

/// Temps restant lisible (« 1 h 05 », « 12 min »), vide si inconnu.
func etaText(_ s: Int64) -> String {
    guard s > 0, s < 8_640_000 else { return "" }
    return s >= 3600 ? "\(s / 3600) h \(String(format: "%02d", s % 3600 / 60))" : "\(max(1, s / 60)) min"
}

extension DownloadEntry {
    /// « 42 % · 3,2 Mo/s · 5 min », ou l'état (« En pause · 42 % », « En attente de sources »…).
    var statusLine: String {
        let pct = "\(Int((progress * 100).rounded(.down))) %"
        switch phase {
        case .done: return "Terminé"
        case .downloading where dlspeed > 0:
            return [pct, "\(humanSize(dlspeed))/s", etaText(eta)].filter { !$0.isEmpty }.joined(separator: " · ")
        case .metadata: return phase.label
        default: return "\(phase.label) · \(pct)"
        }
    }

    /// Navigation au clic : la fiche (FicheView choisit bibliothèque ou aperçu), ou la page du torrent non identifié.
    @MainActor func destination(_ store: LibraryStore) -> String { mediaKey ?? id }
}
