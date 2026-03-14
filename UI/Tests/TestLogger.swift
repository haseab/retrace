import XCTest
import AppKit
import Combine
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

    func testRefreshFrameDataTreatsStaleLoadedTapeAsHistoricalEvenNearLoadedEdge() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_200_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 2
            )
        }
        viewModel.currentIndex = 95

        let originalFrameIDs = viewModel.frames.map(\.frame.id.value)
        let originalNewestTimestamp = viewModel.frames.last?.frame.timestamp
        var fetchInvocationCount = 0

        viewModel.test_refreshFrameDataHooks.now = {
            baseDate.addingTimeInterval(10 * 24 * 60 * 60)
        }
        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            fetchInvocationCount += 1
            return []
        }

        await viewModel.refreshFrameData(
            navigateToNewest: false,
            allowNearLiveAutoAdvance: true,
            refreshPresentation: false
        )

        XCTAssertEqual(fetchInvocationCount, 0)
        XCTAssertEqual(viewModel.currentIndex, 95)
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

    func testShouldDismissTimelineWithCommandW() {
        XCTAssertTrue(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 13,
                charactersIgnoringModifiers: "w",
                modifiers: [.command]
            )
        )
    }

    func testShouldNotDismissTimelineWithExtraModifierOrWrongKey() {
        XCTAssertFalse(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 13,
                charactersIgnoringModifiers: "w",
                modifiers: [.command, .shift]
            )
        )
        XCTAssertFalse(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 14,
                charactersIgnoringModifiers: "e",
                modifiers: [.command]
            )
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

