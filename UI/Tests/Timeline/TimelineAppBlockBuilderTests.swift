import XCTest
@testable import Retrace

final class TimelineAppBlockBuilderTests: XCTestCase {
    func testBuildSnapshotSplitsOnTimeGapAndAppChangeAndTracksBoundaries() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let frames = [
            makeInput(bundleID: "A", appName: "A", segmentIDValue: 1, timestamp: baseDate, videoPath: "video-1"),
            makeInput(bundleID: "A", appName: "A", segmentIDValue: 1, timestamp: baseDate.addingTimeInterval(10), videoPath: "video-1"),
            makeInput(bundleID: "A", appName: "A", segmentIDValue: 2, timestamp: baseDate.addingTimeInterval(140), videoPath: "video-2"),
            makeInput(bundleID: "B", appName: "B", segmentIDValue: 3, timestamp: baseDate.addingTimeInterval(150), videoPath: "video-2")
        ]

        let snapshot = TimelineAppBlockBuilder.buildSnapshot(
            from: frames,
            segmentTagsMap: [:],
            segmentCommentCountsMap: [:],
            hiddenTagID: nil
        )

        XCTAssertEqual(snapshot.blocks.count, 3)
        XCTAssertEqual(snapshot.blocks[0].startIndex, 0)
        XCTAssertEqual(snapshot.blocks[0].endIndex, 1)
        XCTAssertNil(snapshot.blocks[0].gapBeforeSeconds)

        XCTAssertEqual(snapshot.blocks[1].startIndex, 2)
        XCTAssertEqual(snapshot.blocks[1].endIndex, 2)
        XCTAssertEqual(snapshot.blocks[1].gapBeforeSeconds ?? -1, 130, accuracy: 0.001)

        XCTAssertEqual(snapshot.blocks[2].startIndex, 3)
        XCTAssertEqual(snapshot.blocks[2].endIndex, 3)
        XCTAssertNil(snapshot.blocks[2].gapBeforeSeconds)

        XCTAssertEqual(snapshot.frameToBlockIndex, [0, 0, 1, 2])
        XCTAssertEqual(snapshot.videoBoundaryIndices, [2])
        XCTAssertEqual(snapshot.segmentBoundaryIndices, [2, 3])
    }

    func testBuildSnapshotFiltersHiddenTagsAndAggregatesCommentStatePerBlock() {
        let baseDate = Date(timeIntervalSince1970: 1_700_001_000)
        let hiddenTagID: Int64 = 99
        let frames = [
            makeInput(bundleID: "A", appName: "A", segmentIDValue: 1, timestamp: baseDate, videoPath: "video-1"),
            makeInput(bundleID: "A", appName: "A", segmentIDValue: 2, timestamp: baseDate.addingTimeInterval(5), videoPath: "video-1"),
            makeInput(bundleID: "B", appName: "B", segmentIDValue: 3, timestamp: baseDate.addingTimeInterval(15), videoPath: "video-1")
        ]

        let snapshot = TimelineAppBlockBuilder.buildSnapshot(
            from: frames,
            segmentTagsMap: [
                1: [10, hiddenTagID],
                2: [11],
                3: [hiddenTagID]
            ],
            segmentCommentCountsMap: [
                2: 2
            ],
            hiddenTagID: hiddenTagID
        )

        XCTAssertEqual(snapshot.blocks.count, 2)
        XCTAssertEqual(snapshot.blocks[0].tagIDs, [10, 11])
        XCTAssertTrue(snapshot.blocks[0].hasComments)

        XCTAssertEqual(snapshot.blocks[1].tagIDs, [])
        XCTAssertFalse(snapshot.blocks[1].hasComments)
    }

    private func makeInput(
        bundleID: String?,
        appName: String?,
        segmentIDValue: Int64,
        timestamp: Date,
        videoPath: String?
    ) -> TimelineSnapshotFrameInput {
        TimelineSnapshotFrameInput(
            bundleID: bundleID,
            appName: appName,
            segmentIDValue: segmentIDValue,
            timestamp: timestamp,
            videoPath: videoPath
        )
    }
}
