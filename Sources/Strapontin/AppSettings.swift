import Foundation
import SwiftUI

/// Réglages persistés dans UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    static let defaultFolders = [
        NSHomeDirectory() + "/Documents/Films",
        NSHomeDirectory() + "/Documents/Séries",
    ]

    @Published var folders: [String] { didSet { d.set(folders, forKey: "folders") } }
    /// Clé TMDb saisie dans les réglages (vide = celle fournie à la compilation, voir Secrets).
    @Published var tmdbKey: String { didSet { d.set(tmdbKey, forKey: "tmdbKey") } }
    /// La clé réellement utilisée.
    var effectiveTMDbKey: String {
        let k = tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? Secrets.tmdbKey : k
    }
    @Published var tmdbLanguage: String { didSet { d.set(tmdbLanguage, forKey: "tmdbLanguage") } }
    @Published var omdbKey: String { didSet { d.set(omdbKey, forKey: "omdbKey") } }
    @Published var rescanMinutes: Int { didSet { d.set(rescanMinutes, forKey: "rescanMinutes") } }

    @Published var hwdec: String { didSet { d.set(hwdec, forKey: "hwdec") } }
    @Published var highQuality: Bool { didSet { d.set(highQuality, forKey: "highQuality") } }
    /// Enchaîner l'épisode suivant tout seul.
    @Published var autoplayNext: Bool { didSet { d.set(autoplayNext, forKey: "autoplayNext") } }
    /// Repérer intros et génériques à l'oreille, en arrière-plan.
    @Published var detectIntros: Bool { didSet { d.set(detectIntros, forKey: "detectIntros") } }
    @Published var passthrough: Bool { didSet { d.set(passthrough, forKey: "passthrough") } }
    @Published var audioLangs: String { didSet { d.set(audioLangs, forKey: "audioLangs") } }
    @Published var subLangs: String { didSet { d.set(subLangs, forKey: "subLangs") } }
    /// Sous-titres en ligne (OpenSubtitles.com) : clé API et langues cherchées, dans l'ordre.
    @Published var openSubtitlesKey: String { didSet { d.set(openSubtitlesKey, forKey: "openSubtitlesKey") } }
    @Published var onlineSubLangs: String { didSet { d.set(onlineSubLangs, forKey: "onlineSubLangs") } }
    var effectiveOpenSubtitlesKey: String {
        let k = openSubtitlesKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? Secrets.openSubtitlesKey : k
    }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }

    @Published var qbitEnabled: Bool { didSet { d.set(qbitEnabled, forKey: "qbitEnabled") } }
    @Published var qbitURL: String { didSet { d.set(qbitURL, forKey: "qbitURL") } }
    @Published var qbitUser: String { didSet { d.set(qbitUser, forKey: "qbitUser") } }
    @Published var qbitPassword: String { didSet { d.set(qbitPassword, forKey: "qbitPassword") } }

    private init() {
        folders = d.stringArray(forKey: "folders") ?? Self.defaultFolders
        tmdbKey = d.string(forKey: "tmdbKey") ?? ""
        tmdbLanguage = d.string(forKey: "tmdbLanguage") ?? "fr-FR"
        omdbKey = d.string(forKey: "omdbKey") ?? ""
        rescanMinutes = d.object(forKey: "rescanMinutes") as? Int ?? 15
        hwdec = d.string(forKey: "hwdec") ?? "auto-safe"
        highQuality = d.object(forKey: "highQuality") as? Bool ?? true
        autoplayNext = d.object(forKey: "autoplayNext") == nil ? true : d.bool(forKey: "autoplayNext")
        detectIntros = d.object(forKey: "detectIntros") == nil ? true : d.bool(forKey: "detectIntros")
        passthrough = d.object(forKey: "passthrough") as? Bool ?? false
        audioLangs = d.string(forKey: "audioLangs") ?? "fre,fra,fr,eng,en"
        subLangs = d.string(forKey: "subLangs") ?? "fre,fra,fr"
        openSubtitlesKey = d.string(forKey: "openSubtitlesKey") ?? ""
        onlineSubLangs = d.string(forKey: "onlineSubLangs") ?? "fr,en"
        volume = d.object(forKey: "volume") as? Double ?? 100
        qbitEnabled = d.object(forKey: "qbitEnabled") as? Bool ?? false
        qbitURL = d.string(forKey: "qbitURL") ?? "http://127.0.0.1:8080"
        qbitUser = d.string(forKey: "qbitUser") ?? "admin"
        qbitPassword = d.string(forKey: "qbitPassword") ?? ""
    }
}
