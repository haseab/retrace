import Foundation
import Shared

enum CLIDateCoding {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func configure(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
    }

    static func configure(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = formatter.date(from: value) {
                return date
            }

            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]
            if let fallbackDate = fallbackFormatter.date(from: value) {
                return fallbackDate
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
    }
}

public enum CLICommand: Sendable, Equatable {
    case status
    case apps(CLIAppsRequest)
    case search(CLISearchRequest)
    case jump(CLIJumpRequest)
    case around(CLIAroundRequest)
    case open(CLIOpenRequest)
    case config(CLIConfigRequest)
    case usage(CLIUsageRequest)
    case extract(CLIExtractRequest)
    case inspect(CLIInspectRequest)
    case help(CLIHelpRequest)
    case completions(CLICompletionsRequest)

    public var name: String {
        switch self {
        case .status:
            return "status"
        case .apps:
            return "apps"
        case .search:
            return "search"
        case .jump:
            return "jump"
        case .around:
            return "around"
        case .open:
            return "open"
        case .config:
            return "config"
        case .usage:
            return "usage"
        case .extract:
            return "extract"
        case .inspect:
            return "inspect"
        case .help:
            return "help"
        case .completions:
            return "completions"
        }
    }
}

public struct CLITimeReference: Sendable, Equatable {
    public let rawValue: String
    public let date: Date

    public init(rawValue: String, date: Date) {
        self.rawValue = rawValue
        self.date = date
    }
}

public enum CLISearchSort: String, Codable, Sendable, CaseIterable, Equatable {
    case relevance
    case newest
    case oldest
}

public struct CLISearchRequest: Sendable, Equatable {
    public let queryText: String
    public let exact: Bool
    public let includeApps: [String]
    public let excludeApps: [String]
    public let ranges: [DateRangeCriterion]
    public let includeURLTerms: [String]
    public let excludeURLTerms: [String]
    public let includeWindowTerms: [String]
    public let excludeWindowTerms: [String]
    public let includeTagNames: [String]
    public let excludeTagNames: [String]
    public let commentFilter: CommentFilter
    public let hiddenFilter: HiddenFilter
    public let sort: CLISearchSort
    public let limit: Int

    public init(
        queryText: String,
        exact: Bool = false,
        includeApps: [String] = [],
        excludeApps: [String] = [],
        ranges: [DateRangeCriterion] = [],
        includeURLTerms: [String] = [],
        excludeURLTerms: [String] = [],
        includeWindowTerms: [String] = [],
        excludeWindowTerms: [String] = [],
        includeTagNames: [String] = [],
        excludeTagNames: [String] = [],
        commentFilter: CommentFilter = .allFrames,
        hiddenFilter: HiddenFilter = .hide,
        sort: CLISearchSort = .relevance,
        limit: Int = 50
    ) {
        self.queryText = queryText
        self.exact = exact
        self.includeApps = includeApps
        self.excludeApps = excludeApps
        self.ranges = ranges
        self.includeURLTerms = includeURLTerms
        self.excludeURLTerms = excludeURLTerms
        self.includeWindowTerms = includeWindowTerms
        self.excludeWindowTerms = excludeWindowTerms
        self.includeTagNames = includeTagNames
        self.excludeTagNames = excludeTagNames
        self.commentFilter = commentFilter
        self.hiddenFilter = hiddenFilter
        self.sort = sort
        self.limit = limit
    }

    public var filterCount: Int {
        var count = 0

        if !includeApps.isEmpty || !excludeApps.isEmpty {
            count += 1
        }
        if !ranges.isEmpty {
            count += 1
        }
        if !includeURLTerms.isEmpty || !excludeURLTerms.isEmpty {
            count += 1
        }
        if !includeWindowTerms.isEmpty || !excludeWindowTerms.isEmpty {
            count += 1
        }
        if !includeTagNames.isEmpty || !excludeTagNames.isEmpty {
            count += 1
        }
        if commentFilter != .allFrames {
            count += 1
        }
        if hiddenFilter != .hide {
            count += 1
        }

        return count
    }
}

public struct CLIJumpRequest: Sendable, Equatable {
    public let target: CLITimeReference

    public init(target: CLITimeReference) {
        self.target = target
    }
}

public struct CLIDeeplinkTimelineState: Codable, Sendable, Equatable {
    public let timestamp: Date?
    public let frameID: Int64?

    public init(timestamp: Date? = nil, frameID: Int64? = nil) {
        self.timestamp = timestamp
        self.frameID = frameID
    }
}

public struct CLIDeeplinkSearchState: Codable, Sendable, Equatable {
    public let queryText: String?
    public let appBundleIDs: [String]
    public let appFilterMode: AppFilterMode
    public let tagIDs: [Int64]
    public let tagFilterMode: TagFilterMode
    public let hiddenFilter: HiddenFilter
    public let commentFilter: CommentFilter
    public let dateRanges: [DateRangeCriterion]
    public let windowNameTerms: [String]
    public let windowNameExcludedTerms: [String]
    public let browserURLTerms: [String]
    public let browserURLExcludedTerms: [String]
    public let sort: CLISearchSort
    public let timestamp: Date?

    public init(
        queryText: String?,
        appBundleIDs: [String] = [],
        appFilterMode: AppFilterMode = .include,
        tagIDs: [Int64] = [],
        tagFilterMode: TagFilterMode = .include,
        hiddenFilter: HiddenFilter = .hide,
        commentFilter: CommentFilter = .allFrames,
        dateRanges: [DateRangeCriterion] = [],
        windowNameTerms: [String] = [],
        windowNameExcludedTerms: [String] = [],
        browserURLTerms: [String] = [],
        browserURLExcludedTerms: [String] = [],
        sort: CLISearchSort = .relevance,
        timestamp: Date? = nil
    ) {
        self.queryText = queryText
        self.appBundleIDs = appBundleIDs
        self.appFilterMode = appFilterMode
        self.tagIDs = tagIDs
        self.tagFilterMode = tagFilterMode
        self.hiddenFilter = hiddenFilter
        self.commentFilter = commentFilter
        self.dateRanges = Array(dateRanges.filter(\.hasBounds).prefix(5))
        self.windowNameTerms = windowNameTerms
        self.windowNameExcludedTerms = windowNameExcludedTerms
        self.browserURLTerms = browserURLTerms
        self.browserURLExcludedTerms = browserURLExcludedTerms
        self.sort = sort
        self.timestamp = timestamp
    }
}

public enum CLIAroundAnchor: Sendable, Equatable {
    case at(CLITimeReference)
    case frameID(Int64)
    case resultID(Int)
}

public struct CLIAroundRequest: Sendable, Equatable {
    public let anchor: CLIAroundAnchor
    public let beforeCount: Int
    public let afterCount: Int

    public init(anchor: CLIAroundAnchor, beforeCount: Int = 10, afterCount: Int = 10) {
        self.anchor = anchor
        self.beforeCount = beforeCount
        self.afterCount = afterCount
    }
}

public struct CLIOpenSearchRequest: Sendable, Equatable {
    public let queryText: String
    public let exact: Bool
    public let includeApps: [String]
    public let excludeApps: [String]
    public let ranges: [DateRangeCriterion]
    public let includeURLTerms: [String]
    public let excludeURLTerms: [String]
    public let includeWindowTerms: [String]
    public let excludeWindowTerms: [String]
    public let includeTagNames: [String]
    public let excludeTagNames: [String]
    public let commentFilter: CommentFilter
    public let hiddenFilter: HiddenFilter
    public let sort: CLISearchSort
    public let timestamp: CLITimeReference?

