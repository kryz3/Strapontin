import Foundation

/// Noms de chaînes IPTV : les fournisseurs écrivent la même chaîne de dix façons (« FR| CANAL+ SPORT ᴴᴰ »,
/// « Canal Plus Sport FHD », « FR: C+ Sport (backup) »). On en tire :
/// - un nom propre à afficher (« Canal+ Sport ») ;
/// - une clé de comparaison (« canal plus sport ») qui sert à la recherche et à regrouper les variantes ;
/// - la qualité annoncée (4K, FHD, HD, SD) et si c'est une source de secours.
public enum ChannelName {
    public enum Quality: Int, Comparable, Sendable, Codable {
        case sd = 1, unknown = 2, hd = 3, fhd = 4, uhd = 5
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .uhd: "4K"
            case .fhd: "Full HD"
            case .hd: "HD"
            case .sd: "SD"
            case .unknown: "Standard"
            }
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var display: String
        public var key: String
        public var quality: Quality
        public var backup: Bool
        /// Pays écrit devant le nom (« FR| ») s'il y en avait un.
        public var country: String?
    }

    // MARK: mots techniques

    private static let qualityWords: [String: Quality] = [
        "UHD": .uhd, "4K": .uhd, "2160P": .uhd, "8K": .uhd,
        "FHD": .fhd, "1080P": .fhd, "1080I": .fhd, "FULLHD": .fhd,
        "HD": .hd, "720P": .hd, "HQ": .hd,
        "SD": .sd, "LQ": .sd, "480P": .sd, "576P": .sd,
    ]
    private static let backupWords: Set<String> = ["BACKUP", "BKP", "SECOURS", "BACK UP", "ALT", "BK"]
    private static let technicalWords: Set<String> = [
        "HEVC", "H265", "H.265", "H264", "H.264", "X265", "X264", "50FPS", "60FPS", "25FPS", "30FPS", "FPS", "RAW",
        "VIP", "MULTI", "MULTIAUDIO", "PPV", "★", "VO", "VF", "VOSTFR",
        "HDR", "SDR", "DOLBY", "ATMOS", "AAC", "AC3", "MUX", "EVENT", "ONLY", "BK", "LQ",
    ]

    // MARK: alias des grandes chaînes (clé → nom affiché)

    /// Clés reconnues → nom propre. Les clés sont déjà normalisées (voir `key`).
    private static let canonical: [String: String] = [
        "canal plus": "Canal+", "canal plus sport": "Canal+ Sport", "canal plus sport 360": "Canal+ Sport 360",
        "canal plus foot": "Canal+ Foot", "canal plus cinema": "Canal+ Cinéma", "canal plus series": "Canal+ Séries",
        "canal plus premier league": "Canal+ Premier League", "canal plus docs": "Canal+ Docs",
        "canal plus kids": "Canal+ Kids", "canal plus grand ecran": "Canal+ Grand Écran", "canal plus decale": "Canal+ Décalé",
        "canal plus box office": "Canal+ Box Office", "canal plus live 1": "Canal+ Live 1",
        "bein sports": "beIN Sports", "bein sports 1": "beIN Sports 1", "bein sports 2": "beIN Sports 2",
        "bein sports 3": "beIN Sports 3", "bein sports max 4": "beIN Sports Max 4", "bein sports max 5": "beIN Sports Max 5",
        "rmc sport": "RMC Sport", "rmc sport 1": "RMC Sport 1", "rmc sport 2": "RMC Sport 2", "rmc story": "RMC Story",
        "rmc decouverte": "RMC Découverte", "rmc life": "RMC Life",
        "eurosport": "Eurosport", "eurosport 1": "Eurosport 1", "eurosport 2": "Eurosport 2",
        "tf1": "TF1", "tf1 series films": "TF1 Séries Films", "tmc": "TMC", "tfx": "TFX", "lci": "LCI",
        "france 2": "France 2", "france 3": "France 3", "france 4": "France 4", "france 5": "France 5", "france o": "France Ô",
        "franceinfo": "franceinfo", "m6": "M6", "w9": "W9", "6ter": "6ter", "gulli": "Gulli", "paris premiere": "Paris Première",
        "bfm tv": "BFM TV", "bfm business": "BFM Business", "bfm paris": "BFM Paris", "cnews": "CNews", "c8": "C8",
        "cstar": "CStar", "nrj 12": "NRJ 12", "cherie 25": "Chérie 25", "l equipe": "L'Équipe", "arte": "Arte",
        "france 24": "France 24", "tv5 monde": "TV5Monde", "public senat": "Public Sénat", "lcp": "LCP",
        "ocs max": "OCS Max", "ocs city": "OCS City", "ocs choc": "OCS Choc", "ocs geants": "OCS Géants",
        "cine plus premier": "Ciné+ Premier", "cine plus frisson": "Ciné+ Frisson", "cine plus emotion": "Ciné+ Émotion",
        "cine plus famiz": "Ciné+ Famiz", "cine plus club": "Ciné+ Club", "cine plus classic": "Ciné+ Classic",
        "dazn 1": "DAZN 1", "dazn 2": "DAZN 2", "infosport plus": "Infosport+", "golf plus": "Golf+",
        "sky sports main event": "Sky Sports Main Event", "sky sports premier league": "Sky Sports Premier League",
        "sky sports f1": "Sky Sports F1", "sky sports football": "Sky Sports Football", "sky sports news": "Sky Sports News",
        "bbc one": "BBC One", "bbc two": "BBC Two", "itv 1": "ITV1", "channel 4": "Channel 4", "channel 5": "Channel 5",
        "cnn": "CNN", "bbc news": "BBC News", "euronews": "Euronews", "national geographic": "National Geographic",
        "discovery channel": "Discovery Channel", "disney channel": "Disney Channel", "cartoon network": "Cartoon Network",
        "mtv": "MTV",
    ]

    /// Écritures différentes d'un même nom, ramenées à une seule (sur la clé, mot à mot au début).
    private static let keyAliases: [(String, String)] = [
        ("c plus", "canal plus"), ("canalplus", "canal plus"), ("canal sport", "canal plus sport"),
        ("canal plus sports", "canal plus sport"),
        ("beinsports", "bein sports"), ("beinsport", "bein sports"), ("bein sport", "bein sports"), ("bein", "bein sports"),
        ("rmc sports", "rmc sport"), ("rmcsport", "rmc sport"),
        ("euro sport", "eurosport"), ("france info", "franceinfo"), ("bfmtv", "bfm tv"), ("bfm", "bfm tv"),
        ("tv5monde", "tv5 monde"), ("tv 5 monde", "tv5 monde"), ("tv5", "tv5 monde"), ("lequipe", "l equipe"),
        ("l equipe 21", "l equipe"), ("lequipe21", "l equipe"), ("c news", "cnews"), ("c star", "cstar"),
        ("nrj12", "nrj 12"), ("cherie25", "cherie 25"), ("6 ter", "6ter"), ("tf1 series et films", "tf1 series films"),
        ("cineplus", "cine plus"), ("cine plus premiere", "cine plus premier"), ("ocsmax", "ocs max"),
        ("natgeo", "national geographic"), ("nat geo", "national geographic"),
        ("bbc 1", "bbc one"), ("bbc 2", "bbc two"), ("itv", "itv 1"), ("itv1", "itv 1"), ("e4", "e4"),
        ("france2", "france 2"), ("france3", "france 3"), ("france4", "france 4"), ("france5", "france 5"),
        ("canal plus sport360", "canal plus sport 360"), ("arte fr", "arte"),
    ]

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "un": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "sept": "7",
        "huit": "8", "neuf": "9", "dix": "10",
        "ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9",
    ]

    // MARK: lignes de séparation

    /// Les fournisseurs glissent des intertitres dans la liste des chaînes (« ✦●✦| CANAL+ FRANCE |✦●✦ »,
    /// « ##### SPORT ##### ») : ce ne sont pas des chaînes.
    public static func isDecorative(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let first = t.unicodeScalars.first else { return true }
        func decoration(_ sc: Unicode.Scalar) -> Bool {
            (sc.value > 0x7F && [.otherSymbol, .mathSymbol, .otherPunctuation, .dashPunctuation].contains(sc.properties.generalCategory))
                || "#=*~_".unicodeScalars.contains(sc)
        }
        if decoration(first), first.value > 0x7F { return true }
        // trois signes ASCII répétés en tête et en queue : « ##### SPORT ##### », « ===== CINÉMA ===== »
        let lead = t.unicodeScalars.prefix { decoration($0) }
        let trail = t.unicodeScalars.reversed().prefix { decoration($0) }
        return lead.count >= 3 && trail.count >= 3
    }

    /// Groupe « Account Information » (date d'expiration…) : des lignes d'information, pas des chaînes.
    public static func isAccountInfo(_ group: String) -> Bool {
        let g = group.uppercased()
        return (g.contains("ACCOUNT") || g.contains("ACCOUT")) && g.contains("INFO")
    }

    // MARK: analyse

    public static func parse(_ raw: String) -> Parsed {
        var text = decorate(raw)
        // préfixe pays et séparateurs : « FR| », « |FR| », « FR: », « [FR] », « FR - »
        let (country, rest) = IPTVCountry.stripPrefix(text)
        text = rest
        var found: Quality?
        var backup = false
        var kept: [String] = []
        // crochets et parenthèses : ôtés s'ils ne contiennent que des mentions techniques (« (backup) », « [HD] »),
        // gardés sinon (« Chaîne de test (secours) »)
        var cleaned = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if "([{".contains(ch), let close = text[i...].firstIndex(where: { ")]}".contains($0) }) {
                let inner = text[text.index(after: i)..<close]
                let words = inner.split(whereSeparator: { " -_.".contains($0) }).map { $0.uppercased() }
                if !words.isEmpty, words.allSatisfy({ qualityWords[$0] != nil || backupWords.contains($0) || technicalWords.contains($0) }) {
                    cleaned += " " + inner + " "          // les mots passent par le tri ci-dessous (qualité, secours)
                } else {
                    cleaned += text[i...close]
                }
                i = text.index(after: close)
                continue
            }
            cleaned.append(ch == "|" ? " " : ch)
            i = text.index(after: i)
        }
        for var w in cleaned.split(separator: " ").map(String.init) {
            w = w.trimmingCharacters(in: CharacterSet(charactersIn: "-_.:,;"))
            if w.isEmpty { continue }
            let u = w.uppercased()
            if let q = qualityWords[u] { found = max(found ?? q, q); continue }
            if backupWords.contains(u) { backup = true; continue }
            if technicalWords.contains(u) || u.allSatisfy({ !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "&" }) { continue }
            // qualité collée : « TF1HD », « M6FHD »
            if let (base, q) = gluedQuality(w) { found = max(found ?? q, q); kept.append(base); continue }
            kept.append(w)
        }
        // un nom fait seulement de mots techniques : on garde le brut
        if kept.isEmpty { kept = raw.split(separator: " ").map(String.init) }
        let k = key(kept.joined(separator: " "))
        let display = canonical[k] ?? prettyCase(kept.joined(separator: " "))
        return Parsed(display: display, key: k, quality: found ?? .unknown, backup: backup, country: country)
    }

    /// Clé de comparaison d'un nom (ou d'une recherche) : minuscules, sans accents, « + » = « plus », « & » = « et »,
    /// tirets et points en espaces, nombres écrits en chiffres, écritures connues ramenées à une seule.
    public static func key(_ s: String) -> String {
        var t = decorate(s).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        t = t.replacingOccurrences(of: "+", with: " plus ").replacingOccurrences(of: "&", with: " et ")
        var out = ""
        for ch in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch) } else { out.append(" ") }
        }
        var words = out.split(separator: " ").map(String.init)
        // chiffres et nombres écrits : « bein sports one » = « bein sports 1 » (pas en premier mot : « un »…)
        for i in words.indices where i > 0 { if let n = numberWords[words[i]] { words[i] = n } }
        // « tf 1 », « m 6 » → « tf1 », « m6 » (un ou deux lettres suivies d'un nombre)
        var joined: [String] = []
        for w in words {
            if let last = joined.last, last.count <= 2, last.allSatisfy(\.isLetter), w.allSatisfy(\.isNumber) {
                joined[joined.count - 1] = last + w
            } else { joined.append(w) }
        }
        var k = joined.joined(separator: " ")
        for (from, to) in keyAliases where (k == from || k.hasPrefix(from + " ")) && k != to && !k.hasPrefix(to + " ") {
            k = to + k.dropFirst(from.count)
            break
        }
        return k
    }

    /// Nom à chercher : la même clé, pour que « canal + sport » trouve « CANAL+SPORT ».
    public static func searchKey(_ query: String) -> String { key(query) }

    // MARK: détails

    /// Formes de compatibilité (exposants, petites capitales, pleine chasse) ramenées au texte simple, séparées du mot
    /// d'avant (« TF1ᴴᴰ » → « TF1 HD ») ; émojis et symboles décoratifs retirés.
    static func decorate(_ s: String) -> String {
        var out = ""
        var inSpecial = false
        for sc in s.unicodeScalars {
            let mapped = String(sc).precomposedStringWithCompatibilityMapping
            let special = mapped != String(sc) && !CharacterSet.letters.contains(sc) || sc.properties.generalCategory == .modifierLetter
            if sc.properties.isEmojiPresentation || (sc.properties.isEmoji && sc.value > 0x2000 && !special) {
                out.append(" "); inSpecial = false; continue
            }
            if sc.value > 0x7F, [.otherSymbol, .mathSymbol].contains(sc.properties.generalCategory) {
                out.append(" "); inSpecial = false; continue
            }
            if special {
                if !inSpecial { out.append(mapped == "+" ? "" : " ") }
                out.append(mapped)
                inSpecial = true
            } else {
                if inSpecial, CharacterSet.alphanumerics.contains(sc) { out.append(" ") }
                inSpecial = false
                out.unicodeScalars.append(sc)
            }
        }
        return out.replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    private static func gluedQuality(_ w: String) -> (String, Quality)? {
        let u = w.uppercased()
        for (suffix, q) in [("UHD", Quality.uhd), ("FHD", .fhd), ("4K", .uhd), ("HD", .hd)] where u.hasSuffix(suffix) {
            let base = String(w.dropLast(suffix.count))
            // seulement après un chiffre ou un + (« TF1HD », « CANAL+HD ») : « BBCHD » serait ambigu, « RHD » aussi
            if let c = base.last, c.isNumber || c == "+" { return (base, q) }
        }
        return nil
    }

    private static let acronyms: Set<String> = ["LCI", "LCP", "RAI", "ABC", "AMC", "ORF", "SRF", "RTE", "TVE", "TVI", "SIC", "RTP",
                                                "EWTN", "OCS", "AB1", "RTBF", "RTL", "RTS", "TV", "USA", "UK", "BBC", "ITV", "CNN",
                                                "HBO", "ESPN", "NBA", "NFL", "NHL", "UFC", "WWE", "DAZN", "AXN", "TNT", "TCM", "MCM"]

    /// « CANAL+ SPORT » → « Canal+ Sport » ; les sigles courts restent en capitales (TF1, BFM, M6).
    static func prettyCase(_ s: String) -> String {
        guard !s.contains(where: \.isLowercase) else { return s }
        return s.split(separator: " ").map { w -> String in
            let letters = w.filter(\.isLetter)
            let vowels = letters.filter { "AEIOUY".contains($0) }
            if w.contains(where: \.isNumber) || acronyms.contains(String(w)) || (letters.count <= 4 && vowels.isEmpty) {
                return String(w)
            }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/// Une adresse d'une chaîne : sa qualité annoncée, et si c'est un secours.
public struct ChannelVariant: Hashable, Sendable, Identifiable {
    public var id: String          // identifiant de l'entrée de la playlist
    public var url: String
    public var rawName: String
    public var quality: ChannelName.Quality
    public var backup: Bool
    public var label: String {
        backup ? "\(quality == .unknown ? "Secours" : quality.label + " · secours")" : quality.label
    }
}

/// Regroupe les entrées d'une playlist en chaînes : une chaîne = toutes ses variantes (4K, FHD, HD, SD, secours),
/// la meilleure d'abord. Le nom affiché est le nom propre ; l'identifiant (« ch:pays|clé ») ne dépend pas de la playlist.
public enum ChannelGrouping {
    public struct Result: Sendable {
        public var channels: [IPTVEntry]
        public var variants: [String: [ChannelVariant]]
        /// identifiant d'entrée de la playlist → identifiant de chaîne
        public var groupOf: [String: String]
    }

    public static func group(_ entries: [IPTVEntry]) -> Result {
        var order: [String] = []
        var members: [String: [(IPTVEntry, ChannelName.Parsed, Int)]] = [:]
        for (i, e) in entries.enumerated() where !ChannelName.isDecorative(e.name) && !ChannelName.isAccountInfo(e.group) {
            let p = ChannelName.parse(e.name)
            let country = e.country ?? p.country ?? ""
            let gid = "ch:\(country)|\(p.key.isEmpty ? e.id : p.key)"
            if members[gid] == nil { order.append(gid) }
            members[gid, default: []].append((e, p, i))
        }
        var channels: [IPTVEntry] = []
        var variants: [String: [ChannelVariant]] = [:]
        var groupOf: [String: String] = [:]
        channels.reserveCapacity(order.count)
        for gid in order {
            let m = members[gid]!.sorted { a, b in
                if a.1.backup != b.1.backup { return !a.1.backup }
                if a.1.quality != b.1.quality { return a.1.quality > b.1.quality }
                return a.2 < b.2
            }
            let best = m[0]
            var rep = best.0
            rep.id = gid
            rep.name = best.1.display
            rep.logo = m.lazy.compactMap(\.0.logo).first
            rep.number = m.compactMap(\.0.number).min()
            rep.tvgId = m.lazy.compactMap(\.0.tvgId).first
            if rep.country == nil, let c = m.lazy.compactMap({ $0.0.country ?? $0.1.country }).first { rep.country = c }
            channels.append(rep)
            variants[gid] = m.map { ChannelVariant(id: $0.0.id, url: $0.0.url, rawName: $0.0.name, quality: $0.1.quality, backup: $0.1.backup) }
            for x in m { groupOf[x.0.id] = gid }
        }
        return Result(channels: channels, variants: variants, groupOf: groupOf)
    }
}
