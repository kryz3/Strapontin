import Foundation

public struct ParsedName: Equatable, Sendable {
    public var isEpisode: Bool
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?
}

/// Devine titre, année, saison/épisode et qualité à partir d'un nom de release
/// (« Film.2019.1080p.BluRay.x265-GRP.mkv », « Série/Saison 1/Série.S01E02.mkv »).
public enum FilenameParser {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg", "flv", "ogv",
    ]

    static let junkTags = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "bluray", "blu-ray", "bdrip", "brrip",
        "remux", "web-dl", "webdl", "webrip", "web", "hdtv", "dvdrip", "hdrip", "hdlight", "x264", "x265",
        "h264", "h265", "h 264", "h 265", "hevc", "avc", "av1", "xvid", "10bit", "10-bit", "8bit", "hdr", "hdr10",
        "hdr10plus", "dv", "dolby vision", "dts", "dts-hd", "truehd", "atmos", "ac3", "eac3", "ddp5", "dd5", "aac",
        "flac", "multi", "multi-vf2", "vf2", "vff", "vfq", "vfi", "vf", "vo", "vostfr", "french", "truefrench",
        "subfrench", "english", "proper", "repack", "extended", "unrated", "remastered", "imax", "complete",
        "integrale", "intégrale", "custom", "fansub", "amzn", "nf", "dsnp", "hmax", "atvp",
    ]

    public static func isVideo(_ url: URL, size: Int64? = nil) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard videoExtensions.contains(ext), !url.lastPathComponent.hasPrefix(".") else { return false }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let isSample = stem.range(of: #"(^|[\W_])(sample|trailer|bande[ ._-]?annonce)([\W_]|$)"#,
                                  options: .regularExpression) != nil
        if isSample, (size ?? 0) < 300 * 1024 * 1024 { return false }
        return true
    }

    public static func parse(_ url: URL, root: URL? = nil) -> ParsedName {
        let stem = url.deletingPathExtension().lastPathComponent
        let quality = qualityString(stem)
        let name = normalize(stem)

        // 1) épisode : S01E02, 1x02
        if let m = firstMatch(#"(?i)\bs(\d{1,2})\s?e(\d{1,4})(?!\d)"#, in: name) ?? firstMatch(#"(?i)\b(\d{1,2})x(\d{2,3})\b"#, in: name) {
            var title = clean(String(name[..<m.range.lowerBound]))
            if title.isEmpty { title = showNameFromFolders(url, root: root) ?? stem }
            let (t, y) = splitYear(title)
            return ParsedName(isEpisode: true, title: t, year: y, season: Int(m.groups[0]),
                              episode: Int(m.groups[1]), quality: quality)
        }
        // 2) dossier « Saison 2 » + fichier « E03 » / « Episode 3 » / « 03 »
        if let season = seasonFromFolder(url),
           let m = firstMatch(#"(?i)(?:^|\s)(?:e|ep|episode|épisode)?\s?(\d{1,3})(?:\s|$)"#, in: name) {
            let show = showNameFromFolders(url, root: root) ?? clean(String(name[..<m.range.lowerBound]))
            let (t, y) = splitYear(show)
            return ParsedName(isEpisode: true, title: t.isEmpty ? stem : t, year: y, season: season,
                              episode: Int(m.groups[0]), quality: quality)
        }
        // 3) film : titre avant la dernière année plausible, sinon avant le premier tag technique
        let (t, y) = splitYear(name)
        var title = t
        if y == nil { title = cutAtJunk(name) }
        title = clean(title)
        if title.isEmpty { title = clean(stem) }
        return ParsedName(isEpisode: false, title: title, year: y, season: nil, episode: nil, quality: quality)
    }

    // MARK: - Aides

    struct Match { var range: Range<String.Index>; var groups: [String] }

    static func firstMatch(_ pattern: String, in s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        var groups: [String] = []
        for i in 1..<max(1, m.numberOfRanges) {
            if let gr = Range(m.range(at: i), in: s) { groups.append(String(s[gr])) } else { groups.append("") }
        }
        return Match(range: r, groups: groups)
    }

    /// Points et underscores -> espaces, crochets de groupe retirés.
    static func normalize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[\(\[\{]\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\s\-–:,(\[]+$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[\s\-–]+"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Coupe à la dernière année (1900-2099) qui n'est pas en tout début de nom.
    static func splitYear(_ s: String) -> (String, Int?) {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d])(19\d{2}|20\d{2})(?![\d])"#) else { return (s, nil) }
        let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for m in ms.reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            let before = clean(String(s[..<r.lowerBound]))
            if before.isEmpty { continue }   // « 1917 » ou « 2001 l'odyssée » : c'est le titre
            return (clean(cutAtJunk(before)), Int(s[r]))
        }
        return (clean(s), nil)
    }

    static func cutAtJunk(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        for (i, w) in words.enumerated() {
            let lw = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]-"))
            let base = lw.components(separatedBy: "-").first ?? lw
            if i > 0, junkTags.contains(lw) || junkTags.contains(base) { break }
            kept.append(w)
        }
        return kept.joined(separator: " ")
    }

    static func seasonFromFolder(_ url: URL) -> Int? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard let m = firstMatch(#"(?i)^(?:saison|season|s)\s?(\d{1,2})$"#, in: parent.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int(m.groups[0])
    }

    static func showNameFromFolders(_ url: URL, root: URL?) -> String? {
        var dir = url.deletingLastPathComponent()
        for _ in 0..<2 {
            if let root, dir.standardizedFileURL.path == root.standardizedFileURL.path { return nil }
            let n = dir.lastPathComponent
            if seasonFromFolder(dir.appendingPathComponent("x")) == nil, !n.isEmpty, n != "/" {
                let cleaned = clean(cutAtJunk(normalize(n).replacingOccurrences(
                    of: #"(?i)\s(saison|season|s)\s?\d{1,2}.*$"#, with: "", options: .regularExpression)))
                if !cleaned.isEmpty { return cleaned }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func qualityString(_ s: String) -> String? {
        let l = s.lowercased()
        var q: [String] = []
        func has(_ p: String) -> Bool { l.range(of: p, options: .regularExpression) != nil }
        if has(#"2160p|\b4k\b|\buhd\b"#) { q.append("4K") }
        else if has("1080[pi]") { q.append("1080p") }
        else if has("720p") { q.append("720p") }
        if has("remux") { q.append("Remux") }
        else if has(#"blu-?ray|bdrip|brrip"#) { q.append("Blu-ray") }
        else if has(#"web-?dl|webrip|\bweb\b"#) { q.append("WEB") }
        if has(#"\bdv\b|dolby.?vision|\bdovi\b"#) { q.append("Dolby Vision") }
        if has(#"hdr10\+|hdr10plus"#) { q.append("HDR10+") } else if has(#"\bhdr(10)?\b"#) { q.append("HDR") }
        if has(#"x265|h\.?265|hevc"#) { q.append("HEVC") }
        else if has(#"x264|h\.?264|avc"#) { q.append("H.264") }
        else if has(#"\bav1\b"#) { q.append("AV1") }
        if has("atmos") { q.append("Atmos") }
        if has("truehd") { q.append("TrueHD") }
        else if has(#"dts-?hd|dts-?ma"#) { q.append("DTS-HD") }
        else if has(#"\bdts\b"#) { q.append("DTS") }
        return q.isEmpty ? nil : q.joined(separator: " · ")
    }
}
