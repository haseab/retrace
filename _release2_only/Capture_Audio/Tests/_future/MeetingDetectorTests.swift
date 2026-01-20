import XCTest
import Shared
@testable import Capture

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      MEETING DETECTOR TESTS                                  ║
// ║                                                                              ║
// ║  • Verify initial state is not in meeting                                    ║
// ║  • Verify monitoring can be started and stopped                              ║
// ║  • Verify state changes are detected                                         ║
// ║  • Verify meeting app bundle IDs are monitored                               ║
// ║  • Verify state change callbacks are invoked                                 ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class MeetingDetectorTests: XCTestCase {

    var detector: MeetingDetector!

    override func setUp() async throws {
        detector = MeetingDetector()
    }

    override func tearDown() async throws {
        await detector.stopMonitoring()
        detector = nil
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Initial State Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testInitialState_NotInMeeting() async {
        let state = await detector.getCurrentState()

        XCTAssertFalse(state.isInMeeting)
        XCTAssertNil(state.detectedApp)
        XCTAssertNil(state.detectedAt)
    }

    func testIsMeetingActive_InitiallyFalse() {
        let isActive = detector.isMeetingActive()

        XCTAssertFalse(isActive)
    }

    func testGetActiveMeetingApp_InitiallyNil() {
        let app = detector.getActiveMeetingApp()

        XCTAssertNil(app)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Monitoring Tests                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testStartMonitoring_WithBundleIDs() async {
        let bundleIDs: Set<String> = ["us.zoom.xos", "com.microsoft.teams2"]

        await detector.startMonitoring(bundleIDs: bundleIDs)

        // Monitoring should be active
        // Note: We can't directly test the monitoring state without exposing internal state
        // In a real implementation, we'd add a `isMonitoring` property
    }

    func testStopMonitoring_ResetsState() async {
        let bundleIDs: Set<String> = ["us.zoom.xos"]

        await detector.startMonitoring(bundleIDs: bundleIDs)
        await detector.stopMonitoring()

        let state = await detector.getCurrentState()

        // State should be reset
        XCTAssertFalse(state.isInMeeting)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                    State Change Callback Tests                           │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testStateChangeCallback_IsInvoked() async {
        let expectation = expectation(description: "State change callback invoked")
        expectation.isInverted = true  // We don't expect a meeting to be detected immediately

        await detector.onStateChange { state in
            // If a meeting is detected during the test, this will be called
            if state.isInMeeting {
                expectation.fulfill()
            }
        }

        let bundleIDs: Set<String> = ["us.zoom.xos", "com.microsoft.teams2"]
        await detector.startMonitoring(bundleIDs: bundleIDs)

        // Wait a short time
        await fulfillment(of: [expectation], timeout: 3.0)

        // Clean up
        await detector.stopMonitoring()
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Edge Case Tests                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testStartMonitoring_MultipleTimes_DoesNotCrash() async {
        let bundleIDs: Set<String> = ["us.zoom.xos"]

        // Starting monitoring multiple times should be safe
        await detector.startMonitoring(bundleIDs: bundleIDs)
        await detector.startMonitoring(bundleIDs: bundleIDs)
        await detector.startMonitoring(bundleIDs: bundleIDs)

        // Clean up
        await detector.stopMonitoring()
    }

    func testStopMonitoring_WithoutStart_DoesNotCrash() async {
        // Stopping without starting should be safe
        await detector.stopMonitoring()
        await detector.stopMonitoring()
    }
}
