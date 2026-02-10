import XCTest
import Shared
import App
@testable import Retrace

extension XCTestCase {
    func printTestSeparator() {
        print("\n" + String(repeating: "=", count: 80))
        print("UI TEST OUTPUT")
        print(String(repeating: "=", count: 80) + "\n")
    }
}

@MainActor
final class TimelineBlockNavigationTests: XCTestCase {

    func testNavigateToPreviousBlockStartJumpsAcrossBlocks() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 4

        XCTAssertTrue(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartReturnsFalseAtBeginning() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B"])
        viewModel.currentIndex = 0

        XCTAssertFalse(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToNextBlockStartJumpsAcrossBlocks() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 0

        XCTAssertTrue(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartReturnsFalseAtEnd() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 4

        XCTAssertFalse(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameJumpsToNewestFrameInLastBlock() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 3

        XCTAssertTrue(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameReturnsFalseAtNewestFrame() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 4

        XCTAssertFalse(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameStillJumpsToNextBlockStart() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 1

        XCTAssertTrue(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    private func makeViewModelWithFrames(_ bundleIDs: [String]) -> SimpleTimelineViewModel {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        viewModel.frames = bundleIDs.enumerated().map { index, bundleID in
            let frame = FrameReference(
                id: FrameID(value: Int64(index + 1)),
                timestamp: baseDate.addingTimeInterval(TimeInterval(index)),
                segmentID: AppSegmentID(value: Int64(index + 1)),
                frameIndexInSegment: index,
                metadata: FrameMetadata(
                    appBundleID: bundleID,
                    appName: bundleID,
                    displayID: 1
                )
            )

            return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
        }

        viewModel.currentIndex = 0
        return viewModel
    }
}

@MainActor
final class DeeplinkHandlerTests: XCTestCase {

    func testSearchRouteParsesCanonicalTimestampAndApp() {
        let url = URL(string: "retrace://search?q=error&t=1704067200123&app=com.google.Chrome")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .search(query, timestamp, appBundleID)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(query, "error")
        XCTAssertEqual(appBundleID, "com.google.Chrome")
        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.123, accuracy: 0.0001)
    }

    func testSearchRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://search?q=errors&timestamp=1704067200456")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .search(query, timestamp, appBundleID)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(query, "errors")
        XCTAssertEqual(appBundleID, nil)
        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.456, accuracy: 0.0001)
    }

    func testTimelineRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://timeline?timestamp=1704067200999")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .timeline(timestamp)? = route else {
            XCTFail("Expected timeline route")
            return
        }

        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.999, accuracy: 0.0001)
    }

    func testGenerateSearchLinkUsesCanonicalTimestampKey() {
        let timestamp = Date(timeIntervalSince1970: 1_704_067_200.123)
        let url = DeeplinkHandler.generateSearchLink(
            query: "error",
            timestamp: timestamp,
            appBundleID: "com.apple.Safari"
        )

        XCTAssertNotNil(url)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        XCTAssertEqual(queryMap["q"]!, "error")
        XCTAssertEqual(queryMap["app"]!, "com.apple.Safari")
        XCTAssertEqual(queryMap["t"]!, "1704067200123")
        XCTAssertFalse(queryMap.keys.contains("timestamp"))
    }
}