    public init(
        queryText: String,
        exact: Bool = false,
        includeApps: [String] = [],
        excludeApps: [String] = [],
        ranges: [DateRangeCriterion] = [],
        includeURLTerms: [String] = [],
        excludeURLTerms: [String] = [],
        includeWindowTerms: [String] = [],
        excludeWindowTerms: [String] = [],
        includeTagNames: [String] = [],
        excludeTagNames: [String] = [],
        commentFilter: CommentFilter = .allFrames,
        hiddenFilter: HiddenFilter = .hide,
        sort: CLISearchSort = .relevance,
        timestamp: CLITimeReference? = nil
    ) {
        self.queryText = queryText
        self.exact = exact
        self.includeApps = includeApps
        self.excludeApps = excludeApps
        self.ranges = ranges
        self.includeURLTerms = includeURLTerms
        self.excludeURLTerms = excludeURLTerms
        self.includeWindowTerms = includeWindowTerms
        self.excludeWindowTerms = excludeWindowTerms
        self.includeTagNames = includeTagNames
        self.excludeTagNames = excludeTagNames
        self.commentFilter = commentFilter
        self.hiddenFilter = hiddenFilter
        self.sort = sort
        self.timestamp = timestamp
    }
}

public enum CLIOpenSelector: Sendable, Equatable {
    case timeline(CLITimeReference)
    case frameID(Int64)
    case resultID(Int)
    case search(CLIOpenSearchRequest)
}

public struct CLIOpenRequest: Sendable, Equatable {
    public let selector: CLIOpenSelector

    public init(selector: CLIOpenSelector) {
        self.selector = selector
    }
}

public struct CLIAppsListRequest: Sendable, Equatable {
    public init() {}
}

public enum CLIAppsRequest: Sendable, Equatable {
    case list(CLIAppsListRequest)

    public var subcommandName: String {
        switch self {
        case .list:
            return "list"
        }
    }
}

public struct CLIHelpRequest: Sendable, Equatable {
    public let topicPath: [String]

    public init(topicPath: [String] = []) {
        self.topicPath = topicPath
    }
}

public enum CLICompletionShell: String, Codable, Sendable, CaseIterable, Equatable {
    case bash
    case zsh
    case fish
}

public struct CLICompletionsRequest: Sendable, Equatable {
    public let shell: CLICompletionShell

    public init(shell: CLICompletionShell) {
        self.shell = shell
    }
}

public struct CLIConfigKeyRequest: Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

public struct CLIConfigSetRequest: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public enum CLIConfigRequest: Sendable, Equatable {
    case list
    case get(CLIConfigKeyRequest)
    case set(CLIConfigSetRequest)
    case reset(CLIConfigKeyRequest)

    public var subcommandName: String {
        switch self {
        case .list:
            return "list"
        case .get:
            return "get"
        case .set:
            return "set"
        case .reset:
            return "reset"
        }
    }
}

public enum CLIExtractSelector: Sendable, Equatable {
    case at(CLITimeReference)
    case frameID(Int64)
    case resultID(Int)
}

public struct CLIExtractTextRequest: Sendable, Equatable {
    public let selector: CLIExtractSelector

    public init(selector: CLIExtractSelector) {
        self.selector = selector
    }
}

public struct CLIExtractURLRequest: Sendable, Equatable {
    public let selector: CLIExtractSelector

    public init(selector: CLIExtractSelector) {
        self.selector = selector
    }
}

public struct CLIExtractLinksRequest: Sendable, Equatable {
    public let selector: CLIExtractSelector

    public init(selector: CLIExtractSelector) {
        self.selector = selector
    }
}

public struct CLIExtractOCRRequest: Sendable, Equatable {
    public let selector: CLIExtractSelector

    public init(selector: CLIExtractSelector) {
        self.selector = selector
    }
}

public struct CLIExtractImageRequest: Sendable, Equatable {
    public let selector: CLIExtractSelector
    public let outputPath: String
    public let overwrite: Bool

    public init(selector: CLIExtractSelector, outputPath: String, overwrite: Bool = false) {
        self.selector = selector
        self.outputPath = outputPath
        self.overwrite = overwrite
    }
}

public enum CLIExtractRequest: Sendable, Equatable {
    case text(CLIExtractTextRequest)
    case url(CLIExtractURLRequest)
    case links(CLIExtractLinksRequest)
    case ocr(CLIExtractOCRRequest)
    case image(CLIExtractImageRequest)

    public var subcommandName: String {
        switch self {
        case .text:
            return "text"
        case .url:
            return "url"
        case .links:
            return "links"
        case .ocr:
            return "ocr"
        case .image:
            return "image"
        }
    }
}

public struct CLIInspectMetricsRequest: Sendable, Equatable {
    public let recentLimit: Int

    public init(recentLimit: Int = 100) {
        self.recentLimit = recentLimit
    }
}

public enum CLIInspectFrameSelector: Sendable, Equatable {
    case frameID(Int64)
    case resultID(Int)
}

public struct CLIInspectFrameRequest: Sendable, Equatable {
    public let selector: CLIInspectFrameSelector

    public init(selector: CLIInspectFrameSelector) {
        self.selector = selector
    }
}

public enum CLIInspectRequest: Sendable, Equatable {
    case system
    case ocr
    case queue
    case storage
    case metrics(CLIInspectMetricsRequest)
    case frame(CLIInspectFrameRequest)

    public var subcommandName: String {
        switch self {
        case .system:
            return "system"
        case .ocr:
            return "ocr"
        case .queue:
            return "queue"
        case .storage:
            return "storage"
        case .metrics:
            return "metrics"
        case .frame:
            return "frame"
        }
    }
}

public struct CLIUsageTimeRange: Sendable, Equatable {
    public let from: CLITimeReference
    public let to: CLITimeReference

    public init(from: CLITimeReference, to: CLITimeReference) {
        self.from = from
        self.to = to
    }
}

public struct CLIUsageAppsRequest: Sendable, Equatable {
    public let timeRange: CLIUsageTimeRange
    public let limit: Int

    public init(timeRange: CLIUsageTimeRange, limit: Int = 50) {
        self.timeRange = timeRange
        self.limit = limit
    }
}

public struct CLIUsageWebsitesRequest: Sendable, Equatable {
    public let app: String
    public let timeRange: CLIUsageTimeRange
    public let limit: Int

    public init(app: String, timeRange: CLIUsageTimeRange, limit: Int = 50) {
        self.app = app
        self.timeRange = timeRange
        self.limit = limit
    }
}

public struct CLIUsageTabsRequest: Sendable, Equatable {
    public let app: String
    public let website: String?
    public let timeRange: CLIUsageTimeRange
    public let limit: Int

    public init(
        app: String,
        website: String? = nil,
        timeRange: CLIUsageTimeRange,
        limit: Int = 100
    ) {
        self.app = app
        self.website = website
        self.timeRange = timeRange
        self.limit = limit
    }
}

public struct CLIUsageSessionsRequest: Sendable, Equatable {
    public let timeRange: CLIUsageTimeRange
    public let app: String?
    public let window: String?
    public let website: String?
    public let hiddenFilter: HiddenFilter
    public let limit: Int
    public let offset: Int

