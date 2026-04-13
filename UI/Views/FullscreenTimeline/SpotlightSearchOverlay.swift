import SwiftUI
import Shared
import App
import AppKit

private let searchLog = "[SpotlightSearch]"

fileprivate enum SearchFieldSelectionBehavior: Equatable {
    case caretAtEnd
    case selectAll
}

fileprivate struct SearchFieldRefocusRequest: Equatable {
    var id: UUID
    var selectionBehavior: SearchFieldSelectionBehavior

    static var initial: Self {
        .init(id: UUID(), selectionBehavior: .caretAtEnd)
    }
}

private enum SpotlightSearchLayoutMetrics {
    static let searchFieldHeight: CGFloat = 30
    static let searchControlButtonSize: CGFloat = 24
    static let searchBarHorizontalPadding: CGFloat = 20
    static let searchBarVerticalPadding: CGFloat = 16
    static let dividerHeight: CGFloat = 1
    static let filterBarReservedHeight: CGFloat = 48
    static let filterBarResultsGap: CGFloat = 4

    static var searchBarHeight: CGFloat {
        max(searchFieldHeight, searchControlButtonSize) + (searchBarVerticalPadding * 2)
    }

    static var filterBarTopOffset: CGFloat {
        searchBarHeight + dividerHeight
    }
}

/// Spotlight-style search overlay that appears center-screen
/// Triggered by Cmd+K or search icon click
public struct SpotlightSearchOverlay: View {

    // MARK: - Properties

    let coordinator: AppCoordinator
    let onResultSelected: (SearchResult, String) -> Void  // Result + search query for highlighting
    let onDismiss: () -> Void

    /// External SearchViewModel that persists across overlay open/close
    /// This allows search results to be preserved when clicking on a result
    @ObservedObject private var viewModel: SearchViewModel
    @State private var isVisible = false
    @State private var resultsHeight: CGFloat = 0  // Reserved results viewport height to avoid collapse during reloads
    @State private var isExpanded = false  // Whether to show filters and results (expanded view)
    @State private var refocusSearchField = SearchFieldRefocusRequest.initial
    @State private var keyboardSelectedResultIndex: Int?
    @State private var isResultKeyboardNavigationActive = false
    @State private var shouldFocusFirstResultAfterSubmit = false
    @State private var isRecentEntriesPopoverVisible = false
    @State private var isRecentEntriesDismissedByUser = false
    @State private var suppressRecentEntriesForCurrentPresentation = false
    @State private var highlightedRecentEntryIndex = 0
    @State private var hoveredRecentEntryKey: String?
    @State private var rankedRecentEntries: [SearchViewModel.RecentSearchEntry] = []
    @State private var recentEntryTagByID: [Int64: Tag] = [:]
    @State private var recentEntryAppNamesByBundleID: [String: String] = [:]
    @State private var recentEntriesRevealBlockedUntil: Date?
    @State private var recentEntriesRevealTask: Task<Void, Never>?
    @State private var recentEntriesMetadataWarmupTask: Task<Void, Never>?
    @State private var didScheduleRecentEntriesMetadataWarmup = false
    @State private var keyEventMonitor: Any?
    @State private var overlayOpenStartTime: CFAbsoluteTime?
    @State private var didRecordOpenLatency = false
    @State private var isDismissing = false
    @State private var overlaySessionID = "unknown"
    @State private var isSearchFieldFocused = false
    @State private var appIconPrefetchTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 1000
    private let collapsedWidth: CGFloat = 450
    private let maxResultsHeight: CGFloat = 550
    private let minResultsHeight: CGFloat = 220
    private let dismissAnimationDuration: TimeInterval = 0.15
    private let thumbnailSize = CGSize(width: 280, height: 175)
    private let recentEntryLimit = 15
    private let recentEntryVisibleCount = 5
    private let recentEntryRowHeight: CGFloat = 54
    private let recentEntryRowSpacing: CGFloat = 0
    private let recentEntryListVerticalPadding: CGFloat = 6
    private let recentEntryAppIconSize: CGFloat = 16
    private static let recentEntryMediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private static let recentEntryShortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    static func recentEntryAppNameMap(from apps: [AppInfo]) -> [String: String] {
        var appNamesByBundleID: [String: String] = [:]
        for app in apps where appNamesByBundleID[app.bundleID] == nil {
            appNamesByBundleID[app.bundleID] = app.name
        }
        return appNamesByBundleID
    }

    // MARK: - Initialization

