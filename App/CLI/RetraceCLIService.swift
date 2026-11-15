import Database
import Foundation
import AppKit
import Processing
import Shared

private let retraceCLISettingsSuiteName = "io.retrace.app"

private enum CLIConfigStoredValueType: String {
    case bool
    case int
    case double
    case string
    case date
}

private struct CLIConfigDescriptor {
    let key: String
    let defaultsKey: String
    let aliases: [String]
    let category: String
    let valueType: CLIConfigStoredValueType
    let nullable: Bool
    let allowedStringValues: [String]?
    let defaultValue: @Sendable () -> CLIConfigValue
    let note: String?
    let minimumInt: Int?
    let maximumInt: Int?
    let minimumDouble: Double?
    let maximumDouble: Double?

    init(
        key: String,
        defaultsKey: String,
        aliases: [String] = [],
        category: String,
        valueType: CLIConfigStoredValueType,
        nullable: Bool = false,
        allowedStringValues: [String]? = nil,
        defaultValue: @escaping @Sendable () -> CLIConfigValue,
        note: String? = nil,
        minimumInt: Int? = nil,
        maximumInt: Int? = nil,
        minimumDouble: Double? = nil,
        maximumDouble: Double? = nil
    ) {
        self.key = key
        self.defaultsKey = defaultsKey
        self.aliases = aliases
        self.category = category
        self.valueType = valueType
        self.nullable = nullable
        self.allowedStringValues = allowedStringValues
        self.defaultValue = defaultValue
        self.note = note
        self.minimumInt = minimumInt
        self.maximumInt = maximumInt
        self.minimumDouble = minimumDouble
        self.maximumDouble = maximumDouble
    }

    var allAliases: [String] {
        var values = [defaultsKey]
        values.append(contentsOf: aliases)
        return values
    }

    func matchesLookupKey(_ rawValue: String) -> Bool {
        let normalizedValue = Self.normalizedKey(rawValue)
        if Self.normalizedKey(key) == normalizedValue {
            return true
        }

        return allAliases.contains { Self.normalizedKey($0) == normalizedValue }
    }

    func currentValue(in defaults: UserDefaults) -> CLIConfigValue {
        guard let object = defaults.object(forKey: defaultsKey) else {
            return defaultValue()
        }

        switch valueType {
        case .bool:
            if let value = object as? Bool {
                return .bool(value)
            }
            if let number = object as? NSNumber {
                return .bool(number.boolValue)
            }
            return defaultValue()
        case .int:
            if let value = object as? Int {
                return .int(value)
            }
            if let number = object as? NSNumber {
                return .int(number.intValue)
            }
            return defaultValue()
        case .double:
            if let value = object as? Double {
                return .double(value)
            }
            if let number = object as? NSNumber {
                return .double(number.doubleValue)
            }
            return defaultValue()
        case .string:
            if let value = object as? String {
                return .string(value)
            }
            return nullable ? .null : defaultValue()
        case .date:
            if let value = object as? Date {
                return .date(value)
            }
            if let number = object as? NSNumber {
                return .date(Date(timeIntervalSince1970: number.doubleValue))
            }
            return nullable ? .null : defaultValue()
        }
    }

    static func normalizedKey(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public actor RetraceCLIService {
    private var storedCoordinator: AppCoordinator?
    private let coordinatorFactory: @Sendable () throws -> AppCoordinator
    private var coordinator: AppCoordinator {
        guard let storedCoordinator else { preconditionFailure("CLI services have not been initialized") }
        return storedCoordinator
    }
    private let resultStore: CLIResultStore
    private let defaults: UserDefaults
    private let timeParser: CLITimeParser
    private let imageExportHost: any CLIImageExportHosting
    private var isInitialized = false

    private static let encodedMetadataFilterPrefix = "__retrace_meta_filter_v1__"

    private struct EncodedMetadataFilterPayload: Codable {
        let includeTerms: [String]?
        let excludeTerms: [String]?
        let mode: AppFilterMode?
        let terms: [String]?
    }

    private struct ResolvedCLIFrameSelection {
        let requestedAt: String?
        let requestedFrameID: Int64?
        let requestedResultID: Int?
        let frame: FrameReference
        let frameWithVideoInfo: FrameWithVideoInfo?
    }

    init(
        coordinator: AppCoordinator? = nil,
        resultStore: CLIResultStore = CLIResultStore(),
        defaults: UserDefaults = UserDefaults(suiteName: retraceCLISettingsSuiteName) ?? .standard,
        timeParser: CLITimeParser = CLITimeParser(),
        imageExportHost: any CLIImageExportHosting = AppHostedCLIImageExportHost(),
        coordinatorFactory: @escaping @Sendable () throws -> AppCoordinator = { AppCoordinator() }
    ) {
        self.storedCoordinator = coordinator
        self.coordinatorFactory = coordinatorFactory
        self.resultStore = resultStore
        self.defaults = defaults
        self.timeParser = timeParser
        self.imageExportHost = imageExportHost
    }

    public func shutdown() async {
        guard isInitialized else { return }
        try? await coordinator.shutdown()
        isInitialized = false
    }

    public func status() async throws -> CLIStatusOutput {
        try await ensureInitialized()

        let latestFrameTimestamp = try await coordinator.getMostRecentFrameTimestamp()
        let quickStats = try await coordinator.getDatabaseStatisticsQuick()
        let totalCapturedDuration = try await coordinator.getTotalCapturedDuration()
        let distinctAppBundleIDs = try await coordinator.getDistinctAppBundleIDs()

        let storageRoot = AppPaths.expandedStorageRoot
        let databasePath = NSString(string: AppPaths.databasePath).expandingTildeInPath
        let rewindStorageRoot = AppPaths.expandedRewindStorageRoot
        let rewindDatabasePath = NSString(string: AppPaths.rewindDBPath).expandingTildeInPath
        let fileManager = FileManager.default
        let rewindEnabled = defaults.bool(forKey: "useRewindData")

        try? await recordCLICommandMetric(
            command: "status",
            payload: [
                "source": "cli"
            ]
        )

        return CLIStatusOutput(
            pipeline: CLIStatusPipeline(
                isRunning: nil,
                framesProcessed: nil,
                errorCount: nil,
                startTime: nil,
                latestFrameTimestamp: latestFrameTimestamp
            ),
            storage: CLIStatusStorage(
                storageRoot: storageRoot,
                storageRootExists: fileManager.fileExists(atPath: storageRoot),
                databasePath: databasePath,
                databaseExists: fileManager.fileExists(atPath: databasePath)
            ),
            rewind: CLIStatusRewind(
                enabled: rewindEnabled,
                storageRoot: rewindStorageRoot,
                storageRootExists: fileManager.fileExists(atPath: rewindStorageRoot),
                databasePath: rewindDatabasePath,
                databaseExists: fileManager.fileExists(atPath: rewindDatabasePath)
            ),
            statistics: CLIStatusStatistics(
                frameCount: quickStats.frameCount,
                sessionCount: quickStats.sessionCount,
                distinctAppCount: distinctAppBundleIDs.count,
                totalCapturedDurationSeconds: totalCapturedDuration
            )
        )
    }

    public func appsList(_ request: CLIAppsListRequest = CLIAppsListRequest()) async throws -> CLIAppsListOutput {
        _ = request
        try await ensureInitialized()

        let bundleIDs = try await coordinator.getDistinctAppBundleIDs().sorted()
        let entries = bundleIDs.map { bundleID in
            CLIAppsListEntryOutput(
                bundleID: bundleID,
                appName: resolvedAppDisplayName(for: bundleID),
                bundleSuffix: bundleIDSuffixComponent(bundleID),
                installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            )
        }

        try? await recordCLICommandMetric(
            command: "apps_list",
            payload: [
                "source": "cli",
                "count": entries.count
            ]
        )

        return CLIAppsListOutput(count: entries.count, apps: entries)
    }

    public func search(_ request: CLISearchRequest) async throws -> CLISearchOutput {
        try await ensureInitialized()

        let availableBundleIDs = try await coordinator.getDistinctAppBundleIDs()
        let resolvedIncludeApps = try resolveApps(request.includeApps, availableBundleIDs: availableBundleIDs)
        let resolvedExcludeApps = try resolveApps(request.excludeApps, availableBundleIDs: availableBundleIDs)

        let allTags = try await coordinator.getAllTags()
        let resolvedIncludeTagIDs = try resolveTagIDs(request.includeTagNames, tags: allTags)
        let resolvedExcludeTagIDs = try resolveTagIDs(request.excludeTagNames, tags: allTags)

        let sortConfiguration = mapSort(request.sort)
        let queryText = normalizedSearchText(request.queryText, exact: request.exact)
        let filters = SearchFilters(
            dateRanges: request.ranges,
            appBundleIDs: resolvedIncludeApps.isEmpty ? nil : resolvedIncludeApps,
            excludedAppBundleIDs: resolvedExcludeApps.isEmpty ? nil : resolvedExcludeApps,
            selectedTagIds: resolvedIncludeTagIDs.isEmpty ? nil : resolvedIncludeTagIDs,
            excludedTagIds: resolvedExcludeTagIDs.isEmpty ? nil : resolvedExcludeTagIDs,
            hiddenFilter: request.hiddenFilter,
            commentFilter: request.commentFilter,
            windowNameFilter: Self.encodedMetadataFilter(
                includeTerms: request.includeWindowTerms,
                excludeTerms: request.excludeWindowTerms
            ),
            browserUrlFilter: Self.encodedMetadataFilter(
                includeTerms: request.includeURLTerms,
                excludeTerms: request.excludeURLTerms
            )
        )

        let searchQuery = SearchQuery(
            text: queryText,
            filters: filters,
            limit: request.limit,
            offset: 0,
            mode: sortConfiguration.mode,
            sortOrder: sortConfiguration.sortOrder
        )

        let searchResults = try await coordinator.search(query: searchQuery)

        try? await coordinator.recordMetricEvent(
            metricType: .searches,
            metadata: nil
        )

        if request.filterCount > 0,
           let metadata = try? Self.jsonString(
            FilteredSearchMetricMetadata(
                queryLength: request.queryText.count,
                filterCount: request.filterCount
            )
           ) {
            try? await coordinator.recordMetricEvent(
                metricType: .filteredSearchQuery,
                metadata: metadata
            )
        }

        try? await recordCLICommandMetric(
            command: "search",
            payload: [
                "source": "cli",
                "resultCount": searchResults.results.count,
                "hasFilters": request.filterCount > 0
            ]
        )

        let normalizedResults = Self.normalizedSearchResults(
            searchResults.results,
            limit: request.limit
        )
        let storedResultsAvailable: Bool
        do {
            try resultStore.saveLatestSearchResults(
                queryText: request.queryText,
                results: normalizedResults
            )
            storedResultsAvailable = true
        } catch {
            storedResultsAvailable = false
        }

        return CLISearchOutput(
            query: CLISearchQueryOutput(
                text: request.queryText,
                exact: request.exact,
                limit: request.limit,
                sort: request.sort,
                filters: CLISearchFiltersOutput(
                    appBundleIDs: resolvedIncludeApps,
                    excludedAppBundleIDs: resolvedExcludeApps,
                    dateRanges: request.ranges.map { CLIDateRangeOutput(start: $0.start, end: $0.end) },
                    urlTerms: request.includeURLTerms,
                    excludedURLTerms: request.excludeURLTerms,
                    windowTerms: request.includeWindowTerms,
                    excludedWindowTerms: request.excludeWindowTerms,
                    tagNames: request.includeTagNames,
                    excludedTagNames: request.excludeTagNames,
                    commentFilter: request.commentFilter.rawValue,
                    hiddenFilter: request.hiddenFilter.rawValue
                )
            ),
            resultCount: normalizedResults.count,
            searchTimeMs: searchResults.searchTimeMs,
            storedResultsAvailable: storedResultsAvailable,
            nextCursor: searchResults.nextCursor,
            results: normalizedResults
        )
    }

    public func jump(_ request: CLIJumpRequest) async throws -> CLIJumpOutput {
        try await ensureInitialized()

        let nearestMatch = try await nearestFrame(to: request.target.date)
        guard let matchedFrame = nearestMatch.matched else {
            throw CLIError.noFramesAvailable(request.target.rawValue)
        }

        async let previousNeighborTask = coordinator.getFramesBefore(
            timestamp: matchedFrame.timestamp,
            limit: 1
        )
        async let nextNeighborTask = coordinator.getFramesAfter(
            timestamp: matchedFrame.timestamp,
            limit: 1
        )
        let previousNeighbor = try await previousNeighborTask.first
        let nextNeighbor = try await nextNeighborTask.first

        try? await recordCLICommandMetric(
            command: "jump",
            payload: [
                "source": "cli",
                "requestedAt": request.target.rawValue
            ]
        )

        return CLIJumpOutput(
            requestedAt: request.target.rawValue,
            resolvedAt: request.target.date,
            matchedFrame: frameOutput(from: matchedFrame),
            deltaSeconds: matchedFrame.timestamp.timeIntervalSince(request.target.date),
            previousFrame: previousNeighbor.map(frameOutput(from:)),
            nextFrame: nextNeighbor.map(frameOutput(from:))
        )
    }

    public func around(_ request: CLIAroundRequest) async throws -> CLIAroundOutput {
        try await ensureInitialized()

        let anchorResult: (frame: FrameReference, requestedAt: String?, requestedFrameID: Int64?)
        switch request.anchor {
        case .at(let timeReference):
            let nearestMatch = try await nearestFrame(to: timeReference.date)
            guard let matchedFrame = nearestMatch.matched else {
                throw CLIError.noFramesAvailable(timeReference.rawValue)
            }
            anchorResult = (frame: matchedFrame, requestedAt: timeReference.rawValue, requestedFrameID: nil)
        case .frameID(let frameID):
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                throw CLIError.frameNotFound(String(frameID))
            }
            anchorResult = (frame: frameWithVideoInfo.frame, requestedAt: nil, requestedFrameID: frameID)
        case .resultID(let resultID):
            let storedResult = try resultStore.resolveLatestSearchResult(id: resultID)
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: storedResult.frameID)) else {
                throw CLIError.frameNotFound(String(storedResult.frameID))
            }
            anchorResult = (frame: frameWithVideoInfo.frame, requestedAt: nil, requestedFrameID: storedResult.frameID)
        }

