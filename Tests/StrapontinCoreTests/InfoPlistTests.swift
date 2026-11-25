import XCTest

/// L'Info.plist de l'app (recopié tel quel par scripts/bundle.sh) : les serveurs IPTV en http simple doivent passer.
final class InfoPlistTests: XCTestCase {
    func testHTTPAllowedForUserIPTVServers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
    }
}
