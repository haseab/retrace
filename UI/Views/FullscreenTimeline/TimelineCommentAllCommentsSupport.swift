import AppKit
import Foundation
import Shared
import SwiftUI

enum TimelineCommentBrowserKeyboardSupport {
    static func action(
        for context: TimelineCommentBrowserKeyboardContext
    ) -> TimelineCommentBrowserKeyboardAction {
        let modifiers = context.modifiers.intersection([.command, .shift, .option, .control])

        if modifiers.isEmpty, context.keyCode == 53 {
            guard !context.hasPendingDeleteConfirmation else { return .none }

            if context.isTagSubmenuVisible {
                return .dismissTagSubmenu
            }

            if context.isLinkPopoverPresented {
                return .dismissLinkPopover
            }

            return context.isBrowsingAllComments ? .exitAllComments : .closeSubmenu
        }

        if modifiers == [.option], context.keyCode == 0, !context.isBrowsingAllComments {
            return .openAllComments
        }

        guard context.isBrowsingAllComments else { return .none }

        let isCommandBack = modifiers == [.command] &&
            (context.keyCode == 33 || context.charactersIgnoringModifiers == "[")
        if isCommandBack {
            return .exitAllComments
        }

        guard !context.hasPendingDeleteConfirmation, !context.isLinkPopoverPresented else {
            return .none
        }

        if modifiers.isEmpty, context.keyCode == 48 {
            return context.isSearchFieldFocused ? .seedHighlightedSelection : .focusSearchField
        }

        guard modifiers.isEmpty else { return .none }

        switch context.keyCode {
        case 125:
            return .moveHighlightedSelection(delta: 1)
        case 126:
            return .moveHighlightedSelection(delta: -1)
        case 36, 76:
            return .openHighlightedSelection
        default:
            return .none
        }
    }

    static func syncedHighlightedID(
        isBrowsingAllComments: Bool,
        currentHighlightedID: SegmentCommentID?,
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) -> SegmentCommentID? {
        guard isBrowsingAllComments else { return nil }
        guard !resultIDs.isEmpty else { return nil }

        if let currentHighlightedID,
           resultIDs.contains(currentHighlightedID) {
            return currentHighlightedID
        }

        if let preferredIndex = preferredStartIndex(
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        ) {
            return resultIDs[preferredIndex]
        }

        return resultIDs.first
    }

    static func movedHighlightedID(
        delta: Int,
        currentHighlightedID: SegmentCommentID?,
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) -> SegmentCommentID? {
        guard !resultIDs.isEmpty else { return nil }

        let nextIndex: Int
        if let currentHighlightedID,
           let currentIndex = resultIDs.firstIndex(of: currentHighlightedID) {
            nextIndex = min(max(currentIndex + delta, 0), resultIDs.count - 1)
        } else if let preferredIndex = preferredStartIndex(
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        ) {
            nextIndex = min(max(preferredIndex + delta, 0), resultIDs.count - 1)
        } else {
            nextIndex = 0
        }

        return resultIDs[nextIndex]
    }

    static func seededHighlightedID(
        isBrowsingAllComments: Bool,
        currentHighlightedID: SegmentCommentID?,
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) -> SegmentCommentID? {
        guard isBrowsingAllComments else { return currentHighlightedID }
        guard currentHighlightedID == nil else { return currentHighlightedID }
        guard !resultIDs.isEmpty else { return nil }

        if let preferredIndex = preferredStartIndex(
            resultIDs: resultIDs,
            preferredAnchorID: preferredAnchorID
        ) {
            return resultIDs[preferredIndex]
        }

        return resultIDs.first
    }

    static func resolvedOpenTarget(
        isBrowsingAllComments: Bool,
        highlightedID: SegmentCommentID?,
        resultIDs: [SegmentCommentID]
    ) -> TimelineCommentBrowserOpenTarget? {
        guard isBrowsingAllComments else { return nil }
        guard !resultIDs.isEmpty else { return nil }

        if let highlightedID,
           resultIDs.contains(highlightedID) {
            return TimelineCommentBrowserOpenTarget(
                targetID: highlightedID,
                resolvedHighlightedID: highlightedID
            )
        }

        guard let firstID = resultIDs.first else { return nil }
        return TimelineCommentBrowserOpenTarget(
            targetID: firstID,
            resolvedHighlightedID: firstID
        )
    }