    public init(
        timeRange: CLIUsageTimeRange,
        app: String? = nil,
        window: String? = nil,
        website: String? = nil,
        hiddenFilter: HiddenFilter = .hide,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.timeRange = timeRange
        self.app = app
        self.window = window
        self.website = website
        self.hiddenFilter = hiddenFilter
        self.limit = limit
        self.offset = offset
    }
}

public struct CLIUsageScreenTimeRequest: Sendable, Equatable {
    public let timeRange: CLIUsageTimeRange

    public init(timeRange: CLIUsageTimeRange) {
        self.timeRange = timeRange
    }
}

public struct CLIUsageSwitchesRequest: Sendable, Equatable {
    public let timeRange: CLIUsageTimeRange
    public let app: String?
    public let hiddenFilter: HiddenFilter
    public let limit: Int

    public init(
        timeRange: CLIUsageTimeRange,
        app: String? = nil,
        hiddenFilter: HiddenFilter = .hide,
        limit: Int = 100
    ) {
        self.timeRange = timeRange
        self.app = app
        self.hiddenFilter = hiddenFilter
        self.limit = limit
    }
}

public enum CLIUsageRequest: Sendable, Equatable {
    case apps(CLIUsageAppsRequest)
    case websites(CLIUsageWebsitesRequest)
    case tabs(CLIUsageTabsRequest)
    case sessions(CLIUsageSessionsRequest)
    case screenTime(CLIUsageScreenTimeRequest)
    case switches(CLIUsageSwitchesRequest)

    public var subcommandName: String {
        switch self {
        case .apps:
            return "apps"
        case .websites:
            return "websites"
        case .tabs:
            return "tabs"
        case .sessions:
            return "sessions"
        case .screenTime:
            return "screen-time"
        case .switches:
            return "switches"
        }
    }
}

public struct CLICommandEnvelope<Payload: Encodable>: Encodable {
    public let command: String
    public let generatedAt: Date
    public let result: Payload

    public init(command: String, generatedAt: Date = Date(), result: Payload) {
        self.command = command
        self.generatedAt = generatedAt
        self.result = result
    }
}

public enum CLIConfigValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case null
        case bool
        case int
        case double
        case string
        case date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .null:
            self = .null
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .value))
        }
    }
}

public struct CLIErrorEnvelope: Encodable {
    public let command: String?
    public let generatedAt: Date
    public let error: CLIErrorPayload

    public init(command: String? = nil, generatedAt: Date = Date(), error: CLIErrorPayload) {
        self.command = command
        self.generatedAt = generatedAt
        self.error = error
    }
}

public struct CLIConfigEntryOutput: Codable, Sendable, Equatable {
    public let key: String
    public let defaultsKey: String
    public let aliases: [String]
    public let category: String
    public let valueType: String
    public let nullable: Bool
    public let currentValue: CLIConfigValue
    public let defaultValue: CLIConfigValue
    public let currentIsDefault: Bool
    public let allowedValues: [CLIConfigValue]?
    public let note: String?

    public init(
        key: String,
        defaultsKey: String,
        aliases: [String],
        category: String,
        valueType: String,
        nullable: Bool,
        currentValue: CLIConfigValue,
        defaultValue: CLIConfigValue,
        currentIsDefault: Bool,
        allowedValues: [CLIConfigValue]? = nil,
        note: String? = nil
    ) {
        self.key = key
        self.defaultsKey = defaultsKey
        self.aliases = aliases
        self.category = category
        self.valueType = valueType
        self.nullable = nullable
        self.currentValue = currentValue
        self.defaultValue = defaultValue
        self.currentIsDefault = currentIsDefault
        self.allowedValues = allowedValues
        self.note = note
    }
}

public struct CLIConfigListOutput: Codable, Sendable, Equatable {
    public let entryCount: Int
    public let persistenceModel: String
    public let runtimeBehaviorNote: String
    public let entries: [CLIConfigEntryOutput]

    public init(
        entryCount: Int,
        persistenceModel: String,
        runtimeBehaviorNote: String,
        entries: [CLIConfigEntryOutput]
    ) {
        self.entryCount = entryCount
        self.persistenceModel = persistenceModel
        self.runtimeBehaviorNote = runtimeBehaviorNote
        self.entries = entries
    }
}

public struct CLIConfigGetOutput: Codable, Sendable, Equatable {
    public let persistenceModel: String
    public let runtimeBehaviorNote: String
    public let entry: CLIConfigEntryOutput

    public init(
        persistenceModel: String,
        runtimeBehaviorNote: String,
        entry: CLIConfigEntryOutput
    ) {
        self.persistenceModel = persistenceModel
        self.runtimeBehaviorNote = runtimeBehaviorNote
        self.entry = entry
    }
}

public struct CLIConfigSetOutput: Codable, Sendable, Equatable {
    public let key: String
    public let changed: Bool
    public let previousValue: CLIConfigValue
    public let persistenceModel: String
    public let runtimeBehaviorNote: String
    public let entry: CLIConfigEntryOutput

    public init(
        key: String,
        changed: Bool,
        previousValue: CLIConfigValue,
        persistenceModel: String,
        runtimeBehaviorNote: String,
        entry: CLIConfigEntryOutput
    ) {
        self.key = key
        self.changed = changed
        self.previousValue = previousValue
        self.persistenceModel = persistenceModel
        self.runtimeBehaviorNote = runtimeBehaviorNote
        self.entry = entry
    }
}

public struct CLIConfigResetOutput: Codable, Sendable, Equatable {
    public let key: String
    public let changed: Bool
    public let previousValue: CLIConfigValue
    public let persistenceModel: String
    public let runtimeBehaviorNote: String
    public let entry: CLIConfigEntryOutput

    public init(
        key: String,
        changed: Bool,
        previousValue: CLIConfigValue,
        persistenceModel: String,
        runtimeBehaviorNote: String,
        entry: CLIConfigEntryOutput
    ) {
        self.key = key
        self.changed = changed
        self.previousValue = previousValue
        self.persistenceModel = persistenceModel
        self.runtimeBehaviorNote = runtimeBehaviorNote
        self.entry = entry
    }
}

public struct CLIErrorPayload: Encodable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: String]?

    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct CLIStatusOutput: Codable, Sendable, Equatable {
    public let pipeline: CLIStatusPipeline
    public let storage: CLIStatusStorage
    public let rewind: CLIStatusRewind
    public let statistics: CLIStatusStatistics

    public init(
        pipeline: CLIStatusPipeline,
        storage: CLIStatusStorage,
        rewind: CLIStatusRewind,
        statistics: CLIStatusStatistics
    ) {
        self.pipeline = pipeline
        self.storage = storage
        self.rewind = rewind
        self.statistics = statistics
    }
}

public struct CLIStatusPipeline: Codable, Sendable, Equatable {
    public let runtimeStatus = "unavailable: live app state is not queried"
    public let isRunning: Bool?
    public let framesProcessed: Int?
    public let errorCount: Int?
    public let startTime: Date?
    public let latestFrameTimestamp: Date?

    public init(
        isRunning: Bool?,
        framesProcessed: Int?,
        errorCount: Int?,
        startTime: Date?,
        latestFrameTimestamp: Date?
    ) {
        self.isRunning = isRunning
        self.framesProcessed = framesProcessed
        self.errorCount = errorCount
        self.startTime = startTime
        self.latestFrameTimestamp = latestFrameTimestamp
    }
}

public struct CLIStatusStorage: Codable, Sendable, Equatable {
    public let storageRoot: String
    public let storageRootExists: Bool
    public let databasePath: String
    public let databaseExists: Bool

