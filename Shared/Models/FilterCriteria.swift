import Foundation

/// Inclusive date range used by timeline/search filters.
public struct DateRangeCriterion: Codable, Equatable, Sendable, Hashable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public var hasBounds: Bool {
        start != nil || end != nil
    }
}

/// Mode for app filtering - include selected apps or exclude them
public enum AppFilterMode: String, Codable, Sendable, CaseIterable {
    /// Show only selected apps (default)
    case include = "include"
    /// Show all apps except selected ones
    case exclude = "exclude"

    public var displayName: String {
        switch self {
        case .include: return "Include"
        case .exclude: return "Exclude"
        }
    }
}

/// Mode for tag filtering - include selected tags or exclude them
public enum TagFilterMode: String, Codable, Sendable, CaseIterable {
    /// Show only segments with selected tags (default)
    case include = "include"
    /// Show segments without selected tags
    case exclude = "exclude"

    public var displayName: String {
        switch self {
        case .include: return "Include"
        case .exclude: return "Exclude"
        }
    }
}

/// How to handle hidden segments in filtering
public enum HiddenFilter: String, Codable, Sendable, CaseIterable {
    /// Don't show hidden segments (default)
    case hide = "hide"
    /// Only show hidden segments
    case onlyHidden = "only_hidden"
    /// Show both hidden and visible segments
    case showAll = "show_all"

    public var displayName: String {
        switch self {
        case .hide: return "Hide"
        case .onlyHidden: return "Only Hidden"
        case .showAll: return "Show All"
        }
    }
}

/// How to handle comment presence in filtering
public enum CommentFilter: String, Codable, Sendable, CaseIterable {
    /// Show all frames regardless of comments (default)
    case allFrames = "all_frames"
    /// Show only frames from segments that have comments
    case commentsOnly = "comments_only"
    /// Show only frames from segments that do not have comments
    case noComments = "no_comments"

    public var displayName: String {
        switch self {
        case .allFrames: return "All Frames"
        case .commentsOnly: return "Comments Only"
        case .noComments: return "No Comments"
        }
    }
}

/// Represents filter criteria for timeline frames
public struct FilterCriteria: Codable, Equatable, Sendable {
    /// Selected app bundle IDs (nil = all apps)
    public var selectedApps: Set<String>?

    /// App filter mode - include or exclude selected apps
    public var appFilterMode: AppFilterMode

    /// Selected data sources (nil = all sources)
    public var selectedSources: Set<FrameSource>?

    /// How to handle hidden segments
    public var hiddenFilter: HiddenFilter

    /// How to handle comment presence
    public var commentFilter: CommentFilter

    /// Selected tag IDs (nil = all tags, including no tags)
    public var selectedTags: Set<Int64>?

    /// Tag filter mode - include or exclude selected tags
    public var tagFilterMode: TagFilterMode

    // MARK: - Advanced Filters

    /// Window name filter (searches FTS c2/title column)
    public var windowNameFilter: String?

    /// Browser URL filter (partial string match on segment.browserUrl)
    public var browserUrlFilter: String?

    /// Date range start (nil = no start limit)
    public var startDate: Date?

    /// Date range end (nil = no end limit)
    public var endDate: Date?

    /// Filter to a specific display ID (nil = all displays)
    public var displayID: UInt32?

    /// Filter to focused frames only (nil/false = no focus predicate)
    public var focusedOnly: Bool?
    /// Multi-range date filter. When non-empty, this takes precedence over `startDate`/`endDate`.
    public var dateRanges: [DateRangeCriterion]?

