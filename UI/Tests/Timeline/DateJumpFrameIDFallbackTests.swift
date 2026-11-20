import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DateJumpFrameIDFallbackTests: XCTestCase {
    func testCompactNumericTimeFallbackDoesNotFlashFrameNotFoundError() async {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let key = "enableFrameIDSearch"
        let originalValue = defaults.object(forKey: key)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)

        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        var observedErrors: [String] = []
        var cancellables = Set<AnyCancellable>()
        var didAttemptFrameLookup = false

        viewModel.$error
            .compactMap { $0 }
            .sink { observedErrors.append($0) }
            .store(in: &cancellables)

        viewModel.test_frameLookupHooks.getFrameWithVideoInfoByID = { _ in
            didAttemptFrameLookup = true
            return nil
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, _, _, reason in
            switch reason {
            case "searchForDate":
                let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                return [self.makeFrameWithVideoInfo(id: 9001, timestamp: midpoint, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1312")

        XCTAssertFalse(didAttemptFrameLookup)
        XCTAssertFalse(observedErrors.contains("Frame #1312 not found"))
        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 9001)
    }

    private func makeFrameWithVideoInfo(id: Int64, timestamp: Date, processingStatus: Int) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }
}