    public init(
        storageRoot: String,
        storageRootExists: Bool,
        databasePath: String,
        databaseExists: Bool
    ) {
        self.storageRoot = storageRoot
        self.storageRootExists = storageRootExists
        self.databasePath = databasePath
        self.databaseExists = databaseExists
    }
}

public struct CLIStatusRewind: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let storageRoot: String
    public let storageRootExists: Bool
    public let databasePath: String
    public let databaseExists: Bool

    public init(
        enabled: Bool,
        storageRoot: String,
        storageRootExists: Bool,
        databasePath: String,
        databaseExists: Bool
    ) {
        self.enabled = enabled
        self.storageRoot = storageRoot
        self.storageRootExists = storageRootExists
        self.databasePath = databasePath
        self.databaseExists = databaseExists
    }
}

public struct CLIStatusStatistics: Codable, Sendable, Equatable {
    public let frameCount: Int
    public let sessionCount: Int
    public let distinctAppCount: Int
    public let totalCapturedDurationSeconds: Double

    public init(
        frameCount: Int,
        sessionCount: Int,
        distinctAppCount: Int,
        totalCapturedDurationSeconds: Double
    ) {
        self.frameCount = frameCount
        self.sessionCount = sessionCount
        self.distinctAppCount = distinctAppCount
        self.totalCapturedDurationSeconds = totalCapturedDurationSeconds
    }
}

public struct CLISearchOutput: Codable, Sendable, Equatable {
    public let query: CLISearchQueryOutput
    public let resultCount: Int
    public let searchTimeMs: Int
    public let storedResultsAvailable: Bool
    public let nextCursor: SearchPageCursor?
    public let results: [CLISearchResultOutput]

    public init(
        query: CLISearchQueryOutput,
        resultCount: Int,
        searchTimeMs: Int,
        storedResultsAvailable: Bool,
        nextCursor: SearchPageCursor?,
        results: [CLISearchResultOutput]
    ) {
        self.query = query
        self.resultCount = resultCount
        self.searchTimeMs = searchTimeMs
        self.storedResultsAvailable = storedResultsAvailable
        self.nextCursor = nextCursor
        self.results = results
    }
}

public struct CLIFrameOutput: Codable, Sendable, Equatable {
    public let frameID: Int64
    public let timestamp: Date
    public let appBundleID: String?
    public let appName: String?
    public let windowName: String?
    public let browserURL: String?
    public let segmentID: Int64
    public let videoID: Int64
    public let frameIndex: Int
    public let source: FrameSource

    public init(
        frameID: Int64,
        timestamp: Date,
        appBundleID: String?,
        appName: String?,
        windowName: String?,
        browserURL: String?,
        segmentID: Int64,
        videoID: Int64,
        frameIndex: Int,
        source: FrameSource
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowName = windowName
        self.browserURL = browserURL
        self.segmentID = segmentID
        self.videoID = videoID
        self.frameIndex = frameIndex
        self.source = source
    }
}

public struct CLIJumpOutput: Codable, Sendable, Equatable {
    public let requestedAt: String
    public let resolvedAt: Date
    public let matchedFrame: CLIFrameOutput
    public let deltaSeconds: Double
    public let previousFrame: CLIFrameOutput?
    public let nextFrame: CLIFrameOutput?

    public init(
        requestedAt: String,
        resolvedAt: Date,
        matchedFrame: CLIFrameOutput,
        deltaSeconds: Double,
        previousFrame: CLIFrameOutput?,
        nextFrame: CLIFrameOutput?
    ) {
        self.requestedAt = requestedAt
        self.resolvedAt = resolvedAt
        self.matchedFrame = matchedFrame
        self.deltaSeconds = deltaSeconds
        self.previousFrame = previousFrame
        self.nextFrame = nextFrame
    }
}

public struct CLIAroundAnchorOutput: Codable, Sendable, Equatable {
    public let requestedAt: String?
    public let requestedFrameID: Int64?
    public let matchedFrame: CLIFrameOutput

    public init(requestedAt: String?, requestedFrameID: Int64?, matchedFrame: CLIFrameOutput) {
        self.requestedAt = requestedAt
        self.requestedFrameID = requestedFrameID
        self.matchedFrame = matchedFrame
    }
}

public struct CLIAroundFrameOutput: Codable, Sendable, Equatable {
    public let position: String
    public let frame: CLIFrameOutput

    public init(position: String, frame: CLIFrameOutput) {
        self.position = position
        self.frame = frame
    }
}

public struct CLIAroundOutput: Codable, Sendable, Equatable {
    public let anchor: CLIAroundAnchorOutput
    public let beforeCount: Int
    public let afterCount: Int
    public let frames: [CLIAroundFrameOutput]

    public init(
        anchor: CLIAroundAnchorOutput,
        beforeCount: Int,
        afterCount: Int,
        frames: [CLIAroundFrameOutput]
    ) {
        self.anchor = anchor
        self.beforeCount = beforeCount
        self.afterCount = afterCount
        self.frames = frames
    }
}

public struct CLIAppsListEntryOutput: Codable, Sendable, Equatable {
    public let bundleID: String
    public let appName: String
    public let bundleSuffix: String
    public let installed: Bool

    public init(bundleID: String, appName: String, bundleSuffix: String, installed: Bool) {
        self.bundleID = bundleID
        self.appName = appName
        self.bundleSuffix = bundleSuffix
        self.installed = installed
    }
}

public struct CLIAppsListOutput: Codable, Sendable, Equatable {
    public let count: Int
    public let apps: [CLIAppsListEntryOutput]

    public init(count: Int, apps: [CLIAppsListEntryOutput]) {
        self.count = count
        self.apps = apps
    }
}

public struct CLIOpenOutput: Codable, Sendable, Equatable {
    public let url: String
    public let opened: Bool
    public let route: String
    public let timeline: CLIDeeplinkTimelineState?
    public let search: CLIDeeplinkSearchState?

    public init(
        url: String,
        opened: Bool,
        route: String,
        timeline: CLIDeeplinkTimelineState? = nil,
        search: CLIDeeplinkSearchState? = nil
    ) {
        self.url = url
        self.opened = opened
        self.route = route
        self.timeline = timeline
        self.search = search
    }
}

public struct CLIHelpSubcommandOutput: Codable, Sendable, Equatable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public struct CLIHelpOptionOutput: Codable, Sendable, Equatable {
    public let flag: String
    public let valueName: String?
    public let repeatable: Bool
    public let description: String

    public init(flag: String, valueName: String? = nil, repeatable: Bool = false, description: String) {
        self.flag = flag
        self.valueName = valueName
        self.repeatable = repeatable
        self.description = description
    }
}

public struct CLIHelpOutput: Codable, Sendable, Equatable {
    public let topicPath: [String]
    public let summary: String
    public let usage: String
    public let notes: [String]
    public let subcommands: [CLIHelpSubcommandOutput]
    public let options: [CLIHelpOptionOutput]
    public let examples: [String]

    public init(
        topicPath: [String],
        summary: String,
        usage: String,
        notes: [String] = [],
        subcommands: [CLIHelpSubcommandOutput] = [],
        options: [CLIHelpOptionOutput] = [],
        examples: [String] = []
    ) {
        self.topicPath = topicPath
        self.summary = summary
        self.usage = usage
        self.notes = notes
        self.subcommands = subcommands
        self.options = options
        self.examples = examples
    }
}

public struct CLICompletionsOutput: Codable, Sendable, Equatable {
    public let shell: CLICompletionShell
    public let script: String

