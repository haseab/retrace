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

    func testMultipleDisplaysSelectTheirOwnVisibleAppInsteadOfTheGlobalForegroundApp() {
        let displayA = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let displayB = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let editor = localWindow(id: 1, pid: 101, bounds: CGRect(x: 20, y: 20, width: 600, height: 500))
        let calculator = localWindow(id: 2, pid: 202, bounds: CGRect(x: 1100, y: 20, width: 600, height: 500))
        let windows = [editor, calculator]
        let selected = [displayA, displayB].map { display in
            windows.first {
                ForegroundWindowSelection.isEligible($0, foregroundPID: 101,
                    bundleID: "com.example.application", displayBounds: display,
                    requireForegroundApp: false)
            }?[kCGWindowNumber as String] as? Int
        }
        XCTAssertEqual(selected, [1, 2])
        XCTAssertFalse(ForegroundWindowSelection.isEligible(calculator, foregroundPID: 101,
            bundleID: "com.example.calculator", displayBounds: displayB))
    }

    func testDisplayLocalSelectionDoesNotBorrowAnAppFromAnEmptyNeighbouringDisplay() {
        let window = localWindow(id: 1, pid: 101, bounds: CGRect(x: 20, y: 20, width: 600, height: 500))
        XCTAssertFalse(ForegroundWindowSelection.isEligible(window, foregroundPID: 101,
            bundleID: "com.example.editor", displayBounds: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            requireForegroundApp: false))
    }

    func testDisplayLocalSelectionKeepsWindowEligibilityAndFrontToBackOrdering() {
        let valid = localWindow(id: 5, pid: 202, bounds: CGRect(x: 1100, y: 20, width: 600, height: 500))
        var hidden = valid
        hidden[kCGWindowIsOnscreen as String] = false
        var transparent = valid
        transparent[kCGWindowAlpha as String] = 0.0
        var overlay = valid
        overlay[kCGWindowLayer as String] = 3
        var lower = valid
        lower[kCGWindowNumber as String] = 6
        let selected = [hidden, transparent, overlay, valid, lower].first {
            ForegroundWindowSelection.isEligible($0, foregroundPID: nil,
                bundleID: "com.example.calculator", displayBounds: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                requireForegroundApp: false)
        }
        XCTAssertEqual(selected?[kCGWindowNumber as String] as? Int, 5)
        XCTAssertFalse(ForegroundWindowSelection.isEligible(valid, foregroundPID: nil,
            bundleID: "com.openai.sky.CUAService", requireForegroundApp: false))
    }

    private func localWindow(id: Int, pid: pid_t, bounds: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowName as String: "Example document", kCGWindowLayer as String: 0,
         kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
}
