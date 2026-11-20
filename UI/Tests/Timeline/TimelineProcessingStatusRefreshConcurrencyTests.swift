import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineProcessingStatusRefreshConcurrencyTests: XCTestCase {
    func testRefreshProcessingStatusesSkipsSafelyWhenFrameRemovedDuringAwait() async {
        let viewModel = makeViewModelWithFrames(ids: [1, 2, 3], status: 1)
        let gate = SharedAsyncTestGate()

        viewModel.test_refreshProcessingStatusesHooks.getFrameProcessingStatuses = { _ in
            [3: 2]
        }
        viewModel.test_refreshProcessingStatusesHooks.getFrameWithVideoInfoByID = { frameID in
            XCTAssertEqual(frameID.value, 3)
            await gate.enterAndWait()
            return self.makeFrameWithVideoInfo(id: frameID.value, processingStatus: 2)
        }

        let refreshTask = Task { @MainActor in
            await viewModel.refreshProcessingStatuses()
        }

        await gate.waitUntilEntered()
        viewModel.frames = [viewModel.frames[0]]
        await gate.release()
        await refreshTask.value

        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertEqual(viewModel.frames[0].frame.id.value, 1)
        XCTAssertEqual(viewModel.frames[0].processingStatus, 1)
    }

    func testRefreshProcessingStatusesUpdatesMovedFrameByIDAfterAwait() async {
        let viewModel = makeViewModelWithFrames(ids: [1, 2, 3], status: 1)
        let gate = SharedAsyncTestGate()

        viewModel.test_refreshProcessingStatusesHooks.getFrameProcessingStatuses = { _ in
            [3: 2]
        }
        viewModel.test_refreshProcessingStatusesHooks.getFrameWithVideoInfoByID = { frameID in
            XCTAssertEqual(frameID.value, 3)
            await gate.enterAndWait()
            return self.makeFrameWithVideoInfo(id: frameID.value, processingStatus: 2)
        }

        let refreshTask = Task { @MainActor in
            await viewModel.refreshProcessingStatuses()
        }

        await gate.waitUntilEntered()
        let first = viewModel.frames[0]
        let second = viewModel.frames[1]
        let third = viewModel.frames[2]
        viewModel.frames = [third, first, second]
        await gate.release()
        await refreshTask.value

        guard let movedFrame = viewModel.frames.first(where: { $0.frame.id.value == 3 }) else {
            XCTFail("Expected frame 3 to remain in the timeline")
            return
        }

        XCTAssertEqual(movedFrame.processingStatus, 2)
    }

    private func makeViewModelWithFrames(ids: [Int64], status: Int) -> SimpleTimelineViewModel {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = ids.enumerated().map { offset, id in
            makeTimelineFrame(id: id, frameIndex: offset, processingStatus: status)
        }
        viewModel.currentIndex = 0
        return viewModel
    }

    private func makeTimelineFrame(id: Int64, frameIndex: Int, processingStatus: Int) -> TimelineFrame {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: baseDate.addingTimeInterval(TimeInterval(frameIndex)),
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }

    private func makeFrameWithVideoInfo(id: Int64, processingStatus: Int) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: Date(timeIntervalSince1970: 1_700_000_100 + Double(id)),
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: Int(id),
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )
        let videoInfo = FrameVideoInfo(
            videoPath: "/tmp/test-\(id).mp4",
            frameIndex: Int(id),
            frameRate: 30,
            width: 1920,
            height: 1080,
            isVideoFinalized: true
        )
        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo, processingStatus: processingStatus)
    }
}
