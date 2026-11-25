import Foundation

/// Rapprochement des films et séries IPTV avec TMDb, pour qu'un titre n'ait qu'une fiche quelle que soit la source.
///
/// Prudent : mieux vaut un titre non reconnu (rangé dans « Autres titres IPTV ») qu'une mauvaise fiche.
public enum VODMatch {
    /// Titre normalisé pour comparer : sans pays ni qualité (VODTitle.clean), minuscules, sans accents ni ponctuation,
    /// « & » = « et », chiffres romains II–IX en chiffres, article de tête ignoré.
    public static func normalize(_ title: String) -> String {
        var t = CatalogFold.fold(VODTitle.clean(title).replacingOccurrences(of: "&", with: " et "))
        let roman = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]
        var words = t.split(separator: " ").map { roman[String($0)] ?? String($0) }
        if words.count > 1, ["the", "le", "la", "les", "l"].contains(words[0]) { words.removeFirst() }
        t = words.joined(separator: " ")
        return t
    }

    /// Clé d'un titre IPTV : même film en VF, MULTI, 4K… → même clé.
    public static func key(kind: IPTVKind, title: String, year: Int?) -> String {
        "\(kind == .series ? "tv" : "movie")|\(normalize(title))|\(year.map(String.init) ?? "")"
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
