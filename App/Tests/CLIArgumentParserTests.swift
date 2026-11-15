import XCTest
@testable import App
import Shared

final class CLIArgumentParserTests: XCTestCase {
    func testSearchParsesRepeatedRangesAndFilters() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "search",
            "tax",
            "act",
            "--app", "Chrome",
            "--not-app", "Terminal",
            "--range", "2026-04-01..2026-04-05",
            "--range", "2026-04-10..2026-04-12",
            "--url", "taxact.com",
            "--not-url", "logout",
            "--window", "onboarding",
            "--not-window", "help",
            "--tag", "taxes",
            "--not-tag", "hidden",
            "--commented",
            "--hidden", "show",
            "--sort", "newest",
            "--limit", "25"
        ])

        guard case .search(let request) = command else {
            return XCTFail("Expected search command.")
        }

        XCTAssertEqual(request.queryText, "tax act")
        XCTAssertEqual(request.includeApps, ["Chrome"])
        XCTAssertEqual(request.excludeApps, ["Terminal"])
        XCTAssertEqual(request.ranges.count, 2)
        XCTAssertEqual(request.includeURLTerms, ["taxact.com"])
        XCTAssertEqual(request.excludeURLTerms, ["logout"])
        XCTAssertEqual(request.includeWindowTerms, ["onboarding"])
        XCTAssertEqual(request.excludeWindowTerms, ["help"])
        XCTAssertEqual(request.includeTagNames, ["taxes"])
        XCTAssertEqual(request.excludeTagNames, ["hidden"])
        XCTAssertEqual(request.commentFilter, .commentsOnly)
        XCTAssertEqual(request.hiddenFilter, .showAll)
        XCTAssertEqual(request.sort, .newest)
        XCTAssertEqual(request.limit, 25)
    }

    func testSearchRejectsMoreThanFiveRanges() throws {
        let parser = CLIArgumentParser()

        XCTAssertThrowsError(
            try parser.parse(arguments: [
                "search",
                "query",
                "--range", "2026-04-01..2026-04-01",
                "--range", "2026-04-02..2026-04-02",
                "--range", "2026-04-03..2026-04-03",
                "--range", "2026-04-04..2026-04-04",
                "--range", "2026-04-05..2026-04-05",
                "--range", "2026-04-06..2026-04-06"
            ])
        ) { error in
            XCTAssertEqual(error as? CLIError, .tooManyRanges(maximum: 5))
        }
    }

    func testSearchRejectsConflictingCommentFlags() throws {
        let parser = CLIArgumentParser()

        XCTAssertThrowsError(
            try parser.parse(arguments: [
                "search",
                "query",
                "--commented",
                "--uncommented"
            ])
        ) { error in
            XCTAssertEqual(error as? CLIError, .conflictingFlags("--commented", "--uncommented"))
        }
    }

    func testJumpParsesAtSelector() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "jump",
            "--at", "2026-04-15 14:03"
        ])

        guard case .jump(let request) = command else {
            return XCTFail("Expected jump command.")
        }

        XCTAssertEqual(request.target.rawValue, "2026-04-15 14:03")
    }

    func testAroundParsesFrameAnchorAndWindowCounts() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "around",
            "--frame", "12345",
            "--before", "3",
            "--after", "7"
        ])

        guard case .around(let request) = command else {
            return XCTFail("Expected around command.")
        }

        XCTAssertEqual(request.beforeCount, 3)
        XCTAssertEqual(request.afterCount, 7)
        guard case .frameID(let frameID) = request.anchor else {
            return XCTFail("Expected frame anchor.")
        }
        XCTAssertEqual(frameID, 12345)
    }

    func testAroundParsesResultAnchor() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "around",
            "--result", "3",
            "--before", "1",
            "--after", "2"
        ])

        guard case .around(let request) = command else {
            return XCTFail("Expected around command.")
        }

        guard case .resultID(let resultID) = request.anchor else {
            return XCTFail("Expected result anchor.")
        }
        XCTAssertEqual(resultID, 3)
    }

    func testOpenRejectsInvalidSelectorCombination() throws {
        let parser = CLIArgumentParser()

        XCTAssertThrowsError(
            try parser.parse(arguments: [
                "open",
                "--frame", "12345",
                "--query", "cca"
            ])
        ) { error in
            XCTAssertEqual(
                error as? CLIError,
                .invalidSelectorCombination(
                    command: "open",
                    details: ["selectors": "`--frame` cannot be combined with other open selectors or search filters"]
                )
            )
        }
    }

    func testOpenParsesResultSelector() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "open",
            "--result", "2"
        ])

        guard case .open(let request) = command else {
            return XCTFail("Expected open command.")
        }

        guard case .resultID(let resultID) = request.selector else {
            return XCTFail("Expected result selector.")
        }
        XCTAssertEqual(resultID, 2)
    }

    func testOpenParsesSearchFilters() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "open",
            "--query", "cca",
            "--range", "2025-04-01..2025-04-30",
            "--window", "UFile",
            "--not-window", "Help",
            "--url", "ufile.ca",
            "--not-url", "logout",
            "--tag", "taxes",
            "--commented",
            "--hidden", "show",
            "--sort", "oldest"
        ])

        guard case .open(let request) = command,
              case .search(let searchRequest) = request.selector else {
            return XCTFail("Expected open search selector.")
        }

        XCTAssertEqual(searchRequest.queryText, "cca")
        XCTAssertEqual(searchRequest.ranges.count, 1)
        XCTAssertEqual(searchRequest.includeWindowTerms, ["UFile"])
        XCTAssertEqual(searchRequest.excludeWindowTerms, ["Help"])
        XCTAssertEqual(searchRequest.includeURLTerms, ["ufile.ca"])
        XCTAssertEqual(searchRequest.excludeURLTerms, ["logout"])
        XCTAssertEqual(searchRequest.includeTagNames, ["taxes"])
        XCTAssertEqual(searchRequest.commentFilter, .commentsOnly)
        XCTAssertEqual(searchRequest.hiddenFilter, .showAll)
        XCTAssertEqual(searchRequest.sort, .oldest)
    }

    func testAppsListParses() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "apps",
            "list"
        ])

        guard case .apps(let request) = command,
              case .list = request else {
            return XCTFail("Expected apps list command.")
        }
    }

    func testHelpParsesFromDashDashHelp() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "search",
            "--help"
        ])

        guard case .help(let request) = command else {
            return XCTFail("Expected help command.")
        }

        XCTAssertEqual(request.topicPath, ["search"])
    }

    func testCompletionsParsesShell() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "completions",
            "zsh"
        ])

        guard case .completions(let request) = command else {
            return XCTFail("Expected completions command.")
        }

        XCTAssertEqual(request.shell, .zsh)
    }

    func testConfigSetParsesPositionalKeyAndValue() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "config",
            "set",
            "capture.interval",
            "5"
        ])

        guard case .config(let request) = command,
              case .set(let configRequest) = request else {
            return XCTFail("Expected config set command.")
        }

        XCTAssertEqual(configRequest.key, "capture.interval")
        XCTAssertEqual(configRequest.value, "5")
    }

    func testConfigResetParsesKey() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "config",
            "reset",
            "general.theme"
        ])

        guard case .config(let request) = command,
              case .reset(let configRequest) = request else {
            return XCTFail("Expected config reset command.")
        }

        XCTAssertEqual(configRequest.key, "general.theme")
    }

    func testUsageAppsParsesDateRangeAndLimit() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "usage",
            "apps",
            "--from", "2026-04-15 14:00",
            "--to", "2026-04-15 16:00",
            "--limit", "12"
        ])

        guard case .usage(let request) = command,
              case .apps(let usageRequest) = request else {
            return XCTFail("Expected usage apps command.")
        }

        XCTAssertEqual(usageRequest.timeRange.from.rawValue, "2026-04-15 14:00")
        XCTAssertEqual(usageRequest.timeRange.to.rawValue, "2026-04-15 16:00")
        XCTAssertEqual(usageRequest.limit, 12)
    }

    func testUsageTabsParsesWebsiteFilter() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "usage",
            "tabs",
            "--app", "Chrome",
            "--website", "twitter.com",
            "--from", "2026-04-15 14:00",
            "--to", "2026-04-15 16:00"
        ])

        guard case .usage(let request) = command,
              case .tabs(let usageRequest) = request else {
            return XCTFail("Expected usage tabs command.")
        }

        XCTAssertEqual(usageRequest.app, "Chrome")
        XCTAssertEqual(usageRequest.website, "twitter.com")
    }

    func testUsageSessionsParsesFiltersAndPagination() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "usage",
            "sessions",
            "--from", "2026-04-15 14:00",
            "--to", "2026-04-15 16:00",
            "--app", "Chrome",
            "--window", "OpenAI",
            "--website", "openai.com",
            "--hidden", "show",
            "--limit", "40",
            "--offset", "20"
        ])

        guard case .usage(let request) = command,
              case .sessions(let usageRequest) = request else {
            return XCTFail("Expected usage sessions command.")
        }

        XCTAssertEqual(usageRequest.app, "Chrome")
        XCTAssertEqual(usageRequest.window, "OpenAI")
        XCTAssertEqual(usageRequest.website, "openai.com")
        XCTAssertEqual(usageRequest.hiddenFilter, .showAll)
        XCTAssertEqual(usageRequest.limit, 40)
        XCTAssertEqual(usageRequest.offset, 20)
    }

    func testUsageScreenTimeParsesDateRange() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "usage",
            "screen-time",
            "--from", "2026-04-15 00:00",
            "--to", "2026-04-15 23:59"
        ])

        guard case .usage(let request) = command,
              case .screenTime(let usageRequest) = request else {
            return XCTFail("Expected usage screen-time command.")
        }

        XCTAssertEqual(usageRequest.timeRange.from.rawValue, "2026-04-15 00:00")
        XCTAssertEqual(usageRequest.timeRange.to.rawValue, "2026-04-15 23:59")
    }

    func testUsageSwitchesParsesAppAndLimit() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "usage",
            "switches",
            "--from", "2026-04-15 14:00",
            "--to", "2026-04-15 16:00",
            "--app", "Chrome",
            "--hidden", "only",
            "--limit", "15"
        ])

        guard case .usage(let request) = command,
              case .switches(let usageRequest) = request else {
            return XCTFail("Expected usage switches command.")
        }

        XCTAssertEqual(usageRequest.app, "Chrome")
        XCTAssertEqual(usageRequest.hiddenFilter, .onlyHidden)
        XCTAssertEqual(usageRequest.limit, 15)
    }

    func testExtractTextParsesResultSelector() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "extract",
            "text",
            "--result", "4"
        ])

        guard case .extract(let request) = command,
              case .text(let extractRequest) = request else {
            return XCTFail("Expected extract text command.")
        }

        guard case .resultID(let resultID) = extractRequest.selector else {
            return XCTFail("Expected result selector.")
        }
        XCTAssertEqual(resultID, 4)
    }

    func testExtractImageParsesOutputAndOverwrite() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "extract",
            "image",
            "--frame", "12345",
            "--output", "/tmp/frame.jpg",
            "--overwrite"
        ])

        guard case .extract(let request) = command,
              case .image(let extractRequest) = request else {
            return XCTFail("Expected extract image command.")
        }

        XCTAssertEqual(extractRequest.outputPath, "/tmp/frame.jpg")
        XCTAssertTrue(extractRequest.overwrite)
        guard case .frameID(let frameID) = extractRequest.selector else {
            return XCTFail("Expected frame selector.")
        }
        XCTAssertEqual(frameID, 12345)
    }

    func testExtractImageRequiresOutputPath() throws {
        let parser = CLIArgumentParser()

        XCTAssertThrowsError(
            try parser.parse(arguments: [
                "extract",
                "image",
                "--frame", "12345"
            ])
        ) { error in
            XCTAssertEqual(
                error as? CLIError,
                .usage("`extract image` requires `--output <path>`.")
            )
        }
    }

    func testInspectMetricsParsesRecentLimit() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "inspect",
            "metrics",
            "--recent", "25"
        ])

        guard case .inspect(let request) = command,
              case .metrics(let inspectRequest) = request else {
            return XCTFail("Expected inspect metrics command.")
        }

        XCTAssertEqual(inspectRequest.recentLimit, 25)
    }

    func testInspectFrameParsesPositionalFrameID() throws {
        let parser = CLIArgumentParser()

        let command = try parser.parse(arguments: [
            "inspect",
            "frame",
            "12345"
        ])

        guard case .inspect(let request) = command,
              case .frame(let inspectRequest) = request else {
            return XCTFail("Expected inspect frame command.")
        }

        guard case .frameID(let frameID) = inspectRequest.selector else {
            return XCTFail("Expected positional frame selector.")
        }

        XCTAssertEqual(frameID, 12345)
    }

    func testUsageRejectsDescendingTimeRange() throws {
        let parser = CLIArgumentParser()

        XCTAssertThrowsError(
            try parser.parse(arguments: [
                "usage",
                "apps",
                "--from", "2026-04-15 16:00",
                "--to", "2026-04-15 14:00"
            ])
        ) { error in
            XCTAssertEqual(
                error as? CLIError,
                .invalidValue(
                    option: "--from/--to",
                    value: "2026-04-15 16:00..2026-04-15 14:00",
                    details: ["reason": "`--from` must be earlier than or equal to `--to`"]
                )
            )
        }
    }

    func testAppResolutionPrefersHostBrowserOverChromeAppExtensions() async throws {
        let service = RetraceCLIService()

        let resolved = try await service.resolveSingleApp(
            "Chrome",
            availableBundleIDs: [
                "com.google.Chrome",
                "com.google.Chrome.app.cadlkienfkclaiaibeoongdcgmdikeeg",
                "com.google.Chrome.app.oggcgemkombppokocmmjlafigdepodak"
            ]
        )

        XCTAssertEqual(resolved, "com.google.Chrome")
    }

    func testConfigGetResolvesDefaultsKeyAlias() async throws {
        let suiteName = "CLIConfigAliasTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let service = RetraceCLIService(defaults: defaults)
        let output = try await service.configGet(CLIConfigKeyRequest(key: "captureIntervalSeconds"))

        XCTAssertEqual(output.entry.key, "capture.interval")
        XCTAssertEqual(output.entry.defaultsKey, "captureIntervalSeconds")
        XCTAssertEqual(output.entry.currentValue, .double(2.0))
        XCTAssertTrue(output.entry.currentIsDefault)
    }

    func testConfigSetAndResetRoundTripWithIsolatedDefaults() async throws {
        let suiteName = "CLIConfigRoundTripTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let service = RetraceCLIService(defaults: defaults)

        let setOutput = try await service.configSet(
            CLIConfigSetRequest(key: "capture.interval", value: "5")
        )
        XCTAssertTrue(setOutput.changed)
        XCTAssertEqual(setOutput.previousValue, .double(2.0))
        XCTAssertEqual(setOutput.entry.currentValue, .double(5.0))
        XCTAssertEqual(defaults.object(forKey: "captureIntervalSeconds") as? Double, 5.0)

        let resetOutput = try await service.configReset(
            CLIConfigKeyRequest(key: "capture.interval")
        )
        XCTAssertTrue(resetOutput.changed)
        XCTAssertEqual(resetOutput.previousValue, .double(5.0))
        XCTAssertEqual(resetOutput.entry.currentValue, .double(2.0))
        XCTAssertNil(defaults.object(forKey: "captureIntervalSeconds"))
    }

    func testHelpSupportsUsageSubtopics() async throws {
        let service = RetraceCLIService()

        let output = try await service.help(CLIHelpRequest(topicPath: ["usage", "sessions"]))

        XCTAssertEqual(output.topicPath, ["usage", "sessions"])
        XCTAssertEqual(output.usage, "retrace usage sessions --from <time> --to <time> [--app <bundle-or-name>] [--window <term>] [--website <site>] [--hidden hide|show|only] [--limit <n>] [--offset <n>]")
        XCTAssertTrue(output.examples.contains("retrace usage sessions --from \"2pm\" --to \"4pm\""))
    }

    func testHelpSupportsConfigTopic() async throws {
        let service = RetraceCLIService()

        let output = try await service.help(CLIHelpRequest(topicPath: ["config"]))

        XCTAssertEqual(output.topicPath, ["config"])
        XCTAssertEqual(output.subcommands.map(\.name), ["list", "get", "set", "reset"])
        XCTAssertTrue(output.notes.contains("shared_user_defaults"))
    }
}
