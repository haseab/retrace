import SwiftUI
import Combine
import Shared
import App

/// ViewModel for the Search view
/// Handles search queries, filtering, and result management with debouncing
@MainActor
public class SearchViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var searchQuery: String = ""
    @Published public var results: SearchResults?
    @Published public var isSearching = false
    @Published public var isLoadingMore = false
    @Published public var error: String?

    // Filters
    @Published public var selectedAppFilter: String?
    @Published public var startDate: Date?
    @Published public var endDate: Date?
    @Published public var contentType: ContentType = .all

    // Search mode (tabs)
    @Published public var searchMode: SearchMode = .relevant

    // Available apps for filter dropdown
    @Published public var availableApps: [RewindDataSource.AppInfo] = []
    @Published public var isLoadingApps = false

    // Selected result
    @Published public var selectedResult: SearchResult?
    @Published public var showingFrameViewer = false

    // Scroll position - persists across overlay open/close
    public var savedScrollPosition: CGFloat = 0

    // Thumbnail cache - persists across overlay open/close, cleared on new search
    @Published public var thumbnailCache: [String: NSImage] = [:]
    @Published public var loadingThumbnails: Set<String> = []
    @Published public var appIconCache: [String: NSImage] = [:]

    // Search generation counter - incremented on each new search to invalidate in-flight loads
    @Published public var searchGeneration: Int = 0

    // MARK: - Dependencies

    public let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Constants

    private let debounceDelay: TimeInterval = 0.3
    private let defaultResultLimit = 50

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // NOTE: Auto-search on typing is disabled - search is triggered manually on Enter
        // Clear results when query is cleared
        $searchQuery
            .removeDuplicates()
            .sink { [weak self] query in
                if query.isEmpty {
                    self?.results = nil
                }
            }
            .store(in: &cancellables)

        // Re-search when filters change
        Publishers.CombineLatest4(
            $selectedAppFilter,
            $startDate,
            $endDate,
            $contentType
        )
        .debounce(for: .seconds(debounceDelay), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self, !self.searchQuery.isEmpty else { return }
            Task {
                await self.performSearch(query: self.searchQuery)
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Search

    /// Trigger search with current query (called on Enter key)
    public func submitSearch() {
        Task {
            await performSearch(query: searchQuery)
        }
    }

    public func performSearch(query: String) async {
        guard !query.isEmpty else {
            Log.debug("[SearchViewModel] Empty query, clearing results", category: .ui)
            results = nil
            return
        }

        Log.info("[SearchViewModel] Performing search for: '\(query)'", category: .ui)
        isSearching = true
        error = nil
        results = nil  // Clear old results immediately to prevent stale thumbnail loads
        savedScrollPosition = 0  // Reset scroll position for new search
        thumbnailCache.removeAll()  // Clear thumbnail cache for new search
        loadingThumbnails.removeAll()  // Clear loading state for new search
        searchGeneration += 1  // Increment generation to invalidate in-flight thumbnail loads

        do {
            let searchQuery = buildSearchQuery(query)
            Log.debug("[SearchViewModel] Built search query: text='\(searchQuery.text)', limit=\(searchQuery.limit), offset=\(searchQuery.offset)", category: .ui)

            let startTime = Date()
            let searchResults = try await coordinator.search(query: searchQuery)
            let elapsed = Date().timeIntervalSince(startTime) * 1000

            Log.info("[SearchViewModel] Search completed in \(Int(elapsed))ms: \(searchResults.results.count) results (total: \(searchResults.totalCount))", category: .ui)

            if !searchResults.results.isEmpty {
                let firstResult = searchResults.results[0]
                Log.debug("[SearchViewModel] First result: frameID=\(firstResult.frameID.stringValue), timestamp=\(firstResult.timestamp), snippet='\(firstResult.snippet.prefix(50))...'", category: .ui)
            }

            // Ensure UI updates happen on main actor
            await MainActor.run {
                results = searchResults
                isSearching = false
            }
        } catch {
            Log.error("[SearchViewModel] Search failed: \(error.localizedDescription)", category: .ui)
            // Ensure UI updates happen on main actor
            await MainActor.run {
                self.error = "Search failed: \(error.localizedDescription)"
                isSearching = false
            }
        }
    }

    private func buildSearchQuery(_ text: String, offset: Int = 0) -> SearchQuery {
        let filters = SearchFilters(
            startDate: startDate,
            endDate: endDate,
            appBundleIDs: selectedAppFilter != nil ? [selectedAppFilter!] : nil,
            excludedAppBundleIDs: nil
        )

        return SearchQuery(
            text: text,
            filters: filters,
            limit: defaultResultLimit,
            offset: offset,
            mode: searchMode
        )
    }

    /// Switch search mode and re-run search
    public func setSearchMode(_ mode: SearchMode) {
        guard mode != searchMode else { return }
        searchMode = mode
        // Clear results and re-search with new mode
        if !searchQuery.isEmpty {
            Task {
                await performSearch(query: searchQuery)
            }
        }
    }

    // MARK: - Load More (Infinite Scroll)

    /// Whether more results can be loaded
    public var canLoadMore: Bool {
        guard let results = results else { return false }
        return results.hasMore && !isLoadingMore && !isSearching
    }

    /// Load more results for infinite scroll
    public func loadMore() async {
        guard canLoadMore, let currentResults = results else { return }

        Log.info("[SearchViewModel] Loading more results, current count: \(currentResults.results.count)", category: .ui)
        isLoadingMore = true

        do {
            let query = buildSearchQuery(searchQuery, offset: currentResults.results.count)
            let moreResults = try await coordinator.search(query: query)

            Log.info("[SearchViewModel] Loaded \(moreResults.results.count) more results", category: .ui)

            // Append new results to existing
            let combinedResults = currentResults.results + moreResults.results
            results = SearchResults(
                query: moreResults.query,
                results: combinedResults,
                totalCount: moreResults.totalCount,
                searchTimeMs: moreResults.searchTimeMs
            )

            isLoadingMore = false
        } catch {
            Log.error("[SearchViewModel] Load more failed: \(error.localizedDescription)", category: .ui)
            isLoadingMore = false
        }
    }

    // MARK: - Result Selection

    public func selectResult(_ result: SearchResult) {
        selectedResult = result
        showingFrameViewer = true
    }

    public func closeFrameViewer() {
        showingFrameViewer = false
        selectedResult = nil
    }

    // MARK: - Filters

    /// Load available apps for the filter dropdown
    public func loadAvailableApps() async {
        guard !isLoadingApps else { return }

        isLoadingApps = true
        do {
            let apps = try await coordinator.getDistinctApps()
            availableApps = apps
            Log.info("[SearchViewModel] Loaded \(apps.count) apps for filter", category: .ui)
        } catch {
            Log.error("[SearchViewModel] Failed to load apps: \(error)", category: .ui)
        }
        isLoadingApps = false
    }

    public func setAppFilter(_ appBundleID: String?) {
        selectedAppFilter = appBundleID
    }

    public func setDateRange(start: Date?, end: Date?) {
        startDate = start
        endDate = end
    }

    public func setContentType(_ type: ContentType) {
        contentType = type
    }

    public func clearAllFilters() {
        selectedAppFilter = nil
        startDate = nil
        endDate = nil
        contentType = .all
    }

    /// Check if any filters are active
    public var hasActiveFilters: Bool {
        selectedAppFilter != nil || startDate != nil || endDate != nil
    }

    /// Get the display name for the selected app filter
    public var selectedAppName: String? {
        guard let bundleID = selectedAppFilter else { return nil }
        return availableApps.first(where: { $0.bundleID == bundleID })?.name ?? bundleID.components(separatedBy: ".").last
    }

    // MARK: - Navigation

    public func nextResult() {
        guard let results = results,
              let current = selectedResult,
              let index = results.results.firstIndex(where: { $0.frameID == current.frameID }),
              index + 1 < results.results.count else {
            return
        }

        selectResult(results.results[index + 1])
    }

    public func previousResult() {
        guard let results = results,
              let current = selectedResult,
              let index = results.results.firstIndex(where: { $0.frameID == current.frameID }),
              index > 0 else {
            return
        }

        selectResult(results.results[index - 1])
    }

    // MARK: - Sharing

    public func generateShareLink(for result: SearchResult) -> URL? {
        DeeplinkHandler.generateSearchLink(
            query: searchQuery,
            timestamp: result.timestamp,
            appBundleID: selectedAppFilter
        )
    }

    public func copyShareLink(for result: SearchResult) {
        guard let url = generateShareLink(for: result) else { return }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        #endif
    }

    // MARK: - Statistics

    public var resultCount: Int {
        results?.results.count ?? 0
    }

    public var hasResults: Bool {
        resultCount > 0
    }

    public var isEmpty: Bool {
        !hasResults && !isSearching
    }

    // MARK: - Cleanup

    deinit {
        cancellables.removeAll()
    }
}

// MARK: - Content Type

public enum ContentType: String, CaseIterable, Identifiable {
    case all = "All"
    case ocr = "OCR Text"
    case audio = "Audio Transcription"

    public var id: String { rawValue }

    func toSearchContentTypes() -> [String] {
        switch self {
        case .all:
            return []
        case .ocr:
            return ["ocr"]
        case .audio:
            return ["audio"]
        }
    }
}
