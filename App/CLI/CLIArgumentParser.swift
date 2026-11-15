import Foundation
import Shared

public struct CLIArgumentParser {
    private static let maxSearchRanges = 5
    static let topLevelCommands = "status, apps, search, jump, around, open, config, usage, extract, inspect, help, completions"
    private let timeParser: CLITimeParser

    public init(timeParser: CLITimeParser = CLITimeParser()) {
        self.timeParser = timeParser
    }

    public func parse(arguments: [String]) throws -> CLICommand {
        if arguments.isEmpty {
            throw CLIError.usage(
                "Expected a command.",
                details: ["commands": Self.topLevelCommands]
            )
        }

        if let helpCommand = helpCommandIfNeeded(arguments: arguments) {
            return helpCommand
        }

        guard let command = arguments.first else {
            throw CLIError.usage(
                "Expected a command.",
                details: ["commands": Self.topLevelCommands]
            )
        }

        switch command {
        case "status":
            guard arguments.count == 1 else {
                throw CLIError.usage("`status` does not accept additional arguments.")
            }
            return .status
        case "apps":
            return .apps(try parseApps(arguments: Array(arguments.dropFirst())))
        case "search":
            return .search(try parseSearch(arguments: Array(arguments.dropFirst())))
        case "jump":
            return .jump(try parseJump(arguments: Array(arguments.dropFirst())))
        case "around":
            return .around(try parseAround(arguments: Array(arguments.dropFirst())))
        case "open":
            return .open(try parseOpen(arguments: Array(arguments.dropFirst())))
        case "config":
            return .config(try parseConfig(arguments: Array(arguments.dropFirst())))
        case "usage":
            return .usage(try parseUsage(arguments: Array(arguments.dropFirst())))
        case "extract":
            return .extract(try parseExtract(arguments: Array(arguments.dropFirst())))
        case "inspect":
            return .inspect(try parseInspect(arguments: Array(arguments.dropFirst())))
        case "help":
            return .help(try parseHelp(arguments: Array(arguments.dropFirst())))
        case "completions":
            return .completions(try parseCompletions(arguments: Array(arguments.dropFirst())))
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private func helpCommandIfNeeded(arguments: [String]) -> CLICommand? {
        guard !arguments.isEmpty else { return nil }

        if arguments == ["--help"] || arguments == ["-h"] {
            return .help(CLIHelpRequest())
        }

        guard let last = arguments.last, last == "--help" || last == "-h" else {
            return nil
        }

        let topicPath = Array(arguments.dropLast())
        return .help(CLIHelpRequest(topicPath: topicPath))
    }

    private func parseSearch(arguments: [String]) throws -> CLISearchRequest {
        var cursor = ArgumentCursor(arguments: arguments)

        var exact = false
        var includeApps: [String] = []
        var excludeApps: [String] = []
        var ranges: [DateRangeCriterion] = []
        var includeURLTerms: [String] = []
        var excludeURLTerms: [String] = []
        var includeWindowTerms: [String] = []
        var excludeWindowTerms: [String] = []
        var includeTagNames: [String] = []
        var excludeTagNames: [String] = []
        var commentFilter: CommentFilter = .allFrames
        var hiddenFilter: HiddenFilter = .hide
        var sort: CLISearchSort = .relevance
        var limit = 50
        var queryTerms: [String] = []

        while let argument = cursor.next() {
            switch argument {
            case "--exact":
                exact = true
            case "--app":
                includeApps.append(try cursor.requireValue(for: argument))
            case "--not-app":
                excludeApps.append(try cursor.requireValue(for: argument))
            case "--range":
                ranges.append(try timeParser.parseRange(try cursor.requireValue(for: argument)))
            case "--url":
                includeURLTerms.append(try cursor.requireValue(for: argument))
            case "--not-url":
                excludeURLTerms.append(try cursor.requireValue(for: argument))
            case "--window":
                includeWindowTerms.append(try cursor.requireValue(for: argument))
            case "--not-window":
                excludeWindowTerms.append(try cursor.requireValue(for: argument))
            case "--tag":
                includeTagNames.append(try cursor.requireValue(for: argument))
            case "--not-tag":
                excludeTagNames.append(try cursor.requireValue(for: argument))
            case "--commented":
                guard commentFilter != .noComments else {
                    throw CLIError.conflictingFlags("--commented", "--uncommented")
                }
                commentFilter = .commentsOnly
            case "--uncommented":
                guard commentFilter != .commentsOnly else {
                    throw CLIError.conflictingFlags("--commented", "--uncommented")
                }
                commentFilter = .noComments
            case "--hidden":
                hiddenFilter = try parseHiddenFilter(try cursor.requireValue(for: argument))
            case "--sort":
                sort = try parseSort(try cursor.requireValue(for: argument))
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "search")
                }
                queryTerms.append(argument)
            }
        }

        guard !queryTerms.isEmpty else {
            throw CLIError.usage("`search` requires a query string.")
        }

        guard ranges.count <= Self.maxSearchRanges else {
            throw CLIError.tooManyRanges(maximum: Self.maxSearchRanges)
        }

        return CLISearchRequest(
            queryText: queryTerms.joined(separator: " "),
            exact: exact,
            includeApps: deduplicated(includeApps),
            excludeApps: deduplicated(excludeApps),
            ranges: ranges,
            includeURLTerms: deduplicated(includeURLTerms),
            excludeURLTerms: deduplicated(excludeURLTerms),
            includeWindowTerms: deduplicated(includeWindowTerms),
            excludeWindowTerms: deduplicated(excludeWindowTerms),
            includeTagNames: deduplicated(includeTagNames),
            excludeTagNames: deduplicated(excludeTagNames),
            commentFilter: commentFilter,
            hiddenFilter: hiddenFilter,
            sort: sort,
            limit: limit
        )
    }

