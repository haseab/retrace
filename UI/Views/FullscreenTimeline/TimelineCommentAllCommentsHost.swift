import AppKit
import Foundation
import SwiftUI
import Shared

struct TimelineCommentAllCommentsHost: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @ObservedObject var submenuBrowserController: TimelineCommentSubmenuBrowserController
    @ObservedObject var windowController: TimelineCommentBrowserWindowController
    let sectionCornerRadius: CGFloat
    let pageSize: Int
    let dateFormatter: DateFormatter
    let searchFieldFocus: FocusState<Bool>.Binding
    let sessionController: TimelineCommentAllCommentsSessionController
    let flowController: TimelineCommentAllCommentsFlowController
    let openLinkedComment: (SegmentComment, SegmentID?) -> Void

    @State private var hoveredRowID: SegmentCommentID?

    private var hasActiveCommentSearch: Bool {
        !viewModel.commentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commentSearchBinding: Binding<String> {
        Binding(
            get: { viewModel.commentSearchText },
            set: { viewModel.updateCommentSearchQuery($0) }
        )
    }

    private var allCommentsState: TimelineCommentAllCommentsDerivedState {
        TimelineCommentAllCommentsDerivedStateSupport.make(
            rows: viewModel.commentTimelineRows,
            explicitAnchorID: windowController.anchorID,
            fallbackAnchorID: viewModel.commentTimelineAnchorCommentID,
            visibleBeforeCount: windowController.visibleBeforeCount,
            visibleAfterCount: windowController.visibleAfterCount
        )
    }

    private var keyboardState: TimelineCommentSubmenuKeyboardState {
        TimelineCommentSubmenuKeyboardState(
            isBrowsingAllComments: submenuBrowserController.isBrowsingAllComments,
            hasPendingDeleteConfirmation: false,
            isTagSubmenuVisible: viewModel.showTagSubmenu,
            isLinkPopoverPresented: false,
            isSearchFieldFocused: searchFieldFocus.wrappedValue,
            hasActiveCommentSearch: hasActiveCommentSearch,
            searchResults: viewModel.commentSearchResults,
            visibleRows: allCommentsState.visibleRows,
            preferredAnchorID: allCommentsState.anchorID
        )
    }

    private var allCommentsCountLabel: String {
        "All Comments (\(viewModel.commentTimelineRows.count))"
    }

    var body: some View {
        TimelineCommentAllCommentsSection(
            viewModel: viewModel,
            sectionCornerRadius: sectionCornerRadius,
            hasActiveCommentSearch: hasActiveCommentSearch,
            allCommentsCountLabel: allCommentsCountLabel,
            commentSearchBinding: commentSearchBinding,
            searchFieldFocus: searchFieldFocus,
            visibleRows: allCommentsState.visibleRows,
            highlightedCommentSearchResultID: submenuBrowserController.highlightedCommentID,
            allCommentsVisibleBeforeCount: windowController.visibleBeforeCount,
            allCommentsVisibleAfterCount: windowController.visibleAfterCount,
            pendingAnchorPinnedCommentID: windowController.pendingAnchorPinnedCommentID,
            rowContent: allCommentsTimelineCard,
            onVisibleRowAppear: handleVisibleRowAppear,
            onSearchResultAppear: { row in
                viewModel.loadMoreCommentSearchResultsIfNeeded(currentCommentID: row.id)
            },
            onSubmitSearch: {
                _ = TimelineCommentSubmenuKeyboardController.openHighlightedSelection(
                    browserController: submenuBrowserController,
                    state: keyboardState,
                    openComment: openLinkedComment
                )
            },
            onClearSearch: {
                viewModel.updateCommentSearchQuery("")
            },
            onRetrySearch: {
                viewModel.retryCommentSearch()
            },
            onAllCommentsAppear: { proxy in
                flowController.syncOnAppear(
                    environment: allCommentsFlowEnvironment(proxy: proxy)
                )
            },
            onTimelineRowCountChange: { proxy in
                flowController.syncOnTimelineRowCountChange(
                    environment: allCommentsFlowEnvironment(proxy: proxy)
                )
            },
            onVisibleBeforeCountChange: { proxy in
                flowController.restorePinnedAnchor(
                    environment: allCommentsFlowEnvironment(proxy: proxy)
                )
            },
            onVisibleAfterCountChange: { proxy in
                flowController.restorePinnedAnchor(
                    environment: allCommentsFlowEnvironment(proxy: proxy)
                )
            },
            onPendingAnchorPinnedChange: { proxy in
                flowController.restorePinnedAnchor(
                    environment: allCommentsFlowEnvironment(proxy: proxy)
                )
            },
            onHighlightedIDChange: { proxy, selectedID in
                guard let selectedID else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        )
    }

    private func handleVisibleRowAppear(_ row: CommentTimelineRow) {
        flowController.handleVisibleRowAppear(
            row,
            environment: allCommentsFlowEnvironment()
        )
    }

    private func allCommentsTimelineCard(_ row: CommentTimelineRow) -> some View {
        let presentation = TimelineCommentPresentationSupport.makeAllCommentsCardPresentation(
            row: row,
            anchorID: allCommentsState.anchorID,
            highlightedID: submenuBrowserController.highlightedCommentID,
            dateFormatter: dateFormatter
        )

        return TimelineAllCommentsCard(
            presentation: presentation,
            isHovered: hoveredRowID == row.id
        ) {
            openLinkedComment(row.comment, row.context?.segmentID)
        } onHoverChanged: { hovering in
            if hovering {
                hoveredRowID = row.id
                submenuBrowserController.setHighlightedCommentID(row.id)
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
    }

    private func allCommentsFlowEnvironment(
        proxy: ScrollViewProxy? = nil
    ) -> TimelineCommentAllCommentsFlowEnvironment {
        TimelineCommentAllCommentsFlowController.makeEnvironment(
            viewModel: viewModel,
            sessionController: sessionController,
            browserController: submenuBrowserController,
            windowController: windowController,
            pageSize: pageSize,
            allCommentsState: allCommentsState,
            setSearchFieldFocused: {
                searchFieldFocus.wrappedValue = $0
            },
            proxy: proxy
        )
    }
}

struct TimelineCommentAllCommentsDerivedState: Equatable {
    let anchorID: SegmentCommentID?
    let anchorIndex: Int?
    let availableBeforeCount: Int
    let availableAfterCount: Int
    let visibleRows: [CommentTimelineRow]
}

struct TimelineCommentBrowserWindowState: Equatable {
    let anchorID: SegmentCommentID?
    let visibleBeforeCount: Int
    let visibleAfterCount: Int
    let hasPerformedInitialScroll: Bool
    let isRequestingOlderPage: Bool
    let isRequestingNewerPage: Bool
    let pendingAnchorPinnedCommentID: SegmentCommentID?
}

struct TimelineCommentBrowserVisibleCounts: Equatable {
    let before: Int
    let after: Int
}

struct TimelineCommentBrowserKeyboardContext: Equatable {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    let modifiers: NSEvent.ModifierFlags
    let isBrowsingAllComments: Bool
    let hasPendingDeleteConfirmation: Bool
    let isTagSubmenuVisible: Bool
    let isLinkPopoverPresented: Bool
    let isSearchFieldFocused: Bool
}

struct TimelineCommentBrowserOpenTarget: Equatable {
    let targetID: SegmentCommentID
    let resolvedHighlightedID: SegmentCommentID
}

struct TimelineCommentAllCommentsFlowEnvironment {
    let sessionController: TimelineCommentAllCommentsSessionController
    let browserController: TimelineCommentSubmenuBrowserController
    let windowController: TimelineCommentBrowserWindowController
    let pageSize: Int
    let currentAnchorID: () -> SegmentCommentID?
    let anchorIndex: () -> Int?
    let totalRowCount: () -> Int
    let selectedCommentIDs: () -> Set<SegmentCommentID>
    let rowIDs: () -> [SegmentCommentID]
    let visibleRowIDs: () -> [SegmentCommentID]
    let availableBeforeCount: () -> Int
    let availableAfterCount: () -> Int
    let hasMoreOlderPages: () -> Bool
    let hasMoreNewerPages: () -> Bool
    let isLoadingTimeline: () -> Bool
    let isLoadingOlderPage: () -> Bool
    let isLoadingNewerPage: () -> Bool
    let setSearchFieldFocused: (Bool) -> Void
    let resetSearch: () -> Void
    let resetTimeline: () -> Void
    let loadTimeline: (SegmentComment?) async -> Void
    let loadOlderPage: () async -> Void
    let loadNewerPage: () async -> Void
    let performScrollRequest: (TimelineCommentAllCommentsScrollRequest) -> Void
}

enum TimelineCommentBrowserKeyboardAction: Equatable {
    case none
    case dismissTagSubmenu
    case dismissLinkPopover
    case exitAllComments
    case closeSubmenu
    case openAllComments
    case focusSearchField
    case seedHighlightedSelection
    case moveHighlightedSelection(delta: Int)
    case openHighlightedSelection
}

enum TimelineCommentBrowserPageRequestAction: Equatable {
    case none
    case expandedWindow
    case loadPage
}

enum TimelineCommentAllCommentsScrollRequest: Equatable {
    case none
    case scrollTo(SegmentCommentID, animated: Bool)
}

enum TimelineCommentAllCommentsPageLoadPlan: Equatable {
    case none
    case expandedWindow
    case loadOlderPage
    case loadNewerPage
}

enum TimelineCommentAllCommentsDerivedStateSupport {
    static func make(
        rows: [CommentTimelineRow],
        explicitAnchorID: SegmentCommentID?,
        fallbackAnchorID: SegmentCommentID?,
        visibleBeforeCount: Int,
        visibleAfterCount: Int
    ) -> TimelineCommentAllCommentsDerivedState {
        let anchorID = TimelineCommentBrowserWindowSupport.pinnedAnchorID(
            explicitAnchorID: explicitAnchorID,
            fallbackAnchorID: fallbackAnchorID
        )
        let anchorIndex = TimelineCommentBrowserWindowSupport.resolveAnchorIndex(
            rows: rows,
            explicitAnchorID: explicitAnchorID,
            fallbackAnchorID: fallbackAnchorID
        )
        let availableBeforeCount = anchorIndex ?? 0
        let availableAfterCount = anchorIndex.map { max(0, rows.count - $0 - 1) } ?? 0
        let visibleRows = TimelineCommentBrowserWindowSupport.visibleRows(
            rows: rows,
            anchorIndex: anchorIndex,
            visibleBeforeCount: visibleBeforeCount,
            visibleAfterCount: visibleAfterCount
        )

        return TimelineCommentAllCommentsDerivedState(
            anchorID: anchorID,
            anchorIndex: anchorIndex,
            availableBeforeCount: availableBeforeCount,
            availableAfterCount: availableAfterCount,
            visibleRows: visibleRows
        )
    }
}
