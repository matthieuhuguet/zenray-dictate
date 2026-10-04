import XCTest
@testable import ZenRayDictate

// 4 October 2026: reproduce lost release and validate recovery without duplicate or fabricated presses.
final class FnKeyTests:XCTestCase {
    func testMissedReleaseBlocksNextPressUntilRecovered() {
        var state=FnPressState()
        XCTAssertEqual(state.receive(isDown:true),true)
        XCTAssertNil(state.receive(isDown:true))
        XCTAssertTrue(state.recoverRelease(isDown:false))
        XCTAssertEqual(state.receive(isDown:true),true)
    }
    func testHeldKeyIsNeverReleasedByHealthCheck() {
        var state=FnPressState()
        XCTAssertEqual(state.receive(isDown:true),true)
        XCTAssertFalse(state.recoverRelease(isDown:true))
        XCTAssertNil(state.receive(isDown:true))
        XCTAssertEqual(state.receive(isDown:false),false)
    }
    func testHealthCheckNeverCreatesAPress() {
        var state=FnPressState()
        XCTAssertFalse(state.recoverRelease(isDown:true))
        XCTAssertFalse(state.isDown)
        XCTAssertEqual(state.receive(isDown:true),true)
        XCTAssertEqual(state.receive(isDown:false),false)
        XCTAssertFalse(state.recoverRelease(isDown:false))
    }
}
