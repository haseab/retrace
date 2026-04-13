import XCTest
import SQLite3
import Darwin
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                        QUERY BUILDER TESTS                                   ║
// ║                                                                              ║
// ║  • Verify FrameQueries builds correct SQL statements                         ║
// ║  • Verify SegmentQueries builds correct SQL statements                       ║
// ║  • Verify DocumentQueries builds correct SQL statements                      ║
// ║  • Verify query result parsing works correctly                               ║
// ║  • Verify parameter binding prevents SQL injection                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class QueryBuilderTests: XCTestCase {

    var db: OpaquePointer?
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        sqlite3_open(":memory:", &db)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Helper to create VideoSegment with required fields

    private func makeSegment(
        id: VideoSegmentID = VideoSegmentID(value: 0),
        startTime: Date = Date(),
        endTime: Date? = nil,
        frameCount: Int = 100,
        fileSizeBytes: Int64 = 1024,
        relativePath: String = "test.mp4"
    ) -> VideoSegment {
        VideoSegment(
            id: id,
            startTime: startTime,
            endTime: endTime ?? startTime.addingTimeInterval(300),
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: relativePath,
            width: 1920,
            height: 1080
        )
    }

    private func makeFrame(
        id: FrameID = FrameID(value: 0),
        timestamp: Date = Date(),
        segmentID: AppSegmentID,
        videoID: VideoSegmentID = VideoSegmentID(value: 0),
        frameIndex: Int = 0,
        metadata: FrameMetadata = .empty
    ) -> FrameReference {
        FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: frameIndex,
            metadata: metadata
        )
    }

    private func insertFrame(_ frame: FrameReference) throws -> FrameReference {
        let insertedID = try FrameQueries.insert(db: db!, frame: frame)
        return FrameReference(
            id: FrameID(value: insertedID),
            timestamp: frame.timestamp,
            segmentID: frame.segmentID,
            videoID: frame.videoID,
            frameIndexInSegment: frame.frameIndexInSegment,
            metadata: frame.metadata,
            source: frame.source
        )
    }

    private func withProcessTimeZone<T>(
        _ identifier: String,
        _ body: () throws -> T
    ) rethrows -> T {
        let previousTZ = ProcessInfo.processInfo.environment["TZ"]
        let previousDefaultTimeZone = NSTimeZone.default

        setenv("TZ", identifier, 1)
        tzset()
        if let timeZone = TimeZone(identifier: identifier) {
            NSTimeZone.default = timeZone
        }

        defer {
            if let previousTZ {
                setenv("TZ", previousTZ, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.default = previousDefaultTimeZone
        }

        return try body()
    }

    private func dateWithDifferentOffset(
        relativeTo referenceDate: Date,
        timeZone: TimeZone
    ) -> Date? {
        let currentOffset = timeZone.secondsFromGMT(for: referenceDate)
        let dayInterval: TimeInterval = 86_400

        for dayOffset in 1...370 {
            let futureCandidate = referenceDate.addingTimeInterval(Double(dayOffset) * dayInterval)
            if timeZone.secondsFromGMT(for: futureCandidate) != currentOffset {
                return futureCandidate
            }

            let pastCandidate = referenceDate.addingTimeInterval(-Double(dayOffset) * dayInterval)
            if timeZone.secondsFromGMT(for: pastCandidate) != currentOffset {
                return pastCandidate
            }
        }

        return nil
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      SEGMENT QUERIES TESTS                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testSegmentQueries_Insert_StoresAllFields() throws {
        let segment = makeSegment(
            startTime: Date(timeIntervalSince1970: 1702406400),
            endTime: Date(timeIntervalSince1970: 1702406700),
            frameCount: 150,
            fileSizeBytes: 52428800,
            relativePath: "segments/2024/01/test.mp4"
        )

        let insertedID = try SegmentQueries.insert(db: db!, segment: segment)

        // Verify with raw SQL - query the video table (not segments)
        let sql = "SELECT * FROM video WHERE id = ?"
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        sqlite3_bind_int64(statement, 1, insertedID)

        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)

        // Check fields - video table has: id, height, width, path, fileSize, frameRate, processingState
        let height = sqlite3_column_int(statement, 1)
        let width = sqlite3_column_int(statement, 2)
        let path = String(cString: sqlite3_column_text(statement, 3))
        let fileSize = sqlite3_column_int64(statement, 4)

        XCTAssertEqual(height, 1080)
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(path, "segments/2024/01/test.mp4")
        XCTAssertEqual(fileSize, 52428800)

        sqlite3_finalize(statement)
    }

    func testSegmentQueries_GetByID_ReturnsCorrectSegment() throws {
        let segment = makeSegment(frameCount: 100, fileSizeBytes: 1024000)
        let insertedID = try SegmentQueries.insert(db: db!, segment: segment)

        let retrieved = try SegmentQueries.getByID(db: db!, id: VideoSegmentID(value: insertedID))

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedID)
        XCTAssertEqual(retrieved?.frameCount, 150)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024000)
        XCTAssertEqual(retrieved?.width, 1920)
        XCTAssertEqual(retrieved?.height, 1080)
    }

    func testSegmentQueries_GetByID_ReturnsNilForMissingID() throws {
        let result = try SegmentQueries.getByID(db: db!, id: VideoSegmentID(value: 99999))
        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimestamp_FindsContainingSegment() throws {
        let startTime = Date()
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        let insertedVideoID = try SegmentQueries.insert(db: db!, segment: segment)

        let appSegmentID = try AppSegmentQueries.insert(
            db: db!,
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let midpoint = startTime.addingTimeInterval(150)
        _ = try insertFrame(
            makeFrame(
                timestamp: midpoint,
                segmentID: AppSegmentID(value: appSegmentID),
                videoID: VideoSegmentID(value: insertedVideoID)
            )
        )

        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: midpoint)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id.value, insertedVideoID)
    }

    func testSegmentQueries_GetByTimestamp_ReturnsNilOutsideRange() throws {
        let startTime = Date()
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        let insertedVideoID = try SegmentQueries.insert(db: db!, segment: segment)

        let appSegmentID = try AppSegmentQueries.insert(
            db: db!,
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        _ = try insertFrame(
            makeFrame(
                timestamp: startTime,
                segmentID: AppSegmentID(value: appSegmentID),
                videoID: VideoSegmentID(value: insertedVideoID)
            )
        )

        let beforeStart = startTime.addingTimeInterval(-100)
        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: beforeStart)

        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimeRange_ReturnsOverlappingSegments() throws {
        let seg1 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1000),
            endTime: Date(timeIntervalSince1970: 1300),
            relativePath: "seg1.mp4"
        )
        let seg2 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1500),
            endTime: Date(timeIntervalSince1970: 1800),
            relativePath: "seg2.mp4"
        )
        let seg3 = makeSegment(
            startTime: Date(timeIntervalSince1970: 5000),
            endTime: Date(timeIntervalSince1970: 5300),
            relativePath: "seg3.mp4"
        )

        let videoID1 = try SegmentQueries.insert(db: db!, segment: seg1)
        let videoID2 = try SegmentQueries.insert(db: db!, segment: seg2)
        let videoID3 = try SegmentQueries.insert(db: db!, segment: seg3)

        let appSegment1 = try AppSegmentQueries.insert(
            db: db!,
            bundleID: "com.test.one",
            startDate: seg1.startTime,
            endDate: seg1.endTime,
            windowName: nil,
            browserUrl: nil,
            type: 0
        )
        let appSegment2 = try AppSegmentQueries.insert(
            db: db!,
            bundleID: "com.test.two",
            startDate: seg2.startTime,
            endDate: seg2.endTime,
            windowName: nil,
            browserUrl: nil,
            type: 0
        )
        let appSegment3 = try AppSegmentQueries.insert(
            db: db!,
            bundleID: "com.test.three",
            startDate: seg3.startTime,
            endDate: seg3.endTime,
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        _ = try insertFrame(
            makeFrame(
                timestamp: Date(timeIntervalSince1970: 1250),
                segmentID: AppSegmentID(value: appSegment1),
                videoID: VideoSegmentID(value: videoID1)
            )
        )
        _ = try insertFrame(
            makeFrame(
                timestamp: Date(timeIntervalSince1970: 1550),
                segmentID: AppSegmentID(value: appSegment2),
                videoID: VideoSegmentID(value: videoID2)
            )
        )
        _ = try insertFrame(
            makeFrame(
                timestamp: Date(timeIntervalSince1970: 5050),
                segmentID: AppSegmentID(value: appSegment3),
                videoID: VideoSegmentID(value: videoID3)
            )
        )

        let results = try SegmentQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 1200),
            to: Date(timeIntervalSince1970: 1600)
        )

        XCTAssertEqual(results.count, 2, "Should find 2 overlapping segments")
    }

    func testSegmentQueries_Delete_RemovesSegment() throws {
        let segment = makeSegment(relativePath: "to-delete.mp4")
        let insertedID = try SegmentQueries.insert(db: db!, segment: segment)

        let videoID = VideoSegmentID(value: insertedID)
        XCTAssertNotNil(try SegmentQueries.getByID(db: db!, id: videoID))
        try SegmentQueries.delete(db: db!, id: videoID)
        XCTAssertNil(try SegmentQueries.getByID(db: db!, id: videoID))
    }

    func testSegmentQueries_GetCount_ReturnsCorrectCount() throws {
        for i in 0..<5 {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                relativePath: "seg-\(i).mp4"
            )
            _ = try SegmentQueries.insert(db: db!, segment: segment)
        }

        let count = try SegmentQueries.getCount(db: db!)
        XCTAssertEqual(count, 5)
    }

    func testSegmentQueries_GetTotalStorageBytes_SumsCorrectly() throws {
        let sizes: [Int64] = [1000, 2000, 3000, 4000, 5000]

        for (i, size) in sizes.enumerated() {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                fileSizeBytes: size,
                relativePath: "seg-\(i).mp4"
            )
            _ = try SegmentQueries.insert(db: db!, segment: segment)
        }

        let total = try SegmentQueries.getTotalStorageBytes(db: db!)
        XCTAssertEqual(total, 15000)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                       FRAME QUERIES TESTS                               ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestSegment(
        bundleID: String = "com.test.app",
        windowName: String? = nil,
        browserURL: String? = nil
    ) throws -> AppSegmentID {
        // Create video segment first
        let videoSegment = makeSegment(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600)
        )
        _ = try SegmentQueries.insert(db: db!, segment: videoSegment)

        // Create app segment
        let appSegmentID = try AppSegmentQueries.insert(
            db: db!,
            bundleID: bundleID,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            windowName: windowName,
            browserUrl: browserURL,
            type: 0
        )
        return AppSegmentID(value: appSegmentID)
    }

    func testFrameQueries_GetByID_UsesJoinedSegmentMetadata() throws {
        let segmentID = try createTestSegment(
            bundleID: "com.apple.Safari",
            windowName: "GitHub - retrace",
            browserURL: "https://github.com/retrace"
        )

        let frame = try insertFrame(
            makeFrame(
            segmentID: segmentID,
            frameIndex: 42,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Terminal",
                appName: "Terminal",
                windowName: "Ignored Window",
                browserURL: "https://ignored.example"
            )
        ))

        let retrieved = try FrameQueries.getByID(db: db!, id: frame.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.frameIndexInSegment, 42)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertEqual(retrieved?.metadata.windowName, "GitHub - retrace")
        XCTAssertEqual(retrieved?.metadata.browserURL, "https://github.com/retrace")
    }

    func testFrameQueries_Insert_WithNullMetadata_UsesSegmentMetadataWhenAvailable() throws {
        let segmentID = try createTestSegment()
        let frame = try insertFrame(makeFrame(segmentID: segmentID, metadata: FrameMetadata()))

        let retrieved = try FrameQueries.getByID(db: db!, id: frame.id)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.test.app")
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrameQueries_GetByTimeRange_ReturnsOrderedByTimestampAsc() throws {
        let segmentID = try createTestSegment()
        let timestamps = [100.0, 300.0, 200.0, 500.0, 400.0]

        for (i, offset) in timestamps.enumerated() {
            _ = try insertFrame(
                makeFrame(
                timestamp: Date(timeIntervalSince1970: offset),
                segmentID: segmentID,
                frameIndex: i
            ))
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1000),
            limit: 10
        )

        XCTAssertEqual(results.count, 5)

        for i in 0..<(results.count - 1) {
            XCTAssertLessThanOrEqual(
                results[i].timestamp.timeIntervalSince1970,
                results[i + 1].timestamp.timeIntervalSince1970
            )
        }
    }

    func testFrameQueries_GetByTimeRange_RespectsLimit() throws {
        let segmentID = try createTestSegment()

        for i in 0..<10 {
            _ = try insertFrame(
                makeFrame(
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segmentID,
                frameIndex: i
            ))
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date().addingTimeInterval(-100),
            to: Date().addingTimeInterval(100),
            limit: 3
        )

        XCTAssertEqual(results.count, 3)
    }

    func testFrameQueries_GetByApp_FiltersCorrectly() throws {
        let videoID = try SegmentQueries.insert(db: db!, segment: makeSegment(relativePath: "app-filter.mp4"))
        let apps = ["com.apple.Safari", "com.apple.Xcode", "com.apple.Safari", "com.apple.Terminal"]

        for (i, app) in apps.enumerated() {
            let appSegmentID = try AppSegmentQueries.insert(
                db: db!,
                bundleID: app,
                startDate: Date().addingTimeInterval(Double(i)),
                endDate: Date().addingTimeInterval(Double(i + 1)),
                windowName: nil,
                browserUrl: nil,
                type: 0
            )
            _ = try insertFrame(
                makeFrame(
                    timestamp: Date().addingTimeInterval(Double(i)),
                    segmentID: AppSegmentID(value: appSegmentID),
                    videoID: VideoSegmentID(value: videoID),
                    frameIndex: i,
                    metadata: FrameMetadata(appBundleID: app)
                )
            )
        }

        let safariFrames = try FrameQueries.getByApp(
            db: db!,
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(safariFrames.count, 2)
        for frame in safariFrames {
            XCTAssertEqual(frame.metadata.appBundleID, "com.apple.Safari")
        }
    }

    func testFrameQueries_DeleteOlderThan_ReturnsDeletedCount() throws {
        let segmentID = try createTestSegment()
        let now = Date()

        // 5 old frames
        for i in 0..<5 {
            _ = try insertFrame(
                makeFrame(
                timestamp: now.addingTimeInterval(-86400 * Double(100 + i)),
                segmentID: segmentID,
                frameIndex: i
            ))
        }

        // 3 recent frames
        for i in 0..<3 {
            _ = try insertFrame(
                makeFrame(
                timestamp: now.addingTimeInterval(-Double(i)),
                segmentID: segmentID,
                frameIndex: 5 + i
            ))
        }

        let cutoff = now.addingTimeInterval(-86400 * 30)
        let deleted = try FrameQueries.deleteOlderThan(db: db!, date: cutoff)

        XCTAssertEqual(deleted, 5)
        XCTAssertEqual(try FrameQueries.getCount(db: db!), 3)
    }

    func testAppSegmentQueries_GetDailyScreenTime_UsesPerRowLocalDayAcrossDST() throws {
        try withProcessTimeZone("America/Los_Angeles") {
            guard let timeZone = TimeZone(identifier: "America/Los_Angeles"),
                  let shiftedDate = dateWithDifferentOffset(relativeTo: Date(), timeZone: timeZone) else {
                XCTFail("Expected a DST-shifted date in America/Los_Angeles")
                return
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            let targetDayStart = calendar.startOfDay(for: shiftedDate)
            let previousDayStart = calendar.date(byAdding: .day, value: -1, to: targetDayStart)!
            let queryEnd = targetDayStart.addingTimeInterval(15 * 60)

            let segmentID = try createTestSegment()
            _ = try insertFrame(
                makeFrame(
                    timestamp: targetDayStart.addingTimeInterval(10 * 60),
                    segmentID: segmentID,
                    frameIndex: 0
                )
            )
            _ = try insertFrame(
                makeFrame(
                    timestamp: targetDayStart.addingTimeInterval((11 * 60) + 30),
                    segmentID: segmentID,
                    frameIndex: 1
                )
            )

            let results = try AppSegmentQueries.getDailyScreenTime(
                db: db!,
                from: previousDayStart,
                to: queryEnd
            )

            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(calendar.startOfDay(for: results[0].date), targetDayStart)
            XCTAssertEqual(results[0].value, 90_000)
        }
    }

    func testDailyMetricsQueries_GetDailyCounts_UsesPerRowLocalDayAcrossDST() throws {
        try withProcessTimeZone("America/Los_Angeles") {
            guard let timeZone = TimeZone(identifier: "America/Los_Angeles"),
                  let shiftedDate = dateWithDifferentOffset(relativeTo: Date(), timeZone: timeZone) else {
                XCTFail("Expected a DST-shifted date in America/Los_Angeles")
                return
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            let targetDayStart = calendar.startOfDay(for: shiftedDate)
            let previousDayStart = calendar.date(byAdding: .day, value: -1, to: targetDayStart)!

            try DailyMetricsQueries.recordEvent(
                db: db!,
                metricType: .searches,
                timestamp: targetDayStart.addingTimeInterval(10 * 60)
            )

            let results = try DailyMetricsQueries.getDailyCounts(
                db: db!,
                metricType: .searches,
                from: previousDayStart,
                to: targetDayStart
            )

            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(calendar.startOfDay(for: results[0].date), targetDayStart)
            XCTAssertEqual(results[0].value, 1)
        }
    }

    func testDailyMetricsQueries_GetRecentEvents_ReturnsNewestRowsInChronologicalOrder() throws {
        let baseTime = Date(timeIntervalSince1970: 1_774_800_000)

        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .timelineOpens,
            timestamp: baseTime,
            metadata: nil
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .helpOpened,
            timestamp: baseTime.addingTimeInterval(5),
            metadata: #"{"source":"dashboard"}"#
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .feedbackReportExport,
            timestamp: baseTime.addingTimeInterval(10),
            metadata: #"{"outcome":"exported","source":"manual"}"#
        )

        let results = try DailyMetricsQueries.getRecentEvents(
            db: db!,
            limit: 2
        )

        XCTAssertEqual(
            results.map(\.metricType),
            [.helpOpened, .feedbackReportExport]
        )
        XCTAssertEqual(
            results.map { Int($0.timestamp.timeIntervalSince1970) },
            [Int(baseTime.addingTimeInterval(5).timeIntervalSince1970), Int(baseTime.addingTimeInterval(10).timeIntervalSince1970)]
        )
        XCTAssertEqual(results.first?.metadata, #"{"source":"dashboard"}"#)
        XCTAssertEqual(results.last?.metadata, #"{"outcome":"exported","source":"manual"}"#)
    }

    func testDailyMetricsQueries_GetRecentEvents_ExcludesNoisyMetricTypesBeforeApplyingLimit() throws {
        let baseTime = Date(timeIntervalSince1970: 1_774_800_100)

        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .timelineOpens,
            timestamp: baseTime,
            metadata: nil
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .mouseClickCapture,
            timestamp: baseTime.addingTimeInterval(5),
            metadata: #"{"button":"left","outcome":"debounced","trigger":"mouse_click"}"#
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .mouseClickCapture,
            timestamp: baseTime.addingTimeInterval(10),
            metadata: #"{"button":"left","outcome":"captured","trigger":"mouse_click"}"#
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .phraseLevelRedactionQueuedHover,
            timestamp: baseTime.addingTimeInterval(12),
            metadata: #"{"processingStatus":"5"}"#
        )
        try DailyMetricsQueries.recordEvent(
            db: db!,
            metricType: .helpOpened,
            timestamp: baseTime.addingTimeInterval(15),
            metadata: #"{"source":"dashboard"}"#
        )

        let results = try DailyMetricsQueries.getRecentEvents(
            db: db!,
            limit: 2,
            excluding: [.mouseClickCapture, .phraseLevelRedactionQueuedHover]
        )

        XCTAssertEqual(
            results.map(\.metricType),
            [.timelineOpens, .helpOpened]
        )
        XCTAssertEqual(
            results.map { Int($0.timestamp.timeIntervalSince1970) },
            [
                Int(baseTime.timeIntervalSince1970),
                Int(baseTime.addingTimeInterval(15).timeIntervalSince1970),
            ]
        )
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      DOCUMENT QUERIES TESTS                             ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestFrame() throws -> FrameID {
        let segmentID = try createTestSegment()
        let frame = makeFrame(segmentID: segmentID)
        return FrameID(value: try FrameQueries.insert(db: db!, frame: frame))
    }

    func testDocumentQueries_Insert_ReturnsAutoIncrementID() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: "Test content"
        )

        let id1 = try DocumentQueries.insert(db: db!, document: document)
        XCTAssertGreaterThan(id1, 0)

        let frameID2 = try createTestFrame()
        let document2 = IndexedDocument(id: 0, frameID: frameID2, timestamp: Date(), content: "More content")

        let id2 = try DocumentQueries.insert(db: db!, document: document2)
        XCTAssertGreaterThan(id2, id1)
    }

    func testDocumentQueries_Insert_StoresAllFields() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(timeIntervalSince1970: 1702406400),
            content: "Full document content here",
            appName: "Safari",
            windowName: "GitHub Page",
            browserURL: "https://github.com"
        )

        _ = try DocumentQueries.insert(db: db!, document: document)

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.content, "Full document content here")
        XCTAssertEqual(retrieved?.appName, "Safari")
        XCTAssertEqual(retrieved?.windowName, "GitHub Page")
        XCTAssertEqual(retrieved?.browserURL, "https://github.com")
    }

    func testDocumentQueries_Update_ChangesContent() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Original")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        try DocumentQueries.update(db: db!, id: docID, content: "Updated content")

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertEqual(retrieved?.content, "Updated content")
    }

    func testDocumentQueries_Delete_RemovesDocument() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "To delete")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        XCTAssertNotNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
        try DocumentQueries.delete(db: db!, id: docID)
        XCTAssertNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
    }

    func testDocumentQueries_GetCount_ReturnsCorrectCount() throws {
        for _ in 0..<7 {
            let frameID = try createTestFrame()
            let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Content")
            _ = try DocumentQueries.insert(db: db!, document: document)
        }

        let count = try DocumentQueries.getCount(db: db!)
        XCTAssertEqual(count, 7)
    }
}
