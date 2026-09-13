import ApplicationServices
import Foundation
import XCTest
@testable import auto_click_cdp_popup

final class EventDrivenWatcherTests: XCTestCase {
    func testTraversalRejectsCyclesAndEqualReferencesButResetsBetweenScans() {
        let element = AXUIElementCreateApplication(101)
        let equalReference = AXUIElementCreateApplication(101)
        var traversal = CDPTraversalState()
        XCTAssertTrue(traversal.enter(element, depth: 0))
        XCTAssertFalse(traversal.enter(equalReference, depth: 1))
        XCTAssertTrue(traversal.enter(AXUIElementCreateApplication(102), depth: 1))
        var nextScan = CDPTraversalState()
        XCTAssertTrue(nextScan.enter(element, depth: 0))
    }

    func testTraversalExcludesWebContentsAndNativeMenus() {
        for role in ["AXWebArea", kAXMenuBarRole as String, kAXMenuRole as String, kAXMenuItemRole as String] {
            XCTAssertFalse(CDPMatchPolicy.shouldTraverse(role: role))
        }
        for role in [kAXWindowRole as String, kAXGroupRole as String, kAXSheetRole as String, kAXButtonRole as String] {
            XCTAssertTrue(CDPMatchPolicy.shouldTraverse(role: role))
        }
    }

    func testDefaultWatchdogIntervalIsSixtySeconds() {
        XCTAssertEqual(Options().interval, 60)
    }

    func testNativeMessagingFrameRoundTripUsesLittleEndianLength() throws {
        let pipe = Pipe()
        let object: [String: Any] = [
            "type": "request",
            "id": "test",
            "method": "tabs.list"
        ]
        let frame = try NativeMessagingCodec.encode(object)
        try pipe.fileHandleForWriting.write(contentsOf: frame)
        try pipe.fileHandleForWriting.close()
        let decoded = try NativeMessagingCodec.readMessage(from: pipe.fileHandleForReading)
        XCTAssertEqual(decoded?["type"] as? String, "request")
        XCTAssertEqual(decoded?["id"] as? String, "test")
        XCTAssertEqual(decoded?["method"] as? String, "tabs.list")
        let header = frame.prefix(4)
        let byte0 = UInt32(header[header.startIndex])
        let byte1 = UInt32(header[header.startIndex + 1])
        let byte2 = UInt32(header[header.startIndex + 2])
        let byte3 = UInt32(header[header.startIndex + 3])
        let encodedLength = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
        XCTAssertEqual(encodedLength, UInt32(frame.count - 4))
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
        XCTAssertEqual(CDPPressPolicy.burstDelays.first, 0)
        XCTAssertLessThanOrEqual(CDPPressPolicy.burstDelays.last ?? .infinity, 1)
    }

    func testCDPPressRetryIsDebouncedWithoutAbandoningPersistentPrompt() {
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
        XCTAssertFalse(CDPPressPolicy.shouldSuppress(
            attempts: 2,
            elapsedSinceLastAttempt: 1
        ))
        XCTAssertFalse(CDPPressPolicy.shouldSuppress(
            attempts: 100,
            elapsedSinceLastAttempt: 0.500
        ))
        XCTAssertTrue(CDPPressPolicy.shouldSuppress(
            attempts: 100,
            elapsedSinceLastAttempt: 0.100
        ))
    }

    func testTransientAccessibilityFailuresDoNotConfirmDismissal() {
        for error: AXError in [.cannotComplete, .apiDisabled, .failure, .noValue, .success] {
            XCTAssertFalse(CDPPressPolicy.confirmsDisappearance(error))
        }
        XCTAssertTrue(CDPPressPolicy.confirmsDisappearance(.invalidUIElement))
        XCTAssertTrue(CDPPressPolicy.confirmsDisappearance(.invalidUIElementObserver))
    }

    func testReconciliationFindsPromptWithoutAnyNotificationAndServicesEveryBrowser() {
        let watcher = Watcher(options: Options(), isTrusted: { true }, runningApplications: { [] })
        watcher.monitoringStarted = true
        watcher.processKinds = [101: .cdp, 102: .cdp, 103: .homebrewGatekeeper]
        var scanned: [pid_t] = []
        watcher.reconcileCDP { pid in
            scanned.append(pid)
            return "clicked: [cdp] fixture"
        }
        XCTAssertEqual(scanned, [101, 102])
        XCTAssertEqual(watcher.clickCount, 2)
    }

    func testPermissionLossStopsPendingWorkAndRestorationRebuildsMonitoring() {
        var trusted = false
        var applicationReads = 0
        let watcher = Watcher(
            options: Options(),
            isTrusted: { trusted },
            runningApplications: {
                applicationReads += 1
                return []
            }
        )
        watcher.monitoringStarted = true
        watcher.processKinds = [101: .cdp]
        let burst = LocalBurst(pid: 101, root: nil)
        watcher.localBursts = [burst]
        var scans = 0
        watcher.reconcileCDP { _ in
            scans += 1
            return nil
        }
        XCTAssertEqual(scans, 0)
        XCTAssertFalse(watcher.monitoringStarted)
        XCTAssertTrue(watcher.processKinds.isEmpty)
        XCTAssertTrue(burst.stopped)
        XCTAssertNotNil(watcher.accessibilityTimer)
        trusted = true
        watcher.reconcileCDP { _ in
            scans += 1
            return nil
        }
        XCTAssertTrue(watcher.monitoringStarted)
        XCTAssertEqual(applicationReads, 1)
        XCTAssertNil(watcher.accessibilityTimer)
        XCTAssertEqual(scans, 0)
    }

    func testChromeTimerIsIndependentOfSlowMaintenanceInterval() {
        var options = Options()
        options.interval = 60
        let watcher = Watcher(options: options, isTrusted: { false }, runningApplications: { [] })
        watcher.scheduleWatchdog()
        watcher.scheduleReconciliation()
        defer {
            watcher.timer?.invalidate()
            watcher.reconciliationTimer?.invalidate()
        }
        XCTAssertEqual(watcher.timer?.timeInterval, 60)
        XCTAssertEqual(watcher.reconciliationTimer?.timeInterval, 0.250)
    }
}
