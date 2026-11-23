import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Vignettes de la barre de temps : un second libmpv, sans son ni fenêtre, qui saute d'image clé en image clé.
/// La vignette survolée passe devant ; sinon il prépare une planche toutes les 10 s, gardée sur le disque.
///
/// HDR10, HLG et Dolby Vision 8 : filtre `gpu` de mpv (tone-mapping). Dolby Vision 5 : seul gpu-next sait en rendre
/// les couleurs et il lui faut une fenêtre, donc la vignette est en noir et blanc plutôt que verte et violette.
final class ThumbnailEngine: @unchecked Sendable {
    static let step = 10
    static let width = 240

    static func slot(_ t: Double) -> Int { max(0, Int(t)) / step }

    /// Appelé sur le fil principal.
    var onThumbnail: ((Int, Data) -> Void)?

    private let path: String
    private let cacheURL: URL?
    private let pregenerate: Bool
    private let lock = NSCondition()
    private var wanted: Int?
    private var playhead = 0
    private var stopped = false
    private var images: [Int: Data] = [:]

    init(path: String, cacheDirectory: URL?, pregenerate: Bool = true) {
        self.path = path
        self.pregenerate = pregenerate
        if let dir = cacheDirectory, let a = try? FileManager.default.attributesOfItem(atPath: path) {
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let id = SHA256.hash(data: Data("\(path)|\(size)|\(Int(date))|v1".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            cacheURL = dir.appendingPathComponent("\(id).plist")
        } else {
            cacheURL = nil
        }
        let thread = Thread { [self] in work() }
        thread.qualityOfService = .utility
        thread.name = "lecteur.vignettes"
        thread.start()
    }

    /// La vignette survolée : seule la dernière demande est gardée.
    func request(_ t: Double) {
        lock.lock()
        wanted = Self.slot(t)
        lock.signal()
        lock.unlock()
    }

    func follow(_ t: Double) {
        lock.lock()
        playhead = Self.slot(t)
        lock.unlock()
    }

    func image(_ slot: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return images[slot]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.signal()
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: fil de travail

    private func work() {
        if let url = cacheURL, let d = try? Data(contentsOf: url), let saved = try? PropertyListDecoder().decode([Int: Data].self, from: d) {
            lock.lock()
            images = saved
            lock.unlock()
            for (slot, data) in saved { deliver(slot, data) }
        }
        let options: [(String, String)] = [
            ("vo", "null"), ("ao", "null"), ("aid", "no"), ("hwdec", "videotoolbox-copy"), ("hr-seek", "no"), ("pause", "yes"),
            ("keep-open", "yes"), ("cache", "no"), ("demuxer-readahead-secs", "0"), ("demuxer-max-bytes", "8MiB"),
            ("demuxer-max-back-bytes", "0"), ("vd-lavc-threads", "2"),
        ]
        guard let mpv = HeadlessMPV(options: options) else { return }
        let stop = { [unowned self] in self.isStopped }
        mpv.command(["loadfile", path, "replace"])
        guard mpv.wait(for: [.restarted], timeout: 20, cancelled: stop) == .restarted,
              let duration = mpv.get("duration").flatMap(Double.init), duration > 1 else { return }
        configure(mpv)

        let last = Self.slot(max(0, duration - 1))
        var failed = Set<Int>()
        var added = 0

        while true {
            lock.lock()
            var slot: Int?
            var hovered = false
            while !stopped {
                if let w = wanted {
                    wanted = nil
                    let s = min(w, last)
                    if images[s] == nil, !failed.contains(s) { slot = s; hovered = true; break }
                    continue
                }
                if pregenerate {
                    // à partir de la tête de lecture, puis le début
                    let from = min(playhead, last)
                    let order = [from...last, 0...from]
                    if let s = order.lazy.compactMap({ r in r.first { self.images[$0] == nil && !failed.contains($0) } }).first {
                        slot = s
                        break
                    }
                    if added > 0 {
                        added = 0
                        let copy = images
                        lock.unlock()
                        save(copy)
                        lock.lock()
                        continue
                    }
                }
                lock.wait()
            }
            let over = stopped
            lock.unlock()
            if over { break }
            guard let slot else { continue }

            if let data = make(mpv, at: min(Double(slot * Self.step), duration - 1), cancelled: stop) {
                lock.lock()
                images[slot] = data
                lock.unlock()
                added += 1
                deliver(slot, data)
            } else {
                failed.insert(slot)
            }
            if !hovered {
                // la planche laisse souffler la lecture ; une demande de survol la réveille aussitôt
                lock.lock()
                if wanted == nil, !stopped { _ = lock.wait(until: Date().addingTimeInterval(0.1)) }
                lock.unlock()
            }
        }
        if added > 0 {
            lock.lock()
            let copy = images
            lock.unlock()
            save(copy)
        }
    }

    private func configure(_ mpv: HeadlessMPV) {
        let w = mpv.get("video-params/dw").flatMap(Double.init) ?? 16
        let h = mpv.get("video-params/dh").flatMap(Double.init) ?? 9
        guard w > 0, h > 0 else { return }
        let height = max(2, min(Self.width * 2, Int((Double(Self.width) * h / w / 2).rounded()) * 2))
        let gamma = mpv.get("video-params/gamma") ?? ""
        let filter: String
        if mpv.get("current-tracks/video/dolby-vision-profile") == "5" {
            filter = "scale=\(Self.width):\(height),format=gray"
        } else if gamma == "pq" || gamma == "hlg" {
            filter = "gpu=w=\(Self.width):h=\(height):api=vulkan"
        } else {
            filter = "scale=\(Self.width):\(height)"
        }
        mpv.set("vf", filter)
    }

    private func make(_ mpv: HeadlessMPV, at t: Double, cancelled: () -> Bool) -> Data? {
        _ = mpv.wait(for: [], timeout: 0)
        guard mpv.command(["seek", String(t), "absolute+keyframes"]),
              mpv.wait(for: [.restarted], timeout: 5, cancelled: cancelled) == .restarted,
              let f = mpv.frame() else { return nil }
        return Self.jpeg(f)
    }

    static func jpeg(_ f: HeadlessMPV.Frame) -> Data? {
        guard let provider = CGDataProvider(data: f.bgr0 as CFData),
              let full = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.stride,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        var image = full
        if f.width > width + 2 {
            // un filtre qui n'a pas pris : on réduit ici, jamais de 4K en mémoire
            let h = max(1, f.height * width / f.width)
            guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: full.colorSpace!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: width, height: h))
            guard let small = ctx.makeImage() else { return nil }
            image = small
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private func deliver(_ slot: Int, _ data: Data) {
        DispatchQueue.main.async { self.onThumbnail?(slot, data) }
    }

    private func save(_ images: [Int: Data]) {
        guard let url = cacheURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(images) else { return }
        let fm = FileManager.default, dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // les 60 dernières planches suffisent (quelques Mo chacune au plus)
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        for old in all.filter({ $0.pathExtension == "plist" }).sorted(by: { date($0) > date($1) }).dropFirst(60) {
            try? fm.removeItem(at: old)
        }
    }
}