    public init(shell: CLICompletionShell, script: String) {
        self.shell = shell
        self.script = script
    }
}

public struct CLIExtractTargetOutput: Codable, Sendable, Equatable {
    public let requestedAt: String?
    public let requestedFrameID: Int64?
    public let requestedResultID: Int?
    public let matchedFrame: CLIFrameOutput

    public init(
        requestedAt: String?,
        requestedFrameID: Int64?,
        requestedResultID: Int?,
        matchedFrame: CLIFrameOutput
    ) {
        self.requestedAt = requestedAt
        self.requestedFrameID = requestedFrameID
        self.requestedResultID = requestedResultID
        self.matchedFrame = matchedFrame
    }
}

public struct CLIExtractTextOutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let text: String
    public let nodeCount: Int

    public init(target: CLIExtractTargetOutput, text: String, nodeCount: Int) {
        self.target = target
        self.text = text
        self.nodeCount = nodeCount
    }
}

public struct CLIExtractURLOutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let browserURL: String?

    public init(target: CLIExtractTargetOutput, browserURL: String?) {
        self.target = target
        self.browserURL = browserURL
    }
}

public struct CLIExtractLinkStateOutput: Codable, Sendable, Equatable {
    public let mouseX: Double?
    public let mouseY: Double?
    public let scrollX: Double?
    public let scrollY: Double?
    public let videoCurrentTime: Double?

    public init(
        mouseX: Double?,
        mouseY: Double?,
        scrollX: Double?,
        scrollY: Double?,
        videoCurrentTime: Double?
    ) {
        self.mouseX = mouseX
        self.mouseY = mouseY
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.videoCurrentTime = videoCurrentTime
    }
}

public struct CLIExtractLinkRowOutput: Codable, Sendable, Equatable {
    public let order: Int
    public let url: String
    public let nodeID: Int

    public init(order: Int, url: String, nodeID: Int) {
        self.order = order
        self.url = url
        self.nodeID = nodeID
    }
}

public struct CLIExtractLinksOutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let linkCount: Int
    public let state: CLIExtractLinkStateOutput?
    public let links: [CLIExtractLinkRowOutput]

    public init(
        target: CLIExtractTargetOutput,
        linkCount: Int,
        state: CLIExtractLinkStateOutput?,
        links: [CLIExtractLinkRowOutput]
    ) {
        self.target = target
        self.linkCount = linkCount
        self.state = state
        self.links = links
    }
}

public struct CLIExtractOCRNodeOutput: Codable, Sendable, Equatable {
    public let id: Int
    public let nodeOrder: Int
    public let frameID: Int64
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let text: String
    public let isRedacted: Bool

    public init(
        id: Int,
        nodeOrder: Int,
        frameID: Int64,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        text: String,
        isRedacted: Bool
    ) {
        self.id = id
        self.nodeOrder = nodeOrder
        self.frameID = frameID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.isRedacted = isRedacted
    }
}

public struct CLIExtractOCROutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let text: String
    public let nodeCount: Int
    public let nodes: [CLIExtractOCRNodeOutput]

    public init(
        target: CLIExtractTargetOutput,
        text: String,
        nodeCount: Int,
        nodes: [CLIExtractOCRNodeOutput]
    ) {
        self.target = target
        self.text = text
        self.nodeCount = nodeCount
        self.nodes = nodes
    }
}

public struct CLIExtractImageOutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let outputPath: String
    public let byteCount: Int

    public init(target: CLIExtractTargetOutput, outputPath: String, byteCount: Int) {
        self.target = target
        self.outputPath = outputPath
        self.byteCount = byteCount
    }
}

public struct CLIInspectMinuteCountOutput: Codable, Sendable, Equatable {
    public let minuteOffset: Int
    public let count: Int

    public init(minuteOffset: Int, count: Int) {
        self.minuteOffset = minuteOffset
        self.count = count
    }
}

public struct CLIInspectProcessOutput: Codable, Sendable, Equatable {
    public let processID: Int32
    public let operatingSystemVersion: String
    public let processorCount: Int
    public let activeProcessorCount: Int
    public let physicalMemoryBytes: UInt64
    public let systemUptimeSeconds: Double
    public let lowPowerModeEnabled: Bool
    public let thermalState: String

    public init(
        processID: Int32,
        operatingSystemVersion: String,
        processorCount: Int,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64,
        systemUptimeSeconds: Double,
        lowPowerModeEnabled: Bool,
        thermalState: String
    ) {
        self.processID = processID
        self.operatingSystemVersion = operatingSystemVersion
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemUptimeSeconds = systemUptimeSeconds
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
    }
}

public struct CLIInspectPowerOutput: Codable, Sendable, Equatable {
    public let source: String
    public let isPaused: Bool
    public let lowPowerModeEnabled: Bool

