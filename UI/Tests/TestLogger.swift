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
final class TimelineRefreshTrimRegressionTests: XCTestCase {
    func testRefreshFrameDataTrimPreservesNewestIndexAfterAppend() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 99)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(111)
        )
    }

    func testRefreshFrameDataDefersTrimWhileActivelyScrollingAndAnchorsAfterScrollEnds() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_020_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95
        viewModel.isActivelyScrolling = true

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        // While scrubbing, trim should be deferred (window can exceed max in-memory size).
        XCTAssertEqual(viewModel.frames.count, 112)
        XCTAssertEqual(viewModel.currentIndex, 111)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)

        // Scroll end should apply deferred trim and keep playhead anchored to the same frame.
        viewModel.isActivelyScrolling = false

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 99)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(111)
        )
    }

    func testDeferredTrimTracksLatestScrubbedFrameBeforeScrollEnds() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_030_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95
        viewModel.isActivelyScrolling = true

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        XCTAssertEqual(viewModel.frames.count, 112)
        XCTAssertEqual(viewModel.currentIndex, 111)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)

        // Simulate the user continuing to scrub after the trim was deferred.
        viewModel.currentIndex = 95
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 96)

        viewModel.isActivelyScrolling = false

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 83)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 96)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(95)
        )
    }

    func testRefreshFrameDataDoesNotForceNewestReloadWhenNavigateToNewestIsFalseAndWindowIsStale() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)

        viewModel.filterCriteria = FilterCriteria(selectedApps: ["com.google.Chrome"])
        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 2
            )
        }
        viewModel.currentIndex = 10

        let originalFrameIDs = viewModel.frames.map(\.frame.id.value)
        let originalNewestTimestamp = viewModel.frames.last?.frame.timestamp

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, filters in
            XCTAssertEqual(limit, 50)
            XCTAssertTrue(filters.hasActiveFilters)
            return (200..<250).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 2
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: false, allowNearLiveAutoAdvance: false)

        XCTAssertEqual(viewModel.currentIndex, 10)
        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.frames.map(\.frame.id.value), originalFrameIDs)
        XCTAssertEqual(viewModel.frames.last?.frame.timestamp, originalNewestTimestamp)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        processingStatus: Int
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
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

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        processingStatus: Int
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: processingStatus)
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

final class TimelineKeyboardShortcutDecisionTests: XCTestCase {
    func testShouldHandleKeyboardShortcutsWhenTimelineVisibleAndFrontmost() {
        XCTAssertTrue(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenTimelineHidden() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: false,
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenAnotherAppIsFrontmost() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenFrontmostAppIsUnknown() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: nil,
                currentProcessID: 111
            )
        )
    }

    func testShouldToggleSearchOverlayShortcutWhenScrollIsNotActive() {
        XCTAssertTrue(
            TimelineWindowController.shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: false)
        )
    }

    func testShouldNotToggleSearchOverlayShortcutWhenScrollIsActive() {
        XCTAssertFalse(
            TimelineWindowController.shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: true)
        )
    }
}

final class TimelineNavigationShortcutDecisionTests: XCTestCase {
    func testShouldNavigateBackwardWithArrowJAndL() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: []
            )
        )
    }

    func testShouldNavigateForwardWithArrowKAndSemicolon() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 124,
                charactersIgnoringModifiers: nil,
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: []
            )
        )
    }

    func testNavigationShortcutSupportsOptionModifier() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: [.option]
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: [.option]
            )
        )
    }

    func testNavigationShortcutRejectsCommandModifier() {
        XCTAssertFalse(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: [.command]
            )
        )
        XCTAssertFalse(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: [.command]
            )
        )
    }
}

@MainActor
final class SearchOverlayEscapeDecisionTests: XCTestCase {
    func testExpandedOverlayEscShouldCollapseWithoutSubmittedSearch() {
        XCTAssertFalse(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenCommittedQueryExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenResultsPayloadExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: true
            )
        )
    }
}

@MainActor
final class SearchRecentEntriesRemovalTests: XCTestCase {
    private let recentEntriesDefaultsKey = "search.recentEntries.v1"
    private var originalRecentEntriesData: Data?

    override func setUp() {
        super.setUp()
        originalRecentEntriesData = UserDefaults.standard.data(forKey: recentEntriesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: recentEntriesDefaultsKey)
    }

    override func tearDown() {
        if let originalRecentEntriesData {
            UserDefaults.standard.set(originalRecentEntriesData, forKey: recentEntriesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recentEntriesDefaultsKey)
        }
        super.tearDown()
    }

