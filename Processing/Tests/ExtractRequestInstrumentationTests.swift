import XCTest
@testable import Processing

final class ExtractRequestInstrumentationTests: XCTestCase {
    func testCombinedRegionTailResidualUsesLargestDeferredTailBucket() {
        let combinedBytes = ProcessingExtractRequestInstrumentation.combinedRegionTailResidualBytes(
            requestTailBytes: 120,
            cacheTailTotalBytes: 260,
            availableUnattributedBytes: 500
        )

        XCTAssertEqual(combinedBytes, 260)
    }

    func testCombinedRegionTailResidualClampsToAvailableUnattributedBytes() {
        let combinedBytes = ProcessingExtractRequestInstrumentation.combinedRegionTailResidualBytes(
            requestTailBytes: 180,
            cacheTailTotalBytes: 320,
            availableUnattributedBytes: 140
        )

        XCTAssertEqual(combinedBytes, 140)
    }

    func testCombinedRegionTailResidualIgnoresNegativeInputs() {
        let combinedBytes = ProcessingExtractRequestInstrumentation.combinedRegionTailResidualBytes(
            requestTailBytes: -10,
            cacheTailTotalBytes: 90,
            availableUnattributedBytes: -5
        )

        XCTAssertEqual(combinedBytes, 0)
    }
}