    public init(
        coordinator: AppCoordinator,
        viewModel: SearchViewModel,
        onResultSelected: @escaping (SearchResult, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onResultSelected = onResultSelected
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Backdrop - also dismisses dropdowns if open
            // Only show backdrop when expanded
            if isExpanded {
                Color.black.opacity(isVisible ? 0.6 : 0)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if !viewModel.isDropdownOpen {
                            // Outside click should dismiss with animation but preserve search state.
                            dismissOverlayPreservingSearch()
                        }
                    }
            }

            // Search panel - use ZStack to allow dropdowns to escape clipping
            ZStack(alignment: .top) {
                // Main panel content (clipped)
                VStack(spacing: 0) {
                    searchBar

                    // Only show filter bar and results when expanded
                    if isExpanded {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        // Filter bar placeholder + results
                        VStack(spacing: 0) {
                            // Reserve vertical space for the filter bar so results don't jump when it appears.
                            Color.clear
                                .frame(height: SpotlightSearchLayoutMetrics.filterBarReservedHeight)
                                .allowsHitTesting(false)

                            if hasResults {
                                // Small gap before divider to maintain visual spacing below filter bar
                                Color.clear.frame(height: SpotlightSearchLayoutMetrics.filterBarResultsGap)

                                Divider()
                                    .background(Color.white.opacity(0.1))

                                resultsArea
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard !viewModel.isDropdownOpen else { return }
                                    }
                            }
                        }
                    }
                }
                .frame(width: isExpanded ? panelWidth : collapsedWidth)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.4))
                        .background(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(isExpanded ? 0 : 0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
                .overlay(alignment: .top) {
                    recentEntriesPopover
                        .offset(y: isRecentEntriesPopoverVisible ? 58 : 50)
                        .opacity(isRecentEntriesPopoverVisible ? 1 : 0)
                        .allowsHitTesting(isRecentEntriesPopoverVisible)
                        .zIndex(20)
                }

                // Filter bar overlay (NOT clipped, so dropdowns can extend beyond panel)
                if isExpanded {
                    VStack(spacing: 0) {
                        // Offset to position below search bar + divider
                        Color.clear.frame(height: SpotlightSearchLayoutMetrics.filterBarTopOffset)
                        SearchFilterBar(viewModel: viewModel)
                    }
                    .frame(width: panelWidth)
                }
            }
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
            .animation(.easeOut(duration: 0.15), value: isRecentEntriesPopoverVisible)
        }
        .onAppear {
            overlaySessionID = String(UUID().uuidString.prefix(8))
            overlayOpenStartTime = CFAbsoluteTimeGetCurrent()
            didRecordOpenLatency = false
            viewModel.isSearchFieldFocused = false
            viewModel.isRecentEntriesPopoverVisible = false
            logRecentEntriesState(context: "onAppear:beforeOpenAnimation")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isVisible = true
                // If there are existing results, expand to show them
                if viewModel.results != nil && !viewModel.searchQuery.isEmpty {
                    isExpanded = true
                }
            }
            viewModel.isSearchOverlayExpanded = isExpanded
            installKeyEventMonitor()
            scheduleOpenLatencyMeasurement()
            if !viewModel.visibleResults.isEmpty {
                reserveExpandedResultsHeight()
            }
            isRecentEntriesDismissedByUser = false
            configureRecentEntriesRevealDelay()
            refreshRankedRecentEntries()
            refreshRecentEntryTagMap()
            refreshRecentEntryAppNameMap()
            scheduleRecentEntriesMetadataWarmupIfNeeded()
            refreshRecentEntriesPopoverVisibility()
            logRecentEntriesState(context: "onAppear:afterRefresh")
            if !viewModel.visibleResults.isEmpty {
                scheduleAppIconPrefetch(for: viewModel.visibleResults)
            }
        }
        .onDisappear {
            recentEntriesRevealTask?.cancel()
            recentEntriesRevealTask = nil
            recentEntriesMetadataWarmupTask?.cancel()
            recentEntriesMetadataWarmupTask = nil
            removeKeyEventMonitor()
            clearResultKeyboardNavigation()
            viewModel.isSearchOverlayExpanded = false
            viewModel.isSearchFieldFocused = false
            overlayOpenStartTime = nil
            didRecordOpenLatency = false
            isRecentEntriesPopoverVisible = false
            isRecentEntriesDismissedByUser = false
            suppressRecentEntriesForCurrentPresentation = false
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
            isSearchFieldFocused = false
            rankedRecentEntries = []
            recentEntryTagByID = [:]
            recentEntryAppNamesByBundleID = [:]
            appIconPrefetchTask?.cancel()
            appIconPrefetchTask = nil
            recentEntriesRevealBlockedUntil = nil
            didScheduleRecentEntriesMetadataWarmup = false
            viewModel.isRecentEntriesPopoverVisible = false
            logRecentEntriesState(context: "onDisappear")
        }
        .onChange(of: isExpanded) { expanded in
            viewModel.isSearchOverlayExpanded = expanded
        }
        .onExitCommand {
            handleSearchEscape()
        }
        .onChange(of: viewModel.searchQuery) { newValue in
            if newValue != viewModel.committedSearchQuery {
                clearResultKeyboardNavigation()
            }
            highlightedRecentEntryIndex = 0
            if newValue.isEmpty {
                resultsHeight = 0
            }
            refreshRankedRecentEntries()
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.isSearching) { isSearching in
            if isSearching && !isExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }
            // Log results when search completes
            if !isSearching {
                if let results = viewModel.results {
                    Log.info("\(searchLog) Results received: \(results.results.count) results, nextPage=\(results.nextCursor != nil), searchTime=\(results.searchTimeMs)ms", category: .ui)
                }
                updateSubmittedSearchResultFocus()
            }
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.results != nil) { _ in
            updateSubmittedSearchResultFocus()
        }
        .onChange(of: viewModel.visibleResults.count) { _ in
            Log.info(
                "\(searchLog) Results count changed: generation=\(viewModel.searchGeneration), isSearching=\(viewModel.isSearching), filteredCount=\(viewModel.visibleResults.count), totalCount=\(viewModel.results?.results.count ?? 0), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                category: .ui
            )
            if !viewModel.visibleResults.isEmpty {
                reserveExpandedResultsHeight()
            }
            updateSubmittedSearchResultFocus()
            syncKeyboardSelectionWithCurrentResults()
            scheduleAppIconPrefetch(for: viewModel.visibleResults)
        }
        .onChange(of: viewModel.searchGeneration) { generation in
            Log.info(
                "\(searchLog) searchGeneration changed to \(generation) (query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)', currentResults=\(viewModel.results?.results.count ?? 0))",
                category: .ui
            )
        }
        .onChange(of: isExpanded) { _ in
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.openFilterSignal.id) { _ in
            // When Tab cycles back to search field (index 0), trigger refocus
            if viewModel.openFilterSignal.index == 0 {
                requestSearchFieldRefocus()
            }
        }
        .onChange(of: viewModel.isDropdownOpen) { isOpen in
            // When a dropdown closes (Escape or Enter selection), refocus the search field
            if !isOpen {
                requestSearchFieldRefocus()
            }
            if isOpen {
                isRecentEntriesPopoverVisible = false
            } else {
                refreshRecentEntriesPopoverVisibility()
            }
        }
        .onChange(of: viewModel.dismissOverlaySignal.id) { _ in
            dismissOverlay(clearSearchState: viewModel.dismissOverlaySignal.clearSearchState)
        }
        .onChange(of: viewModel.collapseOverlaySignal) { _ in
            collapseToCompactSearchBar(clearFilters: false)
        }
        .onChange(of: viewModel.focusSearchFieldSignal.id) { _ in
            focusSearchField(selectAll: viewModel.focusSearchFieldSignal.selectAll)
        }
        .onChange(of: viewModel.dismissRecentEntriesPopoverSignal) { _ in
            dismissRecentEntriesPopoverByUser()
        }
        .onChange(of: viewModel.recentSearchEntries) { _ in
            refreshRankedRecentEntries()
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.availableTags.map { "\($0.id.value)|\($0.name)" }) { _ in
            refreshRecentEntryTagMap()
        }
        .onChange(of: viewModel.availableApps.map { "\($0.bundleID)|\($0.name)" }) { _ in
            refreshRecentEntryAppNameMap()
        }
        .onChange(of: isRecentEntriesPopoverVisible) { isVisible in
            viewModel.isRecentEntriesPopoverVisible = isVisible
        }
        .onPreferenceChange(ResultsAreaHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            let clampedHeight = min(maxResultsHeight, max(minResultsHeight, height))
            // Guard with epsilon to prevent geometry-driven update loops.
            guard abs(resultsHeight - clampedHeight) > 1 else { return }
            resultsHeight = clampedHeight
        }
    }

    // MARK: - Search Bar

    private var isSpotlightSearchGlowActive: Bool {
        isSearchFieldFocused || !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.retraceTitle3)
                    .foregroundColor(.white.opacity(0.5))

                SpotlightSearchField(
                    text: $viewModel.searchQuery,
                    onSubmit: handleSearchFieldSubmit,
                    onEscape: {
                        handleSearchEscape()
                    },
                    onTab: {
                        // Tab from search field opens search-order dropdown (first filter)
                        isRecentEntriesPopoverVisible = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                        // Signal to open search-order filter (index 1)
                        viewModel.openFilterSignal = (1, UUID())
                    },
                    onBackTab: {
                        // Shift+Tab from search field opens Advanced filter (last filter)
                        isRecentEntriesPopoverVisible = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                        viewModel.openFilterSignal = (7, UUID())
                    },
                    onFocus: {
                        isSearchFieldFocused = true
                        viewModel.isSearchFieldFocused = true
                        clearResultKeyboardNavigation()
                        // Close any open dropdowns when search field gains focus
                        if viewModel.isDropdownOpen {
                            viewModel.closeDropdownsSignal += 1
                        }
                        refreshRecentEntriesPopoverVisibility()
                    },
                    onBlur: {
                        isSearchFieldFocused = false
                        viewModel.isSearchFieldFocused = false
                    },
                    onArrowDown: {
                        guard isRecentEntriesPopoverVisible else { return false }
                        guard !rankedRecentEntries.isEmpty else { return false }
                        highlightedRecentEntryIndex = min(highlightedRecentEntryIndex + 1, rankedRecentEntries.count - 1)
                        return true
                    },
                    onArrowUp: {
                        guard isRecentEntriesPopoverVisible else { return false }
                        highlightedRecentEntryIndex = max(highlightedRecentEntryIndex - 1, 0)
                        return true
                    },
                    refocusRequest: refocusSearchField
                )
                .frame(height: SpotlightSearchLayoutMetrics.searchFieldHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                requestSearchFieldRefocus()
            }

            // Loading spinner (shown while searching)
            if viewModel.isSearching {
                SpinnerView(size: 20, lineWidth: 2, color: .white)
                    // Keep search row height stable while loading so filter bar offset does not shift.
                    .frame(
                        width: SpotlightSearchLayoutMetrics.searchControlButtonSize,
                        height: SpotlightSearchLayoutMetrics.searchControlButtonSize
                    )
            }

            // Filter button (expands to show filters)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isExpanded || viewModel.hasActiveFilters ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isExpanded || viewModel.hasActiveFilters ? .white : .white.opacity(0.6))
                }
                .frame(
                    width: SpotlightSearchLayoutMetrics.searchControlButtonSize,
                    height: SpotlightSearchLayoutMetrics.searchControlButtonSize
                )
                .overlay(alignment: .topTrailing) {
                    if viewModel.activeFilterCount > 0 {
                        Text("\(viewModel.activeFilterCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)

            // Close button
            Button(action: {
                dismissOverlay()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(
                    width: SpotlightSearchLayoutMetrics.searchControlButtonSize,
                    height: SpotlightSearchLayoutMetrics.searchControlButtonSize
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SpotlightSearchLayoutMetrics.searchBarHorizontalPadding)
        .padding(.vertical, SpotlightSearchLayoutMetrics.searchBarVerticalPadding)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: isExpanded ? 0 : 12,
                bottomTrailingRadius: isExpanded ? 0 : 12,
                topTrailingRadius: 12
            )
                .stroke(
                    Color.white.opacity(isExpanded ? 0 : (isSpotlightSearchGlowActive ? 0.60 : 0.28)),
                    lineWidth: isExpanded ? 0 : (isSpotlightSearchGlowActive ? 1.8 : 1.0)
                )
        )
        .shadow(
            color: Color.white.opacity(isExpanded ? 0 : (isSpotlightSearchGlowActive ? 0.28 : 0.10)),
            radius: isSpotlightSearchGlowActive ? 14 : 7,
            x: 0,
            y: 0
        )
        .shadow(
            color: Color.black.opacity(isSpotlightSearchGlowActive ? 0.32 : 0.14),
            radius: isSpotlightSearchGlowActive ? 22 : 10,
            x: 0,
            y: 0
        )
        .animation(.easeOut(duration: 0.18), value: isSpotlightSearchGlowActive)
    }

    static func shouldSelectHighlightedRecentEntry(
        isRecentEntriesPopoverVisible: Bool,
        forceRawQuerySubmit: Bool
    ) -> Bool {
        isRecentEntriesPopoverVisible && !forceRawQuerySubmit
    }

    private func handleSearchFieldSubmit(forceRawQuerySubmit: Bool) {
        if Self.shouldSelectHighlightedRecentEntry(
            isRecentEntriesPopoverVisible: isRecentEntriesPopoverVisible,
            forceRawQuerySubmit: forceRawQuerySubmit
        ) {
            selectHighlightedRecentEntry()
            return
        }

        guard !viewModel.searchQuery.isEmpty else { return }
        if forceRawQuerySubmit {
            DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: "cmd+enter")
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = true
        }
        prepareResultKeyboardNavigationAfterSubmit()
        viewModel.submitSearch(trigger: forceRawQuerySubmit ? "command-submit" : "submit")
    }

    // MARK: - Recent Entries

    private func refreshRankedRecentEntries() {
        rankedRecentEntries = viewModel.rankedRecentSearchEntries(for: viewModel.searchQuery, limit: recentEntryLimit)
    }

    private func refreshRecentEntryTagMap() {
        recentEntryTagByID = Dictionary(uniqueKeysWithValues: viewModel.availableTags.map { ($0.id.value, $0) })
    }

    private func refreshRecentEntryAppNameMap() {
        recentEntryAppNamesByBundleID = Self.recentEntryAppNameMap(from: viewModel.availableApps)
    }

    private var rankedRecentEntriesCount: Int {
        rankedRecentEntries.count
    }

    private var shouldShowRecentEntriesPopover: Bool {
        guard isVisible else { return false }
        guard !isRecentEntriesDismissedByUser else { return false }
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if suppressRecentEntriesForCurrentPresentation && isQueryEmpty {
            return false
        }
        if let blockedUntil = recentEntriesRevealBlockedUntil, Date() < blockedUntil {
            return false
        }
        guard !viewModel.isDropdownOpen else { return false }
        guard !viewModel.isSearching else { return false }
        guard !isResultKeyboardNavigationActive else { return false }
        guard !isExpanded else { return false }
        guard viewModel.results == nil else { return false }
        return rankedRecentEntriesCount > 0
    }

    private func configureRecentEntriesRevealDelay() {
        recentEntriesRevealTask?.cancel()
        recentEntriesRevealTask = nil

        suppressRecentEntriesForCurrentPresentation = viewModel.consumeSuppressRecentEntriesForNextOverlayOpen()
        let revealDelay = viewModel.consumeNextRecentEntriesRevealDelay()
        Log.info(
            "\(searchLog)[\(overlaySessionID)] configureRecentEntriesRevealDelay suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) revealDelay=\(String(format: "%.3f", revealDelay))",
            category: .ui
        )
        guard revealDelay > 0 else {
            recentEntriesRevealBlockedUntil = nil
            return
        }

        recentEntriesRevealBlockedUntil = Date().addingTimeInterval(revealDelay)
        recentEntriesRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(revealDelay), clock: .continuous)
            guard !Task.isCancelled else { return }
            recentEntriesRevealBlockedUntil = nil
            Log.info("\(searchLog)[\(overlaySessionID)] revealDelay elapsed; reevaluating popover visibility", category: .ui)
            refreshRecentEntriesPopoverVisibility()
        }
    }

    private func refreshRecentEntriesPopoverVisibility() {
        let shouldShow = shouldShowRecentEntriesPopover
        if shouldShow != isRecentEntriesPopoverVisible {
            Log.info(
                "\(searchLog)[\(overlaySessionID)] popover visibility \(isRecentEntriesPopoverVisible) -> \(shouldShow)",
                category: .ui
            )
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = shouldShow
            }
        }

        if shouldShow {
            scheduleRecentEntriesMetadataWarmupIfNeeded()
        }

        if isRecentEntriesPopoverVisible {
            highlightedRecentEntryIndex = min(highlightedRecentEntryIndex, max(rankedRecentEntries.count - 1, 0))
        } else {
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
        }
    }

    private func scheduleRecentEntriesMetadataWarmupIfNeeded() {
        guard !didScheduleRecentEntriesMetadataWarmup else { return }
        didScheduleRecentEntriesMetadataWarmup = true

        recentEntriesMetadataWarmupTask?.cancel()
        recentEntriesMetadataWarmupTask = Task(priority: .utility) {
            // Let overlay first frame settle before metadata warmup.
            try? await Task.sleep(for: .milliseconds(120), clock: .continuous)
            guard !Task.isCancelled else { return }

            async let apps: Void = viewModel.loadAvailableApps()
            async let tags: Void = viewModel.loadAvailableTags()
            _ = await (apps, tags)
        }
    }

    private func selectHighlightedRecentEntry() {
        let entries = rankedRecentEntries
        guard !entries.isEmpty else { return }
        let selectedIndex = min(highlightedRecentEntryIndex, entries.count - 1)
        selectRecentEntry(entries[selectedIndex])
    }

    private func selectRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.submitRecentSearchEntry(entry)
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = true
        }

        prepareResultKeyboardNavigationAfterSubmit()
    }

    private func removeRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.removeRecentSearchEntry(entry)
        Log.info("\(searchLog)[\(overlaySessionID)] removed recent entry key=\(entry.key)", category: .ui)
    }

    private func dismissRecentEntriesPopoverByUser() {
        isRecentEntriesDismissedByUser = true
        Log.info("\(searchLog)[\(overlaySessionID)] user dismissed recent entries popover via header x", category: .ui)
        withAnimation(.easeOut(duration: 0.15)) {
            isRecentEntriesPopoverVisible = false
        }
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
    }

    private func logRecentEntriesState(context: String) {
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blockedUntilActive: Bool = {
            if let blockedUntil = recentEntriesRevealBlockedUntil {
                return Date() < blockedUntil
            }
            return false
        }()
        let hasResults = viewModel.results != nil
        let rankedCount = rankedRecentEntriesCount
        let shouldShow = shouldShowRecentEntriesPopover
        Log.info(
            "\(searchLog)[\(overlaySessionID)] \(context) visible=\(isVisible) expanded=\(isExpanded) queryEmpty=\(isQueryEmpty) hasResults=\(hasResults) rankedCount=\(rankedCount) dismissedByUser=\(isRecentEntriesDismissedByUser) suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) blockedUntilActive=\(blockedUntilActive) dropdownOpen=\(viewModel.isDropdownOpen) searching=\(viewModel.isSearching) resultNavActive=\(isResultKeyboardNavigationActive) popoverVisible=\(isRecentEntriesPopoverVisible) shouldShow=\(shouldShow)",
            category: .ui
        )
    }

    private var recentEntriesViewportHeight: CGFloat {
        let visibleCount = max(1, min(recentEntryVisibleCount, rankedRecentEntriesCount))
        let rowsHeight = CGFloat(visibleCount) * recentEntryRowHeight
        let spacingHeight = CGFloat(max(0, visibleCount - 1)) * recentEntryRowSpacing
        return rowsHeight + spacingHeight + (recentEntryListVerticalPadding * 2)
    }

    private var recentEntriesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                Text("Recent Entries")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                Spacer(minLength: 8)
                Button(action: {
                    dismissRecentEntriesPopoverByUser()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Hide recent entries")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: rankedRecentEntriesCount > recentEntryVisibleCount) {
                VStack(spacing: recentEntryRowSpacing) {
                    ForEach(Array(rankedRecentEntries.enumerated()), id: \.element.key) { index, entry in
                        let isRowHovered = hoveredRecentEntryKey == entry.key
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                selectRecentEntry(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(entry.query)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(RetraceMenuStyle.textColor)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 6)
                                        Text(recentEntryRelativeTimeText(for: entry))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(RetraceMenuStyle.textColorMuted)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }

                                    recentEntryFilterSummaryRow(for: entry.filters)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                removeRecentEntry(entry)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 12, height: 12)
                            .padding(.top, 2)
                            .opacity(isRowHovered ? 1 : 0)
                            .allowsHitTesting(isRowHovered)
                            .accessibilityHidden(!isRowHovered)
                            .help("Remove recent search")
                        }
                        .frame(maxWidth: .infinity, minHeight: recentEntryRowHeight, maxHeight: recentEntryRowHeight, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                                .fill(index == highlightedRecentEntryIndex ? RetraceMenuStyle.itemHoverColor : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                                .stroke(
                                    index == highlightedRecentEntryIndex
                                        ? RetraceMenuStyle.filterStrokeMedium
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                        .id(entry.key)
                        .onHover { hovering in
                            if hovering {
                                highlightedRecentEntryIndex = index
                                hoveredRecentEntryKey = entry.key
                            } else if hoveredRecentEntryKey == entry.key {
                                hoveredRecentEntryKey = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, recentEntryListVerticalPadding)
            }
            .frame(height: recentEntriesViewportHeight)
            .padding(.bottom, 10)
        }
        .frame(width: collapsedWidth - 8, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.4))
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
    }

    private func recentEntryRelativeTimeText(for entry: SearchViewModel.RecentSearchEntry) -> String {
        let now = Date()
        let usedDate = Date(timeIntervalSince1970: entry.lastUsedAt)
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(usedDate)))
        let calendar = Calendar.current

        if elapsedSeconds < 60 {
            return "just now"
        }
        if elapsedSeconds < 3600 {
            let minutes = elapsedSeconds / 60
            return "\(minutes) min ago"
        }
        if elapsedSeconds < 86_400 {
            let hours = elapsedSeconds / 3600
            let minutes = (elapsedSeconds % 3600) / 60
            if minutes == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s") ago"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) min ago"
        }
        if calendar.isDateInYesterday(usedDate) {
            return "yesterday"
        }
        if elapsedSeconds < 7 * 86_400 {
            let days = elapsedSeconds / 86_400
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }

        return Self.recentEntryMediumDateFormatter.string(from: usedDate)
    }

    @ViewBuilder
    private func recentEntryFilterSummaryRow(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
            if !filters.appBundleIDs.isEmpty {
                recentEntryAppSummary(for: filters)
            }

            if !filters.tagIDs.isEmpty {
                if filters.tagFilterMode == .exclude {
                    recentEntryMetadataToken(icon: "minus.circle.fill", text: "Tags", tint: .orange.opacity(0.9))
                }
                ForEach(recentEntryTags(for: filters), id: \.id.value) { tag in
                    recentEntryTagBadge(tag)
                }
            }

            if let dateLabel = recentEntryDateLabel(for: filters) {
                recentEntryMetadataToken(icon: "calendar", text: dateLabel)
            }

            if filters.hiddenFilter != .hide {
                recentEntryMetadataToken(
                    icon: visibilityIcon(for: filters.hiddenFilter),
                    text: visibilityLabel(for: filters.hiddenFilter)
                )
            }

            if filters.commentFilter != .allFrames {
                recentEntryMetadataToken(
                    icon: commentIcon(for: filters.commentFilter),
                    text: commentLabel(for: filters.commentFilter)
                )
            }

            if !filters.windowNameTerms.isEmpty {
                let tint: Color = filters.windowNameFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                let icon = filters.windowNameFilterMode == .exclude ? "minus.circle.fill" : "rectangle.and.text.magnifyingglass"
                ForEach(Array(filters.windowNameTerms.prefix(3)), id: \.self) { term in
                    recentEntryMetadataToken(icon: icon, text: "Title: \(term)", tint: tint)
                }
                if filters.windowNameTerms.count > 3 {
                    recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.windowNameTerms.count - 3)", tint: tint)
                }
            }

            if !filters.browserUrlTerms.isEmpty {
                let tint: Color = filters.browserUrlFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                let icon = filters.browserUrlFilterMode == .exclude ? "minus.circle.fill" : "link"
                ForEach(Array(filters.browserUrlTerms.prefix(3)), id: \.self) { term in
                    recentEntryMetadataToken(icon: icon, text: "URL: \(term)", tint: tint)
                }
                if filters.browserUrlTerms.count > 3 {
                    recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.browserUrlTerms.count - 3)", tint: tint)
                }
            }

            if !filters.excludedQueryTerms.isEmpty {
                ForEach(Array(filters.excludedQueryTerms.prefix(4)), id: \.self) { excludedTerm in
                    recentEntryMetadataToken(
                        icon: "minus.circle.fill",
                        text: excludedTerm,
                        tint: .orange.opacity(0.9)
                    )
                }
                if filters.excludedQueryTerms.count > 4 {
                    recentEntryMetadataToken(
                        icon: "ellipsis.circle",
                        text: "+\(filters.excludedQueryTerms.count - 4)",
                        tint: .orange.opacity(0.9)
                    )
                }
            }

            if !hasRecentEntryFilterMetadata(filters) {
                recentEntryMetadataToken(icon: "slider.horizontal.3", text: "No filters")
            }
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentEntryAppSummary(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        let bundleIDs = filters.appBundleIDs

        return HStack(spacing: 4) {
            if filters.appFilterMode == .exclude {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange.opacity(0.95))
            }

            if bundleIDs.count == 1, let bundleID = bundleIDs.first {
                HStack(spacing: 5) {
                    AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                        .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    Text(recentEntryAppName(for: bundleID))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: -4) {
                    ForEach(Array(bundleIDs.prefix(8)), id: \.self) { bundleID in
                        AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                            .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                }
            }
        }
    }

    private func recentEntryAppName(for bundleID: String) -> String {
        if let appName = recentEntryAppNamesByBundleID[bundleID] {
            return appName
        }
        let fallback = bundleID
            .split(separator: ".")
            .last
            .map(String.init) ?? bundleID
        return fallback
    }

    private func recentEntryMetadataToken(icon: String, text: String, tint: Color = RetraceMenuStyle.textColorMuted) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .lineLimit(1)
        }
    }

    private func recentEntryTagBadge(_ tag: Tag) -> some View {
        let tint = TagColorStore.color(for: tag)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(tag.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint.opacity(0.95))
                .lineLimit(1)
        }
    }

    private func recentEntryTags(for filters: SearchViewModel.RecentSearchFilters) -> [Tag] {
        return filters.tagIDs.map { tagID in
            recentEntryTagByID[tagID] ?? Tag(id: TagID(value: tagID), name: "#\(tagID)")
        }
    }

    private func hasRecentEntryFilterMetadata(_ filters: SearchViewModel.RecentSearchFilters) -> Bool {
        let dateRanges = filters.effectiveDateRanges
        return !filters.appBundleIDs.isEmpty ||
        !filters.tagIDs.isEmpty ||
        filters.hiddenFilter != .hide ||
        filters.commentFilter != .allFrames ||
        !dateRanges.isEmpty ||
        !filters.windowNameTerms.isEmpty ||
        !filters.browserUrlTerms.isEmpty ||
        !filters.excludedQueryTerms.isEmpty
    }

    private func recentEntryDateLabel(for filters: SearchViewModel.RecentSearchFilters) -> String? {
        let dateRanges = filters.effectiveDateRanges
        if dateRanges.count > 1 {
            return "\(dateRanges.count) date ranges"
        }
        if let startDate = dateRanges.first?.start, let endDate = dateRanges.first?.end {
            return "\(Self.recentEntryShortDateFormatter.string(from: startDate)) - \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        if let startDate = dateRanges.first?.start {
            return "From \(Self.recentEntryShortDateFormatter.string(from: startDate))"
        }
        if let endDate = dateRanges.first?.end {
            return "Until \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        return nil
    }

    private func visibilityIcon(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "eye"
        case .onlyHidden:
            return "eye.slash"
        case .showAll:
            return "eye.circle"
        }
    }

    private func visibilityLabel(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "Visible"
        case .onlyHidden:
            return "Hidden"
        case .showAll:
            return "All"
        }
    }

    private func commentIcon(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "text.bubble"
        case .commentsOnly:
            return "text.bubble.fill"
        case .noComments:
            return "text.bubble.slash"
        }
    }

    private func commentLabel(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "All"
        case .commentsOnly:
            return "Comments"
        case .noComments:
            return "No Comments"
        }
    }

    // MARK: - Results Area

    private var hasResults: Bool {
        !viewModel.searchQuery.isEmpty && (viewModel.isSearching || viewModel.results != nil || resultsHeight > 0)
    }

    private var reservedResultsHeight: CGFloat {
        max(minResultsHeight, resultsHeight)
    }

    private func reserveExpandedResultsHeight() {
        guard resultsHeight < maxResultsHeight - 1 else { return }
        resultsHeight = maxResultsHeight
    }

    /// Records first-frame overlay open latency once per presentation.
    /// Uses next runloop turn so timing includes view construction/layout cost.
    private func scheduleOpenLatencyMeasurement() {
        DispatchQueue.main.async {
            guard !didRecordOpenLatency, let startTime = overlayOpenStartTime else { return }
            didRecordOpenLatency = true
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Log.recordLatency(
                "search.overlay.open.first_frame_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 5,
                warningThresholdMs: 120,
                criticalThresholdMs: 300
            )
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.isSearching && viewModel.results == nil {
            searchingView
                .frame(height: reservedResultsHeight)
        } else if viewModel.results != nil {
            if viewModel.visibleResults.isEmpty {
                noResultsView
                    .frame(height: reservedResultsHeight)
            } else {
                resultsList(viewModel.visibleResults)
            }
        }
    }

    // MARK: - Results List

    private func resultsList(_ visibleResults: [SearchResult]) -> some View {
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                        GalleryResultCard(
                            result: result,
                            thumbnailKey: thumbnailKey(for: result),
                            thumbnailSize: thumbnailSize,
                            index: index,
                            isKeyboardSelected: isResultKeyboardNavigationActive && keyboardSelectedResultIndex == index,
                            onSelect: {
                                // Save scroll position before selecting result
                                viewModel.savedScrollPosition = CGFloat(index)
                                keyboardSelectedResultIndex = index
                                isResultKeyboardNavigationActive = true
                                selectResult(result)
                            },
                            viewModel: viewModel
                        )
                        .onAppear {
                            loadThumbnail(for: result)

                            // Infinite scroll: load more when near the end
                            if index >= visibleResults.count - 3 && viewModel.canLoadMore {
                                viewModel.loadMore()
                            }
                        }
                    }
                }
                .onAppear {
                    Log.info(
                        "\(searchLog) Results grid appear: generation=\(viewModel.searchGeneration), filteredCount=\(visibleResults.count), totalCount=\(viewModel.results?.results.count ?? 0), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                        category: .ui
                    )
                }
                .onDisappear {
                    Log.info(
                        "\(searchLog) Results grid disappear: generation=\(viewModel.searchGeneration), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                        category: .ui
                    )
                }
                .padding(16)

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        SpinnerView(size: 16, lineWidth: 2, color: .white)
                        Text("Loading more...")
                            .font(.retraceCaption2)
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: maxResultsHeight)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ResultsAreaHeightPreferenceKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onAppear {
                // Restore scroll position when overlay appears
                if viewModel.savedScrollPosition > 0 {
                    let targetIndex = Int(viewModel.savedScrollPosition)
                    guard visibleResults.indices.contains(targetIndex) else { return }
                    let targetResultID = visibleResults[targetIndex].id
                    // Scroll to the saved position with a slight delay to ensure layout is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(targetResultID, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: keyboardSelectedResultIndex) { selectedIndex in
                guard let selectedIndex else { return }
                guard visibleResults.indices.contains(selectedIndex) else { return }
                let selectedResultID = visibleResults[selectedIndex].id
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedResultID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty States

    private var searchingView: some View {
        VStack(spacing: 12) {
            SpinnerView(size: 28, lineWidth: 3, color: .white)

            Text("Searching...")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))

            // Show slow query alert when filtering by app with "All" mode
            if viewModel.selectedAppFilters != nil && !viewModel.selectedAppFilters!.isEmpty && viewModel.searchMode == .all {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.retraceCaption2)
                    Text("\"All\" queries with app filters are slower")
                        .font(.retraceCaption2)
                }
                .foregroundColor(.yellow.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.15))
                )
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.retraceDisplay2)
                .foregroundColor(.white.opacity(0.3))

            Text(viewModel.hasActiveFilters ? "No results match this query with current filters" : "No results found")
                .font(.retraceBodyMedium)
                .foregroundColor(.white.opacity(0.6))

            Text(viewModel.hasActiveFilters ? "Try broadening filters or changing your query" : "Try a different search term")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.4))

            if viewModel.hasActiveFilters {
                noResultsActionButton(title: "Clear Filters") {
                    viewModel.clearAllFilters()
                    viewModel.rerunSearchImmediately(trigger: "no-results.clear-filters")
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noResultsActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thumbnail Loading

    private func thumbnailKey(for result: SearchResult) -> String {
        // Use committedSearchQuery (set on Enter) instead of live searchQuery
        // This prevents thumbnails from reloading while user is typing
        "\(result.segmentID.stringValue)_\(result.timestamp.timeIntervalSince1970)_\(viewModel.committedSearchQuery)"
    }

    private func loadThumbnail(for result: SearchResult) {
        let key = thumbnailKey(for: result)
        let currentGeneration = viewModel.searchGeneration

        if viewModel.thumbnailCache[key] != nil {
            viewModel.markThumbnailAccessed(key)
            return
        }

        guard viewModel.beginThumbnailLoadIfNeeded(key) else {
            return
        }

        let startTime = Date()

        Task {
            if await viewModel.loadThumbnailFromDiskIfAvailable(for: key, generation: currentGeneration) {
                viewModel.loadingThumbnails.remove(key)
                return
            }

            do {
                // 1. Fetch frame image (prefer direct path to avoid per-thumbnail DB lookups and JPEG round-trips)
                let fullImage: NSImage
                if let videoPath = result.videoPath {
                    let cgImage = try await coordinator.getFrameCGImage(
                        videoPath: videoPath,
                        frameIndex: result.frameIndex,
                        frameRate: result.videoFrameRate,
                        source: result.source
                    )
                    fullImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                } else {
                    // Fallback for legacy cached results lacking video path/frame rate.
                    let imageData = try await coordinator.getFrameImageByIndex(
                        videoID: result.videoID,
                        frameIndex: result.frameIndex,
                        source: result.source
                    )
                    guard let decodedImage = NSImage(data: imageData) else {
                        Log.error("\(searchLog) Failed to create NSImage from fallback data", category: .ui)
                        viewModel.failThumbnailLoad(with: nil, for: key, generation: currentGeneration)
                        return
                    }
                    fullImage = decodedImage
                }
                // Check if search generation changed (user started a new search)
                guard viewModel.searchGeneration == currentGeneration else {
                    viewModel.failThumbnailLoad(with: nil, for: key, generation: currentGeneration)
                    return
                }

                let thumbnail: NSImage
                if let matchNode = result.highlightNode {
                    thumbnail = createHighlightedThumbnail(
                        from: fullImage,
                        matchX: matchNode.x,
                        matchY: matchNode.y,
                        matchWidth: matchNode.width,
                        matchHeight: matchNode.height,
                        size: thumbnailSize
                    )
                } else {
                    thumbnail = createThumbnail(from: fullImage, size: thumbnailSize)
                }

                viewModel.finishThumbnailLoad(
                    thumbnail,
                    for: key,
                    generation: currentGeneration
                )
            } catch {
                let duration = Date().timeIntervalSince(startTime) * 1000
                Log.error("\(searchLog) ❌ THUMBNAIL FAILED after \(Int(duration))ms: \(error)", category: .ui)
                Log.error("\(searchLog) ❌ Details: videoID=\(result.videoID), frameIndex=\(result.frameIndex), source=\(result.source)", category: .ui)

                // Create a placeholder thumbnail so the UI doesn't show infinite loading
                let placeholder = createPlaceholderThumbnail(size: thumbnailSize)
                viewModel.failThumbnailLoad(
                    with: placeholder,
                    for: key,
                    generation: currentGeneration
                )
            }
        }
    }

    /// Create a placeholder thumbnail when frame extraction fails
    private func createPlaceholderThumbnail(size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        // Dark gray background
        NSColor(white: 0.15, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw "unavailable" icon
        let iconSize: CGFloat = 40
        let iconRect = NSRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSColor.white.withAlphaComponent(0.3).setStroke()
        let iconPath = NSBezierPath(ovalIn: iconRect.insetBy(dx: 5, dy: 5))
        iconPath.lineWidth = 2
        iconPath.stroke()

        // Draw X through circle
        let xPath = NSBezierPath()
        xPath.move(to: NSPoint(x: iconRect.minX + 10, y: iconRect.minY + 10))
        xPath.line(to: NSPoint(x: iconRect.maxX - 10, y: iconRect.maxY - 10))
        xPath.move(to: NSPoint(x: iconRect.maxX - 10, y: iconRect.minY + 10))
        xPath.line(to: NSPoint(x: iconRect.minX + 10, y: iconRect.maxY - 10))
        xPath.lineWidth = 2
        xPath.stroke()

        thumbnail.unlockFocus()
        return thumbnail
    }

    private func createHighlightedThumbnail(
        from image: NSImage,
        matchX: Double,
        matchY: Double,
        matchWidth: Double,
        matchHeight: Double,
        size: CGSize
    ) -> NSImage {
        let imageSize = image.size

        // OCR coordinates use top-left origin (y=0 at top), but NSImage uses bottom-left origin (y=0 at bottom)
        // We need to flip the Y coordinate: flippedY = 1.0 - y - height
        let flippedNodeY = 1.0 - matchY - matchHeight

        // Calculate the crop region centered on the match with padding
        // OCR coordinates are normalized (0.0-1.0), convert to pixel coordinates
        let matchCenterX = (matchX + matchWidth / 2) * imageSize.width
        let matchCenterY = (flippedNodeY + matchHeight / 2) * imageSize.height

        // Determine crop size to maintain aspect ratio of thumbnail
        // Use a zoom factor to show context around the match
        let zoomFactor: CGFloat = 3.5  // How much to zoom in (higher = more zoom)
        let cropWidth = imageSize.width / zoomFactor
        let cropHeight = cropWidth * (size.height / size.width)  // Maintain aspect ratio

        // Calculate crop origin, ensuring we stay within bounds
        var cropX = matchCenterX - cropWidth / 2
        var cropY = matchCenterY - cropHeight / 2

        // Clamp to image bounds
        cropX = max(0, min(cropX, imageSize.width - cropWidth))
        cropY = max(0, min(cropY, imageSize.height - cropHeight))

        let cropRect = NSRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        // Create the thumbnail
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        // Draw the cropped region of the source image
        let destRect = NSRect(origin: .zero, size: size)
        image.draw(in: destRect, from: cropRect, operation: .copy, fraction: 1.0)

        // Calculate where the highlight box should be drawn in the thumbnail
        // Convert match coordinates from image space to crop space, then to thumbnail space
        // Use the flipped Y coordinate for NSImage drawing
        let matchXInCrop = (matchX * imageSize.width - cropX) / cropWidth * size.width
        let matchYInCrop = (flippedNodeY * imageSize.height - cropY) / cropHeight * size.height
        let matchWidthInThumb = (matchWidth * imageSize.width) / cropWidth * size.width
        let matchHeightInThumb = (matchHeight * imageSize.height) / cropHeight * size.height

        // Add some padding to the highlight box
        let padding: CGFloat = 4
        let highlightRect = NSRect(
            x: matchXInCrop - padding,
            y: matchYInCrop - padding,
            width: matchWidthInThumb + padding * 2,
            height: matchHeightInThumb + padding * 2
        )

        // Draw yellow highlight box (matching the style used in SimpleTimelineView)
        // Use explicit RGB to match SwiftUI's Color.yellow exactly
        let highlightColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3)
        highlightColor.setStroke()
        highlightPath.lineWidth = 2
        highlightPath.stroke()

        thumbnail.unlockFocus()
        return thumbnail
    }

    private func createThumbnail(from image: NSImage, size: CGSize) -> NSImage {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()

        let sourceRect = NSRect(origin: .zero, size: image.size)
        let destRect = NSRect(origin: .zero, size: size)

        image.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)

        thumbnail.unlockFocus()
        return thumbnail
    }

    // MARK: - App Icon Loading

    @MainActor
    private func scheduleAppIconPrefetch(for results: [SearchResult]) {
        appIconPrefetchTask?.cancel()

        let bundleIDs = orderedUniqueAppBundleIDs(from: results)
        guard !bundleIDs.isEmpty else {
            appIconPrefetchTask = nil
            return
        }

        appIconPrefetchTask = Task { @MainActor in
            let appPathsByBundleID = await Task.detached(priority: .utility) {
                Self.resolveInstalledAppPaths(bundleIDs: bundleIDs)
            }.value

            guard !Task.isCancelled else { return }

            for (index, bundleID) in bundleIDs.enumerated() {
                guard !Task.isCancelled else { return }
                guard viewModel.appIconCache[bundleID] == nil,
                      let appPath = appPathsByBundleID[bundleID] else {
                    continue
                }

                let icon = NSWorkspace.shared.icon(forFile: appPath)
                icon.size = NSSize(width: 20, height: 20)
                viewModel.appIconCache[bundleID] = icon

                if (index + 1).isMultiple(of: 3) {
                    await Task.yield()
                }
            }
        }
    }

    private func orderedUniqueAppBundleIDs(from results: [SearchResult]) -> [String] {
        var orderedBundleIDs: [String] = []
        var seenBundleIDs: Set<String> = []
        for result in results {
            guard let bundleID = result.appBundleID,
                  !bundleID.isEmpty,
                  seenBundleIDs.insert(bundleID).inserted else {
                continue
            }
            orderedBundleIDs.append(bundleID)
        }
        return orderedBundleIDs
    }

    nonisolated private static func resolveInstalledAppPaths(
        bundleIDs: [String],
        fileManager: FileManager = .default
    ) -> [String: String] {
        let requiredBundleIDs = Set(bundleIDs.filter { !$0.isEmpty })
        guard !requiredBundleIDs.isEmpty else { return [:] }

        let applicationFolders: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized", isDirectory: true),
        ]

        var remainingBundleIDs = requiredBundleIDs
        var appPathsByBundleID: [String: String] = [:]

        for folder in applicationFolders {
            guard !remainingBundleIDs.isEmpty else { break }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for appURL in entries where appURL.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      remainingBundleIDs.contains(bundleID) else {
                    continue
                }

                appPathsByBundleID[bundleID] = appURL.path
                remainingBundleIDs.remove(bundleID)
            }
        }

        return appPathsByBundleID
    }

    // MARK: - Actions

    private func selectResult(_ result: SearchResult) {
        viewModel.selectResult(result)
        let query = viewModel.committedSearchQuery.isEmpty ? viewModel.searchQuery : viewModel.committedSearchQuery
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("\(searchLog) Result selected: query='\(query)', frameID=\(result.frameID.stringValue), timestamp=\(df.string(from: result.timestamp)) (epoch: \(result.timestamp.timeIntervalSince1970)), segmentID=\(result.segmentID.stringValue), app=\(result.appName ?? "unknown")", category: .ui)

        // Dismiss overlay WITHOUT clearing search state - user selected a result
        dismissOverlayPreservingSearch()

        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onResultSelected(result, query)
        }
    }

    /// Dismisses the overlay without clearing search state (used when selecting a result)
    private func dismissOverlayPreservingSearch() {
        dismissOverlay(clearSearchState: false)
    }

    /// Dismisses the overlay and clears search state (used for explicit dismissal like Escape key)
    private func dismissOverlay() {
        dismissOverlay(clearSearchState: true)
    }

    private func collapseToCompactSearchBar(clearFilters: Bool) {
        guard isExpanded else { return }

        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        if clearFilters {
            viewModel.clearAllFilters()
            viewModel.resetSearchOrderToDefault()
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = false
        }

        requestSearchFieldRefocus()
        refreshRecentEntriesPopoverVisibility()
    }

    private func handleSearchEscape() {
        if isRecentEntriesPopoverVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = false
            }
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
            return
        }

        // If a dropdown is open, close it instead of collapsing/dismissing.
        if viewModel.isDropdownOpen {
            viewModel.closeDropdownsSignal += 1
            return
        }

        // When results own keyboard focus, Escape should return to the query first.
        if viewModel.shouldRefocusSearchFieldOnEscape {
            focusSearchField(selectAll: true)
            return
        }

        // Expanded overlay with no submitted search should collapse back to compact mode.
        if isExpanded && !viewModel.shouldDismissExpandedOverlayOnEscape {
            collapseToCompactSearchBar(clearFilters: true)
            return
        }

        dismissOverlay()
    }

    private func handleSearchCommandK() {
        if viewModel.isDropdownOpen {
            viewModel.closeDropdownsSignal += 1
            return
        }

        if viewModel.shouldRefocusSearchFieldOnEscape {
            focusSearchField(selectAll: true)
            return
        }

        // Cmd+K closes the visible overlay but preserves the current search state.
        dismissOverlayPreservingSearch()
    }

    private func requestSearchFieldRefocus(selectAll: Bool = false) {
        refocusSearchField = SearchFieldRefocusRequest(
            id: UUID(),
            selectionBehavior: selectAll ? .selectAll : .caretAtEnd
        )
    }

    private func focusSearchField(selectAll: Bool) {
        clearResultKeyboardNavigation()
        isSearchFieldFocused = true
        viewModel.isSearchFieldFocused = true
        requestSearchFieldRefocus(selectAll: selectAll)
    }

    private func dismissOverlay(clearSearchState: Bool) {
        guard !isDismissing else { return }
        isDismissing = true

        // Cancel any in-flight search tasks to prevent blocking while the overlay fades out.
        viewModel.cancelSearch()
        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
        rankedRecentEntries = []

        withAnimation(.easeOut(duration: dismissAnimationDuration)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            // Clear only after fade-out completes so dismiss is visually smooth.
            if clearSearchState {
                viewModel.searchQuery = ""
                viewModel.clearAllFilters()
                viewModel.resetSearchOrderToDefault()
            }
            onDismiss()
            isDismissing = false
        }
    }

    // MARK: - Keyboard Navigation

    private var keyboardNavigableResults: [SearchResult] {
        viewModel.visibleResults
    }

    private func prepareResultKeyboardNavigationAfterSubmit() {
        shouldFocusFirstResultAfterSubmit = true
        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = nil
        isRecentEntriesPopoverVisible = false
        resignSearchFieldFocus()
    }

    private func focusFirstResultIfAvailable() {
        let results = keyboardNavigableResults
        shouldFocusFirstResultAfterSubmit = false

        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = 0
        resignSearchFieldFocus()
    }

    private func updateSubmittedSearchResultFocus() {
        guard shouldFocusFirstResultAfterSubmit else { return }

        let totalResultCount = viewModel.results?.results.count
        let visibleResultCount = keyboardNavigableResults.count
        let hasSearchError = viewModel.error != nil

        if visibleResultCount > 0 {
            focusFirstResultIfAvailable()
            return
        }

        if viewModel.isSearching {
            return
        }

        if let totalResultCount {
            if totalResultCount == 0 {
                clearResultKeyboardNavigation()
            }
            return
        }

        if hasSearchError {
            clearResultKeyboardNavigation()
        }
    }

    private func syncKeyboardSelectionWithCurrentResults() {
        let results = keyboardNavigableResults

        if shouldFocusFirstResultAfterSubmit {
            focusFirstResultIfAvailable()
            return
        }

        guard isResultKeyboardNavigationActive else { return }
        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        if let index = keyboardSelectedResultIndex {
            keyboardSelectedResultIndex = min(index, results.count - 1)
        } else {
            keyboardSelectedResultIndex = 0
        }
    }

    private func clearResultKeyboardNavigation() {
        shouldFocusFirstResultAfterSubmit = false
        isResultKeyboardNavigationActive = false
        keyboardSelectedResultIndex = nil
        refreshRecentEntriesPopoverVisibility()
    }

    private func resignSearchFieldFocus() {
        isSearchFieldFocused = false
        viewModel.isSearchFieldFocused = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Handle overlay-level dismissal/focus shortcuts here so AppKit text bindings
            // in the search field do not swallow them before the timeline controller sees them.
            if event.keyCode == 53 && modifiers.isEmpty { // Escape
                handleSearchEscape()
                return nil
            }

            if event.keyCode == 40 && modifiers == [.command] { // Cmd+K
                handleSearchCommandK()
                return nil
            }

            guard isResultKeyboardNavigationActive,
                  !viewModel.isDropdownOpen,
                  !viewModel.isDatePopoverHandlingKeys else {
                return event
            }

            let results = keyboardNavigableResults
            guard !results.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123: // left
                moveSelection(in: results, offset: -1)
                return nil
            case 124: // right
                moveSelection(in: results, offset: 1)
                return nil
            case 125: // down
                moveSelection(in: results, offset: gridColumns.count)
                return nil
            case 126: // up
                moveSelection(in: results, offset: -gridColumns.count)
                return nil
            case 36, 76: // return / enter
                let selectedIndex = min(keyboardSelectedResultIndex ?? 0, results.count - 1)
                keyboardSelectedResultIndex = selectedIndex
                viewModel.savedScrollPosition = CGFloat(selectedIndex)
                selectResult(results[selectedIndex])
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func moveSelection(in results: [SearchResult], offset: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = keyboardSelectedResultIndex ?? 0
        let nextIndex = max(0, min(results.count - 1, currentIndex + offset))
        keyboardSelectedResultIndex = nextIndex
    }
}

