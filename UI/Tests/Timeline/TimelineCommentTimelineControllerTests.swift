import XCTest
import Shared
@testable import Retrace

final class TimelineCommentTimelineControllerTests: XCTestCase {
    func testApplyInitialEntriesSortsRowsAndPreservesMissingAnchorComment() {
        let controller = TimelineCommentTimelineController()
        let anchorComment = makeComment(id: 3, createdAt: 3)
        let didBegin = controller.beginInitialLoad(anchorComment: anchorComment)

        controller.applyInitialEntries(
            [
                makeEntry(commentID: 2, segmentID: 20, createdAt: 2),
                makeEntry(commentID: 1, segmentID: 10, createdAt: 1)
            ],
            anchorComment: anchorComment,
            metadataNormalizer: normalizeMetadata
        ) { comment, context in
            CommentTimelineRow(comment: comment, context: context, primaryTagName: nil)
        }
        controller.finishInitialLoad()

        XCTAssertTrue(didBegin)
        XCTAssertEqual(controller.state.anchorCommentID, anchorComment.id)
        XCTAssertEqual(controller.state.rows.map(\.id.value), [1, 2, 3])
        XCTAssertFalse(controller.state.isLoadingTimeline)
        XCTAssertNil(controller.state.loadError)
    }

    func testIngestFrameBatchDeduplicatesSegmentsAndPrefersClosestContext() async throws {
        let controller = TimelineCommentTimelineController()
        let sharedComment = makeComment(id: 7, createdAt: 10.4)
        var loadedSegmentIDs: [Int64] = []

        let addedCount = try await controller.ingestFrameBatch(
            [
                makeFrame(id: 1, segmentID: 10, timestamp: 10.0, browserURL: nil),
                makeFrame(id: 2, segmentID: 20, timestamp: 11.0, browserURL: "https://example.com")
            ],
            metadataNormalizer: normalizeMetadata
        ) { segmentID in
            loadedSegmentIDs.append(segmentID.value)
            return [sharedComment]
        } rowBuilder: { comment, context in
            CommentTimelineRow(comment: comment, context: context, primaryTagName: nil)
        }

        XCTAssertEqual(addedCount, 1)
        XCTAssertEqual(loadedSegmentIDs, [10, 20])
        XCTAssertEqual(controller.state.rows.count, 1)
        XCTAssertEqual(controller.state.rows.first?.context?.segmentID.value, 10)

        let duplicateBatchAddedCount = try await controller.ingestFrameBatch(
            [makeFrame(id: 3, segmentID: 10, timestamp: 9.0, browserURL: nil)],
            metadataNormalizer: normalizeMetadata
        ) { segmentID in
            loadedSegmentIDs.append(segmentID.value)
            return [sharedComment]
        } rowBuilder: { comment, context in
            CommentTimelineRow(comment: comment, context: context, primaryTagName: nil)
        }

        XCTAssertEqual(duplicateBatchAddedCount, 0)
        XCTAssertEqual(loadedSegmentIDs, [10, 20])
    }

    func testBeginPageLoadClearsUnavailableBoundaryWhenTimestampMissing() {
        let controller = TimelineCommentTimelineController()
        controller.setHasMorePages(true, direction: .older)
        controller.setHasMorePages(true, direction: .newer)

        XCTAssertFalse(controller.beginPageLoad(direction: .older))
        XCTAssertFalse(controller.state.hasOlderPages)
        XCTAssertFalse(controller.beginPageLoad(direction: .newer))
        XCTAssertFalse(controller.state.hasNewerPages)
    }

    private func makeEntry(
        commentID: Int64,
        segmentID: Int64,
        createdAt: TimeInterval
    ) -> TimelineCommentTimelineEntry {
        (
            comment: makeComment(id: commentID, createdAt: createdAt),
            segmentID: SegmentID(value: segmentID),
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            browserURL: "https://example.com/\(commentID)",
            referenceTimestamp: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func makeComment(id: Int64, createdAt: TimeInterval) -> SegmentComment {
        SegmentComment(
            id: SegmentCommentID(value: id),
            body: "Comment \(id)",
            author: "Tester",
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func makeFrame(
        id: Int64,
        segmentID: Int64,
        timestamp: TimeInterval,
        browserURL: String?
    ) -> FrameReference {
        FrameReference(
            id: FrameID(value: id),
            timestamp: Date(timeIntervalSince1970: timestamp),
            segmentID: AppSegmentID(value: segmentID),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                browserURL: browserURL
            )
        )
    }

    private func normalizeMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