    private func parseJump(arguments: [String]) throws -> CLIJumpRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var target: CLITimeReference?

        while let argument = cursor.next() {
            switch argument {
            case "--at":
                let rawValue = try cursor.requireValue(for: argument)
                target = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--at")
                )
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "jump")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `jump`.")
            }
        }

        guard let target else {
            throw CLIError.usage("`jump` requires `--at <time>`.")
        }

        return CLIJumpRequest(target: target)
    }

    private func parseApps(arguments: [String]) throws -> CLIAppsRequest {
        guard let subcommand = arguments.first else {
            throw CLIError.usage(
                "`apps` requires a subcommand.",
                details: ["subcommands": "list"]
            )
        }

        let remainingArguments = Array(arguments.dropFirst())
        switch subcommand {
        case "list":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`apps list` does not accept additional arguments.")
            }
            return .list(CLIAppsListRequest())
        default:
            throw CLIError.unknownOption(subcommand, command: "apps")
        }
    }

    private func parseAround(arguments: [String]) throws -> CLIAroundRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var anchor: CLIAroundAnchor?
        var beforeCount = 10
        var afterCount = 10

        while let argument = cursor.next() {
            switch argument {
            case "--at":
                guard anchor == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "around",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                let rawValue = try cursor.requireValue(for: argument)
                anchor = .at(
                    CLITimeReference(
                        rawValue: rawValue,
                        date: try timeParser.parseInstant(rawValue, optionName: "--at")
                    )
                )
            case "--frame":
                guard anchor == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "around",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                anchor = .frameID(try parseFrameID(try cursor.requireValue(for: argument), option: argument))
            case "--result":
                guard anchor == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "around",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                anchor = .resultID(try parseResultID(try cursor.requireValue(for: argument), option: argument))
            case "--before":
                beforeCount = try parseCount(try cursor.requireValue(for: argument), option: argument)
            case "--after":
                afterCount = try parseCount(try cursor.requireValue(for: argument), option: argument)
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "around")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `around`.")
            }
        }

        guard let anchor else {
            throw CLIError.usage("`around` requires one of `--at <time>`, `--frame <id>`, or `--result <n>`.")
        }

        return CLIAroundRequest(anchor: anchor, beforeCount: beforeCount, afterCount: afterCount)
    }

    private func parseOpen(arguments: [String]) throws -> CLIOpenRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var frameID: Int64?
        var resultID: Int?
        var timeReference: CLITimeReference?
        var query: String?
        var exact = false
        var includeApps: [String] = []
        var excludeApps: [String] = []
        var ranges: [DateRangeCriterion] = []
        var includeURLTerms: [String] = []
        var excludeURLTerms: [String] = []
        var includeWindowTerms: [String] = []
        var excludeWindowTerms: [String] = []
        var includeTagNames: [String] = []
        var excludeTagNames: [String] = []
        var commentFilter: CommentFilter = .allFrames
        var hiddenFilter: HiddenFilter = .hide
        var sort: CLISearchSort = .relevance

        while let argument = cursor.next() {
            switch argument {
            case "--frame":
                let value = try parseFrameID(try cursor.requireValue(for: argument), option: argument)
                guard frameID == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "open",
                        details: ["selectors": "Only one --frame value is allowed"]
                    )
                }
                frameID = value
            case "--result":
                let value = try parseResultID(try cursor.requireValue(for: argument), option: argument)
                guard resultID == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "open",
                        details: ["selectors": "Only one --result value is allowed"]
                    )
                }
                resultID = value
            case "--at":
                let rawValue = try cursor.requireValue(for: argument)
                timeReference = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--at")
                )
            case "--query":
                query = try cursor.requireValue(for: argument)
            case "--exact":
                exact = true
            case "--app":
                includeApps.append(try cursor.requireValue(for: argument))
            case "--not-app":
                excludeApps.append(try cursor.requireValue(for: argument))
            case "--range":
                ranges.append(try timeParser.parseRange(try cursor.requireValue(for: argument)))
            case "--url":
                includeURLTerms.append(try cursor.requireValue(for: argument))
            case "--not-url":
                excludeURLTerms.append(try cursor.requireValue(for: argument))
            case "--window":
                includeWindowTerms.append(try cursor.requireValue(for: argument))
            case "--not-window":
                excludeWindowTerms.append(try cursor.requireValue(for: argument))
            case "--tag":
                includeTagNames.append(try cursor.requireValue(for: argument))
            case "--not-tag":
                excludeTagNames.append(try cursor.requireValue(for: argument))
            case "--commented":
                guard commentFilter != .noComments else {
                    throw CLIError.conflictingFlags("--commented", "--uncommented")
                }
                commentFilter = .commentsOnly
            case "--uncommented":
                guard commentFilter != .commentsOnly else {
                    throw CLIError.conflictingFlags("--commented", "--uncommented")
                }
                commentFilter = .noComments
            case "--hidden":
                hiddenFilter = try parseHiddenFilter(try cursor.requireValue(for: argument))
            case "--sort":
                sort = try parseSort(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "open")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `open`.")
            }
        }

        guard ranges.count <= Self.maxSearchRanges else {
            throw CLIError.tooManyRanges(maximum: Self.maxSearchRanges)
        }

        if let resultID {
            guard frameID == nil,
                  query == nil,
                  timeReference == nil,
                  includeApps.isEmpty,
                  excludeApps.isEmpty,
                  ranges.isEmpty,
                  includeURLTerms.isEmpty,
                  excludeURLTerms.isEmpty,
                  includeWindowTerms.isEmpty,
                  excludeWindowTerms.isEmpty,
                  includeTagNames.isEmpty,
                  excludeTagNames.isEmpty,
                  commentFilter == .allFrames,
                  hiddenFilter == .hide,
                  sort == .relevance,
                  exact == false else {
                throw CLIError.invalidSelectorCombination(
                    command: "open",
                    details: ["selectors": "`--result` cannot be combined with other open selectors or search filters"]
                )
            }
            return CLIOpenRequest(selector: .resultID(resultID))
        }

        if let frameID {
            guard query == nil,
                  timeReference == nil,
                  resultID == nil,
                  includeApps.isEmpty,
                  excludeApps.isEmpty,
                  ranges.isEmpty,
                  includeURLTerms.isEmpty,
                  excludeURLTerms.isEmpty,
                  includeWindowTerms.isEmpty,
                  excludeWindowTerms.isEmpty,
                  includeTagNames.isEmpty,
                  excludeTagNames.isEmpty,
                  commentFilter == .allFrames,
                  hiddenFilter == .hide,
                  sort == .relevance,
                  exact == false else {
                throw CLIError.invalidSelectorCombination(
                    command: "open",
                    details: ["selectors": "`--frame` cannot be combined with other open selectors or search filters"]
                )
            }
            return CLIOpenRequest(selector: .frameID(frameID))
        }

        if let query {
            let normalizedIncludeApps = deduplicated(includeApps)
            let normalizedExcludeApps = deduplicated(excludeApps)
            let normalizedIncludeTags = deduplicated(includeTagNames)
            let normalizedExcludeTags = deduplicated(excludeTagNames)

            if !normalizedIncludeApps.isEmpty && !normalizedExcludeApps.isEmpty {
                throw CLIError.invalidSelectorCombination(
                    command: "open",
                    details: ["filters": "`open --query` supports either include or exclude app filters, not both"]
                )
            }
            if !normalizedIncludeTags.isEmpty && !normalizedExcludeTags.isEmpty {
                throw CLIError.invalidSelectorCombination(
                    command: "open",
                    details: ["filters": "`open --query` supports either include or exclude tag filters, not both"]
                )
            }

            return CLIOpenRequest(
                selector: .search(
                    CLIOpenSearchRequest(
                        queryText: query,
                        exact: exact,
                        includeApps: normalizedIncludeApps,
                        excludeApps: normalizedExcludeApps,
                        ranges: ranges,
                        includeURLTerms: deduplicated(includeURLTerms),
                        excludeURLTerms: deduplicated(excludeURLTerms),
                        includeWindowTerms: deduplicated(includeWindowTerms),
                        excludeWindowTerms: deduplicated(excludeWindowTerms),
                        includeTagNames: normalizedIncludeTags,
                        excludeTagNames: normalizedExcludeTags,
                        commentFilter: commentFilter,
                        hiddenFilter: hiddenFilter,
                        sort: sort,
                        timestamp: timeReference
                    )
                )
            )
        }

        if let timeReference {
            guard includeApps.isEmpty,
                  excludeApps.isEmpty,
                  ranges.isEmpty,
                  includeURLTerms.isEmpty,
                  excludeURLTerms.isEmpty,
                  includeWindowTerms.isEmpty,
                  excludeWindowTerms.isEmpty,
                  includeTagNames.isEmpty,
                  excludeTagNames.isEmpty,
                  commentFilter == .allFrames,
                  hiddenFilter == .hide,
                  sort == .relevance,
                  exact == false else {
                throw CLIError.invalidSelectorCombination(
                    command: "open",
                    details: ["selectors": "Search filters require `--query`"]
                )
            }
            return CLIOpenRequest(selector: .timeline(timeReference))
        }

        throw CLIError.usage(
            "`open` requires one of `--result <n>`, `--frame <id>`, `--at <time>`, or `--query <text>`."
        )
    }

    private func parseHelp(arguments: [String]) throws -> CLIHelpRequest {
        guard !arguments.contains(where: { $0 == "--help" || $0 == "-h" }) else {
            throw CLIError.usage("`help` does not accept `--help`; use `help <topic>`.")
        }
        return CLIHelpRequest(topicPath: arguments)
    }

    private func parseCompletions(arguments: [String]) throws -> CLICompletionsRequest {
        guard arguments.count == 1 else {
            throw CLIError.usage(
                "`completions` requires exactly one shell.",
                details: ["allowed": CLICompletionShell.allCases.map(\.rawValue).joined(separator: ", ")]
            )
        }

        guard let shell = CLICompletionShell(rawValue: arguments[0].lowercased()) else {
            throw CLIError.invalidValue(
                option: "shell",
                value: arguments[0],
                details: ["allowed": CLICompletionShell.allCases.map(\.rawValue).joined(separator: ", ")]
            )
        }

        return CLICompletionsRequest(shell: shell)
    }

    private func parseConfig(arguments: [String]) throws -> CLIConfigRequest {
        guard let subcommand = arguments.first else {
            throw CLIError.usage(
                "`config` requires a subcommand.",
                details: ["subcommands": "list, get, set, reset"]
            )
        }

        let remainingArguments = Array(arguments.dropFirst())
        switch subcommand {
        case "list":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`config list` does not accept additional arguments.")
            }
            return .list
        case "get":
            guard remainingArguments.count == 1 else {
                throw CLIError.usage("`config get` requires exactly one `<key>` argument.")
            }
            return .get(CLIConfigKeyRequest(key: remainingArguments[0]))
        case "set":
            guard remainingArguments.count >= 2 else {
                throw CLIError.usage("`config set` requires `<key> <value>`.")
            }
            return .set(
                CLIConfigSetRequest(
                    key: remainingArguments[0],
                    value: Array(remainingArguments.dropFirst()).joined(separator: " ")
                )
            )
        case "reset":
            guard remainingArguments.count == 1 else {
                throw CLIError.usage("`config reset` requires exactly one `<key>` argument.")
            }
            return .reset(CLIConfigKeyRequest(key: remainingArguments[0]))
        default:
            throw CLIError.unknownOption(subcommand, command: "config")
        }
    }

    private func parseUsage(arguments: [String]) throws -> CLIUsageRequest {
        guard let subcommand = arguments.first else {
            throw CLIError.usage(
                "`usage` requires a subcommand.",
                details: ["subcommands": "apps, websites, tabs, sessions, screen-time, switches"]
            )
        }

        let remainingArguments = Array(arguments.dropFirst())

        switch subcommand {
        case "apps":
            return .apps(try parseUsageApps(arguments: remainingArguments))
        case "websites":
            return .websites(try parseUsageWebsites(arguments: remainingArguments))
        case "tabs":
            return .tabs(try parseUsageTabs(arguments: remainingArguments))
        case "sessions":
            return .sessions(try parseUsageSessions(arguments: remainingArguments))
        case "screen-time":
            return .screenTime(try parseUsageScreenTime(arguments: remainingArguments))
        case "switches":
            return .switches(try parseUsageSwitches(arguments: remainingArguments))
        default:
            throw CLIError.unknownOption(subcommand, command: "usage")
        }
    }

    private func parseExtract(arguments: [String]) throws -> CLIExtractRequest {
        guard let subcommand = arguments.first else {
            throw CLIError.usage(
                "`extract` requires a subcommand.",
                details: ["subcommands": "text, url, links, ocr, image"]
            )
        }

        let remainingArguments = Array(arguments.dropFirst())
        switch subcommand {
        case "text":
            return .text(CLIExtractTextRequest(selector: try parseExtractSelector(arguments: remainingArguments, command: "extract text")))
        case "url":
            return .url(CLIExtractURLRequest(selector: try parseExtractSelector(arguments: remainingArguments, command: "extract url")))
        case "links":
            return .links(CLIExtractLinksRequest(selector: try parseExtractSelector(arguments: remainingArguments, command: "extract links")))
        case "ocr":
            return .ocr(CLIExtractOCRRequest(selector: try parseExtractSelector(arguments: remainingArguments, command: "extract ocr")))
        case "image":
            return .image(try parseExtractImage(arguments: remainingArguments))
        default:
            throw CLIError.unknownOption(subcommand, command: "extract")
        }
    }

    private func parseInspect(arguments: [String]) throws -> CLIInspectRequest {
        guard let subcommand = arguments.first else {
            throw CLIError.usage(
                "`inspect` requires a subcommand.",
                details: ["subcommands": "system, ocr, queue, storage, metrics, frame"]
            )
        }

        let remainingArguments = Array(arguments.dropFirst())
        switch subcommand {
        case "system":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`inspect system` does not accept additional arguments.")
            }
            return .system
        case "ocr":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`inspect ocr` does not accept additional arguments.")
            }
            return .ocr
        case "queue":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`inspect queue` does not accept additional arguments.")
            }
            return .queue
        case "storage":
            guard remainingArguments.isEmpty else {
                throw CLIError.usage("`inspect storage` does not accept additional arguments.")
            }
            return .storage
        case "metrics":
            return .metrics(try parseInspectMetrics(arguments: remainingArguments))
        case "frame":
            return .frame(try parseInspectFrame(arguments: remainingArguments))
        default:
            throw CLIError.unknownOption(subcommand, command: "inspect")
        }
    }

    private func parseInspectMetrics(arguments: [String]) throws -> CLIInspectMetricsRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var recentLimit = 100

        while let argument = cursor.next() {
            switch argument {
            case "--recent":
                recentLimit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "inspect metrics")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `inspect metrics`.")
            }
        }

        return CLIInspectMetricsRequest(recentLimit: recentLimit)
    }

    private func parseInspectFrame(arguments: [String]) throws -> CLIInspectFrameRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var selector: CLIInspectFrameSelector?

        while let argument = cursor.next() {
            switch argument {
            case "--frame":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "inspect frame",
                        details: ["selectors": "Use only one frame selector"]
                    )
                }
                selector = .frameID(try parseFrameID(try cursor.requireValue(for: argument), option: argument))
            case "--result":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "inspect frame",
                        details: ["selectors": "Use only one frame selector"]
                    )
                }
                selector = .resultID(try parseResultID(try cursor.requireValue(for: argument), option: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "inspect frame")
                }
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "inspect frame",
                        details: ["selectors": "Use only one frame selector"]
                    )
                }
                selector = .frameID(try parseFrameID(argument, option: "frame"))
            }
        }

        guard let selector else {
            throw CLIError.usage("`inspect frame` requires `<frame-id>`, `--frame <id>`, or `--result <n>`.")
        }

        return CLIInspectFrameRequest(selector: selector)
    }

    private func parseExtractImage(arguments: [String]) throws -> CLIExtractImageRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var selector: CLIExtractSelector?
        var outputPath: String?
        var overwrite = false

        while let argument = cursor.next() {
            switch argument {
            case "--at":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "extract image",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                let rawValue = try cursor.requireValue(for: argument)
                selector = .at(
                    CLITimeReference(
                        rawValue: rawValue,
                        date: try timeParser.parseInstant(rawValue, optionName: "--at")
                    )
                )
            case "--frame":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "extract image",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                selector = .frameID(try parseFrameID(try cursor.requireValue(for: argument), option: argument))
            case "--result":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: "extract image",
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                selector = .resultID(try parseResultID(try cursor.requireValue(for: argument), option: argument))
            case "--output":
                outputPath = try cursor.requireValue(for: argument)
            case "--overwrite":
                overwrite = true
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "extract image")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `extract image`.")
            }
        }

        guard let selector else {
            throw CLIError.usage("`extract image` requires one of `--at <time>`, `--frame <id>`, or `--result <n>`.")
        }
        guard let outputPath, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("`extract image` requires `--output <path>`.")
        }

        return CLIExtractImageRequest(selector: selector, outputPath: outputPath, overwrite: overwrite)
    }

    private func parseExtractSelector(arguments: [String], command: String) throws -> CLIExtractSelector {
        var cursor = ArgumentCursor(arguments: arguments)
        var selector: CLIExtractSelector?

        while let argument = cursor.next() {
            switch argument {
            case "--at":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: command,
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                let rawValue = try cursor.requireValue(for: argument)
                selector = .at(
                    CLITimeReference(
                        rawValue: rawValue,
                        date: try timeParser.parseInstant(rawValue, optionName: "--at")
                    )
                )
            case "--frame":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: command,
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                selector = .frameID(try parseFrameID(try cursor.requireValue(for: argument), option: argument))
            case "--result":
                guard selector == nil else {
                    throw CLIError.invalidSelectorCombination(
                        command: command,
                        details: ["selectors": "Use only one of --at, --frame, or --result"]
                    )
                }
                selector = .resultID(try parseResultID(try cursor.requireValue(for: argument), option: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: command)
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `\(command)`.")
            }
        }

        guard let selector else {
            throw CLIError.usage("`\(command)` requires one of `--at <time>`, `--frame <id>`, or `--result <n>`.")
        }

        return selector
    }

    private func parseUsageApps(arguments: [String]) throws -> CLIUsageAppsRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var from: CLITimeReference?
        var to: CLITimeReference?
        var limit = 50

        while let argument = cursor.next() {
            switch argument {
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage apps")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage apps`.")
            }
        }

        return CLIUsageAppsRequest(
            timeRange: try parseUsageTimeRange(from: from, to: to),
            limit: limit
        )
    }

    private func parseUsageWebsites(arguments: [String]) throws -> CLIUsageWebsitesRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var app: String?
        var from: CLITimeReference?
        var to: CLITimeReference?
        var limit = 50

        while let argument = cursor.next() {
            switch argument {
            case "--app":
                app = try cursor.requireValue(for: argument)
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage websites")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage websites`.")
            }
        }

        guard let app else {
            throw CLIError.usage("`usage websites` requires `--app <bundle-or-display-name>`.")
        }

        return CLIUsageWebsitesRequest(
            app: app,
            timeRange: try parseUsageTimeRange(from: from, to: to),
            limit: limit
        )
    }

    private func parseUsageTabs(arguments: [String]) throws -> CLIUsageTabsRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var app: String?
        var website: String?
        var from: CLITimeReference?
        var to: CLITimeReference?
        var limit = 100

        while let argument = cursor.next() {
            switch argument {
            case "--app":
                app = try cursor.requireValue(for: argument)
            case "--website":
                website = try cursor.requireValue(for: argument)
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage tabs")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage tabs`.")
            }
        }

        guard let app else {
            throw CLIError.usage("`usage tabs` requires `--app <bundle-or-display-name>`.")
        }

        return CLIUsageTabsRequest(
            app: app,
            website: website?.trimmingCharacters(in: .whitespacesAndNewlines),
            timeRange: try parseUsageTimeRange(from: from, to: to),
            limit: limit
        )
    }

    private func parseUsageSessions(arguments: [String]) throws -> CLIUsageSessionsRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var app: String?
        var window: String?
        var website: String?
        var from: CLITimeReference?
        var to: CLITimeReference?
        var hiddenFilter: HiddenFilter = .hide
        var limit = 200
        var offset = 0

        while let argument = cursor.next() {
            switch argument {
            case "--app":
                app = try cursor.requireValue(for: argument)
            case "--window":
                window = try cursor.requireValue(for: argument)
            case "--website":
                website = try cursor.requireValue(for: argument)
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            case "--hidden":
                hiddenFilter = try parseHiddenFilter(try cursor.requireValue(for: argument))
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            case "--offset":
                offset = try parseCount(try cursor.requireValue(for: argument), option: argument)
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage sessions")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage sessions`.")
            }
        }

        return CLIUsageSessionsRequest(
            timeRange: try parseUsageTimeRange(from: from, to: to),
            app: app?.trimmingCharacters(in: .whitespacesAndNewlines),
            window: window?.trimmingCharacters(in: .whitespacesAndNewlines),
            website: website?.trimmingCharacters(in: .whitespacesAndNewlines),
            hiddenFilter: hiddenFilter,
            limit: limit,
            offset: offset
        )
    }

    private func parseUsageScreenTime(arguments: [String]) throws -> CLIUsageScreenTimeRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var from: CLITimeReference?
        var to: CLITimeReference?

        while let argument = cursor.next() {
            switch argument {
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage screen-time")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage screen-time`.")
            }
        }

        return CLIUsageScreenTimeRequest(
            timeRange: try parseUsageTimeRange(from: from, to: to)
        )
    }

    private func parseUsageSwitches(arguments: [String]) throws -> CLIUsageSwitchesRequest {
        var cursor = ArgumentCursor(arguments: arguments)
        var from: CLITimeReference?
        var to: CLITimeReference?
        var app: String?
        var hiddenFilter: HiddenFilter = .hide
        var limit = 100

        while let argument = cursor.next() {
            switch argument {
            case "--from":
                let rawValue = try cursor.requireValue(for: argument)
                from = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--from")
                )
            case "--to":
                let rawValue = try cursor.requireValue(for: argument)
                to = CLITimeReference(
                    rawValue: rawValue,
                    date: try timeParser.parseInstant(rawValue, optionName: "--to")
                )
            case "--app":
                app = try cursor.requireValue(for: argument)
            case "--hidden":
                hiddenFilter = try parseHiddenFilter(try cursor.requireValue(for: argument))
            case "--limit":
                limit = try parseLimit(try cursor.requireValue(for: argument))
            default:
                if argument.hasPrefix("--") {
                    throw CLIError.unknownOption(argument, command: "usage switches")
                }
                throw CLIError.usage("Unexpected positional argument `\(argument)` for `usage switches`.")
            }
        }

        return CLIUsageSwitchesRequest(
            timeRange: try parseUsageTimeRange(from: from, to: to),
            app: app?.trimmingCharacters(in: .whitespacesAndNewlines),
            hiddenFilter: hiddenFilter,
            limit: limit
        )
    }

    private func parseUsageTimeRange(
        from: CLITimeReference?,
        to: CLITimeReference?
    ) throws -> CLIUsageTimeRange {
        guard let from else {
            throw CLIError.usage("Usage commands require `--from <time>`.")
        }
        guard let to else {
            throw CLIError.usage("Usage commands require `--to <time>`.")
        }
        guard from.date <= to.date else {
            throw CLIError.invalidValue(
                option: "--from/--to",
                value: "\(from.rawValue)..\(to.rawValue)",
                details: ["reason": "`--from` must be earlier than or equal to `--to`"]
            )
        }
        return CLIUsageTimeRange(from: from, to: to)
    }

    private func parseHiddenFilter(_ rawValue: String) throws -> HiddenFilter {
        switch rawValue.lowercased() {
        case "hide":
            return .hide
        case "show":
            return .showAll
        case "only":
            return .onlyHidden
        default:
            throw CLIError.invalidValue(
                option: "--hidden",
                value: rawValue,
                details: ["allowed": "hide, show, only"]
            )
        }
    }

    private func parseSort(_ rawValue: String) throws -> CLISearchSort {
        guard let sort = CLISearchSort(rawValue: rawValue.lowercased()) else {
            throw CLIError.invalidValue(
                option: "--sort",
                value: rawValue,
                details: ["allowed": "relevance, newest, oldest"]
            )
        }
        return sort
    }

    private func parseLimit(_ rawValue: String) throws -> Int {
        guard let limit = Int(rawValue), limit > 0 else {
            throw CLIError.invalidValue(option: "--limit", value: rawValue)
        }
        return limit
    }

    private func parseCount(_ rawValue: String, option: String) throws -> Int {
        guard let value = Int(rawValue), value >= 0 else {
            throw CLIError.invalidValue(option: option, value: rawValue)
        }
        return value
    }

    private func parseFrameID(_ rawValue: String, option: String) throws -> Int64 {
        guard let value = Int64(rawValue), value > 0 else {
            throw CLIError.invalidValue(option: option, value: rawValue)
        }
        return value
    }

    private func parseResultID(_ rawValue: String, option: String) throws -> Int {
        guard let value = Int(rawValue), value > 0 else {
            throw CLIError.invalidValue(option: option, value: rawValue)
        }
        return value
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                ordered.append(normalized)
            }
        }

        return ordered
    }
}