// MARK: - Gallery Result Card

private struct GalleryResultCard: View {
    let result: SearchResult
    let thumbnailKey: String
    let thumbnailSize: CGSize
    let index: Int
    let isKeyboardSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var viewModel: SearchViewModel

    @State private var isHovered = false

    private var thumbnail: NSImage? {
        viewModel.thumbnailCache[thumbnailKey]
    }

    private var appIcon: NSImage? {
        viewModel.appIconCache[result.appBundleID ?? ""]
    }

    /// Display title: window name (c2) if available, otherwise app name
    private var displayTitle: String {
        if let windowName = result.windowName, !windowName.isEmpty {
            return windowName
        }
        return result.appName ?? "Unknown"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail (highlight is baked into the cropped thumbnail)
                thumbnailView

                // Title bar with app icon
                HStack(spacing: 8) {
                    // App icon
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                            .frame(width: 30, height: 30)
                    }

                    // Title and timestamp
                    VStack(alignment: .leading, spacing: 2) {
                        // Title with source badge
                        HStack(spacing: 6) {
                            Text(displayTitle)
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            // Source badge
                            Text(result.source == .native ? "Retrace" : "Rewind")
                                .font(.retraceTinyBold)
                                .foregroundColor(result.source == .native ? RetraceMenuStyle.actionBlue : .purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(result.source == .native ? RetraceMenuStyle.actionBlue.opacity(0.2) : Color.purple.opacity(0.2))
                                .cornerRadius(3)
                        }

                        // Timestamp and relevance
                        HStack(spacing: 6) {
                            Text(formatTimestamp(result.timestamp))
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.5))

                            Text("•")
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.3))

