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
    @Published public var availableApps: [AppInfo] = []
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

    // The committed search query (set when user presses Enter)
    // Used for thumbnail cache keys so thumbnails don't reload while typing
    @Published public var committedSearchQuery: String = ""

    // Flag to prevent re-search during cache restore
    private var isRestoringFromCache = false

    // MARK: - Dependencies

    public let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()

    // Active search tasks that can be cancelled
    private var currentSearchTask: Task<Void, Never>?
    private var currentLoadMoreTask: Task<Void, Never>?

    // MARK: - Constants

    private let debounceDelay: TimeInterval = 0.3
    private let defaultResultLimit = 50

    // MARK: - Search Results Cache (for restoring on app reopen)

    /// Key for storing when the cache was saved (for expiry calculation)
    private static let cachedSearchSavedAtKey = "search.cachedSearchSavedAt"
    /// Key for storing the cached search query text
    private static let cachedSearchQueryKey = "search.cachedSearchQuery"
    /// Key for storing the cached scroll position
    private static let cachedScrollPositionKey = "search.cachedScrollPosition"
    /// Key for storing the cached app filter
    private static let cachedAppFilterKey = "search.cachedAppFilter"
    /// Key for storing the cached start date
    private static let cachedStartDateKey = "search.cachedStartDate"
    /// Key for storing the cached end date
    private static let cachedEndDateKey = "search.cachedEndDate"
    /// Key for storing the cached content type
    private static let cachedContentTypeKey = "search.cachedContentType"
    /// Key for storing the cached search mode
    private static let cachedSearchModeKey = "search.cachedSearchMode"
    /// Cache version - increment when data structure changes to invalidate old caches
    private static let searchCacheVersion = 2  // v2: Added filters
    private static let searchCacheVersionKey = "search.cacheVersion"
    /// How long the cached search results remain valid (2 minutes)
    private static let searchCacheExpirationSeconds: TimeInterval = 120

    /// File path for cached search results data
    private static nonisolated var cachedSearchResultsPath: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("search_results_cache.json")
    }

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // NOTE: Auto-search on typing is disabled - search is triggered manually on Enter
        // Clear results and cache when query is cleared by user (not on init)
        $searchQuery
            .removeDuplicates()
            .dropFirst()  // Skip initial empty value so we don't clear cache on init
            .sink { [weak self] query in
                Log.debug("[SearchCache] searchQuery sink fired: query='\(query)'", category: .ui)
                if query.isEmpty {
                    Log.debug("[SearchCache] Query is empty, clearing results and cache", category: .ui)
                    self?.results = nil
                    self?.committedSearchQuery = ""
                    self?.clearSearchCache()
                }
            }
            .store(in: &cancellables)

        // Re-search when filters change (skip during cache restore)
        Publishers.CombineLatest4(
            $selectedAppFilter,
            $startDate,
            $endDate,
            $contentType
        )
        .dropFirst()  // Skip initial values
        .debounce(for: .seconds(debounceDelay), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self, !self.searchQuery.isEmpty, !self.isRestoringFromCache else { return }
            // Cancel any existing search before starting a new one
            self.currentSearchTask?.cancel()
            self.currentSearchTask = Task {
                await self.performSearch(query: self.searchQuery)
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Search

    /// Trigger search with current query (called on Enter key)
    public func submitSearch() {
        // Cancel any existing search before starting a new one
        currentSearchTask?.cancel()
        currentSearchTask = Task {
            await performSearch(query: searchQuery)
        }
    }

    public func performSearch(query: String) async {
        guard !query.isEmpty else {
            Log.debug("[SearchViewModel] Empty query, clearing results", category: .ui)
            results = nil
            committedSearchQuery = ""
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
        committedSearchQuery = query  // Set committed query for thumbnail cache keys

        do {
            // Check for cancellation before starting the search
            try Task.checkCancellation()

            let searchQuery = buildSearchQuery(query)
            Log.debug("[SearchViewModel] Built search query: text='\(searchQuery.text)', limit=\(searchQuery.limit), offset=\(searchQuery.offset)", category: .ui)

            let startTime = Date()
            let searchResults = try await coordinator.search(query: searchQuery)
            let elapsed = Date().timeIntervalSince(startTime) * 1000

            // Check for cancellation after the search completes
            try Task.checkCancellation()

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
        } catch is CancellationError {
            Log.debug("[SearchViewModel] Search was cancelled", category: .ui)
            await MainActor.run {
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
            // Cancel any existing search before starting a new one
            currentSearchTask?.cancel()
            currentSearchTask = Task {
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
            // Check for cancellation before starting
            try Task.checkCancellation()

            let query = buildSearchQuery(searchQuery, offset: currentResults.results.count)
            let moreResults = try await coordinator.search(query: query)

            // Check for cancellation after the search completes
            try Task.checkCancellation()

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
        } catch is CancellationError {
            Log.debug("[SearchViewModel] Load more was cancelled", category: .ui)
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

    // MARK: - Search Results Cache

    /// Save the current search results to cache for instant restore on app reopen
    public func saveSearchResults() {
        Log.debug("[SearchCache] saveSearchResults called - query: '\(committedSearchQuery)', results: \(results?.results.count ?? 0)", category: .ui)

        guard let results = results, !results.isEmpty else {
            Log.debug("[SearchCache] SKIP: No results to save (results is nil or empty)", category: .ui)
            return
        }
        guard !committedSearchQuery.isEmpty else {
            Log.debug("[SearchCache] SKIP: committedSearchQuery is empty", category: .ui)
            return
        }

        // Save metadata to UserDefaults
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedSearchSavedAtKey)
        UserDefaults.standard.set(committedSearchQuery, forKey: Self.cachedSearchQueryKey)
        UserDefaults.standard.set(Double(savedScrollPosition), forKey: Self.cachedScrollPositionKey)
        UserDefaults.standard.set(Self.searchCacheVersion, forKey: Self.searchCacheVersionKey)
        Log.debug("[SearchCache] Saved version=\(Self.searchCacheVersion) to key='\(Self.searchCacheVersionKey)'", category: .ui)

        // Save filters
        UserDefaults.standard.set(selectedAppFilter, forKey: Self.cachedAppFilterKey)
        if let startDate = startDate {
            UserDefaults.standard.set(startDate.timeIntervalSince1970, forKey: Self.cachedStartDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedStartDateKey)
        }
        if let endDate = endDate {
            UserDefaults.standard.set(endDate.timeIntervalSince1970, forKey: Self.cachedEndDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedEndDateKey)
        }
        UserDefaults.standard.set(contentType.rawValue, forKey: Self.cachedContentTypeKey)
        UserDefaults.standard.set(searchMode.rawValue, forKey: Self.cachedSearchModeKey)

        // Force UserDefaults to persist immediately (important for quick close/reopen)
        UserDefaults.standard.synchronize()

        // Save results to disk (JSON file) - do this async to not block the main thread
        Task.detached(priority: .utility) { [results] in
            do {
                let data = try JSONEncoder().encode(results)
                try data.write(to: Self.cachedSearchResultsPath)
                Log.debug("[SearchCache] Saved \(results.results.count) search results to cache (\(data.count / 1024)KB)", category: .ui)
            } catch {
                Log.warning("[SearchCache] Failed to save search results: \(error)", category: .ui)
            }
        }

        Log.debug("[SearchCache] Saved search results for query: '\(committedSearchQuery)' with filters", category: .ui)
    }

    /// Restore cached search results if they exist and haven't expired
    /// Returns true if cache was restored, false otherwise
    @discardableResult
    public func restoreCachedSearchResults() -> Bool {
        Log.debug("[SearchCache] restoreCachedSearchResults() called", category: .ui)

        // Check cache version first - invalidate if version mismatch
        let cachedVersion = UserDefaults.standard.integer(forKey: Self.searchCacheVersionKey)
        Log.debug("[SearchCache] Reading version from key='\(Self.searchCacheVersionKey)', got: \(cachedVersion)", category: .ui)
        if cachedVersion != Self.searchCacheVersion {
            Log.debug("[SearchCache] Cache version mismatch (cached: \(cachedVersion), current: \(Self.searchCacheVersion)) - invalidating", category: .ui)
            clearSearchCache()
            return false
        }

        let savedAt = UserDefaults.standard.double(forKey: Self.cachedSearchSavedAtKey)
        guard savedAt > 0 else { return false }

        let savedAtDate = Date(timeIntervalSince1970: savedAt)
        let elapsed = Date().timeIntervalSince(savedAtDate)

        // Check if cache has expired
        if elapsed > Self.searchCacheExpirationSeconds {
            Log.debug("[SearchCache] Cache expired (elapsed: \(Int(elapsed))s)", category: .ui)
            clearSearchCache()
            return false
        }

        // Load cached query
        guard let cachedQuery = UserDefaults.standard.string(forKey: Self.cachedSearchQueryKey),
              !cachedQuery.isEmpty else {
            return false
        }

        // Load cached scroll position
        let cachedScrollPosition = UserDefaults.standard.double(forKey: Self.cachedScrollPositionKey)

        // Load cached filters
        let cachedAppFilter = UserDefaults.standard.string(forKey: Self.cachedAppFilterKey)
        let cachedStartDateValue = UserDefaults.standard.double(forKey: Self.cachedStartDateKey)
        let cachedEndDateValue = UserDefaults.standard.double(forKey: Self.cachedEndDateKey)
        let cachedContentTypeRaw = UserDefaults.standard.string(forKey: Self.cachedContentTypeKey)
        let cachedSearchModeRaw = UserDefaults.standard.string(forKey: Self.cachedSearchModeKey)

        // Load cached results from disk
        do {
            let data = try Data(contentsOf: Self.cachedSearchResultsPath)
            let cachedResults = try JSONDecoder().decode(SearchResults.self, from: data)

            guard !cachedResults.isEmpty else { return false }

            // Set flag to prevent re-search while restoring
            isRestoringFromCache = true

            // Restore state
            Log.debug("[SearchCache] Restoring: setting searchQuery='\(cachedQuery)', results=\(cachedResults.results.count)", category: .ui)
            searchQuery = cachedQuery
            committedSearchQuery = cachedQuery
            results = cachedResults
            Log.debug("[SearchCache] After restore: searchQuery='\(searchQuery)', results=\(results?.results.count ?? 0)", category: .ui)
            savedScrollPosition = CGFloat(cachedScrollPosition)
            searchGeneration += 1

            // Restore filters
            selectedAppFilter = cachedAppFilter
            startDate = cachedStartDateValue > 0 ? Date(timeIntervalSince1970: cachedStartDateValue) : nil
            endDate = cachedEndDateValue > 0 ? Date(timeIntervalSince1970: cachedEndDateValue) : nil
            if let rawValue = cachedContentTypeRaw, let type = ContentType(rawValue: rawValue) {
                contentType = type
            }
            if let rawValue = cachedSearchModeRaw, let mode = SearchMode(rawValue: rawValue) {
                searchMode = mode
            }

            // Clear the flag after restore is complete (after debounce delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay + 0.1) { [weak self] in
                self?.isRestoringFromCache = false
            }

            Log.debug("[SearchCache] INSTANT RESTORE: Loaded \(cachedResults.results.count) cached results for '\(cachedQuery)' with filters (saved \(Int(elapsed))s ago)", category: .ui)
            return true
        } catch {
            Log.warning("[SearchCache] Failed to load cached search results: \(error)", category: .ui)
            return false
        }
    }

    /// Clear the cached search results
    private func clearSearchCache() {
        Self.clearPersistedSearchCache()
    }

    /// Static method to clear persisted search cache (can be called without an instance)
    /// Call this when data sources change (e.g., Rewind data toggled)
    public static func clearPersistedSearchCache() {
        Log.info("[SearchCache] Clearing persisted search cache (static)", category: .ui)

        UserDefaults.standard.removeObject(forKey: cachedSearchSavedAtKey)
        UserDefaults.standard.removeObject(forKey: cachedSearchQueryKey)
        UserDefaults.standard.removeObject(forKey: cachedScrollPositionKey)
        UserDefaults.standard.removeObject(forKey: searchCacheVersionKey)

        // Clear cached filters
        UserDefaults.standard.removeObject(forKey: cachedAppFilterKey)
        UserDefaults.standard.removeObject(forKey: cachedStartDateKey)
        UserDefaults.standard.removeObject(forKey: cachedEndDateKey)
        UserDefaults.standard.removeObject(forKey: cachedContentTypeKey)
        UserDefaults.standard.removeObject(forKey: cachedSearchModeKey)

        // Remove cached results file
        try? FileManager.default.removeItem(at: cachedSearchResultsPath)
    }

    /// Clear all search results and caches (called when data source changes)
    public func clearSearchResults() {
        Log.info("[SearchViewModel] Clearing search results due to data source change", category: .ui)

        // Cancel any in-flight searches
        cancelSearch()

        // Clear results and query
        results = nil
        searchQuery = ""
        committedSearchQuery = ""
        error = nil

        // Clear all caches
        thumbnailCache.removeAll()
        loadingThumbnails.removeAll()
        savedScrollPosition = 0
        searchGeneration += 1

        // Clear persisted cache
        clearSearchCache()
    }

    // MARK: - Cleanup

    /// Cancel any in-flight search and load-more tasks
    /// Call this when the search overlay is dismissed to prevent blocking
    public func cancelSearch() {
        Log.debug("[SearchViewModel] Cancelling in-flight search tasks", category: .ui)
        currentSearchTask?.cancel()
        currentSearchTask = nil
        currentLoadMoreTask?.cancel()
        currentLoadMoreTask = nil
        isSearching = false
        isLoadingMore = false
    }

    deinit {
        // Cancel tasks directly - deinit is not actor-isolated so we can't call cancelSearch()
        currentSearchTask?.cancel()
        currentLoadMoreTask?.cancel()
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