    private static func preferredStartIndex(
        resultIDs: [SegmentCommentID],
        preferredAnchorID: SegmentCommentID?
    ) -> Int? {
        guard let preferredAnchorID else { return nil }
        return resultIDs.firstIndex(of: preferredAnchorID)
    }
}

enum TimelineCommentBrowserWindowSupport {
    static func makeAllCommentsState(anchorID: SegmentCommentID?) -> TimelineCommentBrowserWindowState {
        TimelineCommentBrowserWindowState(
            anchorID: anchorID,
            visibleBeforeCount: 0,
            visibleAfterCount: 0,
            hasPerformedInitialScroll: false,
            isRequestingOlderPage: false,
            isRequestingNewerPage: false,
            pendingAnchorPinnedCommentID: nil
        )
    }

    static func makeThreadState() -> TimelineCommentBrowserWindowState {
        makeAllCommentsState(anchorID: nil)
    }

    static func resolveAnchorIndex(
        rows: [CommentTimelineRow],
        explicitAnchorID: SegmentCommentID?,
        fallbackAnchorID: SegmentCommentID?
    ) -> Int? {
        guard !rows.isEmpty else { return nil }

        if let explicitAnchorID,
           let index = rows.firstIndex(where: { $0.id == explicitAnchorID }) {
            return index
        }

        if let fallbackAnchorID,
           let index = rows.firstIndex(where: { $0.id == fallbackAnchorID }) {
            return index
        }

        return rows.count / 2
    }

    static func visibleRows(
        rows: [CommentTimelineRow],
        anchorIndex: Int?,
        visibleBeforeCount: Int,
        visibleAfterCount: Int
    ) -> [CommentTimelineRow] {
        guard let anchorIndex, !rows.isEmpty else { return [] }

        let availableBefore = anchorIndex
        let availableAfter = max(0, rows.count - anchorIndex - 1)
        let clampedBefore = min(visibleBeforeCount, availableBefore)
        let clampedAfter = min(visibleAfterCount, availableAfter)
        let startIndex = max(0, anchorIndex - clampedBefore)
        let endIndex = min(rows.count - 1, anchorIndex + clampedAfter)
        guard startIndex <= endIndex else { return [] }
        return Array(rows[startIndex...endIndex])
    }

    static func syncedVisibleCounts(
        forceReset: Bool,
        anchorIndex: Int?,
        totalRowCount: Int,
        currentBeforeCount: Int,
        currentAfterCount: Int,
        selectedCommentIDs: Set<SegmentCommentID>,
        rowIDs: [SegmentCommentID],
        pageSize: Int
    ) -> TimelineCommentBrowserVisibleCounts? {
        guard let anchorIndex else { return nil }

        let availableBefore = anchorIndex
        let availableAfter = max(0, totalRowCount - anchorIndex - 1)

        if forceReset || (currentBeforeCount == 0 && currentAfterCount == 0) {
            var before = min(pageSize / 2, availableBefore)
            var after = min(max(0, pageSize - before - 1), availableAfter)

            if !selectedCommentIDs.isEmpty {
                let selectedIndexes = rowIDs.enumerated().compactMap { index, rowID in
                    selectedCommentIDs.contains(rowID) ? index : nil
                }
                if let minSelectedIndex = selectedIndexes.min(),
                   let maxSelectedIndex = selectedIndexes.max() {
                    before = max(before, anchorIndex - minSelectedIndex)
                    after = max(after, maxSelectedIndex - anchorIndex)
                }
            }

            before = min(before, availableBefore)
            after = min(after, availableAfter)

            let visibleCount = before + after + 1
            if visibleCount < pageSize {
                let remaining = pageSize - visibleCount
                let extraBefore = min(remaining, max(0, availableBefore - before))
                before += extraBefore
                let extraAfter = min(
                    pageSize - (before + after + 1),
                    max(0, availableAfter - after)
                )
                after += extraAfter
            }

            return TimelineCommentBrowserVisibleCounts(before: before, after: after)
        }

        return TimelineCommentBrowserVisibleCounts(
            before: min(currentBeforeCount, availableBefore),
            after: min(currentAfterCount, availableAfter)
        )
    }

    static func expandedVisibleBeforeCount(
        currentBeforeCount: Int,
        availableBeforeCount: Int,
        pageSize: Int
    ) -> Int {
        min(availableBeforeCount, currentBeforeCount + pageSize)
    }

