import XCTest
import CoreGraphics
import Shared
import Database
import Storage
import SQLCipher
@testable import App

final class InPageURLCaptureRoutingTests: XCTestCase {
    func testHostBrowserBundleIDMapsExactChromiumBrowser() {
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.google.Chrome"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "ai.perplexity.comet"),
            "ai.perplexity.comet"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.Browser"),
            "company.thebrowser.Browser"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia"),
            "company.thebrowser.dia"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.sigmaos.sigmaos.macos"),
            "com.sigmaos.sigmaos.macos"
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
            AppCoordinator.inPageURLHostBrowserBundleID(for: "ai.perplexity.comet.app.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            "ai.perplexity.comet"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia.app.ffffffffffffffffffffffffffffffff"),
            "company.thebrowser.dia"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.sigmaos.sigmaos.macos.app.gggggggggggggggggggggggggggggggg"),
            "com.sigmaos.sigmaos.macos"
        )
    }

    func testHostBrowserBundleIDRejectsUnsupportedBundleIDs() {
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.apple.Safari"))
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.example.notabrowser"))
    }

    func testPreferredURLNeedleIncludesQueryForYouTubeWatchURL() {
        XCTAssertEqual(
            AppCoordinator.preferredURLNeedle(
                from: "https://www.youtube.com/watch?v=CA73grSSk8E&t=388"
            ),
            "youtube.com/watch?v=CA73grSSk8E&t=388"
        )
    }

    func testPreferredURLNeedleKeepsExactPathWithoutQuery() {
        XCTAssertEqual(
            AppCoordinator.preferredURLNeedle(
                from: "https://www.youtube.com/shorts/2AhT7suEBRw"
            ),
            "youtube.com/shorts/2AhT7suEBRw"
        )
    }

    func testPreferredURLNeedleRetainsSlashWhenRootURLHasQuery() {
        XCTAssertEqual(
            AppCoordinator.preferredURLNeedle(
                from: "https://www.youtube.com/?persist_gl=1"
            ),
            "youtube.com/?persist_gl=1"
        )
    }
}

final class SegmentUsageAlignmentTests: XCTestCase {
    func testSegmentEndDateForSessionTransitionUsesTransitionTimestampWhenNotIdle() {
        let lastFrame = Date(timeIntervalSince1970: 1_700_000_000)
        let transition = lastFrame.addingTimeInterval(45)

        let result = AppCoordinator.segmentEndDateForSessionTransition(
            lastFrameTimestamp: lastFrame,
            transitionTimestamp: transition,
            idleDetected: false
        )

        XCTAssertEqual(result, transition)
    }

    func testSegmentEndDateForSessionTransitionUsesLastFrameWhenIdleDetected() {
        let lastFrame = Date(timeIntervalSince1970: 1_700_000_000)
        let transition = lastFrame.addingTimeInterval(600)

        let result = AppCoordinator.segmentEndDateForSessionTransition(
            lastFrameTimestamp: lastFrame,
            transitionTimestamp: transition,
            idleDetected: true
        )

        XCTAssertEqual(result, lastFrame)
    }

    func testSegmentEndDateForSessionTransitionFallsBackWhenLastFrameMissing() {
        let transition = Date(timeIntervalSince1970: 1_700_000_600)

        let result = AppCoordinator.segmentEndDateForSessionTransition(
            lastFrameTimestamp: nil,
            transitionTimestamp: transition,
            idleDetected: true
        )

        XCTAssertEqual(result, transition)
    }

    func testSegmentEndDateForShutdownUsesLastFrameWhenAvailable() {
        let lastFrame = Date(timeIntervalSince1970: 1_700_000_000)
        let shutdown = lastFrame.addingTimeInterval(600)

        let result = AppCoordinator.segmentEndDateForShutdown(
            lastFrameTimestamp: lastFrame,
            shutdownTimestamp: shutdown
        )

        XCTAssertEqual(result, lastFrame)
    }

    func testSegmentEndDateForShutdownFallsBackWhenLastFrameMissing() {
        let shutdown = Date(timeIntervalSince1970: 1_700_000_600)

        let result = AppCoordinator.segmentEndDateForShutdown(
            lastFrameTimestamp: nil,
            shutdownTimestamp: shutdown
        )

        XCTAssertEqual(result, shutdown)
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

final class DBStorageSnapshotLoggingTests: XCTestCase {
    func testDBStorageSnapshotDeltaSummaryUsesSameDayDelta() {
        let currentDay = Date(timeIntervalSince1970: 1_773_744_000)
        let previous = AppCoordinator.DBStorageSnapshotLogState(
            localDay: currentDay,
            dbBytes: 100,
            walBytes: 200,
            sampledAt: currentDay
        )
        let current = AppCoordinator.DBStorageSnapshotLogState(
            localDay: currentDay.addingTimeInterval(300),
            dbBytes: 160,
            walBytes: 260,
            sampledAt: currentDay.addingTimeInterval(300)
        )

        let delta = AppCoordinator.dbStorageSnapshotDeltaSummary(
            current: current,
            previous: previous
        )

        XCTAssertEqual(delta, .init(dbDeltaBytes: 60, walDeltaBytes: 60))
    }

    func testDBStorageSnapshotDeltaSummaryResetsAcrossDays() {
        let previous = AppCoordinator.DBStorageSnapshotLogState(
            localDay: Date(timeIntervalSince1970: 1_773_657_600),
            dbBytes: 100,
            walBytes: 200,
            sampledAt: Date(timeIntervalSince1970: 1_773_657_600)
        )
        let current = AppCoordinator.DBStorageSnapshotLogState(
            localDay: Date(timeIntervalSince1970: 1_773_744_000),
            dbBytes: 160,
            walBytes: 260,
            sampledAt: Date(timeIntervalSince1970: 1_773_744_060)
        )

        let delta = AppCoordinator.dbStorageSnapshotDeltaSummary(
            current: current,
            previous: previous
        )

        XCTAssertEqual(delta, .init(dbDeltaBytes: nil, walDeltaBytes: nil))
    }
}

final class DBStorageSnapshotEstimateTests: XCTestCase {
    private func makeServices(storageRoot: URL) -> ServiceContainer {
        let crashReportDirectory = storageRoot.appendingPathComponent("crash_reports", isDirectory: true).path
        return ServiceContainer(
            databasePath: storageRoot.appendingPathComponent("retrace.db").path,
            storageConfig: StorageConfig(
                storageRootPath: storageRoot.path,
                retentionDays: nil,
                maxStorageGB: nil,
                segmentDurationSeconds: 300
            ),
            storageCrashReportDirectory: crashReportDirectory
        )
    }

    private func makeLocalDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: 0
            )
        )!
    }

    private func growDatabase(_ database: DatabaseManager, timestamp: Date, seed: Int) async throws {
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(60),
                frameCount: 1,
                fileSizeBytes: 1024,
                relativePath: "chunks/202603/13/\(seed).mp4",
                width: 1920,
                height: 1080,
                source: .native
            )
        )
        let segmentID = try await database.insertSegment(
            bundleID: "com.test.snapshot.\(seed)",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(60),
            windowName: "Window \(seed)",
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
                metadata: .empty,
                source: .native
            )
        )
        _ = try await database.indexFrameText(
            mainText: String(repeating: "x", count: 250_000),
            chromeText: nil,
            windowTitle: "Title \(seed)",
            segmentId: segmentID,
            frameId: frameID
        )
    }

    func testDailyDBStorageEstimatedBytesUsesAdjacentLocalDayRows() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBStorageSnapshotAdjacentDays_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()

            let firstSnapshot = makeLocalDate(year: 2026, month: 3, day: 13, hour: 23, minute: 50)
            let secondSnapshot = makeLocalDate(year: 2026, month: 3, day: 14, hour: 0, minute: 10)

            try await services.database.recordDBStorageSnapshot(timestamp: firstSnapshot)
            try await growDatabase(services.database, timestamp: firstSnapshot.addingTimeInterval(60), seed: 1)
            try await services.database.checkpoint()
            try await services.database.recordDBStorageSnapshot(timestamp: secondSnapshot)

            let estimates = try await coordinator.getDailyDBStorageEstimatedBytes(
                from: firstSnapshot,
                to: secondSnapshot
            )

            XCTAssertEqual(estimates.count, 1)
            XCTAssertEqual(Calendar.current.startOfDay(for: estimates[0].date), Calendar.current.startOfDay(for: secondSnapshot))
            XCTAssertGreaterThan(estimates[0].value, 0)

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }

    func testDailyDBStorageEstimatedBytesReturnsPositiveDiffAfterAboutOneDay() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBStorageSnapshotHasDay_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()

            let firstSnapshot = makeLocalDate(year: 2026, month: 3, day: 13, hour: 12, minute: 0)
            let secondSnapshot = makeLocalDate(year: 2026, month: 3, day: 14, hour: 12, minute: 5)

            try await services.database.recordDBStorageSnapshot(timestamp: firstSnapshot)
            try await growDatabase(services.database, timestamp: firstSnapshot.addingTimeInterval(120), seed: 2)
            try await services.database.checkpoint()
            try await services.database.recordDBStorageSnapshot(timestamp: secondSnapshot)

            let estimates = try await coordinator.getDailyDBStorageEstimatedBytes(
                from: firstSnapshot,
                to: secondSnapshot
            )

            XCTAssertEqual(estimates.count, 1)
            XCTAssertEqual(Calendar.current.startOfDay(for: estimates[0].date), Calendar.current.startOfDay(for: secondSnapshot))
            XCTAssertGreaterThan(estimates[0].value, 0)

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }
}