    func testRemoveRecentSearchEntryRemovesMatchingEntryAndPersists() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.recordRecentSearchEntry("alpha query")
        viewModel.recordRecentSearchEntry("beta query")

        guard let removableEntry = viewModel.recentSearchEntries.first(where: { $0.query == "alpha query" }) else {
            XCTFail("Expected alpha query to exist in recent entries")
            return
        }

        viewModel.removeRecentSearchEntry(removableEntry)

        XCTAssertFalse(viewModel.recentSearchEntries.contains(where: { $0.key == removableEntry.key }))

        let reloadedViewModel = SearchViewModel(coordinator: AppCoordinator())
        XCTAssertFalse(reloadedViewModel.recentSearchEntries.contains(where: { $0.key == removableEntry.key }))
    }

    func testRemoveRecentSearchEntryWithUnknownKeyIsNoOp() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.recordRecentSearchEntry("single query")
        let beforeRemoval = viewModel.recentSearchEntries

        viewModel.removeRecentSearchEntry(key: "missing-entry-key")

        XCTAssertEqual(viewModel.recentSearchEntries, beforeRemoval)
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

    func testDateWithCompact24HourTimeParsesAsExactTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("feb 28 1417", now: now) else {
            XCTFail("Expected parser to resolve compact 24-hour time in date input")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 28, hour: 14, minute: 17)
    }

    func testDateWithExplicitYearKeepsYearInterpretation() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("feb 28 2024", now: now) else {
            XCTFail("Expected parser to resolve explicit year input")
            return
        }

        assertDateComponents(result, year: 2024, month: 2, day: 28, hour: 0, minute: 0)
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
    func testSearchTreatsFullInputAsExactPhrase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Create a feature branch"),
            makeNode(id: 3, text: "Feature quickly")
        ]
        viewModel.searchHighlightQuery = "create a feature"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
        XCTAssertEqual(matches.first?.ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "Create a feature")
    }

    func testSearchDoesNotSplitSpacesIntoSeparateTerms() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error message handler"),
            makeNode(id: 2, text: "Error handler"),
            makeNode(id: 3, text: "Message handler")
        ]
        viewModel.searchHighlightQuery = "error message"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1])
    }

    func testSearchSplitsCommaSeparatedPhrases() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Launch checklist"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "create a feature, launch"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
        XCTAssertEqual(matches.first?.ranges.count, 1)
    }

    func testSearchTrimsWhitespaceAroundCommaSeparatedPhrases() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Launch checklist"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "  create a feature  ,   launch   "
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
    }

    func testHighlightedSearchTextLinesGroupsByVisualLine() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error", x: 0.10, y: 0.10),
            makeNode(id: 2, text: "message", x: 0.24, y: 0.11),
            makeNode(id: 3, text: "Error", x: 0.10, y: 0.22),
            makeNode(id: 4, text: "handler", x: 0.24, y: 0.23)
        ]
        viewModel.searchHighlightQuery = "error, message, handler"
        viewModel.isShowingSearchHighlight = true

        let lines = viewModel.highlightedSearchTextLines()

        XCTAssertEqual(lines, ["Error message", "Error handler"])
    }

    func testInFrameSearchReturnsSpecificWordRangeWithinNode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Fatal error occurred")
        ]
        viewModel.searchHighlightQuery = "error"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].node.id, 1)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "error")
    }

    func testInFrameSearchReturnsSpecificPhraseRangeWithinNode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Fatal error occurred")
        ]
        viewModel.searchHighlightQuery = "\"error occurred\""
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "error occurred")
    }

    private func makeNode(id: Int, text: String, x: CGFloat = 0.1, y: CGFloat = 0.1) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: 0.3,
            height: 0.1,
            text: text
        )
    }
}

@MainActor
final class InFrameSearchTests: XCTestCase {
    func testSetInFrameSearchQueryAppliesHighlightAfterDebounce() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")

        XCTAssertTrue(viewModel.isInFrameSearchVisible)
        XCTAssertNil(viewModel.searchHighlightQuery)
        XCTAssertFalse(viewModel.isShowingSearchHighlight)

        try? await Task.sleep(for: .milliseconds(350), clock: .continuous)

