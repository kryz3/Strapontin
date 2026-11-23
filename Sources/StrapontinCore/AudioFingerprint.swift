import Accelerate
import Foundation

// Repérer ce que les épisodes d'une saison ont en commun (intro, générique de fin) à l'oreille, comme Intro Skipper
// de Jellyfin. Empreinte maison (signes des différences d'énergie entre bandes, Haitsma & Kalker) calculée avec
// Accelerate : le FFmpeg embarqué n'a pas Chromaprint, et ça évite une dépendance.

public struct AudioFingerprint: Equatable, Sendable {
    public static let sampleRate = 8000
    static let size = 4096          // 0,512 s
    static let hop = 800            // 0,1 s
    static let lag = 4              // différence prise 0,4 s plus tôt : tolère un calage imparfait
    public static let secondsPerFrame = Double(hop) / Double(sampleRate)

    /// Un mot de 32 bits toutes les 0,1 s ; 0 = silence.
    public var words: [UInt32]

    public init(words: [UInt32]) { self.words = words }

    /// - samples : mono, 8 kHz, -1…1.
    public init(samples: [Float]) {
        let n = Self.size
        guard samples.count >= n, let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else { words = []; return }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binWidth = Double(Self.sampleRate) / Double(n)
        let edges = (0...33).map { i -> Int in Int(300 * pow(2000.0 / 300, Double(i) / 33) / binWidth) }

        let count = (samples.count - n) / Self.hop + 1
        var diffs = [Float](repeating: 0, count: count * 32)
        var loud = [Bool](repeating: false, count: count)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        var bands = [Float](repeating: 0, count: 33)

        for i in 0..<count {
            samples.withUnsafeBufferPointer { s in
                let p = s.baseAddress! + i * Self.hop
                var rms: Float = 0
                vDSP_rmsqv(p, 1, &rms, vDSP_Length(n))
                loud[i] = rms > 0.001       // -60 dB
                vDSP_vmul(p, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            guard loud[i] else { continue }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
                }
            }
            for b in 0..<33 {
                var sum: Float = 0
                for k in edges[b]..<max(edges[b] + 1, edges[b + 1]) { sum += power[k] }
                bands[b] = log(sum + 1e-9)
            }
            for b in 0..<32 { diffs[i * 32 + b] = bands[b] - bands[b + 1] }
        }

        var out = [UInt32](repeating: 0, count: count)
        if count > Self.lag {
            for i in Self.lag..<count where loud[i] && loud[i - Self.lag] {
                var w: UInt32 = 0
                for b in 0..<32 where diffs[i * 32 + b] > diffs[(i - Self.lag) * 32 + b] { w |= UInt32(1) << UInt32(b) }
                out[i] = w == 0 ? 1 : w
            }
        }
        words = out
    }

    /// Milieu de ce que décrit le mot i.
    static func time(_ i: Int) -> Double {
        max(0, Double(i) * secondsPerFrame + (Double(size) / 2 - Double(lag * hop) / 2) / Double(sampleRate))
    }

    public var data: Data { words.withUnsafeBufferPointer { Data(buffer: $0) } }

    public init?(data: Data) {
        guard data.count % 4 == 0 else { return nil }
        var w = [UInt32](repeating: 0, count: data.count / 4)
        _ = w.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        words = w
    }

    /// Le plus franc passage commun aux deux empreintes, quel que soit le décalage.
    public static func commonSpan(_ a: AudioFingerprint, _ b: AudioFingerprint, length: ClosedRange<Double>) -> (a: MediaSpan, b: MediaSpan)? {
        let window = 20                 // 2 s
        let limit = 205                 // 32 % de bits différents sur la fenêtre (le hasard : 50 %)
        let maxGap = 25                 // un trou de 2,5 s (effet sonore, blanc) ne coupe pas
        let minFrames = Int(length.lowerBound / secondsPerFrame)
        let n = a.words.count, m = b.words.count
        guard n >= minFrames, m >= minFrames, minFrames > window else { return nil }

        var errors = [Int32](repeating: 0, count: min(n, m))
        var best: (score: Int, from: Int, to: Int, shift: Int)?

        a.words.withUnsafeBufferPointer { x in
            b.words.withUnsafeBufferPointer { y in
                errors.withUnsafeMutableBufferPointer { err in
                    var shift = -(n - minFrames)
                    while shift <= m - minFrames {
                        let lo = max(0, -shift), hi = min(n, m - shift)
                        let len = hi - lo
                        var i = 0
                        while i < len {
                            let p = x[lo + i], q = y[lo + i + shift]
                            err[i] = p == 0 || q == 0 ? 16 : Int32((p ^ q).nonzeroBitCount)
                            i += 1
                        }
                        var sum = 0, from = -1, lastGood = -1, score = 0
                        func close() {
                            if from >= 0, lastGood - from >= minFrames - window, score > (best?.score ?? 0) {
                                let t0 = time(lo + from), t1 = time(lo + lastGood)
                                if t1 - t0 >= length.lowerBound - 1 { best = (score, lo + from, lo + lastGood, shift) }
                            }
                            from = -1; score = 0
                        }
                        i = 0
                        while i < len {
                            sum += Int(err[i])
                            if i >= window { sum -= Int(err[i - window]) }
                            if i >= window - 1 {
                                let center = i - window / 2
                                if sum < limit {
                                    if from < 0 { from = center }
                                    lastGood = center
                                    score += limit - sum
                                } else if from >= 0, center - lastGood > maxGap {
                                    close()
                                }
                            }
                            i += 1
                        }
                        close()
                        shift += 1
                    }
                }
            }
        }
        guard let best else { return nil }
        func span(_ from: Int, _ to: Int) -> MediaSpan {
            let s = time(from)
            // collé au début : la première seconde n'a pas encore d'empreinte complète
            return MediaSpan(start: s < 2 ? 0 : s, end: time(to))
        }
        let sa = span(best.from, best.to), sb = span(best.from + best.shift, best.to + best.shift)
        guard sa.length >= length.lowerBound, sa.length <= length.upperBound else { return nil }
        return (sa, sb)
    }
}

