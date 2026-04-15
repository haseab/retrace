import AppKit
import Foundation
import Shared
import SwiftUI

@MainActor
final class TimelineCommentAllCommentsFlowController {
    static func makeEnvironment(
        viewModel: SimpleTimelineViewModel,
        sessionController: TimelineCommentAllCommentsSessionController,
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        pageSize: Int,
        allCommentsState: TimelineCommentAllCommentsDerivedState,
        setSearchFieldFocused: @escaping (Bool) -> Void,
        proxy: ScrollViewProxy?
    ) -> TimelineCommentAllCommentsFlowEnvironment {
        TimelineCommentAllCommentsFlowEnvironment(
            sessionController: sessionController,
            browserController: browserController,
            windowController: windowController,
            pageSize: pageSize,
            currentAnchorID: { allCommentsState.anchorID },
            anchorIndex: { allCommentsState.anchorIndex },
            totalRowCount: { viewModel.commentTimelineRows.count },
            selectedCommentIDs: { Set(viewModel.selectedBlockComments.map(\.id)) },
            rowIDs: { viewModel.commentTimelineRows.map(\.id) },
            visibleRowIDs: { allCommentsState.visibleRows.map(\.id) },
            availableBeforeCount: { allCommentsState.availableBeforeCount },
            availableAfterCount: { allCommentsState.availableAfterCount },
            hasMoreOlderPages: { viewModel.commentTimelineHasOlder },
            hasMoreNewerPages: { viewModel.commentTimelineHasNewer },
            isLoadingTimeline: { viewModel.isLoadingCommentTimeline },
            isLoadingOlderPage: { viewModel.isLoadingOlderCommentTimeline },
            isLoadingNewerPage: { viewModel.isLoadingNewerCommentTimeline },
            setSearchFieldFocused: setSearchFieldFocused,
            resetSearch: { viewModel.resetCommentSearchState() },
            resetTimeline: { viewModel.resetCommentTimelineState() },
            loadTimeline: { anchorComment in
                await viewModel.loadCommentTimeline(anchoredAt: anchorComment)
            },
            loadOlderPage: { await viewModel.loadOlderCommentTimelinePage() },
            loadNewerPage: { await viewModel.loadNewerCommentTimelinePage() },
            performScrollRequest: { request in
                guard let proxy else { return }
                performScrollRequest(request, proxy: proxy)
            }
        )
    }

