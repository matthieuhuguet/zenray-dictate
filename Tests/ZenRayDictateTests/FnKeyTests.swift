import XCTest
import AppKit
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
    func testLocalAndGlobalPathsToggleOncePerPhysicalPress() {
        let monitor=FnKeyMonitor();let done=expectation(description:"Two Fn presses across focus boundary")
        var count=0;monitor.onPress={count += 1;if count==2 {done.fulfill()} }
        func event(_ down:Bool,_ code:UInt16=63)->NSEvent {
            NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:down ? [.function] : [],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        monitor.receive(event(true),source:"local")
        monitor.receive(event(true),source:"local")
        monitor.receive(event(false),source:"global")
        monitor.receive(event(true),source:"global")
        monitor.receive(event(true,56),source:"global")
        wait(for:[done],timeout:1)
        XCTAssertEqual(count,2)
    }
}