    public init(
        selectedApps: Set<String>? = nil,
        appFilterMode: AppFilterMode = .include,
        selectedSources: Set<FrameSource>? = nil,
        hiddenFilter: HiddenFilter = .hide,
        commentFilter: CommentFilter = .allFrames,
        selectedTags: Set<Int64>? = nil,
        tagFilterMode: TagFilterMode = .include,
        windowNameFilter: String? = nil,
        browserUrlFilter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        displayID: UInt32? = nil,
        focusedOnly: Bool? = nil,
        dateRanges: [DateRangeCriterion]? = nil
    ) {
        self.selectedApps = selectedApps
        self.appFilterMode = appFilterMode
        self.selectedSources = selectedSources
        self.hiddenFilter = hiddenFilter
        self.commentFilter = commentFilter
        self.selectedTags = selectedTags
        self.tagFilterMode = tagFilterMode
        self.windowNameFilter = windowNameFilter
        self.browserUrlFilter = browserUrlFilter
        self.startDate = startDate
        self.endDate = endDate
        self.displayID = displayID
        self.focusedOnly = focusedOnly
        self.dateRanges = Self.sanitizedDateRanges(dateRanges)
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

    /// Returns true if any filter is active (different from default)
    public var hasActiveFilters: Bool {
        (selectedApps != nil && !selectedApps!.isEmpty) ||
        (selectedSources != nil && !selectedSources!.isEmpty) ||
        hiddenFilter != .hide ||
        commentFilter != .allFrames ||
        (selectedTags != nil && !selectedTags!.isEmpty) ||
        (windowNameFilter != nil && !windowNameFilter!.isEmpty) ||
        (browserUrlFilter != nil && !browserUrlFilter!.isEmpty) ||
        !effectiveDateRanges.isEmpty ||
        displayID != nil ||
        focusedOnly == true
    }

    /// Returns true if any advanced filter is active
    public var hasAdvancedFilters: Bool {
        (windowNameFilter != nil && !windowNameFilter!.isEmpty) ||
        (browserUrlFilter != nil && !browserUrlFilter!.isEmpty)
    }

    /// Count of active filter categories
    public var activeFilterCount: Int {
        var count = 0
        if selectedApps != nil && !selectedApps!.isEmpty { count += 1 }
        if selectedSources != nil && !selectedSources!.isEmpty { count += 1 }
        if hiddenFilter != .hide { count += 1 }
        if commentFilter != .allFrames { count += 1 }
        if selectedTags != nil && !selectedTags!.isEmpty { count += 1 }
        if windowNameFilter != nil && !windowNameFilter!.isEmpty { count += 1 }
        if browserUrlFilter != nil && !browserUrlFilter!.isEmpty { count += 1 }
        if !effectiveDateRanges.isEmpty { count += 1 }
        if displayID != nil { count += 1 }
        if focusedOnly == true { count += 1 }
        return count
    }

    /// No filters applied (default state)
    public static let none = FilterCriteria()

    private enum CodingKeys: String, CodingKey {
        case selectedApps
        case appFilterMode
        case selectedSources
        case hiddenFilter
        case commentFilter
        case selectedTags
        case tagFilterMode
        case windowNameFilter
        case browserUrlFilter
        case startDate
        case endDate
        case dateRanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedApps = try container.decodeIfPresent(Set<String>.self, forKey: .selectedApps)
        appFilterMode = try container.decodeIfPresent(AppFilterMode.self, forKey: .appFilterMode) ?? .include
        selectedSources = try container.decodeIfPresent(Set<FrameSource>.self, forKey: .selectedSources)
        hiddenFilter = try container.decodeIfPresent(HiddenFilter.self, forKey: .hiddenFilter) ?? .hide
        commentFilter = try container.decodeIfPresent(CommentFilter.self, forKey: .commentFilter) ?? .allFrames
        selectedTags = try container.decodeIfPresent(Set<Int64>.self, forKey: .selectedTags)
        tagFilterMode = try container.decodeIfPresent(TagFilterMode.self, forKey: .tagFilterMode) ?? .include
        windowNameFilter = try container.decodeIfPresent(String.self, forKey: .windowNameFilter)
        browserUrlFilter = try container.decodeIfPresent(String.self, forKey: .browserUrlFilter)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        dateRanges = Self.sanitizedDateRanges(try container.decodeIfPresent([DateRangeCriterion].self, forKey: .dateRanges))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedApps, forKey: .selectedApps)
        try container.encode(appFilterMode, forKey: .appFilterMode)
        try container.encodeIfPresent(selectedSources, forKey: .selectedSources)
        try container.encode(hiddenFilter, forKey: .hiddenFilter)
        try container.encode(commentFilter, forKey: .commentFilter)
        try container.encodeIfPresent(selectedTags, forKey: .selectedTags)
        try container.encode(tagFilterMode, forKey: .tagFilterMode)
        try container.encodeIfPresent(windowNameFilter, forKey: .windowNameFilter)
        try container.encodeIfPresent(browserUrlFilter, forKey: .browserUrlFilter)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(Self.sanitizedDateRanges(dateRanges), forKey: .dateRanges)
    }

    private static func sanitizedDateRanges(_ ranges: [DateRangeCriterion]?) -> [DateRangeCriterion]? {
        guard let ranges else { return nil }
        let sanitized = ranges.filter(\.hasBounds)
        return sanitized.isEmpty ? nil : sanitized
    }
}