@MainActor
final class DateJumpRelativeDayAnchoringTests: XCTestCase {
    func testDaysAgoUsesFirstFrameInResolvedDay() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        var anchoredTimestamp: Date?
        var sawDayAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInDay":
                sawDayAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertGreaterThan(end.timeIntervalSince(start), (24 * 60 * 60) - 1)
                let firstFrameInDay = start.addingTimeInterval(123)
                anchoredTimestamp = firstFrameInDay
                return [self.makeFrameWithVideoInfo(id: 7001, timestamp: firstFrameInDay, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected day anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(limit, 1000)
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7001, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("2 days ago")

        XCTAssertTrue(sawDayAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7001)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testDaysAgoPreservesAndAppliesActiveFilters() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let expectedFilters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        viewModel.filterCriteria = expectedFilters
        viewModel.pendingFilterCriteria = expectedFilters

        var anchorFilters: [FilterCriteria] = []
        var windowFilters: [FilterCriteria] = []
        var anchoredTimestamp: Date?

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, filters, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInDay":
                anchorFilters.append(filters)
                XCTAssertEqual(limit, 1)
                let firstFrameInDay = start.addingTimeInterval(90)
                anchoredTimestamp = firstFrameInDay
                return [self.makeFrameWithVideoInfo(id: 7101, timestamp: firstFrameInDay, processingStatus: 4)]

            case "searchForDate":
                windowFilters.append(filters)
                guard let anchoredTimestamp else {
                    XCTFail("Expected day anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7101, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 day ago")

        XCTAssertEqual(anchorFilters.count, 1)
        XCTAssertEqual(windowFilters.count, 1)
        XCTAssertEqual(anchorFilters.first?.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(windowFilters.first?.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(viewModel.filterCriteria.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(viewModel.pendingFilterCriteria.selectedApps, expectedFilters.selectedApps)
    }

    func testHoursAgoUsesFirstFrameInResolvedHourWithinActiveFilters() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let expectedFilters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        viewModel.filterCriteria = expectedFilters
        viewModel.pendingFilterCriteria = expectedFilters

        var sawHourAnchorFetch = false
        var sawWindowFetch = false
        var anchoredTimestamp: Date?

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, filters, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInHour":
                sawHourAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(filters.selectedApps, expectedFilters.selectedApps)
                XCTAssertGreaterThan(end.timeIntervalSince(start), (60 * 60) - 1)
                let firstFrameInHour = start.addingTimeInterval(45)
                anchoredTimestamp = firstFrameInHour
                return [self.makeFrameWithVideoInfo(id: 7201, timestamp: firstFrameInHour, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected hour anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(filters.selectedApps, expectedFilters.selectedApps)
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7201, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 hour ago")

        XCTAssertTrue(sawHourAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7201)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
        XCTAssertEqual(viewModel.filterCriteria.selectedApps, expectedFilters.selectedApps)
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
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

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
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(4)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

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
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

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
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(26)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

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

    func testNavigateToSearchResultAddsEachClickedResultToUndoHistory() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 2),
            timestamp: viewModel.frames[1].frame.timestamp,
            highlightQuery: "error"
        )
        XCTAssertEqual(viewModel.currentIndex, 1)

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 3),
            timestamp: viewModel.frames[2].frame.timestamp,
            highlightQuery: "error"
        )
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToSearchResultSlowPathRecordsUndoHistory() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            switch reason {
            case "navigateToSearchResult":
                return [
                    self.makeFrameWithVideoInfo(
                        id: 49,
                        timestamp: baseDate.addingTimeInterval(119),
                        frameIndex: 49,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 50,
                        timestamp: baseDate.addingTimeInterval(120),
                        frameIndex: 50,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 51,
                        timestamp: baseDate.addingTimeInterval(121),
                        frameIndex: 51,
                        bundleID: "com.apple.Safari"
                    )
                ]
            case "reloadFramesAroundTimestamp":
                return [
                    self.makeFrameWithVideoInfo(
                        id: 1,
                        timestamp: baseDate,
                        frameIndex: 0,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 2,
                        timestamp: baseDate.addingTimeInterval(1),
                        frameIndex: 1,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 3,
                        timestamp: baseDate.addingTimeInterval(2),
                        frameIndex: 2,
                        bundleID: "com.apple.Safari"
                    )
                ]
            default:
                return []
            }
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { _, _, _, _ in [] }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfoAfter = { _, _, _, _ in [] }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .completed }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 50),
            timestamp: baseDate.addingTimeInterval(120),
            highlightQuery: "error"
        )

        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 50)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        try? await Task.sleep(for: .milliseconds(50), clock: .continuous)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 2)
    }

    func testUndoAndRedoRestoreSearchResultHighlightQuery() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 2),
            timestamp: viewModel.frames[1].frame.timestamp,
            highlightQuery: "alpha"
        )
        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 3),
            timestamp: viewModel.frames[2].frame.timestamp,
            highlightQuery: "beta"
        )

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.searchHighlightQuery, "alpha")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)

        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertEqual(viewModel.searchHighlightQuery, "beta")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
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

    func testLoadOlderFramesFallsBackToNearestQueryAfterSparseWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_401_000)
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
                return [
                    self.makeFrameWithVideoInfo(
                        id: 9,
                        timestamp: baseDate.addingTimeInterval(-10),
                        frameIndex: 9,
                        bundleID: "com.apple.Rewind"
                    )
                ]
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

@MainActor
final class SystemMonitorPerformanceNudgeTests: XCTestCase {
    func testPerformanceNudgeShowsForBalancedWithoutPowerLimits() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = false
        viewModel.pauseOnLowPowerModeSetting = false

