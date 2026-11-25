import Foundation

/// Pays d'une chaîne ou d'un titre IPTV, déduit de ce que les fournisseurs écrivent : `tvg-country`, préfixes du groupe ou
/// du nom (`FR|`, `|FR|`, `FR:`, `[FR]`, `FRANCE`, `🇫🇷`), et en dernier recours le suffixe du tvg-id (`tf1.fr`).
///
/// Code renvoyé : ISO 3166 (`FR`, `GB`…) ou une région quand les fournisseurs regroupent ainsi (`ARAB`, `EXYU`, `LATAM`,
/// `AFR`, `MAGHREB`).
public enum IPTVCountry {
    public static let regions: [String: (label: String, flag: String)] = [
        "ARAB": ("Arabe", "🌍"), "EXYU": ("Ex-Yougoslavie", "🌍"), "LATAM": ("Amérique latine", "🌎"),
        "AFR": ("Afrique", "🌍"), "MAGHREB": ("Maghreb", "🌍"),
    ]

    /// Mots qui ressemblent à un code pays mais n'en sont pas dans une playlist (TV = Tuvalu, HD…).
    private static let notCountries: Set<String> = ["TV", "HD", "SD", "FM", "VIP", "UHD", "FHD", "4K", "EN", "VO", "VF", "OK", "NO SIGNAL"]

    private static let aliases: [String: String] = [
        "USA": "US", "UK": "GB", "ENGLAND": "GB", "GER": "DE", "DEU": "DE", "ITA": "IT", "ESP": "ES",
        "POR": "PT", "PRT": "PT", "NED": "NL", "HOL": "NL", "HOLLAND": "NL", "BEL": "BE", "SUI": "CH", "SWISS": "CH",
        "AUT": "AT", "POL": "PL", "TUR": "TR", "GRE": "GR", "ALB": "AL", "RUS": "RU", "UKR": "UA", "SWE": "SE",
        "NOR": "NO", "DEN": "DK", "FIN": "FI", "IND": "IN", "PAK": "PK", "CAN": "CA", "MEX": "MX", "BRA": "BR",
        "ARG": "AR", "QC": "CA", "QUEBEC": "CA", "FRA": "FR", "ROU": "RO", "ROM": "RO", "BUL": "BG", "HUN": "HU",
        "CZE": "CZ", "SVK": "SK", "CRO": "HR", "SRB": "RS", "BIH": "BA", "SLO": "SI", "MKD": "MK", "IRL": "IE",
        "ISR": "IL", "IRN": "IR", "KOR": "KR", "JPN": "JP", "CHN": "CN", "AUS": "AU", "NZL": "NZ", "ZAF": "ZA",
        "MAR": "MA", "ALG": "DZ", "DZA": "DZ", "TUN": "TN", "EGY": "EG", "KSA": "SA", "UAE": "AE",
        "VIET": "VN", "PHI": "PH", "THA": "TH", "CARIB": "LATAM",
        "AR": "ARAB", "ARA": "ARAB", "ARB": "ARAB", "ARAB": "ARAB", "ARABIC": "ARAB", "ARABE": "ARAB",
        "EXYU": "EXYU", "EX-YU": "EXYU", "EX YU": "EXYU", "YU": "EXYU", "BALKAN": "EXYU",
        "LATINO": "LATAM", "LATAM": "LATAM", "LAT": "LATAM", "LATIN": "LATAM",
        "ITALIA": "IT", "DEUTSCHLAND": "DE", "ESPANA": "ES", "NEDERLAND": "NL", "BELGIE": "BE", "SCHWEIZ": "CH",
        "OSTERREICH": "AT", "POLSKA": "PL", "TURKIYE": "TR", "ELLADA": "GR", "SVERIGE": "SE", "NORGE": "NO",
        "DANMARK": "DK", "SUOMI": "FI", "HRVATSKA": "HR", "SRBIJA": "RS", "MAGYARORSZAG": "HU", "CESKO": "CZ",
        "BRASIL": "BR", "SHQIPERIA": "AL",
        "AFR": "AFR", "AFRICA": "AFR", "AFRIQUE": "AFR", "MAGHREB": "MAGHREB",
    ]

