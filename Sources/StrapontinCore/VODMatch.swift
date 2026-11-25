import Foundation

/// Rapprochement des films et séries IPTV avec TMDb, pour qu'un titre n'ait qu'une fiche quelle que soit la source.
///
/// Prudent : mieux vaut un titre non reconnu (rangé dans « Autres titres IPTV ») qu'une mauvaise fiche.
public enum VODMatch {
    /// Titre normalisé pour comparer : sans pays ni qualité (VODTitle.clean), minuscules, sans accents ni ponctuation,
    /// « & » = « et », chiffres romains II–IX en chiffres, article de tête ignoré.
    public static func normalize(_ title: String) -> String { fastKey(title).key }

    /// Mentions techniques qui ne font pas partie du titre (langue, qualité, édition).
    private static let noise: Set<String> = [
        "hd", "fhd", "uhd", "4k", "8k", "sd", "1080p", "720p", "2160p", "480p", "hevc", "x264", "x265", "h264", "h265", "10bit",
        "multi", "vf", "vff", "vfq", "vfi", "vo", "vost", "vostfr", "truefrench", "french", "subfrench", "dual", "hdr", "hdr10", "dv",
        "imax", "remastered", "extended", "uncut", "unrated", "bluray", "webrip", "webdl", "web", "dl", "hdtv", "cam", "ts",
        "netflix", "nf", "amzn", "dsnp", "vip", "new", "sub", "subs", "dub", "dubbed", "eng", "fr", "en",
    ]
    private static let roman: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]

    /// Position du « S01E02 » (ou « S01 E02 ») dans les mots d'un nom.
    static func episodeIndex(_ words: [String]) -> Int? {
        for (i, w) in words.enumerated() where w.count >= 2 && w.first == "s" && w.dropFirst().first?.isNumber == true {
            let rest = w.dropFirst()
            if let e = rest.firstIndex(of: "e"), rest[..<e].allSatisfy(\.isNumber), !rest[rest.index(after: e)...].isEmpty,
               rest[rest.index(after: e)...].allSatisfy(\.isNumber) { return i }
            if rest.allSatisfy(\.isNumber), i + 1 < words.count, let n = words[i + 1].first, n == "e",
               words[i + 1].count > 1, words[i + 1].dropFirst().allSatisfy(\.isNumber) { return i }
        }
        return nil
    }

    /// Saison et épisode d'un nom de playlist (« The Bear S01 E02 » → (1, 2)).
    public static func episode(_ name: String) -> (season: Int, episode: Int)? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let i = episodeIndex(words) else { return nil }
        let w = words[i].dropFirst()
        if let e = w.firstIndex(of: "e"), let s = Int(w[..<e]), let ep = Int(w[w.index(after: e)...]) { return (s, ep) }
        if let s = Int(w), let ep = Int(words[i + 1].dropFirst()) { return (s, ep) }
        return nil
    }

    /// Titre et année d'un nom de fournisseur, sans expressions régulières (des centaines de milliers de titres) :
    /// « FR | Dune (2021) [MULTI] 4K » → (« dune », 2021). Le pays en tête et les mentions techniques tombent ;
    /// l'année est le dernier nombre de 1900 à 2099 qui n'est pas tout le titre (« 1917 (2019) » → « 1917 », 2019).
    public static func fastKey(_ raw: String) -> (key: String, year: Int?) {
        let (_, rest) = IPTVCountry.stripPrefix(ChannelName.decorate(raw))
        let folded = rest.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var words: [String] = []
        var cur = ""
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { cur.unicodeScalars.append(ch) }
            else {
                if !cur.isEmpty { words.append(cur); cur = "" }
                if ch == "&" { words.append("et") }
            }
        }
        if !cur.isEmpty { words.append(cur) }
        // série de playlist : on s'arrête avant « S01E02 » / « S01 E02 »
        if let i = episodeIndex(words) { words = Array(words[..<i]) }
        var year: Int?
        if let i = words.lastIndex(where: { $0.count == 4 && Int($0).map { (1900...2099).contains($0) } == true }), words.count > 1 {
            year = Int(words[i]); words.remove(at: i)
        }
        words = words.filter { !noise.contains($0) }.map { roman[$0] ?? $0 }
        if words.count > 1, ["the", "le", "la", "les", "l"].contains(words[0]) { words.removeFirst() }
        return (words.joined(separator: " "), year)
    }

    /// Clé d'un titre IPTV : même film en VF, MULTI, 4K… → même clé.
    public static func key(kind: IPTVKind, title: String, year: Int?) -> String {
        let k = fastKey(title)
        return "\(kind == .series ? "tv" : "movie")|\(k.key)|\((year ?? k.year).map(String.init) ?? "")"
    }

    /// Le bon résultat TMDb, ou nil si aucun n'est sûr. Il faut le même titre (exact ou original) ; l'année départage,
    /// et une année trop différente écarte le résultat.
    public static func best(_ results: [TMDbSearchResult], title: String, year: Int?, originalTitles: [Int: String] = [:]) -> TMDbSearchResult? {
        let want = normalize(title)
        guard !want.isEmpty else { return nil }
        var scored: [(TMDbSearchResult, Int)] = []
        for (rank, r) in results.prefix(10).enumerated() {
            let names = [r.title, originalTitles[r.id]].compactMap { $0 }.map(normalize)
            let same = names.contains(want)
            let close = !same && names.contains { $0.hasPrefix(want + " ") || want.hasPrefix($0 + " ") }
            guard same || close else { continue }
            var score = same ? 100 : 40
            if let year, let ry = r.year {
                let d = abs(ry - year)
                if d == 0 { score += 50 } else if d == 1 { score += 25 } else if d > 2 { continue }
            } else if year != nil, r.year == nil {
                score -= 10
            }
            score -= rank * 3
            scored.append((r, score))
        }
        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        // titre seulement approché, sans année pour confirmer : pas assez sûr
        if top.1 < 60 { return nil }
        return top.0
    }
}

