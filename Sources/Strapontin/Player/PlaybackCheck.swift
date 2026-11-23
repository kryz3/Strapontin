import Foundation
import ImageIO
import StrapontinCore

/// Contrôles sans fenêtre, comme `--selftest` : ils prouvent que les bibliothèques embarquées savent faire.
///   Strapontin --analyser ep1.mkv ep2.mkv …       intro et générique trouvés à l'oreille
///   Strapontin --vignettes film.mkv [dossier]     latence des vignettes, sans puis avec planche
enum PlaybackCheck {
    /// true : c'était une de ces commandes, le programme se termine quand elle finit.
    static func run(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--analyser") {
            let files = Array(args[(i + 1)...].prefix { !$0.hasPrefix("-") })
            Thread { analyse(files); fflush(stdout); exit(0) }.start()
            return true
        }
        if let i = args.firstIndex(of: "--vignettes"), i + 1 < args.count {
            let out = i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : nil
            Thread { thumbnails(args[i + 1], out: out); fflush(stdout); exit(0) }.start()
            return true
        }
        return false
    }

    private static func analyse(_ files: [String]) {
        var eps: [EpisodeAudio] = []
        for (n, path) in files.enumerated() {
            let t0 = Date()
            guard let r = AudioExtractor.fingerprints(path: path, audioLanguages: "fre,fra,fr,eng,en"),
                  let head = AudioFingerprint(data: r.head), let tail = AudioFingerprint(data: r.tail) else {
                print("ANALYSE échec \((path as NSString).lastPathComponent)")
                continue
            }
            print(String(format: "ANALYSE lu en %.1f s, durée %.1f s : %@", -t0.timeIntervalSinceNow, r.duration, (path as NSString).lastPathComponent))
            let episode = ReleaseInfo.parse((((path as NSString).lastPathComponent) as NSString).deletingPathExtension).episode ?? n + 1
            eps.append(EpisodeAudio(id: path, episode: episode, duration: r.duration, head: head, tail: tail))
        }
        let t0 = Date()
        let found = SeasonAudioDetector.detect(eps)
        print(String(format: "ANALYSE comparaison %.2f s", -t0.timeIntervalSinceNow))
        for e in eps {
            func show(_ s: MediaSpan?) -> String { s.map { String(format: "%.1f → %.1f", $0.start, $0.end) } ?? "—" }
            print("ANALYSE E\(e.episode) intro \(show(found[e.id]?.intro)) · générique \(show(found[e.id]?.credits))")
        }
    }

    private static func thumbnails(_ path: String, out: URL?) {
        guard let duration = duration(path) else { print("VIGNETTE fichier illisible"); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lecteur-vignettes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let points = [0.08, 0.61, 0.33, 0.9, 0.47, 0.22, 0.75, 0.15, 0.55, 0.97].map { $0 * duration }

        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func wait(_ engine: ThumbnailEngine, _ t: Double) -> (Double, Data)? {
            let slot = ThumbnailEngine.slot(min(t, duration - 1)), t0 = Date()
            engine.request(Double(slot * ThumbnailEngine.step))
            while -t0.timeIntervalSinceNow < 8 {
                if let d = engine.image(slot) { return (-t0.timeIntervalSinceNow * 1000, d) }
                usleep(500)
            }
            return nil
        }

        let cold = ThumbnailEngine(path: path, cacheDirectory: nil, pregenerate: false)
        var without: [Double] = []
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (i, t) in points.enumerated() {
            guard let (ms, data) = wait(cold, t) else { print("VIGNETTE échec à \(Int(t)) s"); continue }
            if i == 0 {
                print(String(format: "VIGNETTE première, ouverture comprise : %.0f ms", ms))
            } else {
                without.append(ms)
            }
            if let out { try? data.write(to: out.appendingPathComponent("vignette-\(i).jpg")) }
        }
        cold.stop()
        print(String(format: "VIGNETTE sans planche : médiane %.0f ms, max %.0f ms", median(without), without.max() ?? 0))

        let t0 = Date()
        let builder = ThumbnailEngine(path: path, cacheDirectory: dir)
        let total = ThumbnailEngine.slot(max(0, duration - 1)) + 1
        let limit = min(total, 120)
        while builder.count < limit, -t0.timeIntervalSinceNow < 150 { usleep(100_000) }
        print(String(format: "VIGNETTE planche : %d images sur %d en %.0f s", builder.count, total, -t0.timeIntervalSinceNow))
        var with: [Double] = []
        for i in 0..<10 {
            let slot = i * max(1, builder.count - 1) / 10, t = Date()
            if let data = builder.image(slot), CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil {
                with.append(-t.timeIntervalSinceNow * 1000)
            }
        }
        builder.stop()
        print(String(format: "VIGNETTE avec planche : médiane %.2f ms, max %.2f ms (décodage compris)", median(with), with.max() ?? 0))
        usleep(400_000)
    }

    private static func duration(_ path: String) -> Double? {
        guard let mpv = HeadlessMPV(options: [("vo", "null"), ("ao", "null"), ("pause", "yes")]) else { return nil }
        mpv.command(["loadfile", path, "replace"])
        guard mpv.wait(for: [.loaded], timeout: 20) == .loaded else { return nil }
        return mpv.get("duration").flatMap(Double.init)
    }
}