        XCTAssertEqual(viewModel.searchHighlightQuery, "error")
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightNodes.map(\.node.id), [1])
    }

    func testCloseInFrameSearchClearsQueryAndHighlight() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        viewModel.closeInFrameSearch(clearQuery: true)
        try? await Task.sleep(for: .milliseconds(350), clock: .continuous)

        XCTAssertFalse(viewModel.isInFrameSearchVisible)
        XCTAssertEqual(viewModel.inFrameSearchQuery, "")
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testToggleInFrameSearchClosesWhenAlreadyVisible() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.toggleInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        try? await Task.sleep(for: .milliseconds(350), clock: .continuous)
        XCTAssertTrue(viewModel.isInFrameSearchVisible)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)

        viewModel.toggleInFrameSearch()

        XCTAssertFalse(viewModel.isInFrameSearchVisible)
        XCTAssertEqual(viewModel.inFrameSearchQuery, "")
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testResetSearchHighlightStateCancelsPendingSearchHighlightPresentation() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.showSearchHighlight(query: "error")
        viewModel.resetSearchHighlightState()

        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)

        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)

        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testNavigateToFrameKeepsHighlightWhenInFrameSearchIsActive() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        try? await Task.sleep(for: .milliseconds(350), clock: .continuous)
        viewModel.navigateToFrame(1)

        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightQuery, "error")
    }

    func testUndoClearsSearchResultHighlight() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        // Build undo history through real navigation/stopped-position recording.
        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)

        viewModel.showSearchHighlight(query: "error")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightQuery, "error")

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testUndoThreeTimesThenRedoThreeTimesReturnsToOriginalPosition() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 5, frameIndex: 4, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        // Build stop-history entries at indices 1,2,3,4.
        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(4)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)

        XCTAssertEqual(viewModel.currentIndex, 4)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 3)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)

        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 3)
        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNewNavigationClearsRedoHistoryImmediately() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 2)

        // New navigation branch should invalidate redo chain.
        viewModel.navigateToFrame(1)

        XCTAssertFalse(viewModel.redoLastUndonePosition())
    }

    func testUndoSlowPathResetsBoundaryStateViaSharedReloadPath() async {
        final class FetchTracker {
            var reloadWindowFetches = 0
            var postReloadNewerLoadAttempts = 0
        }

        let tracker = FetchTracker()
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Build undo history away from boundaries so it doesn't mutate pagination flags.
        viewModel.frames = (0..<50).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                frameIndex: offset,
                bundleID: "com.apple.Safari"
            )
        }
        viewModel.currentIndex = 24
        viewModel.navigateToFrame(25)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)
        viewModel.navigateToFrame(26)
        try? await Task.sleep(for: .milliseconds(1100), clock: .continuous)

        // Replace the in-memory window so undo must take slow path (frame ID #26 no longer loaded).
        viewModel.frames = (0..<10).map { offset in
            makeTimelineFrame(
                id: Int64(200 + offset),
                frameIndex: offset,
                bundleID: "com.apple.Safari"
            )
        }
        viewModel.currentIndex = 8

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { _, _, _, _ in [] }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            if reason == "reloadFramesAroundTimestamp" {
                tracker.reloadWindowFetches += 1
                return (0..<10).map { offset in
                    let id: Int64 = (offset == 9) ? 26 : Int64(500 + offset)
                    return self.makeFrameWithVideoInfo(
                        id: id,
                        timestamp: baseDate.addingTimeInterval(120 + TimeInterval(offset)),
                        frameIndex: offset,
                        bundleID: "com.apple.Safari"
                    )
                }
            }

            if reason.contains("loadNewerFrames.reason=reloadFramesAroundTimestamp")
                || reason.contains("loadNewerFrames.reason=navigateToUndoPosition.postReloadFramePin") {
                tracker.postReloadNewerLoadAttempts += 1
                return [
                    self.makeFrameWithVideoInfo(
                        id: 999,
                        timestamp: baseDate.addingTimeInterval(600),
                        frameIndex: 99,
                        bundleID: "com.apple.Safari"
                    )
                ]
            }

            return []
        }

        // Simulate stale boundary state from a previous "hit end" pagination result.
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)

        // Undo should now go through slow path + shared reload, which resets boundary state.
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        try? await Task.sleep(for: .milliseconds(180), clock: .continuous)

        XCTAssertEqual(tracker.reloadWindowFetches, 1)
        XCTAssertGreaterThanOrEqual(tracker.postReloadNewerLoadAttempts, 1)
        XCTAssertTrue(viewModel.frames.contains(where: { $0.frame.id.value == 26 }))
    }

    private func makeTimelineFrame(id: Int64, frameIndex: Int, bundleID: String) -> TimelineFrame {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: baseDate.addingTimeInterval(TimeInterval(frameIndex)),
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeNode(id: Int, text: String, x: CGFloat = 0.1, y: CGFloat = 0.1) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: 0.3,
            height: 0.1,
            text: text
        )
    }
}

