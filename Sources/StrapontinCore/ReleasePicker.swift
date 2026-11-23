import Foundation

/// Ce qu'on lit dans un nom de release (« The.Bear.S03E02.MULTi.1080p.WEB.H264-XXX »).
public struct ReleaseInfo: Hashable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// Dernier épisode si la release en contient plusieurs (« S01E01E02 »).
    public var episodeEnd: Int? = nil
    /// Saison complète (S03, « Saison 3 », « Intégrale » ne compte pas : trop ambigu).
    public var isSeasonPack: Bool
    public var resolution: Int?       // 2160, 1080, 720, 480
    public var language: ReleaseLanguage?
    public var quality: String?       // libellé du FilenameParser, pour l'affichage

    public static func parse(_ releaseName: String) -> ReleaseInfo {
        // FilenameParser attend un chemin : sans extension, « .H265-GRP » serait pris pour l'extension
        let p = FilenameParser.parse(URL(fileURLWithPath: "/" + releaseName.replacingOccurrences(of: "/", with: " ") + ".mkv"))
        let l = releaseName.lowercased()
        func has(_ re: String) -> Bool { l.range(of: re, options: .regularExpression) != nil }

        var info = ReleaseInfo(title: p.title, year: p.year, season: p.season, episode: p.episode,
                               isSeasonPack: false, resolution: nil, language: ReleaseLanguage.detect(l), quality: p.quality)
        if has(#"2160p|\b4k\b|\buhd\b"#) { info.resolution = 2160 }
        else if has("1080[pi]") { info.resolution = 1080 }
        else if has("720p") { info.resolution = 720 }
        else if has(#"480p|\bsd\b|\bdvdrip\b|\bxvid\b"#) { info.resolution = 480 }

        if !p.isEpisode, let r = releaseName.range(of: #"\bs(\d{1,2})(?!\s?e\d)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let s = Int(releaseName[r].dropFirst())
            // titre = ce qui précède « S03 »
            let t = FilenameParser.parse(URL(fileURLWithPath: "/" + String(releaseName[..<r.lowerBound]) + ".mkv"))
            info = ReleaseInfo(title: t.title, year: t.year, season: s, episode: nil, isSeasonPack: true,
                               resolution: info.resolution, language: info.language, quality: info.quality)
        }
        if info.season != nil, let e = info.episode { info.episodeEnd = episodeEnd(in: releaseName, first: e) }
        // « Shogun.S01.1980 » : l'année juste après la saison dit de quelle série il s'agit
        if info.season != nil, info.year == nil,
           let m = FilenameParser.firstMatch(#"(?i)\bs\d{1,2}(?:\s?e\d{1,4})?[\s._(]+((?:19|20)\d{2})(?![\dp])"#, in: releaseName) {
            info.year = Int(m.groups[0])
        }
        return info
    }
}

public enum ReleaseLanguage: String, CaseIterable, Codable, Sendable {
    case multi = "MULTi", vff = "VFF", vfq = "VFQ", french = "FRENCH", vostfr = "VOSTFR", vo = "VO"

    static func detect(_ l: String) -> ReleaseLanguage? {
        func has(_ re: String) -> Bool { l.range(of: re, options: .regularExpression) != nil }
        if has(#"\bmulti(\b|vf|vof|truefrench)"#) { return .multi }   // « MULTiVOF » collé, courant
        if has(#"\bvostfr\b|\bvosfr\b|\bsubfrench\b"#) { return .vostfr }
        if has(#"\bvff\b|\btruefrench\b|\bvf2\b"#) { return .vff }   // VF2 = VFF + VFQ
        if has(#"\bvfq\b"#) { return .vfq }
        // VOF = version originale française (documentaires, films français), courant sur les indexeurs français
        if has(#"\bfrench\b|\bvfi?\b|\bvof\b"#) { return .french }
        return nil
    }
}

/// Préférences de choix d'une release.
public struct GrabPreferences: Codable, Hashable, Sendable {
    public var resolution: Int = 1080                 // visée ; on accepte en dessous seulement si rien d'autre
    public var maxResolution: Int = 2160
    public var languages: [ReleaseLanguage] = [.multi, .vff, .french, .vfq, .vostfr]   // ordre de préférence
    public var minSeeders: Int = 1
    public var maxSizeGB: Double = 0                  // 0 = pas de limite
    public var avoidWords: [String] = ["cam", "hdcam", "telesync", "ts", "screener"]
    public init() {}
}

public enum ReleasePicker {
    /// Note une release ; nil = rejetée. Plus c'est haut, mieux c'est.
    public static func score(_ item: TorznabItem, _ info: ReleaseInfo, prefs: GrabPreferences) -> Double? {
        if let s = item.seeders, s < prefs.minSeeders { return nil }
        if prefs.maxSizeGB > 0, Double(item.size) > prefs.maxSizeGB * 1_073_741_824 { return nil }
        let words = Set(item.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if prefs.avoidWords.contains(where: { words.contains($0.lowercased()) }) { return nil }
        if let r = info.resolution, r > prefs.maxResolution { return nil }
        guard let lang = info.language, let li = prefs.languages.firstIndex(of: lang) else { return nil }

        var score = 0.0
        score += Double(prefs.languages.count - li) * 100            // la langue d'abord
        switch info.resolution {
        case prefs.resolution?: score += 80
        case let r? where r > prefs.resolution: score += 50
        case let r? where r < prefs.resolution: score += 20
        default: score += 10
        }
        if item.isFreeleech { score += 15 }
        score += min(30, log2(Double(max(1, item.seeders ?? 1))) * 4)   // 1 → 0, 128 → 28
        return score
    }

    public static func best(_ items: [TorznabItem], prefs: GrabPreferences,
                            where accept: (ReleaseInfo) -> Bool) -> (TorznabItem, ReleaseInfo)? {
        items.compactMap { it -> (TorznabItem, ReleaseInfo, Double)? in
            let info = ReleaseInfo.parse(it.releaseName)
            guard accept(info), let s = score(it, info, prefs: prefs) else { return nil }
            return (it, info, s)
        }
        .max { $0.2 < $1.2 }
        .map { ($0.0, $0.1) }
    }

    /// Comparaison de titres tolérante (accents, ponctuation, « The », « & »).
    public static func sameTitle(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        let w = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return (w.first == "the" ? Array(w.dropFirst()) : w).joined(separator: " ")
    }
}
