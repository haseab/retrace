import SwiftUI
import Shared
import App
import AppKit

let searchLog = "[SpotlightSearch]"

enum SearchFieldSelectionBehavior: Equatable {
    case caretAtEnd
    case selectAll
}

struct SearchFieldRefocusRequest: Equatable {
    var id: UUID
    var selectionBehavior: SearchFieldSelectionBehavior

    static var initial: Self {
        .init(id: UUID(), selectionBehavior: .caretAtEnd)
    }
}

enum SpotlightSearchLayoutMetrics {
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
    @ObservedObject var viewModel: SearchViewModel
    @State var isVisible = false
    @State var resultsHeight: CGFloat = 0  // Reserved results viewport height to avoid collapse during reloads
    @State var isExpanded = false  // Whether to show filters and results (expanded view)
    @State var refocusSearchField = SearchFieldRefocusRequest.initial
    @State var keyboardSelectedResultIndex: Int?
    @State var isResultKeyboardNavigationActive = false
    @State var shouldFocusFirstResultAfterSubmit = false
    @State var isRecentEntriesPopoverVisible = false
    @State var isRecentEntriesDismissedByUser = false
    @State var suppressRecentEntriesForCurrentPresentation = false
    @State var highlightedRecentEntryIndex = 0
    @State var hoveredRecentEntryKey: String?
    @State var rankedRecentEntries: [SearchViewModel.RecentSearchEntry] = []
    @State var recentEntryTagByID: [Int64: Tag] = [:]
    @State var recentEntryAppNamesByBundleID: [String: String] = [:]
    @State var recentEntriesRevealBlockedUntil: Date?
    @State var recentEntriesRevealTask: Task<Void, Never>?
    @State var recentEntriesMetadataWarmupTask: Task<Void, Never>?
    @State var didScheduleRecentEntriesMetadataWarmup = false
    @State var keyEventMonitor: Any?
    @State var overlayOpenStartTime: CFAbsoluteTime?
    @State var didRecordOpenLatency = false
    @State var isDismissing = false
    @State var overlaySessionID = "unknown"
    @State var isSearchFieldFocused = false
    @State var appIconPrefetchTask: Task<Void, Never>?

    let panelWidth: CGFloat = 1000
    let collapsedWidth: CGFloat = 450
    let maxResultsHeight: CGFloat = 550
    let minResultsHeight: CGFloat = 220
    let dismissAnimationDuration: TimeInterval = 0.15
    let thumbnailSize = CGSize(width: 280, height: 175)
    let recentEntryLimit = 15
    let recentEntryVisibleCount = 5
    let recentEntryRowHeight: CGFloat = 54
    let recentEntryRowSpacing: CGFloat = 0
    let recentEntryListVerticalPadding: CGFloat = 6
    let recentEntryAppIconSize: CGFloat = 16
    static let recentEntryMediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    static let recentEntryShortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    let gridColumns = [
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
                .onChange(of: viewModel.isDropdownOpen) { isOpen in
                    if isOpen {
                        isRecentEntriesPopoverVisible = false
                    } else {
                        refreshRecentEntriesPopoverVisibility()
                    }
                }

                if isExpanded {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: SpotlightSearchLayoutMetrics.filterBarTopOffset)
                            .allowsHitTesting(false)

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

    var isSpotlightSearchGlowActive: Bool {
        isSearchFieldFocused || !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchBar: some View {
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

    func handleSearchFieldSubmit(forceRawQuerySubmit: Bool) {
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
}

// MARK: - App Icon Loading

extension SpotlightSearchOverlay {
    @MainActor
    func scheduleAppIconPrefetch(for results: [SearchResult]) {
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