@MainActor
final class TimelineFilteredEmptyStateTests: XCTestCase {
    func testLoadMostRecentFrameClearsStaleFramesWhenFilteredResultsAreEmpty() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_300_000)

        viewModel.frames = [
            makeTimelineFrame(
                id: 1,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = NSImage(size: NSSize(width: 12, height: 12))
        viewModel.filterCriteria = FilterCriteria(selectedApps: ["com.google.Chrome"])

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, filters in
            XCTAssertGreaterThan(limit, 0)
            XCTAssertTrue(filters.hasActiveFilters)
            return []
        }

        await viewModel.loadMostRecentFrame()

        XCTAssertTrue(viewModel.frames.isEmpty)
        XCTAssertEqual(viewModel.currentIndex, 0)
        XCTAssertNil(viewModel.currentFrame)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(
            viewModel.error,
            "No frames found matching the current filters. Clear filters to see all frames."
        )
        XCTAssertFalse(viewModel.isLoading)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }
}

@MainActor
final class TimelineBoundaryOlderFallbackTests: XCTestCase {
    func testLoadOlderFramesFallsBackToNearestQueryAfterEmptyWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_400_000)
        var recordedCalls: [(limit: Int, startDate: Date?, endDate: Date?, reason: String)] = []

        viewModel.frames = [
            makeTimelineFrame(
                id: 10,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 11,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { timestamp, limit, filters, reason in
            recordedCalls.append((limit, filters.startDate, filters.endDate, reason))
            if limit == 25 {
                XCTAssertEqual(timestamp, baseDate)
                XCTAssertNotNil(filters.startDate)
                XCTAssertNotNil(filters.endDate)
                return []
            }

            XCTAssertEqual(limit, 50)
            XCTAssertNil(filters.startDate)
            XCTAssertNil(filters.endDate)
            XCTAssertTrue(reason.contains("nearestFallback"))

            return [
                self.makeFrameWithVideoInfo(
                    id: 8,
                    timestamp: baseDate.addingTimeInterval(-120),
                    frameIndex: 8,
                    bundleID: "com.apple.Rewind"
                ),
                self.makeFrameWithVideoInfo(
                    id: 7,
                    timestamp: baseDate.addingTimeInterval(-240),
                    frameIndex: 7,
                    bundleID: "com.apple.Rewind"
                )
            ]
        }

        await viewModel.test_loadOlderFrames()

        XCTAssertEqual(recordedCalls.count, 2)
        XCTAssertEqual(recordedCalls.map(\.limit), [25, 50])
        XCTAssertEqual(viewModel.frames.count, 4)
        XCTAssertEqual(viewModel.frames.first?.frame.id.value, 7)
        XCTAssertEqual(viewModel.frames[1].frame.id.value, 8)
        XCTAssertEqual(viewModel.currentIndex, 3)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreOlder)
        XCTAssertFalse(paginationState.hasReachedAbsoluteStart)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(
            frame: frame,
            videoInfo: nil,
            processingStatus: 2,
            videoCurrentTime: nil,
            scrollY: nil
        )
    }
}

