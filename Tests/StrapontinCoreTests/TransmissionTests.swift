import XCTest
@testable import StrapontinCore

/// États de Transmission traduits dans le vocabulaire de qBittorrent (affiché par `Torrent.stateLabel`).
final class TransmissionTests: XCTestCase {
    func testStates() {
        XCTAssertEqual(TransmissionClient.state(status: 0, progress: 0.4, rate: 0, error: 0), "stoppedDL")
        XCTAssertEqual(TransmissionClient.state(status: 0, progress: 1, rate: 0, error: 0), "stoppedUP")
        XCTAssertEqual(TransmissionClient.state(status: 2, progress: 0.4, rate: 0, error: 0), "checkingDL")
        XCTAssertEqual(TransmissionClient.state(status: 4, progress: 0, rate: 0, error: 0), "metaDL")
        XCTAssertEqual(TransmissionClient.state(status: 4, progress: 0.3, rate: 0, error: 0), "stalledDL")
        XCTAssertEqual(TransmissionClient.state(status: 4, progress: 0.3, rate: 1000, error: 0), "downloading")
        XCTAssertEqual(TransmissionClient.state(status: 6, progress: 1, rate: 0, error: 0), "uploading")
        XCTAssertEqual(TransmissionClient.state(status: 4, progress: 0.3, rate: 1000, error: 3), "error")
        // un torrent terminé et en partage compte comme fini (rescan de la bibliothèque)
        let t = Torrent(hash: "a", name: "x", progress: 1, state: TransmissionClient.state(status: 6, progress: 1, rate: 0, error: 0),
                        dlspeed: 0, eta: 0, size: 1, savePath: "/", contentPath: "/x", addedOn: 0)
        XCTAssertTrue(t.isDone)
        XCTAssertEqual(t.stateLabel, "Terminé · partage")
    }

    /// Empreinte calculée depuis le .torrent ou le magnet : sert à suivre la progression sur la fiche.
    func testInfoHash() {
        let t = Data(base64Encoded: "ZDg6YW5ub3VuY2UxNDp1ZHA6Ly94OjEvYW5ubzEwOmNyZWF0ZWQgYnkzOmxlYzQ6aW5mb2Q2Omxlbmd0aGkxMmU0Om5hbWU1OmEubWt2MTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6AQEBAQEBAQEBAQEBAQEBAQEBAQFlZQ==")!
        XCTAssertEqual(TorrentPayload.file(t, name: "a.torrent").infoHash, "d24475fbedc50adeabc6d1e0c582233b61b65bf4")
        XCTAssertEqual(TorrentPayload.magnet("magnet:?xt=urn:btih:D24475FBEDC50ADEABC6D1E0C582233B61B65BF4&dn=a").infoHash,
                       "d24475fbedc50adeabc6d1e0c582233b61b65bf4")
        XCTAssertEqual(TorrentPayload.magnet("magnet:?xt=urn:btih:2JCHL67NYUFN5K6G2HQMLARDHNQ3MW7U").infoHash,
                       "d24475fbedc50adeabc6d1e0c582233b61b65bf4")
        XCTAssertNil(TorrentPayload.file(Data("<html>".utf8), name: "x").infoHash)
    }

    /// Démon absent : erreur claire, pas de blocage.
    func testUnreachable() async {
        let c = TransmissionClient(url: "http://127.0.0.1:1/transmission/rpc", username: "a", password: "b")
        do { _ = try await c.version(); XCTFail("aurait dû échouer") } catch {
            XCTAssertEqual(error.localizedDescription, TransmissionError.unreachable.localizedDescription)
        }
    }
}

/// Port déjà pris : TorrentEngine ne lance pas de second démon.
final class LocalPortTests: XCTestCase {
    func testListening() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        XCTAssertEqual(withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) } }, 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertTrue(LocalPort.isListening(port))
        Darwin.close(fd)
        XCTAssertFalse(LocalPort.isListening(port))
    }
}