final class DataAdapterRewindBoundaryTests: XCTestCase {
    private final class BrokenDatabaseConnection: DatabaseConnection, @unchecked Sendable {
        func getConnection() -> OpaquePointer? {
            nil
        }

        func prepare(sql: String) throws -> OpaquePointer? {
            throw DatabaseConnectionError.notConnected
        }

        @discardableResult
        func execute(sql: String) throws -> Int {
            throw DatabaseConnectionError.notConnected
        }

        func beginTransaction() throws {
            throw DatabaseConnectionError.notConnected
        }

        func commit() throws {
            throw DatabaseConnectionError.notConnected
        }

        func rollback() throws {
            throw DatabaseConnectionError.notConnected
        }

        func finalize(_ statement: OpaquePointer?) {}
    }

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

    private struct SeededFrame {
        let frameID: FrameID
        let segmentID: Int64
    }

    private func makeFixture(
        cutoffDate: Date,
        retraceReadConnectionPool: SQLiteReadConnectionPool? = nil
    ) async throws -> AdapterFixture {
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
        let activeRetraceReadConnectionPool = retraceReadConnectionPool ?? SQLiteReadConnectionPool(
            label: "test_retrace_search",
            sharedConnection: retraceConnection
        )
        let adapter = DataAdapter(
            retraceConnection: retraceConnection,
            retraceReadConnectionPool: activeRetraceReadConnectionPool,
            retraceConfig: .retrace(),
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

    private func seedFrameRecord(
        in database: DatabaseManager,
        timestamp: Date,
        bundleID: String,
        text: String,
        source: FrameSource,
        windowName: String = "Window",
        browserURL: String? = nil
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
                source: source
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
                source: source
            )
        )

        _ = try await database.indexFrameText(
            mainText: text,
            chromeText: nil,
            windowTitle: windowName,
            segmentId: segmentID,
            frameId: frameID
        )

        return SeededFrame(
            frameID: FrameID(value: frameID),
            segmentID: segmentID
        )
    }

    private func seedFrame(
        in database: DatabaseManager,
        timestamp: Date,
        bundleID: String,
        text: String,
        source: FrameSource,
        windowName: String = "Window",
        browserURL: String? = nil
    ) async throws -> FrameID {
        try await seedFrameRecord(
            in: database,
            timestamp: timestamp,
            bundleID: bundleID,
            text: text,
            source: source,
            windowName: windowName,
            browserURL: browserURL
        ).frameID
    }

    private func close(_ fixture: AdapterFixture) async throws {
        await fixture.adapter.shutdown()
        try await fixture.retraceDatabase.close()
        try await fixture.rewindDatabase.close()
    }

    private func withConnection<T>(
        _ database: DatabaseManager,
        _ body: (OpaquePointer) throws -> T
    ) async throws -> T {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        return try body(db)
    }

