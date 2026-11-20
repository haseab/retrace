import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class TimelineRecentTapeDecisionTests: XCTestCase {
    func testNewestLoadedTimestampIsRecentWithinFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_500_000)
        let newestTimestamp = now.addingTimeInterval(-299)

        XCTAssertTrue(
            SimpleTimelineViewModel.isNewestLoadedTimestampRecent(
                newestTimestamp,
                now: now
            )
        )
    }

    func testNewestLoadedTimestampIsNotRecentBeyondFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_500_000)
        let newestTimestamp = now.addingTimeInterval(-301)

        XCTAssertFalse(
            SimpleTimelineViewModel.isNewestLoadedTimestampRecent(
                newestTimestamp,
                now: now
            )
        )
    }
}
