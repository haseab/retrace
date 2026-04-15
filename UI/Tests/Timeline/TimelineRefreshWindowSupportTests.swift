import XCTest
import Shared
@testable import Retrace

final class TimelineRefreshWindowSupportTests: XCTestCase {
    func testMakeExistingWindowActionSkipsRefreshForHistoricalPosition() {
        let action = TimelineRefreshWindowSupport.makeExistingWindowAction(
            navigateToNewest: false,
            allowNearLiveAutoAdvance: true,
            currentIndex: 40,
            frameCount: 100,
            hasActiveFilters: false,
            newestLoadedFrameIsRecent: true,
            nearLiveEdgeFrameThreshold: 50
        )

        XCTAssertEqual(action, .skipRefresh)
    }

    func testMakeExistingWindowActionPromotesNearLivePositionToNewestWhenAllowed() {
        let action = TimelineRefreshWindowSupport.makeExistingWindowAction(
            navigateToNewest: false,
            allowNearLiveAutoAdvance: true,
            currentIndex: 95,
            frameCount: 100,
            hasActiveFilters: false,
            newestLoadedFrameIsRecent: true,
            nearLiveEdgeFrameThreshold: 50
        )

        XCTAssertEqual(action, .refresh(shouldNavigateToNewest: true))
    }

    func testMakeExistingWindowActionPreservesExplicitHistoricalFilteredRefresh() {
        let action = TimelineRefreshWindowSupport.makeExistingWindowAction(
            navigateToNewest: false,
            allowNearLiveAutoAdvance: true,
            currentIndex: 95,
            frameCount: 100,
            hasActiveFilters: true,
            newestLoadedFrameIsRecent: true,
            nearLiveEdgeFrameThreshold: 50
        )

        XCTAssertEqual(action, .refresh(shouldNavigateToNewest: false))
    }

    func testMakeFetchActionRequiresFullReloadWhenEntireFetchWindowIsNewAndAutoAdvanceAllowed() {
        let base = Date(timeIntervalSince1970: 1_700_070_000)
        let existingFrames = makeTimelineFrames(ids: Array(1...100), start: base)
        let fetchedFrames = makeFrameWithVideoInfos(
            ids: Array((200...249).reversed()),
            base: base
        )

        let action = TimelineRefreshWindowSupport.makeFetchAction(
            existingFrames: existingFrames,
            currentIndex: 95,
            fetchedFrames: fetchedFrames,
            newestCachedTimestamp: base.addingTimeInterval(99),
            refreshLimit: 50,
            shouldNavigateToNewest: true,
            hasStartedScrubbingThisVisibleSession: false
        )

        switch action {
        case .requireFullReloadToNewest:
            break
        default:
            XCTFail("Expected full reload when every fetched frame is newer and auto-advance is allowed")
        }
    }

    func testMakeFetchActionDoesNotForceFullReloadWhenHistoricalPlaybackShouldBePreserved() {
        let base = Date(timeIntervalSince1970: 1_700_070_000)
        let existingFrames = makeTimelineFrames(ids: Array(1...100), start: base)
        let fetchedFrames = makeFrameWithVideoInfos(
            ids: Array((200...249).reversed()),
            base: base
        )

        let action = TimelineRefreshWindowSupport.makeFetchAction(
            existingFrames: existingFrames,
            currentIndex: 10,
            fetchedFrames: fetchedFrames,
            newestCachedTimestamp: base.addingTimeInterval(99),
            refreshLimit: 50,
            shouldNavigateToNewest: false,
            hasStartedScrubbingThisVisibleSession: false
        )

        switch action {
        case .noChange:
            break
        default:
            XCTFail("Expected no-op when a full reload would violate historical-position preservation")
        }
    }

    func testMakeFetchActionAppendsNewFramesAndPinsToNewestWhenAllowed() {
        let base = Date(timeIntervalSince1970: 1_700_070_000)
        let existingFrames = makeTimelineFrames(ids: Array(1...100), start: base)
        let fetchedFrames = makeFrameWithVideoInfos(
            ids: Array((100...111).reversed()),
            base: base
        )

        let action = TimelineRefreshWindowSupport.makeFetchAction(
            existingFrames: existingFrames,
            currentIndex: 95,
            fetchedFrames: fetchedFrames,
            newestCachedTimestamp: base.addingTimeInterval(99),
            refreshLimit: 50,
            shouldNavigateToNewest: true,
            hasStartedScrubbingThisVisibleSession: false
        )

        switch action {
        case let .append(result):
            XCTAssertEqual(result.frames.count, 111)
            XCTAssertEqual(result.frames.suffix(3).map(\.frame.id.value), [109, 110, 111])
            XCTAssertEqual(result.resultingCurrentIndex, 110)
            XCTAssertEqual(result.appendedFrameCount, 11)
            XCTAssertEqual(result.oldestTimestamp, base)
            XCTAssertEqual(result.newestTimestamp, base.addingTimeInterval(110))
        default:
            XCTFail("Expected append mutation when only part of the refresh batch is new")
        }
    }

    func testMakeFetchActionPinsToExistingNewestWhenNoFreshFramesArrive() {
        let base = Date(timeIntervalSince1970: 1_700_070_000)
        let existingFrames = makeTimelineFrames(ids: Array(1...100), start: base)
        let fetchedFrames = makeFrameWithVideoInfos(
            ids: Array((90...100).reversed()),
            base: base
        )

        let action = TimelineRefreshWindowSupport.makeFetchAction(
            existingFrames: existingFrames,
            currentIndex: 95,
            fetchedFrames: fetchedFrames,
            newestCachedTimestamp: base.addingTimeInterval(99),
            refreshLimit: 50,
            shouldNavigateToNewest: true,
            hasStartedScrubbingThisVisibleSession: false
        )

        switch action {
        case let .pinToNewestExisting(resultingCurrentIndex):
            XCTAssertEqual(resultingCurrentIndex, 99)
        default:
            XCTFail("Expected pin-to-existing-newest when no newer frame was fetched")
        }
    }

    private func makeTimelineFrames(ids: [Int], start: Date) -> [TimelineFrame] {
        ids.enumerated().map { offset, id in
            TimelineFrame(
                frame: FrameReference(
                    id: FrameID(value: Int64(id)),
                    timestamp: start.addingTimeInterval(TimeInterval(offset)),
                    segmentID: AppSegmentID(value: Int64(id)),
                    frameIndexInSegment: offset,
                    metadata: FrameMetadata(
                        appBundleID: "test.app",
                        appName: "Test App",
                        displayID: 1
                    )
                ),
                videoInfo: nil,
                processingStatus: 2
            )
        }
    }

    private func makeFrameWithVideoInfos(ids: [Int], base: Date) -> [FrameWithVideoInfo] {
        ids.map { id in
            let frame = FrameReference(
                id: FrameID(value: Int64(id)),
                timestamp: base.addingTimeInterval(TimeInterval(id - 1)),
                segmentID: AppSegmentID(value: Int64(id)),
                frameIndexInSegment: id - 1,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                )
            )

            return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: 2)
        }
    }
}
