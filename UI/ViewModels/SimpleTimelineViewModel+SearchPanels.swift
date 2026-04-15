import App
import Foundation
import SwiftUI
import Shared

extension SimpleTimelineViewModel {
    // MARK: - Date Search Panel

    /// Open the date search panel with animation
    public func openDateSearch() {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .dateSearch)
        // Show controls if hidden (user expects to see the date search panel)
        showControlsIfHidden()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isDateSearchActive = true
        }
    }

    /// Close the date search panel with animation
    public func closeDateSearch() {
        withAnimation(.easeOut(duration: 0.15)) {
            isDateSearchActive = false
            closeCalendarPicker()
        }
        dateSearchText = ""
        // Clear any date search errors when closing
        setPresentationError(nil)
        errorDismissTask?.cancel()
    }

    /// Toggle the date search panel with animation
    public func toggleDateSearch() {
        if isDateSearchActive {
            closeDateSearch()
        } else {
            openDateSearch()
        }
    }

    // MARK: - In-Frame Search

    /// Toggle in-frame OCR search visibility.
    /// When active, toggling closes and clears the in-frame query.
    public func toggleInFrameSearch(clearQueryOnClose: Bool = true) {
        let hasQuery = !inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isInFrameSearchVisible || hasQuery {
            closeInFrameSearch(clearQuery: clearQueryOnClose)
        } else {
            openInFrameSearch()
        }
    }

    /// Open in-frame OCR search and focus the top-right search field.
    public func openInFrameSearch() {
        dismissOtherDialogs(except: .inFrameSearch)
        showControlsIfHidden()
        inFrameSearchDebounceTask?.cancel()
        inFrameSearchDebounceTask = nil
        isInFrameSearchVisible = true
        focusInFrameSearchFieldSignal &+= 1
        applyInFrameSearchHighlighting()
    }

    /// Close in-frame search. Optionally clears the query and highlight state.
    public func closeInFrameSearch(clearQuery: Bool) {
        isInFrameSearchVisible = false
        inFrameSearchDebounceTask?.cancel()
        inFrameSearchDebounceTask = nil
        if clearQuery {
            inFrameSearchQuery = ""
            clearSearchHighlightImmediately()
        }
    }

    /// Update in-frame query and refresh highlight state with a short debounce.
    public func setInFrameSearchQuery(_ query: String) {
        inFrameSearchQuery = query
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        inFrameSearchDebounceTask?.cancel()

        guard !normalizedQuery.isEmpty else {
            inFrameSearchDebounceTask = nil
            clearSearchHighlightImmediately()
            return
        }

        inFrameSearchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .nanoseconds(Int64(Self.inFrameSearchDebounceNanoseconds)),
                clock: .continuous
            )
            guard !Task.isCancelled, let self else { return }
            guard self.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuery else {
                return
            }
            self.applyInFrameSearchHighlighting()
        }
    }

    private func applyInFrameSearchHighlighting() {
        let normalizedQuery = inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearSearchHighlightImmediately()
            return
        }

        invalidateSearchResultNavigation()
        cancelPendingSearchHighlightTasks()
        searchHighlightMode = .matchedTextRanges
        searchHighlightQuery = normalizedQuery
        isShowingSearchHighlight = true
    }

    // MARK: - Search Overlay

    /// Open the search overlay and dismiss other dialogs.
    /// - Parameter recentEntriesRevealDelay: One-shot delay before showing recent entries popover.
    public func openSearchOverlay(recentEntriesRevealDelay: TimeInterval = 0) {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .search)
        // Show controls if hidden (user expects to see the search overlay)
        showControlsIfHidden()
        searchViewModel.setNextRecentEntriesRevealDelay(recentEntriesRevealDelay)
        isSearchOverlayVisible = true
        // Clear any existing search highlight
        Task { @MainActor in
            clearSearchHighlight()
        }
    }

    /// Close the search overlay
    public func closeSearchOverlay() {
        searchViewModel.setNextRecentEntriesRevealDelay(0)
        isSearchOverlayVisible = false
    }

    /// Toggle the search overlay.
    /// - Parameter recentEntriesRevealDelayOnOpen: One-shot delay applied only when opening.
    public func toggleSearchOverlay(recentEntriesRevealDelayOnOpen: TimeInterval = 0) {
        if isSearchOverlayVisible {
            closeSearchOverlay()
        } else {
            openSearchOverlay(recentEntriesRevealDelay: recentEntriesRevealDelayOnOpen)
        }
    }

    /// Apply deeplink search state from `retrace://search`.
    /// This resets stale query/filter state first, then applies deeplink values.
    public func applySearchDeeplink(query: String?, appBundleID: String?, source: String = "unknown") {
        let deeplinkID = String(UUID().uuidString.prefix(8))
        let normalizedQuery: String? = {
            guard let query else { return nil }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let normalizedAppBundleID: String? = {
            guard let appBundleID else { return nil }
            let trimmed = appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        Log.info(
            "[SearchDeeplink][\(deeplinkID)] begin source=\(source), query=\(normalizedQuery ?? "nil"), app=\(normalizedAppBundleID ?? "nil")",
            category: .ui
        )
        openSearchOverlay()

        // Reset prior transient search state so deeplinks are deterministic.
        searchViewModel.cancelSearch()
        searchViewModel.searchQuery = ""
        searchViewModel.clearAllFilters()

        if let normalizedAppBundleID {
            searchViewModel.setAppFilter(normalizedAppBundleID)
        }

        guard let normalizedQuery else {
            Log.info("[SearchDeeplink][\(deeplinkID)] completed with no query (app=\(normalizedAppBundleID ?? "nil"))", category: .ui)
            return
        }

        searchViewModel.searchQuery = normalizedQuery
        searchViewModel.submitSearch(trigger: "deeplink:\(source)")
        Log.info("[SearchDeeplink][\(deeplinkID)] submitted query='\(normalizedQuery)' app=\(normalizedAppBundleID ?? "nil")", category: .ui)
    }

}