/// Un film ou une série d'une playlist, réduit à l'essentiel pour la retrouver depuis une fiche TMDb.
public struct VODRef: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: IPTVKind
    /// Nom tel que le fournisseur l'écrit (pour distinguer les versions : VF, VOSTFR, 4K…).
    public var name: String
    public var key: String
    public var year: Int?
    public var tmdb: Int?
    /// Xtream : identifiant du film (stream_id) ou de la série (series_id), et extension du fichier.
    public var stream: Int?
    public var ext: String?
    /// Playlist sans API : adresse du film ou de l'épisode, et numéros d'épisode.
    public var url: String?
    public var season: Int?
    public var episode: Int?
    public var poster: String?

    public init(id: String, kind: IPTVKind, name: String, tmdb: Int? = nil, stream: Int? = nil, ext: String? = nil, url: String? = nil,
                season: Int? = nil, episode: Int? = nil, poster: String? = nil, year: Int? = nil) {
        let k = VODMatch.fastKey(name)
        self.id = id; self.kind = kind; self.name = name; self.key = k.key; self.year = year ?? k.year; self.tmdb = tmdb
        self.stream = stream; self.ext = ext; self.url = url; self.season = season; self.episode = episode; self.poster = poster
    }
}

/// Index des films et séries d'IPTV : clé de titre et identifiant TMDb → versions. Recherche « à l'envers » : on part
/// de la fiche TMDb ouverte, aucune requête réseau.
public struct VODLookup: Sendable {
    public private(set) var refs: [VODRef] = []
    private var byKey: [String: [Int32]] = [:]
    private var byTmdb: [Int: [Int32]] = [:]

    public init(_ refs: [VODRef] = []) {
        self.refs = refs
        for (i, r) in refs.enumerated() {
            byKey["\(r.kind.rawValue)|\(r.key)", default: []].append(Int32(i))
            if let t = r.tmdb, t > 0 { byTmdb[t, default: []].append(Int32(i)) }
        }
    }

    public var count: Int { refs.count }

    /// Versions d'un titre : par identifiant TMDb si le fournisseur le donne, sinon par titre (et titres originaux) et
    /// année (à un an près ; une version sans année est acceptée).
    public func find(kind: IPTVKind, tmdbId: Int?, titles: [String], year: Int?) -> [VODRef] {
        var out: [VODRef] = []
        var seen = Set<String>()
        if let t = tmdbId, let list = byTmdb[t] {
            for i in list where refs[Int(i)].kind == kind && seen.insert(refs[Int(i)].id).inserted { out.append(refs[Int(i)]) }
        }
        for title in titles {
            let k = VODMatch.fastKey(title).key
            guard !k.isEmpty, let list = byKey["\(kind.rawValue)|\(k)"] else { continue }
            for i in list {
                let r = refs[Int(i)]
                if let y = year, let ry = r.year, abs(ry - y) > 1 { continue }
                if let rt = r.tmdb, let t = tmdbId, rt > 0, rt != t { continue }
                if seen.insert(r.id).inserted { out.append(r) }
            }
        }
        return out
    }

    /// Recherche par le nom (« Autres titres IPTV » dans la recherche) : un résultat par titre.
    public func search(_ query: String, limit: Int = 30) -> [VODRef] {
        let q = VODMatch.fastKey(query).key
        guard q.count >= 2 else { return [] }
        var out: [VODRef] = []
        var seen = Set<String>()
        var prefix: [VODRef] = []
        for r in refs where r.episode == nil || r.episode == 1 {
            guard r.key.contains(q), seen.insert("\(r.kind.rawValue)|\(r.key)|\(r.year ?? 0)").inserted else { continue }
            if r.key == q || r.key.hasPrefix(q) { prefix.append(r) } else { out.append(r) }
            if prefix.count >= limit { break }
        }
        return Array((prefix + out).prefix(limit))
    }

    /// Épisodes d'une série de playlist sans API (mêmes clé et type, avec numéros).
    public func episodes(of ref: VODRef) -> [VODRef] {
        (byKey["\(ref.kind.rawValue)|\(ref.key)"] ?? []).map { refs[Int($0)] }.filter { $0.episode != nil }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }
}