    private func fetchInt64(
        db: OpaquePointer,
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil
    ) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare SQL: \(sql)")
            return 0
        }

        if let bind, let statement {
            bind(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("Expected row for SQL: \(sql)")
            return 0
        }

        return sqlite3_column_int64(statement, 0)
    }

    private func decodeMetricMetadata(_ metadata: String?) throws -> [String: Any] {
        let json = try XCTUnwrap(metadata)
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    private func executeUpdate(
        db: OpaquePointer,
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil
    ) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare SQL: \(sql)")
            return 0
        }

        if let bind, let statement {
            bind(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            XCTFail("Expected update to finish for SQL: \(sql)")
            return 0
        }

        return sqlite3_last_insert_rowid(db)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    private func tagID(named name: String, in database: DatabaseManager) async throws -> Int64 {
        try await withConnection(database) { db in
            _ = try executeUpdate(
                db: db,
                sql: "INSERT OR IGNORE INTO tag (name) VALUES (?);",
                bind: { sqlite3_bind_text($0, 1, (name as NSString).utf8String, -1, nil) }
            )
            return try fetchInt64(
                db: db,
                sql: "SELECT id FROM tag WHERE name = ?;",
                bind: { sqlite3_bind_text($0, 1, (name as NSString).utf8String, -1, nil) }
            )
        }
    }

    private func attachTag(named name: String, to segmentID: Int64, in database: DatabaseManager) async throws {
        let tagID = try await tagID(named: name, in: database)
        try await withConnection(database) { db in
            _ = try executeUpdate(
                db: db,
                sql: "INSERT OR IGNORE INTO segment_tag (segmentId, tagId) VALUES (?, ?);",
                bind: {
                    sqlite3_bind_int64($0, 1, segmentID)
                    sqlite3_bind_int64($0, 2, tagID)
                }
            )
        }
    }

    private func addComment(to segmentID: Int64, in database: DatabaseManager, body: String = "comment") async throws {
        try await withConnection(database) { db in
            let commentID = try executeUpdate(
                db: db,
                sql: """
                    INSERT INTO segment_comment (body, author, attachmentsJson)
                    VALUES (?, 'test', '[]');
                    """,
                bind: { sqlite3_bind_text($0, 1, (body as NSString).utf8String, -1, nil) }
            )
            _ = try executeUpdate(
                db: db,
                sql: "INSERT INTO segment_comment_link (commentId, segmentId) VALUES (?, ?);",
                bind: {
                    sqlite3_bind_int64($0, 1, commentID)
                    sqlite3_bind_int64($0, 2, segmentID)
                }
            )
        }
    }

    private func normalizedDays(_ dates: [Date]) -> Set<Date> {
        let currentCalendar = calendar()
        return Set(dates.map { currentCalendar.startOfDay(for: $0) })
    }

    private func hourValues(_ dates: [Date]) -> Set<Int> {
        let currentCalendar = calendar()
        return Set(dates.map { currentCalendar.component(.hour, from: $0) })
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

    func testDeletionHiddenNativeFramesAreExcludedFromTimelineAndDirectLookups() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let timestamp = cutoffDate.addingTimeInterval(3_600)
        let seeded = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: timestamp,
            bundleID: "com.retrace.hidden",
            text: "hidden native frame",
            source: .native,
            browserURL: "https://example.com/hidden"
        )
        try await fixture.retraceDatabase.insertNodes(
            frameID: seeded.frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [:],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await fixture.retraceDatabase.updateFrameProcessingStatus(
            frameID: seeded.frameID.value,
            status: 5,
            rewritePurpose: "deletion"
        )

        let recentFrames = try await fixture.adapter.getMostRecentFrames(limit: 10)
        let frameLookup = try await fixture.adapter.getFrameWithVideoInfoByID(id: seeded.frameID)
        let nodesByTimestamp = try await fixture.adapter.getAllOCRNodes(
            timestamp: timestamp,
            source: .native
        )
        let nodesByID = try await fixture.adapter.getAllOCRNodes(
            frameID: seeded.frameID,
            source: .native
        )

        XCTAssertFalse(recentFrames.contains { $0.id == seeded.frameID && $0.source == .native })
        XCTAssertNil(frameLookup)
        XCTAssertTrue(nodesByTimestamp.isEmpty)
        XCTAssertTrue(nodesByID.isEmpty)
    }

    func testMostRecentFramesTreatInactiveFiltersSameAsNilFilters() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let nativeFrame = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.retrace.filtered.native",
            text: "native frame after cutoff",
            source: .native
        )
        let rewindFrame = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-1800),
            bundleID: "com.rewind.filtered",
            text: "rewind frame before cutoff",
            source: .rewind
        )

        let baseline = try await fixture.adapter.getMostRecentFrames(limit: 10)
        let inactiveFilterResults = try await fixture.adapter.getMostRecentFrames(
            limit: 10,
            filters: FilterCriteria()
        )

        let baselineKeys = baseline.map { "\($0.source.rawValue):\($0.id.value)" }
        let inactiveFilterKeys = inactiveFilterResults.map { "\($0.source.rawValue):\($0.id.value)" }

        XCTAssertEqual(baselineKeys, inactiveFilterKeys)
        XCTAssertEqual(
            baselineKeys,
            ["native:\(nativeFrame.value)", "rewind:\(rewindFrame.value)"]
        )
    }

    func testTimelineReadsTreatInactiveFiltersSameAsNilFilters() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 2, day: 5, hour: 0, minute: 0, second: 0))!

        let firstFrameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: dayOne.addingTimeInterval(8 * 3600),
            bundleID: "com.retrace.filtered.one",
            text: "first filtered frame",
            source: .native
        )
        let secondFrameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: dayOne.addingTimeInterval(12 * 3600),
            bundleID: "com.retrace.filtered.two",
            text: "second filtered frame",
            source: .native
        )

        let filters = FilterCriteria()

        let baselineRange = try await fixture.adapter.getFramesWithVideoInfo(
            from: dayOne,
            to: dayOne.addingTimeInterval(86399),
            limit: 10
        )
        let inactiveFilterRange = try await fixture.adapter.getFramesWithVideoInfo(
            from: dayOne,
            to: dayOne.addingTimeInterval(86399),
            limit: 10,
            filters: filters
        )
        XCTAssertEqual(baselineRange.map(\.frame.id.value), inactiveFilterRange.map(\.frame.id.value))
        XCTAssertEqual(inactiveFilterRange.map(\.frame.id.value), [firstFrameID.value, secondFrameID.value])

        let baselineBefore = try await fixture.adapter.getFramesWithVideoInfoBefore(
            timestamp: dayOne.addingTimeInterval(10 * 3600),
            limit: 10
        )
        let inactiveFilterBefore = try await fixture.adapter.getFramesWithVideoInfoBefore(
            timestamp: dayOne.addingTimeInterval(10 * 3600),
            limit: 10,
            filters: filters
        )
        XCTAssertEqual(baselineBefore.map(\.frame.id.value), inactiveFilterBefore.map(\.frame.id.value))
        XCTAssertEqual(inactiveFilterBefore.map(\.frame.id.value), [firstFrameID.value])

        let baselineAfter = try await fixture.adapter.getFramesWithVideoInfoAfter(
            timestamp: dayOne.addingTimeInterval(10 * 3600),
            limit: 10
        )
        let inactiveFilterAfter = try await fixture.adapter.getFramesWithVideoInfoAfter(
            timestamp: dayOne.addingTimeInterval(10 * 3600),
            limit: 10,
            filters: filters
        )
        XCTAssertEqual(baselineAfter.map(\.frame.id.value), inactiveFilterAfter.map(\.frame.id.value))
        XCTAssertEqual(inactiveFilterAfter.map(\.frame.id.value), [secondFrameID.value])
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

    func testSearchIgnoresShellFlagsInCommandLikeQuery() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let command = #"osascript -e 'tell application "Codex" to hide' -e 'tell application "Retrace" to activate' -e 'delay 1'"#
        let frameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.apple.Terminal",
            text: command,
            source: .native
        )

        let results = try await fixture.adapter.search(query: SearchQuery(text: command))

        XCTAssertTrue(results.results.contains(where: { $0.id.value == frameID.value && $0.source == .native }))
    }

    func testSearchStillTreatsPlainDashTermsAsExclusions() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let excludedFrameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.apple.Terminal",
            text: "swift java",
            source: .native
        )
        let includedFrameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(7200),
            bundleID: "com.apple.Terminal",
            text: "swift objc",
            source: .native
        )

        let results = try await fixture.adapter.search(query: SearchQuery(text: "swift -java"))
        let resultIDs = Set(results.results.map(\.id.value))

        XCTAssertFalse(resultIDs.contains(excludedFrameID.value))
        XCTAssertTrue(resultIDs.contains(includedFrameID.value))
    }

    func testSearchUsesLastMatchingNodeForThumbnailPreviewAcrossModes() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let timestamp = cutoffDate.addingTimeInterval(3600)
        let seeded = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: timestamp,
            bundleID: "com.retrace.search",
            text: "alpha beta alpha",
            source: .native
        )
        try await fixture.retraceDatabase.insertNodes(
            frameID: seeded.frameID,
            nodes: [
                (textOffset: 0, textLength: 5, bounds: CGRect(x: 10, y: 10, width: 120, height: 24), windowIndex: nil),
                (textOffset: 6, textLength: 4, bounds: CGRect(x: 160, y: 10, width: 120, height: 24), windowIndex: nil),
                (textOffset: 11, textLength: 5, bounds: CGRect(x: 310, y: 10, width: 120, height: 24), windowIndex: nil)
            ],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        let allResults = try await fixture.adapter.search(query: SearchQuery(text: "alpha", mode: .all))
        let relevantResults = try await fixture.adapter.search(query: SearchQuery(text: "alpha", mode: .relevant))

        let allResult = try XCTUnwrap(allResults.results.first)
        let relevantResult = try XCTUnwrap(relevantResults.results.first)

        XCTAssertEqual(allResults.results.count, 1)
        XCTAssertEqual(relevantResults.results.count, 1)
        XCTAssertEqual(allResult.highlightNode?.nodeOrder, 2)
        XCTAssertEqual(relevantResult.highlightNode?.nodeOrder, 2)
    }

    func testSearchDeduplicatesSameTextWhenOnlyOneAxisMovesFarEnough() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let first = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.retrace.search",
            text: "alpha",
            source: .native
        )
        let second = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3660),
            bundleID: "com.retrace.search",
            text: "alpha",
            source: .native
        )

        try await fixture.retraceDatabase.insertNodes(
            frameID: first.frameID,
            nodes: [
                (textOffset: 0, textLength: 5, bounds: CGRect(x: 10, y: 10, width: 120, height: 24), windowIndex: nil)
            ],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await fixture.retraceDatabase.insertNodes(
            frameID: second.frameID,
            nodes: [
                (textOffset: 0, textLength: 5, bounds: CGRect(x: 10, y: 340, width: 120, height: 24), windowIndex: nil)
            ],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        let results = try await fixture.adapter.search(
            query: SearchQuery(text: "alpha", mode: .all, sortOrder: .oldestFirst)
        )

        XCTAssertEqual(results.results.map(\.id.value), [first.frameID.value])
    }

    func testSearchKeepsSameTextWhenBothAxesMoveFarEnough() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let first = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.retrace.search",
            text: "alpha",
            source: .native
        )
        let second = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3660),
            bundleID: "com.retrace.search",
            text: "alpha",
            source: .native
        )

        try await fixture.retraceDatabase.insertNodes(
            frameID: first.frameID,
            nodes: [
                (textOffset: 0, textLength: 5, bounds: CGRect(x: 10, y: 10, width: 120, height: 24), windowIndex: nil)
            ],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await fixture.retraceDatabase.insertNodes(
            frameID: second.frameID,
            nodes: [
                (textOffset: 0, textLength: 5, bounds: CGRect(x: 340, y: 340, width: 120, height: 24), windowIndex: nil)
            ],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        let results = try await fixture.adapter.search(
            query: SearchQuery(text: "alpha", mode: .all, sortOrder: .oldestFirst)
        )

        XCTAssertEqual(results.results.map(\.id.value), [first.frameID.value, second.frameID.value])
    }

    func testSearchThrowsWhenNativeSourceFailsUnexpectedlyAndRewindHasNoMatches() async throws {
        let cutoffDate = makeCutoffDate()
        let brokenRetracePool = SQLiteReadConnectionPool(
            label: "broken_retrace_search",
            sharedConnection: BrokenDatabaseConnection()
        )
        let fixture = try await makeFixture(
            cutoffDate: cutoffDate,
            retraceReadConnectionPool: brokenRetracePool
        )
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-1800),
            bundleID: "com.rewind.nomatch",
            text: "completely different content",
            source: .rewind
        )

        do {
            _ = try await fixture.adapter.search(query: SearchQuery(text: "needle"))
            XCTFail("Expected unexpected native search failure to be surfaced")
        } catch DatabaseConnectionError.notConnected {
            // Expected: unexpected source failures should no longer be converted into empty results.
        } catch {
            XCTFail("Expected notConnected, got \(error)")
        }
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

    func testFilteredDistinctDatesRespectActiveAppFilter() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let matchingTimestamp = cutoffDate.addingTimeInterval(86400 * 2 + 9 * 3600)
        let nonMatchingTimestamp = cutoffDate.addingTimeInterval(86400 * 4 + 11 * 3600)

        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: matchingTimestamp,
            bundleID: "com.apple.Safari",
            text: "matching app",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: nonMatchingTimestamp,
            bundleID: "com.apple.Terminal",
            text: "non matching app",
            source: .native
        )

        let filters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        let dates = try await fixture.adapter.getDistinctDates(filters: filters)

        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: matchingTimestamp)])
    }

    func testFilteredDistinctHoursRespectActiveAppFilter() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let day = cutoffDate.addingTimeInterval(86400 * 2)
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: day.addingTimeInterval(9 * 3600),
            bundleID: "com.apple.Safari",
            text: "matching morning",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: day.addingTimeInterval(10 * 3600),
            bundleID: "com.apple.Terminal",
            text: "non matching hour",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: day.addingTimeInterval(15 * 3600),
            bundleID: "com.apple.Safari",
            text: "matching afternoon",
            source: .native
        )

        let filters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        let hours = try await fixture.adapter.getDistinctHoursForDate(day, filters: filters)

        XCTAssertEqual(hourValues(hours), [9, 15])
    }

    func testFilteredDistinctCalendarRespectsMetadataFilterAndSourceSelection() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let rewindDay = cutoffDate.addingTimeInterval(-86400 * 2)
        let nativeDay = cutoffDate.addingTimeInterval(86400 * 2)

        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: rewindDay.addingTimeInterval(10 * 3600),
            bundleID: "com.apple.Safari",
            text: "matching rewind url",
            source: .rewind,
            windowName: "Daily Notes",
            browserURL: "https://docs.example.com/matching"
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: rewindDay.addingTimeInterval(12 * 3600),
            bundleID: "com.apple.Safari",
            text: "non matching rewind url",
            source: .rewind,
            windowName: "Other Window",
            browserURL: "https://docs.example.com/other"
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: nativeDay.addingTimeInterval(9 * 3600),
            bundleID: "com.apple.Safari",
            text: "matching native url",
            source: .native,
            windowName: "Daily Notes",
            browserURL: "https://docs.example.com/matching"
        )

        let filters = FilterCriteria(
            selectedSources: [.rewind],
            browserUrlFilter: "matching"
        )

        let dates = try await fixture.adapter.getDistinctDates(filters: filters)
        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: rewindDay)])

        let hours = try await fixture.adapter.getDistinctHoursForDate(rewindDay, filters: filters)
        XCTAssertEqual(hourValues(hours), [10])
    }

    func testFilteredDistinctCalendarRespectsSelectedTagsAndSkipsRewind() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let tagged = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 2 + 8 * 3600),
            bundleID: "com.apple.Safari",
            text: "tagged native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 2 + 9 * 3600),
            bundleID: "com.apple.Safari",
            text: "untagged native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 + 10 * 3600),
            bundleID: "com.apple.Safari",
            text: "rewind frame",
            source: .rewind
        )

        try await attachTag(named: "focus", to: tagged.segmentID, in: fixture.retraceDatabase)
        let focusTagID = try await tagID(named: "focus", in: fixture.retraceDatabase)
        let filters = FilterCriteria(selectedTags: [focusTagID])

        let dates = try await fixture.adapter.getDistinctDates(filters: filters)
        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: cutoffDate.addingTimeInterval(86400 * 2))])

        let hours = try await fixture.adapter.getDistinctHoursForDate(
            cutoffDate.addingTimeInterval(86400 * 2),
            filters: filters
        )
        XCTAssertEqual(hourValues(hours), [8])
    }

    func testFilteredDistinctCalendarRespectsOnlyHiddenFilter() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let hidden = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 3 + 7 * 3600),
            bundleID: "com.apple.Safari",
            text: "hidden native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 3 + 11 * 3600),
            bundleID: "com.apple.Safari",
            text: "visible native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 * 2 + 9 * 3600),
            bundleID: "com.apple.Safari",
            text: "rewind frame",
            source: .rewind
        )

        try await attachTag(named: "hidden", to: hidden.segmentID, in: fixture.retraceDatabase)
        let filters = FilterCriteria(hiddenFilter: .onlyHidden)

        let hiddenDay = cutoffDate.addingTimeInterval(86400 * 3)
        let dates = try await fixture.adapter.getDistinctDates(filters: filters)
        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: hiddenDay)])

        let hours = try await fixture.adapter.getDistinctHoursForDate(hiddenDay, filters: filters)
        XCTAssertEqual(hourValues(hours), [7])
    }

    func testFilteredDistinctCalendarRespectsCommentsOnlyFilter() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let commented = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 4 + 9 * 3600),
            bundleID: "com.apple.Safari",
            text: "commented native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(86400 * 4 + 13 * 3600),
            bundleID: "com.apple.Safari",
            text: "plain native frame",
            source: .native
        )
        _ = try await seedFrameRecord(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 + 9 * 3600),
            bundleID: "com.apple.Safari",
            text: "rewind frame",
            source: .rewind
        )

        try await addComment(to: commented.segmentID, in: fixture.retraceDatabase)
        let filters = FilterCriteria(commentFilter: .commentsOnly)
        let commentDay = cutoffDate.addingTimeInterval(86400 * 4)

        let dates = try await fixture.adapter.getDistinctDates(filters: filters)
        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: commentDay)])

        let hours = try await fixture.adapter.getDistinctHoursForDate(commentDay, filters: filters)
        XCTAssertEqual(hourValues(hours), [9])
    }

    func testFilteredDistinctDatesSkipRewindWhenDateRangeStartsAfterCutoff() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let nativeTimestamp = cutoffDate.addingTimeInterval(86400 * 2 + 14 * 3600)
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: nativeTimestamp,
            bundleID: "com.apple.Safari",
            text: "post cutoff native frame",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-86400 * 2 + 10 * 3600),
            bundleID: "com.apple.Safari",
            text: "pre cutoff rewind frame",
            source: .rewind
        )

        let filters = FilterCriteria(
            dateRanges: [
                DateRangeCriterion(
                    start: cutoffDate.addingTimeInterval(3600),
                    end: cutoffDate.addingTimeInterval(86400 * 3)
                )
            ]
        )

        let dates = try await fixture.adapter.getDistinctDates(filters: filters)
        XCTAssertEqual(normalizedDays(dates), [calendar().startOfDay(for: nativeTimestamp)])
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

    func testDistinctAppBundleIDsForNativeSourceExcludeRewindApps() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(7200),
            bundleID: "com.retrace.new",
            text: "native new",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(-7200),
            bundleID: "com.retrace.old",
            text: "native old",
            source: .native
        )
        _ = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-3600),
            bundleID: "com.rewind.old",
            text: "rewind old",
            source: .rewind
        )

        let bundleIDs = try await fixture.adapter.getDistinctAppBundleIDs(source: .native)

        XCTAssertEqual(bundleIDs, ["com.retrace.new"])
    }

    func testDistinctAppBundleIDsForRewindSourceExcludeRetraceApps() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

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

        let bundleIDs = try await fixture.adapter.getDistinctAppBundleIDs(source: .rewind)

        XCTAssertEqual(bundleIDs, ["com.rewind.old"])
    }

    func testDeleteFrameRemovesFTSRowsForNativeSource() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let frameID = try await seedFrame(
            in: fixture.retraceDatabase,
            timestamp: cutoffDate.addingTimeInterval(3600),
            bundleID: "com.retrace.delete",
            text: "native delete me",
            source: .native
        )

        let docid = try await withConnection(fixture.retraceDatabase) { db in
            try fetchInt64(
                db: db,
                sql: "SELECT MAX(docid) FROM doc_segment WHERE frameId = ?;",
                bind: { sqlite3_bind_int64($0, 1, frameID.value) }
            )
        }
        XCTAssertGreaterThan(docid, 0)

        try await fixture.adapter.deleteFrame(frameID: frameID, source: .native)

        try await withConnection(fixture.retraceDatabase) { db in
            XCTAssertEqual(
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
                    bind: { sqlite3_bind_int64($0, 1, frameID.value) }
                ),
                0
            )
            XCTAssertEqual(
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
                    bind: { sqlite3_bind_int64($0, 1, docid) }
                ),
                0
            )
        }
    }

    func testDeleteFrameRemovesFTSRowsForRewindSource() async throws {
        let cutoffDate = makeCutoffDate()
        let fixture = try await makeFixture(cutoffDate: cutoffDate)
        defer {
            Task {
                try? await self.close(fixture)
            }
        }

        let frameID = try await seedFrame(
            in: fixture.rewindDatabase,
            timestamp: cutoffDate.addingTimeInterval(-3600),
            bundleID: "com.rewind.delete",
            text: "rewind delete me",
            source: .rewind
        )

        let docid = try await withConnection(fixture.rewindDatabase) { db in
            try fetchInt64(
                db: db,
                sql: "SELECT MAX(docid) FROM doc_segment WHERE frameId = ?;",
                bind: { sqlite3_bind_int64($0, 1, frameID.value) }
            )
        }
        XCTAssertGreaterThan(docid, 0)

        try await fixture.adapter.deleteFrame(frameID: frameID, source: .rewind)

        try await withConnection(fixture.rewindDatabase) { db in
            XCTAssertEqual(
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
                    bind: { sqlite3_bind_int64($0, 1, frameID.value) }
                ),
                0
            )
            XCTAssertEqual(
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
                    bind: { sqlite3_bind_int64($0, 1, docid) }
                ),
                0
            )
        }
    }
}

