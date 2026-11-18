import XCTest
import CoreGraphics
@testable import Capture

final class ForegroundWindowSelectionTests: XCTestCase {
    private func recordedWindows() throws -> [[String: Any]] {
        let data = Data("""
        [
          {
            "kCGWindowNumber": 29442,
            "kCGWindowOwnerPID": 62907,
            "kCGWindowName": "Window",
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1,
            "kCGWindowIsOnscreen": true,
            "kCGWindowBounds": {"X": 304, "Y": 145, "Width": 66, "Height": 20}
          },
          {
            "kCGWindowNumber": 29331,
            "kCGWindowOwnerPID": 62907,
            "kCGWindowName": "Input Source Probe — isolated test",
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1,
            "kCGWindowIsOnscreen": true,
            "kCGWindowBounds": {"X": 298, "Y": 139, "Width": 760, "Height": 582}
          }
        ]
        """.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testRecordedSharingIndicatorIsSkippedBeforeTheRealWindow() throws {
        let windows = try recordedWindows()
        let selected = windows.first {
            ForegroundWindowSelection.isEligible($0, foregroundPID: 62907, bundleID: "local.retrace.input-source-probe")
        }

        XCTAssertEqual(selected?[kCGWindowNumber as String] as? Int, 29331)
        XCTAssertEqual(selected?[kCGWindowName as String] as? String, "Input Source Probe — isolated test")
    }

    func testBackgroundProcessCannotSupplyForegroundMetadata() throws {
        let selected = try recordedWindows().first {
            ForegroundWindowSelection.isEligible($0, foregroundPID: 3056, bundleID: "local.retrace.input-source-probe")
        }

        XCTAssertNil(selected)
    }

    func testSharingIndicatorAloneDoesNotBecomeTheFallbackWindow() throws {
        let indicator = try XCTUnwrap(recordedWindows().first)

        XCTAssertFalse(ForegroundWindowSelection.isEligible(
            indicator,
            foregroundPID: 62907,
            bundleID: "local.retrace.input-source-probe"
        ))
    }

    func testNormalWindowNamedWindowIsKept() throws {
        var window = try XCTUnwrap(recordedWindows().last)
        window[kCGWindowName as String] = "Window"

        XCTAssertTrue(ForegroundWindowSelection.isEligible(window, foregroundPID: 62907, bundleID: "dev.bb.desktop"))
    }

    func testCompactWindowWithAnotherTitleIsKept() throws {
        var window = try XCTUnwrap(recordedWindows().first)
        window[kCGWindowName as String] = "Find"

        XCTAssertTrue(ForegroundWindowSelection.isEligible(window, foregroundPID: 62907, bundleID: "dev.bb.desktop"))
    }

    func testComputerUseServiceCannotSupplyMetadataEvenWhenForeground() throws {
        let window = try XCTUnwrap(recordedWindows().last)

        XCTAssertFalse(ForegroundWindowSelection.isEligible(
            window,
            foregroundPID: 62907,
            bundleID: "com.openai.sky.CUAService"
        ))
    }

    func testWindowMustIntersectTheCapturedDisplay() throws {
        let window = try XCTUnwrap(recordedWindows().last)

        XCTAssertFalse(ForegroundWindowSelection.isEligible(
            window,
            foregroundPID: 62907,
            bundleID: "dev.bb.desktop",
            displayBounds: CGRect(x: 2000, y: 0, width: 1440, height: 900)
        ))
    }

    func testMissingForegroundProcessDoesNotFallBackToAnotherApp() throws {
        let window = try XCTUnwrap(recordedWindows().last)

        XCTAssertFalse(ForegroundWindowSelection.isEligible(window, foregroundPID: nil, bundleID: "dev.bb.desktop"))
    }
}
