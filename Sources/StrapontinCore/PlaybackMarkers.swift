import Foundation

// Intro, récap, générique de fin : ce que disent les chapitres et l'empreinte audio. Logique pure, testée.

/// Un passage de la vidéo, en secondes.
public struct MediaSpan: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { end - start }
}

public struct Chapter: Hashable, Sendable {
    public var title: String
    public var start: Double
    public init(title: String, start: Double) { self.title = title; self.start = start }
}

public enum MarkerSource: String, Sendable {
    case namedChapter, lastChapter, audio
}

public struct Marker: Hashable, Sendable {
    public var span: MediaSpan
    public var source: MarkerSource
    public init(span: MediaSpan, source: MarkerSource) { self.span = span; self.source = source }
}

/// Ce que l'analyse audio a trouvé dans un épisode.
public struct DetectedMarkers: Codable, Hashable, Sendable {
    public var intro: MediaSpan?
    public var credits: MediaSpan?
    public init(intro: MediaSpan? = nil, credits: MediaSpan? = nil) { self.intro = intro; self.credits = credits }
}

enum ChapterRole {
    case intro, recap, credits
    /// « Générique », « Credits » : début ou fin selon la place du chapitre.
    case theme
    /// Après le générique (épilogue, scène bonus) : ni l'un ni l'autre.
    case story
}

