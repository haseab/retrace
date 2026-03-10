import XCTest
import CoreGraphics
import Shared
import Database
import Storage
@testable import App

final class InPageURLCaptureRoutingTests: XCTestCase {
    func testHostBrowserBundleIDMapsExactChromiumBrowser() {
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.google.Chrome"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.Browser"),
            "company.thebrowser.Browser"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia"),
            "company.thebrowser.dia"
        )
    }

    func testHostBrowserBundleIDMapsChromiumAppShimToHostBrowser() {
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.google.Chrome.app.cadlkienfkclaiaibeoongdcgmdikeeg"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.brave.Browser.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "com.brave.Browser"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia.app.ffffffffffffffffffffffffffffffff"),
            "company.thebrowser.dia"
        )
    }

    func testHostBrowserBundleIDRejectsUnsupportedBundleIDs() {
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.apple.Safari"))
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.example.notabrowser"))
    }
}

final class ServiceContainerRewindCutoffTests: XCTestCase {
    func testStoredRewindCutoffDateReturnsPersistedValue() {
        let suiteName = "io.retrace.app.tests.rewindCutoff.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedDate = Date(timeIntervalSince1970: 1_772_934_400.123)
        defaults.set(storedDate, forKey: "rewindCutoffDate")

        XCTAssertEqual(ServiceContainer.storedRewindCutoffDate(in: defaults), storedDate)
    }

    func testDefaultRewindCutoffDateUsesDecember20_2025AtLocalMidnightForCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let cutoffDate = ServiceContainer.defaultRewindCutoffDate(calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: cutoffDate)

        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 20)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testRewindCutoffDateFallsBackToDefaultWhenUnset() {
        let suiteName = "io.retrace.app.tests.rewindCutoff.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            ServiceContainer.rewindCutoffDate(in: defaults, calendar: calendar),
            ServiceContainer.defaultRewindCutoffDate(calendar: calendar)
        )
    }
}

final class DataAdapterRewindBoundaryTests: XCTestCase {
    private struct StubImageExtractor: ImageExtractor {
        enum StubError: Error {
            case notImplemented
        }

        func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
            throw StubError.notImplemented
        }

