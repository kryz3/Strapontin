import Foundation

/// L'épisode qui suit celui qu'on regarde, saisons comprises. Calculé au moment voulu, pas figé au lancement :
/// un épisode arrivé entre-temps est vu, deux versions du même épisode ne s'enchaînent pas.
public enum NextEpisode: Equatable, Sendable {
    case inLibrary(MediaFile)
    /// Diffusé, pas dans la bibliothèque.
    case missing(EpisodeKey)
    case none

    /// - files : les fichiers de la même série.
    /// - seasons, episodes : ce que TMDb dit (vides hors ligne).
    public static func after(_ current: MediaFile, files: [MediaFile], seasons: [Int],
                             episodes: [Int: [Int: EpisodeInfo]], today: String) -> NextEpisode {
        guard let s = current.season, let first = current.episode else { return .none }
        let e = EpisodeRules.owned([current]).filter { $0.season == s }.map(\.episode).max() ?? first

        var covering: [EpisodeKey: [MediaFile]] = [:]
        for f in files where f.path != current.path {
            for k in EpisodeRules.owned([f]) { covering[k, default: []].append(f) }
        }
        func file(_ k: EpisodeKey) -> NextEpisode? {
            guard let list = covering[k] else { return nil }
            // plusieurs versions : celle commencée, sinon la même qualité que l'épisode en cours
            let sorted = list.sorted { $0.path < $1.path }
            let pick = sorted.first(where: \.inProgress) ?? sorted.first { $0.quality == current.quality } ?? sorted.first
            return pick.map { .inLibrary($0) }
        }
        func known(_ k: EpisodeKey) -> NextEpisode {
            if let f = file(k) { return f }
            guard let air = episodes[k.season]?[k.episode]?.airDate, air <= today else { return .none }
            return .missing(k)
        }

        if let f = file(EpisodeKey(s, e + 1)) { return f }
        let laterInSeason = covering.keys.filter { $0.season == s && $0.episode > e }.map(\.episode).min()

        if let list = episodes[s]?.keys, !list.isEmpty {
            if let n = list.filter({ $0 > e }).min() { return known(EpisodeKey(s, n)) }
            if let n = laterInSeason, let f = file(EpisodeKey(s, n)) { return f }
            guard s > 0 else { return .none }
            if let ns = seasons.filter({ $0 > s }).min() {
                if let n = episodes[ns]?.keys.min() { return known(EpisodeKey(ns, n)) }
                return file(EpisodeKey(ns, 1)) ?? .none
            }
            return file(EpisodeKey(s + 1, 1)) ?? .none
        }
        // TMDb muet : un trou dans la saison est sûr, le reste ne se devine pas
        if laterInSeason != nil { return .missing(EpisodeKey(s, e + 1)) }
        guard s > 0 else { return .none }
        return file(EpisodeKey(s + 1, 1)) ?? .none
    }
}

/// Garder la langue choisie d'un épisode à l'autre : mpv ne retient que le numéro de piste, qui change d'un fichier à l'autre.
public struct TrackTraits: Hashable, Sendable {
    public var id: Int
    public var language: String?
    public var title: String?
    public var forced: Bool
    public var external: Bool
    public var channels: Int?

    public init(id: Int, language: String?, title: String?, forced: Bool = false, external: Bool = false, channels: Int? = nil) {
        self.id = id; self.language = language; self.title = title
        self.forced = forced; self.external = external; self.channels = channels
    }
}

public enum TrackChoice: Equatable, Sendable {
    case track(Int)
    case off
    /// Rien d'équivalent : on laisse mpv choisir selon les réglages.
    case automatic

    static let threeLetters = ["fre": "fr", "fra": "fr", "eng": "en", "ger": "de", "deu": "de", "spa": "es", "ita": "it", "jpn": "ja",
                               "por": "pt", "kor": "ko", "chi": "zh", "zho": "zh", "dut": "nl", "nld": "nl", "rus": "ru", "ara": "ar"]

    static func language(_ l: String?) -> String? {
        guard let base = l?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              !base.isEmpty, base != "und" else { return nil }
        return threeLetters[base] ?? base
    }

    static func forHearingImpaired(_ t: TrackTraits) -> Bool {
        t.title?.lowercased().range(of: #"\bsdh\b|sourds|malentendant|\bcc\b"#, options: .regularExpression) != nil
    }

    static func forcedOnly(_ t: TrackTraits) -> Bool {
        t.forced || t.title?.lowercased().range(of: #"forced|forc[ée]"#, options: .regularExpression) != nil
    }

    static func variant(_ t: TrackTraits) -> String? {
        t.title?.lowercased().range(of: #"\b(vfq|vff|vfi|vf2|vof|ad|audiodescription|commentary|commentaire)\b"#, options: .regularExpression)
            .map { String(t.title!.lowercased()[$0]) }
    }

    /// La piste de `tracks` équivalente à `wanted`. `subtitles` : nil voulu = sous-titres coupés.
    public static func matching(_ wanted: TrackTraits?, in tracks: [TrackTraits], subtitles: Bool) -> TrackChoice {
        guard let w = wanted else { return subtitles ? .off : .automatic }
        let lang = language(w.language)
        let same = tracks.filter { language($0.language) == lang }
        // « forcés seulement » ne devient pas des sous-titres complets
        let pool = subtitles && forcedOnly(w) ? same.filter(forcedOnly) : same
        func score(_ t: TrackTraits) -> Int {
            (forcedOnly(t) == forcedOnly(w) ? 32 : 0) + (variant(t) == variant(w) ? 16 : 0)
                + (forHearingImpaired(t) == forHearingImpaired(w) ? 8 : 0) + (t.title == w.title ? 4 : 0)
                + (t.channels == w.channels ? 2 : 0) + (t.external == w.external ? 1 : 0)
        }
        if let best = pool.max(by: { (score($0), -$0.id) < (score($1), -$1.id) }) { return .track(best.id) }
        return subtitles && forcedOnly(w) ? .off : .automatic
    }
}
