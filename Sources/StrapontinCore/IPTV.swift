import Foundation

/// Ce qu'est une entrée de playlist : une chaîne en direct, un film ou un épisode de série à la demande.
public enum IPTVKind: String, Codable, Sendable { case live, movie, series }

/// Une entrée de playlist M3U (#EXTINF + adresse).
public struct IPTVEntry: Codable, Hashable, Identifiable, Sendable {
    /// Stable d'une mise à jour de la playlist à l'autre : tvg-id s'il existe, sinon groupe + nom.
    public var id: String
    public var name: String
    public var url: String
    public var tvgId: String?
    public var logo: String?
    public var group: String
    public var number: Int?
    public var kind: IPTVKind
    /// Playlist d'origine.
    public var playlist: String

    public init(id: String, name: String, url: String, tvgId: String?, logo: String?, group: String, number: Int?,
                kind: IPTVKind, playlist: String) {
        self.id = id; self.name = name; self.url = url; self.tvgId = tvgId; self.logo = logo; self.group = group
        self.number = number; self.kind = kind; self.playlist = playlist
    }
}

/// Lecture rapide d'une playlist M3U / M3U8 étendue (dizaines de milliers d'entrées : une seule passe, pas de regex).
public enum M3UParser {
    public struct Result: Sendable {
        public var entries: [IPTVEntry]
        /// Guide XMLTV annoncé dans l'en-tête (url-tvg / x-tvg-url).
        public var guideURL: String?
    }

    public static func parse(_ text: String, playlist: String = "") -> Result {
        var entries: [IPTVEntry] = []
        entries.reserveCapacity(text.utf8.count / 120)
        var guide: String?
        var pending: (attrs: [String: String], title: String)?
        var groupOverride: String?
        var seen: [String: Int] = [:]
        var autoNumber = 0
        var explicit = Set<String>()

        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            if line.hasPrefix("#EXTM3U") {
                let a = attributes(line)
                guide = a["url-tvg"] ?? a["x-tvg-url"] ?? guide
            } else if line.hasPrefix("#EXTINF") {
                let (attrs, title) = extinf(line)
                pending = (attrs, title)
                groupOverride = nil
            } else if line.hasPrefix("#EXTGRP:") {
                groupOverride = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                return   // #EXTVLCOPT et autres : ignorés
            } else if let p = pending {
                let a = p.attrs
                let name = (p.title.isEmpty ? a["tvg-name"] : p.title) ?? line
                let group = a["group-title"] ?? groupOverride ?? "Autres"
                let kind = classify(url: line, group: group, attrs: a)
                if kind == .live { autoNumber += 1 }
                let number = a["tvg-chno"].flatMap { Int($0) } ?? a["channel-number"].flatMap { Int($0) }
                    ?? (kind == .live ? autoNumber : nil)
                var id = (a["tvg-id"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(group)|\(name)").lowercased()
                // même tvg-id pour plusieurs entrées (qualités, sources de secours) : identifiants distincts
                if let n = seen[id] { seen[id] = n + 1; id += "#\(n + 1)" } else { seen[id] = 1 }
                if a["tvg-chno"] != nil || a["channel-number"] != nil { explicit.insert(playlist + "/" + id) }
                entries.append(IPTVEntry(id: playlist + "/" + id, name: name, url: line, tvgId: a["tvg-id"],
                                         logo: a["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }, group: group,
                                         number: number, kind: kind, playlist: playlist))
                pending = nil
            }
        }
        // numéros : ceux de la playlist s'il y en a ; sinon l'ordre des chaînes (1, 2, 3…)
        if entries.contains(where: { $0.kind == .live && $0.number != nil && explicit.contains($0.id) }) {
            for i in entries.indices where !explicit.contains(entries[i].id) { entries[i].number = nil }
        }
        return Result(entries: entries, guideURL: guide)
    }

    /// `#EXTINF:-1 tvg-id="x" group-title="Sport",Nom` → (attributs, nom). Les virgules dans les attributs entre
    /// guillemets ne coupent pas le nom.
    static func extinf(_ line: String) -> ([String: String], String) {
        let chars = Array(line)
        var inQuote = false
        var comma: Int?
        for (i, c) in chars.enumerated() {
            if c == "\"" { inQuote.toggle() } else if c == ",", !inQuote { comma = i; break }
        }
        guard let comma else { return (attributes(line), "") }
        let head = String(chars[..<comma])
        let title = String(chars[(comma + 1)...]).trimmingCharacters(in: .whitespaces)
        return (attributes(head), title)
    }

    /// `clé="valeur"` (ou `clé=valeur`), clés en minuscules.
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            // nom de l'attribut : lettres, chiffres, tirets
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" { j += 1 }
            if j > i, j < chars.count, chars[j] == "=" {
                let key = String(chars[i..<j]).lowercased()
                var k = j + 1
                var value = ""
                if k < chars.count, chars[k] == "\"" {
                    k += 1
                    let start = k
                    while k < chars.count, chars[k] != "\"" { k += 1 }
                    value = String(chars[start..<min(k, chars.count)])
                    k += 1
                } else {
                    let start = k
                    while k < chars.count, chars[k] != " " { k += 1 }
                    value = String(chars[start..<k])
                }
                out[key] = value
                i = k
            } else {
                i = max(j, i + 1)
            }
        }
        return out
    }