/// Un épisode prêt à comparer.
public struct EpisodeAudio: Sendable {
    public var id: String
    public var episode: Int
    public var duration: Double
    public var head: AudioFingerprint
    public var tail: AudioFingerprint

    public init(id: String, episode: Int, duration: Double, head: AudioFingerprint, tail: AudioFingerprint) {
        self.id = id; self.episode = episode; self.duration = duration; self.head = head; self.tail = tail
    }
}

public enum SeasonAudioDetector {
    public static let introLength = 15.0...150.0
    public static let creditsLength = 15.0...330.0

    /// Début analysé : 10 min au plus, et environ le premier quart (sinon un épisode court retrouve son générique de fin).
    public static func headLength(duration d: Double) -> Double { min(600, max(d / 4, min(90, d / 2))) }
    /// Fin analysée : 6 min au plus.
    public static func tailLength(duration d: Double) -> Double { min(360, max(d * 0.15, min(90, d * 0.4))) }

    public static func detect(_ input: [EpisodeAudio], isCancelled: () -> Bool = { false }) -> [String: DetectedMarkers] {
        let eps = input.sorted { ($0.episode, $0.id) < ($1.episode, $1.id) }
        var intros: [String: [MediaSpan]] = [:], credits: [String: [MediaSpan]] = [:]
        let numbers = Array(Set(eps.map(\.episode))).sorted()
        let order = Dictionary(uniqueKeysWithValues: numbers.enumerated().map { ($1, $0) })

        for i in eps.indices {
            for j in eps.indices where j > i {
                if isCancelled() { return [:] }
                let a = eps[i], b = eps[j]
                // jamais deux fichiers du même épisode ; quatre voisins suffisent
                guard a.episode != b.episode, order[b.episode]! - order[a.episode]! <= 4 else { continue }
                if let m = AudioFingerprint.commonSpan(a.head, b.head, length: introLength) {
                    intros[a.id, default: []].append(m.a)
                    intros[b.id, default: []].append(m.b)
                }
                if let m = AudioFingerprint.commonSpan(a.tail, b.tail, length: creditsLength) {
                    func inFile(_ s: MediaSpan, _ e: EpisodeAudio) -> MediaSpan {
                        let offset = max(0, e.duration - tailLength(duration: e.duration))
                        var r = MediaSpan(start: offset + s.start, end: min(e.duration, offset + s.end))
                        if e.duration - r.end < 2 { r.end = e.duration }
                        return r
                    }
                    credits[a.id, default: []].append(inFile(m.a, a))
                    credits[b.id, default: []].append(inFile(m.b, b))
                }
            }
        }
        var out: [String: DetectedMarkers] = [:]
        for e in eps {
            out[e.id] = DetectedMarkers(intro: consensus(intros[e.id] ?? []),
                                        credits: consensus((credits[e.id] ?? []).filter { e.duration - $0.end <= 120 }))
        }
        return out
    }

    /// Le passage sur lequel le plus de voisins s'accordent, le plus long à égalité.
    static func consensus(_ spans: [MediaSpan]) -> MediaSpan? {
        let groups = spans.map { s in spans.filter { abs($0.start - s.start) < 5 && abs($0.end - s.end) < 5 } }
        guard let best = groups.max(by: { ($0.count, $0[0].length) < ($1.count, $1[0].length) }) else { return nil }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        return MediaSpan(start: median(best.map(\.start)), end: median(best.map(\.end)))
    }
}