        XCTAssertTrue(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenWhenOnlyWhilePluggedInEnabled() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = true
        viewModel.pauseOnLowPowerModeSetting = false

        XCTAssertFalse(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenWhenLowPowerPauseEnabled() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = false
        viewModel.pauseOnLowPowerModeSetting = true

        XCTAssertFalse(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenForLightAndEfficiencyModes() {
        for level in [1, 2] {
            let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
            viewModel.ocrEnabled = true
            viewModel.isPausedForBattery = false
            viewModel.queueDepth = 100
            viewModel.ocrProcessingLevel = level
            viewModel.pauseOnBatterySetting = false
            viewModel.pauseOnLowPowerModeSetting = false

            XCTAssertFalse(viewModel.shouldShowPerformanceNudge, "Level \(level) should suppress the nudge")
        }
    }
}

@MainActor
final class SystemMonitorOCRMemoryAttributionTests: XCTestCase {
    func testOCRMemoryAttributionShowsWhenOCRIsActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 1
        viewModel.processingCount = 2

        XCTAssertTrue(viewModel.shouldShowOCRMemoryAttribution)
    }

    func testOCRMemoryAttributionShowsEvenWithNoBacklogWhenOCRIsActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 0
        viewModel.processingCount = 1

        XCTAssertTrue(viewModel.shouldShowOCRMemoryAttribution)
    }

    func testOCRMemoryAttributionHiddenWhenOCRIsNotActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.queueDepth = 24
        viewModel.processingCount = 0

        XCTAssertFalse(viewModel.shouldShowOCRMemoryAttribution)
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
final class TimelineHeadlessPrerenderStateTests: XCTestCase {
    func testSimpleTimelineViewOnAppearSkipsMostRecentReloadWhenFramesAlreadyExist() {
        XCTAssertFalse(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: false,
                frameCount: 100
            )
        )
        XCTAssertFalse(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: true,
                frameCount: 0
            )
        )
        XCTAssertTrue(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: false,
                frameCount: 0
            )
        )
    }

    func testLoadMostRecentFrameMetadataOnlyLeavesCurrentImageUntouched() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let sentinel = makeSolidImage(size: NSSize(width: 8, height: 8), color: .systemRed)
        viewModel.currentImage = sentinel

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 100)
            return [
                self.makeFrameWithVideoInfo(
                    id: 1,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_000),
                    frameIndex: 0
                ),
            ]
        }

        await viewModel.loadMostRecentFrame(refreshPresentation: false)

        XCTAssertTrue(viewModel.currentImage === sentinel)
        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testRefreshStaticPresentationIfNeededReloadsOCRForVideoBackedFrame() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 11),
                timestamp: Date(timeIntervalSince1970: 1_700_100_011),
                segmentID: AppSegmentID(value: 11),
                frameIndexInSegment: 4,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-video-backed.mp4",
                frameIndex: 4,
                frameRate: 30,
                width: 1920,
                height: 1080,
                isVideoFinalized: true
            ),
            processingStatus: 2
        )

        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        var ocrStatusLoads = 0
        var ocrNodeLoads = 0
        var frameImageLoads = 0
        let expectedNode = OCRNodeWithText(
            id: 99,
            frameId: timelineFrame.frame.id.value,
            x: 0.10,
            y: 0.20,
            width: 0.30,
            height: 0.08,
            text: "Launch OCR"
        )

        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { frameID in
            XCTAssertEqual(frameID, timelineFrame.frame.id)
            ocrStatusLoads += 1
            return .completed
        }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { frameID, source in
            XCTAssertEqual(frameID, timelineFrame.frame.id)
            XCTAssertEqual(source, .native)
            ocrNodeLoads += 1
            return [expectedNode]
        }
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            frameImageLoads += 1
            return Data()
        }

        viewModel.refreshStaticPresentationIfNeeded()

        for _ in 0..<20 {
            if viewModel.ocrNodes.count == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTAssertEqual(viewModel.ocrStatus, .completed)
        XCTAssertEqual(viewModel.ocrNodes, [expectedNode])
        XCTAssertEqual(ocrStatusLoads, 1)
        XCTAssertEqual(ocrNodeLoads, 1)
        XCTAssertEqual(frameImageLoads, 0)
    }

    func testForegroundPresentationLoadCachesVideoBackedFramesInDiskBuffer() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 42),
                timestamp: Date(timeIntervalSince1970: 1_700_100_042),
                segmentID: AppSegmentID(value: 42),
                frameIndexInSegment: 12,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-video.mp4",
                frameIndex: 12,
                frameRate: 30,
                width: 32,
                height: 24
            ),
            processingStatus: 2
        )

        let expectedImage = makeSolidImage(size: NSSize(width: 32, height: 24), color: .systemPurple)
        let expectedImageData = try XCTUnwrap(expectedImage.tiffRepresentation)
        var dataLoads = 0

        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { frame in
            XCTAssertEqual(frame.frame.id, timelineFrame.frame.id)
            dataLoads += 1
            return expectedImageData
        }

        let firstImage = try await viewModel.test_loadForegroundPresentationImage(timelineFrame)
        let secondImage = try await viewModel.test_loadForegroundPresentationImage(timelineFrame)

        XCTAssertEqual(dataLoads, 1)
        XCTAssertNotNil(firstImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotNil(secondImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testCompactPresentationStateClearsPresentationPayloadsButPreservesTimelineState() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "test.app"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "test.app"),
        ]
        viewModel.currentIndex = 1
        viewModel.searchViewModel.searchQuery = "test query"
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 12, height: 12), color: .systemBlue)
        viewModel.liveScreenshot = makeSolidImage(size: NSSize(width: 10, height: 10), color: .systemGreen)
        viewModel.shiftDragDisplaySnapshot = makeSolidImage(size: NSSize(width: 6, height: 6), color: .systemOrange)
        viewModel.shiftDragDisplaySnapshotFrameID = 2
        viewModel.forceVideoReload = true
        viewModel.isInLiveMode = true
        XCTAssertNotNil(viewModel.currentImage)
        XCTAssertNotNil(viewModel.liveScreenshot)
        XCTAssertNotNil(viewModel.shiftDragDisplaySnapshot)

        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)

        XCTAssertEqual(viewModel.frames.count, 2)
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.searchViewModel.searchQuery, "test query")
        XCTAssertNil(viewModel.currentImage)
        XCTAssertNil(viewModel.liveScreenshot)
        XCTAssertNil(viewModel.shiftDragDisplaySnapshot)
        XCTAssertNil(viewModel.shiftDragDisplaySnapshotFrameID)
        XCTAssertFalse(viewModel.forceVideoReload)
        XCTAssertFalse(viewModel.isInLiveMode)
    }

    func testInFlightMostRecentLoadDoesNotRebuildPresentationAfterCompaction() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        let frameImageData = try XCTUnwrap(
            makeSolidImage(size: NSSize(width: 16, height: 16), color: .systemTeal).tiffRepresentation
        )
        let fetchStarted = expectation(description: "most recent fetch started")
        var releaseFetch: CheckedContinuation<Void, Never>?
        var dataLoads = 0

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            fetchStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseFetch = continuation
            }
            return [
                self.makeFrameWithVideoInfo(
                    id: 77,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_077),
                    frameIndex: 3
                ),
            ]
        }
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return frameImageData
        }

        let loadTask = Task {
            await viewModel.loadMostRecentFrame()
        }

        await fulfillment(of: [fetchStarted], timeout: 1.0)
        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)
        releaseFetch?.resume()
        await loadTask.value

        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(dataLoads, 0)
    }

    func testHiddenRefreshAfterCompactionStaysMetadataOnly() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "test.app"),
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 12, height: 12), color: .systemPink)

        let frameImageData = try XCTUnwrap(
            makeSolidImage(size: NSSize(width: 16, height: 16), color: .systemIndigo).tiffRepresentation
        )
        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return frameImageData
        }
        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            [
                self.makeFrameWithVideoInfo(
                    id: 2,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_100),
                    frameIndex: 1
                ),
            ]
        }

        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)
        await viewModel.refreshFrameData(
            navigateToNewest: true,
            allowNearLiveAutoAdvance: true,
            refreshPresentation: false
        )

        XCTAssertEqual(viewModel.frames.count, 2)
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(dataLoads, 0)
    }

    private func makeTimelineFrame(id: Int64, frameIndex: Int, bundleID: String) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: Date(timeIntervalSince1970: 1_700_100_000 + Double(frameIndex)),
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

    private func makeFrameWithVideoInfo(id: Int64, timestamp: Date, frameIndex: Int) -> FrameWithVideoInfo {
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
        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeSolidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
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

@MainActor
final class DeveloperFrameIDToggleTests: XCTestCase {
    func testToggleFrameIDBadgeVisibilityFromDevMenuPersistsShowFrameIDsSetting() {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let originalValue = defaults.object(forKey: "showFrameIDs")
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: "showFrameIDs")
            } else {
                defaults.removeObject(forKey: "showFrameIDs")
            }
        }

        defaults.set(false, forKey: "showFrameIDs")

        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
        XCTAssertTrue(defaults.bool(forKey: "showFrameIDs"))
        XCTAssertTrue(viewModel.showFrameIDs)

        viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
        XCTAssertFalse(defaults.bool(forKey: "showFrameIDs"))
        XCTAssertFalse(viewModel.showFrameIDs)
    }
}