        async let olderFramesTask = coordinator.getFramesBefore(
            timestamp: anchorResult.frame.timestamp,
            limit: request.beforeCount
        )
        async let newerFramesTask = coordinator.getFramesAfter(
            timestamp: anchorResult.frame.timestamp,
            limit: request.afterCount
        )

        let olderFrames = try await olderFramesTask
        let newerFrames = try await newerFramesTask

        let frames: [CLIAroundFrameOutput] =
            olderFrames.reversed().map { CLIAroundFrameOutput(position: "before", frame: frameOutput(from: $0)) } +
            [CLIAroundFrameOutput(position: "anchor", frame: frameOutput(from: anchorResult.frame))] +
            newerFrames.map { CLIAroundFrameOutput(position: "after", frame: frameOutput(from: $0)) }

        try? await recordCLICommandMetric(
            command: "around",
            payload: [
                "source": "cli",
                "beforeCount": request.beforeCount,
                "afterCount": request.afterCount
            ]
        )

        return CLIAroundOutput(
            anchor: CLIAroundAnchorOutput(
                requestedAt: anchorResult.requestedAt,
                requestedFrameID: anchorResult.requestedFrameID,
                matchedFrame: frameOutput(from: anchorResult.frame)
            ),
            beforeCount: olderFrames.count,
            afterCount: newerFrames.count,
            frames: frames
        )
    }

    public func open(_ request: CLIOpenRequest) async throws -> CLIOpenOutput {
        try await ensureInitialized()

        let url: URL
        let route: String
        let timelineState: CLIDeeplinkTimelineState?
        let searchState: CLIDeeplinkSearchState?
        switch request.selector {
        case .timeline(let timeReference):
            let state = CLIDeeplinkTimelineState(timestamp: timeReference.date)
            guard let timelineURL = CLIDeeplinkBuilder.timelineURL(state: state) else {
                throw CLIError.openFailed(timeReference.rawValue)
            }
            url = timelineURL
            route = "timeline"
            timelineState = state
            searchState = nil
        case .frameID(let frameID):
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                throw CLIError.frameNotFound(String(frameID))
            }
            let state = CLIDeeplinkTimelineState(timestamp: frameWithVideoInfo.frame.timestamp, frameID: frameID)
            guard let timelineURL = CLIDeeplinkBuilder.timelineURL(state: state) else {
                throw CLIError.openFailed(String(frameID))
            }
            url = timelineURL
            route = "timeline"
            timelineState = state
            searchState = nil
        case .resultID(let resultID):
            let storedResult = try resultStore.resolveLatestSearchResult(id: resultID)
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: storedResult.frameID)) else {
                throw CLIError.frameNotFound(String(storedResult.frameID))
            }
            let state = CLIDeeplinkTimelineState(
                timestamp: frameWithVideoInfo.frame.timestamp,
                frameID: storedResult.frameID
            )
            guard let timelineURL = CLIDeeplinkBuilder.timelineURL(state: state) else {
                throw CLIError.openFailed(String(storedResult.frameID))
            }
            url = timelineURL
            route = "timeline"
            timelineState = state
            searchState = nil
        case .search(let searchRequest):
            let state = try await searchDeeplinkState(from: searchRequest)
            guard let searchURL = CLIDeeplinkBuilder.searchURL(state: state) else {
                throw CLIError.openFailed(searchRequest.queryText)
            }
            url = searchURL
            route = "search"
            timelineState = nil
            searchState = state
        }

        guard CLIDeeplinkBuilder.open(url) else {
            throw CLIError.openFailed(url.absoluteString)
        }

        try? await recordCLICommandMetric(
            command: "open",
            payload: [
                "source": "cli",
                "url": url.absoluteString
            ]
        )

        return CLIOpenOutput(
            url: url.absoluteString,
            opened: true,
            route: route,
            timeline: timelineState,
            search: searchState
        )
    }

    public func help(_ request: CLIHelpRequest) async throws -> CLIHelpOutput {
        let topic = request.topicPath
        try? await recordCLICommandMetric(
            command: "help",
            payload: [
                "source": "cli",
                "topic": topic.joined(separator: " ")
            ]
        )

        switch topic {
        case []:
            return CLIHelpOutput(
                topicPath: [],
                summary: "First-party Retrace CLI for search, navigation, extraction, analytics, operations, and GUI handoff.",
                usage: "retrace <command> [options]",
                notes: [
                    "All commands emit JSON.",
                    "Use `retrace <command> --help` or `retrace help <command>` for command-specific details."
                ],
                subcommands: [
                    CLIHelpSubcommandOutput(name: "status", summary: "Show database and storage status; live app state is unavailable."),
                    CLIHelpSubcommandOutput(name: "apps", summary: "List known app bundle IDs for filter discovery."),
                    CLIHelpSubcommandOutput(name: "search", summary: "Search past content and metadata."),
                    CLIHelpSubcommandOutput(name: "jump", summary: "Resolve a time and return the nearest frame."),
                    CLIHelpSubcommandOutput(name: "around", summary: "Return frames around a frame, time, or stored result."),
                    CLIHelpSubcommandOutput(name: "open", summary: "Open Retrace with a timeline or search deeplink."),
                    CLIHelpSubcommandOutput(name: "usage", summary: "Summarize apps, websites, tabs, sessions, and switches."),
                    CLIHelpSubcommandOutput(name: "extract", summary: "Recover text, URLs, OCR, links, or frame images."),
                    CLIHelpSubcommandOutput(name: "inspect", summary: "Inspect OCR, queue, storage, metrics, and frame metadata."),
                    CLIHelpSubcommandOutput(name: "config", summary: "View or modify curated Retrace settings."),
                    CLIHelpSubcommandOutput(name: "completions", summary: "Generate shell completion scripts.")
                ],
                examples: [
                    "retrace search \"taxact onboarding\" --url taxact.com --window onboarding",
                    "retrace open --query \"cca\" --range 2025-04-01..2025-04-30 --window UFile",
                    "retrace apps list",
                    "retrace completions zsh"
                ]
            )
        case ["search"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Content-first retrieval across OCR, titles, URLs, comments, and tags.",
                usage: "retrace search <query...> [filters]",
                options: searchOptionHelp(includeLimit: true),
                examples: [
                    "retrace search \"form 5472\" --range 2024-01-01..2024-12-31",
                    "retrace search 'verification code' --url openai.com --window login"
                ]
            )
        case ["jump"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Resolve a time expression and return the nearest frame plus neighbors.",
                usage: "retrace jump --at <time>",
                options: [
                    CLIHelpOptionOutput(flag: "--at", valueName: "time", description: "Natural-language or exact time to resolve.")
                ],
                examples: [
                    "retrace jump --at \"20 minutes ago\"",
                    "retrace jump --at \"last tuesday 3pm\""
                ]
            )
        case ["around"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Return surrounding frames for a time, frame ID, or stored result.",
                usage: "retrace around (--at <time> | --frame <id> | --result <n>) [--before <n>] [--after <n>]",
                options: [
                    CLIHelpOptionOutput(flag: "--at", valueName: "time", description: "Anchor around a time expression."),
                    CLIHelpOptionOutput(flag: "--frame", valueName: "id", description: "Anchor around a frame ID."),
                    CLIHelpOptionOutput(flag: "--result", valueName: "n", description: "Anchor around a stored result ID."),
                    CLIHelpOptionOutput(flag: "--before", valueName: "n", description: "How many frames to return before the anchor."),
                    CLIHelpOptionOutput(flag: "--after", valueName: "n", description: "How many frames to return after the anchor.")
                ],
                examples: [
                    "retrace around --result 1 --before 5 --after 5",
                    "retrace around --frame 123456 --before 3 --after 10"
                ]
            )
        case ["open"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Explicit GUI handoff into Retrace timeline or search.",
                usage: "retrace open (--frame <id> | --result <n> | --at <time> | --query <text> [filters])",
                notes: [
                    "`open --query` supports the same search filters as `search`, except it does not accept `--limit`.",
                    "`open --frame` and `open --result` preserve the resolved frame ID in the deeplink."
                ],
                options: [
                    CLIHelpOptionOutput(flag: "--frame", valueName: "id", description: "Open the timeline anchored to a frame ID."),
                    CLIHelpOptionOutput(flag: "--result", valueName: "n", description: "Open the timeline anchored to a stored search result."),
                    CLIHelpOptionOutput(flag: "--at", valueName: "time", description: "Open the timeline or anchor a deeplinked search near a time."),
                    CLIHelpOptionOutput(flag: "--query", valueName: "text", description: "Open the search overlay with query and filter state applied.")
                ] + searchOptionHelp(includeLimit: false),
                examples: [
                    "retrace open --frame 123456",
                    "retrace open --query \"tax question\" --range 2024-04-01..2024-04-30 --not-tag hidden"
                ]
            )
        case ["apps"], ["apps", "list"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "List known app bundle IDs and resolved names from Retrace history.",
                usage: "retrace apps list",
                examples: ["retrace apps list"]
            )
        case ["usage"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Usage analytics and raw activity exports for apps, websites, tabs, sessions, screen time, and switches.",
                usage: "retrace usage <apps|websites|tabs|sessions|screen-time|switches> ...",
                subcommands: [
                    CLIHelpSubcommandOutput(name: "apps", summary: "Aggregate time spent per app in a contiguous range."),
                    CLIHelpSubcommandOutput(name: "websites", summary: "Browser-only website breakdown for a supported browser app."),
                    CLIHelpSubcommandOutput(name: "tabs", summary: "Browser tabs or non-browser windows for an app."),
                    CLIHelpSubcommandOutput(name: "sessions", summary: "Raw ordered activity/session export for custom analysis."),
                    CLIHelpSubcommandOutput(name: "screen-time", summary: "Daily screen-time series for a contiguous range."),
                    CLIHelpSubcommandOutput(name: "switches", summary: "Derived app-to-app context-switch transitions.")
                ],
                examples: [
                    "retrace usage apps --from today --to now",
                    "retrace usage sessions --from \"2pm\" --to \"4pm\""
                ]
            )
        case ["usage", "apps"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Aggregate time spent per app.",
                usage: "retrace usage apps --from <time> --to <time> [--limit <n>]",
                options: [
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned rows.")
                ],
                examples: [
                    "retrace usage apps --from today --to now",
                    "retrace usage apps --from \"2026-04-05 18:00\" --to \"2026-04-05 19:00\" --limit 5"
                ]
            )
        case ["usage", "websites"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Browser-only website breakdown for a supported browser app.",
                usage: "retrace usage websites --app <bundle-or-name> --from <time> --to <time> [--limit <n>]",
                notes: ["`usage websites` only works for apps in Retrace's supported browser list."],
                options: [
                    CLIHelpOptionOutput(flag: "--app", valueName: "bundle-or-name", description: "Browser app to analyze."),
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned rows.")
                ],
                examples: [
                    "retrace usage websites --app Chrome --from today --to now",
                    "retrace usage websites --app Safari --from \"2026-04-05 18:00\" --to \"2026-04-05 19:00\" --limit 5"
                ]
            )
        case ["usage", "tabs"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Break down browser tabs or non-browser windows for an app.",
                usage: "retrace usage tabs --app <bundle-or-name> --from <time> --to <time> [--website <site>] [--limit <n>]",
                notes: ["`--website` only works for supported browser apps. Non-browser apps return app-window rows instead."],
                options: [
                    CLIHelpOptionOutput(flag: "--app", valueName: "bundle-or-name", description: "App to analyze."),
                    CLIHelpOptionOutput(flag: "--website", valueName: "site", description: "Optional browser website filter."),
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned rows.")
                ],
                examples: [
                    "retrace usage tabs --app Chrome --from today --to now",
                    "retrace usage tabs --app Chrome --website twitter.com --from today --to now"
                ]
            )
        case ["usage", "sessions"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Raw ordered session export for custom analytics like context switches.",
                usage: "retrace usage sessions --from <time> --to <time> [--app <bundle-or-name>] [--window <term>] [--website <site>] [--hidden hide|show|only] [--limit <n>] [--offset <n>]",
                options: [
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--app", valueName: "bundle-or-name", description: "Optional app filter."),
                    CLIHelpOptionOutput(flag: "--window", valueName: "term", description: "Optional window-title substring filter."),
                    CLIHelpOptionOutput(flag: "--website", valueName: "site", description: "Optional website/domain substring filter."),
                    CLIHelpOptionOutput(flag: "--hidden", valueName: "hide|show|only", description: "Control hidden-segment visibility."),
                    CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned rows."),
                    CLIHelpOptionOutput(flag: "--offset", valueName: "n", description: "Offset into the ordered result set.")
                ],
                examples: [
                    "retrace usage sessions --from \"2pm\" --to \"4pm\"",
                    "retrace usage sessions --from \"2026-04-05 18:00\" --to \"2026-04-05 18:15\" --app Chrome --limit 5"
                ]
            )
        case ["usage", "screen-time"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Return a daily screen-time series for a contiguous range.",
                usage: "retrace usage screen-time --from <time> --to <time>",
                options: [
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range.")
                ],
                examples: [
                    "retrace usage screen-time --from 2026-04-01 --to 2026-04-15"
                ]
            )
        case ["usage", "switches"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Return derived app-to-app context-switch transitions.",
                usage: "retrace usage switches --from <time> --to <time> [--app <bundle-or-name>] [--hidden hide|show|only] [--limit <n>]",
                notes: ["For custom switch definitions, prefer `retrace usage sessions` and derive them from the raw stream."],
                options: [
                    CLIHelpOptionOutput(flag: "--from", valueName: "time", description: "Start of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--to", valueName: "time", description: "End of the contiguous time range."),
                    CLIHelpOptionOutput(flag: "--app", valueName: "bundle-or-name", description: "Restrict transitions to those involving this app."),
                    CLIHelpOptionOutput(flag: "--hidden", valueName: "hide|show|only", description: "Control hidden-segment visibility."),
                    CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned transitions.")
                ],
                examples: [
                    "retrace usage switches --from \"2pm\" --to \"4pm\"",
                    "retrace usage switches --from \"2026-04-05 18:00\" --to \"2026-04-05 18:15\" --app Chrome --limit 5"
                ]
            )
        case ["extract"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Recover text, URLs, OCR, in-page links, or frame images from a frame or stored result.",
                usage: "retrace extract <text|url|links|ocr|image> ...",
                notes: [
                    "`extract image` is app-backed only and requires a running Retrace.app export host."
                ],
                subcommands: [
                    CLIHelpSubcommandOutput(name: "text", summary: "Return extracted text for a frame or stored result."),
                    CLIHelpSubcommandOutput(name: "url", summary: "Return the primary browser URL for a frame or stored result."),
                    CLIHelpSubcommandOutput(name: "links", summary: "Return captured in-page link rows and routing state."),
                    CLIHelpSubcommandOutput(name: "ocr", summary: "Return OCR node-level output."),
                    CLIHelpSubcommandOutput(name: "image", summary: "Export a frame image to disk.")
                ],
                examples: [
                    "retrace extract text --result 1",
                    "retrace extract image --frame 123456 --output /tmp/frame.jpg"
                ]
            )
        case ["inspect"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Inspect Retrace system health, OCR state, queue depth, storage, metrics, or a frame.",
                usage: "retrace inspect <system|ocr|queue|storage|metrics|frame> ...",
                subcommands: [
                    CLIHelpSubcommandOutput(name: "system", summary: "Return CPU, memory, and recent app health details."),
                    CLIHelpSubcommandOutput(name: "ocr", summary: "Return OCR progress and processing status."),
                    CLIHelpSubcommandOutput(name: "queue", summary: "Return frame-processing queue state."),
                    CLIHelpSubcommandOutput(name: "storage", summary: "Return storage/database path and retention details."),
                    CLIHelpSubcommandOutput(name: "metrics", summary: "Return recent daily_metrics rows."),
                    CLIHelpSubcommandOutput(name: "frame", summary: "Return detailed metadata for a frame or stored result.")
                ],
                examples: [
                    "retrace inspect system",
                    "retrace inspect frame --result 1"
                ]
            )
        case ["config"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "List, read, set, and reset curated Retrace settings.",
                usage: "retrace config <list|get|set|reset> ...",
                notes: [
                    Self.configPersistenceModel,
                    Self.configRuntimeBehaviorNote
                ],
                subcommands: [
                    CLIHelpSubcommandOutput(name: "list", summary: "List all curated config entries."),
                    CLIHelpSubcommandOutput(name: "get", summary: "Read one config entry by canonical key or alias."),
                    CLIHelpSubcommandOutput(name: "set", summary: "Write one config entry after validation."),
                    CLIHelpSubcommandOutput(name: "reset", summary: "Clear one config entry back to default.")
                ],
                examples: [
                    "retrace config list",
                    "retrace config get capture.interval",
                    "retrace config set developer.showOCRDebugOverlay false"
                ]
            )
        case ["completions"]:
            return CLIHelpOutput(
                topicPath: topic,
                summary: "Generate completion scripts for supported shells.",
                usage: "retrace completions <bash|zsh|fish>",
                examples: [
                    "retrace completions zsh",
                    "retrace completions bash"
                ]
            )
        default:
            throw CLIError.usage(
                "No help topic found for `\(topic.joined(separator: " "))`.",
                details: ["commands": "status, apps, search, jump, around, open, config, usage, extract, inspect, completions"]
            )
        }
    }

    public func completions(_ request: CLICompletionsRequest) async throws -> CLICompletionsOutput {
        let script = switch request.shell {
        case .bash:
            Self.bashCompletionScript
        case .zsh:
            Self.zshCompletionScript
        case .fish:
            Self.fishCompletionScript
        }

        try? await recordCLICommandMetric(
            command: "completions",
            payload: [
                "source": "cli",
                "shell": request.shell.rawValue
            ]
        )

        return CLICompletionsOutput(shell: request.shell, script: script)
    }

    public func configList() async throws -> CLIConfigListOutput {
        let entries = Self.configDescriptors
            .sorted { $0.key < $1.key }
            .map { configEntryOutput(for: $0) }

        try? await recordCLICommandMetric(
            command: "config_list",
            payload: [
                "source": "cli",
                "entryCount": entries.count
            ]
        )

        return CLIConfigListOutput(
            entryCount: entries.count,
            persistenceModel: Self.configPersistenceModel,
            runtimeBehaviorNote: Self.configRuntimeBehaviorNote,
            entries: entries
        )
    }

    public func configGet(_ request: CLIConfigKeyRequest) async throws -> CLIConfigGetOutput {
        let descriptor = try configDescriptor(for: request.key)

        try? await recordCLICommandMetric(
            command: "config_get",
            payload: [
                "source": "cli",
                "key": descriptor.key
            ]
        )

        return CLIConfigGetOutput(
            persistenceModel: Self.configPersistenceModel,
            runtimeBehaviorNote: Self.configRuntimeBehaviorNote,
            entry: configEntryOutput(for: descriptor)
        )
    }

    public func configSet(_ request: CLIConfigSetRequest) async throws -> CLIConfigSetOutput {
        let descriptor = try configDescriptor(for: request.key)
        try requireCLIWritable(descriptor)
        let previousValue = descriptor.currentValue(in: defaults)
        let newValue = try parsedConfigValue(
            request.value,
            for: descriptor
        )

        try validateConfigValue(newValue, for: descriptor)
        writeConfigValue(newValue, for: descriptor)

        let updatedEntry = configEntryOutput(for: descriptor)

        try? await recordCLICommandMetric(
            command: "config_set",
            payload: [
                "source": "cli",
                "key": descriptor.key,
                "changed": previousValue != updatedEntry.currentValue
            ]
        )

        return CLIConfigSetOutput(
            key: descriptor.key,
            changed: previousValue != updatedEntry.currentValue,
            previousValue: previousValue,
            persistenceModel: Self.configPersistenceModel,
            runtimeBehaviorNote: Self.configRuntimeBehaviorNote,
            entry: updatedEntry
        )
    }

    public func configReset(_ request: CLIConfigKeyRequest) async throws -> CLIConfigResetOutput {
        let descriptor = try configDescriptor(for: request.key)
        try requireCLIWritable(descriptor)
        let previousValue = descriptor.currentValue(in: defaults)
        defaults.removeObject(forKey: descriptor.defaultsKey)

        let updatedEntry = configEntryOutput(for: descriptor)

        try? await recordCLICommandMetric(
            command: "config_reset",
            payload: [
                "source": "cli",
                "key": descriptor.key,
                "changed": previousValue != updatedEntry.currentValue
            ]
        )

        return CLIConfigResetOutput(
            key: descriptor.key,
            changed: previousValue != updatedEntry.currentValue,
            previousValue: previousValue,
            persistenceModel: Self.configPersistenceModel,
            runtimeBehaviorNote: Self.configRuntimeBehaviorNote,
            entry: updatedEntry
        )
    }

    public func extractText(_ request: CLIExtractTextRequest) async throws -> CLIExtractTextOutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveFrameSelection(request.selector)
        let nodes = try await coordinator.getAllOCRNodes(
            frameID: FrameID(value: resolvedSelection.frame.id.value),
            source: resolvedSelection.frame.source
        )
        let joinedText = joinedOCRText(nodes)

        try? await recordCLICommandMetric(
            command: "extract_text",
            payload: [
                "source": "cli",
                "frameID": resolvedSelection.frame.id.value,
                "nodeCount": nodes.count
            ]
        )

        return CLIExtractTextOutput(
            target: extractTargetOutput(from: resolvedSelection),
            text: joinedText,
            nodeCount: nodes.count
        )
    }

    public func extractURL(_ request: CLIExtractURLRequest) async throws -> CLIExtractURLOutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveFrameSelection(request.selector)

        try? await recordCLICommandMetric(
            command: "extract_url",
            payload: [
                "source": "cli",
                "frameID": resolvedSelection.frame.id.value,
                "hasBrowserURL": resolvedSelection.frame.metadata.browserURL != nil
            ]
        )

        return CLIExtractURLOutput(
            target: extractTargetOutput(from: resolvedSelection),
            browserURL: resolvedSelection.frame.metadata.browserURL
        )
    }

    public func extractLinks(_ request: CLIExtractLinksRequest) async throws -> CLIExtractLinksOutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveFrameSelection(request.selector)
        let frameID = FrameID(value: resolvedSelection.frame.id.value)
        let rows = try await coordinator.getFrameInPageURLRows(frameID: frameID)
        let state = try await coordinator.getFrameInPageURLState(frameID: frameID)

        try? await recordCLICommandMetric(
            command: "extract_links",
            payload: [
                "source": "cli",
                "frameID": resolvedSelection.frame.id.value,
                "linkCount": rows.count
            ]
        )

        return CLIExtractLinksOutput(
            target: extractTargetOutput(from: resolvedSelection),
            linkCount: rows.count,
            state: state.map {
                CLIExtractLinkStateOutput(
                    mouseX: $0.mouseX,
                    mouseY: $0.mouseY,
                    scrollX: $0.scrollX,
                    scrollY: $0.scrollY,
                    videoCurrentTime: $0.videoCurrentTime
                )
            },
            links: rows.map { CLIExtractLinkRowOutput(order: $0.order, url: $0.url, nodeID: $0.nodeID) }
        )
    }

    public func extractOCR(_ request: CLIExtractOCRRequest) async throws -> CLIExtractOCROutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveFrameSelection(request.selector)
        let nodes = try await coordinator.getAllOCRNodes(
            frameID: FrameID(value: resolvedSelection.frame.id.value),
            source: resolvedSelection.frame.source
        )

        try? await recordCLICommandMetric(
            command: "extract_ocr",
            payload: [
                "source": "cli",
                "frameID": resolvedSelection.frame.id.value,
                "nodeCount": nodes.count
            ]
        )

        return CLIExtractOCROutput(
            target: extractTargetOutput(from: resolvedSelection),
            text: joinedOCRText(nodes),
            nodeCount: nodes.count,
            nodes: nodes.map {
                CLIExtractOCRNodeOutput(
                    id: $0.id,
                    nodeOrder: $0.nodeOrder,
                    frameID: $0.frameId,
                    x: Double($0.x),
                    y: Double($0.y),
                    width: Double($0.width),
                    height: Double($0.height),
                    text: $0.text,
                    isRedacted: $0.isRedacted
                )
            }
        )
    }

    public func extractImage(_ request: CLIExtractImageRequest) async throws -> CLIExtractImageOutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveFrameSelection(request.selector)
        let outputPath = URL(fileURLWithPath: NSString(string: request.outputPath).expandingTildeInPath).standardizedFileURL.path

        if FileManager.default.fileExists(atPath: outputPath), !request.overwrite {
            throw CLIError.outputAlreadyExists(outputPath)
        }

        guard imageExportHost.isAppRunning() else {
            throw CLIError.imageExportHostUnavailable
        }

        do {
            let response = try await imageExportHost.exportImage(
                frameID: resolvedSelection.frame.id.value,
                outputPath: outputPath,
                overwrite: request.overwrite
            )

            if let errorMessage = response.errorMessage {
                throw CLIError.imageExportFailed(errorMessage)
            }

            guard let byteCount = response.byteCount else {
                throw CLIError.imageExportFailed("Retrace.app did not report exported byte count.")
            }

            try? await recordCLICommandMetric(
                command: "extract_image",
                payload: [
                    "source": "cli",
                    "frameID": resolvedSelection.frame.id.value,
                    "byteCount": byteCount
                ]
            )

            return CLIExtractImageOutput(
                target: extractTargetOutput(from: resolvedSelection),
                outputPath: response.outputPath,
                byteCount: byteCount
            )
        } catch let error as CLIError {
            throw error
        } catch CLIImageExportTransportError.timeout {
            throw CLIError.imageExportTimedOut(resolvedSelection.frame.id.value)
        } catch {
            throw CLIError.imageExportFailed(String(describing: error))
        }
    }

    public func inspectSystem() async throws -> CLIInspectSystemOutput {
        try await ensureInitialized()

        let appStats = try await coordinator.getStatistics()
        let queueStats: QueueStatistics? = nil
        let encodingStats: (queueDepth: Int, pendingCount: Int)? = nil
        let powerState = coordinator.getCurrentPowerState()
        let memorySnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: false)

        try? await recordCLICommandMetric(
            command: "inspect_system",
            payload: [
                "source": "cli",
                "hasQueueStats": queueStats != nil,
                "hasEncodingStats": encodingStats != nil
            ]
        )

        return CLIInspectSystemOutput(
            process: inspectProcessOutput(),
            pipeline: CLIStatusPipeline(
                isRunning: nil,
                framesProcessed: nil,
                errorCount: nil,
                startTime: nil,
                latestFrameTimestamp: appStats.database.newestFrameDate
            ),
            isCapturing: nil,
            database: inspectDatabaseOutput(from: appStats.database),
            capture: nil,
            processing: nil,
            search: nil,
            queue: queueStats.map { inspectQueueOutput(from: $0) },
            encoding: encodingStats.map { inspectEncodingOutput(from: $0) },
            power: inspectPowerOutput(from: powerState),
            memory: inspectMemoryOutput(from: memorySnapshot)
        )
    }

    public func inspectOCR() async throws -> CLIInspectOCROutput {
        try await ensureInitialized()

        let queueStats: QueueStatistics? = nil
        let encodingStats: (queueDepth: Int, pendingCount: Int)? = nil
        async let processedPerMinuteTask = coordinator.getFramesProcessedPerMinute(lastMinutes: 10)
        async let encodedPerMinuteTask = coordinator.getFramesEncodedPerMinute(lastMinutes: 10)
        async let rewrittenPerMinuteTask = coordinator.getFramesRewrittenPerMinute(lastMinutes: 10)

        let powerState = coordinator.getCurrentPowerState()
        let processedPerMinute = try await processedPerMinuteTask
        let encodedPerMinute = try await encodedPerMinuteTask
        let rewrittenPerMinute = try await rewrittenPerMinuteTask

        try? await recordCLICommandMetric(
            command: "inspect_ocr",
            payload: [
                "source": "cli",
                "hasQueueStats": queueStats != nil,
                "hasEncodingStats": encodingStats != nil
            ]
        )

        return CLIInspectOCROutput(
            queue: queueStats.map { inspectQueueOutput(from: $0) },
            encoding: encodingStats.map { inspectEncodingOutput(from: $0) },
            power: inspectPowerOutput(from: powerState),
            framesProcessedPerMinute: minuteCountOutputs(from: processedPerMinute),
            framesEncodedPerMinute: minuteCountOutputs(from: encodedPerMinute),
            framesRewrittenPerMinute: minuteCountOutputs(from: rewrittenPerMinute)
        )
    }

    public func inspectQueue() async throws -> CLIInspectQueueOutput {
        try await ensureInitialized()

        let queueStats: QueueStatistics? = nil
        let encodingStats: (queueDepth: Int, pendingCount: Int)? = nil
        let powerState = coordinator.getCurrentPowerState()

        try? await recordCLICommandMetric(
            command: "inspect_queue",
            payload: [
                "source": "cli",
                "hasQueueStats": queueStats != nil,
                "hasEncodingStats": encodingStats != nil
            ]
        )

        return CLIInspectQueueOutput(
            queue: queueStats.map { inspectQueueOutput(from: $0) },
            encoding: encodingStats.map { inspectEncodingOutput(from: $0) },
            power: inspectPowerOutput(from: powerState)
        )
    }

    public func inspectStorage() async throws -> CLIInspectStorageOutput {
        try await ensureInitialized()

        let databaseStats = try await coordinator.getDatabaseStatistics()
        let totalCapturedDuration = try await coordinator.getTotalCapturedDuration()
        let distinctAppBundleIDs = try await coordinator.getDistinctAppBundleIDs()
        let quickStats = try await coordinator.getDatabaseStatisticsQuick()

        let fileManager = FileManager.default
        let rewindEnabled = defaults.bool(forKey: "useRewindData")

        try? await recordCLICommandMetric(
            command: "inspect_storage",
            payload: [
                "source": "cli",
                "rewindEnabled": rewindEnabled
            ]
        )

        return CLIInspectStorageOutput(
            storage: CLIStatusStorage(
                storageRoot: AppPaths.expandedStorageRoot,
                storageRootExists: fileManager.fileExists(atPath: AppPaths.expandedStorageRoot),
                databasePath: NSString(string: AppPaths.databasePath).expandingTildeInPath,
                databaseExists: fileManager.fileExists(atPath: NSString(string: AppPaths.databasePath).expandingTildeInPath)
            ),
            rewind: CLIStatusRewind(
                enabled: rewindEnabled,
                storageRoot: AppPaths.expandedRewindStorageRoot,
                storageRootExists: fileManager.fileExists(atPath: AppPaths.expandedRewindStorageRoot),
                databasePath: NSString(string: AppPaths.rewindDBPath).expandingTildeInPath,
                databaseExists: fileManager.fileExists(atPath: NSString(string: AppPaths.rewindDBPath).expandingTildeInPath)
            ),
            statistics: CLIStatusStatistics(
                frameCount: quickStats.frameCount,
                sessionCount: quickStats.sessionCount,
                distinctAppCount: distinctAppBundleIDs.count,
                totalCapturedDurationSeconds: totalCapturedDuration
            ),
            database: inspectDatabaseOutput(from: databaseStats)
        )
    }

    public func inspectMetrics(_ request: CLIInspectMetricsRequest) async throws -> CLIInspectMetricsOutput {
        try await ensureInitialized()

        let events = try await coordinator.getRecentMetricEvents(limit: request.recentLimit)

        try? await recordCLICommandMetric(
            command: "inspect_metrics",
            payload: [
                "source": "cli",
                "recentLimit": request.recentLimit,
                "returnedCount": events.count
            ]
        )

        return CLIInspectMetricsOutput(
            recentLimit: request.recentLimit,
            returnedCount: events.count,
            events: events
        )
    }

    public func inspectFrame(_ request: CLIInspectFrameRequest) async throws -> CLIInspectFrameOutput {
        try await ensureInitialized()

        let resolvedSelection = try await resolveInspectFrameSelection(request.selector)
        let frameID = FrameID(value: resolvedSelection.frame.id.value)
        let nodes = try await coordinator.getAllOCRNodes(
            frameID: frameID,
            source: resolvedSelection.frame.source
        )
        let links = try await coordinator.getFrameInPageURLRows(frameID: frameID)
        let linkState = try await coordinator.getFrameInPageURLState(frameID: frameID)
        let ocrStatus = try await coordinator.getOCRStatus(frameID: frameID)

        try? await recordCLICommandMetric(
            command: "inspect_frame",
            payload: [
                "source": "cli",
                "frameID": resolvedSelection.frame.id.value,
                "nodeCount": nodes.count,
                "linkCount": links.count
            ]
        )

        return CLIInspectFrameOutput(
            target: extractTargetOutput(from: resolvedSelection),
            processingStatusCode: resolvedSelection.frameWithVideoInfo?.processingStatus ?? -1,
            ocrStatus: inspectOCRStatusOutput(from: ocrStatus),
            videoInfo: resolvedSelection.frameWithVideoInfo?.videoInfo,
            nodeCount: nodes.count,
            linkCount: links.count,
            inPageURLState: linkState.map {
                CLIExtractLinkStateOutput(
                    mouseX: $0.mouseX,
                    mouseY: $0.mouseY,
                    scrollX: $0.scrollX,
                    scrollY: $0.scrollY,
                    videoCurrentTime: $0.videoCurrentTime
                )
            }
        )
    }

    public func usageApps(_ request: CLIUsageAppsRequest) async throws -> CLIUsageAppsOutput {
        try await ensureInitialized()

        let rows = try await coordinator.getAppUsageStats(
            from: request.timeRange.from.date,
            to: request.timeRange.to.date
        )
        let normalizedRows = rows
            .sorted {
                if $0.duration == $1.duration {
                    return $0.bundleID < $1.bundleID
                }
                return $0.duration > $1.duration
            }
            .map {
                CLIUsageAppRowOutput(
                    bundleID: $0.bundleID,
                    isBrowser: AppInfo.browserBundleIDs.contains($0.bundleID),
                    durationSeconds: $0.duration,
                    uniqueItemCount: $0.uniqueItemCount
                )
            }

        let limitedRows = Array(normalizedRows.prefix(request.limit))

        try? await recordCLICommandMetric(
            command: "usage_apps",
            payload: [
                "source": "cli",
                "from": request.timeRange.from.rawValue,
                "to": request.timeRange.to.rawValue,
                "resultCount": limitedRows.count
            ]
        )

        return CLIUsageAppsOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            limit: request.limit,
            returnedCount: limitedRows.count,
            totalDurationSeconds: normalizedRows.reduce(0) { $0 + $1.durationSeconds },
            results: limitedRows
        )
    }

    public func usageWebsites(_ request: CLIUsageWebsitesRequest) async throws -> CLIUsageWebsitesOutput {
        try await ensureInitialized()

        let bundleID = try await resolveUsageApp(request.app)
        guard AppInfo.browserBundleIDs.contains(bundleID) else {
            throw CLIError.invalidValue(
                option: "--app",
                value: request.app,
                details: ["reason": "`usage websites` only supports browser apps"]
            )
        }

        let rows = try await coordinator.getWindowUsageForApp(
            bundleID: bundleID,
            from: request.timeRange.from.date,
            to: request.timeRange.to.date,
            limit: nil
        )
        let normalizedRows = rows.compactMap { row -> CLIUsageWebsiteRowOutput? in
            guard row.isWebsite, let website = row.windowName?.trimmingCharacters(in: .whitespacesAndNewlines), !website.isEmpty else {
                return nil
            }
            return CLIUsageWebsiteRowOutput(
                website: website,
                durationSeconds: row.duration,
                tabCount: row.tabCount
            )
        }

        let limitedRows = Array(normalizedRows.prefix(request.limit))

        try? await recordCLICommandMetric(
            command: "usage_websites",
            payload: [
                "source": "cli",
                "appBundleID": bundleID,
                "from": request.timeRange.from.rawValue,
                "to": request.timeRange.to.rawValue,
                "resultCount": limitedRows.count
            ]
        )

        return CLIUsageWebsitesOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            appBundleID: bundleID,
            limit: request.limit,
            returnedCount: limitedRows.count,
            totalMatchedCount: normalizedRows.count,
            totalDurationSeconds: normalizedRows.reduce(0) { $0 + $1.durationSeconds },
            results: limitedRows
        )
    }

    public func usageTabs(_ request: CLIUsageTabsRequest) async throws -> CLIUsageTabsOutput {
        try await ensureInitialized()

        let bundleID = try await resolveUsageApp(request.app)
        let normalizedWebsiteFilter = normalizedFilterTerm(request.website)
        let normalizedRows: [CLIUsageTabRowOutput]

        if AppInfo.browserBundleIDs.contains(bundleID) {
            let rows: [(windowName: String?, browserUrl: String?, duration: TimeInterval)]
            if let normalizedWebsiteFilter {
                rows = try await coordinator.getBrowserTabUsageForDomain(
                    bundleID: bundleID,
                    domain: normalizedWebsiteFilter,
                    from: request.timeRange.from.date,
                    to: request.timeRange.to.date
                )
            } else {
                rows = try await coordinator.getBrowserTabUsage(
                    bundleID: bundleID,
                    from: request.timeRange.from.date,
                    to: request.timeRange.to.date
                )
            }

            normalizedRows = rows.map {
                CLIUsageTabRowOutput(
                    itemKind: "browser_tab",
                    title: $0.windowName,
                    browserURL: $0.browserUrl,
                    durationSeconds: $0.duration
                )
            }
        } else {
            if let website = normalizedWebsiteFilter {
                throw CLIError.invalidValue(
                    option: "--website",
                    value: website,
                    details: ["reason": "`usage tabs --website` only works for supported browser apps"]
                )
            }

            let rows = try await coordinator.getWindowUsageForApp(
                bundleID: bundleID,
                from: request.timeRange.from.date,
                to: request.timeRange.to.date,
                limit: nil
            )

            normalizedRows = rows.compactMap { row in
                guard !row.isWebsite else { return nil }
                return CLIUsageTabRowOutput(
                    itemKind: "app_window",
                    title: row.windowName,
                    browserURL: nil,
                    durationSeconds: row.duration
                )
            }
        }

        let limitedRows = Array(normalizedRows.prefix(request.limit))

        var usageTabsMetricPayload: [String: Any] = [
            "source": "cli",
            "appBundleID": bundleID,
            "from": request.timeRange.from.rawValue,
            "to": request.timeRange.to.rawValue,
            "hasWebsiteFilter": normalizedWebsiteFilter != nil,
            "resultCount": limitedRows.count
        ]
        if let normalizedWebsiteFilter {
            usageTabsMetricPayload["website"] = normalizedWebsiteFilter
        }

        try? await recordCLICommandMetric(
            command: "usage_tabs",
            payload: usageTabsMetricPayload
        )

        return CLIUsageTabsOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            appBundleID: bundleID,
            website: normalizedWebsiteFilter,
            limit: request.limit,
            returnedCount: limitedRows.count,
            totalMatchedCount: normalizedRows.count,
            totalDurationSeconds: normalizedRows.reduce(0) { $0 + $1.durationSeconds },
            results: limitedRows
        )
    }

    public func usageSessions(_ request: CLIUsageSessionsRequest) async throws -> CLIUsageSessionsOutput {
        try await ensureInitialized()

        let normalizedContext = try await normalizedUsageSessionRows(for: request)
        let normalizedRows = normalizedContext.rows

        let pagedRows = Array(normalizedRows.dropFirst(request.offset).prefix(request.limit))

        try? await recordCLICommandMetric(
            command: "usage_sessions",
            payload: [
                "source": "cli",
                "from": request.timeRange.from.rawValue,
                "to": request.timeRange.to.rawValue,
                "hasAppFilter": normalizedContext.resolvedApp != nil,
                "hasWindowFilter": normalizedContext.normalizedWindowFilter != nil,
                "hasWebsiteFilter": normalizedContext.normalizedWebsiteFilter != nil,
                "hiddenFilter": request.hiddenFilter.rawValue,
                "resultCount": pagedRows.count
            ]
        )

        return CLIUsageSessionsOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            filters: CLIUsageSessionFiltersOutput(
                appBundleID: normalizedContext.resolvedApp,
                window: normalizedContext.normalizedWindowFilter,
                website: normalizedContext.normalizedWebsiteFilter,
                hiddenFilter: request.hiddenFilter.rawValue
            ),
            limit: request.limit,
            offset: request.offset,
            totalMatchedCount: normalizedRows.count,
            returnedCount: pagedRows.count,
            results: pagedRows
        )
    }

    public func usageScreenTime(_ request: CLIUsageScreenTimeRequest) async throws -> CLIUsageScreenTimeOutput {
        try await ensureInitialized()

        let dailyRows = try await coordinator.getDailyScreenTime(
            from: request.timeRange.from.date,
            to: request.timeRange.to.date
        )
        let normalizedRows = dailyRows.map {
            CLIUsageScreenTimeRowOutput(
                date: $0.date,
                durationMilliseconds: $0.value,
                durationSeconds: Double($0.value) / 1000.0
            )
        }
        let totalDurationMilliseconds = normalizedRows.reduce(Int64(0)) { $0 + $1.durationMilliseconds }

        try? await recordCLICommandMetric(
            command: "usage_screen_time",
            payload: [
                "source": "cli",
                "from": request.timeRange.from.rawValue,
                "to": request.timeRange.to.rawValue,
                "dayCount": normalizedRows.count
            ]
        )

        return CLIUsageScreenTimeOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            totalDurationMilliseconds: totalDurationMilliseconds,
            totalDurationSeconds: Double(totalDurationMilliseconds) / 1000.0,
            daily: normalizedRows
        )
    }

    public func usageSwitches(_ request: CLIUsageSwitchesRequest) async throws -> CLIUsageSwitchesOutput {
        try await ensureInitialized()

        let resolvedApp = try await resolveOptionalUsageApp(request.app)
        let sessionContext = try await normalizedUsageSessionRows(
            for: CLIUsageSessionsRequest(
                timeRange: request.timeRange,
                hiddenFilter: request.hiddenFilter,
                limit: Int.max,
                offset: 0
            )
        )

        let transitions = zip(sessionContext.rows, sessionContext.rows.dropFirst()).compactMap { previous, next -> CLIUsageSwitchTransitionOutput? in
            guard previous.bundleID.caseInsensitiveCompare(next.bundleID) != .orderedSame else {
                return nil
            }

            if let resolvedApp,
               previous.bundleID.caseInsensitiveCompare(resolvedApp) != .orderedSame,
               next.bundleID.caseInsensitiveCompare(resolvedApp) != .orderedSame {
                return nil
            }

            return CLIUsageSwitchTransitionOutput(
                occurredAt: next.effectiveStart,
                fromSegmentID: previous.segmentID,
                toSegmentID: next.segmentID,
                fromBundleID: previous.bundleID,
                toBundleID: next.bundleID,
                fromWindowName: previous.windowName,
                toWindowName: next.windowName,
                fromWebsite: previous.website,
                toWebsite: next.website
            )
        }

        let limitedTransitions = Array(transitions.prefix(request.limit))

        try? await recordCLICommandMetric(
            command: "usage_switches",
            payload: [
                "source": "cli",
                "from": request.timeRange.from.rawValue,
                "to": request.timeRange.to.rawValue,
                "hasAppFilter": resolvedApp != nil,
                "hiddenFilter": request.hiddenFilter.rawValue,
                "resultCount": limitedTransitions.count
            ]
        )

        return CLIUsageSwitchesOutput(
            timeWindow: usageTimeWindowOutput(request.timeRange),
            appBundleID: resolvedApp,
            hiddenFilter: request.hiddenFilter.rawValue,
            limit: request.limit,
            totalSwitchCount: transitions.count,
            returnedTransitionCount: limitedTransitions.count,
            transitions: limitedTransitions
        )
    }

    internal static func encodedMetadataFilter(includeTerms: [String], excludeTerms: [String]) -> String? {
        let normalizedIncludeTerms = normalizedMetadataTerms(includeTerms)
        var normalizedExcludeTerms = normalizedMetadataTerms(excludeTerms)
        guard !normalizedIncludeTerms.isEmpty || !normalizedExcludeTerms.isEmpty else {
            return nil
        }

        let includeKeys = Set(normalizedIncludeTerms.map { $0.lowercased() })
        normalizedExcludeTerms.removeAll { includeKeys.contains($0.lowercased()) }

        let payload = EncodedMetadataFilterPayload(
            includeTerms: normalizedIncludeTerms.isEmpty ? nil : normalizedIncludeTerms,
            excludeTerms: normalizedExcludeTerms.isEmpty ? nil : normalizedExcludeTerms,
            mode: nil,
            terms: nil
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }

        return encodedMetadataFilterPrefix + data.base64EncodedString()
    }

    internal static func normalizedSearchResults(
        _ results: [SearchResult],
        limit: Int
    ) -> [CLISearchResultOutput] {
        Array(results.prefix(limit)).enumerated().map { index, result in
            CLISearchResultOutput(
                resultID: index + 1,
                frameID: result.id.value,
                timestamp: result.timestamp,
                appBundleID: result.metadata.appBundleID,
                appName: result.metadata.appName,
                windowName: result.metadata.windowName,
                browserURL: result.metadata.browserURL,
                snippet: result.snippet,
                matchedText: result.matchedText,
                relevanceScore: result.relevanceScore,
                segmentID: result.segmentID.value,
                videoID: result.videoID.value,
                frameIndex: result.frameIndex,
                source: result.source
            )
        }
    }

    private static let configPersistenceModel = "shared_user_defaults"
    private static let configRuntimeBehaviorNote =
        "Storage locations and encryption must be changed in Settings. CLI config commands write shared settings only. Running Retrace windows usually pick up UI-facing defaults automatically, but capture, OCR, storage, and login-item behaviors may need the app to refresh or restart before the effect is visible."

    private static let configDescriptors: [CLIConfigDescriptor] = [
        CLIConfigDescriptor(
            key: "general.launchAtLogin",
            defaultsKey: "launchAtLogin",
            category: "general",
            valueType: .bool,
            defaultValue: { .bool(false) },
            note: "Persisted preference only. The actual login item is normally applied by the app process."
        ),
        CLIConfigDescriptor(
            key: "general.showDockIcon",
            defaultsKey: "showDockIcon",
            category: "general",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "general.showMenuBarIcon",
            defaultsKey: "showMenuBarIcon",
            category: "general",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "general.theme",
            defaultsKey: "theme",
            category: "general",
            valueType: .string,
            allowedStringValues: ["Auto", "Light", "Dark"],
            defaultValue: { .string("Auto") }
        ),
        CLIConfigDescriptor(
            key: "general.fontStyle",
            defaultsKey: "retraceFontStyle",
            category: "general",
            valueType: .string,
            allowedStringValues: ["default", "rounded", "serif"],
            defaultValue: { .string("default") }
        ),
        CLIConfigDescriptor(
            key: "general.colorTheme",
            defaultsKey: "retraceColorThemePreference",
            category: "general",
            valueType: .string,
            allowedStringValues: ["blue", "gold", "purple"],
            defaultValue: { .string("blue") }
        ),
        CLIConfigDescriptor(
            key: "general.timelineColoredBorders",
            defaultsKey: "timelineColoredBorders",
            category: "general",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "general.scrubbingAnimationDuration",
            defaultsKey: "scrubbingAnimationDuration",
            category: "general",
            valueType: .double,
            defaultValue: { .double(0.10) },
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "general.scrollSensitivity",
            defaultsKey: "scrollSensitivity",
            category: "general",
            valueType: .double,
            defaultValue: { .double(0.50) },
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "general.timelineScrollOrientation",
            defaultsKey: "timelineScrollOrientation",
            category: "general",
            valueType: .string,
            allowedStringValues: ["horizontal", "vertical"],
            defaultValue: { .string("horizontal") }
        ),
        CLIConfigDescriptor(
            key: "general.dashboardAppUsageViewMode",
            defaultsKey: "dashboardAppUsageViewMode",
            category: "general",
            valueType: .string,
            allowedStringValues: ["list", "squares"],
            defaultValue: { .string("list") }
        ),
        CLIConfigDescriptor(
            key: "capture.pauseReminderDelayMinutes",
            defaultsKey: "pauseReminderDelayMinutes",
            category: "capture",
            valueType: .double,
            defaultValue: { .double(30) },
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "capture.interval",
            defaultsKey: "captureIntervalSeconds",
            aliases: ["capture.captureIntervalSeconds"],
            category: "capture",
            valueType: .double,
            defaultValue: { .double(2.0) },
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "capture.resolution",
            defaultsKey: "captureResolution",
            category: "capture",
            valueType: .string,
            allowedStringValues: ["Original", "4K", "1080p", "720p"],
            defaultValue: { .string("Original") }
        ),
        CLIConfigDescriptor(
            key: "capture.activeDisplayOnly",
            defaultsKey: "captureActiveDisplayOnly",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(false) },
            note: "Stored preference; current runtime use is limited."
        ),
        CLIConfigDescriptor(
            key: "capture.excludeCursor",
            defaultsKey: "excludeCursor",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "capture.mousePosition",
            defaultsKey: "captureMousePosition",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "capture.videoQuality",
            defaultsKey: "videoQuality",
            category: "capture",
            valueType: .double,
            defaultValue: { .double(0.5) },
            minimumDouble: 0,
            maximumDouble: 1
        ),
        CLIConfigDescriptor(
            key: "capture.deleteDuplicateFrames",
            defaultsKey: "deleteDuplicateFrames",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "capture.deduplicationThreshold",
            defaultsKey: "deduplicationThreshold",
            category: "capture",
            valueType: .double,
            defaultValue: { .double(CaptureConfig.defaultDeduplicationThreshold) },
            minimumDouble: 0,
            maximumDouble: 1
        ),
        CLIConfigDescriptor(
            key: "capture.keepFramesOnMouseMovement",
            defaultsKey: "keepFramesOnMouseMovement",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "capture.onWindowChange",
            defaultsKey: "captureOnWindowChange",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "capture.onMouseClick",
            defaultsKey: "captureOnMouseClick",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "capture.collectInPageURLs",
            defaultsKey: "collectInPageURLsExperimental",
            category: "capture",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "storage.retentionDays",
            defaultsKey: "retentionDays",
            category: "storage",
            valueType: .int,
            defaultValue: { .int(0) },
            minimumInt: 0
        ),
        CLIConfigDescriptor(
            key: "storage.maxStorageGB",
            defaultsKey: "maxStorageGB",
            category: "storage",
            valueType: .double,
            defaultValue: { .double(50.0) },
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "storage.useRewindData",
            defaultsKey: "useRewindData",
            category: "storage",
            valueType: .bool,
            defaultValue: { .bool(false) },
            note: "Persisted preference only. A running app may need to reconnect or restart before Rewind data changes are visible."
        ),
        CLIConfigDescriptor(
            key: "storage.rewindCutoffDate",
            defaultsKey: "rewindCutoffDate",
            category: "storage",
            valueType: .date,
            defaultValue: { .date(ServiceContainer.defaultRewindCutoffDate()) },
            note: "Stored as a start-of-day Date."
        ),
        CLIConfigDescriptor(
            key: "storage.retentionExcludedApps",
            defaultsKey: "retentionExcludedApps",
            category: "storage",
            valueType: .string,
            defaultValue: { .string("") },
            note: "Comma-separated bundle IDs."
        ),
        CLIConfigDescriptor(
            key: "storage.retentionExcludedTagIds",
            defaultsKey: "retentionExcludedTagIds",
            category: "storage",
            valueType: .string,
            defaultValue: { .string("") },
            note: "Comma-separated tag IDs."
        ),
        CLIConfigDescriptor(
            key: "storage.retentionExcludeHidden",
            defaultsKey: "retentionExcludeHidden",
            category: "storage",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "storage.customRetraceDBLocation",
            defaultsKey: "customRetraceDBLocation",
            category: "storage",
            valueType: .string,
            nullable: true,
            defaultValue: { .null },
            note: "Changing database locations usually requires the app to restart."
        ),
        CLIConfigDescriptor(
            key: "storage.customRewindDBLocation",
            defaultsKey: "customRewindDBLocation",
            category: "storage",
            valueType: .string,
            nullable: true,
            defaultValue: { .null },
            note: "Changing database locations usually requires the app to restart."
        ),
        CLIConfigDescriptor(
            key: "privacy.excludedApps",
            defaultsKey: "excludedApps",
            category: "privacy",
            valueType: .string,
            defaultValue: { .string("") },
            note: "JSON-encoded excluded app list."
        ),
        CLIConfigDescriptor(
            key: "privacy.excludePrivateWindows",
            defaultsKey: "excludePrivateWindows",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "privacy.enableCustomPatternWindowRedaction",
            defaultsKey: "enableCustomPatternWindowRedaction",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "privacy.redactWindowTitlePatterns",
            defaultsKey: "redactWindowTitlePatterns",
            category: "privacy",
            valueType: .string,
            defaultValue: { .string("") }
        ),
        CLIConfigDescriptor(
            key: "privacy.redactBrowserURLPatterns",
            defaultsKey: "redactBrowserURLPatterns",
            category: "privacy",
            valueType: .string,
            defaultValue: { .string("") }
        ),
        CLIConfigDescriptor(
            key: "privacy.phraseLevelRedactionEnabled",
            defaultsKey: "phraseLevelRedactionEnabled",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(false) },
            note: "Enabling this requires a master key in Keychain."
        ),
        CLIConfigDescriptor(
            key: "privacy.phraseLevelRedactionPhrases",
            defaultsKey: "phraseLevelRedactionPhrases",
            category: "privacy",
            valueType: .string,
            defaultValue: { .string("[]") },
            note: "JSON array of redacted phrases."
        ),
        CLIConfigDescriptor(
            key: "privacy.excludeSafariPrivate",
            defaultsKey: "excludeSafariPrivate",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "privacy.excludeChromeIncognito",
            defaultsKey: "excludeChromeIncognito",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "privacy.encryptionEnabled",
            defaultsKey: "encryptionEnabled",
            category: "privacy",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "developer.showFrameIDs",
            defaultsKey: "showFrameIDs",
            category: "developer",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "developer.enableFrameIDSearch",
            defaultsKey: "enableFrameIDSearch",
            category: "developer",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "developer.showOCRDebugOverlay",
            defaultsKey: "showOCRDebugOverlay",
            category: "developer",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "developer.showVideoControls",
            defaultsKey: "showVideoControls",
            category: "developer",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "developer.showMenuBarCaptureFeedback",
            defaultsKey: "showMenuBarCaptureFeedback",
            category: "developer",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "power.ocrEnabled",
            defaultsKey: "ocrEnabled",
            category: "power",
            valueType: .bool,
            defaultValue: { .bool(true) }
        ),
        CLIConfigDescriptor(
            key: "power.onlyWhenPluggedIn",
            defaultsKey: "ocrOnlyWhenPluggedIn",
            category: "power",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "power.pauseInLowPowerMode",
            defaultsKey: "ocrPauseInLowPowerMode",
            category: "power",
            valueType: .bool,
            defaultValue: { .bool(false) }
        ),
        CLIConfigDescriptor(
            key: "power.maxFramesPerSecond",
            defaultsKey: "ocrMaxFramesPerSecond",
            category: "power",
            valueType: .double,
            defaultValue: { .double(0) },
            note: "Stored preference; current runtime use is limited.",
            minimumDouble: 0
        ),
        CLIConfigDescriptor(
            key: "power.processingLevel",
            defaultsKey: "ocrProcessingLevel",
            category: "power",
            valueType: .int,
            defaultValue: { .int(3) },
            minimumInt: 1,
            maximumInt: 5
        ),
        CLIConfigDescriptor(
            key: "power.appFilterMode",
            defaultsKey: "ocrAppFilterMode",
            category: "power",
            valueType: .string,
            allowedStringValues: OCRAppFilterMode.allCases.map(\.rawValue),
            defaultValue: { .string(OCRAppFilterMode.allApps.rawValue) }
        ),
        CLIConfigDescriptor(
            key: "power.filteredApps",
            defaultsKey: "ocrFilteredApps",
            category: "power",
            valueType: .string,
            defaultValue: { .string("") },
            note: "JSON-encoded app filter list."
        ),
        CLIConfigDescriptor(
            key: "power.autoMaxOCR",
            defaultsKey: "autoMaxOCR",
            category: "power",
            valueType: .bool,
            defaultValue: { .bool(false) }
        )
    ]

    private func configDescriptor(for rawKey: String) throws -> CLIConfigDescriptor {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.unknownConfigKey(rawKey)
        }

        guard let descriptor = Self.configDescriptors.first(where: { $0.matchesLookupKey(trimmed) }) else {
            throw CLIError.unknownConfigKey(trimmed)
        }

        return descriptor
    }

    private func configEntryOutput(for descriptor: CLIConfigDescriptor) -> CLIConfigEntryOutput {
        let currentValue = descriptor.currentValue(in: defaults)
        let defaultValue = descriptor.defaultValue()
        let aliases = descriptor.allAliases.filter {
            CLIConfigDescriptor.normalizedKey($0) != CLIConfigDescriptor.normalizedKey(descriptor.key)
        }

        return CLIConfigEntryOutput(
            key: descriptor.key,
            defaultsKey: descriptor.defaultsKey,
            aliases: aliases,
            category: descriptor.category,
            valueType: descriptor.valueType.rawValue,
            nullable: descriptor.nullable,
            currentValue: currentValue,
            defaultValue: defaultValue,
            currentIsDefault: currentValue == defaultValue,
            allowedValues: descriptor.allowedStringValues?.map { .string($0) },
            note: descriptor.note
        )
    }

    private func parsedConfigValue(
        _ rawValue: String,
        for descriptor: CLIConfigDescriptor
    ) throws -> CLIConfigValue {
        switch descriptor.valueType {
        case .bool:
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "1", "yes", "on":
                return .bool(true)
            case "false", "0", "no", "off":
                return .bool(false)
            default:
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["expected": "boolean"]
                )
            }
        case .int:
            guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["expected": "integer"]
                )
            }
            if let minimum = descriptor.minimumInt, value < minimum {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["reason": "Value must be >= \(minimum)"]
                )
            }
            if let maximum = descriptor.maximumInt, value > maximum {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["reason": "Value must be <= \(maximum)"]
                )
            }
            return .int(value)
        case .double:
            guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["expected": "number"]
                )
            }
            if let minimum = descriptor.minimumDouble, value < minimum {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["reason": "Value must be >= \(minimum)"]
                )
            }
            if let maximum = descriptor.maximumDouble, value > maximum {
                throw CLIError.invalidValue(
                    option: descriptor.key,
                    value: rawValue,
                    details: ["reason": "Value must be <= \(maximum)"]
                )
            }
            return .double(value)
        case .string:
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let allowedValues = descriptor.allowedStringValues {
                guard let matchedValue = allowedValues.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                    throw CLIError.invalidValue(
                        option: descriptor.key,
                        value: rawValue,
                        details: ["allowed": allowedValues.joined(separator: ", ")]
                    )
                }
                return .string(matchedValue)
            }
            if descriptor.nullable, trimmed.lowercased() == "null" {
                return .null
            }
            return .string(rawValue)
        case .date:
            if descriptor.nullable, rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "null" {
                return .null
            }
            let parsedDate = try timeParser.parseInstant(rawValue, optionName: descriptor.key)
            return .date(parsedDate)
        }
    }

    private func validateConfigValue(
        _ value: CLIConfigValue,
        for descriptor: CLIConfigDescriptor
    ) throws {
        if descriptor.defaultsKey == "phraseLevelRedactionEnabled",
           value == .bool(true),
           !MasterKeyManager.hasMasterKey() {
            throw CLIError.invalidValue(
                option: descriptor.key,
                value: "true",
                details: ["reason": "A master key must exist in Keychain before phrase-level redaction can be enabled"]
            )
        }
    }

    private func writeConfigValue(
        _ value: CLIConfigValue,
        for descriptor: CLIConfigDescriptor
    ) {
        switch value {
        case .null:
            defaults.removeObject(forKey: descriptor.defaultsKey)
        case .bool(let boolValue):
            defaults.set(boolValue, forKey: descriptor.defaultsKey)
        case .int(let intValue):
            defaults.set(intValue, forKey: descriptor.defaultsKey)
        case .double(let doubleValue):
            defaults.set(doubleValue, forKey: descriptor.defaultsKey)
        case .string(let stringValue):
            defaults.set(stringValue, forKey: descriptor.defaultsKey)
        case .date(let dateValue):
            if descriptor.defaultsKey == "rewindCutoffDate" {
                defaults.set(Calendar.current.startOfDay(for: dateValue), forKey: descriptor.defaultsKey)
            } else {
                defaults.set(dateValue, forKey: descriptor.defaultsKey)
            }
        }
    }

    private func requireCLIWritable(_ descriptor: CLIConfigDescriptor) throws {
        guard !["customRetraceDBLocation", "customRewindDBLocation", "encryptionEnabled"].contains(descriptor.defaultsKey) else {
            throw CLIError.usage("Change \(descriptor.key) in Retrace Settings so its validation and migration steps run.")
        }
    }

    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        if storedCoordinator == nil { storedCoordinator = try coordinatorFactory() }
        try await coordinator.initializeForCLI(includeRewind: defaults.bool(forKey: "useRewindData"))
        isInitialized = true
        await Self.flushPendingMetrics(coordinator: coordinator, defaults: defaults)
    }

    // Called only once a CLI query or normal app startup has initialized the database.
    public static func flushPendingMetrics(
        coordinator: AppCoordinator,
        defaults: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    ) async {
        var pending = defaults.stringArray(forKey: "cliPendingMetrics") ?? []
        while let metadata = pending.first {
            do {
                try await coordinator.recordMetricEvent(metricType: .cliCommandInvoked, metadata: metadata)
                pending.removeFirst()
                defaults.set(pending, forKey: "cliPendingMetrics")
            } catch { break }
        }
    }

    private func nearestFrame(to date: Date) async throws -> (matched: FrameReference?, previous: FrameReference?, next: FrameReference?) {
        async let exactFramesTask = coordinator.getFrames(
            from: date.addingTimeInterval(-0.5),
            to: date.addingTimeInterval(0.5),
            limit: 3
        )
        async let previousFramesTask = coordinator.getFramesBefore(timestamp: date, limit: 1)
        async let nextFramesTask = coordinator.getFramesAfter(timestamp: date, limit: 1)

        let exactFrames = try await exactFramesTask
        let previous = try await previousFramesTask.first
        let next = try await nextFramesTask.first

        let matched: FrameReference?
        if let exact = exactFrames.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) {
            matched = exact
        } else if let previous, let next {
            let previousDelta = abs(previous.timestamp.timeIntervalSince(date))
            let nextDelta = abs(next.timestamp.timeIntervalSince(date))
            matched = previousDelta <= nextDelta ? previous : next
        } else {
            matched = previous ?? next
        }

        return (matched: matched, previous: previous, next: next)
    }

    private func resolveFrameSelection(_ selector: CLIExtractSelector) async throws -> ResolvedCLIFrameSelection {
        switch selector {
        case .at(let timeReference):
            let nearestMatch = try await nearestFrame(to: timeReference.date)
            guard let matchedFrame = nearestMatch.matched else {
                throw CLIError.noFramesAvailable(timeReference.rawValue)
            }
            let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: matchedFrame.id)
            return ResolvedCLIFrameSelection(
                requestedAt: timeReference.rawValue,
                requestedFrameID: nil,
                requestedResultID: nil,
                frame: frameWithVideoInfo?.frame ?? matchedFrame,
                frameWithVideoInfo: frameWithVideoInfo
            )
        case .frameID(let frameID):
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                throw CLIError.frameNotFound(String(frameID))
            }
            return ResolvedCLIFrameSelection(
                requestedAt: nil,
                requestedFrameID: frameID,
                requestedResultID: nil,
                frame: frameWithVideoInfo.frame,
                frameWithVideoInfo: frameWithVideoInfo
            )
        case .resultID(let resultID):
            let storedResult = try resultStore.resolveLatestSearchResult(id: resultID)
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: storedResult.frameID)) else {
                throw CLIError.frameNotFound(String(storedResult.frameID))
            }
            return ResolvedCLIFrameSelection(
                requestedAt: nil,
                requestedFrameID: nil,
                requestedResultID: resultID,
                frame: frameWithVideoInfo.frame,
                frameWithVideoInfo: frameWithVideoInfo
            )
        }
    }

    private func resolveInspectFrameSelection(_ selector: CLIInspectFrameSelector) async throws -> ResolvedCLIFrameSelection {
        switch selector {
        case .frameID(let frameID):
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                throw CLIError.frameNotFound(String(frameID))
            }
            return ResolvedCLIFrameSelection(
                requestedAt: nil,
                requestedFrameID: frameID,
                requestedResultID: nil,
                frame: frameWithVideoInfo.frame,
                frameWithVideoInfo: frameWithVideoInfo
            )
        case .resultID(let resultID):
            let storedResult = try resultStore.resolveLatestSearchResult(id: resultID)
            guard let frameWithVideoInfo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: storedResult.frameID)) else {
                throw CLIError.frameNotFound(String(storedResult.frameID))
            }
            return ResolvedCLIFrameSelection(
                requestedAt: nil,
                requestedFrameID: nil,
                requestedResultID: resultID,
                frame: frameWithVideoInfo.frame,
                frameWithVideoInfo: frameWithVideoInfo
            )
        }
    }

    private func extractTargetOutput(from resolvedSelection: ResolvedCLIFrameSelection) -> CLIExtractTargetOutput {
        CLIExtractTargetOutput(
            requestedAt: resolvedSelection.requestedAt,
            requestedFrameID: resolvedSelection.requestedFrameID,
            requestedResultID: resolvedSelection.requestedResultID,
            matchedFrame: frameOutput(from: resolvedSelection.frame)
        )
    }

    private func joinedOCRText(_ nodes: [OCRNodeWithText]) -> String {
        nodes
            .sorted { $0.nodeOrder < $1.nodeOrder }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frameOutput(from frame: FrameReference) -> CLIFrameOutput {
        CLIFrameOutput(
            frameID: frame.id.value,
            timestamp: frame.timestamp,
            appBundleID: frame.metadata.appBundleID,
            appName: frame.metadata.appName,
            windowName: frame.metadata.windowName,
            browserURL: frame.metadata.browserURL,
            segmentID: frame.segmentID.value,
            videoID: frame.videoID.value,
            frameIndex: frame.frameIndexInSegment,
            source: frame.source
        )
    }

    private func frameOutput(from storedResult: CLISearchResultOutput) -> CLIFrameOutput {
        CLIFrameOutput(
            frameID: storedResult.frameID,
            timestamp: storedResult.timestamp,
            appBundleID: storedResult.appBundleID,
            appName: storedResult.appName,
            windowName: storedResult.windowName,
            browserURL: storedResult.browserURL,
            segmentID: storedResult.segmentID,
            videoID: storedResult.videoID,
            frameIndex: storedResult.frameIndex,
            source: storedResult.source
        )
    }

    private func inspectProcessOutput() -> CLIInspectProcessOutput {
        let processInfo = ProcessInfo.processInfo
        return CLIInspectProcessOutput(
            processID: processInfo.processIdentifier,
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            systemUptimeSeconds: processInfo.systemUptime,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateString(processInfo.thermalState)
        )
    }

    private func inspectPowerOutput(
        from powerState: (source: PowerStateMonitor.PowerSource, isPaused: Bool)
    ) -> CLIInspectPowerOutput {
        CLIInspectPowerOutput(
            source: powerSourceString(powerState.source),
            isPaused: powerState.isPaused,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private func inspectMemoryOutput(from snapshot: MemoryLedger.Snapshot) -> CLIInspectMemoryOutput {
        CLIInspectMemoryOutput(
            componentCount: snapshot.componentCount,
            trackedMemoryBytes: snapshot.trackedMemoryBytes,
            contextualBytes: snapshot.contextualBytes,
            trackedAllBytes: snapshot.trackedAllBytes,
            footprintBytes: snapshot.footprintBytes,
            residentBytes: snapshot.residentBytes,
            internalBytes: snapshot.internalBytes,
            compressedBytes: snapshot.compressedBytes,
            unattributedBytes: snapshot.unattributedBytes,
            topComponents: snapshot.components.prefix(10).map {
                CLIInspectMemoryComponentOutput(
                    tag: $0.tag,
                    category: $0.category.rawValue,
                    bytes: $0.bytes,
                    count: $0.count,
                    unit: $0.unit,
                    function: $0.function,
                    kind: $0.kind,
                    note: $0.note,
                    countsTowardTrackedMemory: $0.countsTowardTrackedMemory
                )
            },
            topFunctions: snapshot.functions.prefix(10).map {
                CLIInspectMemoryFunctionOutput(
                    function: $0.function,
                    trackedBytes: $0.trackedBytes,
                    contextualBytes: $0.contextualBytes,
                    componentCount: $0.componentCount
                )
            }
        )
    }

    private func inspectQueueOutput(from statistics: QueueStatistics) -> CLIInspectQueueStatisticsOutput {
        CLIInspectQueueStatisticsOutput(
            ocrQueueDepth: statistics.ocrQueueDepth,
            ocrPendingCount: statistics.ocrPendingCount,
            ocrProcessingCount: statistics.ocrProcessingCount,
            rewriteQueueDepth: statistics.rewriteQueueDepth,
            rewritePendingCount: statistics.rewritePendingCount,
            rewriteProcessingCount: statistics.rewriteProcessingCount,
            totalProcessed: statistics.totalProcessed,
            totalRewritten: statistics.totalRewritten,
            totalFailed: statistics.totalFailed,
            workerCount: statistics.workerCount
        )
    }

    private func inspectEncodingOutput(
        from statistics: (queueDepth: Int, pendingCount: Int)
    ) -> CLIInspectEncodingOutput {
        CLIInspectEncodingOutput(
            queueDepth: statistics.queueDepth,
            pendingCount: statistics.pendingCount
        )
    }

    private func inspectDatabaseOutput(from statistics: DatabaseStatistics) -> CLIInspectDatabaseOutput {
        CLIInspectDatabaseOutput(
            frameCount: statistics.frameCount,
            segmentCount: statistics.segmentCount,
            documentCount: statistics.documentCount,
            databaseSizeBytes: statistics.databaseSizeBytes,
            oldestFrameDate: statistics.oldestFrameDate,
            newestFrameDate: statistics.newestFrameDate
        )
    }

    private func inspectCaptureOutput(from statistics: CaptureStatistics) -> CLIInspectCaptureOutput {
        CLIInspectCaptureOutput(
            totalFramesCaptured: statistics.totalFramesCaptured,
            framesDeduped: statistics.framesDeduped,
            averageFrameSizeBytes: statistics.averageFrameSizeBytes,
            captureStartTime: statistics.captureStartTime,
            lastFrameTime: statistics.lastFrameTime
        )
    }

    private func inspectProcessingOutput(from statistics: ProcessingStatistics) -> CLIInspectProcessingOutput {
        CLIInspectProcessingOutput(
            framesProcessed: statistics.framesProcessed,
            averageOCRTimeMs: statistics.averageOCRTimeMs,
            averageTextLength: statistics.averageTextLength,
            errorCount: statistics.errorCount
        )
    }

    private func inspectSearchOutput(from statistics: SearchStatistics) -> CLIInspectSearchStatisticsOutput {
        CLIInspectSearchStatisticsOutput(
            totalDocuments: statistics.totalDocuments,
            totalSearches: statistics.totalSearches,
            averageSearchTimeMs: statistics.averageSearchTimeMs
        )
    }

    private func minuteCountOutputs(from counts: [Int: Int]) -> [CLIInspectMinuteCountOutput] {
        counts.keys.sorted().map { key in
            CLIInspectMinuteCountOutput(minuteOffset: key, count: counts[key] ?? 0)
        }
    }

    private func inspectOCRStatusOutput(from status: OCRProcessingStatus) -> CLIInspectOCRStatusOutput {
        let state: String
        switch status.state {
        case .completed:
            state = "completed"
        case .pending:
            state = "pending"
        case .queued:
            state = "queued"
        case .processing:
            state = "processing"
        case .rewriting:
            state = "rewriting"
        case .failed:
            state = "failed"
        case .unknown:
            state = "unknown"
        }

        return CLIInspectOCRStatusOutput(
            state: state,
            displayText: status.displayText,
            queuePosition: status.queuePosition,
            queueDepth: status.queueDepth,
            isInProgress: status.isInProgress
        )
    }

    private func powerSourceString(_ source: PowerStateMonitor.PowerSource) -> String {
        switch source {
        case .ac:
            return "ac"
        case .battery:
            return "battery"
        case .unknown:
            return "unknown"
        }
    }

    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func resolveApps(
        _ rawValues: [String],
        availableBundleIDs: [String]
    ) throws -> [String] {
        var resolved: [String] = []

        for rawValue in rawValues {
            if let bundleID = try resolveSingleApp(rawValue, availableBundleIDs: availableBundleIDs),
               !resolved.contains(bundleID) {
                resolved.append(bundleID)
            }
        }

        return resolved
    }

    private func resolveOptionalUsageApp(_ rawValue: String?) async throws -> String? {
        guard let normalized = normalizedFilterTerm(rawValue) else {
            return nil
        }
        return try await resolveUsageApp(normalized)
    }

    private func resolveUsageApp(_ rawValue: String) async throws -> String {
        let availableBundleIDs = try await coordinator.getDistinctAppBundleIDs()
        return try resolveSingleApp(rawValue, availableBundleIDs: availableBundleIDs) ?? rawValue
    }

    func resolveSingleApp(
        _ rawValue: String,
        availableBundleIDs: [String]
    ) throws -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let exactMatch = availableBundleIDs.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exactMatch
        }

        let normalizedQuery = normalizedLookupKey(trimmed)
        let suffixMatches = availableBundleIDs.filter {
            normalizedLookupKey(bundleIDSuffixComponent($0)) == normalizedQuery
        }
        if suffixMatches.count == 1 {
            return suffixMatches[0]
        }

        let matches = availableBundleIDs.filter {
            normalizedLookupKey($0).contains(normalizedQuery)
        }
        let nonExtensionMatches = matches.filter { !$0.contains(".app.") }

        switch nonExtensionMatches.count {
        case 1:
            return nonExtensionMatches[0]
        case let count where count > 1:
            throw CLIError.ambiguousApp(rawValue, matches: nonExtensionMatches.sorted())
        default:
            break
        }

        switch matches.count {
        case 0:
            if trimmed.contains(".") {
                return trimmed
            }
            throw CLIError.appNotFound(rawValue)
        case 1:
            return matches[0]
        default:
            throw CLIError.ambiguousApp(rawValue, matches: matches.sorted())
        }
    }

    func bundleIDSuffixComponent(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private func resolveTagIDs(_ rawValues: [String], tags: [Tag]) throws -> [Int64] {
        var resolved: [Int64] = []

        for rawValue in rawValues {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let exactMatches = tags.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            if let exactMatch = exactMatches.first {
                if !resolved.contains(exactMatch.id.value) {
                    resolved.append(exactMatch.id.value)
                }
                continue
            }

            let normalizedQuery = normalizedLookupKey(trimmed)
            let fuzzyMatches = tags.filter { normalizedLookupKey($0.name).contains(normalizedQuery) }

            switch fuzzyMatches.count {
            case 0:
                throw CLIError.tagNotFound(rawValue)
            case 1:
                let tagID = fuzzyMatches[0].id.value
                if !resolved.contains(tagID) {
                    resolved.append(tagID)
                }
            default:
                throw CLIError.ambiguousTag(rawValue, matches: fuzzyMatches.map(\.name).sorted())
            }
        }

        return resolved
    }

    private func searchDeeplinkState(from request: CLIOpenSearchRequest) async throws -> CLIDeeplinkSearchState {
        let availableBundleIDs = try await coordinator.getDistinctAppBundleIDs()

        let appBundleIDs: [String]
        let appFilterMode: AppFilterMode
        if !request.includeApps.isEmpty {
            appBundleIDs = try resolveApps(request.includeApps, availableBundleIDs: availableBundleIDs)
            appFilterMode = .include
        } else if !request.excludeApps.isEmpty {
            appBundleIDs = try resolveApps(request.excludeApps, availableBundleIDs: availableBundleIDs)
            appFilterMode = .exclude
        } else {
            appBundleIDs = []
            appFilterMode = .include
        }

        let allTags = try await coordinator.getAllTags()

        let tagIDs: [Int64]
        let tagFilterMode: TagFilterMode
        if !request.includeTagNames.isEmpty {
            tagIDs = try resolveTagIDs(request.includeTagNames, tags: allTags)
            tagFilterMode = .include
        } else if !request.excludeTagNames.isEmpty {
            tagIDs = try resolveTagIDs(request.excludeTagNames, tags: allTags)
            tagFilterMode = .exclude
        } else {
            tagIDs = []
            tagFilterMode = .include
        }

        return CLIDeeplinkSearchState(
            queryText: normalizedSearchText(request.queryText, exact: request.exact),
            appBundleIDs: appBundleIDs,
            appFilterMode: appFilterMode,
            tagIDs: tagIDs,
            tagFilterMode: tagFilterMode,
            hiddenFilter: request.hiddenFilter,
            commentFilter: request.commentFilter,
            dateRanges: request.ranges,
            windowNameTerms: request.includeWindowTerms,
            windowNameExcludedTerms: request.excludeWindowTerms,
            browserURLTerms: request.includeURLTerms,
            browserURLExcludedTerms: request.excludeURLTerms,
            sort: request.sort,
            timestamp: request.timestamp?.date
        )
    }

    private func normalizedUsageSessionRows(
        for request: CLIUsageSessionsRequest
    ) async throws -> (
        resolvedApp: String?,
        normalizedWindowFilter: String?,
        normalizedWebsiteFilter: String?,
        rows: [CLIUsageSessionRowOutput]
    ) {
        let resolvedApp = try await resolveOptionalUsageApp(request.app)
        let normalizedWindowFilter = normalizedFilterTerm(request.window)
        let normalizedWebsiteFilter = normalizedFilterTerm(request.website)
        let hiddenSegmentIDs = try await coordinator.getHiddenSegmentIds().reduce(into: Set<Int64>()) { partialResult, segmentID in
            partialResult.insert(segmentID.value)
        }

        let segments = try await coordinator.getSegments(
            from: request.timeRange.from.date,
            to: request.timeRange.to.date
        )
        let rows = segments
            .sorted { $0.startDate < $1.startDate }
            .compactMap { segment -> CLIUsageSessionRowOutput? in
                let effectiveStart = max(segment.startDate, request.timeRange.from.date)
                let effectiveEnd = min(segment.endDate, request.timeRange.to.date)
                guard effectiveStart < effectiveEnd else { return nil }

                let isHidden = hiddenSegmentIDs.contains(segment.id.value)
                switch request.hiddenFilter {
                case .hide:
                    guard !isHidden else { return nil }
                case .onlyHidden:
                    guard isHidden else { return nil }
                case .showAll:
                    break
                }

                if let resolvedApp, segment.bundleID.caseInsensitiveCompare(resolvedApp) != .orderedSame {
                    return nil
                }

                if let normalizedWindowFilter,
                   let windowName = segment.windowName?.lowercased(),
                   !windowName.contains(normalizedWindowFilter) {
                    return nil
                } else if normalizedWindowFilter != nil, segment.windowName == nil {
                    return nil
                }

                let website = Self.normalizedWebsite(from: segment.browserUrl)
                if let normalizedWebsiteFilter,
                   !Self.matchesWebsiteFilter(
                    normalizedWebsiteFilter,
                    website: website,
                    browserURL: segment.browserUrl
                   ) {
                    return nil
                }

                return CLIUsageSessionRowOutput(
                    segmentID: segment.id.value,
                    bundleID: segment.bundleID,
                    isBrowser: AppInfo.browserBundleIDs.contains(segment.bundleID),
                    segmentStart: segment.startDate,
                    segmentEnd: segment.endDate,
                    effectiveStart: effectiveStart,
                    effectiveEnd: effectiveEnd,
                    segmentDurationSeconds: segment.duration,
                    effectiveDurationSeconds: effectiveEnd.timeIntervalSince(effectiveStart),
                    windowName: segment.windowName,
                    browserURL: segment.browserUrl,
                    website: website,
                    isHidden: isHidden,
                    type: segment.type
                )
            }

        return (
            resolvedApp: resolvedApp,
            normalizedWindowFilter: normalizedWindowFilter,
            normalizedWebsiteFilter: normalizedWebsiteFilter,
            rows: rows
        )
    }

    private func normalizedSearchText(_ rawText: String, exact: Bool) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exact else { return trimmed }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return trimmed
        }

        let sanitized = trimmed.replacingOccurrences(of: "\"", with: "")
        return "\"\(sanitized)\""
    }

    private func mapSort(_ sort: CLISearchSort) -> (mode: SearchMode, sortOrder: SearchSortOrder) {
        switch sort {
        case .relevance:
            return (.relevant, .newestFirst)
        case .newest:
            return (.all, .newestFirst)
        case .oldest:
            return (.all, .oldestFirst)
        }
    }

    private func resolvedAppDisplayName(for bundleID: String) -> String {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: applicationURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !bundleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return bundleName
            }
        }

        let suffix = bundleIDSuffixComponent(bundleID)
        guard !suffix.isEmpty else {
            return bundleID
        }

        return suffix
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func searchOptionHelp(includeLimit: Bool) -> [CLIHelpOptionOutput] {
        var options: [CLIHelpOptionOutput] = [
            CLIHelpOptionOutput(flag: "--exact", description: "Treat the query as an exact phrase if it is not already quoted."),
            CLIHelpOptionOutput(flag: "--app", valueName: "bundle-or-name", repeatable: true, description: "Include matching apps."),
            CLIHelpOptionOutput(flag: "--not-app", valueName: "bundle-or-name", repeatable: true, description: "Exclude matching apps. `open --query` does not allow mixing this with `--app`."),
            CLIHelpOptionOutput(flag: "--range", valueName: "start..end", repeatable: true, description: "Restrict search to a date range. Up to 5 ranges."),
            CLIHelpOptionOutput(flag: "--url", valueName: "term", repeatable: true, description: "Require URL substring matches."),
            CLIHelpOptionOutput(flag: "--not-url", valueName: "term", repeatable: true, description: "Exclude URL substring matches."),
            CLIHelpOptionOutput(flag: "--window", valueName: "term", repeatable: true, description: "Require window-title matches."),
            CLIHelpOptionOutput(flag: "--not-window", valueName: "term", repeatable: true, description: "Exclude window-title matches."),
            CLIHelpOptionOutput(flag: "--tag", valueName: "tag", repeatable: true, description: "Include matching tags."),
            CLIHelpOptionOutput(flag: "--not-tag", valueName: "tag", repeatable: true, description: "Exclude matching tags. `open --query` does not allow mixing this with `--tag`."),
            CLIHelpOptionOutput(flag: "--commented", description: "Only include frames with comments."),
            CLIHelpOptionOutput(flag: "--uncommented", description: "Only include frames without comments."),
            CLIHelpOptionOutput(flag: "--hidden", valueName: "hide|show|only", description: "Control hidden-frame visibility."),
            CLIHelpOptionOutput(flag: "--sort", valueName: "relevance|newest|oldest", description: "Choose result ordering.")
        ]

        if includeLimit {
            options.append(CLIHelpOptionOutput(flag: "--limit", valueName: "n", description: "Limit returned results."))
        }

        return options
    }

    private static let bashCompletionScript = """
    _retrace_completions() {
      local cur prev words cword
      _init_completion || return
      local commands="status apps search jump around open config usage extract inspect help completions"

      if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
      fi

      case "${words[1]}" in
        apps)
          COMPREPLY=( $(compgen -W "list" -- "$cur") )
          ;;
        usage)
          COMPREPLY=( $(compgen -W "apps websites tabs sessions screen-time switches" -- "$cur") )
          ;;
        extract)
          COMPREPLY=( $(compgen -W "text url links ocr image" -- "$cur") )
          ;;
        inspect)
          COMPREPLY=( $(compgen -W "system ocr queue storage metrics frame" -- "$cur") )
          ;;
        config)
          COMPREPLY=( $(compgen -W "list get set reset" -- "$cur") )
          ;;
        completions)
          COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
          ;;
      esac
    }
    complete -F _retrace_completions retrace
    """

    private static let zshCompletionScript = """
    #compdef retrace
    local -a commands
    commands=(
      'status:Show storage and capture status'
      'apps:List known apps'
      'search:Search history'
      'jump:Jump to a time'
      'around:Inspect surrounding frames'
      'open:Open Retrace'
      'config:View or change settings'
      'usage:Summarize usage'
      'extract:Recover artifacts'
      'inspect:Inspect Retrace health'
      'help:Show CLI help'
      'completions:Generate completion scripts'
    )

    local curcontext="$curcontext" state line
    _arguments -C \
      '1:command:->command' \
      '2:subcommand:->subcommand'

    case $state in
      command)
        _describe 'command' commands
        ;;
      subcommand)
        case $words[2] in
          apps) _describe 'subcommand' 'list:List known apps' ;;
          usage) _describe 'subcommand' 'apps:Apps' 'websites:Websites' 'tabs:Tabs' 'sessions:Sessions' 'screen-time:Screen time' 'switches:Switches' ;;
          extract) _describe 'subcommand' 'text:Text' 'url:URL' 'links:Links' 'ocr:OCR' 'image:Image' ;;
          inspect) _describe 'subcommand' 'system:System' 'ocr:OCR' 'queue:Queue' 'storage:Storage' 'metrics:Metrics' 'frame:Frame' ;;
          config) _describe 'subcommand' 'list:List' 'get:Get' 'set:Set' 'reset:Reset' ;;
          completions) _describe 'shell' 'bash:Bash' 'zsh:Zsh' 'fish:Fish' ;;
        esac
        ;;
    esac
    """

    private static let fishCompletionScript = """
    complete -c retrace -f
    complete -c retrace -n '__fish_use_subcommand' -a 'status apps search jump around open config usage extract inspect help completions'
    complete -c retrace -n '__fish_seen_subcommand_from apps' -a 'list'
    complete -c retrace -n '__fish_seen_subcommand_from usage' -a 'apps websites tabs sessions screen-time switches'
    complete -c retrace -n '__fish_seen_subcommand_from extract' -a 'text url links ocr image'
    complete -c retrace -n '__fish_seen_subcommand_from inspect' -a 'system ocr queue storage metrics frame'
    complete -c retrace -n '__fish_seen_subcommand_from config' -a 'list get set reset'
    complete -c retrace -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'
    """

    private static func normalizedMetadataTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                normalized.append(trimmed)
            }
        }

        return normalized
    }

    private func usageTimeWindowOutput(_ timeRange: CLIUsageTimeRange) -> CLIUsageTimeWindowOutput {
        CLIUsageTimeWindowOutput(
            requestedFrom: timeRange.from.rawValue,
            requestedTo: timeRange.to.rawValue,
            resolvedFrom: timeRange.from.date,
            resolvedTo: timeRange.to.date
        )
    }

    private func normalizedFilterTerm(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func normalizedWebsite(from rawURL: String?) -> String? {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return nil
        }

        var candidate = rawURL
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        if let host = URLComponents(string: candidate)?.host?.lowercased() {
            if host.hasPrefix("www.") {
                return String(host.dropFirst(4))
            }
            return host
        }

        let hostCandidate = candidate
            .components(separatedBy: "://")
            .last?
            .components(separatedBy: "/")
            .first?
            .components(separatedBy: "?")
            .first?
            .lowercased()

        if let hostCandidate, hostCandidate.hasPrefix("www.") {
            return String(hostCandidate.dropFirst(4))
        }
        return hostCandidate
    }

    private static func matchesWebsiteFilter(
        _ filter: String,
        website: String?,
        browserURL: String?
    ) -> Bool {
        if let website, website.contains(filter) {
            return true
        }
        if let browserURL = browserURL?.lowercased(), browserURL.contains(filter) {
            return true
        }
        return false
    }

    private func normalizedLookupKey(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func recordCLICommandMetric(command: String, payload: [String: Any]) async throws {
        let safeKeys: Set<String> = ["source", "key", "changed", "entryCount", "resultCount", "limit", "offset", "filterCount", "hasWebsiteFilter", "hasQueueStats", "hasEncodingStats", "frameID", "byteCount"]
        let safePayload = payload.filter { safeKeys.contains($0.key) }
        let metadata = Self.metricMetadata(safePayload.merging(["command": command]) { _, new in new })
        if isInitialized {
            try await coordinator.recordMetricEvent(metricType: .cliCommandInvoked, metadata: metadata)
        } else if let metadata {
            var pending = defaults.stringArray(forKey: "cliPendingMetrics") ?? []
            pending.append(metadata)
            defaults.set(Array(pending.suffix(128)), forKey: "cliPendingMetrics")
        }
    }

    private static func metricMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLIError.usage("Failed to encode JSON metadata.")
        }
        return json
    }
}