    /// Direct, film ou série : l'adresse d'abord (Xtream : /movie/, /series/ ; fichiers .mp4, .mkv…), puis le groupe.
    static func classify(url: String, group: String, attrs: [String: String]) -> IPTVKind {
        let u = url.lowercased()
        if u.contains("/series/") { return .series }
        if u.contains("/movie/") { return .movie }
        let path = u.split(separator: "?").first.map(String.init) ?? u
        let vodExt = [".mp4", ".mkv", ".avi", ".mov", ".m4v", ".wmv"]
        let g = CatalogFold.fold(group)
        let seriesWords = ["serie", "series", "tv show", "shows", "saison"]
        let movieWords = ["vod", "film", "movie", "cinema"]
        if vodExt.contains(where: { path.hasSuffix($0) }) {
            return seriesWords.contains(where: { g.contains($0) }) || isEpisodeName(attrs["tvg-name"] ?? "") ? .series : .movie
        }
        if seriesWords.contains(where: { g.contains($0) }) && !g.contains("live") { return .series }
        if movieWords.contains(where: { g.contains($0) }) && !g.contains("live") { return .movie }
        return .live
    }

    static func isEpisodeName(_ s: String) -> Bool {
        s.range(of: #"(?i)\bs\d{1,2}\s?e\d{1,3}\b"#, options: .regularExpression) != nil
    }
}

/// Mise à plat des textes pour la recherche : minuscules, sans accents, ponctuation en espaces.
public enum CatalogFold {
    public static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        var out = ""
        out.reserveCapacity(folded.count)
        var lastSpace = true
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return lastSpace && !out.isEmpty ? String(out.dropLast()) : out
    }
}

/// Index de recherche des chaînes et du catalogue : préparé une fois (en tâche de fond), interrogé à chaque frappe.
/// Tolère accents, casse, préfixes, une petite faute par mot (≥ 4 lettres), le numéro de chaîne et le nom du groupe.
public struct IPTVSearchIndex: Sendable {
    struct Row: Sendable {
        var index: Int
        var name: String          // nom mis à plat
        var tokens: [[UInt8]]
        var group: String
        var number: Int?
    }
    private var rows: [Row] = []
    public private(set) var entries: [IPTVEntry] = []

    public init(_ entries: [IPTVEntry]) {
        self.entries = entries
        rows = entries.enumerated().map { i, e in
            let n = CatalogFold.fold(e.name)
            return Row(index: i, name: n, tokens: n.split(separator: " ").map { Array($0.utf8) },
                       group: CatalogFold.fold(e.group), number: e.number)
        }
    }

    /// Les meilleures correspondances, au plus `limit`.
    public func search(_ query: String, kinds: Set<IPTVKind>? = nil, limit: Int = 200) -> [IPTVEntry] {
        let q = CatalogFold.fold(query)
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map { Array($0.utf8) }
        let number = Int(q)
        var scored: [(Int, Double)] = []
        for r in rows {
            if let kinds, !kinds.contains(entries[r.index].kind) { continue }
            var score = 0.0
            if let number, r.number == number { score += 100 }
            if r.name == q { score += 60 } else if r.name.hasPrefix(q) { score += 40 }
            var all = true
            for w in words {
                var best = 0.0
                for t in r.tokens {
                    if t == w { best = 10; break }
                    if t.count >= w.count, t.starts(with: w) { best = max(best, 7); continue }
                    // une faute : seulement si le mot commence pareil (première ou deuxième lettre), sinon trop coûteux
                    if best < 4, w.count >= 4, t.count >= 3, t[0] == w[0] || (t.count > 1 && t[1] == w[1]),
                       Self.closeEnough(t, w) { best = 4 }
                }
                if best == 0, r.group.contains(String(decoding: w, as: UTF8.self)) { best = 2 }
                if best == 0 { all = false; break }
                score += best
            }
            if !all {
                // la frappe tient dans le nom sans être un début de mot (« ance 5 »)
                if r.name.contains(q) { score += 25 } else if score < 25 { continue }
            }
            if score > 0 { scored.append((r.index, score - Double(r.name.count) / 200)) }   // à égalité, le nom le plus court
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).map { entries[$0.0] }
    }