    static func performScrollRequest(
        _ request: TimelineCommentAllCommentsScrollRequest,
        proxy: ScrollViewProxy
    ) {
        switch request {
        case .none:
            return
        case let .scrollTo(commentID, animated):
            DispatchQueue.main.async {
                if animated {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(commentID, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(commentID, anchor: .center)
                }
            }
        }
    }

    func syncOnAppear(environment: TimelineCommentAllCommentsFlowEnvironment) {
        syncVisibleWindow(forceReset: true, environment: environment)
        performInitialAndPinnedScrollRequests(environment: environment)
    }

    func syncOnTimelineRowCountChange(environment: TimelineCommentAllCommentsFlowEnvironment) {
        syncVisibleWindow(forceReset: false, environment: environment)

        if environment.isLoadingTimeline()
            || environment.isLoadingOlderPage()
            || environment.isLoadingNewerPage() {
            environment.sessionController.pinAnchorForNextViewportUpdate(
                browserController: environment.browserController,
                windowController: environment.windowController,
                anchorID: environment.currentAnchorID()
            )
        }

        performInitialAndPinnedScrollRequests(environment: environment)
    }

    func restorePinnedAnchor(environment: TimelineCommentAllCommentsFlowEnvironment) {
        environment.performScrollRequest(
            environment.sessionController.restorePinnedAnchorRequest(
                browserController: environment.browserController,
                windowController: environment.windowController,
                visibleRowIDs: environment.visibleRowIDs()
            )
        )
    }

    func openAllComments(
        anchoredAt comment: SegmentComment?,
        environment: TimelineCommentAllCommentsFlowEnvironment
    ) {
        environment.resetSearch()
        environment.setSearchFieldFocused(false)
        environment.sessionController.openAllComments(
            anchorID: comment?.id,
            browserController: environment.browserController,
            windowController: environment.windowController
        )

        Task { @MainActor in
            await environment.loadTimeline(comment)
            self.syncVisibleWindow(forceReset: true, environment: environment)
        }
    }

    func exitAllComments(environment: TimelineCommentAllCommentsFlowEnvironment) {
        environment.sessionController.exitAllComments(
            browserController: environment.browserController,
            windowController: environment.windowController
        )
        environment.setSearchFieldFocused(false)
        environment.resetTimeline()
    }

    func handleVisibleRowAppear(
        _ row: CommentTimelineRow,
        environment: TimelineCommentAllCommentsFlowEnvironment
    ) {
        guard environment.browserController.isBrowsingAllComments else { return }

        let visibleRowIDs = environment.visibleRowIDs()
        guard !visibleRowIDs.isEmpty else { return }

        if row.id == visibleRowIDs.first {
            requestOlderPageIfNeeded(environment: environment)
        }

        if row.id == visibleRowIDs.last {
            requestNewerPageIfNeeded(environment: environment)
        }
    }

    private func syncVisibleWindow(
        forceReset: Bool,
        environment: TimelineCommentAllCommentsFlowEnvironment
    ) {
        environment.sessionController.syncVisibleWindow(
            browserController: environment.browserController,
            windowController: environment.windowController,
            forceReset: forceReset,
            anchorIndex: environment.anchorIndex(),
            totalRowCount: environment.totalRowCount(),
            selectedCommentIDs: environment.selectedCommentIDs(),
            rowIDs: environment.rowIDs(),
            pageSize: environment.pageSize
        )
    }

    private func performInitialAndPinnedScrollRequests(
        environment: TimelineCommentAllCommentsFlowEnvironment
    ) {
        environment.performScrollRequest(
            environment.sessionController.initialScrollRequest(
                browserController: environment.browserController,
                windowController: environment.windowController,
                anchorID: environment.currentAnchorID(),
                visibleRowIDs: environment.visibleRowIDs()
            )
        )
        environment.performScrollRequest(
            environment.sessionController.restorePinnedAnchorRequest(
                browserController: environment.browserController,
                windowController: environment.windowController,
                visibleRowIDs: environment.visibleRowIDs()
            )
        )
    }

    private func requestOlderPageIfNeeded(environment: TimelineCommentAllCommentsFlowEnvironment) {
        let action = environment.sessionController.requestOlderPage(
            browserController: environment.browserController,
            windowController: environment.windowController,
            availableBeforeCount: environment.availableBeforeCount(),
            pageSize: environment.pageSize,
            hasMorePages: environment.hasMoreOlderPages(),
            isLoadingPage: environment.isLoadingOlderPage(),
            anchorID: environment.currentAnchorID()
        )

        guard action == .loadOlderPage else { return }

        Task { @MainActor in
            await environment.loadOlderPage()
            self.syncVisibleWindow(forceReset: false, environment: environment)
            environment.sessionController.finishOlderPageLoad(
                windowController: environment.windowController,
                refreshedAvailableBeforeCount: environment.availableBeforeCount(),
                pageSize: environment.pageSize,
                anchorID: environment.currentAnchorID()
            )
        }
    }

    private func requestNewerPageIfNeeded(environment: TimelineCommentAllCommentsFlowEnvironment) {
        let action = environment.sessionController.requestNewerPage(
            browserController: environment.browserController,
            windowController: environment.windowController,
            availableAfterCount: environment.availableAfterCount(),
            pageSize: environment.pageSize,
            hasMorePages: environment.hasMoreNewerPages(),
            isLoadingPage: environment.isLoadingNewerPage(),
            anchorID: environment.currentAnchorID()
        )

        guard action == .loadNewerPage else { return }

        Task { @MainActor in
            await environment.loadNewerPage()
            self.syncVisibleWindow(forceReset: false, environment: environment)
            environment.sessionController.finishNewerPageLoad(
                windowController: environment.windowController,
                refreshedAvailableAfterCount: environment.availableAfterCount(),
                pageSize: environment.pageSize,
                anchorID: environment.currentAnchorID()
            )
        }
    }
}

@MainActor
struct TimelineCommentAllCommentsSessionController {
    func openAllComments(
        anchorID: SegmentCommentID?,
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController
    ) {
        windowController.prepareAllComments(anchorID: anchorID)
        browserController.enterAllComments()
    }

    func exitAllComments(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController
    ) {
        browserController.exitAllComments()
        windowController.resetForThread()
    }

    func syncVisibleWindow(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        forceReset: Bool,
        anchorIndex: Int?,
        totalRowCount: Int,
        selectedCommentIDs: Set<SegmentCommentID>,
        rowIDs: [SegmentCommentID],
        pageSize: Int
    ) {
        guard browserController.isBrowsingAllComments else { return }
        windowController.syncVisibleWindow(
            forceReset: forceReset,
            anchorIndex: anchorIndex,
            totalRowCount: totalRowCount,
            selectedCommentIDs: selectedCommentIDs,
            rowIDs: rowIDs,
            pageSize: pageSize
        )
    }