final class CrashRecoveryStartupTests: XCTestCase {
    private func makeServices(storageRoot: URL) -> ServiceContainer {
        let crashReportDirectory = storageRoot.appendingPathComponent("crash_reports", isDirectory: true).path
        return ServiceContainer(
            databasePath: "file:app_crash_recovery_\(UUID().uuidString)?mode=memory&cache=shared",
            storageConfig: StorageConfig(
                storageRootPath: storageRoot.path,
                retentionDays: nil,
                maxStorageGB: nil,
                segmentDurationSeconds: 300
            ),
            storageCrashReportDirectory: crashReportDirectory
        )
    }

    private func makeCapturedFrame(timestamp: Date) -> CapturedFrame {
        CapturedFrame(
            timestamp: timestamp,
            imageData: Data(repeating: 0xAB, count: 32 * 8),
            width: 8,
            height: 8,
            bytesPerRow: 32,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Window",
                browserURL: "https://example.com",
                displayID: 1
            )
        )
    }

    func testPrepareForPipelineStartFailsWhenWALUnavailable() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryBlockedWAL_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: storageRoot.appendingPathComponent("chunks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: storageRoot.appendingPathComponent("temp", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: storageRoot.appendingPathComponent("wal", isDirectory: false).path,
            contents: Data("blocking-file".utf8)
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storageRoot.path)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storageRoot.path)
            try? FileManager.default.removeItem(at: storageRoot)
        }

        do {
            try await services.initialize()

            do {
                try await coordinator.prepareForPipelineStart()
                XCTFail("Expected WAL-unavailable preflight failure")
            } catch let error as StorageError {
                guard case .walUnavailable = error else {
                    XCTFail("Expected walUnavailable, got \(error)")
                    return
                }
            }

            let walIssue = await services.storage.currentWALAvailabilityIssue()
            XCTAssertNotNil(walIssue)
            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }

    func testScheduleCrashRecoveryIfNeededCoalescesInFlightTask() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryCoalesce_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let storageManager = await services.storage
            let walManager = await storageManager.getWALManager()
            let database = await services.database
            let timestamp = Date(timeIntervalSince1970: 1_740_100_000)

            let sessionVideoID = VideoSegmentID(value: 707)
            var session = try await walManager.createSession(videoID: sessionVideoID)
            try await walManager.appendFrame(makeCapturedFrame(timestamp: timestamp), to: &session)

            _ = try await database.insertVideoSegment(
                VideoSegment(
                    id: sessionVideoID,
                    startTime: timestamp,
                    endTime: timestamp,
                    frameCount: 1,
                    fileSizeBytes: 123,
                    relativePath: "chunks/202603/12/\(sessionVideoID.value)",
                    width: 8,
                    height: 8
                )
            )

            let firstStarted = await coordinator.scheduleCrashRecoveryIfNeeded(
                skipOnboardingCheck: true,
                logFailures: false
            )
            let secondStarted = await coordinator.scheduleCrashRecoveryIfNeeded(
                skipOnboardingCheck: true,
                logFailures: false
            )

            XCTAssertTrue(firstStarted)
            XCTAssertFalse(secondStarted)
            let didRunRecovery = try await coordinator.awaitCrashRecoveryIfNeeded()
            XCTAssertTrue(didRunRecovery)
            let activeSessions = try await walManager.listActiveSessions()
            XCTAssertTrue(activeSessions.isEmpty)
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            XCTAssertTrue(unfinalisedVideos.isEmpty)

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testFinalizeUnfinalisedVideoBeforeResumingUsesActualFrameCountAndCorrectWALRoot() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryResumeFinalize_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let storageManager = await services.storage
            let database = await services.database
            let walManager = await storageManager.getWALManager()
            let timestamp = Date(timeIntervalSince1970: 1_740_200_000)

            let writer = try await storageManager.createSegmentWriter()
            try await writer.appendFrame(makeCapturedFrame(timestamp: timestamp))
            let segment = try await writer.finalize()

            let databaseVideoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: segment.id,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    frameCount: 99,
                    fileSizeBytes: segment.fileSizeBytes,
                    relativePath: segment.relativePath,
                    width: segment.width,
                    height: segment.height
                )
            )
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            let unfinalised = try XCTUnwrap(unfinalisedVideos.first(where: { $0.id == databaseVideoID }))

            _ = try await walManager.createSession(videoID: segment.id)
            let staleWALDir = storageRoot
                .appendingPathComponent("wal", isDirectory: true)
                .appendingPathComponent("active_segment_\(segment.id.value)", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staleWALDir.path))

            try await coordinator.finalizeUnfinalisedVideoBeforeResuming(unfinalised)

            let finalizedVideoRecord = try await database.getVideoSegment(
                id: VideoSegmentID(value: databaseVideoID)
            )
            let finalizedVideo = try XCTUnwrap(finalizedVideoRecord)
            XCTAssertEqual(finalizedVideo.frameCount, segment.frameCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleWALDir.path))

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testFinalizeUnfinalisedVideoBeforeResumingPreservesRecoverableStaleWALData() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryResumePreserveRecoverableWAL_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let storageManager = await services.storage
            let database = await services.database
            let walManager = await storageManager.getWALManager()
            let timestamp = Date(timeIntervalSince1970: 1_740_205_000)

            let writer = try await storageManager.createSegmentWriter()
            try await writer.appendFrame(makeCapturedFrame(timestamp: timestamp))
            let segment = try await writer.finalize()

            let databaseVideoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: segment.id,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    frameCount: 99,
                    fileSizeBytes: segment.fileSizeBytes,
                    relativePath: segment.relativePath,
                    width: segment.width,
                    height: segment.height
                )
            )
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            let unfinalised = try XCTUnwrap(unfinalisedVideos.first(where: { $0.id == databaseVideoID }))

            var staleSession = try await walManager.createSession(videoID: segment.id)
            try await walManager.appendFrame(makeCapturedFrame(timestamp: timestamp.addingTimeInterval(2)), to: &staleSession)

            let staleWALDir = storageRoot
                .appendingPathComponent("wal", isDirectory: true)
                .appendingPathComponent("active_segment_\(segment.id.value)", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staleWALDir.path))

            try await coordinator.finalizeUnfinalisedVideoBeforeResuming(unfinalised)

            let recoverableFrameCount = try await walManager.recoverableFrameCountIfPresent(videoID: segment.id)
            XCTAssertEqual(recoverableFrameCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staleWALDir.path))

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testShouldResumeUnfinalisedVideoReturnsFalseWhenActiveWALSessionStillExists() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoverySkipResume_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let storageManager = await services.storage
            let database = await services.database
            let timestamp = Date(timeIntervalSince1970: 1_740_250_000)

            let writer = try await storageManager.createSegmentWriter()
            let incrementalWriter = try XCTUnwrap(writer as? IncrementalSegmentWriter)
            let pathVideoID = await writer.segmentID
            let relativePath = await writer.relativePath
            try await writer.appendFrame(makeCapturedFrame(timestamp: timestamp))
            try await incrementalWriter.cancelPreservingRecoveryData()

            let databaseVideoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: pathVideoID,
                    startTime: timestamp,
                    endTime: timestamp,
                    frameCount: 1,
                    fileSizeBytes: 123,
                    relativePath: relativePath,
                    width: 8,
                    height: 8
                )
            )
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            let unfinalised = try XCTUnwrap(unfinalisedVideos.first(where: { $0.id == databaseVideoID }))

            let segmentExists = try await storageManager.segmentExists(id: pathVideoID)
            XCTAssertFalse(segmentExists)
            let shouldResume = try await coordinator.shouldResumeUnfinalisedVideo(unfinalised)
            XCTAssertFalse(shouldResume)

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testPrepareForPipelineStartRunsRecoveryAfterValidateRepairsWAL() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryRepairBeforePrepare_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storageRoot.path)
            }

            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: storageRoot.appendingPathComponent("chunks", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: storageRoot.appendingPathComponent("temp", isDirectory: true),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: storageRoot.appendingPathComponent("wal", isDirectory: false).path,
                contents: Data("blocking-file".utf8)
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storageRoot.path)

            try await services.initialize()

            let storageManager = await services.storage
            let initialWALIssue = await storageManager.currentWALAvailabilityIssue()
            XCTAssertNotNil(initialWALIssue)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storageRoot.path)
            try FileManager.default.removeItem(at: storageRoot.appendingPathComponent("wal", isDirectory: false))
            try FileManager.default.createDirectory(
                at: storageRoot.appendingPathComponent("wal", isDirectory: true),
                withIntermediateDirectories: true
            )

            let walManager = await storageManager.getWALManager()
            let database = await services.database
            let timestamp = Date(timeIntervalSince1970: 1_740_300_000)
            let sessionVideoID = VideoSegmentID(value: 808)
            var session = try await walManager.createSession(videoID: sessionVideoID)
            try await walManager.appendFrame(makeCapturedFrame(timestamp: timestamp), to: &session)

            _ = try await database.insertVideoSegment(
                VideoSegment(
                    id: sessionVideoID,
                    startTime: timestamp,
                    endTime: timestamp,
                    frameCount: 1,
                    fileSizeBytes: 123,
                    relativePath: "chunks/202603/12/\(sessionVideoID.value)",
                    width: 8,
                    height: 8
                )
            )

            await services.onboardingManager.markOnboardingCompleted()
            try await coordinator.prepareForPipelineStart()

            let repairedWALIssue = await storageManager.currentWALAvailabilityIssue()
            XCTAssertNil(repairedWALIssue)
            let activeSessions = try await walManager.listActiveSessions()
            XCTAssertTrue(activeSessions.isEmpty)
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            XCTAssertTrue(unfinalisedVideos.isEmpty)

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testCrashRecoveryStartupDoesNotFinalizeQuarantinedUnrecoverableVideo() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryStartupTests_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let storageManager = await services.storage
            let walManager = await storageManager.getWALManager()
            let database = await services.database
            let configuredStorageRoot = await storageManager.getStorageDirectory()

            XCTAssertEqual(
                configuredStorageRoot.standardizedFileURL.path,
                storageRoot.standardizedFileURL.path
            )
            let initialActiveSessions = try await walManager.listActiveSessions()
            XCTAssertTrue(initialActiveSessions.isEmpty)

            let sessionVideoID = VideoSegmentID(value: 606)
            var session = try await walManager.createSession(videoID: sessionVideoID)
            let timestamp = Date(timeIntervalSince1970: 1_740_000_200)
            try await walManager.appendFrame(makeCapturedFrame(timestamp: timestamp), to: &session)

            let fileHandle = try XCTUnwrap(FileHandle(forWritingAtPath: session.framesURL.path))
            defer { try? fileHandle.close() }
            try fileHandle.truncate(atOffset: 0)

            let placeholderVideo = VideoSegment(
                id: sessionVideoID,
                startTime: timestamp,
                endTime: timestamp,
                frameCount: 1,
                fileSizeBytes: 123,
                relativePath: "chunks/202603/12/\(sessionVideoID.value)",
                width: 8,
                height: 8
            )
            let databaseVideoID = try await database.insertVideoSegment(placeholderVideo)

            try await coordinator.runCrashRecoveryForTesting()

            let recoveredVideo = try await database.getVideoSegment(id: VideoSegmentID(value: databaseVideoID))
            XCTAssertNil(recoveredVideo)
            let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
            XCTAssertTrue(unfinalisedVideos.isEmpty)
            let activeSessions = try await walManager.listActiveSessions()
            XCTAssertTrue(activeSessions.isEmpty)

            try await coordinator.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await coordinator.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testResolveActiveDatabaseVideoIDsMatchesMP4RelativePaths() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryActiveWALPathMP4_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let database = await services.database
            let timestamp = Date(timeIntervalSince1970: 1_740_400_000)
            let pathVideoID = VideoSegmentID(value: 9_876)
            let databaseVideoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: pathVideoID,
                    startTime: timestamp,
                    endTime: timestamp,
                    frameCount: 0,
                    fileSizeBytes: 0,
                    relativePath: "chunks/202603/12/\(pathVideoID.value).mp4",
                    width: 8,
                    height: 8
                )
            )

            let activeVideoIDs = try await coordinator.resolveActiveDatabaseVideoIDs(
                from: [
                    WALSession(
                        videoID: pathVideoID,
                        sessionDir: storageRoot.appendingPathComponent("wal/active_segment_\(pathVideoID.value)", isDirectory: true),
                        framesURL: storageRoot.appendingPathComponent("wal/active_segment_\(pathVideoID.value)/frames.bin"),
                        metadata: WALMetadata(
                            videoID: pathVideoID,
                            startTime: timestamp,
                            frameCount: 0,
                            width: 8,
                            height: 8,
                            durableReadableFrameCount: 0,
                            durableVideoFileSizeBytes: 0
                        )
                    )
                ]
            )

            XCTAssertEqual(activeVideoIDs, Set([databaseVideoID]))

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }

    func testServiceContainerDataAdapterUsesConfiguredStorageRootForVideoPaths() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceContainerStorageRootTests_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let previousUseRewindData = defaults.object(forKey: "useRewindData")

        defaults.set(false, forKey: "useRewindData")

        do {
            defer {
                if let previousUseRewindData {
                    defaults.set(previousUseRewindData, forKey: "useRewindData")
                } else {
                    defaults.removeObject(forKey: "useRewindData")
                }
            }

            try await services.initialize()

            let database = await services.database
            let adapterReference = await services.dataAdapter
            let adapter = try XCTUnwrap(adapterReference)
            let timestamp = Date(timeIntervalSince1970: 1_741_700_123)
            let insertedVideoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: VideoSegmentID(value: 0),
                    startTime: timestamp,
                    endTime: timestamp.addingTimeInterval(60),
                    frameCount: 1,
                    fileSizeBytes: 1024,
                    relativePath: "chunks/202603/12/9876.mp4",
                    width: 1920,
                    height: 1080,
                    source: .native
                )
            )
            let segmentID = try await database.insertSegment(
                bundleID: "com.apple.Safari",
                startDate: timestamp,
                endDate: timestamp.addingTimeInterval(60),
                windowName: "Window",
                browserUrl: "https://example.com",
                type: 0
            )
            let frameID = try await database.insertFrame(
                FrameReference(
                    id: FrameID(value: 0),
                    timestamp: timestamp,
                    segmentID: AppSegmentID(value: segmentID),
                    videoID: VideoSegmentID(value: insertedVideoID),
                    frameIndexInSegment: 0,
                    metadata: .empty,
                    source: .native
                )
            )

            let frameWithVideoInfo = try await adapter.getFrameWithVideoInfoByID(
                id: FrameID(value: frameID)
            )
            let frame = try XCTUnwrap(frameWithVideoInfo)
            let videoInfo = try XCTUnwrap(frame.videoInfo)

            XCTAssertEqual(
                videoInfo.videoPath,
                storageRoot.appendingPathComponent("chunks/202603/12/9876.mp4").path
            )

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }
}

