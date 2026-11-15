import XCTest
@testable import App
import Database
import Shared

final class CLIResultStoreTests: XCTestCase {
    func testResultStorePersistsAndResolvesLatestSearchResults() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDirectory.appendingPathComponent("results.json")
        let store = CLIResultStore(fileURL: fileURL)

        let results = [
            CLISearchResultOutput(
                resultID: 1,
                frameID: 101,
                timestamp: Date(timeIntervalSince1970: 100),
                appBundleID: "com.google.Chrome",
                appName: "Chrome",
                windowName: "OpenAI",
                browserURL: "https://openai.com",
                snippet: "OpenAI",
                matchedText: "OpenAI",
                relevanceScore: 0.9,
                segmentID: 11,
                videoID: 21,
                frameIndex: 3,
                source: .native
            ),
            CLISearchResultOutput(
                resultID: 2,
                frameID: 202,
                timestamp: Date(timeIntervalSince1970: 200),
                appBundleID: "com.openai.codex",
                appName: "Codex",
                windowName: "Codex",
                browserURL: nil,
                snippet: "prompt",
                matchedText: "prompt",
                relevanceScore: 0.8,
                segmentID: 12,
                videoID: 22,
                frameIndex: 4,
                source: .native
            )
        ]

        try store.saveLatestSearchResults(queryText: "openai", results: results)
        let loaded = try XCTUnwrap(store.loadLatestSearchResults())

        XCTAssertEqual(loaded.queryText, "openai")
        XCTAssertEqual(loaded.results, results)
        XCTAssertEqual(try store.resolveLatestSearchResult(id: 2), results[1])
    }
}

final class CLIResultNormalizationTests: XCTestCase {
    func testNormalizedSearchResultsAssignSequentialIDsAndApplyLimit() {
        let timestamp = Date(timeIntervalSince1970: 1_776_000_000)
        let results = [
            SearchResult(
                id: FrameID(value: 101),
                timestamp: timestamp,
                snippet: "needle newest",
                matchedText: "needle",
                relevanceScore: 0.95,
                metadata: FrameMetadata(
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Workspace",
                    browserURL: "https://openai.com/new"
                ),
                segmentID: AppSegmentID(value: 201),
                videoID: VideoSegmentID(value: 301),
                frameIndex: 4,
                source: .native
            ),
            SearchResult(
                id: FrameID(value: 102),
                timestamp: timestamp.addingTimeInterval(-60),
                snippet: "needle older",
                matchedText: "needle",
                relevanceScore: 0.80,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Terminal",
                    appName: "Terminal",
                    windowName: "Shell",
                    browserURL: nil
                ),
                segmentID: AppSegmentID(value: 202),
                videoID: VideoSegmentID(value: 302),
                frameIndex: 9,
                source: .rewind
            )
        ]

        let normalized = RetraceCLIService.normalizedSearchResults(results, limit: 1)

        XCTAssertEqual(
            normalized,
            [
                CLISearchResultOutput(
                    resultID: 1,
                    frameID: 101,
                    timestamp: timestamp,
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Workspace",
                    browserURL: "https://openai.com/new",
                    snippet: "needle newest",
                    matchedText: "needle",
                    relevanceScore: 0.95,
                    segmentID: 201,
                    videoID: 301,
                    frameIndex: 4,
                    source: .native
                )
            ]
        )
    }
}

final class CLIServiceSearchIntegrationTests: XCTestCase {
    private struct SeededFrame {
        let frameID: FrameID
        let segmentID: Int64
    }

