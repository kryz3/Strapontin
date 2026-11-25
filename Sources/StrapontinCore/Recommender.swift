import Foundation

/// Un titre proposé par TMDb (recommandations, découverte, populaires), avec de quoi le classer.
public struct TMDbPick: Identifiable, Hashable, Sendable {
    public var id: String { Media.key(kind, tmdbId) }
    public var tmdbId: Int
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    public var overview: String
    public var posterPath: String?
    public var backdropPath: String?
    public var genreIds: [Int]
    public var vote: Double
    public var voteCount: Int
    public var popularity: Double
    /// « Parce que tu as aimé … » : le titre qui l'a amené (nil pour la découverte).
    public var because: String?

    public init(tmdbId: Int, kind: MediaKind, title: String, year: Int?, overview: String, posterPath: String?,
                backdropPath: String?, genreIds: [Int], vote: Double, voteCount: Int, popularity: Double, because: String? = nil) {
        self.tmdbId = tmdbId; self.kind = kind; self.title = title; self.year = year; self.overview = overview
        self.posterPath = posterPath; self.backdropPath = backdropPath; self.genreIds = genreIds
        self.vote = vote; self.voteCount = voteCount; self.popularity = popularity; self.because = because
    }
}

/// Réaction à une carte de « Pour toi ».
public enum FeedReaction: String, Codable, Sendable { case like, dislike, seen }

/// Ce qu'on sait des goûts, tout calculé sur ce Mac.
public struct TasteProfile: Equatable, Sendable {
    /// Poids par genre TMDb (positif : aimé, négatif : rejeté).
    public var genres: [Int: Double] = [:]
    /// Poids par décennie (1990, 2000…).
    public var decades: [Int: Double] = [:]
    /// Part des séries dans ce qui est regardé (0 = que des films, 1 = que des séries).
    public var seriesShare: Double = 0.5
    public init() {}

    /// Un signal : un titre de la bibliothèque, vu, en cours, aimé, suivi ou rejeté, avec son poids.
    public struct Signal: Sendable {
        public var kind: MediaKind
        public var genreIds: [Int]
        public var year: Int?
        public var weight: Double
        public init(kind: MediaKind, genreIds: [Int], year: Int?, weight: Double) {
            self.kind = kind; self.genreIds = genreIds; self.year = year; self.weight = weight
        }
    }

    /// Poids conseillés : présent dans la bibliothèque 1, en cours 1,5, vu en entier 2, suivi 2, aimé 3, rejeté −3.
    public static func build(_ signals: [Signal]) -> TasteProfile {
        var p = TasteProfile()
        var series = 0.0, total = 0.0
        for s in signals {
            for g in s.genreIds { p.genres[g, default: 0] += s.weight / Double(max(1, s.genreIds.count)).squareRoot() }
            if let y = s.year, s.weight > 0 { p.decades[y / 10 * 10, default: 0] += s.weight }
            if s.weight > 0 {
                total += s.weight
                if s.kind == .tv { series += s.weight }
            }
        }
        if total > 0 { p.seriesShare = series / total }
        return p
    }

    var maxGenre: Double { genres.values.map(abs).max() ?? 0 }
}

/// Classement du fil « Pour toi » : fonction pure, testable.
public enum Recommender {
    /// - candidates : propositions (la même fiche peut venir de plusieurs titres aimés : c'est un bon signe).
    /// - exclude : déjà dans la bibliothèque, déjà vu, déjà refusé, déjà montré.
    /// - discovery : part de cartes « découverte » (hors des genres habituels), 1 sur 6 par défaut.
    public static func rank(_ candidates: [TMDbPick], profile: TasteProfile, exclude: Set<String>,
                            discovery every: Int = 6) -> [TMDbPick] {
        // regroupe les doublons : combien de titres aimés mènent à celui-ci
        var byKey: [String: (pick: TMDbPick, sources: Int)] = [:]
        for c in candidates where !exclude.contains(c.id) {
            if let e = byKey[c.id] {
                var p = e.pick
                if p.because == nil { p.because = c.because }
                byKey[c.id] = (p, e.sources + (c.because == nil ? 0 : 1))
            } else {
                byKey[c.id] = (c, c.because == nil ? 0 : 1)
            }
        }
        let maxG = max(1, profile.maxGenre)
        func affinity(_ p: TMDbPick) -> Double {
            guard !p.genreIds.isEmpty else { return 0 }
            return p.genreIds.map { (profile.genres[$0] ?? 0) / maxG }.reduce(0, +) / Double(p.genreIds.count).squareRoot()
        }
        func score(_ e: (pick: TMDbPick, sources: Int)) -> Double {
            let p = e.pick
            var s = 0.0
            s += 2.2 * log(1 + Double(e.sources))                      // recommandé par plusieurs titres aimés
            s += 2.0 * affinity(p)                                     // genres qui plaisent (ou non)
            s += 0.35 * max(0, p.vote - 5)                             // note TMDb, si elle est fiable
                * min(1, Double(p.voteCount) / 300)
            s += 0.15 * log(1 + p.popularity)
            if let y = p.year, let maxD = profile.decades.values.max(), maxD > 0 {
                s += 0.4 * (profile.decades[y / 10 * 10] ?? 0) / maxD  // époque préférée
            }
            s += 0.5 * (p.kind == .tv ? profile.seriesShare : 1 - profile.seriesShare)
            return s
        }
        let scored = byKey.values.map { ($0.pick, score($0), affinity($0.pick)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }

        // diversité : on évite d'enchaîner le même genre principal ; une carte « découverte » de temps en temps
        var pool = scored
        var out: [TMDbPick] = []
        var recent: [Int] = []
        while !pool.isEmpty {
            let wantDiscovery = every > 0 && (out.count + 1) % every == 0
            var idx = 0
            if wantDiscovery, let d = pool.firstIndex(where: { $0.2 <= 0.15 }) {
                idx = d
            } else if let d = pool.firstIndex(where: { e in
                // pas un troisième du même genre principal d'affilée
                guard let g = e.0.genreIds.first else { return true }
                let last = recent.suffix(2)
                return !(last.count == 2 && last.allSatisfy { $0 == g })
            }) {
                idx = d
            }
            let next = pool.remove(at: idx)
            out.append(next.0)
            if let g = next.0.genreIds.first { recent.append(g) }
        }
        return out
    }
}