                            Text(String(format: "relevance: %.0f%%", result.relevanceScore * 100))
                                .font(.retraceMonoSmall)
                                .foregroundColor(.yellow.opacity(0.7))
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.3) : Color.white.opacity(0.1), lineWidth: isHovered ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.retraceAccent, lineWidth: 2)
                    .opacity(isKeyboardSelected ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.03), value: true)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color.black

            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else {
                SpinnerView(size: 16, lineWidth: 2, color: .white.opacity(0.4))
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
}

private struct ResultsAreaHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Spotlight Search Field

/// NSViewRepresentable text field for the spotlight search overlay
/// Uses manual makeFirstResponder for reliable focus in borderless windows
struct SpotlightSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: (Bool) -> Void
    let onEscape: () -> Void
    var onTab: (() -> Void)? = nil
    var onBackTab: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var onArrowDown: (() -> Bool)? = nil
    var onArrowUp: (() -> Bool)? = nil
    var placeholder: String = "Search anything you have seen..."
    fileprivate var refocusRequest: SearchFieldRefocusRequest = .initial

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 17, weight: .medium)
            ]
        )
        textField.font = .systemFont(ofSize: 17, weight: .medium)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true

        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onBackTab = onBackTab
        context.coordinator.onFocus = onFocus
        context.coordinator.onBlur = onBlur
        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onArrowUp = onArrowUp
        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            self.onFocus?()
        }
        textField.onCommandReturnCallback = {
            self.onSubmit(true)
        }

        // Focus the text field with retry logic for external monitors
        Log.info("\(searchLog)[FieldFocus] makeNSView scheduling initial focus", category: .ui)
        focusTextField(textField, attempt: 1, selectionBehavior: .caretAtEnd)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onBackTab = onBackTab
        context.coordinator.onFocus = onFocus
        context.coordinator.onBlur = onBlur
        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onArrowUp = onArrowUp
        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            self.onFocus?()
        }
        textField.onCommandReturnCallback = {
            self.onSubmit(true)
        }
        // Check if refocus was triggered
        if context.coordinator.lastRefocusRequest != refocusRequest {
            context.coordinator.lastRefocusRequest = refocusRequest
            focusTextField(textField, attempt: 1, selectionBehavior: refocusRequest.selectionBehavior)
        }
    }

    private func focusTextField(
        _ textField: FocusableTextField,
        attempt: Int,
        selectionBehavior: SearchFieldSelectionBehavior
    ) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(
                            textField,
                            attempt: attempt + 1,
                            selectionBehavior: selectionBehavior
                        )
                    }
                }
                return
            }
            self.performFocus(
                textField,
                in: window,
                attempt: attempt,
                selectionBehavior: selectionBehavior
            )
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func performFocus(
        _ textField: FocusableTextField,
        in window: NSWindow,
        attempt: Int,
        selectionBehavior: SearchFieldSelectionBehavior
    ) {
        let maxAttempts = 5

        // Activate the app first — required for makeKey to work on external monitors
        // where NSApp.isActive may be false when the overlay opens
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let success = window.makeFirstResponder(textField)

        // Ensure field editor exists for caret to appear
        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        // Restore either a caret-at-end focus or a select-all replacement affordance.
        if let fieldEditor = window.fieldEditor(false, for: textField) as? NSTextView {
            switch selectionBehavior {
            case .caretAtEnd:
                let endPosition = fieldEditor.string.count
                fieldEditor.setSelectedRange(NSRange(location: endPosition, length: 0))
            case .selectAll:
                fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.count))
            }
        }

        // Keep SwiftUI focus state in sync with programmatic AppKit focus restoration.
        if success {
            onFocus?()
        }

        // If the window isn't key yet (activation is async on external monitors),
        // retry so keystrokes actually reach the text field
        if !window.isKeyWindow && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(
                    textField,
                    attempt: attempt + 1,
                    selectionBehavior: selectionBehavior
                )
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(
                    textField,
                    attempt: attempt + 1,
                    selectionBehavior: selectionBehavior
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onEscape: onEscape,
            onTab: onTab,
            onBackTab: onBackTab,
            onFocus: onFocus,
            onBlur: onBlur,
            onArrowDown: onArrowDown,
            onArrowUp: onArrowUp
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: (Bool) -> Void
        var onEscape: () -> Void
        var onTab: (() -> Void)?
        var onBackTab: (() -> Void)?
        var onFocus: (() -> Void)?
        var onBlur: (() -> Void)?
        var onArrowDown: (() -> Bool)?
        var onArrowUp: (() -> Bool)?
        fileprivate var lastRefocusRequest: SearchFieldRefocusRequest = .initial

        init(
            text: Binding<String>,
            onSubmit: @escaping (Bool) -> Void,
            onEscape: @escaping () -> Void,
            onTab: (() -> Void)?,
            onBackTab: (() -> Void)?,
            onFocus: (() -> Void)?,
            onBlur: (() -> Void)?,
            onArrowDown: (() -> Bool)?,
            onArrowUp: (() -> Bool)?
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
            self.onTab = onTab
            self.onBackTab = onBackTab
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onArrowDown = onArrowDown
            self.onArrowUp = onArrowUp
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            onFocus?()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onBlur?()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                onSubmit(false)
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab?()
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onBackTab?()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return onArrowDown?() ?? false
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return onArrowUp?() ?? false
            }
            return false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SpotlightSearchOverlay_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SpotlightSearchOverlay(
            coordinator: coordinator,
            viewModel: SearchViewModel(coordinator: coordinator),
            onResultSelected: { _, _ in },
            onDismiss: {}
        )
        .frame(width: 800, height: 600)
        .background(Color.gray.opacity(0.3))
        .preferredColorScheme(.dark)
    }
}
#endif
