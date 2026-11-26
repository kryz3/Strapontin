import XCTest
@testable import StrapontinCore

final class VolumeIconTests: XCTestCase {
    func testMutedShowsSlashedSpeakerWhateverTheVolume() {
        XCTAssertEqual(VolumeIcon.name(volume: 100, muted: true), "speaker.slash.fill")   // le bug : ondes affichées son coupé
        XCTAssertEqual(VolumeIcon.name(volume: 100, muted: false), "speaker.wave.3.fill")
        XCTAssertEqual(VolumeIcon.name(volume: 50, muted: false), "speaker.wave.2.fill")
        XCTAssertEqual(VolumeIcon.name(volume: 20, muted: false), "speaker.wave.1.fill")
        XCTAssertEqual(VolumeIcon.name(volume: 0, muted: false), "speaker.slash.fill")
    }
}
