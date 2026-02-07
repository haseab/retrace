import Foundation

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

    public init(
        selectedApps: Set<String>? = nil,
        appFilterMode: AppFilterMode = .include,
        selectedSources: Set<FrameSource>? = nil,
        hiddenFilter: HiddenFilter = .hide,
        selectedTags: Set<Int64>? = nil,
        tagFilterMode: TagFilterMode = .include,
        windowNameFilter: String? = nil,
        browserUrlFilter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.selectedApps = selectedApps
        self.appFilterMode = appFilterMode
        self.selectedSources = selectedSources
        self.hiddenFilter = hiddenFilter
        self.selectedTags = selectedTags
        self.tagFilterMode = tagFilterMode
        self.windowNameFilter = windowNameFilter
        self.browserUrlFilter = browserUrlFilter
        self.startDate = startDate
        self.endDate = endDate
    }

    /// Returns true if any filter is active (different from default)
    public var hasActiveFilters: Bool {
        (selectedApps != nil && !selectedApps!.isEmpty) ||
        (selectedSources != nil && !selectedSources!.isEmpty) ||
        hiddenFilter != .hide ||
        (selectedTags != nil && !selectedTags!.isEmpty) ||
        (windowNameFilter != nil && !windowNameFilter!.isEmpty) ||
        (browserUrlFilter != nil && !browserUrlFilter!.isEmpty) ||
        startDate != nil ||
        endDate != nil
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
        if selectedTags != nil && !selectedTags!.isEmpty { count += 1 }
        if windowNameFilter != nil && !windowNameFilter!.isEmpty { count += 1 }
        if browserUrlFilter != nil && !browserUrlFilter!.isEmpty { count += 1 }
        if startDate != nil || endDate != nil { count += 1 }
        return count
    }

    /// No filters applied (default state)
    public static let none = FilterCriteria()
}
