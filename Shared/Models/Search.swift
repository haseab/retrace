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

/// Source-specific keyset cursor for paginating search results.
public struct SearchSourceCursor: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let frameID: Int64

    public init(timestamp: Date, frameID: Int64) {
        self.timestamp = timestamp
        self.frameID = frameID
    }
}

/// Cursor state for combined multi-source search pagination.
public struct SearchPageCursor: Codable, Sendable, Equatable {
    public let native: SearchSourceCursor?
    public let rewind: SearchSourceCursor?

    public init(native: SearchSourceCursor? = nil, rewind: SearchSourceCursor? = nil) {
        self.native = native
        self.rewind = rewind
    }
}

/// A search query with optional filters
public struct SearchQuery: Codable, Sendable {
    public let text: String
    public let filters: SearchFilters
    public let limit: Int
    public let offset: Int
    public let cursor: SearchPageCursor?
    public let mode: SearchMode
    public let sortOrder: SearchSortOrder

    public init(
        text: String,
        filters: SearchFilters = .none,
        limit: Int = 50,
        offset: Int = 0,
        cursor: SearchPageCursor? = nil,
        mode: SearchMode = .all,
        sortOrder: SearchSortOrder = .newestFirst
    ) {
        self.text = text
        self.filters = filters
        self.limit = limit
        self.offset = offset
        self.cursor = cursor
        self.mode = mode
        self.sortOrder = sortOrder
    }
}

/// Filters to narrow search results
public struct SearchFilters: Codable, Sendable {
    public let startDate: Date?
    public let endDate: Date?
    public let dateRanges: [DateRangeCriterion]?
    public let appBundleIDs: [String]?  // nil means all apps
    public let excludedAppBundleIDs: [String]?
    public let selectedTagIds: [Int64]?  // nil means all tags
    public let excludedTagIds: [Int64]?  // Tags to exclude
    public let hiddenFilter: HiddenFilter  // How to handle hidden segments
    public let commentFilter: CommentFilter  // How to handle comment presence
    public let windowNameFilter: String?  // Partial match on segment.windowName
    public let browserUrlFilter: String?  // Partial match on segment.browserUrl

