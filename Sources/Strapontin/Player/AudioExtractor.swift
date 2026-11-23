import Foundation
import StrapontinCore

/// Le son du début et de la fin d'un épisode, en mono 8 kHz, décodé par le libmpv embarqué (sortie « pcm » :
/// bien plus vite que le temps réel, rien ne sort des haut-parleurs). Aucune dépendance de plus.
enum AudioExtractor {
    /// Version du calcul : la changer refait les empreintes.
    static let version = 1

    struct Result: Codable {
        var duration: Double
        var head: Data
        var tail: Data
    }

    static func fingerprints(path: String, audioLanguages: String, cancelled: @escaping () -> Bool = { false }) -> Result? {
        // durée inconnue tant que le fichier n'est pas ouvert : on décode 10 min puis on recoupe
        guard let (first, duration) = pcm(path: path, start: 0, length: 600, languages: audioLanguages, cancelled: cancelled),
              duration >= 60 else { return nil }
        let headCount = min(first.count, Int(SeasonAudioDetector.headLength(duration: duration)) * AudioFingerprint.sampleRate)
        let from = max(0, duration - SeasonAudioDetector.tailLength(duration: duration))
        guard let (last, _) = pcm(path: path, start: from, length: nil, languages: audioLanguages, cancelled: cancelled) else { return nil }
        return Result(duration: duration,
                      head: AudioFingerprint(samples: Array(first.prefix(headCount))).data,
                      tail: AudioFingerprint(samples: last).data)
    }

    private static func pcm(path: String, start: Double, length: Double?, languages: String,
                            cancelled: () -> Bool) -> ([Float], duration: Double)? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lecteur-son-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: out) }
        var options: [(String, String)] = [
            ("vid", "no"), ("ao", "pcm"), ("ao-pcm-waveheader", "no"), ("ao-pcm-file", out.path),
            ("audio-format", "s16"), ("audio-samplerate", String(AudioFingerprint.sampleRate)), ("audio-channels", "mono"),
            ("alang", languages), ("volume", "100"), ("hr-seek", "yes"), ("start", String(format: "%.3f", start)),
        ]
        if let length { options.append(("length", String(format: "%.3f", length))) }

        var duration = 0.0
        do {
            guard let mpv = HeadlessMPV(options: options) else { return nil }
            mpv.command(["loadfile", path, "replace"])
            guard mpv.wait(for: [.loaded], timeout: 30, cancelled: cancelled) == .loaded else { return nil }
            duration = mpv.get("duration").flatMap(Double.init) ?? 0
            guard mpv.wait(for: [.ended], timeout: 180, cancelled: cancelled) == .ended else { return nil }
        }   // mpv détruit ici : le fichier est complet

        guard duration > 0, let data = try? Data(contentsOf: out), data.count >= 2 else { return nil }
        let samples = data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        return (samples, duration)
    }
}