    static func expandedVisibleAfterCount(
        currentAfterCount: Int,
        availableAfterCount: Int,
        pageSize: Int
    ) -> Int {
        min(availableAfterCount, currentAfterCount + pageSize)
    }

    static func pinnedAnchorID(
        explicitAnchorID: SegmentCommentID?,
        fallbackAnchorID: SegmentCommentID?
    ) -> SegmentCommentID? {
        explicitAnchorID ?? fallbackAnchorID
    }
}

struct TimelineCommentAllCommentsSection<RowContent: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let sectionCornerRadius: CGFloat
    let hasActiveCommentSearch: Bool
    let allCommentsCountLabel: String
    let commentSearchBinding: Binding<String>
    let searchFieldFocus: FocusState<Bool>.Binding
    let visibleRows: [CommentTimelineRow]
    let highlightedCommentSearchResultID: SegmentCommentID?
    let allCommentsVisibleBeforeCount: Int
    let allCommentsVisibleAfterCount: Int
    let pendingAnchorPinnedCommentID: SegmentCommentID?
    let rowContent: (CommentTimelineRow) -> RowContent
    let onVisibleRowAppear: (CommentTimelineRow) -> Void
    let onSearchResultAppear: (CommentTimelineRow) -> Void
    let onSubmitSearch: () -> Void
    let onClearSearch: () -> Void
    let onRetrySearch: () -> Void
    let onAllCommentsAppear: (ScrollViewProxy) -> Void
    let onTimelineRowCountChange: (ScrollViewProxy) -> Void
    let onVisibleBeforeCountChange: (ScrollViewProxy) -> Void
    let onVisibleAfterCountChange: (ScrollViewProxy) -> Void
    let onPendingAnchorPinnedChange: (ScrollViewProxy) -> Void
    let onHighlightedIDChange: (ScrollViewProxy, SegmentCommentID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasActiveCommentSearch ? "Search Results (\(viewModel.commentSearchResults.count))" : allCommentsCountLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.retraceSecondary)

            searchField

            if hasActiveCommentSearch {
                searchResultsSection
            } else if viewModel.isLoadingCommentTimeline {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading all comments...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else if let loadError = viewModel.commentTimelineLoadError,
                      viewModel.commentTimelineRows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.9))
                    Text(loadError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else if viewModel.commentTimelineRows.isEmpty {
                Text("No related comments found.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if viewModel.isLoadingOlderCommentTimeline {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading older...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.retraceSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                            }

                            ForEach(visibleRows) { row in
                                rowContent(row)
                                    .id(row.id)
                                    .onAppear {
                                        onVisibleRowAppear(row)
                                    }
                            }

                            if viewModel.isLoadingNewerCommentTimeline {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading newer...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.retraceSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onAppear {
                        onAllCommentsAppear(proxy)
                    }
                    .onChange(of: viewModel.commentTimelineRows.count) { _ in
                        onTimelineRowCountChange(proxy)
                    }
                    .onChange(of: allCommentsVisibleBeforeCount) { _ in
                        onVisibleBeforeCountChange(proxy)
                    }
                    .onChange(of: allCommentsVisibleAfterCount) { _ in
                        onVisibleAfterCountChange(proxy)
                    }
                    .onChange(of: pendingAnchorPinnedCommentID) { _ in
                        onPendingAnchorPinnedChange(proxy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.85))

            TextField("Search comments", text: commentSearchBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retracePrimary)
                .focused(searchFieldFocus)
                .onSubmit {
                    onSubmitSearch()
                }

            if !viewModel.commentSearchText.isEmpty {
                Button(action: onClearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.retraceSecondary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            searchFieldFocus.wrappedValue = true
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if viewModel.isSearchingComments && viewModel.commentSearchResults.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching comments...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else if let searchError = viewModel.commentSearchError,
                  viewModel.commentSearchResults.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.9))
                    Text(searchError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }

                Button("Retry") {
                    onRetrySearch()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.9))
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else if viewModel.commentSearchResults.isEmpty {
            Text("No matching comments.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retraceSecondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.commentSearchResults) { row in
                            rowContent(row)
                                .id(row.id)
                                .onAppear {
                                    onSearchResultAppear(row)
                                }
                        }

                        if viewModel.isSearchingComments && !viewModel.commentSearchResults.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading more...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.retraceSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onChange(of: highlightedCommentSearchResultID) { selectedID in
                    onHighlightedIDChange(proxy, selectedID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
