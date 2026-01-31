import SwiftUI
import Combine
import Shared
import App

/// Lightweight struct for caching app info to disk
private struct CachedAppInfo: Codable {
    let bundleID: String
    let name: String
}

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
    @Published public var selectedAppFilters: Set<String>?  // nil = all apps, empty set also means all apps
    @Published public var appFilterMode: AppFilterMode = .include  // include or exclude selected apps
    @Published public var startDate: Date?
    @Published public var endDate: Date?
    @Published public var contentType: ContentType = .all
    @Published public var selectedTags: Set<Int64>?  // nil = all tags
    @Published public var tagFilterMode: TagFilterMode = .include  // include or exclude selected tags
    @Published public var hiddenFilter: HiddenFilter = .hide  // How to handle hidden segments
    @Published public var availableTags: [Tag] = []  // Available tags for filter dropdown

    // Search mode (tabs)
    @Published public var searchMode: SearchMode = .relevant

    // Available apps for filter dropdown (installed apps shown first, then "other" apps from DB)
    @Published public var installedApps: [AppInfo] = []
    @Published public var otherApps: [AppInfo] = []  // Apps from DB that aren't currently installed
    @Published public var isLoadingApps = false

    /// Combined list: installed apps + other apps (for backwards compatibility)
    public var availableApps: [AppInfo] {
        installedApps + otherApps
    }

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

    // Dropdown state - tracks whether any filter dropdown is open
    // Used by parent views to handle Escape key properly (dismiss dropdown first, then overlay)
    @Published public var isDropdownOpen = false

    // Signal to close all dropdowns - incremented when Escape is pressed while dropdown is open
    @Published public var closeDropdownsSignal: Int = 0

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
    private static let searchCacheVersion = 3  // v3: Multi-select app filters
    private static let searchCacheVersionKey = "search.cacheVersion"
    /// How long the cached search results remain valid (2 minutes)
    private static let searchCacheExpirationSeconds: TimeInterval = 120

    // MARK: - Other Apps Cache (for uninstalled apps from DB)

    /// Key for storing when the other apps cache was last refreshed
    private static let otherAppsCacheSavedAtKey = "search.otherAppsCacheSavedAt"
    /// How long the other apps cache remains valid (24 hours)
    private static let otherAppsCacheExpirationSeconds: TimeInterval = 24 * 60 * 60

    /// File path for cached other apps data
    private static nonisolated var cachedOtherAppsPath: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("other_apps_cache.json")
    }

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
        // Use CombineLatest to watch all filter properties
        Publishers.CombineLatest4(
            $selectedAppFilters,
            $startDate,
            $endDate,
            $contentType
        )
        .combineLatest($selectedTags, $hiddenFilter)
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

        // Track search event only on explicit submit (Enter key)
        let query = searchQuery
        if !query.isEmpty {
            DashboardViewModel.recordSearch(coordinator: coordinator, query: query)

            // Track filtered search if any filters are active
            if hasActiveFilters {
                let filtersJson = buildFiltersJson()
                DashboardViewModel.recordFilteredSearch(coordinator: coordinator, query: query, filters: filtersJson)
            }
        }

        currentSearchTask = Task {
            await performSearch(query: query)
        }
    }

    /// Build JSON representation of active filters for metrics
    private func buildFiltersJson() -> String {
        var components: [String] = []

        if let apps = selectedAppFilters, !apps.isEmpty {
            let appsArray = apps.map { "\"\($0)\"" }.joined(separator: ",")
            components.append("\"apps\":[\(appsArray)]")
            components.append("\"appMode\":\"\(appFilterMode.rawValue)\"")
        }

        if let startDate = startDate {
            components.append("\"startDate\":\"\(ISO8601DateFormatter().string(from: startDate))\"")
        }

        if let endDate = endDate {
            components.append("\"endDate\":\"\(ISO8601DateFormatter().string(from: endDate))\"")
        }

        if contentType != .all {
            components.append("\"contentType\":\"\(contentType.rawValue)\"")
        }

        if let tags = selectedTags, !tags.isEmpty {
            let tagsArray = tags.map { "\($0)" }.joined(separator: ",")
            components.append("\"tags\":[\(tagsArray)]")
            components.append("\"tagMode\":\"\(tagFilterMode.rawValue)\"")
        }

        if hiddenFilter != .hide {
            components.append("\"hiddenFilter\":\"\(hiddenFilter.rawValue)\"")
        }

        return "{\(components.joined(separator: ","))}"
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
        // Convert Set to Array for the filter, nil if no apps selected (means all apps)
        // Use appBundleIDs for include mode, excludedAppBundleIDs for exclude mode
        let appBundleIDsArray: [String]?
        let excludedAppBundleIDsArray: [String]?

        if let apps = selectedAppFilters, !apps.isEmpty {
            if appFilterMode == .include {
                appBundleIDsArray = Array(apps)
                excludedAppBundleIDsArray = nil
            } else {
                appBundleIDsArray = nil
                excludedAppBundleIDsArray = Array(apps)
            }
        } else {
            appBundleIDsArray = nil
            excludedAppBundleIDsArray = nil
        }

        // Convert tag Set to Array, similar to apps
        let selectedTagIdsArray: [Int64]?
        let excludedTagIdsArray: [Int64]?

        if let tags = selectedTags, !tags.isEmpty {
            if tagFilterMode == .include {
                selectedTagIdsArray = Array(tags)
                excludedTagIdsArray = nil
            } else {
                selectedTagIdsArray = nil
                excludedTagIdsArray = Array(tags)
            }
        } else {
            selectedTagIdsArray = nil
            excludedTagIdsArray = nil
        }

        let filters = SearchFilters(
            startDate: startDate,
            endDate: endDate,
            appBundleIDs: appBundleIDsArray,
            excludedAppBundleIDs: excludedAppBundleIDsArray,
            selectedTagIds: selectedTagIdsArray,
            excludedTagIds: excludedTagIdsArray,
            hiddenFilter: hiddenFilter
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
    /// Phase 1: Instantly load installed apps from /Applications (synchronous)
    /// Phase 2: Load "other" apps from cache (instant) or DB if cache expired
    public func loadAvailableApps() async {
        guard !isLoadingApps else {
            Log.debug("[SearchViewModel] loadAvailableApps skipped - already loading", category: .ui)
            return
        }

        // Skip if already loaded
        guard installedApps.isEmpty else {
            Log.debug("[SearchViewModel] loadAvailableApps skipped - already have \(installedApps.count) installed + \(otherApps.count) other apps", category: .ui)
            return
        }

        isLoadingApps = true
        let startTime = CFAbsoluteTimeGetCurrent()

        // Phase 1: Instant - get installed apps from /Applications folder
        let installed = AppNameResolver.shared.getInstalledApps()
        let installedBundleIDs = Set(installed.map { $0.bundleID })
        installedApps = installed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Log.info("[SearchViewModel] Phase 1: Loaded \(installedApps.count) installed apps in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms", category: .ui)

        // Phase 2: Load "other apps" from cache first (instant), refresh from DB if stale
        let cacheStartTime = CFAbsoluteTimeGetCurrent()
        let (cachedApps, cacheIsStale) = loadOtherAppsFromCache(installedBundleIDs: installedBundleIDs)

        if !cachedApps.isEmpty {
            otherApps = cachedApps
            Log.info("[SearchViewModel] Phase 2: Loaded \(otherApps.count) other apps from cache in \(Int((CFAbsoluteTimeGetCurrent() - cacheStartTime) * 1000))ms (stale: \(cacheIsStale))", category: .ui)
        }

        // If cache is stale or empty, refresh from DB in background
        if cacheIsStale || cachedApps.isEmpty {
            Task.detached { [weak self] in
                await self?.refreshOtherAppsFromDB(installedBundleIDs: installedBundleIDs)
            }
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        Log.info("[SearchViewModel] Total: \(installedApps.count) installed + \(otherApps.count) other apps in \(Int(totalTime * 1000))ms", category: .ui)
        isLoadingApps = false
    }

    // MARK: - Other Apps Cache

    /// Load other apps from disk cache
    /// Returns (apps, isStale) - apps may be empty if no cache exists
    private func loadOtherAppsFromCache(installedBundleIDs: Set<String>) -> ([AppInfo], Bool) {
        // Check if cache exists and is not expired
        let savedAt = UserDefaults.standard.double(forKey: Self.otherAppsCacheSavedAtKey)
        let now = Date().timeIntervalSince1970
        let isStale = savedAt == 0 || (now - savedAt) > Self.otherAppsCacheExpirationSeconds

        // Try to load from disk
        guard FileManager.default.fileExists(atPath: Self.cachedOtherAppsPath.path) else {
            return ([], true)
        }

        do {
            let data = try Data(contentsOf: Self.cachedOtherAppsPath)
            let allCachedApps = try JSONDecoder().decode([CachedAppInfo].self, from: data)

            // Filter out apps that are now installed, and resolve names fresh via AppNameResolver
            // (don't use cached names - they may be stale)
            let uninstalledBundleIDs = allCachedApps
                .map { $0.bundleID }
                .filter { !installedBundleIDs.contains($0) }
            let uninstalledApps = AppNameResolver.shared.resolveAll(bundleIDs: uninstalledBundleIDs)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            return (uninstalledApps, isStale)
        } catch {
            Log.error("[SearchViewModel] Failed to load other apps cache: \(error)", category: .ui)
            return ([], true)
        }
    }

    /// Refresh other apps from DB and save to cache (runs in background)
    private func refreshOtherAppsFromDB(installedBundleIDs: Set<String>) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let bundleIDs = try await coordinator.getDistinctAppBundleIDs()
            let dbApps = AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)

            // Filter to only apps that aren't currently installed
            let uninstalledApps = dbApps
                .filter { !installedBundleIDs.contains($0.bundleID) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Update UI on main thread
            await MainActor.run {
                self.otherApps = uninstalledApps
            }

            // Save ALL apps from DB to cache (not just uninstalled - we filter on load)
            // This way if an app gets uninstalled later, it will appear in "Other Apps"
            saveOtherAppsToCache(dbApps)

            Log.info("[SearchViewModel] Refreshed \(uninstalledApps.count) other apps from DB in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms", category: .ui)
        } catch {
            Log.error("[SearchViewModel] Failed to refresh other apps from DB: \(error)", category: .ui)
        }
    }

    /// Save apps to disk cache
    private func saveOtherAppsToCache(_ apps: [AppInfo]) {
        do {
            let cachedApps = apps.map { CachedAppInfo(bundleID: $0.bundleID, name: $0.name) }
            let data = try JSONEncoder().encode(cachedApps)
            try data.write(to: Self.cachedOtherAppsPath, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.otherAppsCacheSavedAtKey)
            Log.debug("[SearchViewModel] Saved \(apps.count) apps to other apps cache", category: .ui)
        } catch {
            Log.error("[SearchViewModel] Failed to save other apps cache: \(error)", category: .ui)
        }
    }

    /// Toggle an app in the filter - if bundleID is nil, clears all app filters
    public func toggleAppFilter(_ bundleID: String?) {
        guard let bundleID = bundleID else {
            // Clear all app filters (select "All Apps")
            selectedAppFilters = nil
            return
        }

        if selectedAppFilters == nil {
            // Currently showing all apps - start a new selection with just this app
            selectedAppFilters = [bundleID]
        } else if selectedAppFilters!.contains(bundleID) {
            // Remove this app from selection
            selectedAppFilters!.remove(bundleID)
            // If no apps left, go back to "all apps"
            if selectedAppFilters!.isEmpty {
                selectedAppFilters = nil
            }
        } else {
            // Add this app to selection
            selectedAppFilters!.insert(bundleID)
        }
    }

    /// Legacy single-select method for backward compatibility
    public func setAppFilter(_ appBundleID: String?) {
        if let bundleID = appBundleID {
            selectedAppFilters = [bundleID]
        } else {
            selectedAppFilters = nil
        }
    }

    public func setDateRange(start: Date?, end: Date?) {
        startDate = start
        endDate = end
    }

    public func setContentType(_ type: ContentType) {
        contentType = type
    }

    public func clearAllFilters() {
        selectedAppFilters = nil
        appFilterMode = .include
        startDate = nil
        endDate = nil
        contentType = .all
        selectedTags = nil
        tagFilterMode = .include
        hiddenFilter = .hide
    }

    /// Set app filter mode (include/exclude)
    public func setAppFilterMode(_ mode: AppFilterMode) {
        appFilterMode = mode
    }

    // MARK: - Tag Filters

    /// Load available tags for the filter dropdown
    public func loadAvailableTags() async {
        do {
            let tags = try await coordinator.getAllTags()
            await MainActor.run {
                self.availableTags = tags
            }
            Log.debug("[SearchViewModel] Loaded \(tags.count) tags for filter", category: .ui)
        } catch {
            Log.error("[SearchViewModel] Failed to load tags: \(error)", category: .ui)
        }
    }

    /// Toggle a tag in the filter - if tagId is nil, clears all tag filters
    public func toggleTagFilter(_ tagId: TagID?) {
        guard let tagId = tagId else {
            // Clear all tag filters (select "All Tags")
            selectedTags = nil
            return
        }

        let tagIdValue = tagId.value
        if selectedTags == nil {
            // Currently showing all tags - start a new selection with just this tag
            selectedTags = [tagIdValue]
        } else if selectedTags!.contains(tagIdValue) {
            // Remove this tag from selection
            selectedTags!.remove(tagIdValue)
            // If no tags left, go back to "all tags"
            if selectedTags!.isEmpty {
                selectedTags = nil
            }
        } else {
            // Add this tag to selection
            selectedTags!.insert(tagIdValue)
        }
    }

    /// Set tag filter mode (include/exclude)
    public func setTagFilterMode(_ mode: TagFilterMode) {
        tagFilterMode = mode
    }

    /// Set hidden filter mode
    public func setHiddenFilter(_ filter: HiddenFilter) {
        hiddenFilter = filter
    }

    /// Check if any filters are active
    public var hasActiveFilters: Bool {
        (selectedAppFilters != nil && !selectedAppFilters!.isEmpty) ||
        startDate != nil || endDate != nil ||
        (selectedTags != nil && !selectedTags!.isEmpty) ||
        hiddenFilter != .hide
    }

    /// Get the display name for the selected app filter(s)
    public var selectedAppName: String? {
        guard let apps = selectedAppFilters, !apps.isEmpty else { return nil }
        if apps.count == 1 {
            let bundleID = apps.first!
            return availableApps.first(where: { $0.bundleID == bundleID })?.name ?? bundleID.components(separatedBy: ".").last
        } else {
            return "\(apps.count) Apps"
        }
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
        // For share links, use the first selected app if any
        let appBundleID = selectedAppFilters?.first
        return DeeplinkHandler.generateSearchLink(
            query: searchQuery,
            timestamp: result.timestamp,
            appBundleID: appBundleID
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

        // Save filters - convert Set to Array for storage
        if let apps = selectedAppFilters, !apps.isEmpty {
            UserDefaults.standard.set(Array(apps), forKey: Self.cachedAppFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedAppFilterKey)
        }
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

        // Load cached filters - convert Array back to Set
        let cachedAppFilters: Set<String>? = if let apps = UserDefaults.standard.stringArray(forKey: Self.cachedAppFilterKey), !apps.isEmpty {
            Set(apps)
        } else {
            nil
        }
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
            selectedAppFilters = cachedAppFilters
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
