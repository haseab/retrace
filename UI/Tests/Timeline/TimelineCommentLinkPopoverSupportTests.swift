import Foundation
import XCTest
@testable import Retrace

final class TimelineCommentLinkPopoverSupportTests: XCTestCase {
    func testPreparedPendingURLDefaultsToHttpsWhenInputIsBlank() {
        XCTAssertEqual(
            TimelineCommentLinkPopoverSupport.preparedPendingURL(from: "   "),
            "https://"
        )
    }

    func testPreparedPendingURLPreservesExistingValue() {
        XCTAssertEqual(
            TimelineCommentLinkPopoverSupport.preparedPendingURL(from: "docs.example.com"),
            "docs.example.com"
        )
    }

    func testNormalizedURLPreservesSchemedValuesAndAddsHttpsFallback() {
        XCTAssertEqual(
            TimelineCommentLinkPopoverSupport.normalizedURL(from: "https://example.com/path")?.absoluteString,
            "https://example.com/path"
        )

        XCTAssertEqual(
            TimelineCommentLinkPopoverSupport.normalizedURL(from: "docs.example.com")?.absoluteString,
            "https://docs.example.com"
        )
    }

    func testInsertCommandURLReturnsNilForBlankValue() {
        XCTAssertNil(TimelineCommentLinkPopoverSupport.insertCommandURL(from: " "))
    }
}
