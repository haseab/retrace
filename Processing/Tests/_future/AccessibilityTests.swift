import XCTest
import Shared
@testable import Processing

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      ACCESSIBILITY TESTS                                     ║
// ║                                                                              ║
// ║  Tests REAL macOS Accessibility API behavior:                                ║
// ║  • Permission checks (real system state)                                     ║
// ║  • App info extraction (real running apps)                                   ║
// ║  • Text extraction (real accessibility tree)                                 ║
// ║                                                                              ║
// ║  NOTE: These tests require Accessibility permission to be granted            ║
// ║        Tests will skip if permission is not available                        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class AccessibilityTests: XCTestCase {

    var service: AccessibilityService!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        service = AccessibilityService()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                   REAL SYSTEM TESTS (macOS APIs)                         │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testHasPermission() async {
        // Tests REAL macOS permission check
        let hasPermission = await service.hasPermission()

        // Verify the method doesn't crash and returns a boolean
        XCTAssertNotNil(hasPermission)
    }

    func testGetFrontmostAppInfoReturnsValidData() async throws {
        // Tests REAL running app extraction
        // Only run if we have permission
        guard await service.hasPermission() else {
            throw XCTSkip("Accessibility permission not granted")
        }

        let appInfo = try await service.getFrontmostAppInfo()

        // Verify we got REAL data from a REAL running app
        XCTAssertFalse(appInfo.bundleID.isEmpty, "Bundle ID should not be empty")
        XCTAssertFalse(appInfo.name.isEmpty, "App name should not be empty")
    }

    func testGetFocusedAppTextWithPermission() async throws {
        // Tests REAL accessibility tree extraction
        // Only run if we have permission
        guard await service.hasPermission() else {
            throw XCTSkip("Accessibility permission not granted")
        }

        let result = try await service.getFocusedAppText()

        // Verify we got REAL data from REAL accessibility API
        XCTAssertNotNil(result.appInfo)
        XCTAssertFalse(result.appInfo.bundleID.isEmpty)
        XCTAssertNotNil(result.textElements)
        XCTAssertEqual(result.extractionTime.timeIntervalSinceNow, 0, accuracy: 1.0)
    }
}