final class OCRReprocessSafetyTests: XCTestCase {
    private func makeServices(storageRoot: URL) -> ServiceContainer {
        let crashReportDirectory = storageRoot.appendingPathComponent("crash_reports", isDirectory: true).path
        return ServiceContainer(
            databasePath: "file:app_ocr_reprocess_\(UUID().uuidString)?mode=memory&cache=shared",
            storageConfig: StorageConfig(
                storageRootPath: storageRoot.path,
                retentionDays: nil,
                maxStorageGB: nil,
                segmentDurationSeconds: 300
            ),
            storageCrashReportDirectory: crashReportDirectory
        )
    }

    func testReprocessOCRRejectsFramesWithRedactedNodes() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRReprocessSafetyTests_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)

        do {
            try await services.initialize()

            let database = await services.database
            guard let queue = await services.processingQueue else {
                XCTFail("Expected processing queue to be initialized")
                return
            }
            let timestamp = Date(timeIntervalSince1970: 1_740_500_000)
            let videoID = try await database.insertVideoSegment(
                VideoSegment(
                    id: VideoSegmentID(value: 9_999),
                    startTime: timestamp,
                    endTime: timestamp,
                    frameCount: 1,
                    fileSizeBytes: 123,
                    relativePath: "chunks/202603/12/9999",
                    width: 8,
                    height: 8
                )
            )
            let segmentID = try await database.insertSegment(
                bundleID: "com.apple.Safari",
                startDate: timestamp,
                endDate: timestamp,
                windowName: "Protected Window",
                browserUrl: "https://example.com",
                type: 0
            )
            let frameIDValue = try await database.insertFrame(
                FrameReference(
                    id: FrameID(value: 0),
                    timestamp: timestamp,
                    segmentID: AppSegmentID(value: segmentID),
                    videoID: VideoSegmentID(value: videoID),
                    frameIndexInSegment: 0,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.Safari",
                        appName: "Safari",
                        windowName: "Protected Window",
                        browserURL: "https://example.com",
                        displayID: 1
                    ),
                    source: .native
                )
            )
            let frameID = FrameID(value: frameIDValue)
            let docid = try await database.indexFrameText(
                mainText: "super secret",
                chromeText: nil,
                windowTitle: "Protected Window",
                segmentId: segmentID,
                frameId: frameIDValue
            )
            try await database.insertNodes(
                frameID: frameID,
                nodes: [(
                    textOffset: 0,
                    textLength: 12,
                    bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                    windowIndex: nil
                )],
                encryptedTexts: [0: "ciphertext"],
                frameWidth: 8,
                frameHeight: 8
            )
            try await database.updateFrameProcessingStatus(frameID: frameIDValue, status: 2)

            let queueDepthBefore = try await queue.getQueueDepth()

            do {
                try await coordinator.reprocessOCR(frameID: frameID)
                XCTFail("Expected redacted frame reprocess to be rejected")
            } catch let error as AppError {
                guard case .ocrReprocessBlockedForRedactedFrame(let rejectedFrameID) = error else {
                    XCTFail("Expected ocrReprocessBlockedForRedactedFrame, got \(error)")
                    return
                }
                XCTAssertEqual(rejectedFrameID, frameIDValue)
            }

            let queueDepthAfter = try await queue.getQueueDepth()
            XCTAssertEqual(queueDepthAfter, queueDepthBefore)

            let preservedNodes = try await database.getOCRNodesWithText(frameID: frameID)
            XCTAssertEqual(preservedNodes.count, 1)
            XCTAssertTrue(preservedNodes[0].isRedacted)
            XCTAssertEqual(preservedNodes[0].encryptedText, "ciphertext")

            let preservedDocid = try await database.getDocidForFrame(frameId: frameIDValue)
            XCTAssertEqual(preservedDocid, docid)
            let preservedFTS = try await database.getFTSContent(docid: docid)
            XCTAssertEqual(preservedFTS?.mainText, "super secret")

            let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameIDValue])
            XCTAssertEqual(statuses[frameIDValue], 2)

            try await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
        } catch {
            try? await services.shutdown()
            try? FileManager.default.removeItem(at: storageRoot)
            throw error
        }
    }
}