    /// Une seule faute (lettre en trop, en moins, différente, ou deux lettres inversées) entre le mot tapé et le
    /// début d'un mot du nom.
    static func closeEnough(_ token: [UInt8], _ word: [UInt8]) -> Bool {
        for len in [word.count, word.count + 1, word.count - 1] where len > 0 && len <= token.count {
            if osa(token[0..<len], word[...]) <= 1 { return true }
        }
        return false
    }

    /// Distance d'édition avec inversion de deux lettres voisines (Damerau restreinte), sur des mots courts.
    static func osa(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > 1 { return 2 }
        let w = b.count + 1
        var prev2 = [Int](repeating: 0, count: w), prev = Array(0...b.count), cur = [Int](repeating: 0, count: w)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > 1 { return 2 }   // au-delà d'une faute : inutile de continuer
            prev2 = prev; prev = cur
        }
        return prev[b.count]
    }
}

/// Guide des programmes (XMLTV) : ce qui passe maintenant et ensuite, par chaîne.
public struct ProgramGuide: Sendable {
    public struct Program: Hashable, Sendable {
        public var start: Date
        public var stop: Date
        public var title: String
        public var detail: String?
    }
    public private(set) var programs: [String: [Program]] = [:]

    public init(programs: [String: [Program]] = [:]) { self.programs = programs }

    public static func parse(_ data: Data, keepFrom from: Date = Date().addingTimeInterval(-6 * 3600),
                             until: Date = Date().addingTimeInterval(36 * 3600)) -> ProgramGuide {
        let d = XMLTVDelegate(from: from, until: until)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        var out = d.programs
        for k in out.keys { out[k]?.sort { $0.start < $1.start } }
        return ProgramGuide(programs: out)
    }

    /// (maintenant, ensuite) pour une chaîne (tvg-id, insensible à la casse).
    public func nowNext(_ channel: String?, at date: Date = Date()) -> (now: Program?, next: Program?) {
        guard let channel, let list = programs[channel.lowercased()] else { return (nil, nil) }
        guard let i = list.firstIndex(where: { $0.start <= date && date < $0.stop }) else {
            return (nil, list.first { $0.start > date })
        }
        return (list[i], i + 1 < list.count ? list[i + 1] : nil)
    }

    /// « 20250101203000 +0100 »
    static func date(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard let first = parts.first, first.count >= 14 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = parts.count > 1 ? "yyyyMMddHHmmss Z" : "yyyyMMddHHmmss"
        f.timeZone = parts.count > 1 ? nil : TimeZone(identifier: "UTC")
        return f.date(from: parts.count > 1 ? "\(first.prefix(14)) \(parts[1])" : String(first.prefix(14)))
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    let from: Date, until: Date
    var programs: [String: [ProgramGuide.Program]] = [:]
    private var current: (channel: String, start: Date, stop: Date)?
    private var title = "", desc = "", field = ""

    init(from: Date, until: Date) { self.from = from; self.until = until }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        if name == "programme", let ch = a["channel"], let s = a["start"].flatMap(ProgramGuide.date),
           let e = a["stop"].flatMap(ProgramGuide.date), e > from, s < until {
            current = (ch.lowercased(), s, e); title = ""; desc = ""
        }
        field = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        if field == "title" { title += string } else if field == "desc" { desc += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "programme", let c = current {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            programs[c.channel, default: []].append(.init(start: c.start, stop: c.stop, title: t.isEmpty ? "Programme" : t,
                                                          detail: desc.isEmpty ? nil : desc.trimmingCharacters(in: .whitespacesAndNewlines)))
            current = nil
        }
        field = ""
    }
}