private struct ArgumentCursor {
    let arguments: [String]
    private(set) var index = 0

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let value = next() else {
            throw CLIError.missingValue(option)
        }
        return value
    }
}

public enum CLIError: LocalizedError, Sendable, Equatable {
    case usage(String, details: [String: String]? = nil)
    case unknownCommand(String)
    case unknownOption(String, command: String)
    case missingValue(String)
    case invalidValue(option: String, value: String, details: [String: String]? = nil)
    case conflictingFlags(String, String)
    case tooManyRanges(maximum: Int)
    case appNotFound(String)
    case ambiguousApp(String, matches: [String])
    case tagNotFound(String)
    case ambiguousTag(String, matches: [String])
    case unknownConfigKey(String)
    case invalidSelectorCombination(command: String, details: [String: String]? = nil)
    case frameNotFound(String)
    case noFramesAvailable(String)
    case noStoredResultsAvailable
    case storedResultNotFound(Int)
    case openFailed(String)
    case outputAlreadyExists(String)
    case writeFailed(String)
    case imageUnavailable(String)
    case imageExportHostUnavailable
    case imageExportTimedOut(Int64)
    case imageExportFailed(String)

    public var errorDescription: String? {
        payload.message
    }

    public var payload: CLIErrorPayload {
        switch self {
        case .usage(let message, let details):
            return CLIErrorPayload(code: "usage_error", message: message, details: details)
        case .unknownCommand(let command):
            return CLIErrorPayload(
                code: "unknown_command",
                message: "Unknown command `\(command)`.",
                details: ["commands": CLIArgumentParser.topLevelCommands]
            )
        case .unknownOption(let option, let command):
            return CLIErrorPayload(
                code: "unknown_option",
                message: "Unknown option `\(option)` for `\(command)`.",
                details: nil
            )
        case .missingValue(let option):
            return CLIErrorPayload(
                code: "missing_option_value",
                message: "Missing value for `\(option)`.",
                details: nil
            )
        case .invalidValue(let option, let value, let details):
            return CLIErrorPayload(
                code: "invalid_option_value",
                message: "Invalid value `\(value)` for `\(option)`.",
                details: details
            )
        case .conflictingFlags(let first, let second):
            return CLIErrorPayload(
                code: "conflicting_flags",
                message: "Flags `\(first)` and `\(second)` cannot be used together.",
                details: nil
            )
        case .tooManyRanges(let maximum):
            return CLIErrorPayload(
                code: "too_many_ranges",
                message: "At most \(maximum) `--range` filters are allowed.",
                details: ["maximum": "\(maximum)"]
            )
        case .appNotFound(let rawValue):
            return CLIErrorPayload(
                code: "app_not_found",
                message: "Could not resolve app filter `\(rawValue)`.",
                details: nil
            )
        case .ambiguousApp(let rawValue, let matches):
            return CLIErrorPayload(
                code: "ambiguous_app",
                message: "App filter `\(rawValue)` matched multiple bundle IDs.",
                details: ["matches": matches.joined(separator: ", ")]
            )
        case .tagNotFound(let rawValue):
            return CLIErrorPayload(
                code: "tag_not_found",
                message: "Could not resolve tag `\(rawValue)`.",
                details: nil
            )
        case .ambiguousTag(let rawValue, let matches):
            return CLIErrorPayload(
                code: "ambiguous_tag",
                message: "Tag filter `\(rawValue)` matched multiple tags.",
                details: ["matches": matches.joined(separator: ", ")]
            )
        case .unknownConfigKey(let rawValue):
            return CLIErrorPayload(
                code: "unknown_config_key",
                message: "Unknown config key `\(rawValue)`.",
                details: nil
            )
        case .invalidSelectorCombination(let command, let details):
            return CLIErrorPayload(
                code: "invalid_selector_combination",
                message: "Invalid selector combination for `\(command)`.",
                details: details
            )
        case .frameNotFound(let rawValue):
            return CLIErrorPayload(
                code: "frame_not_found",
                message: "Could not resolve frame `\(rawValue)`.",
                details: nil
            )
        case .noFramesAvailable(let rawValue):
            return CLIErrorPayload(
                code: "no_frames_available",
                message: "No frames found for `\(rawValue)`.",
                details: nil
            )
        case .noStoredResultsAvailable:
            return CLIErrorPayload(
                code: "no_stored_results",
                message: "No stored search results are available for `--result` lookups.",
                details: nil
            )
        case .storedResultNotFound(let value):
            return CLIErrorPayload(
                code: "stored_result_not_found",
                message: "Stored search result `\(value)` was not found.",
                details: nil
            )
        case .openFailed(let rawValue):
            return CLIErrorPayload(
                code: "open_failed",
                message: "Failed to open deeplink `\(rawValue)`.",
                details: nil
            )
        case .outputAlreadyExists(let path):
            return CLIErrorPayload(
                code: "output_exists",
                message: "Refusing to overwrite existing file `\(path)`.",
                details: nil
            )
        case .writeFailed(let path):
            return CLIErrorPayload(
                code: "write_failed",
                message: "Failed to write output file `\(path)`.",
                details: nil
            )
        case .imageUnavailable(let rawValue):
            return CLIErrorPayload(
                code: "image_unavailable",
                message: "Could not extract an image for `\(rawValue)`.",
                details: nil
            )
        case .imageExportHostUnavailable:
            return CLIErrorPayload(
                code: "image_export_host_unavailable",
                message: "`retrace extract image` requires a running Retrace.app export host.",
                details: ["bundleIdentifier": "io.retrace.app"]
            )
        case .imageExportTimedOut(let frameID):
            return CLIErrorPayload(
                code: "image_export_timed_out",
                message: "Timed out waiting for Retrace.app to export frame `\(frameID)`.",
                details: ["bundleIdentifier": "io.retrace.app"]
            )
        case .imageExportFailed(let message):
            return CLIErrorPayload(
                code: "image_export_failed",
                message: message,
                details: nil
            )
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage,
             .unknownCommand,
             .unknownOption,
             .missingValue,
             .invalidValue,
             .conflictingFlags,
             .tooManyRanges,
             .appNotFound,
             .ambiguousApp,
             .tagNotFound,
             .ambiguousTag,
             .unknownConfigKey,
             .invalidSelectorCombination,
             .frameNotFound,
             .noFramesAvailable,
             .noStoredResultsAvailable,
             .storedResultNotFound,
             .openFailed,
             .outputAlreadyExists,
             .writeFailed,
             .imageUnavailable,
             .imageExportHostUnavailable,
             .imageExportTimedOut,
             .imageExportFailed:
            return 64
        }
    }
}