    public init(source: String, isPaused: Bool, lowPowerModeEnabled: Bool) {
        self.source = source
        self.isPaused = isPaused
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

public struct CLIInspectMemoryComponentOutput: Codable, Sendable, Equatable {
    public let tag: String
    public let category: String
    public let bytes: Int64
    public let count: Int?
    public let unit: String?
    public let function: String
    public let kind: String
    public let note: String?
    public let countsTowardTrackedMemory: Bool

    public init(
        tag: String,
        category: String,
        bytes: Int64,
        count: Int?,
        unit: String?,
        function: String,
        kind: String,
        note: String?,
        countsTowardTrackedMemory: Bool
    ) {
        self.tag = tag
        self.category = category
        self.bytes = bytes
        self.count = count
        self.unit = unit
        self.function = function
        self.kind = kind
        self.note = note
        self.countsTowardTrackedMemory = countsTowardTrackedMemory
    }
}

public struct CLIInspectMemoryFunctionOutput: Codable, Sendable, Equatable {
    public let function: String
    public let trackedBytes: Int64
    public let contextualBytes: Int64
    public let componentCount: Int

    public init(function: String, trackedBytes: Int64, contextualBytes: Int64, componentCount: Int) {
        self.function = function
        self.trackedBytes = trackedBytes
        self.contextualBytes = contextualBytes
        self.componentCount = componentCount
    }
}

public struct CLIInspectMemoryOutput: Codable, Sendable, Equatable {
    public let componentCount: Int
    public let trackedMemoryBytes: Int64
    public let contextualBytes: Int64
    public let trackedAllBytes: Int64
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let internalBytes: UInt64
    public let compressedBytes: UInt64
    public let unattributedBytes: UInt64
    public let topComponents: [CLIInspectMemoryComponentOutput]
    public let topFunctions: [CLIInspectMemoryFunctionOutput]

    public init(
        componentCount: Int,
        trackedMemoryBytes: Int64,
        contextualBytes: Int64,
        trackedAllBytes: Int64,
        footprintBytes: UInt64,
        residentBytes: UInt64,
        internalBytes: UInt64,
        compressedBytes: UInt64,
        unattributedBytes: UInt64,
        topComponents: [CLIInspectMemoryComponentOutput],
        topFunctions: [CLIInspectMemoryFunctionOutput]
    ) {
        self.componentCount = componentCount
        self.trackedMemoryBytes = trackedMemoryBytes
        self.contextualBytes = contextualBytes
        self.trackedAllBytes = trackedAllBytes
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.internalBytes = internalBytes
        self.compressedBytes = compressedBytes
        self.unattributedBytes = unattributedBytes
        self.topComponents = topComponents
        self.topFunctions = topFunctions
    }
}

public struct CLIInspectQueueStatisticsOutput: Codable, Sendable, Equatable {
    public let ocrQueueDepth: Int
    public let ocrPendingCount: Int
    public let ocrProcessingCount: Int
    public let rewriteQueueDepth: Int
    public let rewritePendingCount: Int
    public let rewriteProcessingCount: Int
    public let totalProcessed: Int
    public let totalRewritten: Int
    public let totalFailed: Int
    public let workerCount: Int

    public init(
        ocrQueueDepth: Int,
        ocrPendingCount: Int,
        ocrProcessingCount: Int,
        rewriteQueueDepth: Int,
        rewritePendingCount: Int,
        rewriteProcessingCount: Int,
        totalProcessed: Int,
        totalRewritten: Int,
        totalFailed: Int,
        workerCount: Int
    ) {
        self.ocrQueueDepth = ocrQueueDepth
        self.ocrPendingCount = ocrPendingCount
        self.ocrProcessingCount = ocrProcessingCount
        self.rewriteQueueDepth = rewriteQueueDepth
        self.rewritePendingCount = rewritePendingCount
        self.rewriteProcessingCount = rewriteProcessingCount
        self.totalProcessed = totalProcessed
        self.totalRewritten = totalRewritten
        self.totalFailed = totalFailed
        self.workerCount = workerCount
    }
}

public struct CLIInspectEncodingOutput: Codable, Sendable, Equatable {
    public let queueDepth: Int
    public let pendingCount: Int

    public init(queueDepth: Int, pendingCount: Int) {
        self.queueDepth = queueDepth
        self.pendingCount = pendingCount
    }
}

public struct CLIInspectDatabaseOutput: Codable, Sendable, Equatable {
    public let frameCount: Int
    public let segmentCount: Int
    public let documentCount: Int
    public let databaseSizeBytes: Int64
    public let oldestFrameDate: Date?
    public let newestFrameDate: Date?

    public init(
        frameCount: Int,
        segmentCount: Int,
        documentCount: Int,
        databaseSizeBytes: Int64,
        oldestFrameDate: Date?,
        newestFrameDate: Date?
    ) {
        self.frameCount = frameCount
        self.segmentCount = segmentCount
        self.documentCount = documentCount
        self.databaseSizeBytes = databaseSizeBytes
        self.oldestFrameDate = oldestFrameDate
        self.newestFrameDate = newestFrameDate
    }
}

public struct CLIInspectCaptureOutput: Codable, Sendable, Equatable {
    public let totalFramesCaptured: Int
    public let framesDeduped: Int
    public let averageFrameSizeBytes: Int
    public let captureStartTime: Date?
    public let lastFrameTime: Date?

    public init(
        totalFramesCaptured: Int,
        framesDeduped: Int,
        averageFrameSizeBytes: Int,
        captureStartTime: Date?,
        lastFrameTime: Date?
    ) {
        self.totalFramesCaptured = totalFramesCaptured
        self.framesDeduped = framesDeduped
        self.averageFrameSizeBytes = averageFrameSizeBytes
        self.captureStartTime = captureStartTime
        self.lastFrameTime = lastFrameTime
    }
}

public struct CLIInspectProcessingOutput: Codable, Sendable, Equatable {
    public let framesProcessed: Int
    public let averageOCRTimeMs: Double
    public let averageTextLength: Int
    public let errorCount: Int

    public init(
        framesProcessed: Int,
        averageOCRTimeMs: Double,
        averageTextLength: Int,
        errorCount: Int
    ) {
        self.framesProcessed = framesProcessed
        self.averageOCRTimeMs = averageOCRTimeMs
        self.averageTextLength = averageTextLength
        self.errorCount = errorCount
    }
}

public struct CLIInspectSearchStatisticsOutput: Codable, Sendable, Equatable {
    public let totalDocuments: Int
    public let totalSearches: Int
    public let averageSearchTimeMs: Double

    public init(totalDocuments: Int, totalSearches: Int, averageSearchTimeMs: Double) {
        self.totalDocuments = totalDocuments
        self.totalSearches = totalSearches
        self.averageSearchTimeMs = averageSearchTimeMs
    }
}

public struct CLIInspectSystemOutput: Codable, Sendable, Equatable {
    public let processScope = "cli_process; power describes this machine"
    public let process: CLIInspectProcessOutput
    public let pipeline: CLIStatusPipeline
    public let isCapturing: Bool?
    public let database: CLIInspectDatabaseOutput
    public let capture: CLIInspectCaptureOutput?
    public let processing: CLIInspectProcessingOutput?
    public let search: CLIInspectSearchStatisticsOutput?
    public let runtimeStatus = "unavailable: live app queue and encoding state are not queried"
    public let queue: CLIInspectQueueStatisticsOutput?
    public let encoding: CLIInspectEncodingOutput?
    public let power: CLIInspectPowerOutput
    public let memory: CLIInspectMemoryOutput

    public init(
        process: CLIInspectProcessOutput,
        pipeline: CLIStatusPipeline,
        isCapturing: Bool?,
        database: CLIInspectDatabaseOutput,
        capture: CLIInspectCaptureOutput?,
        processing: CLIInspectProcessingOutput?,
        search: CLIInspectSearchStatisticsOutput?,
        queue: CLIInspectQueueStatisticsOutput?,
        encoding: CLIInspectEncodingOutput?,
        power: CLIInspectPowerOutput,
        memory: CLIInspectMemoryOutput
    ) {
        self.process = process
        self.pipeline = pipeline
        self.isCapturing = isCapturing
        self.database = database
        self.capture = capture
        self.processing = processing
        self.search = search
        self.queue = queue
        self.encoding = encoding
        self.power = power
        self.memory = memory
    }
}

public struct CLIInspectOCROutput: Codable, Sendable, Equatable {
    public let runtimeStatus = "unavailable: live app queue and encoding state are not queried"
    public let queue: CLIInspectQueueStatisticsOutput?
    public let encoding: CLIInspectEncodingOutput?
    public let power: CLIInspectPowerOutput
    public let framesProcessedPerMinute: [CLIInspectMinuteCountOutput]
    public let framesEncodedPerMinute: [CLIInspectMinuteCountOutput]
    public let framesRewrittenPerMinute: [CLIInspectMinuteCountOutput]

    public init(
        queue: CLIInspectQueueStatisticsOutput?,
        encoding: CLIInspectEncodingOutput?,
        power: CLIInspectPowerOutput,
        framesProcessedPerMinute: [CLIInspectMinuteCountOutput],
        framesEncodedPerMinute: [CLIInspectMinuteCountOutput],
        framesRewrittenPerMinute: [CLIInspectMinuteCountOutput]
    ) {
        self.queue = queue
        self.encoding = encoding
        self.power = power
        self.framesProcessedPerMinute = framesProcessedPerMinute
        self.framesEncodedPerMinute = framesEncodedPerMinute
        self.framesRewrittenPerMinute = framesRewrittenPerMinute
    }
}

public struct CLIInspectQueueOutput: Codable, Sendable, Equatable {
    public let runtimeStatus = "unavailable: live app queue and encoding state are not queried"
    public let queue: CLIInspectQueueStatisticsOutput?
    public let encoding: CLIInspectEncodingOutput?
    public let power: CLIInspectPowerOutput

    public init(
        queue: CLIInspectQueueStatisticsOutput?,
        encoding: CLIInspectEncodingOutput?,
        power: CLIInspectPowerOutput
    ) {
        self.queue = queue
        self.encoding = encoding
        self.power = power
    }
}

public struct CLIInspectStorageOutput: Codable, Sendable, Equatable {
    public let storage: CLIStatusStorage
    public let rewind: CLIStatusRewind
    public let statistics: CLIStatusStatistics
    public let database: CLIInspectDatabaseOutput

    public init(
        storage: CLIStatusStorage,
        rewind: CLIStatusRewind,
        statistics: CLIStatusStatistics,
        database: CLIInspectDatabaseOutput
    ) {
        self.storage = storage
        self.rewind = rewind
        self.statistics = statistics
        self.database = database
    }
}

public struct CLIInspectMetricsOutput: Codable, Sendable, Equatable {
    public let recentLimit: Int
    public let returnedCount: Int
    public let events: [FeedbackRecentMetricEvent]

    public init(recentLimit: Int, returnedCount: Int, events: [FeedbackRecentMetricEvent]) {
        self.recentLimit = recentLimit
        self.returnedCount = returnedCount
        self.events = events
    }
}

public struct CLIInspectOCRStatusOutput: Codable, Sendable, Equatable {
    public let state: String
    public let displayText: String
    public let queuePosition: Int?
    public let queueDepth: Int?
    public let isInProgress: Bool

    public init(
        state: String,
        displayText: String,
        queuePosition: Int?,
        queueDepth: Int?,
        isInProgress: Bool
    ) {
        self.state = state
        self.displayText = displayText
        self.queuePosition = queuePosition
        self.queueDepth = queueDepth
        self.isInProgress = isInProgress
    }
}

public struct CLIInspectFrameOutput: Codable, Sendable, Equatable {
    public let target: CLIExtractTargetOutput
    public let processingStatusCode: Int
    public let ocrStatus: CLIInspectOCRStatusOutput
    public let videoInfo: FrameVideoInfo?
    public let nodeCount: Int
    public let linkCount: Int
    public let inPageURLState: CLIExtractLinkStateOutput?

    public init(
        target: CLIExtractTargetOutput,
        processingStatusCode: Int,
        ocrStatus: CLIInspectOCRStatusOutput,
        videoInfo: FrameVideoInfo?,
        nodeCount: Int,
        linkCount: Int,
        inPageURLState: CLIExtractLinkStateOutput?
    ) {
        self.target = target
        self.processingStatusCode = processingStatusCode
        self.ocrStatus = ocrStatus
        self.videoInfo = videoInfo
        self.nodeCount = nodeCount
        self.linkCount = linkCount
        self.inPageURLState = inPageURLState
    }
}

public struct CLIUsageTimeWindowOutput: Codable, Sendable, Equatable {
    public let requestedFrom: String
    public let requestedTo: String
    public let resolvedFrom: Date
    public let resolvedTo: Date

    public init(
        requestedFrom: String,
        requestedTo: String,
        resolvedFrom: Date,
        resolvedTo: Date
    ) {
        self.requestedFrom = requestedFrom
        self.requestedTo = requestedTo
        self.resolvedFrom = resolvedFrom
        self.resolvedTo = resolvedTo
    }
}

public struct CLIUsageAppRowOutput: Codable, Sendable, Equatable {
    public let bundleID: String
    public let isBrowser: Bool
    public let durationSeconds: Double
    public let uniqueItemCount: Int

    public init(bundleID: String, isBrowser: Bool, durationSeconds: Double, uniqueItemCount: Int) {
        self.bundleID = bundleID
        self.isBrowser = isBrowser
        self.durationSeconds = durationSeconds
        self.uniqueItemCount = uniqueItemCount
    }
}

public struct CLIUsageAppsOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let limit: Int
    public let returnedCount: Int
    public let totalDurationSeconds: Double
    public let results: [CLIUsageAppRowOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        limit: Int,
        returnedCount: Int,
        totalDurationSeconds: Double,
        results: [CLIUsageAppRowOutput]
    ) {
        self.timeWindow = timeWindow
        self.limit = limit
        self.returnedCount = returnedCount
        self.totalDurationSeconds = totalDurationSeconds
        self.results = results
    }
}

public struct CLIUsageWebsiteRowOutput: Codable, Sendable, Equatable {
    public let website: String
    public let durationSeconds: Double
    public let tabCount: Int?

