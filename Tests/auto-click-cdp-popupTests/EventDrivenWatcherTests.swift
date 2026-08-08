import ApplicationServices
import XCTest
@testable import auto_click_cdp_popup

final class EventDrivenWatcherTests: XCTestCase {
    func testDefaultWatchdogIntervalIsSixtySeconds() {
        XCTAssertEqual(Options().interval, 60)
    }

    func testPromptTextCarriersAreLimitedToNativeTextAndButtons() {
        XCTAssertTrue(CDPMatchPolicy.canCarryTarget(role: kAXStaticTextRole as String))
        XCTAssertTrue(CDPMatchPolicy.canCarryTarget(role: kAXHeadingRole as String))
        XCTAssertTrue(CDPMatchPolicy.canCarryTarget(role: kAXButtonRole as String))
        XCTAssertFalse(CDPMatchPolicy.canCarryTarget(role: kAXWindowRole as String))
        XCTAssertFalse(CDPMatchPolicy.canCarryTarget(role: kAXRadioButtonRole as String))
        XCTAssertFalse(CDPMatchPolicy.canCarryTarget(role: "AXWebArea"))
    }

    func testChromeApplicationAlertDialogIsAnAllowedBoundary() {
        XCTAssertTrue(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXGroupRole as String,
            subrole: kAXApplicationAlertDialogSubrole as String
        ))
    }

    func testGenericNativeGroupsCannotCombineTargetAndButton() {
        XCTAssertFalse(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXGroupRole as String,
            subrole: ""
        ))
        XCTAssertFalse(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXGroupRole as String,
            subrole: kAXApplicationGroupSubrole as String
        ))
    }

    func testWindowAndWebContentCannotCombineTargetAndButton() {
        XCTAssertFalse(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String
        ))
        XCTAssertFalse(CDPMatchPolicy.canCombineTargetAndButton(
            role: "AXWebArea",
            subrole: ""
        ))
    }

    func testSheetPopoverAndExplicitButtonAreAllowedBoundaries() {
        XCTAssertTrue(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXSheetRole as String,
            subrole: ""
        ))
        XCTAssertTrue(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXPopoverRole as String,
            subrole: ""
        ))
        XCTAssertTrue(CDPMatchPolicy.canCombineTargetAndButton(
            role: kAXButtonRole as String,
            subrole: ""
        ))
    }

    func testCDPPressBurstWaitsForThePromptToBecomeReady() {
        XCTAssertEqual(CDPPressPolicy.burstDelays.first, 0.075)
        XCTAssertLessThanOrEqual(CDPPressPolicy.burstDelays.last ?? .infinity, 1)
    }

    func testCDPPressRetryIsDebouncedAndLimited() {
        XCTAssertFalse(CDPPressPolicy.shouldSuppress(
            attempts: 0,
            elapsedSinceLastAttempt: 0
        ))
        XCTAssertTrue(CDPPressPolicy.shouldSuppress(
            attempts: 1,
            elapsedSinceLastAttempt: 0.499
        ))
        XCTAssertFalse(CDPPressPolicy.shouldSuppress(
            attempts: 1,
            elapsedSinceLastAttempt: 0.500
        ))
        XCTAssertTrue(CDPPressPolicy.shouldSuppress(
            attempts: 2,
            elapsedSinceLastAttempt: 1
        ))
    }
}
