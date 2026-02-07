import Foundation

// MARK: - Search Query

/// Search mode determines how results are ranked and filtered
public enum SearchMode: String, Codable, Sendable, CaseIterable {
    case relevant   // Top N by relevance, then sorted by date
    case all        // All matches sorted by date (chronological)
}

/// Sort order for search results (used in "all" mode)
public enum SearchSortOrder: String, Codable, Sendable, CaseIterable {
    case newestFirst   // ORDER BY createdAt DESC
    case oldestFirst   // ORDER BY createdAt ASC
}

/// A search query with optional filters
public struct SearchQuery: Codable, Sendable {
    public let text: String
    public let filters: SearchFilters
    public let limit: Int
    public let offset: Int
    public let mode: SearchMode
    public let sortOrder: SearchSortOrder

    public init(
        text: String,
        filters: SearchFilters = .none,
        limit: Int = 50,
        offset: Int = 0,
        mode: SearchMode = .relevant,
        sortOrder: SearchSortOrder = .newestFirst
    ) {
        self.text = text
        self.filters = filters
        self.limit = limit
        self.offset = offset
        self.mode = mode
        self.sortOrder = sortOrder
    }
}

/// Filters to narrow search results
public struct SearchFilters: Codable, Sendable {
    public let startDate: Date?
    public let endDate: Date?
    public let appBundleIDs: [String]?  // nil means all apps
    public let excludedAppBundleIDs: [String]?
    public let selectedTagIds: [Int64]?  // nil means all tags
    public let excludedTagIds: [Int64]?  // Tags to exclude
    public let hiddenFilter: HiddenFilter  // How to handle hidden segments

    public init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        appBundleIDs: [String]? = nil,
        excludedAppBundleIDs: [String]? = nil,
        selectedTagIds: [Int64]? = nil,
        excludedTagIds: [Int64]? = nil,
        hiddenFilter: HiddenFilter = .hide
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.appBundleIDs = appBundleIDs
        self.excludedAppBundleIDs = excludedAppBundleIDs
        self.selectedTagIds = selectedTagIds
        self.excludedTagIds = excludedTagIds
        self.hiddenFilter = hiddenFilter
    }

    public static let none = SearchFilters()

    public var hasFilters: Bool {
        startDate != nil || endDate != nil ||
        appBundleIDs != nil || excludedAppBundleIDs != nil ||
        selectedTagIds != nil || excludedTagIds != nil ||
        hiddenFilter != .hide
    }
}

// MARK: - Search Result

/// A single search result
/// Rewind-compatible: links to both app segment (session context) and video (playback)
public struct SearchResult: Codable, Sendable, Identifiable {
    public let id: FrameID
    public let timestamp: Date
    public let snippet: String       // Text snippet with match highlighted
    public let matchedText: String   // The actual matched text
    public let relevanceScore: Double
    public let metadata: FrameMetadata
    public let segmentID: AppSegmentID    // App segment (session) for context
    public let videoID: VideoSegmentID    // Video chunk for playback
    public let frameIndex: Int            // Position within video (0-149)
    public var source: FrameSource        // Which data source this result came from

    public init(
        id: FrameID,
        timestamp: Date,
        snippet: String,
        matchedText: String,
        relevanceScore: Double,
        metadata: FrameMetadata,
        segmentID: AppSegmentID,
        videoID: VideoSegmentID = VideoSegmentID(value: 0),
        frameIndex: Int,
        source: FrameSource = .native
    ) {
        self.id = id
        self.timestamp = timestamp
        self.snippet = snippet
        self.matchedText = matchedText
        self.relevanceScore = relevanceScore
        self.metadata = metadata
        self.segmentID = segmentID
        self.videoID = videoID
        self.frameIndex = frameIndex
        self.source = source
    }
}

/// Collection of search results with metadata
public struct SearchResults: Codable, Sendable {
    public let query: SearchQuery
    public var results: [SearchResult]  // var to allow source tagging
    public let totalCount: Int       // Total matches (may be > results.count due to limit)
    public let searchTimeMs: Int     // How long the search took

    public init(
        query: SearchQuery,
        results: [SearchResult],
        totalCount: Int,
        searchTimeMs: Int
    ) {
        self.query = query
        self.results = results
        self.totalCount = totalCount
        self.searchTimeMs = searchTimeMs
    }

    public var isEmpty: Bool { results.isEmpty }
    public var hasMore: Bool { results.count < totalCount }
}

// MARK: - Grouped Search Results

/// View mode for search results display
public enum SearchViewMode: String, Codable, Sendable, CaseIterable {
    case flat       // Traditional flat list of all results
    case grouped    // Segment-first with day grouping
}

/// A segment stack representing multiple search matches within a single segment
/// The representative result is the highest-relevance match in the segment
public struct SegmentSearchStack: Codable, Sendable, Identifiable {
    /// Unique identifier (uses representative result's frame ID)
    public var id: FrameID { representativeResult.id }

    /// The segment ID this stack represents
    public let segmentID: AppSegmentID

    /// The highest-relevance match in this segment (shown as the preview)
    public let representativeResult: SearchResult

    /// Total number of matching frames in this segment
    public let matchCount: Int

    /// All matching frames in this segment (sorted by timestamp, newest first)
    public var expandedResults: [SearchResult]?

    /// Whether this stack is currently expanded in the UI
    public var isExpanded: Bool

    public init(
        segmentID: AppSegmentID,
        representativeResult: SearchResult,
        matchCount: Int,
        expandedResults: [SearchResult]? = nil,
        isExpanded: Bool = false
    ) {
        self.segmentID = segmentID
        self.representativeResult = representativeResult
        self.matchCount = matchCount
        self.expandedResults = expandedResults
        self.isExpanded = isExpanded
    }
}

/// A day section containing grouped segment stacks
public struct SearchDaySection: Codable, Sendable, Identifiable {
    /// Unique identifier based on the date
    public var id: String { dateKey }

    /// Date key for grouping (e.g., "2024-12-29")
    public let dateKey: String

    /// Display label (e.g., "Today", "Yesterday", "Dec 29")
    public let displayLabel: String

    /// The actual date (start of day)
    public let date: Date

    /// Segment stacks within this day, ordered by time (newest first)
    public var segmentStacks: [SegmentSearchStack]

    /// Total match count across all stacks in this day
    public var totalMatchCount: Int {
        segmentStacks.reduce(0) { $0 + $1.matchCount }
    }

    public init(
        dateKey: String,
        displayLabel: String,
        date: Date,
        segmentStacks: [SegmentSearchStack]
    ) {
        self.dateKey = dateKey
        self.displayLabel = displayLabel
        self.date = date
        self.segmentStacks = segmentStacks
    }
}

/// Grouped search results with day sections and segment stacks
public struct GroupedSearchResults: Codable, Sendable {
    public let query: SearchQuery
    public var daySections: [SearchDaySection]
    public let totalMatchCount: Int
    public let totalSegmentCount: Int
    public let searchTimeMs: Int

    public init(
        query: SearchQuery,
        daySections: [SearchDaySection],
        totalMatchCount: Int,
        totalSegmentCount: Int,
        searchTimeMs: Int
    ) {
        self.query = query
        self.daySections = daySections
        self.totalMatchCount = totalMatchCount
        self.totalSegmentCount = totalSegmentCount
        self.searchTimeMs = searchTimeMs
    }

    public var isEmpty: Bool { daySections.isEmpty }
}

