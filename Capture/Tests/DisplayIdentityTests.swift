import XCTest
import Shared

final class DisplayIdentityTests: XCTestCase {
    func testIDsPersistAcrossRuntimeChangesAndDoNotCollapseDuplicateUUIDs() throws {
        let suite = "display-identity-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DisplayIdentityRegistry(defaults: defaults)
        let id = first.displayID(for: 1, uuid: "11111111-1111-1111-1111-111111111111")
        let twin = first.displayID(for: 2, uuid: "11111111-1111-1111-1111-111111111111")
        XCTAssertNotEqual(id, twin)
        XCTAssertEqual(first.displayID(for: 1, uuid: "11111111-1111-1111-1111-111111111111"), id)
        XCTAssertEqual(first.displayID(for: 2, uuid: "11111111-1111-1111-1111-111111111111"), twin)
        let restarted = DisplayIdentityRegistry(defaults: defaults)
        XCTAssertEqual(restarted.displayID(for: 7, uuid: "11111111-1111-1111-1111-111111111111"), id)
        // New hardware reusing a runtime ID cannot inherit a different panel's ID.
        XCTAssertNotEqual(restarted.displayID(for: 7, uuid: "22222222-2222-2222-2222-222222222222"), id)
        XCTAssertGreaterThan(id, 0)
        XCTAssertLessThanOrEqual(twin, UInt32(Int32.max))
    }
}
