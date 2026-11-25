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
/// La qualité voulue, en termes simples (Réglages › Téléchargements, ou par série depuis sa fiche).
public enum QualityChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case hd720 = "720p", fullHD = "1080p", uhdIfAvailable = "4K si disponible", best = "La meilleure"
    public var id: String { rawValue }

    /// (résolution visée, résolution maximale acceptée)
    var resolutions: (target: Int, max: Int) {
        switch self {
        case .hd720: return (720, 1080)
        case .fullHD: return (1080, 1080)
        case .uhdIfAvailable, .best: return (2160, 2160)
        }
    }
}

public struct GrabPreferences: Codable, Hashable, Sendable {
    public var resolution: Int = 1080                 // visée ; on accepte en dessous seulement si rien d'autre
    public var maxResolution: Int = 1080
    public var languages: [ReleaseLanguage] = [.multi, .vff, .french, .vfq, .vostfr]   // ordre de préférence
    public var minSeeders: Int = 1
    public var maxSizeGB: Double = 0                  // 0 = pas de limite
    public var avoidWords: [String] = ["cam", "hdcam", "telesync", "ts", "screener"]
    /// Qualité choisie dans les réglages ; fixe `resolution` et `maxResolution`.
    public var quality: QualityChoice = .fullHD { didSet { apply(quality) } }
    /// Taille maximale d'un épisode seul, en Go (0 = pas de limite ; les saisons complètes ne sont pas concernées).
    public var maxEpisodeGB: Double = 0
    /// Une série déjà commencée garde la qualité et la source de ses épisodes (1080p WEB, 4K BluRay…).
    public var matchExisting = true

    public init() {}

    mutating func apply(_ q: QualityChoice) { (resolution, maxResolution) = q.resolutions }

    /// Avec la qualité propre à une série, si elle en a une.
    public func overriding(_ q: QualityChoice?) -> GrabPreferences {
        guard let q else { return self }
        var p = self
        p.quality = q
        return p
    }

    enum CodingKeys: String, CodingKey { case resolution, maxResolution, languages, minSeeders, maxSizeGB, avoidWords, quality, maxEpisodeGB, matchExisting }

    // réglages enregistrés par une version d'avant : les nouveaux champs prennent leur valeur par défaut
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GrabPreferences()
        languages = try c.decodeIfPresent([ReleaseLanguage].self, forKey: .languages) ?? d.languages
        minSeeders = try c.decodeIfPresent(Int.self, forKey: .minSeeders) ?? d.minSeeders
        maxSizeGB = try c.decodeIfPresent(Double.self, forKey: .maxSizeGB) ?? d.maxSizeGB
        avoidWords = try c.decodeIfPresent([String].self, forKey: .avoidWords) ?? d.avoidWords
        maxEpisodeGB = try c.decodeIfPresent(Double.self, forKey: .maxEpisodeGB) ?? d.maxEpisodeGB
        matchExisting = try c.decodeIfPresent(Bool.self, forKey: .matchExisting) ?? d.matchExisting
        if let q = try c.decodeIfPresent(QualityChoice.self, forKey: .quality) {
            quality = q
            apply(q)
        } else {
            // ancienne version : seulement une résolution visée
            let r = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? 1080
            quality = r >= 2160 ? .uhdIfAvailable : r <= 720 ? .hd720 : .fullHD
            apply(quality)
        }
    }
}

/// La « signature » des épisodes déjà téléchargés d'une série : résolution et source les plus fréquentes.
public struct SeriesStyle: Equatable, Sendable {
    public var resolution: Int?
    public var source: String?      // « web », « bluray », « hdtv »
    public init(resolution: Int?, source: String?) { self.resolution = resolution; self.source = source }

    public static func source(of name: String) -> String? {
        let l = name.lowercased()
        func has(_ re: String) -> Bool { l.range(of: re, options: .regularExpression) != nil }
        if has(#"\b(remux|blu-?ray|bdrip|brrip|bdmv)\b"#) { return "bluray" }
        if has(#"\b(web-?dl|webrip|web|nf|amzn|dsnp|hmax|atvp)\b"#) { return "web" }
        if has(#"\bhdtv\b"#) { return "hdtv" }
        return nil
    }

    /// D'après les noms des fichiers déjà là (nil s'il n'y en a pas).
    public static func from(names: [String]) -> SeriesStyle? {
        guard !names.isEmpty else { return nil }
        func mostCommon<T: Hashable>(_ values: [T]) -> T? {
            Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
        }
        let infos = names.map { ReleaseInfo.parse($0) }
        let style = SeriesStyle(resolution: mostCommon(infos.compactMap(\.resolution)), source: mostCommon(names.compactMap(source)))
        return style.resolution == nil && style.source == nil ? nil : style
    }
}

public enum ReleasePicker {
    /// Note une release ; nil = rejetée. Plus c'est haut, mieux c'est.
    public static func score(_ item: TorznabItem, _ info: ReleaseInfo, prefs: GrabPreferences, style: SeriesStyle? = nil) -> Double? {
        if let s = item.seeders, s < prefs.minSeeders { return nil }
        if prefs.maxSizeGB > 0, Double(item.size) > prefs.maxSizeGB * 1_073_741_824 { return nil }
        if prefs.maxEpisodeGB > 0, info.episode != nil, !info.isSeasonPack, Double(item.size) > prefs.maxEpisodeGB * 1_073_741_824 { return nil }
        let words = Set(item.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if prefs.avoidWords.contains(where: { words.contains($0.lowercased()) }) { return nil }
        if let r = info.resolution, r > prefs.maxResolution { return nil }
        guard let lang = info.language, let li = prefs.languages.firstIndex(of: lang) else { return nil }

        var score = 0.0
        score += Double(prefs.languages.count - li) * 100            // la langue d'abord
        switch info.resolution {
        case prefs.resolution?: score += 80
        case let r? where r > prefs.resolution: score += 50
        case let r? where r < prefs.resolution: score += 20 + Double(r) / 100   // en dessous : la plus haute
        default: score += 10
        }
        // « La meilleure » : à résolution égale, la meilleure source
        if prefs.quality == .best {
            switch SeriesStyle.source(of: item.title) {
            case "bluray"?: score += 12
            case "web"?: score += 6
            default: break
            }
        }
        // même qualité et même source que les épisodes déjà là
        if prefs.matchExisting, let style {
            if let r = style.resolution, info.resolution == r { score += 60 }
            if let src = style.source, SeriesStyle.source(of: item.title) == src { score += 25 }
        }
        if item.isFreeleech { score += 15 }
        score += min(30, log2(Double(max(1, item.seeders ?? 1))) * 4)   // 1 → 0, 128 → 28
        return score
    }

    public static func best(_ items: [TorznabItem], prefs: GrabPreferences, style: SeriesStyle? = nil,
                            where accept: (ReleaseInfo) -> Bool) -> (TorznabItem, ReleaseInfo)? {
        items.compactMap { it -> (TorznabItem, ReleaseInfo, Double)? in
            let info = ReleaseInfo.parse(it.releaseName)
            guard accept(info), let s = score(it, info, prefs: prefs, style: style) else { return nil }
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
