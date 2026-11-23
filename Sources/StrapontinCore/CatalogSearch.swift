import Foundation

/// Recherche dans le catalogue et la bibliothèque (barre d'outils et Découvrir).
public enum CatalogSearch {
    /// Sans accents ni majuscules : « shogun » trouve « Shōgun », « amelie » trouve « Amélie ».
    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Les titres qui correspondent exactement d'abord, puis ceux qui commencent par la recherche ; sinon l'ordre de TMDb
    /// (qui renvoie les films avant les séries : la série « Shōgun » finissait derrière « Shogun Cop »).
    public static func rank(_ results: [TMDbSearchResult], _ query: String) -> [TMDbSearchResult] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        func score(_ r: TMDbSearchResult) -> Int {
            let t = fold(r.title)
            return t == q ? 0 : t.hasPrefix(q) ? 1 : 2
        }
        return results.enumerated().sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }.map(\.element)
    }
}
