import Foundation

/// Surveille un flux en direct et décide quoi faire quand il se fige, s'arrête ou échoue : fonction pure,
/// appelée deux fois par seconde par le lecteur, testable sans réseau.
///
/// Réparation graduée, sans action de l'utilisateur : se recaler au bord du direct, puis rouvrir le flux, puis un
/// débit plus bas (HLS), puis une autre adresse de la même chaîne ; avec des délais croissants et une limite :
/// jamais de boucle infinie.
public struct LiveWatchdog: Equatable, Sendable {
    public struct Observation: Sendable {
        public var time: Double            // horloge (s)
        public var position: Double?       // time-pos du lecteur
        public var userPaused: Bool
        public var cacheSeconds: Double?   // demuxer-cache-duration
        public var ended: Bool             // fin de flux inattendue (un direct ne finit pas)
        public var failed: Bool            // erreur réseau / HTTP signalée par le lecteur
        public init(time: Double, position: Double?, userPaused: Bool = false, cacheSeconds: Double? = nil,
                    ended: Bool = false, failed: Bool = false) {
            self.time = time; self.position = position; self.userPaused = userPaused
            self.cacheSeconds = cacheSeconds; self.ended = ended; self.failed = failed
        }
    }

    public enum Action: Equatable, Sendable {
        case seekToLive
        case reload
        case lowerBitrate
        case alternateSource
        /// Abandon après trop d'essais : afficher « Chaîne indisponible » avec « Réessayer ».
        case giveUp
    }

    /// Tolérances : figé au-delà de `stallAfter` s sans progression ; démarrage toléré `startupGrace` s.
    public var stallAfter = 5.0
    public var startupGrace = 15.0
    public var maxAttempts = 10
    /// Délais avant chaque essai successif.
    public var backoff: [Double] = [0, 1, 2, 4, 8, 15, 30]
    public var hasLowerBitrate = false
    public var hasAlternate = false

    private(set) var startedAt: Double?
    private(set) var lastPosition: Double?
    private(set) var lastProgressAt: Double?
    private(set) var attempts = 0
    private(set) var nextAttemptAt: Double = 0
    private(set) var incidentAt: Double?
    /// Durée de la dernière panne réparée (s), pour le journal.
    public private(set) var lastRecovery: Double?
    public var isRecovering: Bool { incidentAt != nil }

    public init() {}

    /// Nouvelle ouverture du flux (au lancement ou après une réparation) : délai de démarrage à nouveau.
    public mutating func opened(at t: Double) {
        startedAt = t
        lastPosition = nil
        lastProgressAt = nil
    }

    public mutating func observe(_ o: Observation) -> Action? {
        if startedAt == nil { startedAt = o.time }
        // la lecture avance : tout va bien, et une panne en cours est réparée
        if let p = o.position, let last = lastPosition, p > last + 0.05 {
            lastProgressAt = o.time
            lastPosition = p
            if let since = incidentAt {
                lastRecovery = o.time - since
                incidentAt = nil
                attempts = 0
            }
            return nil
        }
        if lastPosition == nil, let p = o.position { lastPosition = p; lastProgressAt = o.time }
        if o.userPaused { lastProgressAt = o.time; return nil }   // pause voulue : rien à réparer

        let broken: Bool
        if o.failed || o.ended {
            broken = true
        } else if let since = lastProgressAt {
            broken = o.time - since > stallAfter
        } else {
            broken = o.time - (startedAt ?? o.time) > startupGrace   // n'a jamais démarré
        }
        guard broken else { return nil }
        if incidentAt == nil { incidentAt = o.time; nextAttemptAt = o.time }
        guard o.time >= nextAttemptAt else { return nil }
        guard attempts < maxAttempts else { return .giveUp }

        let step = attempts
        attempts += 1
        nextAttemptAt = o.time + backoff[min(step + 1, backoff.count - 1)]
        // l'échelle : recaler au bord du direct (seulement pour un figeage avec des données en réserve),
        // rouvrir, débit plus bas, autre adresse, puis rouvrir encore en espaçant les essais
        switch step {
        case 0 where !o.failed && !o.ended && (o.cacheSeconds ?? 0) > 1: return .seekToLive
        case 0, 1: return .reload
        case 2 where hasLowerBitrate: return .lowerBitrate
        case 2, 3: return hasAlternate ? .alternateSource : .reload
        default: return .reload
        }
    }

    /// « Réessayer » après un abandon.
    public mutating func reset() {
        attempts = 0
        incidentAt = nil
        nextAttemptAt = 0
        startedAt = nil
        lastPosition = nil
        lastProgressAt = nil
    }
}

/// Options mpv / ffmpeg adaptées au direct : reconnexion automatique, cache court, démarrage rapide.
public enum LiveOptions {
    public static func mpv(userAgent: String?, referer: String?) -> [(String, String)] {
        var lavf = ["reconnect=1", "reconnect_streamed=1", "reconnect_on_network_error=1",
                    "reconnect_on_http_error=4xx,5xx", "reconnect_delay_max=4", "rw_timeout=10000000"]
        if let referer, !referer.isEmpty { lavf.append("referer=\(referer)") }
        var out: [(String, String)] = [
            ("stream-lavf-o", lavf.joined(separator: ",")),
            ("cache", "yes"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-readahead-secs", "8"),
            ("cache-pause-initial", "no"),
            ("cache-pause-wait", "1"),
            ("hls-bitrate", "max"),
            ("network-timeout", "10"),
        ]
        if let userAgent, !userAgent.isEmpty { out.append(("user-agent", userAgent)) }
        if let referer, !referer.isEmpty { out.append(("referrer", referer)) }
        return out
    }
}
