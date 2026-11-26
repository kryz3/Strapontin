import XCTest
@testable import StrapontinCore

final class OpenSubtitlesTests: XCTestCase {
    func testParseAndRank() throws {
        let json = """
        {"data":[
         {"attributes":{"language":"en","release":"Show.S04E20.720p","download_count":900,"files":[{"file_id":1,"file_name":"a.srt"}]}},
         {"attributes":{"language":"fr","release":"Show.S04E20.VOSTFR","download_count":50,"ai_translated":true,"files":[{"file_id":2}]}},
         {"attributes":{"language":"fr","release":"Show.S04E20.FRENCH","download_count":10,"files":[{"file_id":3}]}},
         {"attributes":{"language":"fr","files":[]}}
        ]}
        """
        let r = OpenSubtitlesClient.rank(OpenSubtitlesClient.parseSearch(Data(json.utf8)), languages: ["fr", "en"])
        XCTAssertEqual(r.map(\.id), [3, 2, 1])      // français humain, puis traduit par machine, puis anglais
        XCTAssertTrue(r[1].machineTranslated)
    }
}

final class ScrambleTests: XCTestCase {
    /// Même brouillage que scripts/bundle.sh (XOR « strapontin » + base64), aller-retour avec une clé factice.
    func testRoundTrip() {
        let salt = Array("strapontin".utf8)
        let scrambled = Data(Array("cle-factice-123".utf8).enumerated().map { $0.element ^ salt[$0.offset % salt.count] }).base64EncodedString()
        let back = Data(base64Encoded: scrambled).map { d in String(bytes: d.enumerated().map { $0.element ^ salt[$0.offset % salt.count] }, encoding: .utf8) }
        XCTAssertEqual(back, "cle-factice-123")
        XCTAssertFalse(scrambled.contains("factice"))
    }
}
