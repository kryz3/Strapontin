import CryptoKit
import Foundation
import StrapontinCore

/// Intros et génériques repérés à l'oreille, saison par saison, en arrière-plan après le scan.
///
/// Le résultat est dans intro-markers.json (jamais dans library.json : une autre version doit pouvoir le relire),
/// les empreintes dans les caches. Pendant une lecture, seule la saison regardée est analysée.
@MainActor
final class IntroAnalyzer {
    static let shared = IntroAnalyzer()

    private struct Entry: Codable {
        var size: Int64
        var markers: DetectedMarkers
    }

    private struct Saved: Codable {
        var version: Int
        var files: [String: Entry]
        var seasons: [String: String]   // saison → signature de ses fichiers
    }

    private struct Job {
        var id: String
        var signature: String
        var files: [MediaFile]
    }

    private var entries: [String: Entry] = [:]
    private var done: [String: String] = [:]
    private var queue: [Job] = []
    private var running: (job: Job, task: Task<([String: DetectedMarkers], complete: Bool)?, Never>)?
    private var watching: String?
    private var playing = false
    private var retry: Timer?
    private let stateURL: URL
    private let cacheDir: URL

    private init() {
        stateURL = LibraryStore.shared.supportDir.appendingPathComponent("intro-markers.json")
        cacheDir = LibraryStore.shared.cacheDir.appendingPathComponent("empreintes", isDirectory: true)
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(Saved.self, from: d),
           s.version == AudioExtractor.version {
            entries = s.files
            done = s.seasons
        }
    }

    func markers(for file: MediaFile) -> DetectedMarkers? {
        guard let e = entries[file.path], e.size == file.size else { return nil }
        return e.markers
    }

    /// Après chaque scan.
    func schedule() {
        guard AppSettings.shared.detectIntros else { queue = []; return }
        let store = LibraryStore.shared
        var groups: [String: [MediaFile]] = [:]
        for f in store.files where f.episode != nil && f.season != nil { groups[Self.group(f), default: []].append(f) }

        var tooYoung = false
        queue = groups.compactMap { id, files -> Job? in
            guard Set(files.compactMap(\.episode)).count >= 2 else { return nil }
            let signature = files.map { "\($0.path)|\($0.size)|\($0.episode ?? 0)" }.sorted().joined(separator: "\n")
            let digest = SHA256.hash(data: Data(signature.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            guard done[id] != digest, running?.job.signature != digest else { return nil }
            // fichier en cours de copie : on repasse
            if files.contains(where: { Date().timeIntervalSince1970 - $0.mtime < 30 }) { tooYoung = true; return nil }
            return Job(id: id, signature: digest, files: files)
        }
        // la saison la plus récemment touchée d'abord
        .sorted { ($0.files.map(\.added).max() ?? 0) > ($1.files.map(\.added).max() ?? 0) }

        retry?.invalidate()
        if tooYoung {
            retry = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { _ in
                MainActor.assumeIsolated { IntroAnalyzer.shared.schedule() }
            }
        }
        next()
    }

    /// Lecture commencée : sa saison passe devant, les autres attendent la fin de la lecture.
    func playbackStarted(_ file: MediaFile?) {
        playing = true
        watching = file.map(Self.group)
        if let r = running, r.job.id != watching {
            r.task.cancel()
        }
        next()
    }

    func playbackEnded() {
        playing = false
        watching = nil
        next()
    }

    private static func group(_ f: MediaFile) -> String {
        "\(f.mediaKey ?? "u:" + f.guessTitle.lowercased())|s\(f.season ?? 0)"
    }

    private func next() {
        guard running == nil, AppSettings.shared.detectIntros else { return }
        guard let i = playing ? queue.firstIndex(where: { $0.id == watching }) : queue.indices.first else { return }
        let job = queue.remove(at: i)
        let dir = cacheDir, languages = AppSettings.shared.audioLangs
        let inputs = job.files
        let task = Task.detached(priority: .utility) { () -> ([String: DetectedMarkers], complete: Bool)? in
            var eps: [EpisodeAudio] = []
            var complete = true
            for f in inputs {
                if Task.isCancelled { return nil }
                guard let r = Self.fingerprints(f, cache: dir, languages: languages),
                      let head = AudioFingerprint(data: r.head), let tail = AudioFingerprint(data: r.tail) else {
                    complete = false
                    continue
                }
                eps.append(EpisodeAudio(id: f.path, episode: f.episode ?? 0, duration: r.duration, head: head, tail: tail))
            }
            let found = SeasonAudioDetector.detect(eps, isCancelled: { Task.isCancelled })
            return Task.isCancelled ? nil : (found, complete)
        }
        running = (job, task)
        Task {
            let result = await task.value
            running = nil
            if let (found, complete) = result {
                for f in job.files {
                    if let m = found[f.path] { entries[f.path] = Entry(size: f.size, markers: m) }
                }
                // un fichier illisible (disque débranché…) : la saison sera refaite au prochain scan
                if complete { done[job.id] = job.signature }
                save()
            } else {
                queue.append(job)
            }
            next()
        }
    }

    private nonisolated static func fingerprints(_ f: MediaFile, cache dir: URL, languages: String) -> AudioExtractor.Result? {
        let id = SHA256.hash(data: Data("\(f.path)|\(f.size)|\(languages)|\(AudioExtractor.version)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent("\(id).plist")
        if let d = try? Data(contentsOf: url), let r = try? PropertyListDecoder().decode(AudioExtractor.Result.self, from: d) { return r }
        guard let r = AudioExtractor.fingerprints(path: f.path, audioLanguages: languages, cancelled: { Task.isCancelled }) else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let d = try? encoder.encode(r) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? d.write(to: url, options: .atomic)
        }
        return r
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(version: AudioExtractor.version, files: entries, seasons: done)) {
            try? d.write(to: stateURL, options: .atomic)
        }
    }
}