    public init(website: String, durationSeconds: Double, tabCount: Int?) {
        self.website = website
        self.durationSeconds = durationSeconds
        self.tabCount = tabCount
    }
}

public struct CLIUsageWebsitesOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let appBundleID: String
    public let limit: Int
    public let returnedCount: Int
    public let totalMatchedCount: Int
    public let totalDurationSeconds: Double
    public let results: [CLIUsageWebsiteRowOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        appBundleID: String,
        limit: Int,
        returnedCount: Int,
        totalMatchedCount: Int,
        totalDurationSeconds: Double,
        results: [CLIUsageWebsiteRowOutput]
    ) {
        self.timeWindow = timeWindow
        self.appBundleID = appBundleID
        self.limit = limit
        self.returnedCount = returnedCount
        self.totalMatchedCount = totalMatchedCount
        self.totalDurationSeconds = totalDurationSeconds
        self.results = results
    }
}

public struct CLIUsageTabRowOutput: Codable, Sendable, Equatable {
    public let itemKind: String
    public let title: String?
    public let browserURL: String?
    public let durationSeconds: Double

    public init(itemKind: String, title: String?, browserURL: String?, durationSeconds: Double) {
        self.itemKind = itemKind
        self.title = title
        self.browserURL = browserURL
        self.durationSeconds = durationSeconds
    }
}

public struct CLIUsageTabsOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let appBundleID: String
    public let website: String?
    public let limit: Int
    public let returnedCount: Int
    public let totalMatchedCount: Int
    public let totalDurationSeconds: Double
    public let results: [CLIUsageTabRowOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        appBundleID: String,
        website: String?,
        limit: Int,
        returnedCount: Int,
        totalMatchedCount: Int,
        totalDurationSeconds: Double,
        results: [CLIUsageTabRowOutput]
    ) {
        self.timeWindow = timeWindow
        self.appBundleID = appBundleID
        self.website = website
        self.limit = limit
        self.returnedCount = returnedCount
        self.totalMatchedCount = totalMatchedCount
        self.totalDurationSeconds = totalDurationSeconds
        self.results = results
    }
}

public struct CLIUsageSessionFiltersOutput: Codable, Sendable, Equatable {
    public let appBundleID: String?
    public let window: String?
    public let website: String?
    public let hiddenFilter: String

    public init(appBundleID: String?, window: String?, website: String?, hiddenFilter: String) {
        self.appBundleID = appBundleID
        self.window = window
        self.website = website
        self.hiddenFilter = hiddenFilter
    }
}

public struct CLIUsageSessionRowOutput: Codable, Sendable, Equatable {
    public let segmentID: Int64
    public let bundleID: String
    public let isBrowser: Bool
    public let segmentStart: Date
    public let segmentEnd: Date
    public let effectiveStart: Date
    public let effectiveEnd: Date
    public let segmentDurationSeconds: Double
    public let effectiveDurationSeconds: Double
    public let windowName: String?
    public let browserURL: String?
    public let website: String?
    public let isHidden: Bool
    public let type: Int

