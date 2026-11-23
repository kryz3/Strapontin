import CryptoKit
import Foundation

/// Ce dont Strapontin a besoin d'un client BitTorrent. Deux implémentations :
/// `TransmissionClient` (moteur intégré, par défaut) et `QbitClient` (qBittorrent déjà installé).
public protocol TorrentClient: Sendable {
    func version() async throws -> String
    func torrents() async throws -> [Torrent]
    func add(_ payload: TorrentPayload, savePath: String?, paused: Bool) async throws
    func pause(_ hashes: [String]) async throws
    func resume(_ hashes: [String]) async throws
    func delete(_ hashes: [String], deleteFiles: Bool) async throws
}

extension TorrentClient {
    public func add(_ payload: TorrentPayload, savePath: String?) async throws {
        try await add(payload, savePath: savePath, paused: false)
    }

    /// Glisser-déposer : un .torrent sur le disque ou un lien magnet.
    public func add(torrentAt url: URL, savePath: String?) async throws {
        try await add(.file(try Data(contentsOf: url), name: url.lastPathComponent), savePath: savePath)
    }

    public func add(magnets: [String], savePath: String?) async throws {
        for m in magnets { try await add(.magnet(m), savePath: savePath) }
    }

    public func knownHashes() async throws -> Set<String> {
        Set(try await torrents().map { $0.hash.lowercased() })
    }
}

extension TorrentPayload {
    /// Empreinte du torrent (SHA-1 du dictionnaire « info »), en hexadécimal minuscule : c'est l'identifiant
    /// que les moteurs affichent. Sert à retrouver la progression d'un envoi même quand l'indexeur ne la donne pas.
    public var infoHash: String? {
        switch self {
        case .file(let data, _): return Self.infoHash(torrent: data)
        case .magnet(let m): return Self.infoHash(magnet: m)
        }
    }

    static func infoHash(torrent data: Data) -> String? {
        let b = [UInt8](data)
        guard b.first == UInt8(ascii: "d") else { return nil }
        var i = 1
        while i < b.count, b[i] != UInt8(ascii: "e") {
            guard let key = Bencode.string(b, &i) else { return nil }
            let start = i
            guard Bencode.skip(b, &i) else { return nil }
            if key == Array("info".utf8) {
                return Insecure.SHA1.hash(data: Data(b[start..<i])).map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }

    static func infoHash(magnet: String) -> String? {
        guard let r = magnet.range(of: "urn:btih:", options: .caseInsensitive) else { return nil }
        let v = magnet[r.upperBound...].prefix { $0.isLetter || $0.isNumber }
        if v.count == 40 { return v.lowercased() }
        guard v.count == 32 else { return nil }
        // forme base32 (32 caractères) → hexadécimal
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0, out = ""
        for c in v.uppercased() {
            guard let n = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | n
            bits += 5
            if bits >= 8 { bits -= 8; out += String(format: "%02x", (value >> bits) & 0xff) }
        }
        return out
    }
}

/// Lecture minimale du format bencode des .torrent (juste de quoi trouver le dictionnaire « info »).
enum Bencode {
    static func string(_ b: [UInt8], _ i: inout Int) -> [UInt8]? {
        var len = 0
        while i < b.count, b[i] >= 48, b[i] <= 57 { len = len * 10 + Int(b[i] - 48); i += 1 }
        guard i < b.count, b[i] == UInt8(ascii: ":"), i + 1 + len <= b.count else { return nil }
        let s = Array(b[(i + 1)..<(i + 1 + len)])
        i += 1 + len
        return s
    }

    static func skip(_ b: [UInt8], _ i: inout Int) -> Bool {
        guard i < b.count else { return false }
        switch b[i] {
        case UInt8(ascii: "i"):
            guard let e = b[i...].firstIndex(of: UInt8(ascii: "e")) else { return false }
            i = e + 1
            return true
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            i += 1
            while i < b.count, b[i] != UInt8(ascii: "e") { guard skip(b, &i) else { return false } }
            guard i < b.count else { return false }
            i += 1
            return true
        default:
            return string(b, &i) != nil
        }
    }
}

/// Un programme écoute-t-il déjà sur ce port local ? Sert à ne pas lancer un second moteur quand le premier
/// est seulement lent à répondre (vérification d'un gros torrent, disque occupé…).
public enum LocalPort {
    public static func isListening(_ port: Int, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }
}