    func testSearchUsesSeededDatabaseFiltersAndStoresNormalizedResults() async throws {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")
        defaults.set(false, forKey: "useRewindData")
        defer {
            if let previousUseRewindData {
                defaults.set(previousUseRewindData, forKey: "useRewindData")
            } else {
                defaults.removeObject(forKey: "useRewindData")
            }
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resultStore = CLIResultStore(fileURL: tempDirectory.appendingPathComponent("results.json"))
        let serviceDefaults = UserDefaults(suiteName: "cli-search-tests-\(UUID().uuidString)")!
        let services = ServiceContainer(inMemory: true)
        let coordinator = AppCoordinator(services: services)

        defer {
            Task {
                try? await coordinator.shutdown()
            }
        }

        try await coordinator.initializeForCLI()

        let database = await services.database
        let baseDate = Date(timeIntervalSince1970: 1_776_100_000)
        _ = try await seedFrameRecord(
            in: database,
            timestamp: baseDate,
            bundleID: "com.google.Chrome",
            text: "needle older chrome result",
            windowName: "Workspace Search",
            browserURL: "https://openai.com/older"
        )
        let newest = try await seedFrameRecord(
            in: database,
            timestamp: baseDate.addingTimeInterval(120),
            bundleID: "com.google.Chrome",
            text: "needle newest chrome result",
            windowName: "Workspace Search",
            browserURL: "https://openai.com/newer"
        )
        _ = try await seedFrameRecord(
            in: database,
            timestamp: baseDate.addingTimeInterval(180),
            bundleID: "com.google.Chrome",
            text: "needle wrong website",
            windowName: "Workspace Search",
            browserURL: "https://example.com/off-topic"
        )
        _ = try await seedFrameRecord(
            in: database,
            timestamp: baseDate.addingTimeInterval(240),
            bundleID: "com.google.Chrome",
            text: "needle wrong window",
            windowName: "Notes",
            browserURL: "https://openai.com/window-miss"
        )
        _ = try await seedFrameRecord(
            in: database,
            timestamp: baseDate.addingTimeInterval(300),
            bundleID: "com.apple.Terminal",
            text: "needle wrong app",
            windowName: "Workspace Search",
            browserURL: "https://openai.com/app-miss"
        )

        let service = RetraceCLIService(
            coordinator: coordinator,
            resultStore: resultStore,
            defaults: serviceDefaults
        )

        let output = try await service.search(
            CLISearchRequest(
                queryText: "needle",
                includeApps: ["Chrome"],
                ranges: [
                    DateRangeCriterion(
                        start: baseDate.addingTimeInterval(-60),
                        end: baseDate.addingTimeInterval(400)
                    )
                ],
                includeURLTerms: ["openai.com"],
                includeWindowTerms: ["Workspace"],
                sort: .newest,
                limit: 1
            )
        )

        XCTAssertEqual(output.query.text, "needle")
        XCTAssertEqual(output.query.limit, 1)
        XCTAssertEqual(output.query.sort, .newest)
        XCTAssertEqual(output.query.filters.appBundleIDs, ["com.google.Chrome"])
        XCTAssertEqual(output.query.filters.urlTerms, ["openai.com"])
        XCTAssertEqual(output.query.filters.windowTerms, ["Workspace"])
        XCTAssertEqual(output.resultCount, 1)
        XCTAssertEqual(output.results.count, 1)
        XCTAssertGreaterThanOrEqual(output.searchTimeMs, 0)
        XCTAssertTrue(output.storedResultsAvailable)

        let result = try XCTUnwrap(output.results.first)
        XCTAssertEqual(result.resultID, 1)
        XCTAssertEqual(result.frameID, newest.frameID.value)
        XCTAssertEqual(result.appBundleID, "com.google.Chrome")
        XCTAssertEqual(result.windowName, "Workspace Search")
        XCTAssertEqual(result.browserURL, "https://openai.com/newer")
        XCTAssertEqual(result.segmentID, newest.segmentID)
        XCTAssertEqual(result.source, .native)

        let storedResults = try XCTUnwrap(resultStore.loadLatestSearchResults())
        XCTAssertEqual(storedResults.queryText, "needle")
        XCTAssertEqual(storedResults.results, output.results)
        XCTAssertEqual(try resultStore.resolveLatestSearchResult(id: 1), result)
    }

    private func seedFrameRecord(
        in database: DatabaseManager,
        timestamp: Date,
        bundleID: String,
        text: String,
        windowName: String,
        browserURL: String?
    ) async throws -> SeededFrame {
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(60),
                frameCount: 1,
                fileSizeBytes: 1,
                relativePath: "\(UUID().uuidString).mp4",
                width: 1920,
                height: 1080,
                source: .native
            )
        )

        let segmentID = try await database.insertSegment(
            bundleID: bundleID,
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(60),
            windowName: windowName,
            browserUrl: browserURL,
            type: 0
        )

        let frameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: bundleID,
                    appName: bundleID,
                    windowName: windowName,
                    browserURL: browserURL
                ),
                source: .native
            )
        )

        _ = try await database.indexFrameText(
            mainText: text,
            chromeText: nil,
            windowTitle: windowName,
            segmentId: segmentID,
            frameId: frameID
        )

        return SeededFrame(frameID: FrameID(value: frameID), segmentID: segmentID)
    }
}