final class FrameDeletionSemanticsTests: XCTestCase {
    private func makeServices(storageRoot: URL) -> ServiceContainer {
        let crashReportDirectory = storageRoot.appendingPathComponent("crash_reports", isDirectory: true).path
        return ServiceContainer(
            databasePath: storageRoot.appendingPathComponent("retrace.db").path,
            storageConfig: StorageConfig(
                storageRootPath: storageRoot.path,
                retentionDays: nil,
                maxStorageGB: nil,
                segmentDurationSeconds: 300
            ),
            storageCrashReportDirectory: crashReportDirectory
        )
    }

    private func makeCapturedFrame(timestamp: Date) -> CapturedFrame {
        CapturedFrame(
            timestamp: timestamp,
            imageData: Data(repeating: 0xAB, count: 32 * 8),
            width: 8,
            height: 8,
            bytesPerRow: 32,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Window",
                browserURL: "https://example.com",
                displayID: 1
            )
        )
    }

    private func seedVideoBackedFrame(
        services: ServiceContainer,
        timestamp: Date
    ) async throws -> (frameID: FrameID, videoID: Int64, segmentPath: String) {
        let storage = await services.storage
        let database = await services.database
        let capturedFrame = makeCapturedFrame(timestamp: timestamp)

        let writer = try await storage.createSegmentWriter()
        try await writer.appendFrame(capturedFrame)
        let segment = try await writer.finalize()

        let databaseVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                frameCount: segment.frameCount,
                fileSizeBytes: segment.fileSizeBytes,
                relativePath: segment.relativePath,
                width: segment.width,
                height: segment.height,
                source: .native
            )
        )
        try await database.markVideoFinalized(
            id: databaseVideoID,
            frameCount: segment.frameCount,
            fileSize: segment.fileSizeBytes
        )

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp,
            windowName: "Delete Test",
            browserUrl: "https://example.com",
            type: 0
        )
        let frameIDValue = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: appSegmentID),
                videoID: VideoSegmentID(value: databaseVideoID),
                frameIndexInSegment: 0,
                metadata: capturedFrame.metadata,
                source: .native
            )
        )
        try await database.updateFrameProcessingStatus(frameID: frameIDValue, status: 2)

        let storageDirectory = await storage.getStorageDirectory()

        return (
            frameID: FrameID(value: frameIDValue),
            videoID: databaseVideoID,
            segmentPath: storageDirectory.appendingPathComponent(segment.relativePath).path
        )
    }

    private func withConnection<T>(
        _ database: DatabaseManager,
        _ body: (OpaquePointer) throws -> T
    ) async throws -> T {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        return try body(db)
    }

    private func fetchInt64(
        db: OpaquePointer,
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil
    ) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare SQL: \(sql)")
            return 0
        }

        if let bind {
            bind(statement!)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("Failed to step SQL: \(sql)")
            return 0
        }

        return sqlite3_column_int64(statement, 0)
    }

    private func decodeMetricMetadata(_ metadata: String?) throws -> [String: Any] {
        let json = try XCTUnwrap(metadata)
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDeleteFrameReturnsQueuedResultWhileTimelineVisible() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameDeletionQueued_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let timestamp = Date(timeIntervalSince1970: 1_775_300_000)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()
            let seeded = try await seedVideoBackedFrame(services: services, timestamp: timestamp)
            let database = await services.database

            await coordinator.setTimelineVisible(true)
            let result = try await coordinator.deleteFrame(
                frameID: seeded.frameID,
                timestamp: timestamp,
                source: .native,
                metricSource: "frame_delete_test"
            )

            XCTAssertEqual(result, FrameDeletionResult(completedFrames: 0, queuedFrames: 1))

            let visibleFrameIDs = try await database.getVisibleNativeFrameIDsNewerThan(
                timestamp.addingTimeInterval(-1)
            )
            XCTAssertFalse(visibleFrameIDs.contains(seeded.frameID.value))

            let pendingJobs = try await database.getPendingFrameDeletionJobs(
                videoID: seeded.videoID,
                includeInProgressJobs: true,
                includeRetryableFailures: true
            )
            XCTAssertEqual(pendingJobs.map(\.frameID), [seeded.frameID.value])

            let frameCount = try await withConnection(database) { db in
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM frame WHERE id = ?;",
                    bind: { sqlite3_bind_int64($0, 1, seeded.frameID.value) }
                )
            }
            XCTAssertEqual(frameCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.segmentPath))

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }

    func testDeleteFrameReturnsCompletedResultAfterWholeVideoRewrite() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameDeletionCompleted_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let timestamp = Date(timeIntervalSince1970: 1_775_300_100)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()
            let seeded = try await seedVideoBackedFrame(services: services, timestamp: timestamp)
            let database = await services.database

            let result = try await coordinator.deleteFrame(
                frameID: seeded.frameID,
                timestamp: timestamp,
                source: .native
            )

            XCTAssertEqual(result, FrameDeletionResult(completedFrames: 1, queuedFrames: 0))

            let pendingJobs = try await database.getPendingFrameDeletionJobs(
                videoID: seeded.videoID,
                includeInProgressJobs: true,
                includeRetryableFailures: true
            )
            XCTAssertTrue(pendingJobs.isEmpty)

            let frameCount = try await withConnection(database) { db in
                try fetchInt64(
                    db: db,
                    sql: "SELECT COUNT(*) FROM frame WHERE id = ?;",
                    bind: { sqlite3_bind_int64($0, 1, seeded.frameID.value) }
                )
            }
            XCTAssertEqual(frameCount, 0)
            let deletedVideo = try await database.getVideoSegment(id: VideoSegmentID(value: seeded.videoID))
            XCTAssertNil(deletedVideo)
            XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.segmentPath))

            let recentMetricEvents = try await database.getRecentMetricEvents(limit: 5)
            let metricEvent = try XCTUnwrap(
                recentMetricEvents.first { $0.metricType == .frameDeleted }
            )
            let metricMetadata = try decodeMetricMetadata(metricEvent.metadata)
            XCTAssertEqual(metricMetadata["source"] as? String, "frame_delete")
            XCTAssertEqual(metricMetadata["dataSource"] as? String, "native")
            XCTAssertEqual((metricMetadata["frameID"] as? NSNumber)?.int64Value, seeded.frameID.value)
            XCTAssertEqual((metricMetadata["completedFrames"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((metricMetadata["queuedFrames"] as? NSNumber)?.intValue, 0)

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }

    func testDeleteRecentDataRecordsSegmentDeletedMetric() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameDeletionQuickDelete_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let timestamp = Date(timeIntervalSince1970: 1_775_300_200)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()
            _ = try await seedVideoBackedFrame(services: services, timestamp: timestamp)
            let database = await services.database

            let result = try await coordinator.deleteRecentData(
                newerThan: timestamp.addingTimeInterval(-1),
                metricSource: "quick_delete_test"
            )

            XCTAssertEqual(result, FrameDeletionResult(completedFrames: 1, queuedFrames: 0))

            let recentMetricEvents = try await database.getRecentMetricEvents(limit: 5)
            let metricEvent = try XCTUnwrap(
                recentMetricEvents.first { $0.metricType == .segmentDeleted }
            )
            let metricMetadata = try decodeMetricMetadata(metricEvent.metadata)
            XCTAssertEqual(metricMetadata["source"] as? String, "quick_delete_test")
            XCTAssertEqual((metricMetadata["frameCount"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((metricMetadata["completedFrames"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((metricMetadata["queuedFrames"] as? NSNumber)?.intValue, 0)

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }
}

final class VideoQualityMetricsTests: XCTestCase {
    private func makeServices(storageRoot: URL) -> ServiceContainer {
        let crashReportDirectory = storageRoot.appendingPathComponent("crash_reports", isDirectory: true).path
        return ServiceContainer(
            databasePath: storageRoot.appendingPathComponent("retrace.db").path,
            storageConfig: StorageConfig(
                storageRootPath: storageRoot.path,
                retentionDays: nil,
                maxStorageGB: nil,
                segmentDurationSeconds: 300
            ),
            storageCrashReportDirectory: crashReportDirectory
        )
    }

    func testUpdateVideoQualityRecordsDailyMetric() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoQualityMetricsTests_\(UUID().uuidString)", isDirectory: true)
        let services = makeServices(storageRoot: storageRoot)
        let coordinator = AppCoordinator(services: services)
        let startDate = Date().addingTimeInterval(-60)
        let endDate = Date().addingTimeInterval(60)

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        do {
            try await services.initialize()

            await coordinator.updateVideoQuality(0.85)

            let metricRows = try await coordinator.getDailyMetrics(
                metricType: .videoQualityUpdated,
                from: startDate,
                to: endDate
            )
            let totalCount = metricRows.reduce(into: Int64(0)) { partialResult, row in
                partialResult += row.value
            }

            XCTAssertEqual(totalCount, 1)

            try await services.shutdown()
        } catch {
            try? await services.shutdown()
            throw error
        }
    }
}
