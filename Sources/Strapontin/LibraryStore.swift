import AppKit
import Foundation
import StrapontinCore

/// Le SDK macOS récent exporte aussi un `LibraryItem` (DeveloperToolsSupport, via SwiftUI) :
/// cet alias, déclaré dans le module, l'emporte sur les noms importés et lève l'ambiguïté.
typealias LibraryItem = StrapontinCore.LibraryItem

/// État de la bibliothèque : fichiers, fiches, scan, surveillance des dossiers.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var media: [String: Media] = [:]
    @Published private(set) var items: [LibraryItem] = []
    @Published var status: String = ""
    @Published var isScanning = false

    let settings = AppSettings.shared
    let supportDir: URL
    let cacheDir: URL
    private var watcher: FolderWatcher?
    private var periodic: Timer?
    private var debounce: Timer?
    private var scanAgain = false

    private struct Saved: Codable {
        var files: [MediaFile]
        var media: [Media]
    }

    private init() {
        let fm = FileManager.default
        supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin")
        cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Strapontin")
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistance

    private var dbURL: URL { supportDir.appendingPathComponent("library.json") }

    private func load() {
        guard let data = try? Data(contentsOf: dbURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        files = saved.files
        media = Dictionary(saved.media.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        rebuild()
    }

    private func save() {
        let saved = Saved(files: files, media: Array(media.values))
        let url = dbURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func rebuild() {
        let new = LibraryItem.build(files: files, media: media)
        // une entrée qui change d'id (fiche corrigée, enfin identifiée) : les pages ouvertes la suivent
        let moved = LibraryItem.redirects(from: items, to: new)
        if !moved.isEmpty {
            redirects.merge(moved) { _, n in n }
            // chaînes (A → B puis B → C) : tout pointe vers le dernier
            for (k, v) in redirects { if let n = moved[v] { redirects[k] = n } }
        }
        items = new
    }

    /// Ancien id d'entrée → nouvel id (pour la session).
    @Published private(set) var redirects: [String: String] = [:]

    /// L'entrée affichée sous cet id, en suivant les redirections.
    func resolve(_ id: String) -> LibraryItem? {
        if let i = item(id: id) { return i }
        var seen = Set<String>(), cur = id
        while let n = redirects[cur], seen.insert(cur).inserted {
            if let i = item(id: n) { return i }
            cur = n
        }
        return nil
    }

    func posterURL(_ m: Media) -> URL { cacheDir.appendingPathComponent("posters/\(m.kind.rawValue)_\(m.tmdbId).jpg") }
    func backdropURL(_ m: Media) -> URL { cacheDir.appendingPathComponent("backdrops/\(m.kind.rawValue)_\(m.tmdbId).jpg") }

    // MARK: - Démarrage et surveillance

    func start() {
        // les dossiers par défaut sont créés s'ils n'existent pas encore
        for f in settings.folders where !FileManager.default.fileExists(atPath: f) && AppSettings.defaultFolders.contains(f) {
            try? FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true)
        }
        foldersChanged()
    }

    func foldersChanged() {
        let folders = settings.folders
        files.removeAll { !folders.contains($0.folder) }
        rebuild()
        watcher = FolderWatcher(paths: folders) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        periodic?.invalidate()
        if settings.rescanMinutes > 0 {
            periodic = Timer.scheduledTimer(withTimeInterval: Double(settings.rescanMinutes) * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rescan() }
            }
        }
        rescan()
    }

    func addFolder(_ path: String) {
        guard !settings.folders.contains(path) else { return }
        settings.folders.append(path)
        foldersChanged()
    }

    func removeFolder(_ path: String) {
        settings.folders.removeAll { $0 == path }
        foldersChanged()
    }

    private func scheduleRescan() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    // MARK: - Scan + identification

    func rescan(retryNotFound: Bool = false) {
        if retryNotFound {
            for i in files.indices where files[i].matchState == .notFound { files[i].matchState = .pending }
        }
        if isScanning { scanAgain = true; return }
        isScanning = true
        let folders = settings.folders
        Task {
            var changed = false
            for folder in folders {
                status = "Scan de \((folder as NSString).lastPathComponent)…"
                let found = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(folder: folder) }.value
                guard let found else { continue }   // dossier inaccessible : on ne touche à rien
                let (merged, c) = LibraryScanner.merge(known: files, folder: folder, found: found)
                if c { files = merged; changed = true }
            }
            if changed {
                pruneMedia()
                rebuild()
                save()
            }
            await matchPending()
            status = ""
            isScanning = false
            IntroAnalyzer.shared.schedule()
            if scanAgain { scanAgain = false; rescan() }
        }
    }

    private func tmdb() -> TMDbClient? {
        settings.effectiveTMDbKey.isEmpty ? nil : TMDbClient(key: settings.effectiveTMDbKey, language: settings.tmdbLanguage, omdbKey: settings.omdbKey)
    }

    private func matchPending() async {
        guard let client = tmdb() else { return }
        let pending = files.filter { $0.matchState == .pending }
        guard !pending.isEmpty else { return }
        var cache: [String: String?] = [:]          // recherche -> clé de fiche
        var seasons: [String: [Int: EpisodeInfo]] = [:]  // "tvId:saison" -> épisodes
        for (n, f) in pending.enumerated() {
            status = "Identification \(n + 1)/\(pending.count) : \(f.guessTitle)"
            // vient d'un téléchargement rattaché : sa fiche et son épisode, sans passer un instant par une fiche devinée
            if let o = DownloadsModel.shared.origin(of: f.path) {
                claim(pathPrefix: o.path, media: o.media, season: o.link.season, episode: o.link.episode)
                continue
            }
            let q = "\(f.kind.rawValue)|\(f.guessTitle.lowercased())|\(f.isEpisode ? 0 : (f.guessYear ?? 0))"
            do {
                if cache[q] == nil {
                    cache[q] = try await findMedia(client, kind: f.kind, title: f.guessTitle, year: f.guessYear)
                }
                guard let idx = files.firstIndex(where: { $0.path == f.path }) else { continue }
                guard let key = cache[q] ?? nil, let m = media[key] else {
                    files[idx].matchState = .notFound
                    continue
                }
                files[idx].mediaKey = key
                files[idx].matchState = .matched
                if m.kind == .tv, let s = f.season {
                    let sk = "\(m.tmdbId):\(s)"
                    if seasons[sk] == nil { seasons[sk] = await client.seasonEpisodes(tvId: m.tmdbId, season: s) }
                    apply(f.episode.flatMap { seasons[sk]?[$0] }, to: idx)
                }
            } catch let e as TMDbError {
                status = e.localizedDescription
                break
            } catch {
                continue   // réseau coupé : on réessaiera au prochain scan
            }
            if n % 10 == 9 { rebuild() }
        }
        rebuild()
        save()
    }

    private func apply(_ info: EpisodeInfo?, to idx: Int) {
        files[idx].episodeTitle = info?.name
        files[idx].episodeOverview = info?.overview
        files[idx].stillPath = info?.stillPath
    }

    private func findMedia(_ client: TMDbClient, kind: MediaKind, title: String, year: Int?) async throws -> String? {
        guard !title.isEmpty else { return nil }
        var hit = try await client.bestMatch(kind, title: title, year: year)
        if hit == nil, kind == .movie {
            hit = try await client.bestMatch(.tv, title: title, year: year)   // fichier mal nommé
        }
        guard let hit else { return nil }
        return try await storeMedia(client, kind: hit.kind, id: hit.id)
    }

    @discardableResult
    func storeMedia(_ client: TMDbClient, kind: MediaKind, id: Int) async throws -> String {
        let key = Media.key(kind, id)
        if media[key] != nil { return key }
        let m = try await client.details(kind, id: id)
        _ = await client.downloadImage(m.posterPath, size: "w500", to: posterURL(m))
        _ = await client.downloadImage(m.backdropPath, size: "w1280", to: backdropURL(m))
        media[key] = m
        return key
    }

    private func pruneMedia() {
        let used = Set(files.compactMap(\.mediaKey))
        media = media.filter { used.contains($0.key) }
    }

    /// Correction manuelle : rattache tous les fichiers d'une entrée à une fiche choisie.
    func assign(_ item: LibraryItem, kind: MediaKind, tmdbId: Int) async {
        guard let client = tmdb() else { return }
        status = "Récupération de la fiche…"
        do {
            let key = try await storeMedia(client, kind: kind, id: tmdbId)
            var seasons: [Int: [Int: EpisodeInfo]] = [:]
            for f in item.files {
                guard let idx = files.firstIndex(where: { $0.path == f.path }) else { continue }
                files[idx].mediaKey = key
                files[idx].matchState = .manual
                if kind == .tv, let s = f.season {
                    if seasons[s] == nil { seasons[s] = await client.seasonEpisodes(tvId: tmdbId, season: s) }
                    apply(f.episode.flatMap { seasons[s]?[$0] }, to: idx)
                }
            }
            pruneMedia()
            rebuild()
            save()
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    /// Téléchargement terminé dont on connaît la fiche : ses fichiers la prennent, avec leur épisode (sauf correction
    /// à la main), même si leur nom aurait mené ailleurs ou nulle part. Appelé à chaque passage : ne fait rien s'il
    /// n'y a rien à changer.
    func claim(pathPrefix: String, media m: Media, season: Int? = nil, episode: Int? = nil) {
        let prefix = pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
        let inside = files.filter { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
        guard !inside.isEmpty, !claiming.contains(prefix) else { return }
        let place = m.kind == .tv ? EpisodeRules.placement(files: inside, season: season, episode: episode) : [:]
        let paths = Set(inside.filter { f in
            guard f.matchState != .manual else { return false }
            if f.mediaKey != m.key { return true }
            return place[f.path].map { $0.season != f.season || $0.episode != f.episode } ?? false
        }.map(\.path))
        guard !paths.isEmpty else { return }
        claiming.insert(prefix)
        Task {
            defer { claiming.remove(prefix) }
            let client = tmdb()
            if media[m.key] == nil {
                // copie complète de la fiche (genres, distribution…) si possible, sinon celle du téléchargement
                let full = (try? await client?.details(m.kind, id: m.tmdbId)) ?? m
                _ = await client?.downloadImage(full.posterPath, size: "w500", to: posterURL(full))
                _ = await client?.downloadImage(full.backdropPath, size: "w1280", to: backdropURL(full))
                media[m.key] = full
            }
            var infos: [Int: [Int: EpisodeInfo]] = [:]
            if m.kind == .tv, let client {
                let seasons = Set(inside.filter { paths.contains($0.path) }.compactMap { place[$0.path]?.season ?? $0.season })
                for s in seasons { infos[s] = await client.seasonEpisodes(tvId: m.tmdbId, season: s) }
            }
            // par chemin, pas par indice : un scan peut passer pendant les attentes réseau
            for i in files.indices where paths.contains(files[i].path) && files[i].matchState != .manual {
                files[i].mediaKey = m.key
                files[i].matchState = .matched
                if let k = place[files[i].path] {
                    files[i].isEpisode = true
                    files[i].season = k.season
                    files[i].episode = k.episode
                }
                if m.kind == .tv, let s = files[i].season, let e = files[i].episode { apply(infos[s]?[e], to: i) }
                else if m.kind == .movie { files[i].isEpisode = false }
            }
            pruneMedia()
            rebuild()
            save()
        }
    }
    private var claiming = Set<String>()

    // MARK: - Lecture

    /// creditsStart : début du générique s'il est connu (« vu » dès qu'on l'atteint, sinon à 92 %).
    func saveProgress(path: String, position: Double, duration: Double, finished: Bool, creditsStart: Double? = nil) {
        guard let idx = files.firstIndex(where: { $0.path == path }) else { return }
        let watched = finished || PlaybackMarkers.isWatched(position: position, duration: duration, creditsStart: creditsStart)
        files[idx].watched = watched
        files[idx].position = watched ? 0 : position
        if duration > 0 { files[idx].duration = duration }
        files[idx].lastPlayed = Date().timeIntervalSince1970
        rebuild()
        save()
    }

    func setWatched(_ paths: [String], _ watched: Bool) {
        for i in files.indices where paths.contains(files[i].path) {
            files[i].watched = watched
            files[i].position = 0
        }
        rebuild()
        save()
    }

    func item(id: String) -> LibraryItem? { items.first { $0.id == id } }
}