        func extractFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> CGImage {
            throw StubError.notImplemented
        }
    }

    private struct AdapterFixture {
        let adapter: DataAdapter
        let retraceDatabase: DatabaseManager
        let rewindDatabase: DatabaseManager
    }

    private func makeFixture(cutoffDate: Date) async throws -> AdapterFixture {
        let retraceDatabase = DatabaseManager(
            databasePath: "file:retrace_boundary_\(UUID().uuidString)?mode=memory&cache=private"
        )
        try await retraceDatabase.initialize()

        let rewindDatabase = DatabaseManager(
            databasePath: "file:rewind_boundary_\(UUID().uuidString)?mode=memory&cache=private"
        )
        try await rewindDatabase.initialize()

        guard let retracePointer = await retraceDatabase.getConnection(),
              let rewindPointer = await rewindDatabase.getConnection() else {
            XCTFail("Failed to get test database connections")
            throw NSError(domain: "DataAdapterRewindBoundaryTests", code: 1)
        }

        let retraceConnection = SQLiteConnection(db: retracePointer)
        let rewindConnection = SQLiteConnection(db: rewindPointer)
        let adapter = DataAdapter(
            retraceConnection: retraceConnection,
            retraceConfig: .retrace,
            retraceImageExtractor: StubImageExtractor(),
            database: retraceDatabase
        )
        await adapter.configureRewind(
            connection: rewindConnection,
            config: DatabaseConfig(
                dateFormatter: nil,
                storageRoot: "/tmp",
                source: .rewind,
                cutoffDate: cutoffDate
            ),
            imageExtractor: StubImageExtractor(),
            cutoffDate: cutoffDate
        )
        try await adapter.initialize()

        return AdapterFixture(
            adapter: adapter,
            retraceDatabase: retraceDatabase,
            rewindDatabase: rewindDatabase
        )
    }

    private func makeCutoffDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 0, minute: 0, second: 0))!
    }

    private func seedFrame(
        in database: DatabaseManager,
        timestamp: Date,
        bundleID: String,
        text: String,
        source: FrameSource
    ) async throws -> FrameID {
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
                source: source
            )
        )

        let segmentID = try await database.insertSegment(
            bundleID: bundleID,
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(60),
            windowName: "Window",
            browserUrl: nil,
            type: 0
        )

        let frameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                encodingStatus: .success,
                metadata: FrameMetadata(
                    appBundleID: bundleID,
                    appName: bundleID,
                    windowName: "Window"
                ),
                source: source
            )
        )

        _ = try await database.indexFrameText(
            mainText: text,
            chromeText: nil,
            windowTitle: "Window",
            segmentId: segmentID,
            frameId: frameID
        )

        return FrameID(value: frameID)
    }

    private func close(_ fixture: AdapterFixture) async throws {
        await fixture.adapter.shutdown()
        try await fixture.retraceDatabase.close()
        try await fixture.rewindDatabase.close()
    }

    func testMostRecentFramesExcludeRetraceFramesBeforeCutoff() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let preCutoffNativeFrame = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(-3600),
            bundleID: "com.retrace.old",
            text: "old native frame",
            source: .native
        )
        let postCutoffNativeFrame = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.retrace.new",
            text: "new native frame",
            source: .native
        )
        let preCutoffRewindFrame = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-1800),
            bundleID: "com.rewind.old",
            text: "rewind frame",
            source: .rewind
        )

        let frames = try await fixture.adapter.getMostRecentFrames(limit: 10)
        let resultKeys = Set(frames.map { "\($0.source.rawValue):\($0.id.value)" })

        XCTAssertFalse(resultKeys.contains("native:\(preCutoffNativeFrame.value)"))
        XCTAssertTrue(resultKeys.contains("native:\(postCutoffNativeFrame.value)"))
        XCTAssertTrue(resultKeys.contains("rewind:\(preCutoffRewindFrame.value)"))
    }

    func testSearchExcludesRetraceMatchesBeforeCutoff() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let preCutoffNativeFrame = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(-3600),
            bundleID: "com.retrace.old",
            text: "robert old native",
            source: .native
        )
        let preCutoffRewindFrame = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-1800),
            bundleID: "com.rewind.old",
            text: "robert rewind",
            source: .rewind
        )

        let results = try await fixture.adapter.search(query: SearchQuery(text: "robert"))
        let resultKeys = Set(results.results.map { "\($0.source.rawValue):\($0.id.value)" })

        XCTAssertFalse(resultKeys.contains("native:\(preCutoffNativeFrame.value)"))
        XCTAssertTrue(resultKeys.contains("rewind:\(preCutoffRewindFrame.value)"))
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results.first?.source, .rewind)
    }

    func testDistinctDatesExcludePreCutoffRetraceDates() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 * 2),
            bundleID: "com.retrace.old",
            text: "native old",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 2),
            bundleID: "com.retrace.new",
            text: "native new",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 * 3),
            bundleID: "com.rewind.old",
            text: "rewind old",
            source: .rewind
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let dates = try await fixture.adapter.getDistinctDates()
        let normalized = Set(dates.map { calendar.startOfDay(for: $0) })

        XCTAssertTrue(normalized.contains(calendar.startOfDay(for: cutoffDate.addingTimeInterval(86400 * 2))))
        XCTAssertTrue(normalized.contains(calendar.startOfDay(for: cutoffDate.addingTimeInterval(-86400 * 3))))
        XCTAssertFalse(normalized.contains(calendar.startOfDay(for: cutoffDate.addingTimeInterval(-86400 * 2))))
    }

    func testDistinctHoursExcludePreCutoffRetraceHours() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let day = cutoffDate.addingTimeInterval(-86400)
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: day.addingTimeInterval(9 * 3600),
            bundleID: "com.retrace.old",
            text: "native hour",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: day.addingTimeInterval(10 * 3600),
            bundleID: "com.rewind.old",
            text: "rewind hour",
            source: .rewind
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let hours = try await fixture.adapter.getDistinctHoursForDate(day)
        let hourValues = Set(hours.map { calendar.component(.hour, from: $0) })

        XCTAssertEqual(hourValues, [10])
    }

    func testDistinctAppBundleIDsExcludePreCutoffRetraceApps() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(-7200),
            bundleID: "com.retrace.old",
            text: "native old",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(7200),
            bundleID: "com.retrace.new",
            text: "native new",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-3600),
            bundleID: "com.rewind.old",
            text: "rewind old",
            source: .rewind
        )

        let bundleIDs = try await fixture.adapter.getDistinctAppBundleIDs()

        XCTAssertFalse(bundleIDs.contains("com.retrace.old"))
        XCTAssertTrue(bundleIDs.contains("com.retrace.new"))
        XCTAssertTrue(bundleIDs.contains("com.rewind.old"))
    }
}