    public init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        dateRanges: [DateRangeCriterion]? = nil,
        appBundleIDs: [String]? = nil,
        excludedAppBundleIDs: [String]? = nil,
        selectedTagIds: [Int64]? = nil,
        excludedTagIds: [Int64]? = nil,
        hiddenFilter: HiddenFilter = .hide,
        commentFilter: CommentFilter = .allFrames,
        windowNameFilter: String? = nil,
        browserUrlFilter: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.dateRanges = Self.sanitizedDateRanges(dateRanges)
        self.appBundleIDs = appBundleIDs
        self.excludedAppBundleIDs = excludedAppBundleIDs
        self.selectedTagIds = selectedTagIds
        self.excludedTagIds = excludedTagIds
        self.hiddenFilter = hiddenFilter
        self.commentFilter = commentFilter
        self.windowNameFilter = windowNameFilter
        self.browserUrlFilter = browserUrlFilter
    }

    /// Effective date ranges for querying. Falls back to legacy single-range fields for compatibility.
    public var effectiveDateRanges: [DateRangeCriterion] {
        let normalized = Self.sanitizedDateRanges(dateRanges) ?? []
        if !normalized.isEmpty {
            return normalized
        }
        if startDate != nil || endDate != nil {
            return [DateRangeCriterion(start: startDate, end: endDate)]
        }
        return []
    }

    public static let none = SearchFilters()

    public var hasFilters: Bool {
        !effectiveDateRanges.isEmpty ||
        appBundleIDs != nil || excludedAppBundleIDs != nil ||
        selectedTagIds != nil || excludedTagIds != nil ||
        hiddenFilter != .hide ||
        commentFilter != .allFrames ||
        (windowNameFilter?.isEmpty == false) ||
        (browserUrlFilter?.isEmpty == false)
    }

    private enum CodingKeys: String, CodingKey {
        case startDate
        case endDate
        case dateRanges
        case appBundleIDs
        case excludedAppBundleIDs
        case selectedTagIds
        case excludedTagIds
        case hiddenFilter
        case commentFilter
        case windowNameFilter
        case browserUrlFilter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        dateRanges = Self.sanitizedDateRanges(try container.decodeIfPresent([DateRangeCriterion].self, forKey: .dateRanges))
        appBundleIDs = try container.decodeIfPresent([String].self, forKey: .appBundleIDs)
        excludedAppBundleIDs = try container.decodeIfPresent([String].self, forKey: .excludedAppBundleIDs)
        selectedTagIds = try container.decodeIfPresent([Int64].self, forKey: .selectedTagIds)
        excludedTagIds = try container.decodeIfPresent([Int64].self, forKey: .excludedTagIds)
        hiddenFilter = try container.decodeIfPresent(HiddenFilter.self, forKey: .hiddenFilter) ?? .hide
        commentFilter = try container.decodeIfPresent(CommentFilter.self, forKey: .commentFilter) ?? .allFrames
        windowNameFilter = try container.decodeIfPresent(String.self, forKey: .windowNameFilter)
        browserUrlFilter = try container.decodeIfPresent(String.self, forKey: .browserUrlFilter)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(Self.sanitizedDateRanges(dateRanges), forKey: .dateRanges)
        try container.encodeIfPresent(appBundleIDs, forKey: .appBundleIDs)
        try container.encodeIfPresent(excludedAppBundleIDs, forKey: .excludedAppBundleIDs)
        try container.encodeIfPresent(selectedTagIds, forKey: .selectedTagIds)
        try container.encodeIfPresent(excludedTagIds, forKey: .excludedTagIds)
        try container.encode(hiddenFilter, forKey: .hiddenFilter)
        try container.encode(commentFilter, forKey: .commentFilter)
        try container.encodeIfPresent(windowNameFilter, forKey: .windowNameFilter)
        try container.encodeIfPresent(browserUrlFilter, forKey: .browserUrlFilter)
    }

    private static func sanitizedDateRanges(_ ranges: [DateRangeCriterion]?) -> [DateRangeCriterion]? {
        guard let ranges else { return nil }
        let sanitized = ranges.filter(\.hasBounds)
        return sanitized.isEmpty ? nil : sanitized
    }
}

// MARK: - Search Result

/// A single search result
/// Rewind-compatible: links to both app segment (session context) and video (playback)
public struct SearchResult: Codable, Sendable, Identifiable {
    public struct HighlightNode: Codable, Sendable {
        public let nodeID: Int64
        public let nodeOrder: Int
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(
            nodeID: Int64,
            nodeOrder: Int,
            x: Double,
            y: Double,
            width: Double,
            height: Double
        ) {
            self.nodeID = nodeID
            self.nodeOrder = nodeOrder
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let id: FrameID
    public let timestamp: Date
    public let snippet: String       // Text snippet with match highlighted
    public let matchedText: String   // The actual matched text
    public let relevanceScore: Double
    public let metadata: FrameMetadata
    public let segmentID: AppSegmentID    // App segment (session) for context
    public let videoID: VideoSegmentID    // Video chunk for playback
    public let frameIndex: Int            // Position within video (0-149)
    public let videoPath: String?         // Relative/absolute path to backing video file
    public let videoFrameRate: Double?    // Video frame rate for precise seek
    public var source: FrameSource        // Which data source this result came from
    public let highlightNode: HighlightNode?

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
        videoPath: String? = nil,
        videoFrameRate: Double? = nil,
        source: FrameSource = .native,
        highlightNode: HighlightNode? = nil
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
        self.videoPath = videoPath
        self.videoFrameRate = videoFrameRate
        self.source = source
        self.highlightNode = highlightNode
    }
}

/// A single paginated search response.
public struct SearchResults: Codable, Sendable {
    public let query: SearchQuery
    public var results: [SearchResult]  // var to allow source tagging
    public let searchTimeMs: Int     // How long the search took
    public let nextCursor: SearchPageCursor?

    public init(
        query: SearchQuery,
        results: [SearchResult],
        searchTimeMs: Int,
        nextCursor: SearchPageCursor? = nil
    ) {
        self.query = query
        self.results = results
        self.searchTimeMs = searchTimeMs
        self.nextCursor = nextCursor
    }

    public var isEmpty: Bool { results.isEmpty }
    public var hasMore: Bool { nextCursor != nil }
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