    func initialScrollRequest(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        anchorID: SegmentCommentID?,
        visibleRowIDs: [SegmentCommentID]
    ) -> TimelineCommentAllCommentsScrollRequest {
        guard let anchorID = windowController.initialScrollAnchorIfNeeded(
            isBrowsingAllComments: browserController.isBrowsingAllComments,
            anchorID: anchorID,
            visibleRowIDs: visibleRowIDs
        ) else {
            return .none
        }

        return .scrollTo(anchorID, animated: true)
    }

    func restorePinnedAnchorRequest(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        visibleRowIDs: [SegmentCommentID]
    ) -> TimelineCommentAllCommentsScrollRequest {
        guard let pinnedID = windowController.consumePinnedAnchorIfVisible(
            isBrowsingAllComments: browserController.isBrowsingAllComments,
            visibleRowIDs: visibleRowIDs
        ) else {
            return .none
        }

        return .scrollTo(pinnedID, animated: false)
    }

    func pinAnchorForNextViewportUpdate(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        anchorID: SegmentCommentID?
    ) {
        guard browserController.isBrowsingAllComments else { return }
        windowController.pinAnchorForNextViewportUpdate(anchorID)
    }

    func requestOlderPage(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        availableBeforeCount: Int,
        pageSize: Int,
        hasMorePages: Bool,
        isLoadingPage: Bool,
        anchorID: SegmentCommentID?
    ) -> TimelineCommentAllCommentsPageLoadPlan {
        guard browserController.isBrowsingAllComments else { return .none }

        switch windowController.requestOlderPageAction(
            availableBeforeCount: availableBeforeCount,
            pageSize: pageSize,
            hasMorePages: hasMorePages,
            isLoadingPage: isLoadingPage,
            anchorID: anchorID
        ) {
        case .none:
            return .none
        case .expandedWindow:
            return .expandedWindow
        case .loadPage:
            return .loadOlderPage
        }
    }

    func finishOlderPageLoad(
        windowController: TimelineCommentBrowserWindowController,
        refreshedAvailableBeforeCount: Int,
        pageSize: Int,
        anchorID: SegmentCommentID?
    ) {
        defer { windowController.finishOlderPageRequest() }
        guard windowController.visibleBeforeCount < refreshedAvailableBeforeCount else { return }

        _ = windowController.requestOlderPageAction(
            availableBeforeCount: refreshedAvailableBeforeCount,
            pageSize: pageSize,
            hasMorePages: false,
            isLoadingPage: false,
            anchorID: anchorID
        )
    }

    func requestNewerPage(
        browserController: TimelineCommentSubmenuBrowserController,
        windowController: TimelineCommentBrowserWindowController,
        availableAfterCount: Int,
        pageSize: Int,
        hasMorePages: Bool,
        isLoadingPage: Bool,
        anchorID: SegmentCommentID?
    ) -> TimelineCommentAllCommentsPageLoadPlan {
        guard browserController.isBrowsingAllComments else { return .none }

        switch windowController.requestNewerPageAction(
            availableAfterCount: availableAfterCount,
            pageSize: pageSize,
            hasMorePages: hasMorePages,
            isLoadingPage: isLoadingPage,
            anchorID: anchorID
        ) {
        case .none:
            return .none
        case .expandedWindow:
            return .expandedWindow
        case .loadPage:
            return .loadNewerPage
        }
    }

    func finishNewerPageLoad(
        windowController: TimelineCommentBrowserWindowController,
        refreshedAvailableAfterCount: Int,
        pageSize: Int,
        anchorID: SegmentCommentID?
    ) {
        defer { windowController.finishNewerPageRequest() }
        guard windowController.visibleAfterCount < refreshedAvailableAfterCount else { return }

        _ = windowController.requestNewerPageAction(
            availableAfterCount: refreshedAvailableAfterCount,
            pageSize: pageSize,
            hasMorePages: false,
            isLoadingPage: false,
            anchorID: anchorID
        )
    }
}

@MainActor
final class TimelineCommentBrowserWindowController: ObservableObject {
    @Published var anchorID: SegmentCommentID?
    @Published var visibleBeforeCount = 0
    @Published var visibleAfterCount = 0
    @Published var hasPerformedInitialScroll = false
    @Published var isRequestingOlderPage = false
    @Published var isRequestingNewerPage = false
    @Published var pendingAnchorPinnedCommentID: SegmentCommentID?

    func apply(_ state: TimelineCommentBrowserWindowState) {
        anchorID = state.anchorID
        visibleBeforeCount = state.visibleBeforeCount
        visibleAfterCount = state.visibleAfterCount
        hasPerformedInitialScroll = state.hasPerformedInitialScroll
        isRequestingOlderPage = state.isRequestingOlderPage
        isRequestingNewerPage = state.isRequestingNewerPage
        pendingAnchorPinnedCommentID = state.pendingAnchorPinnedCommentID
    }

