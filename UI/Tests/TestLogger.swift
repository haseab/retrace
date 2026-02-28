import XCTest
import AppKit
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

final class MenuBarManagerClickBehaviorTests: XCTestCase {
    func testLeftMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseDown))
    }

    func testLeftClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseUp))
    }

    func testRightMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseDown))
    }

    func testRightClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseUp))
    }

    func testUnrelatedEventDoesNotOpenStatusMenu() {
        XCTAssertFalse(MenuBarManager.shouldOpenStatusMenu(for: .keyDown))
    }

    func testMissingEventDefaultsToOpenStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: nil))
    }
}

final class TimelineFocusRestoreDecisionTests: XCTestCase {
    func testShouldCaptureFocusRestoreTargetForExternalFrontmostApp() {
        XCTAssertTrue(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotCaptureFocusRestoreTargetWhenFrontmostIsRetrace() {
        XCTAssertFalse(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotCaptureFocusRestoreTargetWhenFrontmostUnavailable() {
        XCTAssertFalse(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: nil,
                currentProcessID: 111
            )
        )
    }

    func testShouldRestoreFocusWhenRequestedAndTargetExternal() {
        XCTAssertTrue(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: false,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenHideWasForDashboard() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: true,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenNotRequested() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: false,
                isHidingToShowDashboard: false,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenTargetIsCurrentProcess() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: false,
                targetProcessID: 111,
                currentProcessID: 111
            )
        )
    }
}

final class DashboardWindowTitleFormatterTests: XCTestCase {
    func testStripsWebPrefixForChromePWAAppShimBundle() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "ChatGPT Web - New Chat",
            appBundleID: "com.google.Chrome.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )

        XCTAssertEqual(result, "New Chat")
    }

    func testStripsUnreadBadgeAfterWebPrefix() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Notion Web - (4) Project Roadmap",
            appBundleID: "com.google.Chrome.app.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )

        XCTAssertEqual(result, "Project Roadmap")
    }

    func testStripsDomainPrefixForChromePWAAppShimBundle() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "timetracking.live - Weekly Report",
            appBundleID: "com.google.Chrome.app.cccccccccccccccccccccccccccccccc"
        )

        XCTAssertEqual(result, "Weekly Report")
    }

    func testKeepsRegularChromeTabTitlesUntouched() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Feature request - GitHub",
            appBundleID: "com.google.Chrome"
        )

        XCTAssertEqual(result, "Feature request - GitHub")
    }

    func testKeepsNonChromeTitlesUntouched() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Terminal - zsh",
            appBundleID: "com.apple.Terminal"
        )

        XCTAssertEqual(result, "Terminal - zsh")
    }
}

@MainActor
final class DateJumpTimeOnlyParsingTests: XCTestCase {
    func testFutureTimeOnlyInputResolvesToPreviousDay() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("4pm", now: now) else {
            XCTFail("Expected parser to resolve a time-only date")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 22, hour: 16, minute: 0)
    }

    func testPastTimeOnlyInputStaysOnCurrentDay() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 18, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("4pm", now: now) else {
            XCTFail("Expected parser to resolve a time-only date")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 16, minute: 0)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = components.date else {
            fatalError("Failed to construct test date")
        }
        return date
    }

    private func assertDateComponents(_ date: Date, year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, year)
        XCTAssertEqual(components.month, month)
        XCTAssertEqual(components.day, day)
        XCTAssertEqual(components.hour, hour)
        XCTAssertEqual(components.minute, minute)
    }
}

@MainActor
final class DateJumpPlayheadRelativeParsingTests: XCTestCase {
    func testDayEarlierResolvesToExact1440MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 day earlier", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative day offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 22, hour: 9, minute: 48)
    }

    func testWeekLaterResolvesToExact10080MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 week later", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative week offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 7 * 24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 3, day: 2, hour: 9, minute: 48)
    }

    func testMonthEarlierUsesPlayheadAsBaseAndPreservesClockTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 5, day: 15, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 month earlier", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative month offset")
            return
        }

        assertDateComponents(result, year: 2026, month: 4, day: 15, hour: 9, minute: 48)
    }

    func testHourBeforeResolvesToExact60MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 hour before", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative hour offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 8, minute: 48)
    }

    func testMonthAfterUsesPlayheadAsBaseAndPreservesClockTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 5, day: 15, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 month after", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative month offset")
            return
        }

        assertDateComponents(result, year: 2026, month: 6, day: 15, hour: 9, minute: 48)
    }

    func testAgoPhraseIsNotHandledByPlayheadEarlierLaterParser() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 hour ago", baseTimestamp: base)
        XCTAssertNil(result)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = components.date else {
            fatalError("Failed to construct test date")
        }
        return date
    }

    private func assertDateComponents(_ date: Date, year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, year)
        XCTAssertEqual(components.month, month)
        XCTAssertEqual(components.day, day)
        XCTAssertEqual(components.hour, hour)
        XCTAssertEqual(components.minute, minute)
    }
}

@MainActor
final class SearchHighlightQueryParsingTests: XCTestCase {
    func testSingleLetterTermHighlightsWholeWordOnly() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Status page"),
            makeNode(id: 2, text: "Create a feature quickly"),
            makeNode(id: 3, text: "Planning board")
        ]
        viewModel.searchHighlightQuery = "a"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [2])
        XCTAssertEqual(matches.first?.ranges.count, 1)
    }

    func testMixedQueryDoesNotHighlightEmbeddedSingleLetterMatches() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Status planning board"),
            makeNode(id: 2, text: "Create a feature quickly"),
            makeNode(id: 3, text: "Feature rollout")
        ]
        viewModel.searchHighlightQuery = "create a feature"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [2, 3])
    }

    func testQuotedPhraseSearchOnlyHighlightsPhraseMatches() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Roadmap for release"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "\"create a feature\""
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1])
        XCTAssertEqual(matches.first?.ranges.count, 1)
    }

    func testMixedPhraseAndTermSearchDoesNotSplitPhraseIntoSingleWords() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Launch checklist"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "\"create a feature\" launch"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
    }

    private func makeNode(id: Int, text: String) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: 0.1,
            y: 0.1,
            width: 0.3,
            height: 0.1,
            text: text
        )
    }
}

@MainActor
final class SystemMonitorBacklogTrendTests: XCTestCase {
    func testQueueDepthChangePerMinutePositiveWhenBacklogGrows() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 2),
            (timestamp: t0.addingTimeInterval(15), depth: 6),
            (timestamp: t0.addingTimeInterval(30), depth: 10)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNotNil(change)
        XCTAssertEqual(change ?? 0, 16, accuracy: 0.001)
    }

    func testQueueDepthChangePerMinuteNegativeWhenQueueDrains() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 12),
            (timestamp: t0.addingTimeInterval(15), depth: 8),
            (timestamp: t0.addingTimeInterval(30), depth: 4)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNotNil(change)
        XCTAssertEqual(change ?? 0, -16, accuracy: 0.001)
    }

    func testQueueDepthChangePerMinuteReturnsNilWithoutEnoughTimeWindow() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 2),
            (timestamp: t0.addingTimeInterval(8), depth: 4)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNil(change)
    }
}