    public init(
        segmentID: Int64,
        bundleID: String,
        isBrowser: Bool,
        segmentStart: Date,
        segmentEnd: Date,
        effectiveStart: Date,
        effectiveEnd: Date,
        segmentDurationSeconds: Double,
        effectiveDurationSeconds: Double,
        windowName: String?,
        browserURL: String?,
        website: String?,
        isHidden: Bool,
        type: Int
    ) {
        self.segmentID = segmentID
        self.bundleID = bundleID
        self.isBrowser = isBrowser
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.effectiveStart = effectiveStart
        self.effectiveEnd = effectiveEnd
        self.segmentDurationSeconds = segmentDurationSeconds
        self.effectiveDurationSeconds = effectiveDurationSeconds
        self.windowName = windowName
        self.browserURL = browserURL
        self.website = website
        self.isHidden = isHidden
        self.type = type
    }
}

public struct CLIUsageSessionsOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let filters: CLIUsageSessionFiltersOutput
    public let limit: Int
    public let offset: Int
    public let totalMatchedCount: Int
    public let returnedCount: Int
    public let results: [CLIUsageSessionRowOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        filters: CLIUsageSessionFiltersOutput,
        limit: Int,
        offset: Int,
        totalMatchedCount: Int,
        returnedCount: Int,
        results: [CLIUsageSessionRowOutput]
    ) {
        self.timeWindow = timeWindow
        self.filters = filters
        self.limit = limit
        self.offset = offset
        self.totalMatchedCount = totalMatchedCount
        self.returnedCount = returnedCount
        self.results = results
    }
}

public struct CLIUsageScreenTimeRowOutput: Codable, Sendable, Equatable {
    public let date: Date
    public let durationMilliseconds: Int64
    public let durationSeconds: Double

    public init(date: Date, durationMilliseconds: Int64, durationSeconds: Double) {
        self.date = date
        self.durationMilliseconds = durationMilliseconds
        self.durationSeconds = durationSeconds
    }
}

public struct CLIUsageScreenTimeOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let totalDurationMilliseconds: Int64
    public let totalDurationSeconds: Double
    public let daily: [CLIUsageScreenTimeRowOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        totalDurationMilliseconds: Int64,
        totalDurationSeconds: Double,
        daily: [CLIUsageScreenTimeRowOutput]
    ) {
        self.timeWindow = timeWindow
        self.totalDurationMilliseconds = totalDurationMilliseconds
        self.totalDurationSeconds = totalDurationSeconds
        self.daily = daily
    }
}

public struct CLIUsageSwitchTransitionOutput: Codable, Sendable, Equatable {
    public let occurredAt: Date
    public let fromSegmentID: Int64
    public let toSegmentID: Int64
    public let fromBundleID: String
    public let toBundleID: String
    public let fromWindowName: String?
    public let toWindowName: String?
    public let fromWebsite: String?
    public let toWebsite: String?

    public init(
        occurredAt: Date,
        fromSegmentID: Int64,
        toSegmentID: Int64,
        fromBundleID: String,
        toBundleID: String,
        fromWindowName: String?,
        toWindowName: String?,
        fromWebsite: String?,
        toWebsite: String?
    ) {
        self.occurredAt = occurredAt
        self.fromSegmentID = fromSegmentID
        self.toSegmentID = toSegmentID
        self.fromBundleID = fromBundleID
        self.toBundleID = toBundleID
        self.fromWindowName = fromWindowName
        self.toWindowName = toWindowName
        self.fromWebsite = fromWebsite
        self.toWebsite = toWebsite
    }
}

public struct CLIUsageSwitchesOutput: Codable, Sendable, Equatable {
    public let timeWindow: CLIUsageTimeWindowOutput
    public let appBundleID: String?
    public let hiddenFilter: String
    public let limit: Int
    public let totalSwitchCount: Int
    public let returnedTransitionCount: Int
    public let transitions: [CLIUsageSwitchTransitionOutput]

    public init(
        timeWindow: CLIUsageTimeWindowOutput,
        appBundleID: String?,
        hiddenFilter: String,
        limit: Int,
        totalSwitchCount: Int,
        returnedTransitionCount: Int,
        transitions: [CLIUsageSwitchTransitionOutput]
    ) {
        self.timeWindow = timeWindow
        self.appBundleID = appBundleID
        self.hiddenFilter = hiddenFilter
        self.limit = limit
        self.totalSwitchCount = totalSwitchCount
        self.returnedTransitionCount = returnedTransitionCount
        self.transitions = transitions
    }
}

public struct CLISearchQueryOutput: Codable, Sendable, Equatable {
    public let text: String
    public let exact: Bool
    public let limit: Int
    public let sort: CLISearchSort
    public let filters: CLISearchFiltersOutput

    public init(
        text: String,
        exact: Bool,
        limit: Int,
        sort: CLISearchSort,
        filters: CLISearchFiltersOutput
    ) {
        self.text = text
        self.exact = exact
        self.limit = limit
        self.sort = sort
        self.filters = filters
    }
}

public struct CLISearchFiltersOutput: Codable, Sendable, Equatable {
    public let appBundleIDs: [String]
    public let excludedAppBundleIDs: [String]
    public let dateRanges: [CLIDateRangeOutput]
    public let urlTerms: [String]
    public let excludedURLTerms: [String]
    public let windowTerms: [String]
    public let excludedWindowTerms: [String]
    public let tagNames: [String]
    public let excludedTagNames: [String]
    public let commentFilter: String
    public let hiddenFilter: String

    public init(
        appBundleIDs: [String],
        excludedAppBundleIDs: [String],
        dateRanges: [CLIDateRangeOutput],
        urlTerms: [String],
        excludedURLTerms: [String],
        windowTerms: [String],
        excludedWindowTerms: [String],
        tagNames: [String],
        excludedTagNames: [String],
        commentFilter: String,
        hiddenFilter: String
    ) {
        self.appBundleIDs = appBundleIDs
        self.excludedAppBundleIDs = excludedAppBundleIDs
        self.dateRanges = dateRanges
        self.urlTerms = urlTerms
        self.excludedURLTerms = excludedURLTerms
        self.windowTerms = windowTerms
        self.excludedWindowTerms = excludedWindowTerms
        self.tagNames = tagNames
        self.excludedTagNames = excludedTagNames
        self.commentFilter = commentFilter
        self.hiddenFilter = hiddenFilter
    }
}

public struct CLIDateRangeOutput: Codable, Sendable, Equatable {
    public let start: Date?
    public let end: Date?

    public init(start: Date?, end: Date?) {
        self.start = start
        self.end = end
    }
}

public struct CLISearchResultOutput: Codable, Sendable, Equatable {
    public let resultID: Int
    public let frameID: Int64
    public let timestamp: Date
    public let appBundleID: String?
    public let appName: String?
    public let windowName: String?
    public let browserURL: String?
    public let snippet: String
    public let matchedText: String
    public let relevanceScore: Double
    public let segmentID: Int64
    public let videoID: Int64
    public let frameIndex: Int
    public let source: FrameSource

    public init(
        resultID: Int,
        frameID: Int64,
        timestamp: Date,
        appBundleID: String?,
        appName: String?,
        windowName: String?,
        browserURL: String?,
        snippet: String,
        matchedText: String,
        relevanceScore: Double,
        segmentID: Int64,
        videoID: Int64,
        frameIndex: Int,
        source: FrameSource
    ) {
        self.resultID = resultID
        self.frameID = frameID
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowName = windowName
        self.browserURL = browserURL
        self.snippet = snippet
        self.matchedText = matchedText
        self.relevanceScore = relevanceScore
        self.segmentID = segmentID
        self.videoID = videoID
        self.frameIndex = frameIndex
        self.source = source
    }
}