@MainActor
final class TimelineBoundaryNewerFallbackTests: XCTestCase {
    func testLoadNewerFramesFallsBackToNearestQueryAfterEmptyWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_500_000)
        var recordedWindowCalls: [(from: Date, to: Date, limit: Int, reason: String)] = []
        var recordedAfterCalls: [(timestamp: Date, limit: Int, startDate: Date?, endDate: Date?, reason: String)] = []

        viewModel.frames = [
            makeTimelineFrame(
                id: 20,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 21,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { from, to, limit, _, reason in
            recordedWindowCalls.append((from, to, limit, reason))
            XCTAssertEqual(limit, 25)
            XCTAssertTrue(reason.contains("loadNewerFrames.reason=test"))
            return []
        }

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoAfter = { timestamp, limit, filters, reason in
            recordedAfterCalls.append((timestamp, limit, filters.startDate, filters.endDate, reason))
            XCTAssertEqual(timestamp, baseDate.addingTimeInterval(1))
            XCTAssertEqual(limit, 50)
            XCTAssertNil(filters.startDate)
            XCTAssertNil(filters.endDate)
            XCTAssertTrue(reason.contains("nearestFallback"))

            return [
                self.makeFrameWithVideoInfo(
                    id: 22,
                    timestamp: baseDate.addingTimeInterval(120),
                    frameIndex: 2,
                    bundleID: "com.apple.Retrace"
                ),
                self.makeFrameWithVideoInfo(
                    id: 23,
                    timestamp: baseDate.addingTimeInterval(240),
                    frameIndex: 3,
                    bundleID: "com.apple.Retrace"
                )
            ]
        }

        await viewModel.test_loadNewerFrames()

        XCTAssertEqual(recordedWindowCalls.count, 1)
        XCTAssertEqual(recordedWindowCalls.first?.limit, 25)
        XCTAssertEqual(recordedAfterCalls.count, 1)
        XCTAssertEqual(recordedAfterCalls.first?.limit, 50)
        XCTAssertEqual(viewModel.frames.count, 4)
        XCTAssertEqual(viewModel.frames[2].frame.id.value, 22)
        XCTAssertEqual(viewModel.frames[3].frame.id.value, 23)
        XCTAssertEqual(viewModel.currentIndex, 3)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreNewer)
        XCTAssertFalse(paginationState.hasReachedAbsoluteEnd)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(
            frame: frame,
            videoInfo: nil,
            processingStatus: 2,
            videoCurrentTime: nil,
            scrollY: nil
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

private actor AsyncTestGate {
    private var didEnter = false
    private var enterContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        enterContinuation?.resume()
        enterContinuation = nil

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if didEnter {
            return
        }

        await withCheckedContinuation { continuation in
            enterContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class TimelineProcessingStatusRefreshConcurrencyTests: XCTestCase {
    func testRefreshProcessingStatusesSkipsSafelyWhenFrameRemovedDuringAwait() async {
        let viewModel = makeViewModelWithFrames(ids: [1, 2, 3], status: 1)
        let gate = AsyncTestGate()

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
        let gate = AsyncTestGate()

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

@MainActor
final class CommandDragTextSelectionTests: XCTestCase {
    func testCommandDragSelectsIntersectingNodesWithFullRanges() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Alpha", x: 0.10, y: 0.10, width: 0.20, height: 0.08),
            makeNode(id: 2, text: "Beta", x: 0.36, y: 0.12, width: 0.22, height: 0.08),
            makeNode(id: 3, text: "Gamma", x: 0.70, y: 0.12, width: 0.18, height: 0.08)
        ]

        viewModel.startDragSelection(at: CGPoint(x: 0.18, y: 0.09), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.56, y: 0.24), mode: .box)
        viewModel.endDragSelection()

        XCTAssertEqual(viewModel.boxSelectedNodeIDs, Set([1, 2]))

        let firstRange = viewModel.getSelectionRange(for: 1)
        let secondRange = viewModel.getSelectionRange(for: 2)
        let thirdRange = viewModel.getSelectionRange(for: 3)

        XCTAssertEqual(firstRange?.start, 0)
        XCTAssertEqual(firstRange?.end, "Alpha".count)
        XCTAssertEqual(secondRange?.start, 0)
        XCTAssertEqual(secondRange?.end, "Beta".count)
        XCTAssertNil(thirdRange)
        XCTAssertEqual(viewModel.selectedText, "Alpha Beta")
    }

    func testCommandDragIncludesNodeTouchingSelectionBoundary() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 9, text: "Edge", x: 0.60, y: 0.20, width: 0.20, height: 0.10)
        ]

        // Rectangle maxX/maxY land exactly on node minX/minY, which should still count as touching.
        viewModel.startDragSelection(at: CGPoint(x: 0.20, y: 0.10), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.60, y: 0.20), mode: .box)

        XCTAssertEqual(viewModel.boxSelectedNodeIDs, Set([9]))
        XCTAssertEqual(viewModel.getSelectionRange(for: 9)?.start, 0)
        XCTAssertEqual(viewModel.getSelectionRange(for: 9)?.end, "Edge".count)
    }

    func testClearTextSelectionResetsCommandDragSelection() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 4, text: "Reset me", x: 0.25, y: 0.25, width: 0.30, height: 0.10)
        ]

        viewModel.startDragSelection(at: CGPoint(x: 0.20, y: 0.20), mode: .box)
        viewModel.updateDragSelection(to: CGPoint(x: 0.40, y: 0.30), mode: .box)
        XCTAssertTrue(viewModel.hasSelection)

        viewModel.clearTextSelection()

        XCTAssertTrue(viewModel.boxSelectedNodeIDs.isEmpty)
        XCTAssertFalse(viewModel.hasSelection)
        XCTAssertEqual(viewModel.selectedText, "")
    }

    private func makeNode(
        id: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: width,
            height: height,
            text: text
        )
    }
}