    private static let iso: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter {
        $0.count == 2 && $0.allSatisfy(\.isLetter)
    })

    /// Noms de pays (anglais et français, sans accents, en majuscules) → code.
    private static let names: [String: String] = {
        var out: [String: String] = [:]
        for code in iso {
            for loc in ["en", "fr"] {
                if let n = Locale(identifier: loc).localizedString(forRegionCode: code) { out[fold(n)] = code }
            }
        }
        return out
    }()

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Abréviations assez sûres pour valoir même en premier mot d'un titre (« USA Network », « GER Sport »).
    private static let safeFirstWords: Set<String> = ["USA", "GER", "ITA", "ESP", "FRA", "TUR", "KSA", "UAE", "EXYU", "NED"]

    /// Un morceau isolé (entre séparateurs) qui désigne un pays ? Sinon (`alone` faux) un premier mot : noms complets
    /// et abréviations sûres seulement.
    private static func code(token raw: String, alone: Bool) -> String? {
        let t = fold(raw)
        guard !t.isEmpty, !notCountries.contains(t) else { return nil }
        if let a = aliases[t], alone || t.count >= 5 || safeFirstWords.contains(t) { return a }
        if t.count == 2, iso.contains(t), alone { return t }
        if t.count >= 4, let c = names[t] { return c }
        return nil
    }

    private static func flagCode(_ s: String) -> String? {
        let scalars = Array(s.unicodeScalars)
        for i in scalars.indices.dropLast() {
            let a = scalars[i].value, b = scalars[i + 1].value
            if (0x1F1E6...0x1F1FF).contains(a), (0x1F1E6...0x1F1FF).contains(b) {
                let code = String(UnicodeScalar(a - 0x1F1E6 + 65)!) + String(UnicodeScalar(b - 0x1F1E6 + 65)!)
                return code == "UK" ? "GB" : code
            }
        }
        return nil
    }

    private static let strong = CharacterSet(charactersIn: "|:[](){}/▎┃│•★✦*#»«")

    /// Dans un groupe ou un nom : drapeau, morceau entre séparateurs, ou premier mot si c'est un nom de pays.
    /// Mots de rangement que les fournisseurs mettent avant le pays (« VOD FR | Action », « VIP UK: Sport »).
    private static let noise: Set<String> = ["VOD", "VIP", "4K", "HD", "FHD", "UHD", "SD", "LIVE", "PPV", "TV", "24/7", "MOVIES",
                                             "FILMS", "SERIES", "SERIE"]

    private static func dropNoise(_ s: String) -> String {
        var words = s.split(separator: " ", omittingEmptySubsequences: true)
        while let w = words.first, noise.contains(fold(String(w))), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func fromText(_ rawText: String) -> String? {
        if let f = flagCode(rawText) { return f }
        let text = dropNoise(rawText.trimmingCharacters(in: .whitespaces))
        // « FR - Sport » : le tiret entouré d'espaces sépare aussi
        let normalized = text.replacingOccurrences(of: " - ", with: "|").replacingOccurrences(of: " – ", with: "|")
        let parts = normalized.components(separatedBy: strong).map { dropNoise($0.trimmingCharacters(in: .whitespaces)) }
        let hasSeparator = parts.count > 1
        for p in parts where !p.isEmpty {
            if let c = code(token: p, alone: hasSeparator) { return c }
            // « VIP | FRANCE SPORT » : premier mot du morceau
            if hasSeparator, let w = p.split(separator: " ").first, w.count >= 3, let c = code(token: String(w), alone: false) { return c }
        }
        // « FR-Sport », « FRANCE 2 » : premier mot
        let first = normalized.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).first.map(String.init) ?? ""
        let firstFolded = fold(first)
        if firstFolded.count >= 3, let c = code(token: first, alone: false) { return c }
        // « FR-Sport » : deux lettres collées à un tiret ou un point
        if firstFolded.count == 2, let i = normalized.firstIndex(where: { $0 == "-" || $0 == "_" || $0 == "." }),
           fold(String(normalized[..<i])) == firstFolded, iso.contains(firstFolded) || aliases[firstFolded] != nil {
            return code(token: first, alone: true)
        }
        return nil
    }

    /// Retire le pays écrit devant un nom de chaîne avec un séparateur (« FR| », « |FR| », « FR: », « [FR] », « FR - »,
    /// « VIP | UK | ») : (pays, reste). Sans séparateur on ne touche à rien : « France 2 » reste « France 2 ».
    public static func stripPrefix(_ text: String) -> (String?, String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var found: String?
        let separators: [Character] = ["|", ":", "]", ")", "▎", "┃", "│", "»", "-", "–"]
        for _ in 0..<3 {
            rest = rest.drop(while: { $0 == " " || "|[(▎┃│«".contains($0) })
            // jusqu'au premier séparateur, s'il vient tôt
            guard let i = rest.prefix(16).firstIndex(where: { separators.contains($0) }) else { break }
            let token = rest[..<i].trimmingCharacters(in: .whitespaces)
            // un tiret ne sépare que s'il est entouré d'espaces (« FR - TF1 », pas « Canal+ Sport-Live »)
            if rest[i] == "-" || rest[i] == "–" {
                let before = i > rest.startIndex ? rest[rest.index(before: i)] : " "
                if before != " " { break }
            }
            let t = fold(token)
            if let c = code(token: token, alone: true) { found = found ?? c }
            else if !noise.contains(t) { break }
            rest = rest[rest.index(after: i)...]
        }
        let out = rest.drop(while: { $0 == " " || "|]):-–▎┃│»".contains($0) })
        return (found, out.isEmpty ? text : String(out))
    }

    public static func detect(tvgCountry: String? = nil, group: String, name: String, tvgId: String? = nil) -> String? {
        if let tc = tvgCountry?.split(whereSeparator: { ",;| ".contains($0) }).first,
           let c = code(token: String(tc), alone: true) { return c }
        if let c = fromText(group) ?? fromText(name) { return c }
        if let id = tvgId, let dot = id.lastIndex(of: ".") {
            let suffix = fold(String(id[id.index(after: dot)...]))
            if suffix.count == 2, iso.contains(suffix), !notCountries.contains(suffix) { return suffix == "UK" ? "GB" : suffix }
            if suffix == "UK" { return "GB" }
        }
        return nil
    }

    public static func label(_ code: String) -> String {
        regions[code]?.label ?? Locale(identifier: "fr_FR").localizedString(forRegionCode: code) ?? code
    }

    public static func flag(_ code: String) -> String {
        if let r = regions[code] { return r.flag }
        guard code.count == 2 else { return "🏳️" }
        return code.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 65) }.map(String.init).joined()
    }
}