enum ChapterTitle {
    static func role(_ raw: String) -> ChapterRole? {
        // sans accents latins ; les autres écritures telles quelles (« オープニング » perdrait ses marques)
        let latin = raw.unicodeScalars.allSatisfy { $0.value < 0x0370 }
        var t = latin ? raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")) : raw.lowercased()
        t = t.replacingOccurrences(of: #"[\s._:\-–—'’]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }

        if has(#"post ?(credit|generique)|after (the )?credits|apres (le )?generique|\bepilog(ue|o)?\b"#) { return .story }
        if has(#"\b(recap|recapitulatif|previously|precedemment|episodes? precedents?|resume (de l|des|du|precedent)|last time on|was bisher geschah|ruckblick|rueckblick|riassunto|resumen|anteriormente|nelle puntate precedenti)\b|^resume$|前回|あらすじ"#) { return .recap }
        if has(#"generique (de |du )?(debut|ouverture)|generique d ouverture|\b(opening|main titles?|title sequence|theme song|vorspann|abertura|apertura|cabecera|sigla iniziale|creditos iniciales)\b|^(nc ?)?op ?\d*$|オープニング|片头"#) { return .intro }
        if has(#"generique (de )?fin|\b(end(ing)? (credits?|titles?|theme)|closing (credits?|titles?)|ending|outro|abspann|nachspann|creditos finales|encerramento|titoli di coda|sigla finale)\b|^(nc ?)?ed ?\d*$|エンディング|片尾"#) { return .credits }
        if has(#"^intro( ?\d+)?$|^introduction$|^intro (start|sequence|credits)$"#) { return .intro }
        if has(#"\bgeneriques?\b|^credits?( ?\d+)?$|^creditos?$|^sigla$"#) { return .theme }
        return nil
    }
}

/// Les repères d'un épisode : chapitres d'abord, puis l'empreinte audio.
public struct PlaybackMarkers: Equatable, Sendable {
    public var intro: Marker?
    public var recap: Marker?
    public var credits: Marker?

    public init() {}

    public init(chapters raw: [Chapter], detected: DetectedMarkers?, duration d: Double) {
        guard d > 0 else { return }
        let chapters = raw.filter { $0.start >= 0 && $0.start < d }.sorted { $0.start < $1.start }
        let spans = chapters.indices.map {
            MediaSpan(start: chapters[$0].start, end: $0 + 1 < chapters.count ? chapters[$0 + 1].start : d)
        }
        let roles = chapters.map { ChapterTitle.role($0.title) }

        for (i, span) in spans.enumerated() {
            let early = span.start < d * 0.4
            let short = span.length >= 3 && span.length <= 300
            switch roles[i] {
            case .recap where early && short && recap == nil:
                recap = Marker(span: span, source: .namedChapter)
            case .intro where early && short && intro == nil:
                intro = Marker(span: span, source: .namedChapter)
            case .theme where span.start < d * 0.35 && short && intro == nil:
                intro = Marker(span: span, source: .namedChapter)
            case .credits where span.start >= d * 0.5:
                if credits == nil { credits = Marker(span: span, source: .namedChapter) }
            case .theme where span.start >= d * 0.65:
                if credits == nil { credits = Marker(span: span, source: .namedChapter) }
            default: break
            }
        }

        if credits == nil, let last = spans.last, let role = roles.last,
           Self.lastChapterIsCredits(last, role: role, starts: chapters.map(\.start), duration: d) {
            credits = Marker(span: last, source: .lastChapter)
        }
        if intro == nil, let s = detected?.intro, s.end < d { intro = Marker(span: s, source: .audio) }
        if credits == nil, let s = detected?.credits, s.start < d {
            credits = Marker(span: MediaSpan(start: s.start, end: min(d, s.end)), source: .audio)
        }
    }

    /// Dernier chapitre = générique s'il commence dans les 15 derniers % et dure moins de 5 min.
    static func lastChapterIsCredits(_ last: MediaSpan, role: ChapterRole?, starts: [Double], duration d: Double) -> Bool {
        guard role == nil, starts.count >= 2, last.start >= d * 0.85, last.length >= 5, last.length < 300 else { return false }
        // chapitres posés toutes les N minutes par l'outil d'encodage : le dernier ne veut rien dire
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        if gaps.count >= 2, let lo = gaps.min(), let hi = gaps.max(), hi - lo < 1.5, last.length <= hi + 1.5 { return false }
        return true
    }

    /// Le bouton à montrer à cette position.
    public func skip(at t: Double) -> SkipOffer? {
        func inside(_ m: Marker?) -> MediaSpan? {
            guard let s = m?.span, t >= s.start, t < s.end - 1 else { return nil }
            return s
        }
        // détection audio : un cheveu avant la fin mesurée, pour ne jamais manger le début de la scène
        func target(_ m: Marker?, _ s: MediaSpan) -> Double { m?.source == .audio ? max(s.start, s.end - 0.3) : s.end }
        if let s = inside(recap) { return SkipOffer(kind: .recap, target: target(recap, s)) }
        if let s = inside(intro) { return SkipOffer(kind: .intro, target: target(intro, s)) }
        return nil
    }

    /// Vu : à partir du générique s'il est connu, sinon à 92 %.
    public static func isWatched(position: Double, duration: Double, creditsStart: Double?) -> Bool {
        guard duration > 0 else { return false }
        if let c = creditsStart { return position >= c }
        return position / duration > 0.92
    }
}

public struct SkipOffer: Equatable, Sendable {
    public enum Kind: Sendable { case intro, recap }
    public var kind: Kind
    public var target: Double
}

/// La carte « Épisode suivant » : quand elle paraît, son compte à rebours, quoi faire à la fin.
/// Le compte suit la position de lecture : en pause il s'arrête.
public struct EndCard: Equatable, Sendable {
    public enum Next: Equatable, Sendable {
        case ready
        /// Pas dans la bibliothèque : on propose, on n'enchaîne jamais.
        case notOwned
        case none
    }
    public enum AtEnd: Equatable, Sendable {
        case playNext, stay, close
    }

    public static let countdown = 10.0
    public static let fallbackWindow = 30.0

    public private(set) var visible = false
    public private(set) var secondsLeft: Int?
    /// 0…1 du compte à rebours.
    public private(set) var fraction: Double?
    public private(set) var dismissed = false
    /// Une scène suit le générique : proposer de le passer plutôt que d'enchaîner.
    public private(set) var sceneAfter: Double?
    /// Pendant la scène qui suit le générique : la carte se replie.
    public private(set) var compact = false

    private var anchor: Double?
    private var last: Double?
    private var lastNext: Next?
    public private(set) var ended = false

    public init() {}

    public static func start(duration: Double, credits: MediaSpan?) -> Double {
        credits?.start ?? duration - min(fallbackWindow, duration / 4)
    }

    /// Ce qu'on sait coupable sans rien perdre : un générique nommé ou entendu qui va jusqu'à la fin du fichier
    /// (à 2 s près). Un dernier chapitre « plausible » ne suffit pas.
    public static func endsWithCredits(_ credits: Marker?, duration d: Double) -> Bool {
        guard let c = credits, c.source != .lastChapter else { return false }
        return d - c.span.end <= 2
    }

    /// À chaque avancée de la lecture. true : c'est le moment d'enchaîner.
    /// - certain : ce qui reste après le début du générique n'est que du générique (voir `endsWithCredits`).
    ///   Sinon le compte va jusqu'à la vraie fin du fichier : rien n'est coupé.
    public mutating func update(position t: Double, duration d: Double, credits: MediaSpan?, certain: Bool = true,
                                next: Next, autoplay: Bool) -> Bool {
        guard d > 0 else { return false }
        defer { last = t }
        let start = Self.start(duration: d, credits: credits)
        // arrivé entre-temps (téléchargement fini) : le compte part de maintenant, jamais d'un enchaînement immédiat
        if lastNext != next { if anchor != nil { anchor = t }; lastNext = next }
        guard t >= start || ended else {
            dismissed = false
            anchor = nil
            show(nil)
            visible = false
            sceneAfter = nil
            compact = false
            return false
        }
        // arrivée dans le générique ou saut dedans : le compte repart
        if anchor == nil { anchor = t } else if let last, abs(t - last) > 2 { anchor = t }
        // quelque chose suit le générique (scène, bonus) : on ne le coupe pas, la carte se fait discrète pendant
        let scene = credits.flatMap { d - $0.end > 2 ? $0.end : nil }
        sceneAfter = scene.flatMap { t < $0 - 1 ? $0 : nil }
        compact = scene.map { t >= $0 - 0.5 } ?? false
        let cut = certain && scene == nil && credits != nil

        visible = next != .none && (!dismissed || (ended && next == .ready))
        guard visible, next == .ready, autoplay, !dismissed, !ended, let anchor else {
            show(nil)
            return false
        }
        if cut {
            let end = min(anchor + Self.countdown, d)
            show((end - t, end - anchor))
            return end < d - 0.5 && t >= end
        }
        // pas sûr de ce qui reste : on compte jusqu'à la vraie fin, et on ne l'affiche qu'à 30 s
        show(d - t <= Self.fallbackWindow ? (d - t, min(Self.fallbackWindow, d - start)) : nil)
        return false
    }

    private mutating func show(_ v: (left: Double, total: Double)?) {
        secondsLeft = v.map { max(0, Int($0.left.rounded(.up))) }
        fraction = v.map { $0.total > 0 ? min(1, max(0, 1 - $0.left / $0.total)) : 1 }
    }

    /// Revenu en arrière depuis la fin. (Pas déduit de la position : mpv recule un peu en s'arrêtant sur la dernière image.)
    public mutating func leftEnd() { ended = false }

    /// « Regarder le générique ».
    public mutating func dismiss() {
        dismissed = true
        visible = false
        show(nil)
    }

    public mutating func reachedEnd(next: Next, autoplay: Bool) -> AtEnd {
        show(nil)
        switch next {
        case .none:
            visible = false
            return .close
        case .notOwned:
            guard !dismissed else { visible = false; return .close }
        case .ready:
            if autoplay && !dismissed { return .playNext }
        }
        ended = true
        visible = true
        sceneAfter = nil
        compact = false
        return .stay
    }
}
