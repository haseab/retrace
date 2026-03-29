import SwiftUI
import Combine
import CryptoKit
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
    typealias SearchExecutor = @Sendable (SearchQuery) async throws -> SearchResults

    // MARK: - Recent Search Entry

    public struct RecentSearchFilters: Codable, Hashable {
        public var appBundleIDs: [String]
        public var appFilterMode: AppFilterMode
        public var tagIDs: [Int64]
        public var tagFilterMode: TagFilterMode
        public var hiddenFilter: HiddenFilter
        public var commentFilter: CommentFilter
        public var startDate: Date?
        public var endDate: Date?
        public var dateRanges: [DateRangeCriterion]
        public var windowNameTerms: [String]  // include terms
        public var windowNameExcludedTerms: [String]
        public var windowNameFilterMode: AppFilterMode
        public var browserUrlTerms: [String]  // include terms
        public var browserUrlExcludedTerms: [String]
        public var browserUrlFilterMode: AppFilterMode
        // Legacy single-value fields (kept for decode compatibility)
        public var windowNameFilter: String?
        public var browserUrlFilter: String?
        public var excludedQueryTerms: [String]

        private enum CodingKeys: String, CodingKey {
            case appBundleIDs
            case appFilterMode
            case tagIDs
            case tagFilterMode
            case hiddenFilter
            case commentFilter
            case startDate
            case endDate
            case dateRanges
            case windowNameTerms
            case windowNameExcludedTerms
            case windowNameFilterMode
            case browserUrlTerms
            case browserUrlExcludedTerms
            case browserUrlFilterMode
            case windowNameFilter
            case browserUrlFilter
            case excludedQueryTerms
        }

        public init(
            appBundleIDs: [String] = [],
            appFilterMode: AppFilterMode = .include,
            tagIDs: [Int64] = [],
            tagFilterMode: TagFilterMode = .include,
            hiddenFilter: HiddenFilter = .hide,
            commentFilter: CommentFilter = .allFrames,
            startDate: Date? = nil,
            endDate: Date? = nil,
            dateRanges: [DateRangeCriterion] = [],
            windowNameTerms: [String] = [],
            windowNameExcludedTerms: [String] = [],
            windowNameFilterMode: AppFilterMode = .include,
            browserUrlTerms: [String] = [],
            browserUrlExcludedTerms: [String] = [],
            browserUrlFilterMode: AppFilterMode = .include,
            windowNameFilter: String? = nil,
            browserUrlFilter: String? = nil,
            excludedQueryTerms: [String] = []
        ) {
            self.appBundleIDs = appBundleIDs
            self.appFilterMode = appFilterMode
            self.tagIDs = tagIDs
            self.tagFilterMode = tagFilterMode
            self.hiddenFilter = hiddenFilter
            self.commentFilter = commentFilter
            self.startDate = startDate
            self.endDate = endDate
            self.dateRanges = dateRanges.filter(\.hasBounds)
            self.windowNameTerms = windowNameTerms
            self.windowNameExcludedTerms = windowNameExcludedTerms
            self.windowNameFilterMode = windowNameFilterMode
            self.browserUrlTerms = browserUrlTerms
            self.browserUrlExcludedTerms = browserUrlExcludedTerms
            self.browserUrlFilterMode = browserUrlFilterMode
            self.windowNameFilter = windowNameFilter
            self.browserUrlFilter = browserUrlFilter
            self.excludedQueryTerms = excludedQueryTerms
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appBundleIDs = try container.decode([String].self, forKey: .appBundleIDs)
            appFilterMode = try container.decode(AppFilterMode.self, forKey: .appFilterMode)
            tagIDs = try container.decode([Int64].self, forKey: .tagIDs)
            tagFilterMode = try container.decode(TagFilterMode.self, forKey: .tagFilterMode)
            hiddenFilter = try container.decode(HiddenFilter.self, forKey: .hiddenFilter)
            commentFilter = try container.decode(CommentFilter.self, forKey: .commentFilter)
            startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
            endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
            dateRanges = (try container.decodeIfPresent([DateRangeCriterion].self, forKey: .dateRanges) ?? []).filter(\.hasBounds)
            if dateRanges.isEmpty, startDate != nil || endDate != nil {
                dateRanges = [DateRangeCriterion(start: startDate, end: endDate)]
            } else if let firstRange = dateRanges.first {
                startDate = firstRange.start
                endDate = firstRange.end
            }
            windowNameTerms = try container.decodeIfPresent([String].self, forKey: .windowNameTerms) ?? []
            windowNameExcludedTerms = try container.decodeIfPresent([String].self, forKey: .windowNameExcludedTerms) ?? []
            windowNameFilterMode = try container.decodeIfPresent(AppFilterMode.self, forKey: .windowNameFilterMode) ?? .include
            browserUrlTerms = try container.decodeIfPresent([String].self, forKey: .browserUrlTerms) ?? []
            browserUrlExcludedTerms = try container.decodeIfPresent([String].self, forKey: .browserUrlExcludedTerms) ?? []
            browserUrlFilterMode = try container.decodeIfPresent(AppFilterMode.self, forKey: .browserUrlFilterMode) ?? .include
            windowNameFilter = try container.decodeIfPresent(String.self, forKey: .windowNameFilter)
            browserUrlFilter = try container.decodeIfPresent(String.self, forKey: .browserUrlFilter)
            if windowNameExcludedTerms.isEmpty, windowNameFilterMode == .exclude, !windowNameTerms.isEmpty {
                windowNameExcludedTerms = windowNameTerms
                windowNameTerms = []
            }
            if browserUrlExcludedTerms.isEmpty, browserUrlFilterMode == .exclude, !browserUrlTerms.isEmpty {
                browserUrlExcludedTerms = browserUrlTerms
                browserUrlTerms = []
            }
            if windowNameTerms.isEmpty, windowNameExcludedTerms.isEmpty, let windowNameFilter, !windowNameFilter.isEmpty {
                if windowNameFilterMode == .exclude {
                    windowNameExcludedTerms = [windowNameFilter]
                } else {
                    windowNameTerms = [windowNameFilter]
                }
            }
            if browserUrlTerms.isEmpty, browserUrlExcludedTerms.isEmpty, let browserUrlFilter, !browserUrlFilter.isEmpty {
                if browserUrlFilterMode == .exclude {
                    browserUrlExcludedTerms = [browserUrlFilter]
                } else {
                    browserUrlTerms = [browserUrlFilter]
                }
            }
            excludedQueryTerms = try container.decodeIfPresent([String].self, forKey: .excludedQueryTerms) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(appBundleIDs, forKey: .appBundleIDs)
            try container.encode(appFilterMode, forKey: .appFilterMode)
            try container.encode(tagIDs, forKey: .tagIDs)
            try container.encode(tagFilterMode, forKey: .tagFilterMode)
            try container.encode(hiddenFilter, forKey: .hiddenFilter)
            try container.encode(commentFilter, forKey: .commentFilter)
            let effectiveRanges = self.effectiveDateRanges
            try container.encodeIfPresent(effectiveRanges.first?.start ?? startDate, forKey: .startDate)
            try container.encodeIfPresent(effectiveRanges.first?.end ?? endDate, forKey: .endDate)
            try container.encode(effectiveRanges, forKey: .dateRanges)
            try container.encode(windowNameTerms, forKey: .windowNameTerms)
            try container.encode(windowNameExcludedTerms, forKey: .windowNameExcludedTerms)
            try container.encode(windowNameFilterMode, forKey: .windowNameFilterMode)
            try container.encode(browserUrlTerms, forKey: .browserUrlTerms)
            try container.encode(browserUrlExcludedTerms, forKey: .browserUrlExcludedTerms)
            try container.encode(browserUrlFilterMode, forKey: .browserUrlFilterMode)
            try container.encodeIfPresent(windowNameTerms.first ?? windowNameExcludedTerms.first, forKey: .windowNameFilter)
            try container.encodeIfPresent(browserUrlTerms.first ?? browserUrlExcludedTerms.first, forKey: .browserUrlFilter)
            try container.encode(excludedQueryTerms, forKey: .excludedQueryTerms)
        }

        public var effectiveDateRanges: [DateRangeCriterion] {
            let sanitized = dateRanges.filter(\.hasBounds)
            if !sanitized.isEmpty {
                return sanitized
            }
            if startDate != nil || endDate != nil {
                return [DateRangeCriterion(start: startDate, end: endDate)]
            }
            return []
        }
    }

    public struct RecentSearchEntry: Codable, Hashable, Identifiable {
        public let key: String
        public var query: String
        public var usageCount: Int
        public var lastUsedAt: TimeInterval
        public var filters: RecentSearchFilters

        public var id: String { key }

        private enum CodingKeys: String, CodingKey {
            case key
            case query
            case usageCount
            case lastUsedAt
            case filters
        }

        public init(
            key: String,
            query: String,
            usageCount: Int,
            lastUsedAt: TimeInterval,
            filters: RecentSearchFilters
        ) {
            self.key = key
            self.query = query
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
            self.filters = filters
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            query = try container.decode(String.self, forKey: .query)
            usageCount = try container.decode(Int.self, forKey: .usageCount)
            lastUsedAt = try container.decode(TimeInterval.self, forKey: .lastUsedAt)
            filters = try container.decodeIfPresent(RecentSearchFilters.self, forKey: .filters) ?? RecentSearchFilters()
        }
    }

    // MARK: - Published State

    @Published public var searchQuery: String = "" {
        didSet {
            updateVisibleResults()
        }
    }
    @Published public var results: SearchResults? {
        didSet {
            resultSetBytes = SearchMemoryEstimator.searchResultsBytes(results?.results ?? [])
            updateVisibleResults()
        }
    }
    @Published public var isSearching = false
    @Published public var isLoadingMore = false
    @Published public var error: String?

    // Filters
    @Published public var selectedAppFilters: Set<String>?  // nil = all apps, empty set also means all apps
    @Published public var appFilterMode: AppFilterMode = .include  // include or exclude selected apps
    @Published public var startDate: Date?
    @Published public var endDate: Date?
    @Published public var dateRanges: [DateRangeCriterion] = []
    @Published public var contentType: ContentType = .all
    @Published public var selectedTags: Set<Int64>?  // nil = all tags
    @Published public var tagFilterMode: TagFilterMode = .include  // include or exclude selected tags
    @Published public var hiddenFilter: HiddenFilter = .hide  // How to handle hidden segments
    @Published public var commentFilter: CommentFilter = .allFrames  // How to handle comment presence
    @Published public var windowNameTerms: [String] = []  // include terms
    @Published public var windowNameExcludedTerms: [String] = []
    @Published public var windowNameFilterMode: AppFilterMode = .include
    @Published public var browserUrlTerms: [String] = []  // include terms
    @Published public var browserUrlExcludedTerms: [String] = []
    @Published public var browserUrlFilterMode: AppFilterMode = .include
    @Published public var excludedSearchTerms: [String] = []  // Query terms/phrases excluded via Advanced filter
    @Published public var availableTags: [Tag] = []  // Available tags for filter dropdown

    // Search mode (tabs)
    @Published public var searchMode: SearchMode = .all

    // Sort order (for "all" mode)
    @Published public var sortOrder: SearchSortOrder = .newestFirst

    // Available apps for filter dropdown (installed apps shown first, then "other" apps from DB)
    @Published public var installedApps: [AppInfo] = []
    @Published public var otherApps: [AppInfo] = []  // Apps from DB that aren't currently installed
    @Published public var isLoadingApps = false

    /// Combined list: installed apps + other apps (for backwards compatibility)
    public var availableApps: [AppInfo] {
        Self.deduplicateAppsByBundleID(installedApps + otherApps)
    }

    nonisolated static func deduplicateAppsByBundleID(_ apps: [AppInfo]) -> [AppInfo] {
        var seenBundleIDs = Set<String>()
        return apps.filter { seenBundleIDs.insert($0.bundleID).inserted }
    }

    /// Effective date ranges for filtering. Falls back to legacy single-range fields.
    public var effectiveDateRanges: [DateRangeCriterion] {
        let sanitized = dateRanges.filter(\.hasBounds)
        if !sanitized.isEmpty {
            return sanitized
        }
        if startDate != nil || endDate != nil {
            return [DateRangeCriterion(start: startDate, end: endDate)]
        }
        return []
    }

    // Selected result
    @Published public var selectedResult: SearchResult?
    @Published public var showingFrameViewer = false

    // Scroll position - persists across overlay open/close
    public var savedScrollPosition: CGFloat = 0

    // Thumbnail cache - persists across overlay open/close, cleared on new search
    @Published public var thumbnailCache: [String: NSImage] = [:] {
        didSet {
            thumbnailCacheBytes = UIMemoryEstimator.imageDictionaryBytes(thumbnailCache)
        }
    }
    @Published public var loadingThumbnails: Set<String> = []
    @Published public var appIconCache: [String: NSImage] = [:] {
        didSet {
            appIconCacheBytes = UIMemoryEstimator.imageDictionaryBytes(appIconCache)
        }
    }

    // Search generation counter - incremented on each new search to invalidate in-flight loads
    @Published public var searchGeneration: Int = 0

    // The committed search query (set when user presses Enter)
    // Used for thumbnail cache keys so thumbnails don't reload while typing
    @Published public var committedSearchQuery: String = "" {
        didSet {
            updateVisibleResults()
        }
    }

    /// Search results shown by the overlay.
    /// Kept as a derived cache so SwiftUI reads a stable array.
    @Published public private(set) var visibleResults: [SearchResult] = []

    // Dropdown state - tracks whether any filter dropdown is open
    // Used by parent views to handle Escape key properly (dismiss dropdown first, then overlay)
    @Published public var isDropdownOpen = false

    /// Whether the recent-entries popover is currently visible in the search overlay.
    /// Used by timeline controller to decide when wheel events should be blocked.
    @Published public var isRecentEntriesPopoverVisible = false

    // Whether the search overlay is currently in expanded mode (filters/results visible).
    // Used by timeline-level event routing to keep scroll input inside the expanded overlay.
    @Published public var isSearchOverlayExpanded = false

    // Whether the spotlight search text field currently owns focus.
    // Used by Escape routing so results return focus to the field before dismissing.
    @Published public var isSearchFieldFocused = false

    // Whether the DateFilterPopover is actively handling keyboard events (Tab/Enter/arrows)
    // When true, SearchFilterBar's tab monitor and TimelineWindowController's arrow key handler skip processing
    public var isDatePopoverHandlingKeys = false

    // Signal to close all dropdowns - incremented when Escape is pressed while dropdown is open
    @Published public var closeDropdownsSignal: Int = 0

    // Signal to open a specific filter dropdown via Tab key navigation
    // Values: 0 = search field, 1 = order, 2 = apps, 3 = date, 4 = tags, 5 = visibility, 6 = comments, 7 = advanced
    @Published public var openFilterSignal: (index: Int, id: UUID) = (0, UUID())

    // Signal to dismiss the search overlay from parent-level handlers (e.g. global Escape).
    // clearSearchState=true clears query/results/filters after the overlay fade-out completes.
    @Published public var dismissOverlaySignal: (clearSearchState: Bool, id: UUID) = (false, UUID())

    // Signal to collapse overlay UI back to compact search bar without dismissing.
    @Published public var collapseOverlaySignal: UUID = UUID()

    // Signal to refocus the spotlight search field from parent-level handlers.
    @Published public var focusSearchFieldSignal: UUID = UUID()

    // Signal to dismiss the recent-entries popover as if the user clicked the header "x".
    @Published public var dismissRecentEntriesPopoverSignal: UUID = UUID()

    /// Recent submitted search queries used by spotlight "Recent Entries" popover.
    @Published public private(set) var recentSearchEntries: [RecentSearchEntry] = [] {
        didSet {
            recentSearchEntriesBytes = SearchMemoryEstimator.recentSearchEntriesBytes(recentSearchEntries)
        }
    }

    /// One-shot delay for showing the "Recent Entries" popover on next overlay open.
    private var nextRecentEntriesRevealDelay: TimeInterval = 0

    /// One-shot suppression for the "Recent Entries" popover on next overlay open.
    private var suppressRecentEntriesOnNextOverlayOpen = false

    // Flag to prevent re-search during cache restore
    private var isRestoringFromCache = false

    // Flag to track if user has submitted a search at least once
    // Filter changes only auto-trigger re-search after first submit
    private var hasSubmittedSearch = false

    // Pagination termination state for infinite scroll.
    // We stop loading only when the backend returns an empty page.
    private var didReachPaginationEnd = false
    // Backend keyset cursor for infinite scroll.
    private var nextPageCursor: SearchPageCursor?

    // One-shot suppression window for filter-change auto-search.
    // Used to avoid immediate duplicate re-search after deeplink applies filters + submits.
    private var suppressFilterAutoSearchUntil: Date?

    // MARK: - Dependencies

    public let coordinator: AppCoordinator
    private let executeSearch: SearchExecutor
    private var cancellables = Set<AnyCancellable>()

    // Active search tasks that can be cancelled
    private var currentSearchTask: Task<Void, Never>?
    private var currentLoadMoreTask: Task<Void, Never>?
    private var pendingOtherAppsRefreshTask: Task<Void, Never>?
    private var memoryReportTask: Task<Void, Never>?
    private var thumbnailCacheBytes: Int64 = 0
    private var appIconCacheBytes: Int64 = 0
    private var resultSetBytes: Int64 = 0
    private var recentSearchEntriesBytes: Int64 = 0
    private var thumbnailLRUKeys: [String] = []

    // MARK: - Constants

    private let debounceDelay: TimeInterval = 0.3
    private let defaultResultLimit = 50
    private let maxSearchWords = 15  // Limit search queries to prevent performance issues
    private let otherAppsRefreshDelayNs: UInt64 = 2_000_000_000
    private let memoryReportIntervalNs: UInt64 = 5_000_000_000
    private let maxInMemoryThumbnailCount = 60
    nonisolated private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    nonisolated private static let memoryLedgerThumbnailTag = "ui.search.thumbnailCache"
    nonisolated private static let memoryLedgerAppIconTag = "ui.search.appIconCache"
    nonisolated private static let memoryLedgerResultSetTag = "ui.search.resultSet"
    nonisolated private static let memoryLedgerRecentSearchesTag = "ui.search.recentEntries"
    private static let thumbnailDiskCacheMaxBytes: Int64 = 512 * 1024 * 1024
    private static let thumbnailDiskCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maxRecentSearchEntryCount = 80
    private static let recentSearchEntriesKey = "search.recentEntries.v1"
    private static let encodedMetadataFilterPrefix = "__retrace_meta_filter_v1__"

    private struct EncodedMetadataFilterPayload: Codable {
        let includeTerms: [String]
        let excludeTerms: [String]
    }

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
    /// Key for storing cached multi-range date filters
    private static let cachedDateRangesKey = "search.cachedDateRanges"
    /// Key for storing the cached content type
    private static let cachedContentTypeKey = "search.cachedContentType"
    /// Keys for storing cached advanced metadata filters.
    private static let cachedWindowNameTermsKey = "search.cachedWindowNameTerms"
    private static let cachedWindowNameExcludeTermsKey = "search.cachedWindowNameExcludeTerms"
    private static let cachedWindowNameModeKey = "search.cachedWindowNameMode"
    private static let cachedBrowserUrlTermsKey = "search.cachedBrowserUrlTerms"
    private static let cachedBrowserUrlExcludeTermsKey = "search.cachedBrowserUrlExcludeTerms"
    private static let cachedBrowserUrlModeKey = "search.cachedBrowserUrlMode"
    // Legacy keys kept for one-way migration.
    private static let cachedWindowNameFilterKey = "search.cachedWindowNameFilter"
    private static let cachedBrowserUrlFilterKey = "search.cachedBrowserUrlFilter"
    /// Key for storing cached excluded query terms
    private static let cachedExcludedSearchTermsKey = "search.cachedExcludedSearchTerms"
    /// Key for storing the cached comment filter
    private static let cachedCommentFilterKey = "search.cachedCommentFilter"
    /// Key for storing the cached search mode
    private static let cachedSearchModeKey = "search.cachedSearchMode"
    /// Key for storing the cached sort order
    private static let cachedSearchSortOrderKey = "search.cachedSearchSortOrder"
    /// Cache version - increment when data structure changes to invalidate old caches
    private static let searchCacheVersion = 6  // v6: adds multi-range date filter cache support
    private static let searchCacheVersionKey = "search.cacheVersion"
    /// How long cached search results remain valid.
    /// Keep this aligned with timeline hidden-state cache invalidation.
    private static let searchCacheExpirationSeconds: TimeInterval = TimelineWindowController.hiddenStateCacheExpirationSeconds

    // MARK: - Other Apps Cache (for uninstalled apps from DB)

    /// Key for storing when the other apps cache was last refreshed
    private nonisolated static let otherAppsCacheSavedAtKey = "search.otherAppsCacheSavedAt"
    /// How long the other apps cache remains valid (24 hours)
    private nonisolated static let otherAppsCacheExpirationSeconds: TimeInterval = 24 * 60 * 60

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

    /// File path for disk-backed search thumbnails.
    private static nonisolated var cachedSearchThumbnailsDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("search_thumbnails_v1", isDirectory: true)
    }

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.executeSearch = { query in
            try await coordinator.search(query: query)
        }
        loadRecentSearchEntries()
        setupBindings()
        startMemoryReporting()
        prepareThumbnailDiskCache()
    }

    init(coordinator: AppCoordinator, executeSearch: @escaping SearchExecutor) {
        self.coordinator = coordinator
        self.executeSearch = executeSearch
        loadRecentSearchEntries()
        setupBindings()
        startMemoryReporting()
        prepareThumbnailDiskCache()
    }

    // MARK: - Setup

    private func setupBindings() {
        // NOTE: Auto-search on typing is disabled - search is triggered manually on Enter
        // Clear results and cache when query is cleared by user (not on init)
        $searchQuery
            .removeDuplicates()
            .dropFirst()  // Skip initial empty value so we don't clear cache on init
            .sink { [weak self] query in
                if query.isEmpty {
                    self?.results = nil
                    self?.committedSearchQuery = ""
                    self?.hasSubmittedSearch = false  // Reset so filters don't auto-update for new query
                    self?.resetSearchOrderToDefault()
                    self?.clearInMemoryThumbnailCache()
                    self?.clearSearchCache()
                } else {
                    self?.pendingOtherAppsRefreshTask?.cancel()
                    self?.pendingOtherAppsRefreshTask = nil
                }
            }
            .store(in: &cancellables)

        // Re-search when filters change (skip during cache restore and before first submit)
        // Use CombineLatest to watch all filter properties
        Publishers.CombineLatest4(
            $selectedAppFilters,
            $startDate,
            $endDate,
            $contentType
        )
        .combineLatest($dateRanges)
        .combineLatest($selectedTags, $hiddenFilter, $commentFilter)
        .combineLatest(
            Publishers.CombineLatest3(
                Publishers.CombineLatest($windowNameTerms, $windowNameExcludedTerms),
                Publishers.CombineLatest($browserUrlTerms, $browserUrlExcludedTerms),
                $excludedSearchTerms
            )
        )
        .dropFirst()  // Skip initial values
        .debounce(for: .seconds(debounceDelay), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self else { return }

            if let until = self.suppressFilterAutoSearchUntil {
                if Date() <= until {
                    self.suppressFilterAutoSearchUntil = nil
                    return
                }

                // Suppression window expired without a matching event.
                self.suppressFilterAutoSearchUntil = nil
            }

            // Only auto-trigger re-search if:
            // 1. Query is not empty
            // 2. Not restoring from cache
            // 3. User has already submitted a search at least once
            guard !self.searchQuery.isEmpty,
                  !self.isRestoringFromCache,
                  self.hasSubmittedSearch else { return }

            self.startFreshSearchTask(query: self.searchQuery, trigger: "filter-change")
        }
        .store(in: &cancellables)
    }

    private func prepareThumbnailDiskCache() {
        Task.detached(priority: .utility) {
            let directory = Self.cachedSearchThumbnailsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.trimThumbnailDiskCache(
                maxBytes: Self.thumbnailDiskCacheMaxBytes,
                maxAge: Self.thumbnailDiskCacheMaxAge
            )
        }
    }

    private func clearInMemoryThumbnailCache() {
        thumbnailCache.removeAll()
        loadingThumbnails.removeAll()
        thumbnailLRUKeys.removeAll()
    }

    public func beginThumbnailLoadIfNeeded(_ key: String) -> Bool {
        if thumbnailCache[key] != nil {
            markThumbnailAccessed(key)
            return false
        }
        guard !loadingThumbnails.contains(key) else { return false }
        loadingThumbnails.insert(key)
        return true
    }

    public func markThumbnailAccessed(_ key: String) {
        guard thumbnailCache[key] != nil else { return }
        touchThumbnailKey(key)
    }

    public func finishThumbnailLoad(
        _ image: NSImage,
        for key: String,
        generation: Int,
        persistToDisk: Bool = true
    ) {
        guard searchGeneration == generation else {
            loadingThumbnails.remove(key)
            return
        }
        insertThumbnailIntoMemory(image, for: key)
        loadingThumbnails.remove(key)
        if persistToDisk {
            persistThumbnailToDisk(image, for: key)
        }
    }

    public func failThumbnailLoad(
        with placeholder: NSImage?,
        for key: String,
        generation: Int
    ) {
        guard searchGeneration == generation else {
            loadingThumbnails.remove(key)
            return
        }
        if let placeholder {
            insertThumbnailIntoMemory(placeholder, for: key)
        }
        loadingThumbnails.remove(key)
    }

    public func loadThumbnailFromDiskIfAvailable(for key: String, generation: Int) async -> Bool {
        if thumbnailCache[key] != nil {
            touchThumbnailKey(key)
            return true
        }

        let url = Self.diskThumbnailURL(for: key)
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value

        guard let data, searchGeneration == generation else { return false }
        guard let image = NSImage(data: data) else { return false }

        insertThumbnailIntoMemory(image, for: key)
        return true
    }

    private func insertThumbnailIntoMemory(_ image: NSImage, for key: String) {
        thumbnailCache[key] = image
        touchThumbnailKey(key)
        evictThumbnailsIfNeeded()
    }

    private func touchThumbnailKey(_ key: String) {
        if let existingIndex = thumbnailLRUKeys.firstIndex(of: key) {
            thumbnailLRUKeys.remove(at: existingIndex)
        }
        thumbnailLRUKeys.append(key)
    }

    private func evictThumbnailsIfNeeded() {
        guard thumbnailCache.count > maxInMemoryThumbnailCount else { return }

        let evictCount = thumbnailCache.count - maxInMemoryThumbnailCount
        for _ in 0..<evictCount {
            guard let oldestKey = thumbnailLRUKeys.first else { break }
            thumbnailLRUKeys.removeFirst()
            thumbnailCache.removeValue(forKey: oldestKey)
        }
    }

    private func persistThumbnailToDisk(_ image: NSImage, for key: String) {
        guard let tiffData = image.tiffRepresentation else { return }
        let targetURL = Self.diskThumbnailURL(for: key)

        Task.detached(priority: .utility) {
            guard let data = Self.jpegData(fromTIFFData: tiffData) else { return }
            let directory = Self.cachedSearchThumbnailsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try data.write(to: targetURL, options: .atomic)
                Self.trimThumbnailDiskCache(
                    maxBytes: Self.thumbnailDiskCacheMaxBytes,
                    maxAge: Self.thumbnailDiskCacheMaxAge
                )
            } catch {
                // Ignore disk cache write failures; memory cache still serves this thumbnail.
            }
        }
    }

    private nonisolated static func diskThumbnailURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return cachedSearchThumbnailsDirectory.appendingPathComponent("\(fileName).jpg")
    }

    private nonisolated static func jpegData(fromTIFFData tiffData: Data) -> Data? {
        guard let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.72]
        )
    }

    private nonisolated static func trimThumbnailDiskCache(maxBytes: Int64, maxAge: TimeInterval) {
        let directory = cachedSearchThumbnailsDirectory
        let fileManager = FileManager.default

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        struct DiskEntry {
            let url: URL
            let modifiedAt: Date
            let size: Int64
        }

        var entries: [DiskEntry] = []
        var totalBytes: Int64 = 0

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)

            if modifiedAt < cutoff {
                try? fileManager.removeItem(at: url)
                continue
            }

            entries.append(DiskEntry(url: url, modifiedAt: modifiedAt, size: size))
            totalBytes += size
        }

        guard totalBytes > maxBytes else { return }

        let sortedByOldest = entries.sorted { $0.modifiedAt < $1.modifiedAt }
        for entry in sortedByOldest where totalBytes > maxBytes {
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private func startMemoryReporting() {
        memoryReportTask?.cancel()
        let intervalNs = Int64(memoryReportIntervalNs)
        memoryReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(intervalNs), clock: .continuous)
                guard !Task.isCancelled, let self else { break }
                self.logMemorySnapshot()
            }
        }
    }

    private func logMemorySnapshot() {
        let resultCount = results?.results.count ?? 0
        Log.info(
            "[Search-Memory] results=\(resultCount) visibleResults=\(visibleResults.count) thumbnails=\(thumbnailCache.count)/\(Self.formatBytes(thumbnailCacheBytes)) appIcons=\(appIconCache.count)/\(Self.formatBytes(appIconCacheBytes))",
            category: .ui
        )

        updateMemoryLedger(resultCount: resultCount)
    }

    private func updateMemoryLedger(resultCount: Int) {
        MemoryLedger.set(
            tag: Self.memoryLedgerThumbnailTag,
            bytes: thumbnailCacheBytes,
            count: thumbnailCache.count,
            unit: "images",
            function: "ui.search",
            kind: "images"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerAppIconTag,
            bytes: appIconCacheBytes,
            count: appIconCache.count,
            unit: "icons",
            function: "ui.search",
            kind: "images"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerResultSetTag,
            bytes: resultSetBytes,
            count: resultCount,
            unit: "results",
            function: "ui.search",
            kind: "result-window",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerRecentSearchesTag,
            bytes: recentSearchEntriesBytes,
            count: recentSearchEntries.count,
            unit: "entries",
            function: "ui.search",
            kind: "recent-searches",
            note: "estimated"
        )
        MemoryLedger.emitSummary(
            reason: "ui.search.memory",
            category: .ui,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func updateVisibleResults() {
        guard let allResults = results?.results, !allResults.isEmpty else {
            visibleResults = []
            return
        }

        // URL-only filtering was removed from the client path.
        // Search now scopes MATCH to FTS column `text`, so metadata-only hits
        // (window title / URL columns) are excluded by the query itself.
        visibleResults = allResults
    }

    // MARK: - Recent Search Entries

    public func rankedRecentSearchEntries(for query: String, limit: Int = 8) -> [RecentSearchEntry] {
        guard limit > 0 else { return [] }
        let sourceEntries = recentSearchEntries
        guard !sourceEntries.isEmpty else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return sourceEntries
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.lastUsedAt != rhs.element.lastUsedAt {
                        return lhs.element.lastUsedAt > rhs.element.lastUsedAt
                    }
                    if lhs.element.usageCount != rhs.element.usageCount {
                        return lhs.element.usageCount > rhs.element.usageCount
                    }
                    return lhs.offset < rhs.offset
                }
                .prefix(limit)
                .map(\.element)
        }

        return sourceEntries
            .enumerated()
            .map { index, entry -> (entry: RecentSearchEntry, fuzzyScore: Int, index: Int)? in
                let fuzzyResult = Self.fuzzyMatch(query: trimmedQuery, text: entry.query)
                guard fuzzyResult.matches else { return nil }
                return (entry: entry, fuzzyScore: fuzzyResult.score, index: index)
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                // While typing, prioritize frequently used queries.
                if lhs.entry.usageCount != rhs.entry.usageCount {
                    return lhs.entry.usageCount > rhs.entry.usageCount
                }
                if lhs.fuzzyScore != rhs.fuzzyScore {
                    return lhs.fuzzyScore > rhs.fuzzyScore
                }
                if lhs.entry.lastUsedAt != rhs.entry.lastUsedAt {
                    return lhs.entry.lastUsedAt > rhs.entry.lastUsedAt
                }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map(\.entry)
    }

    public func submitRecentSearchEntry(_ entry: RecentSearchEntry) {
        applyRecentSearchFilters(entry.filters)
        searchQuery = entry.query
        submitSearch(trigger: "recent-entry")
    }

    public func applyRecentSearchFilters(_ filters: RecentSearchFilters) {
        selectedAppFilters = filters.appBundleIDs.isEmpty ? nil : Set(filters.appBundleIDs)
        appFilterMode = filters.appFilterMode
        selectedTags = filters.tagIDs.isEmpty ? nil : Set(filters.tagIDs)
        tagFilterMode = filters.tagFilterMode
        hiddenFilter = filters.hiddenFilter
        commentFilter = filters.commentFilter
        let restoredDateRanges = Array(filters.effectiveDateRanges.prefix(5))
        dateRanges = restoredDateRanges
        startDate = restoredDateRanges.first?.start
        endDate = restoredDateRanges.first?.end
        let legacyWindowTerms = filters.windowNameFilter.map { [$0] } ?? []
        let legacyBrowserTerms = filters.browserUrlFilter.map { [$0] } ?? []
        let restoredWindowIncludeSource = filters.windowNameTerms.isEmpty
            ? (filters.windowNameFilterMode == .include ? legacyWindowTerms : [])
            : filters.windowNameTerms
        let restoredWindowExcludeSource = filters.windowNameExcludedTerms.isEmpty
            ? (filters.windowNameFilterMode == .exclude ? legacyWindowTerms : [])
            : filters.windowNameExcludedTerms
        let restoredWindowBuckets = normalizedMetadataFilterBuckets(
            include: restoredWindowIncludeSource,
            exclude: restoredWindowExcludeSource
        )
        windowNameTerms = restoredWindowBuckets.includeTerms
        windowNameExcludedTerms = restoredWindowBuckets.excludeTerms

        let restoredBrowserIncludeSource = filters.browserUrlTerms.isEmpty
            ? (filters.browserUrlFilterMode == .include ? legacyBrowserTerms : [])
            : filters.browserUrlTerms
        let restoredBrowserExcludeSource = filters.browserUrlExcludedTerms.isEmpty
            ? (filters.browserUrlFilterMode == .exclude ? legacyBrowserTerms : [])
            : filters.browserUrlExcludedTerms
        let restoredBrowserBuckets = normalizedMetadataFilterBuckets(
            include: restoredBrowserIncludeSource,
            exclude: restoredBrowserExcludeSource
        )
        browserUrlTerms = restoredBrowserBuckets.includeTerms
        browserUrlExcludedTerms = restoredBrowserBuckets.excludeTerms
        windowNameFilterMode = filters.windowNameFilterMode
        browserUrlFilterMode = filters.browserUrlFilterMode
        excludedSearchTerms = normalizedExcludedSearchTerms(filters.excludedQueryTerms)
    }

    public func recordRecentSearchEntry(_ query: String) {
        let sanitizedQuery = Self.sanitizedRecentSearchQuery(query)
        guard !sanitizedQuery.isEmpty else { return }

        let filters = currentRecentSearchFilters()
        let key = Self.recentSearchKey(for: sanitizedQuery, filters: filters)
        let now = Date().timeIntervalSince1970

        var entries = recentSearchEntries
        if let existingIndex = entries.firstIndex(where: { $0.key == key }) {
            var existingEntry = entries.remove(at: existingIndex)
            existingEntry.query = sanitizedQuery
            existingEntry.usageCount += 1
            existingEntry.lastUsedAt = now
            existingEntry.filters = filters
            entries.insert(existingEntry, at: 0)
        } else {
            let newEntry = RecentSearchEntry(
                key: key,
                query: sanitizedQuery,
                usageCount: 1,
                lastUsedAt: now,
                filters: filters
            )
            entries.insert(newEntry, at: 0)
        }

        if entries.count > Self.maxRecentSearchEntryCount {
            entries.removeLast(entries.count - Self.maxRecentSearchEntryCount)
        }

        recentSearchEntries = entries
        saveRecentSearchEntries()
    }

    public func removeRecentSearchEntry(_ entry: RecentSearchEntry) {
        removeRecentSearchEntry(key: entry.key)
    }

    public func removeRecentSearchEntry(key: String) {
        guard !key.isEmpty else { return }

        let priorCount = recentSearchEntries.count
        recentSearchEntries.removeAll { $0.key == key }
        guard recentSearchEntries.count != priorCount else { return }
        saveRecentSearchEntries()
    }

    private func currentRecentSearchFilters() -> RecentSearchFilters {
        let appBundleIDs = (selectedAppFilters ?? []).sorted()
        let tagIDs = (selectedTags ?? []).sorted()
        let normalizedWindowBuckets = normalizedMetadataFilterBuckets(
            include: windowNameTerms,
            exclude: windowNameExcludedTerms
        )
        let normalizedBrowserBuckets = normalizedMetadataFilterBuckets(
            include: browserUrlTerms,
            exclude: browserUrlExcludedTerms
        )

        return RecentSearchFilters(
            appBundleIDs: appBundleIDs,
            appFilterMode: appFilterMode,
            tagIDs: tagIDs,
            tagFilterMode: tagFilterMode,
            hiddenFilter: hiddenFilter,
            commentFilter: commentFilter,
            startDate: effectiveDateRanges.first?.start,
            endDate: effectiveDateRanges.first?.end,
            dateRanges: effectiveDateRanges,
            windowNameTerms: normalizedWindowBuckets.includeTerms,
            windowNameExcludedTerms: normalizedWindowBuckets.excludeTerms,
            windowNameFilterMode: windowNameFilterMode,
            browserUrlTerms: normalizedBrowserBuckets.includeTerms,
            browserUrlExcludedTerms: normalizedBrowserBuckets.excludeTerms,
            browserUrlFilterMode: browserUrlFilterMode,
            windowNameFilter: normalizedWindowBuckets.includeTerms.first ?? normalizedWindowBuckets.excludeTerms.first,
            browserUrlFilter: normalizedBrowserBuckets.includeTerms.first ?? normalizedBrowserBuckets.excludeTerms.first,
            excludedQueryTerms: normalizedExcludedSearchTerms(excludedSearchTerms)
        )
    }

    private func loadRecentSearchEntries() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentSearchEntriesKey) else { return }
        do {
            let entries = try JSONDecoder().decode([RecentSearchEntry].self, from: data)
            recentSearchEntries = entries
        } catch {
            recentSearchEntries = []
            UserDefaults.standard.removeObject(forKey: Self.recentSearchEntriesKey)
            Log.warning("[SearchViewModel] Failed to decode recent search entries: \(error)", category: .ui)
        }
    }

    private func saveRecentSearchEntries() {
        do {
            let encoded = try JSONEncoder().encode(recentSearchEntries)
            UserDefaults.standard.set(encoded, forKey: Self.recentSearchEntriesKey)
        } catch {
            Log.warning("[SearchViewModel] Failed to save recent search entries: \(error)", category: .ui)
        }
    }

    private static func recentSearchKey(for query: String, filters: RecentSearchFilters) -> String {
        let normalizedQuery = normalizedRecentSearchQuery(query)
        let filterFingerprint = recentSearchFilterFingerprint(filters)
        let rawKey = "\(normalizedQuery)|\(filterFingerprint)"
        return sha256(rawKey)
    }

    private static func sanitizedRecentSearchQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizedRecentSearchQuery(_ query: String) -> String {
        sanitizedRecentSearchQuery(query).lowercased()
    }

    private static func recentSearchFilterFingerprint(_ filters: RecentSearchFilters) -> String {
        [
            "apps=\(filters.appFilterMode.rawValue):\(filters.appBundleIDs.joined(separator: ","))",
            "tags=\(filters.tagFilterMode.rawValue):\(filters.tagIDs.map(String.init).joined(separator: ","))",
            "visibility=\(filters.hiddenFilter.rawValue)",
            "comments=\(filters.commentFilter.rawValue)",
            "dateRanges=\(filters.effectiveDateRanges.map { "\($0.start?.timeIntervalSince1970 ?? -1)-\($0.end?.timeIntervalSince1970 ?? -1)" }.joined(separator: ","))",
            "window=include:\(filters.windowNameTerms.map { $0.lowercased() }.sorted().joined(separator: ","));exclude:\(filters.windowNameExcludedTerms.map { $0.lowercased() }.sorted().joined(separator: ","))",
            "url=include:\(filters.browserUrlTerms.map { $0.lowercased() }.sorted().joined(separator: ","));exclude:\(filters.browserUrlExcludedTerms.map { $0.lowercased() }.sorted().joined(separator: ","))",
            "exclude=\(filters.excludedQueryTerms.map { $0.lowercased() }.sorted().joined(separator: ","))"
        ]
        .joined(separator: "|")
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fuzzyMatch(query: String, text: String) -> (matches: Bool, score: Int) {
        if query.isEmpty { return (true, 0) }

        let queryLower = query.lowercased()
        let textLower = text.lowercased()

        var queryIndex = queryLower.startIndex
        var score = 0
        var lastMatchOffset: Int? = nil

        for (offset, character) in textLower.enumerated() {
            guard queryIndex < queryLower.endIndex else { break }
            guard character == queryLower[queryIndex] else { continue }

            let previousCharacter = offset > 0 ? textLower[textLower.index(textLower.startIndex, offsetBy: offset - 1)] : nil
            let isWordStart = previousCharacter == nil || previousCharacter == " " || previousCharacter == "-"
            score += isWordStart ? 5 : 1

            if let lastMatchOffset, lastMatchOffset == offset - 1 {
                score += 5
            }

            lastMatchOffset = offset
            queryIndex = queryLower.index(after: queryIndex)
        }

        let didMatch = queryIndex == queryLower.endIndex
        return (didMatch, didMatch ? score : 0)
    }

    /// Ask the overlay view to run its own dismiss animation.
    /// - Parameter clearSearchState: Whether to clear query/results/filters after fade-out.
    public func requestOverlayDismiss(clearSearchState: Bool = true) {
        dismissOverlaySignal = (clearSearchState, UUID())
    }

    /// Ask the overlay view to collapse back to compact mode without dismissing.
    public func requestOverlayCollapse() {
        collapseOverlaySignal = UUID()
    }

    /// Ask the overlay view to move focus back to the search field.
    public func requestSearchFieldFocus() {
        focusSearchFieldSignal = UUID()
    }

    /// Set a one-shot delay for the next "Recent Entries" popover reveal.
    public func setNextRecentEntriesRevealDelay(_ delay: TimeInterval) {
        let normalizedDelay = max(0, delay)
        nextRecentEntriesRevealDelay = normalizedDelay
    }

    /// Returns and clears any queued "Recent Entries" reveal delay.
    public func consumeNextRecentEntriesRevealDelay() -> TimeInterval {
        let delay = nextRecentEntriesRevealDelay
        nextRecentEntriesRevealDelay = 0
        return delay
    }

    /// Suppress recent entries for the next overlay presentation.
    public func suppressRecentEntriesForNextOverlayOpen() {
        suppressRecentEntriesOnNextOverlayOpen = true
    }

    /// Returns and clears one-shot suppression for recent entries on overlay presentation.
    public func consumeSuppressRecentEntriesForNextOverlayOpen() -> Bool {
        let shouldSuppress = suppressRecentEntriesOnNextOverlayOpen
        suppressRecentEntriesOnNextOverlayOpen = false
        return shouldSuppress
    }

    /// Request the overlay to dismiss the recent-entries popover via its user-dismiss handler path.
    public func requestDismissRecentEntriesPopoverByUser() {
        dismissRecentEntriesPopoverSignal = UUID()
    }

    // MARK: - Search

    private func cancelInFlightLoadMore(reason: String) {
        guard currentLoadMoreTask != nil || isLoadingMore else { return }

        currentLoadMoreTask?.cancel()
        currentLoadMoreTask = nil
        isLoadingMore = false
        Log.info("[SearchViewModel] Cancelled in-flight load more due to \(reason)", category: .ui)
    }

    private func startFreshSearchTask(query: String, trigger: String) {
        currentSearchTask?.cancel()
        cancelInFlightLoadMore(reason: trigger)
        currentSearchTask = Task {
            await performSearch(query: query, trigger: trigger)
        }
    }

    /// Trigger search with current query (called on Enter key)
    public func submitSearch(trigger: String = "submit") {
        // Mark that user has submitted a search - enables filter auto-refresh
        hasSubmittedSearch = true

        // Deeplink flow updates filters + query, then submits immediately.
        // Debounced filter observers can otherwise trigger a second redundant search.
        if trigger.hasPrefix("deeplink:") || trigger == "recent-entry" {
            armFilterAutoSearchSuppression()
        }

        // Track search event only on explicit submit (Enter key)
        let query = searchQuery
        if !query.isEmpty {
            recordRecentSearchEntry(query)
            DashboardViewModel.recordSearch(coordinator: coordinator, query: query)

            // Track filtered search if any filters are active
            if hasActiveFilters {
                let filtersJson = buildFiltersJson()
                DashboardViewModel.recordFilteredSearch(coordinator: coordinator, query: query, filters: filtersJson)
            }
        }

        startFreshSearchTask(query: query, trigger: trigger)
    }

    /// Re-run the current query immediately without recording a new "submitted search" analytics event.
    /// Useful for corrective actions in no-results diagnostics.
    public func rerunSearchImmediately(trigger: String = "manual-rerun") {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard hasSubmittedSearch else { return }

        startFreshSearchTask(query: query, trigger: trigger)
    }

    /// Build JSON representation of active filters for metrics
    private func buildFiltersJson() -> String {
        var components: [String] = []

        if let apps = selectedAppFilters, !apps.isEmpty {
            let appsArray = apps.map { "\"\($0)\"" }.joined(separator: ",")
            components.append("\"apps\":[\(appsArray)]")
            components.append("\"appMode\":\"\(appFilterMode.rawValue)\"")
        }

        if effectiveDateRanges.count == 1 {
            if let startDate = effectiveDateRanges[0].start {
                components.append("\"startDate\":\"\(Log.timestamp(from: startDate))\"")
            }
            if let endDate = effectiveDateRanges[0].end {
                components.append("\"endDate\":\"\(Log.timestamp(from: endDate))\"")
            }
        } else if !effectiveDateRanges.isEmpty {
            let encodedRanges = effectiveDateRanges.map { range in
                let start = range.start.map { "\"\(Log.timestamp(from: $0))\"" } ?? "null"
                let end = range.end.map { "\"\(Log.timestamp(from: $0))\"" } ?? "null"
                return "{\"start\":\(start),\"end\":\(end)}"
            }.joined(separator: ",")
            components.append("\"dateRanges\":[\(encodedRanges)]")
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

        if commentFilter != .allFrames {
            components.append("\"commentFilter\":\"\(commentFilter.rawValue)\"")
        }

        let normalizedWindowBuckets = normalizedMetadataFilterBuckets(
            include: windowNameTerms,
            exclude: windowNameExcludedTerms
        )
        if !normalizedWindowBuckets.includeTerms.isEmpty {
            let escapedTerms = normalizedWindowBuckets.includeTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
            components.append("\"windowNamesInclude\":[\(escapedTerms)]")
        }
        if !normalizedWindowBuckets.excludeTerms.isEmpty {
            let escapedTerms = normalizedWindowBuckets.excludeTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
            components.append("\"windowNamesExclude\":[\(escapedTerms)]")
        }

        let normalizedBrowserBuckets = normalizedMetadataFilterBuckets(
            include: browserUrlTerms,
            exclude: browserUrlExcludedTerms
        )
        if !normalizedBrowserBuckets.includeTerms.isEmpty {
            let escapedTerms = normalizedBrowserBuckets.includeTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
            components.append("\"browserUrlsInclude\":[\(escapedTerms)]")
        }
        if !normalizedBrowserBuckets.excludeTerms.isEmpty {
            let escapedTerms = normalizedBrowserBuckets.excludeTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
            components.append("\"browserUrlsExclude\":[\(escapedTerms)]")
        }

        if !excludedSearchTerms.isEmpty {
            let escapedTerms = normalizedExcludedSearchTerms(excludedSearchTerms)
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
            components.append("\"excludedTerms\":[\(escapedTerms)]")
        }

        return "{\(components.joined(separator: ","))}"
    }

    private func armFilterAutoSearchSuppression() {
        // Debounce is 300ms; use a slightly wider window to absorb the immediate post-deeplink filter event.
        let windowSeconds = debounceDelay + 0.35
        suppressFilterAutoSearchUntil = Date().addingTimeInterval(windowSeconds)
    }

    public func performSearch(query: String, trigger: String = "unknown") async {
        cancelInFlightLoadMore(reason: trigger)

        guard !query.isEmpty else {
            results = nil
            committedSearchQuery = ""
            clearInMemoryThumbnailCache()
            didReachPaginationEnd = false
            nextPageCursor = nil
            return
        }

        pendingOtherAppsRefreshTask?.cancel()
        pendingOtherAppsRefreshTask = nil

        isSearching = true
        error = nil

        results = nil  // Clear old results immediately to prevent stale thumbnail loads
        savedScrollPosition = 0  // Reset scroll position for new search
        clearInMemoryThumbnailCache()  // Clear in-memory thumbnail cache for new search
        searchGeneration += 1  // Increment generation to invalidate in-flight thumbnail loads
        committedSearchQuery = query  // Set committed query for thumbnail cache keys
        didReachPaginationEnd = false
        nextPageCursor = nil

        do {
            // Check for cancellation before starting the search
            try Task.checkCancellation()

            let searchQuery = buildSearchQuery(query)
            let searchResults = try await executeSearch(searchQuery)

            // Check for cancellation after the search completes
            try Task.checkCancellation()

            // Ensure UI updates happen on main actor
            await MainActor.run {
                results = searchResults
                nextPageCursor = searchResults.nextCursor
                didReachPaginationEnd = searchResults.nextCursor == nil
                isSearching = false
            }
        } catch is CancellationError {
            await MainActor.run {
                isSearching = false
            }
        } catch {
            // Ensure UI updates happen on main actor
            await MainActor.run {
                self.error = "Search failed: \(error.localizedDescription)"
                isSearching = false
            }
        }
    }

    private func buildSearchQuery(_ text: String, offset: Int = 0, cursor: SearchPageCursor? = nil) -> SearchQuery {
        let exclusionFragment = exclusionQueryFragment()
        let queryWithExclusions: String
        if exclusionFragment.isEmpty {
            queryWithExclusions = text
        } else if text.isEmpty {
            queryWithExclusions = exclusionFragment
        } else {
            queryWithExclusions = "\(text) \(exclusionFragment)"
        }

        // Truncate query to max words to prevent performance issues with very long queries
        let truncatedText = truncateToMaxWords(queryWithExclusions)

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

        let activeDateRanges = effectiveDateRanges
        let filters = SearchFilters(
            startDate: activeDateRanges.first?.start ?? startDate,
            endDate: activeDateRanges.first?.end ?? endDate,
            dateRanges: activeDateRanges,
            appBundleIDs: appBundleIDsArray,
            excludedAppBundleIDs: excludedAppBundleIDsArray,
            selectedTagIds: selectedTagIdsArray,
            excludedTagIds: excludedTagIdsArray,
            hiddenFilter: hiddenFilter,
            commentFilter: commentFilter,
            windowNameFilter: encodedMetadataFilter(includeTerms: windowNameTerms, excludeTerms: windowNameExcludedTerms),
            browserUrlFilter: encodedMetadataFilter(includeTerms: browserUrlTerms, excludeTerms: browserUrlExcludedTerms)
        )

        return SearchQuery(
            text: truncatedText,
            filters: filters,
            limit: defaultResultLimit,
            offset: offset,
            cursor: cursor,
            mode: searchMode,
            sortOrder: sortOrder
        )
    }

    /// Truncate query text to maximum allowed words
    private func truncateToMaxWords(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxSearchWords else { return text }

        let truncated = words.prefix(maxSearchWords).joined(separator: " ")
        Log.warning("[SearchViewModel] Query truncated from \(words.count) to \(maxSearchWords) words", category: .ui)
        return truncated
    }

    private func exclusionQueryFragment() -> String {
        let tokens = normalizedExcludedSearchTerms(excludedSearchTerms)
        guard !tokens.isEmpty else { return "" }

        return tokens
            .map { token in
                let sanitized = token.replacingOccurrences(of: "\"", with: "")
                if sanitized.contains(where: \.isWhitespace) {
                    return "-\"\(sanitized)\""
                }
                return "-\(sanitized)"
            }
            .joined(separator: " ")
    }

    private func encodedMetadataFilter(includeTerms: [String], excludeTerms: [String]) -> String? {
        let normalizedBuckets = normalizedMetadataFilterBuckets(include: includeTerms, exclude: excludeTerms)
        guard !normalizedBuckets.includeTerms.isEmpty || !normalizedBuckets.excludeTerms.isEmpty else {
            return nil
        }

        let payload = EncodedMetadataFilterPayload(
            includeTerms: normalizedBuckets.includeTerms,
            excludeTerms: normalizedBuckets.excludeTerms
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return Self.encodedMetadataFilterPrefix + data.base64EncodedString()
    }

    private func normalizedMetadataFilterTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let normalized = Self.normalizedMetadataFilterTerm(term) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(normalized)
            }
        }

        return normalizedTerms
    }

    private func normalizedMetadataFilterBuckets(include: [String], exclude: [String]) -> (includeTerms: [String], excludeTerms: [String]) {
        let normalizedInclude = normalizedMetadataFilterTerms(include)
        let includeKeys = Set(normalizedInclude.map { $0.lowercased() })
        var seenExclude = Set<String>()
        var normalizedExclude: [String] = []

        for term in exclude {
            guard let normalized = Self.normalizedMetadataFilterTerm(term) else { continue }
            let key = normalized.lowercased()
            guard !includeKeys.contains(key) else { continue }
            if seenExclude.insert(key).inserted {
                normalizedExclude.append(normalized)
            }
        }

        return (normalizedInclude, normalizedExclude)
    }

    private static func normalizedMetadataFilterTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func normalizedExcludedSearchTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let normalized = Self.normalizedExcludedSearchTerm(term) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(normalized)
            }
        }

        return normalizedTerms
    }

    private static func normalizedExcludedSearchTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Switch search mode and re-run search
    public func setSearchMode(_ mode: SearchMode) {
        guard mode != searchMode else { return }
        searchMode = mode
        // Clear results and re-search with new mode (only if user has submitted a search)
        if !searchQuery.isEmpty && hasSubmittedSearch {
            startFreshSearchTask(query: searchQuery, trigger: "search-mode-change")
        }
    }

    /// Switch sort order and re-run search (only affects "all" mode)
    public func setSearchSortOrder(_ order: SearchSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        // Re-search with new sort order (only if user has submitted a search)
        if !searchQuery.isEmpty && hasSubmittedSearch {
            startFreshSearchTask(query: searchQuery, trigger: "sort-order-change")
        }
    }

    /// Set search mode and sort order in one update, then run at most one re-search.
    public func setSearchModeAndSort(mode: SearchMode, sortOrder: SearchSortOrder?) {
        var didChange = false

        if self.searchMode != mode {
            self.searchMode = mode
            didChange = true
        }

        if let sortOrder, self.sortOrder != sortOrder {
            self.sortOrder = sortOrder
            didChange = true
        }

        guard didChange else { return }

        if !searchQuery.isEmpty && hasSubmittedSearch {
            startFreshSearchTask(query: searchQuery, trigger: "search-mode-or-sort-change")
        }
    }

    // MARK: - Load More (Infinite Scroll)

    /// Whether more results can be loaded
    public var canLoadMore: Bool {
        guard results != nil else { return false }
        return !didReachPaginationEnd && !isLoadingMore && !isSearching
    }

    /// Load more results for infinite scroll
    public func loadMore() {
        guard currentLoadMoreTask == nil, !isLoadingMore, !isSearching else {
            Log.debug("[SearchViewModel] Ignoring duplicate load more trigger while pagination is already in flight", category: .ui)
            return
        }

        currentLoadMoreTask = Task { @MainActor [weak self] in
            await self?.performLoadMore()
        }
    }

    private func performLoadMore() async {
        guard canLoadMore, let currentResults = results else { return }

        Log.info("[SearchViewModel] Loading more results, current count: \(currentResults.results.count)", category: .ui)
        isLoadingMore = true

        defer {
            currentLoadMoreTask = nil
        }

        do {
            // Check for cancellation before starting
            try Task.checkCancellation()

            let query = buildSearchQuery(searchQuery, offset: 0, cursor: nextPageCursor)
            let moreResults = try await executeSearch(query)

            // Check for cancellation after the search completes
            try Task.checkCancellation()

            Log.info("[SearchViewModel] Loaded \(moreResults.results.count) more results", category: .ui)

            if moreResults.results.isEmpty {
                didReachPaginationEnd = true
                nextPageCursor = nil
                results = SearchResults(
                    query: currentResults.query,
                    results: currentResults.results,
                    searchTimeMs: moreResults.searchTimeMs,
                    nextCursor: nil
                )
                isLoadingMore = false
                return
            }

            // Append new results to existing
            let combinedResults = currentResults.results + moreResults.results
            results = SearchResults(
                query: moreResults.query,
                results: combinedResults,
                searchTimeMs: moreResults.searchTimeMs,
                nextCursor: moreResults.nextCursor
            )
            nextPageCursor = moreResults.nextCursor
            didReachPaginationEnd = moreResults.nextCursor == nil

            isLoadingMore = false
        } catch is CancellationError {
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

    private struct AvailableAppsLoadSnapshot {
        let installedApps: [AppInfo]
        let installedBundleIDs: Set<String>
        let cachedOtherApps: [AppInfo]
        let cacheIsStale: Bool
        let installedPhaseMs: Int
        let cachePhaseMs: Int
    }

    /// Load available apps for the filter dropdown.
    /// Heavy filesystem/system discovery runs off-main; only state publication stays on main.
    public func loadAvailableApps() async {
        guard !isLoadingApps else {
            return
        }

        // Skip if already loaded
        guard installedApps.isEmpty else {
            return
        }

        isLoadingApps = true
        defer { isLoadingApps = false }

        let startTime = CFAbsoluteTimeGetCurrent()
        let snapshot = await Task.detached(priority: .utility) {
            let installedStart = CFAbsoluteTimeGetCurrent()
            let installed = Self.deduplicateAppsByBundleID(AppNameResolver.shared.getInstalledApps())
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let installedBundleIDs = Set(installed.map { $0.bundleID })
            let installedPhaseMs = Int((CFAbsoluteTimeGetCurrent() - installedStart) * 1000)

            let cacheStart = CFAbsoluteTimeGetCurrent()
            let cacheResult = Self.loadOtherAppsFromCache(installedBundleIDs: installedBundleIDs)
            let cachePhaseMs = Int((CFAbsoluteTimeGetCurrent() - cacheStart) * 1000)

            return AvailableAppsLoadSnapshot(
                installedApps: installed,
                installedBundleIDs: installedBundleIDs,
                cachedOtherApps: cacheResult.apps,
                cacheIsStale: cacheResult.isStale,
                installedPhaseMs: installedPhaseMs,
                cachePhaseMs: cachePhaseMs
            )
        }.value

        installedApps = snapshot.installedApps
        Log.info(
            "[SearchViewModel] Phase 1: Loaded \(installedApps.count) installed apps in \(snapshot.installedPhaseMs)ms (background)",
            category: .ui
        )

        if !snapshot.cachedOtherApps.isEmpty {
            otherApps = snapshot.cachedOtherApps
            Log.info(
                "[SearchViewModel] Phase 2: Loaded \(otherApps.count) other apps from cache in \(snapshot.cachePhaseMs)ms (stale: \(snapshot.cacheIsStale), background)",
                category: .ui
            )
        }

        // If cache is stale or empty, refresh from DB in background.
        if snapshot.cacheIsStale || snapshot.cachedOtherApps.isEmpty {
            scheduleOtherAppsRefresh(installedBundleIDs: snapshot.installedBundleIDs)
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        Log.info("[SearchViewModel] Total: \(installedApps.count) installed + \(otherApps.count) other apps in \(Int(totalTime * 1000))ms", category: .ui)
    }

    private func scheduleOtherAppsRefresh(installedBundleIDs: Set<String>) {
        pendingOtherAppsRefreshTask?.cancel()
        pendingOtherAppsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: otherAppsRefreshDelayNs)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard searchQuery.isEmpty, !isSearching, !hasSubmittedSearch else {
                Log.info(
                    "[SearchViewModel] Skipping deferred other apps refresh because search became active",
                    category: .ui
                )
                pendingOtherAppsRefreshTask = nil
                return
            }

            Log.info("[SearchViewModel] Starting deferred other apps refresh", category: .ui)
            await refreshOtherAppsFromDB(installedBundleIDs: installedBundleIDs)
            pendingOtherAppsRefreshTask = nil
        }
    }

    // MARK: - Other Apps Cache

    /// Load other apps from disk cache
    /// Returns (apps, isStale) - apps may be empty if no cache exists
    nonisolated private static func loadOtherAppsFromCache(installedBundleIDs: Set<String>) -> (apps: [AppInfo], isStale: Bool) {
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
            guard !Task.isCancelled else { return }
            let dbApps = AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)
            guard !Task.isCancelled else { return }

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

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Log.info(
                "[SearchViewModel] Refreshed \(uninstalledApps.count) other apps from DB in \(Int(elapsedMs))ms",
                category: .ui
            )
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

    public func setDateRanges(_ ranges: [DateRangeCriterion]) {
        let sanitized = Array(ranges.filter(\.hasBounds).prefix(5))
        dateRanges = sanitized
        startDate = sanitized.first?.start
        endDate = sanitized.first?.end
    }

    public func setDateRange(start: Date?, end: Date?) {
        if start == nil && end == nil {
            setDateRanges([])
        } else {
            setDateRanges([DateRangeCriterion(start: start, end: end)])
        }
    }

    public func recordKeyboardShortcut(_ shortcut: String) {
        DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: shortcut)
    }

    public func setContentType(_ type: ContentType) {
        contentType = type
    }

    public func setExcludedSearchTerms(_ terms: [String]) {
        excludedSearchTerms = normalizedExcludedSearchTerms(terms)
    }

    public func addExcludedSearchTerm(_ term: String) {
        var updated = excludedSearchTerms
        updated.append(term)
        excludedSearchTerms = normalizedExcludedSearchTerms(updated)
    }

    public func removeExcludedSearchTerm(_ term: String) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        excludedSearchTerms.removeAll { existing in
            existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    public func clearExcludedSearchTerms() {
        guard !excludedSearchTerms.isEmpty else { return }
        excludedSearchTerms.removeAll()
    }

    public func clearAllFilters() {
        selectedAppFilters = nil
        appFilterMode = .include
        startDate = nil
        endDate = nil
        dateRanges = []
        contentType = .all
        selectedTags = nil
        tagFilterMode = .include
        hiddenFilter = .hide
        commentFilter = .allFrames
        windowNameTerms = []
        windowNameExcludedTerms = []
        windowNameFilterMode = .include
        browserUrlTerms = []
        browserUrlExcludedTerms = []
        browserUrlFilterMode = .include
        excludedSearchTerms = []
    }

    public func resetSearchOrderToDefault() {
        searchMode = .all
        sortOrder = .newestFirst
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

    /// Set comment presence filter mode
    public func setCommentFilter(_ filter: CommentFilter) {
        commentFilter = filter
    }

    /// Check if any filters are active
    public var hasActiveFilters: Bool {
        (selectedAppFilters != nil && !selectedAppFilters!.isEmpty) ||
        !effectiveDateRanges.isEmpty ||
        (selectedTags != nil && !selectedTags!.isEmpty) ||
        hiddenFilter != .hide ||
        commentFilter != .allFrames ||
        !windowNameTerms.isEmpty ||
        !windowNameExcludedTerms.isEmpty ||
        !browserUrlTerms.isEmpty ||
        !browserUrlExcludedTerms.isEmpty ||
        !excludedSearchTerms.isEmpty
    }

    /// Number of active filter categories (for badge display)
    public var activeFilterCount: Int {
        var count = 0
        if let apps = selectedAppFilters, !apps.isEmpty { count += 1 }
        if !effectiveDateRanges.isEmpty { count += 1 }
        if let tags = selectedTags, !tags.isEmpty { count += 1 }
        if hiddenFilter != .hide { count += 1 }
        if commentFilter != .allFrames { count += 1 }
        if !windowNameTerms.isEmpty || !windowNameExcludedTerms.isEmpty { count += 1 }
        if !browserUrlTerms.isEmpty || !browserUrlExcludedTerms.isEmpty { count += 1 }
        if !excludedSearchTerms.isEmpty { count += 1 }
        return count
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

    public static func shouldDismissExpandedOverlayOnEscape(
        committedSearchQuery: String,
        hasSearchResultsPayload: Bool
    ) -> Bool {
        if hasSearchResultsPayload {
            return true
        }
        return !committedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var shouldDismissExpandedOverlayOnEscape: Bool {
        Self.shouldDismissExpandedOverlayOnEscape(
            committedSearchQuery: committedSearchQuery,
            hasSearchResultsPayload: results != nil
        )
    }

    public static func shouldRefocusSearchFieldOnEscape(
        committedSearchQuery: String,
        hasSearchResultsPayload: Bool,
        isSearchFieldFocused: Bool
    ) -> Bool {
        guard shouldDismissExpandedOverlayOnEscape(
            committedSearchQuery: committedSearchQuery,
            hasSearchResultsPayload: hasSearchResultsPayload
        ) else {
            return false
        }
        return !isSearchFieldFocused
    }

    public var shouldRefocusSearchFieldOnEscape: Bool {
        Self.shouldRefocusSearchFieldOnEscape(
            committedSearchQuery: committedSearchQuery,
            hasSearchResultsPayload: results != nil,
            isSearchFieldFocused: isSearchFieldFocused
        )
    }

    public var isEmpty: Bool {
        !hasResults && !isSearching
    }

    // MARK: - Search Results Cache

    /// Save the current search results to cache for instant restore on app reopen
    public func saveSearchResults() {

        guard let results = results, !results.isEmpty else {
            return
        }
        guard !committedSearchQuery.isEmpty else {
            return
        }

        // Save metadata to UserDefaults
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedSearchSavedAtKey)
        UserDefaults.standard.set(committedSearchQuery, forKey: Self.cachedSearchQueryKey)
        UserDefaults.standard.set(Double(savedScrollPosition), forKey: Self.cachedScrollPositionKey)
        UserDefaults.standard.set(Self.searchCacheVersion, forKey: Self.searchCacheVersionKey)

        // Save filters - convert Set to Array for storage
        if let apps = selectedAppFilters, !apps.isEmpty {
            UserDefaults.standard.set(Array(apps), forKey: Self.cachedAppFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedAppFilterKey)
        }
        let cachedDateRanges = effectiveDateRanges
        if let startDate = cachedDateRanges.first?.start {
            UserDefaults.standard.set(startDate.timeIntervalSince1970, forKey: Self.cachedStartDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedStartDateKey)
        }
        if let endDate = cachedDateRanges.first?.end {
            UserDefaults.standard.set(endDate.timeIntervalSince1970, forKey: Self.cachedEndDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedEndDateKey)
        }
        if let encodedDateRanges = try? JSONEncoder().encode(cachedDateRanges), !cachedDateRanges.isEmpty {
            UserDefaults.standard.set(encodedDateRanges, forKey: Self.cachedDateRangesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedDateRangesKey)
        }
        if !windowNameTerms.isEmpty || !windowNameExcludedTerms.isEmpty {
            UserDefaults.standard.set(windowNameTerms, forKey: Self.cachedWindowNameTermsKey)
            UserDefaults.standard.set(windowNameExcludedTerms, forKey: Self.cachedWindowNameExcludeTermsKey)
            UserDefaults.standard.set(windowNameFilterMode.rawValue, forKey: Self.cachedWindowNameModeKey)
            UserDefaults.standard.set(windowNameTerms.first ?? windowNameExcludedTerms.first, forKey: Self.cachedWindowNameFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedWindowNameTermsKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedWindowNameExcludeTermsKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedWindowNameModeKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedWindowNameFilterKey)
        }
        if !browserUrlTerms.isEmpty || !browserUrlExcludedTerms.isEmpty {
            UserDefaults.standard.set(browserUrlTerms, forKey: Self.cachedBrowserUrlTermsKey)
            UserDefaults.standard.set(browserUrlExcludedTerms, forKey: Self.cachedBrowserUrlExcludeTermsKey)
            UserDefaults.standard.set(browserUrlFilterMode.rawValue, forKey: Self.cachedBrowserUrlModeKey)
            UserDefaults.standard.set(browserUrlTerms.first ?? browserUrlExcludedTerms.first, forKey: Self.cachedBrowserUrlFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedBrowserUrlTermsKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedBrowserUrlExcludeTermsKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedBrowserUrlModeKey)
            UserDefaults.standard.removeObject(forKey: Self.cachedBrowserUrlFilterKey)
        }
        if !excludedSearchTerms.isEmpty {
            UserDefaults.standard.set(excludedSearchTerms, forKey: Self.cachedExcludedSearchTermsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedExcludedSearchTermsKey)
        }
        if commentFilter != .allFrames {
            UserDefaults.standard.set(commentFilter.rawValue, forKey: Self.cachedCommentFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cachedCommentFilterKey)
        }
        UserDefaults.standard.set(contentType.rawValue, forKey: Self.cachedContentTypeKey)
        UserDefaults.standard.set(searchMode.rawValue, forKey: Self.cachedSearchModeKey)
        UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.cachedSearchSortOrderKey)

        // Force UserDefaults to persist immediately (important for quick close/reopen)
        UserDefaults.standard.synchronize()

        // Save results to disk (JSON file) - do this async to not block the main thread
        Task.detached(priority: .utility) { [results] in
            do {
                let data = try JSONEncoder().encode(results)
                try data.write(to: Self.cachedSearchResultsPath)
            } catch {
                Log.warning("[SearchCache] Failed to save search results: \(error)", category: .ui)
            }
        }

    }

    /// Restore cached search results if they exist and haven't expired
    /// Returns true if cache was restored, false otherwise
    @discardableResult
    public func restoreCachedSearchResults() async -> Bool {

        // Check cache version first - invalidate if version mismatch
        let cachedVersion = UserDefaults.standard.integer(forKey: Self.searchCacheVersionKey)
        if cachedVersion != Self.searchCacheVersion {
            clearSearchCache()
            return false
        }

        let savedAt = UserDefaults.standard.double(forKey: Self.cachedSearchSavedAtKey)
        guard savedAt > 0 else { return false }

        let savedAtDate = Date(timeIntervalSince1970: savedAt)
        let elapsed = Date().timeIntervalSince(savedAtDate)

        // Check if cache has expired
        if elapsed > Self.searchCacheExpirationSeconds {
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
        let cachedDateRanges: [DateRangeCriterion] = {
            guard let data = UserDefaults.standard.data(forKey: Self.cachedDateRangesKey),
                  let decoded = try? JSONDecoder().decode([DateRangeCriterion].self, from: data) else {
                return []
            }
            return decoded.filter(\.hasBounds)
        }()
        let cachedWindowNameTerms = UserDefaults.standard.stringArray(forKey: Self.cachedWindowNameTermsKey) ?? []
        let cachedWindowNameExcludeTerms = UserDefaults.standard.stringArray(forKey: Self.cachedWindowNameExcludeTermsKey) ?? []
        let cachedWindowNameModeRaw = UserDefaults.standard.string(forKey: Self.cachedWindowNameModeKey)
        let cachedLegacyWindowNameFilter = UserDefaults.standard.string(forKey: Self.cachedWindowNameFilterKey)
        let cachedBrowserUrlTerms = UserDefaults.standard.stringArray(forKey: Self.cachedBrowserUrlTermsKey) ?? []
        let cachedBrowserUrlExcludeTerms = UserDefaults.standard.stringArray(forKey: Self.cachedBrowserUrlExcludeTermsKey) ?? []
        let cachedBrowserUrlModeRaw = UserDefaults.standard.string(forKey: Self.cachedBrowserUrlModeKey)
        let cachedLegacyBrowserUrlFilter = UserDefaults.standard.string(forKey: Self.cachedBrowserUrlFilterKey)
        let cachedExcludedSearchTerms = UserDefaults.standard.stringArray(forKey: Self.cachedExcludedSearchTermsKey) ?? []
        let cachedCommentFilterRaw = UserDefaults.standard.string(forKey: Self.cachedCommentFilterKey)
        let cachedContentTypeRaw = UserDefaults.standard.string(forKey: Self.cachedContentTypeKey)
        let cachedSearchModeRaw = UserDefaults.standard.string(forKey: Self.cachedSearchModeKey)
        let cachedSearchSortOrderRaw = UserDefaults.standard.string(forKey: Self.cachedSearchSortOrderKey)

        // Load cached results from disk (off-main)
        let cachedResults: SearchResults
        do {
            cachedResults = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: Self.cachedSearchResultsPath)
                return try JSONDecoder().decode(SearchResults.self, from: data)
            }.value

            guard !cachedResults.isEmpty else { return false }

            // Set flag to prevent re-search while restoring
            isRestoringFromCache = true

            // Restore state
            searchQuery = cachedQuery
            committedSearchQuery = cachedQuery
            results = cachedResults
            savedScrollPosition = CGFloat(cachedScrollPosition)
            searchGeneration += 1
            nextPageCursor = cachedResults.nextCursor
            didReachPaginationEnd = cachedResults.nextCursor == nil

            // Restore filters
            selectedAppFilters = cachedAppFilters
            if !cachedDateRanges.isEmpty {
                dateRanges = Array(cachedDateRanges.prefix(5))
                startDate = dateRanges.first?.start
                endDate = dateRanges.first?.end
            } else {
                startDate = cachedStartDateValue > 0 ? Date(timeIntervalSince1970: cachedStartDateValue) : nil
                endDate = cachedEndDateValue > 0 ? Date(timeIntervalSince1970: cachedEndDateValue) : nil
                if startDate != nil || endDate != nil {
                    dateRanges = [DateRangeCriterion(start: startDate, end: endDate)]
                } else {
                    dateRanges = []
                }
            }
            let restoredWindowTermsSource: [String] = if !cachedWindowNameTerms.isEmpty {
                cachedWindowNameTerms
            } else if let legacy = cachedLegacyWindowNameFilter,
                      !legacy.isEmpty,
                      (cachedWindowNameModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include) == .include {
                [legacy]
            } else {
                []
            }
            let restoredWindowExcludeSource: [String] = if !cachedWindowNameExcludeTerms.isEmpty {
                cachedWindowNameExcludeTerms
            } else if let legacy = cachedLegacyWindowNameFilter,
                      !legacy.isEmpty,
                      (cachedWindowNameModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include) == .exclude {
                [legacy]
            } else {
                []
            }
            let restoredWindowBuckets = normalizedMetadataFilterBuckets(
                include: restoredWindowTermsSource,
                exclude: restoredWindowExcludeSource
            )
            windowNameTerms = restoredWindowBuckets.includeTerms
            windowNameExcludedTerms = restoredWindowBuckets.excludeTerms
            windowNameFilterMode = cachedWindowNameModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include

            let restoredBrowserTermsSource: [String] = if !cachedBrowserUrlTerms.isEmpty {
                cachedBrowserUrlTerms
            } else if let legacy = cachedLegacyBrowserUrlFilter,
                      !legacy.isEmpty,
                      (cachedBrowserUrlModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include) == .include {
                [legacy]
            } else {
                []
            }
            let restoredBrowserExcludeSource: [String] = if !cachedBrowserUrlExcludeTerms.isEmpty {
                cachedBrowserUrlExcludeTerms
            } else if let legacy = cachedLegacyBrowserUrlFilter,
                      !legacy.isEmpty,
                      (cachedBrowserUrlModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include) == .exclude {
                [legacy]
            } else {
                []
            }
            let restoredBrowserBuckets = normalizedMetadataFilterBuckets(
                include: restoredBrowserTermsSource,
                exclude: restoredBrowserExcludeSource
            )
            browserUrlTerms = restoredBrowserBuckets.includeTerms
            browserUrlExcludedTerms = restoredBrowserBuckets.excludeTerms
            browserUrlFilterMode = cachedBrowserUrlModeRaw.flatMap(AppFilterMode.init(rawValue:)) ?? .include
            excludedSearchTerms = normalizedExcludedSearchTerms(cachedExcludedSearchTerms)
            if let rawValue = cachedCommentFilterRaw, let filter = CommentFilter(rawValue: rawValue) {
                commentFilter = filter
            } else {
                commentFilter = .allFrames
            }
            if let rawValue = cachedContentTypeRaw, let type = ContentType(rawValue: rawValue) {
                contentType = type
            }
            if let rawValue = cachedSearchModeRaw, let mode = SearchMode(rawValue: rawValue) {
                searchMode = mode
            }
            if let rawValue = cachedSearchSortOrderRaw, let order = SearchSortOrder(rawValue: rawValue) {
                sortOrder = order
            }

            // Clear the flag after restore is complete (after debounce delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay + 0.1) { [weak self] in
                self?.isRestoringFromCache = false
            }

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
        UserDefaults.standard.removeObject(forKey: cachedDateRangesKey)
        UserDefaults.standard.removeObject(forKey: cachedWindowNameTermsKey)
        UserDefaults.standard.removeObject(forKey: cachedWindowNameExcludeTermsKey)
        UserDefaults.standard.removeObject(forKey: cachedWindowNameModeKey)
        UserDefaults.standard.removeObject(forKey: cachedBrowserUrlTermsKey)
        UserDefaults.standard.removeObject(forKey: cachedBrowserUrlExcludeTermsKey)
        UserDefaults.standard.removeObject(forKey: cachedBrowserUrlModeKey)
        UserDefaults.standard.removeObject(forKey: cachedWindowNameFilterKey)
        UserDefaults.standard.removeObject(forKey: cachedBrowserUrlFilterKey)
        UserDefaults.standard.removeObject(forKey: cachedExcludedSearchTermsKey)
        UserDefaults.standard.removeObject(forKey: cachedCommentFilterKey)
        UserDefaults.standard.removeObject(forKey: cachedContentTypeKey)
        UserDefaults.standard.removeObject(forKey: cachedSearchModeKey)
        UserDefaults.standard.removeObject(forKey: cachedSearchSortOrderKey)

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
        resetSearchOrderToDefault()
        error = nil
        didReachPaginationEnd = false
        nextPageCursor = nil

        // Clear all caches
        clearInMemoryThumbnailCache()
        savedScrollPosition = 0
        searchGeneration += 1

        // Clear persisted cache
        clearSearchCache()
    }

    // MARK: - Cleanup

    /// Cancel any in-flight search and load-more tasks
    /// Call this when the search overlay is dismissed to prevent blocking
    public func cancelSearch() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        currentLoadMoreTask?.cancel()
        currentLoadMoreTask = nil
        pendingOtherAppsRefreshTask?.cancel()
        pendingOtherAppsRefreshTask = nil
        isSearching = false
        isLoadingMore = false
    }

    deinit {
        // Cancel tasks directly - deinit is not actor-isolated so we can't call cancelSearch()
        currentSearchTask?.cancel()
        currentLoadMoreTask?.cancel()
        pendingOtherAppsRefreshTask?.cancel()
        memoryReportTask?.cancel()
        cancellables.removeAll()

        MemoryLedger.set(
            tag: Self.memoryLedgerThumbnailTag,
            bytes: 0,
            count: 0,
            unit: "images",
            function: "ui.search",
            kind: "images"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerAppIconTag,
            bytes: 0,
            count: 0,
            unit: "icons",
            function: "ui.search",
            kind: "images"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerResultSetTag,
            bytes: 0,
            count: 0,
            unit: "results",
            function: "ui.search",
            kind: "result-window"
        )
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