    func snapshot() -> TimelineCommentBrowserWindowState {
        TimelineCommentBrowserWindowState(
            anchorID: anchorID,
            visibleBeforeCount: visibleBeforeCount,
            visibleAfterCount: visibleAfterCount,
            hasPerformedInitialScroll: hasPerformedInitialScroll,
            isRequestingOlderPage: isRequestingOlderPage,
            isRequestingNewerPage: isRequestingNewerPage,
            pendingAnchorPinnedCommentID: pendingAnchorPinnedCommentID
        )
    }

    func resetForThread() {
        apply(TimelineCommentBrowserWindowSupport.makeThreadState())
    }

    func prepareAllComments(anchorID: SegmentCommentID?) {
        apply(TimelineCommentBrowserWindowSupport.makeAllCommentsState(anchorID: anchorID))
    }

    func syncVisibleWindow(
        forceReset: Bool,
        anchorIndex: Int?,
        totalRowCount: Int,
        selectedCommentIDs: Set<SegmentCommentID>,
        rowIDs: [SegmentCommentID],
        pageSize: Int
    ) {
        guard let visibleCounts = TimelineCommentBrowserWindowSupport.syncedVisibleCounts(
            forceReset: forceReset,
            anchorIndex: anchorIndex,
            totalRowCount: totalRowCount,
            currentBeforeCount: visibleBeforeCount,
            currentAfterCount: visibleAfterCount,
            selectedCommentIDs: selectedCommentIDs,
            rowIDs: rowIDs,
            pageSize: pageSize
        ) else {
            return
        }

        visibleBeforeCount = visibleCounts.before
        visibleAfterCount = visibleCounts.after
    }

    func initialScrollAnchorIfNeeded(
        isBrowsingAllComments: Bool,
        anchorID: SegmentCommentID?,
        visibleRowIDs: [SegmentCommentID]
    ) -> SegmentCommentID? {
        guard isBrowsingAllComments,
              !hasPerformedInitialScroll,
              let anchorID,
              visibleRowIDs.contains(anchorID) else {
            return nil
        }

        hasPerformedInitialScroll = true
        return anchorID
    }

    func consumePinnedAnchorIfVisible(
        isBrowsingAllComments: Bool,
        visibleRowIDs: [SegmentCommentID]
    ) -> SegmentCommentID? {
        guard isBrowsingAllComments,
              let pinnedID = pendingAnchorPinnedCommentID,
              visibleRowIDs.contains(pinnedID) else {
            return nil
        }

        pendingAnchorPinnedCommentID = nil
        return pinnedID
    }

    func pinAnchorForNextViewportUpdate(_ anchorID: SegmentCommentID?) {
        guard let anchorID else { return }
        pendingAnchorPinnedCommentID = anchorID
    }

    func requestOlderPageAction(
        availableBeforeCount: Int,
        pageSize: Int,
        hasMorePages: Bool,
        isLoadingPage: Bool,
        anchorID: SegmentCommentID?
    ) -> TimelineCommentBrowserPageRequestAction {
        if visibleBeforeCount < availableBeforeCount {
            pinAnchorForNextViewportUpdate(anchorID)
            visibleBeforeCount = TimelineCommentBrowserWindowSupport.expandedVisibleBeforeCount(
                currentBeforeCount: visibleBeforeCount,
                availableBeforeCount: availableBeforeCount,
                pageSize: pageSize
            )
            return .expandedWindow
        }

        guard hasMorePages, !isLoadingPage, !isRequestingOlderPage else {
            return .none
        }

        isRequestingOlderPage = true
        pinAnchorForNextViewportUpdate(anchorID)
        return .loadPage
    }

    func requestNewerPageAction(
        availableAfterCount: Int,
        pageSize: Int,
        hasMorePages: Bool,
        isLoadingPage: Bool,
        anchorID: SegmentCommentID?
    ) -> TimelineCommentBrowserPageRequestAction {
        if visibleAfterCount < availableAfterCount {
            pinAnchorForNextViewportUpdate(anchorID)
            visibleAfterCount = TimelineCommentBrowserWindowSupport.expandedVisibleAfterCount(
                currentAfterCount: visibleAfterCount,
                availableAfterCount: availableAfterCount,
                pageSize: pageSize
            )
            return .expandedWindow
        }

        guard hasMorePages, !isLoadingPage, !isRequestingNewerPage else {
            return .none
        }

        isRequestingNewerPage = true
        pinAnchorForNextViewportUpdate(anchorID)
        return .loadPage
    }

    func finishOlderPageRequest() {
        isRequestingOlderPage = false
    }

    func finishNewerPageRequest() {
        isRequestingNewerPage = false
    }
}
