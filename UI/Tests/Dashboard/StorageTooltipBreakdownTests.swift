import XCTest
@testable import Retrace

final class StorageTooltipBreakdownTests: XCTestCase {
    func testTooltipContentIncludesDBAndMP4Breakdown() {
        let point = DailyDataPoint(
            date: Date(timeIntervalSince1970: 1_774_649_600),
            value: 745_700_000,
            storageBreakdown: DailyStorageBreakdown(
                databaseBytes: 12_300_000,
                mp4Bytes: 733_400_000
            )
        )

        let content = MiniLineGraphView.tooltipContent(for: point)

        XCTAssertEqual(content.headline, "745.7MB")
        XCTAssertEqual(content.details, ["DB: 12.3MB", "MP4: 733.4MB"])
    }

    func testTooltipContentFallsBackToSingleLineWhenNoBreakdownExists() {
        let point = DailyDataPoint(
            date: Date(timeIntervalSince1970: 1_774_649_600),
            value: 745_700_000
        )

        let content = MiniLineGraphView.tooltipContent(for: point)

        XCTAssertEqual(content.headline, "745.7MB")
        XCTAssertTrue(content.details.isEmpty)
    }
}
