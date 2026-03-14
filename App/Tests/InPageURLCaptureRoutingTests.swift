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
                encodingStatus: .success,
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

    func testDailyDBStorageEstimatedBytesRequiresAboutOneDayOfHistory() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBStorageSnapshotRequiresDay_\(UUID().uuidString)", isDirectory: true)
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
            try await services.database.recordDBStorageSnapshot(timestamp: secondSnapshot)

            let estimates = try await coordinator.getDailyDBStorageEstimatedBytes(
                from: firstSnapshot,
                to: secondSnapshot
            )

            XCTAssertTrue(estimates.isEmpty)

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
                    encodingStatus: .success,
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
