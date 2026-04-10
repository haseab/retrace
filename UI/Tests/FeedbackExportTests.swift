import XCTest
import App
import zlib
@testable import Retrace

final class FeedbackExportTests: XCTestCase {
    func testCollectDiagnosticsQuickAsyncBuildsMemorySummaryOffMainThread() async {
        let stats = DiagnosticInfo.DatabaseStats(
            sessionCount: 0,
            frameCount: 0,
            segmentCount: 0,
            databaseSizeMB: 0
        )

        let diagnostics = await Task.detached {
            await FeedbackService.shared.collectDiagnosticsQuickAsync(with: stats)
        }.value

        XCTAssertFalse(
            diagnostics.recentLogs.contains {
                $0.contains("Retrace memory summary unavailable off the main thread")
            }
        )
        XCTAssertTrue(
            diagnostics.recentLogs.contains {
                $0.contains("[FeedbackMemoryProfile]")
            }
        )
    }

    func testFilteredFeedbackLogEntriesExcludeVMMapSummaryLogs() {
        let filtered = FeedbackService.filteredFeedbackLogEntries([
            "[2026-03-13T11:57:00Z] [INFO] [ProcessMonitor-VMMap] TOTAL, minus reserved VM space: 1.2G",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SearchViewModel.swift:821 - [Search-Memory] results=0 visibleResults=0 thumbnails=0/Zero KB appIcons=0/Zero KB",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SimpleTimelineViewModel.swift:2721 - [Timeline-Memory] diskFrameBufferCount=0 diskFrameBufferBytes=Zero KB frameWindowCount=100",
            "[2026-04-05T01:05:25Z] [INFO] [Processing] FrameProcessingQueue.swift:3276 - [Queue-Memory] footprint=1.00 GB resident=1.10 GB internal=1.05 GB compressed=Zero KB ocrQueueDepth=0 ocrPending=0 ocrProcessing=0 rewritePending=0 rewriteProcessing=0 workers=2 memoryPaused=false",
            "[2026-04-05T01:05:25Z] [DEBUG] [UI] SimpleTimelineViewModel.swift:2065 - [SimpleTimelineViewModel] currentVideoInfo: frame 123 videoPath=/tmp/test, frameIndex=1, processingStatus=2",
            "[2026-04-05T01:05:25Z] [INFO] [Processing] FrameProcessingQueue.swift:1337 - [Queue-TIMING] Frame 123: prep=15ms frame=63ms ocr=604ms index=10ms total=692ms size=3024x1964",
            "[2026-04-05T01:05:25Z] [DEBUG] [Processing] FrameProcessingQueue.swift:724 - [Queue-Rewrite] Suspended pending segment rewrites (timeline-scrubbing); timelineVisible=true, scrubbing=true",
            "[2026-04-05T01:05:25Z] [DEBUG] [UI] SimpleTimelineView.swift:2001 - [VideoView] Released decoder resources (view removed from window)",
            "[2026-04-05T01:05:25Z] [INFO] [Storage] StorageManager.swift:681 - [VideoExtract] Invalidated stale cache for 1775357238907, creating fresh generator",
            "[2026-04-05T01:05:25Z] [INFO] [App] AppCoordinator.swift:1775 - [Pipeline-Memory] reason=rotation pendingRawFrames=0 pendingRawBytes=0 B activeWriters=1 byResolution=[none]",
            "[2026-04-05T01:05:25Z] [INFO] [Storage] StorageHealthMonitor.swift:430 - [StorageHealth] diskFreeGB=120.0 avgLatencyMs=0 slowWrites=0 criticalWrites=0 spinups=0",
            "[2026-04-05T01:05:25Z] [DEBUG] [UI] SimpleTimelineView.swift:4222 - [ZoomedTextSelectionNSView] updateNSView called, selectionStart=true",
            "[2026-04-05T01:05:25Z] [DEBUG] [UI] SimpleTimelineView.swift:3586 - [ZoomDismiss] ZoomUnifiedOverlay rendered - isTransitioning: false, isExitTransitioning: false, progress: 1.0",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SimpleTimelineViewModel.swift:17013 - [Memory] APPLYING deferred trim trigger=manual direction=newer frames=100",
            "[2026-04-05T01:05:25Z] [INFO] [UI] TimelineWindowController.swift:1211 - [TimelineToggle] show requested state=hidden actualVisible=false searchOverlayVisible=false",
            "[2026-04-05T01:05:25Z] [INFO] [UI] TimelineWindowController.swift:1413 - [TIMELINE-SHOW] visible=true",
            "[2026-04-05T01:05:25Z] [INFO] [UI] TimelineWindowController.swift:706 - [TIMELINE-FOCUS] Captured restore target pid=123 bundleID=com.apple.Safari",
            "[2026-04-05T01:05:25Z] [INFO] [UI] TimelineWindowController.swift:1154 - [TIMELINE-PRERENDER] prepareWindow() started",
            "[2026-04-05T01:05:25Z] [INFO] [UI] TimelineWindowController.swift:1314 - [TIMELINE-REOPEN] hidden=5.0s framesFromNewestBefore=0 framesFromNewestAfter=0 loadedTapeIsRecent=true instantEligible=true instantExpiryElapsed=true nearEligible=true nearExpiryElapsed=true cacheExpired=false hasActiveFilters=false shouldSnapOnShow=true liveModeOnShow=true",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SimpleTimelineViewModel.swift:12462 - [PhraseRedaction][UI] Skipping reveal for tiny node 1 frame=2",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SpotlightSearchOverlay.swift:635 - refreshRecentEntriesPopoverVisibility visible=true",
            "[2026-04-05T01:05:25Z] [DEBUG] [Database] DataAdapter.swift:1810 - [Filter] Query SQL:",
            "SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodedAt, f.processingStatus, f.redactionReason,",
            "FROM frame f",
            "[2026-03-13T11:59:00Z] [INFO] [UI] Sample log line"
        ])

        XCTAssertEqual(filtered, [
            "[2026-03-13T11:59:00Z] [INFO] [UI] Sample log line"
        ])
    }

    func testMakeFeedbackRequestGzipCompressesJSONBody() throws {
        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: String(repeating: "repeated log payload ", count: 512),
            diagnostics: makeSampleDiagnostics()
        )

        let request = try FeedbackService.makeFeedbackRequest(
            for: submission,
            endpoint: URL(string: "https://example.com/api/feedback")!
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")

        let compressedBody = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(Array(compressedBody.prefix(2)), [0x1f, 0x8b])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let expectedJSON = try encoder.encode(submission)
        let decompressedBody = try gunzip(compressedBody)
        let expectedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: expectedJSON, options: []) as? NSDictionary
        )
        let actualObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: decompressedBody, options: []) as? NSDictionary
        )

        XCTAssertEqual(actualObject, expectedObject)
        XCTAssertLessThan(compressedBody.count, expectedJSON.count)
    }

    func testExportFeedbackReportWritesGzippedJSONFile() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let reportURL = directoryURL.appendingPathComponent("retrace-feedback-bug-report.json.gz")
        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "Export me",
            diagnostics: makeSampleDiagnostics()
        )

        let exportedURLs = try await FeedbackService.shared.exportFeedbackReport(
            submission,
            to: reportURL,
            launchSource: .manual
        )

        XCTAssertEqual(exportedURLs, [reportURL])
        let compressedData = try Data(contentsOf: reportURL)
        XCTAssertEqual(Array(compressedData.prefix(2)), [0x1f, 0x8b])

        let decompressedData = try gunzip(compressedData)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: decompressedData, options: []) as? [String: Any]
        )
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["description"] as? String, "Manual export")
    }

    func testCompactEmergencyCrashReportForFeedbackKeepsEssentialSectionsOnly() {
        let report = """
        === RETRACE EMERGENCY DIAGNOSTIC ===
        Trigger: watchdog_auto_quit
        Timestamp: 2026-03-30_150817
        PID: 14687

        --- SYSTEM ---
        macOS: 26.1.0
        Model: Mac15,8

        --- PERFORMANCE ---
        Memory Used: 36.6 GB

        --- DISPLAYS ---
        Active Displays: 1

        --- MAIN THREAD BACKTRACE ---
        (Captured from background thread - main thread may be frozen)
        Main thread probe: NO RESPONSE after 50ms (main thread is FROZEN)

        --- MAIN THREAD ACTIVITY ---
        Recent checkpoints (newest last):
        - 2026-03-30T22:08:05.307Z dashboard.website_row.metrics_column.appear | interactionID=1
        - 2026-03-30T22:08:05.307Z dashboard.website_row.progress_slot.appear | interactionID=1
        - 2026-03-30T22:08:05.321Z dashboard.expanded_container.appear | interactionID=1
        - 2026-03-30T22:08:05.329Z dashboard.window_rows.appear | interactionID=1
        - 2026-03-30T22:08:05.789Z watchdog.delay | elapsed_s=0.542 count=1
        - 2026-03-30T22:08:16.292Z watchdog.delay | elapsed_s=11.044 count=50

        Captured main-thread stack snapshots:
        [1] 2026-03-30T22:08:05.196Z dashboard.window_usage.publish_state
        0   Retrace  frame0
        1   Retrace  frame1
        2   Retrace  frame2
        3   Retrace  frame3
        4   Retrace  frame4
        5   Retrace  frame5
        6   Retrace  frame6
        7   Retrace  frame7
        8   Retrace  frame8
        9   Retrace  frame9
        10  Retrace  frame10
        11  Retrace  frame11
        12  Retrace  frame12

        [2] 2026-03-30T22:08:05.271Z dashboard.app_row.toggle_expansion
        0   Retrace  second0
        1   Retrace  second1

        --- CURRENT THREAD ---
        Thread: <NSThread: 0x96851c640>{number = 5, name = MainThreadWatchdog}
        0   Retrace  watchdog0
        1   Retrace  watchdog1
        """

        let compacted = FeedbackService.compactEmergencyCrashReportForFeedback(report)

        XCTAssertTrue(compacted.contains("=== RETRACE EMERGENCY DIAGNOSTIC ==="))
        XCTAssertTrue(compacted.contains("Note: Compacted for feedback submission"))
        XCTAssertTrue(compacted.contains("--- SYSTEM ---"))
        XCTAssertTrue(compacted.contains("--- PERFORMANCE ---"))
        XCTAssertTrue(compacted.contains("--- DISPLAYS ---"))
        XCTAssertTrue(compacted.contains("--- MAIN THREAD BACKTRACE ---"))
        XCTAssertTrue(compacted.contains("--- MAIN THREAD ACTIVITY (COMPACTED) ---"))
        XCTAssertTrue(compacted.contains("dashboard.expanded_container.appear"))
        XCTAssertTrue(compacted.contains("dashboard.window_rows.appear"))
        XCTAssertTrue(compacted.contains("watchdog.delay | elapsed_s=11.044 count=50"))
        XCTAssertFalse(compacted.contains("watchdog.delay | elapsed_s=0.542 count=1"))
        XCTAssertTrue(compacted.contains("Captured main-thread stack snapshots (latest only):"))
        XCTAssertTrue(compacted.contains("[1] 2026-03-30T22:08:05.196Z dashboard.window_usage.publish_state"))
        XCTAssertFalse(compacted.contains("[2] 2026-03-30T22:08:05.271Z dashboard.app_row.toggle_expansion"))
        XCTAssertTrue(compacted.contains("additional stack frames omitted"))
        XCTAssertFalse(compacted.contains("--- CURRENT THREAD ---"))
        XCTAssertFalse(compacted.contains("watchdog0"))
    }

    func testCompactDiagnosticCrashReportForFeedbackKeepsEssentialJSONFieldsOnly() {
        let report = """
        {
          "timestamp": "2026-04-05 22:44:00.00 -0700",
          "bug_type": "309",
          "procName": "Retrace",
          "procPath": "/Applications/Retrace.app/Contents/MacOS/Retrace",
          "bundleInfo": {
            "CFBundleShortVersionString": "0.9.1",
            "CFBundleVersion": "123"
          },
          "modelCode": "Mac15,8",
          "faultingThread": 2,
          "exception": {
            "type": "EXC_BAD_ACCESS",
            "signal": "SIGSEGV",
            "codes": "0x0000000000000001, 0x0000000100000000"
          },
          "termination": {
            "namespace": "SIGNAL",
            "indicator": "Segmentation fault: 11",
            "reasons": "Namespace SIGNAL, Code 11",
            "byProc": "exc handler"
          },
          "threads": [
            { "frames": [{"imageName":"Retrace","symbol":"frame0"}] },
            { "frames": [{"imageName":"Retrace","symbol":"frame1"}] },
            {
              "frames": [
                {"imageName":"Retrace","symbol":"frame2"},
                {"imageName":"SwiftUI","symbol":"frame3"}
              ]
            }
          ]
        }
        """

        let compacted = FeedbackService.compactDiagnosticCrashReportForFeedback(
            report,
            fileName: "Retrace-2026-04-05-224400.ips"
        )

        XCTAssertTrue(compacted.contains("=== RETRACE macOS DIAGNOSTIC CRASH REPORT ==="))
        XCTAssertTrue(compacted.contains("File: Retrace-2026-04-05-224400.ips"))
        XCTAssertTrue(compacted.contains("--- METADATA ---"))
        XCTAssertTrue(compacted.contains("procName: Retrace"))
        XCTAssertTrue(compacted.contains("bundleVersion: 0.9.1"))
        XCTAssertTrue(compacted.contains("--- EXCEPTION ---"))
        XCTAssertTrue(compacted.contains("type: EXC_BAD_ACCESS"))
        XCTAssertTrue(compacted.contains("faultingThread: 2"))
        XCTAssertTrue(compacted.contains("--- CRASHING THREAD ---"))
        XCTAssertTrue(compacted.contains("0 Retrace frame2"))
        XCTAssertTrue(compacted.contains("1 SwiftUI frame3"))
    }

    func testCompactDiagnosticCrashReportForFeedbackKeepsEssentialPlaintextSectionsOnly() {
        let report = """
        Process:               Retrace [12345]
        Path:                  /Applications/Retrace.app/Contents/MacOS/Retrace
        Identifier:            io.retrace.app
        Version:               0.9.1 (123)
        Code Type:             ARM-64 (Native)
        Date/Time:             2026-04-05 22:44:00.000 -0700
        OS Version:            macOS 26.1 (25B500)
        Hardware Model:        Mac15,8
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000000
        Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11
        Crashed Thread:        4 Dispatch queue: com.apple.main-thread

        Last Exception Backtrace:
        0   Retrace  frame0
        1   SwiftUI  frame1

        Thread 4 Crashed:
        0   Retrace  crash0
        1   SwiftUI  crash1
        2   AppKit   crash2

        Binary Images:
        0x100000000 - 0x1000fffff Retrace
        """

        let compacted = FeedbackService.compactDiagnosticCrashReportForFeedback(
            report,
            fileName: "Retrace-2026-04-05-224400.crash"
        )

        XCTAssertTrue(compacted.contains("=== RETRACE macOS DIAGNOSTIC CRASH REPORT ==="))
        XCTAssertTrue(compacted.contains("--- METADATA ---"))
        XCTAssertTrue(compacted.contains("Process:               Retrace [12345]"))
        XCTAssertTrue(compacted.contains("--- EXCEPTION ---"))
        XCTAssertTrue(compacted.contains("Exception Type:        EXC_BAD_ACCESS (SIGSEGV)"))
        XCTAssertTrue(compacted.contains("--- LAST EXCEPTION BACKTRACE ---"))
        XCTAssertTrue(compacted.contains("0   Retrace  frame0"))
        XCTAssertTrue(compacted.contains("--- CRASHING THREAD ---"))
        XCTAssertTrue(compacted.contains("0   Retrace  crash0"))
        XCTAssertFalse(compacted.contains("Binary Images:"))
    }

    func testCompactFeedbackLogEntriesGroupsHighVolumeFamiliesAndKeepsRawOneOffs() throws {
        let rawEntries = groupedLogInputEntries() + [
            "[2026-04-05T01:05:29Z] [DEBUG] [App] AppCoordinator.swift:2430 - Started segment: com.openai.codex [segmentID=42, windowToken=w_3f6a8c1d2b4e, browserURL=nil]"
        ]

        let compacted = FeedbackService.compactFeedbackLogEntries(rawEntries)

        XCTAssertEqual(compacted.retainedLogs, [
            "[2026-04-05T01:05:29Z] [DEBUG] [App] AppCoordinator.swift:2430 - Started segment: com.openai.codex [segmentID=42, windowToken=w_3f6a8c1d2b4e, browserURL=nil]"
        ])

        let groupedLogs = try XCTUnwrap(compacted.groupedLogs)
        XCTAssertEqual(Set(groupedLogs.schema.keys), Set(["fd", "hf", "ro", "ts"]))

        let frameDeduped = try XCTUnwrap(groupedLogs.groups.first { $0.eventCode == "fd" })
        XCTAssertTrue(frameDeduped.scalarFields.isEmpty)
        XCTAssertEqual(frameDeduped.seriesFields["dt"], [0, 67_000])
        XCTAssertEqual(Set(frameDeduped.seriesFields.keys), Set(["dt"]))

        let regionOCR = try XCTUnwrap(groupedLogs.groups.first { $0.eventCode == "ro" })
        XCTAssertTrue(regionOCR.scalarFields.isEmpty)
        XCTAssertEqual(regionOCR.seriesFields["dt"], [0, 5_000])
        XCTAssertEqual(Set(regionOCR.seriesFields.keys), Set(["dt"]))

        let fragmentWrites = try XCTUnwrap(groupedLogs.groups.first { $0.eventCode == "hf" })
        XCTAssertTrue(fragmentWrites.scalarFields.isEmpty)
        XCTAssertEqual(fragmentWrites.seriesFields["dt"], [0, 6_000])
        XCTAssertEqual(Set(fragmentWrites.seriesFields.keys), Set(["dt"]))

        let timelineScrub = try XCTUnwrap(groupedLogs.groups.first { $0.eventCode == "ts" })
        XCTAssertTrue(timelineScrub.scalarFields.isEmpty)
        XCTAssertEqual(timelineScrub.seriesFields["dt"], [0, 5_000])
        XCTAssertEqual(Set(timelineScrub.seriesFields.keys), Set(["dt"]))
    }

    func testReadRecentFeedbackLogEntriesSkipsExcludedNoiseAndSQLFragments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = [
            "[2026-04-05T01:05:20Z] [INFO] [UI] First kept line",
            "[2026-04-05T01:05:21Z] [INFO] [Processing] FrameProcessingQueue.swift:1337 - [Queue-TIMING] Frame 123: prep=15ms frame=63ms ocr=604ms index=10ms total=692ms size=3024x1964",
            "SELECT f.id, f.createdAt FROM frame f",
            "[2026-04-05T01:05:22Z] [INFO] [UI] Second kept line",
            "[2026-04-05T01:05:23Z] [DEBUG] [Processing] FrameProcessingQueue.swift:724 - [Queue-Rewrite] Suspended pending segment rewrites (timeline-scrubbing); timelineVisible=true, scrubbing=true",
            "[2026-04-05T01:05:24Z] [INFO] [UI] Third kept line",
        ].joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let lines = FeedbackService.readRecentFeedbackLogEntries(maxCount: 2, fileURL: url)

        XCTAssertEqual(lines, [
            "[2026-04-05T01:05:22Z] [INFO] [UI] Second kept line",
            "[2026-04-05T01:05:24Z] [INFO] [UI] Third kept line",
        ])
    }

    func testReadRecentFeedbackLogEntriesLossilyHandlesInvalidUTF8() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data("[2026-04-05T01:05:25Z] [INFO] first line\n".utf8)
        data.append(Data([0xF0, 0x9F]))
        data.append(Data("broken utf8\n[2026-04-05T01:05:30Z] [INFO] second line\n".utf8))
        try data.write(to: url)

        let lines = FeedbackService.readRecentFeedbackLogEntries(maxCount: 10, fileURL: url)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "[2026-04-05T01:05:25Z] [INFO] first line")
        XCTAssertTrue(lines[1].contains("broken utf8"))
        XCTAssertEqual(lines.last, "[2026-04-05T01:05:30Z] [INFO] second line")
    }

    func testReadRecentFeedbackLogEntriesHandlesChunkBoundariesFromTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = (1...220).map { index in
            let padding = String(repeating: "x", count: 380)
            return "[2026-04-05T01:05:\(String(format: "%02d", index % 60))Z] [INFO] [UI] Chunk boundary line \(index) \(padding)"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let retained = FeedbackService.readRecentFeedbackLogEntries(maxCount: 3, fileURL: url)

        XCTAssertEqual(retained, Array(lines.suffix(3)))
    }

    func testCollectFeedbackLogSnapshotKeeps500RawLinesDespiteGroupedAndExcludedNoise() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: url) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseDate = Date(timeIntervalSince1970: 1_775_313_600)

        func timestamp(_ offset: Int) -> String {
            formatter.string(from: baseDate.addingTimeInterval(TimeInterval(offset)))
        }

        let rawLines = (1...520).map { index in
            "[\(timestamp(index))] [INFO] [UI] Raw kept line \(index)"
        }

        let groupedLines = (1...100).map { index in
            "[\(timestamp(1_000 + index))] [DEBUG] [UI] SimpleTimelineViewModel.swift:14366 - [Timeline-Scrub] started source=trackpad"
        }

        let excludedLines = (1...100).map { index in
            "[\(timestamp(2_000 + index))] [INFO] [Processing] FrameProcessingQueue.swift:1337 - [Queue-TIMING] Frame \(index): prep=15ms frame=63ms ocr=604ms index=10ms total=692ms size=3024x1964"
        }

        let contents = (rawLines + groupedLines + excludedLines).joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let snapshot = FeedbackService.collectFeedbackLogSnapshot(
            rawLimit: 500,
            fileURL: url,
            groupedLimitPerFamily: 2_000
        )

        XCTAssertEqual(snapshot.retainedLogs.count, 500)
        XCTAssertEqual(snapshot.retainedLogs.first, rawLines[20])
        XCTAssertEqual(snapshot.retainedLogs.last, rawLines[519])

        let groupedLogs = try XCTUnwrap(snapshot.groupedLogs)
        let scrubGroup = try XCTUnwrap(groupedLogs.groups.first { $0.eventCode == "ts" })
        XCTAssertEqual(scrubGroup.seriesFields["dt"]?.count, 100)
    }

    func testCollectFeedbackLogSnapshotSkipsRecentErrorsAndStillBackfillsRawBudget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: url) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseDate = Date(timeIntervalSince1970: 1_775_313_600)

        func timestamp(_ offset: Int) -> String {
            formatter.string(from: baseDate.addingTimeInterval(TimeInterval(offset)))
        }

        let rawLines = (1...1_020).map { index in
            "[\(timestamp(index))] [INFO] [UI] Raw kept line \(index)"
        }

        let errorLines = (1...80).map { index in
            "[\(timestamp(2_000 + index))] [⚠️ WARN] [UI] Logging.swift:257 - [PERF] slow sample \(index)"
        }

        let contents = (rawLines + errorLines).joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let snapshot = FeedbackService.collectFeedbackLogSnapshot(
            rawLimit: 1_000,
            fileURL: url,
            groupedLimitPerFamily: 2_000
        )

        XCTAssertEqual(snapshot.retainedLogs.count, 1_000)
        XCTAssertFalse(snapshot.retainedLogs.contains { $0.contains("[⚠️ WARN]") })
        XCTAssertEqual(snapshot.retainedLogs.first, rawLines[20])
        XCTAssertEqual(snapshot.retainedLogs.last, rawLines[1_019])
    }

    func testFormattedMemoryProfileBytesUsesGBBeforeMBHitsFourDigits() {
        XCTAssertEqual(
            FeedbackService.formattedMemoryProfileBytes(1016 * 1024 * 1024),
            "0.99 GB"
        )
        XCTAssertEqual(
            FeedbackService.formattedMemoryProfileBytes(512 * 1024 * 1024),
            "512 MB"
        )
    }

    func testSubmissionRawLogBudgetReservesSpaceForGeneratedMemorySummaryLogs() {
        XCTAssertEqual(FeedbackService.submissionRawLogBudget(memorySummaryCount: 0), 10_000)
        XCTAssertEqual(FeedbackService.submissionRawLogBudget(memorySummaryCount: 1), 9_999)
        XCTAssertEqual(FeedbackService.submissionRawLogBudget(memorySummaryCount: 7), 9_993)
        XCTAssertEqual(FeedbackService.submissionRawLogBudget(memorySummaryCount: 20_000), 0)
    }

    @MainActor
    func testCanExportWithoutDescriptionOrValidEmail() {
        let viewModel = FeedbackViewModel()
        viewModel.email = "not-an-email"
        viewModel.description = ""

        XCTAssertTrue(viewModel.canExport)
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testExportTextReturnsMachineReadableJSONDocument() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_773_489_600)
        let diagnostics = makeSampleDiagnostics()

        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "Steps to reproduce\n1. Open Help\n2. Block network",
            diagnostics: diagnostics,
            includeScreenshot: true,
            screenshotData: Data([0x89, 0x50])
        )

        let text = submission.exportText(
            generatedAt: generatedAt,
            launchSource: .crashBanner,
            screenshotFileName: "report-screenshot.png"
        )
        XCTAssertTrue(text.contains(#""metadata""#))
        XCTAssertTrue(text.contains(#""report""#))
        XCTAssertFalse(text.contains("=== BEGIN SUBMISSION JSON ==="))
        XCTAssertFalse(text.contains("=== FEEDBACK ==="))
        XCTAssertFalse(text.contains("--- FULL LOGS (last hour) ---"))

        let payload = try exportPayload(from: text)
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["launchSource"] as? String, "crashBanner")
        XCTAssertEqual(metadata["screenshotFileName"] as? String, "report-screenshot.png")
        XCTAssertEqual(metadata["screenshotByteCount"] as? Int, 2)
        XCTAssertEqual(metadata["exportFormatVersion"] as? Int, 4)

        let report = try XCTUnwrap(payload["report"] as? [String: Any])
        let feedback = try XCTUnwrap(report["feedback"] as? [String: Any])
        XCTAssertEqual(feedback["type"] as? String, "Bug Report")
        XCTAssertEqual(feedback["email"] as? String, "user@example.com")
        XCTAssertEqual(feedback["includeScreenshot"] as? Bool, true)
        XCTAssertEqual(feedback["description"] as? String, "Steps to reproduce\n1. Open Help\n2. Block network")

        let diagnosticsPayload = try XCTUnwrap(report["diagnostics"] as? [String: Any])
        let diagnosticsSummary = try XCTUnwrap(diagnosticsPayload["summary"] as? [String: Any])
        let diagnosticsSections = try XCTUnwrap(diagnosticsPayload["sections"] as? [String: Any])
        XCTAssertEqual(
            diagnosticsSummary["includedSectionIDs"] as? [String],
            [
                "app_system",
                "database",
                "displays",
                "performance",
                "retrace_memory_summary",
                "running_apps",
                "accessibility",
                "recent_errors",
                "settings",
                "recent_actions",
                "emergency_crash_reports",
                "full_logs",
            ]
        )
        XCTAssertEqual(
            diagnosticsSummary["sectionOrder"] as? [String],
            [
                "app_system",
                "database",
                "displays",
                "performance",
                "retrace_memory_summary",
                "running_apps",
                "accessibility",
                "recent_errors",
                "settings",
                "recent_actions",
                "emergency_crash_reports",
                "full_logs",
            ]
        )
        let fullLogsSection = try XCTUnwrap(diagnosticsSections["full_logs"] as? [String: Any])
        let counts = try XCTUnwrap(fullLogsSection["counts"] as? [String: Any])
        XCTAssertEqual(counts["representedEntries"] as? Int, 1)
        XCTAssertEqual(counts["rawEntries"] as? Int, 1)
        XCTAssertEqual(fullLogsSection["rawEncoding"] as? String, "gzip_base64_utf8")
        XCTAssertEqual(
            try decodeRawLogText(from: fullLogsSection),
            "2026-03-13T11:59:00Z [INFO] Sample log line"
        )
        XCTAssertEqual(fullLogsSection["recentErrorsStoredSeparately"] as? Bool, true)
        XCTAssertNil(fullLogsSection["preview"])
        XCTAssertNil(fullLogsSection["title"])
    }

    func testExportTextOmitsUncheckedDiagnosticSectionsFromJSONPayload() throws {
        let diagnostics = makeSampleDiagnostics()
        let submission = FeedbackSubmission(
            type: .bug,
            description: "Need a narrower report",
            diagnostics: diagnostics,
            includedDiagnosticSections: [
                .appSystem,
                .memorySummary,
                .recentActions,
            ]
        )

        let text = submission.exportText(generatedAt: Date(timeIntervalSince1970: 1_773_489_600))
        XCTAssertFalse(text.contains("=== DATABASE ==="))

        let payload = try exportPayload(from: text)
        let report = try XCTUnwrap(payload["report"] as? [String: Any])
        let diagnosticsPayload = try XCTUnwrap(report["diagnostics"] as? [String: Any])
        let diagnosticsSummary = try XCTUnwrap(diagnosticsPayload["summary"] as? [String: Any])
        let diagnosticsSections = try XCTUnwrap(diagnosticsPayload["sections"] as? [String: Any])

        XCTAssertEqual(
            diagnosticsSummary["includedSectionIDs"] as? [String],
            ["app_system", "retrace_memory_summary", "recent_actions"]
        )
        XCTAssertNil(diagnosticsSections["database"])
        XCTAssertNil(diagnosticsSections["settings"])
        XCTAssertNil(diagnosticsSections["full_logs"])
    }

    func testExportTextEmbedsGroupedLogsAndRawLogsInsideFullLogsSection() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_773_489_600)
        let diagnostics = makeGroupedLogDiagnostics()

        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "Grouped logs please",
            diagnostics: diagnostics
        )

        let text = submission.exportText(generatedAt: generatedAt)
        XCTAssertTrue(text.contains(#""grouped""#))
        XCTAssertTrue(text.contains(#""rawData""#))
        XCTAssertTrue(text.contains(#""rawEncoding""#))
        XCTAssertFalse(text.contains(#""preview""#))
        XCTAssertFalse(text.contains(#""title""#))

        let payload = try exportPayload(from: text)
        let report = try XCTUnwrap(payload["report"] as? [String: Any])
        let diagnosticsPayload = try XCTUnwrap(report["diagnostics"] as? [String: Any])
        let diagnosticsSections = try XCTUnwrap(diagnosticsPayload["sections"] as? [String: Any])
        let fullLogsSection = try XCTUnwrap(diagnosticsSections["full_logs"] as? [String: Any])
        let counts = try XCTUnwrap(fullLogsSection["counts"] as? [String: Any])
        XCTAssertEqual(counts["groupedFamilies"] as? Int, 4)
        XCTAssertEqual(counts["groupedEntries"] as? Int, 8)
        XCTAssertEqual(counts["rawEntries"] as? Int, 1)

        let grouped = try XCTUnwrap(fullLogsSection["grouped"] as? [String: Any])
        let schema = try XCTUnwrap(grouped["schema"] as? [String: Any])
        let groups = try XCTUnwrap(grouped["groups"] as? [[String: Any]])
        let rawText = try decodeRawLogText(from: fullLogsSection)

        XCTAssertEqual(Set(schema.keys), Set(["fd", "hf", "ro", "ts"]))
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(rawText, "2026-03-13T11:59:00Z [INFO] Sample log line")
    }

    func testExportJSONDoesNotRepeatRecentErrorsInsideRecentLogs() throws {
        let repeatedError = "[2026-04-05T02:47:21.875Z] [⚠️ WARN] [UI] Logging.swift:257 - [PERF] dashboard.query.storage_single_day_ms slow sample: 269.8ms (warning >= 250.0ms)"
        let diagnostics = DiagnosticInfo(
            appVersion: "1.2.3",
            buildNumber: "45",
            macOSVersion: "14.4",
            deviceModel: "Mac14,15",
            totalDiskSpace: "1 TB",
            freeDiskSpace: "512 GB",
            databaseStats: DiagnosticInfo.DatabaseStats(
                sessionCount: 3,
                frameCount: 42,
                segmentCount: 7,
                databaseSizeMB: 128.5
            ),
            settingsSnapshot: [:],
            recentErrors: [repeatedError],
            recentLogs: [
                "2026-03-13T11:57:00Z [FeedbackMemoryProfile] Sampler window: 12.0 h | latest sample age: 1 s",
                repeatedError,
                "2026-03-13T11:59:00Z [INFO] Sample log line"
            ],
            recentMetricEvents: [],
            displayInfo: makeSampleDiagnostics().displayInfo,
            processInfo: makeSampleDiagnostics().processInfo,
            accessibilityInfo: makeSampleDiagnostics().accessibilityInfo,
            performanceInfo: makeSampleDiagnostics().performanceInfo,
            emergencyCrashReports: nil,
            timestamp: Date(timeIntervalSince1970: 1_773_486_000)
        )

        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "No duplicate errors",
            diagnostics: diagnostics
        )

        let payload = try exportPayload(
            from: submission.exportText(generatedAt: Date(timeIntervalSince1970: 1_773_489_600))
        )
        let report = try XCTUnwrap(payload["report"] as? [String: Any])
        let diagnosticsPayload = try XCTUnwrap(report["diagnostics"] as? [String: Any])
        let diagnosticsSections = try XCTUnwrap(diagnosticsPayload["sections"] as? [String: Any])
        let recentErrorsSection = try XCTUnwrap(diagnosticsSections["recent_errors"] as? [String: Any])
        let recentErrors = try XCTUnwrap(recentErrorsSection["entries"] as? [String])
        let fullLogsSection = try XCTUnwrap(diagnosticsSections["full_logs"] as? [String: Any])
        let rawText = try decodeRawLogText(from: fullLogsSection)

        XCTAssertEqual(recentErrors, [repeatedError])
        XCTAssertFalse(rawText.contains(repeatedError))
    }

    func testExportTextReturnsCompactJSONDocument() throws {
        let diagnostics = makeGroupedLogDiagnostics()
        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "Grouped logs please",
            diagnostics: diagnostics
        )

        let text = submission.exportText(generatedAt: Date(timeIntervalSince1970: 1_773_489_600))
        let jsonString = try exportPayloadString(from: text)
        let lines = jsonString.components(separatedBy: .newlines)
        let maxLineLength = lines.map(\.count).max() ?? 0

        XCTAssertEqual(lines.count, 1)
        XCTAssertGreaterThan(maxLineLength, 1_000)
        XCTAssertTrue(jsonString.contains(#""summary""#))
        XCTAssertTrue(jsonString.contains(#""sections""#))
        XCTAssertTrue(jsonString.contains(#""rawData""#))
        XCTAssertTrue(jsonString.contains(#""rawEncoding""#))
        XCTAssertTrue(jsonString.contains(#""grouped""#))
    }

    func testDiagnosticSectionSummariesUseCompactPreviewsForVerboseSections() throws {
        let diagnostics = makePreviewDiagnostics()
        let summaries = diagnostics.sectionSummaries(includeVerboseSections: true)

        let memorySummary = try XCTUnwrap(summaries.first { $0.id == .memorySummary })
        XCTAssertEqual(
            memorySummary.previewDisclosure,
            "Preview truncated. Download .json.gz below to inspect the full contents."
        )

        let settingsSummary = try XCTUnwrap(summaries.first { $0.id == .settings })
        XCTAssertTrue(settingsSummary.preview.contains("more lines"))
        XCTAssertEqual(
            settingsSummary.previewDisclosure,
            "Preview truncated. Download .json.gz below to inspect the full contents."
        )

        let recentActionsSummary = try XCTUnwrap(summaries.first { $0.id == .recentActions })
        XCTAssertTrue(recentActionsSummary.preview.contains("more lines"))
        XCTAssertEqual(
            recentActionsSummary.previewDisclosure,
            "Preview truncated. Download .json.gz below to inspect the full contents."
        )

        let fullLogsSummary = try XCTUnwrap(summaries.first { $0.id == .fullLogs })
        XCTAssertTrue(fullLogsSummary.preview.contains("…"))
        XCTAssertTrue(fullLogsSummary.preview.contains("downloadable .json.gz report"))
        let fullLogsDisclosure = try XCTUnwrap(fullLogsSummary.previewDisclosure)
        XCTAssertEqual(fullLogsDisclosure, DiagnosticInfo.fullLogsPreviewDisclosureText())
        XCTAssertTrue(fullLogsDisclosure.contains("last ~30 minutes"))
        XCTAssertFalse(fullLogsSummary.preview.contains("Full log entry 6"))

        let crashReportsSummary = try XCTUnwrap(summaries.first { $0.id == .emergencyCrashReports })
        XCTAssertTrue(crashReportsSummary.preview.contains("plus 1 more report"))
        XCTAssertEqual(
            crashReportsSummary.previewDisclosure,
            "Preview truncated. Download .json.gz below to inspect the full contents."
        )
        XCTAssertFalse(crashReportsSummary.preview.contains("Crash line 12"))
    }

    func testSuggestedBaseNameSlugifiesFeedbackType() {
        let baseName = FeedbackSubmission.suggestedBaseName(
            forType: "Feature Request",
            timestamp: Date(timeIntervalSince1970: 1_773_489_600)
        )

        XCTAssertEqual(baseName, "retrace-feedback-feature-request-2026-03-14-120000")
    }

    func testSuggestedExportURLUsesProvidedDirectory() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let exportURL = FeedbackViewModel.suggestedExportURL(
            defaultFileName: "retrace-feedback-bug-report.json.gz",
            directoryURL: directoryURL
        )

        XCTAssertEqual(exportURL.deletingLastPathComponent(), directoryURL)
        XCTAssertEqual(exportURL.lastPathComponent, "retrace-feedback-bug-report.json.gz")
    }

    func testSuggestedExportURLKeepsProvidedFilenameWhenFileAlreadyExists() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let existingURL = directoryURL.appendingPathComponent("retrace-feedback-bug-report.json.gz")
        try "existing".write(to: existingURL, atomically: true, encoding: .utf8)

        let exportURL = FeedbackViewModel.suggestedExportURL(
            defaultFileName: "retrace-feedback-bug-report.json.gz",
            directoryURL: directoryURL
        )

        XCTAssertEqual(exportURL.lastPathComponent, "retrace-feedback-bug-report.json.gz")
    }

    private func exportPayload(from text: String) throws -> [String: Any] {
        let jsonString = try exportPayloadString(from: text)
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func exportPayloadString(from text: String) throws -> String {
        text
    }

    private func decodeRawLogText(from fullLogsSection: [String: Any]) throws -> String {
        let rawEncoding = try XCTUnwrap(fullLogsSection["rawEncoding"] as? String)
        let rawData = try XCTUnwrap(fullLogsSection["rawData"] as? String)
        let payload = try XCTUnwrap(Data(base64Encoded: rawData))

        switch rawEncoding {
        case "gzip_base64_utf8":
            return try XCTUnwrap(String(data: gunzip(payload), encoding: .utf8))
        case "base64_utf8":
            return try XCTUnwrap(String(data: payload, encoding: .utf8))
        default:
            XCTFail("Unexpected rawEncoding: \(rawEncoding)")
            return ""
        }
    }

    private func makeSampleDiagnostics() -> DiagnosticInfo {
        DiagnosticInfo(
            appVersion: "1.2.3",
            buildNumber: "45",
            macOSVersion: "14.4",
            deviceModel: "Mac14,15",
            totalDiskSpace: "1 TB",
            freeDiskSpace: "512 GB",
            databaseStats: DiagnosticInfo.DatabaseStats(
                sessionCount: 3,
                frameCount: 42,
                segmentCount: 7,
                databaseSizeMB: 128.5
            ),
            settingsSnapshot: [
                "captureIntervalSeconds": "2",
                "isRecordingEnabled": "true"
            ],
            recentErrors: ["[ERROR] Sample error"],
            recentLogs: [
                "2026-03-13T11:57:00Z [FeedbackMemoryProfile] Sampler window: 12.0 h | latest sample age: 1 s",
                "2026-03-13T11:58:00Z [FeedbackMemoryProfile] Retrace memory hierarchy:",
                "2026-03-13T11:58:01Z [FeedbackMemoryProfile] Retrace: now 512 MB | avg 480 MB | peak 600 MB | tracked share now 55.0%",
                "2026-03-13T11:58:02Z [FeedbackMemoryProfile]   storage.videoEncoding: now 256 MB | avg 240 MB | peak 320 MB | tracked share now 27.5%",
                "2026-03-13T11:59:00Z [INFO] Sample log line"
            ],
            recentMetricEvents: [
                FeedbackRecentMetricEvent(
                    timestamp: Date(timeIntervalSince1970: 1_773_485_700),
                    metricType: "help_opened",
                    summary: "Help opened",
                    details: ["source": "dashboard"]
                ),
                FeedbackRecentMetricEvent(
                    timestamp: Date(timeIntervalSince1970: 1_773_485_760),
                    metricType: "filtered_search_query",
                    summary: "Filtered search submitted",
                    details: ["queryLength": "12", "filterCount": "2"]
                )
            ],
            displayInfo: DiagnosticInfo.DisplayInfo(
                count: 1,
                displays: [
                    DiagnosticInfo.DisplayInfo.Display(
                        index: 0,
                        resolution: "3024x1964",
                        backingScaleFactor: "2.0",
                        colorSpace: "P3",
                        refreshRate: "120Hz",
                        isRetina: true,
                        frame: "(0,0,3024,1964)"
                    )
                ],
                mainDisplayIndex: 0
            ),
            processInfo: DiagnosticInfo.ProcessInfo(
                totalRunning: 12,
                eventMonitoringApps: 1,
                windowManagementApps: 0,
                securityApps: 1,
                hasJamf: false,
                hasKandji: false,
                axuiServerCPU: 2.3,
                windowServerCPU: 8.1
            ),
            accessibilityInfo: DiagnosticInfo.AccessibilityInfo(
                voiceOverEnabled: false,
                switchControlEnabled: false,
                reduceMotionEnabled: true,
                increaseContrastEnabled: false,
                reduceTransparencyEnabled: false,
                differentiateWithoutColorEnabled: false,
                displayHasInvertedColors: false
            ),
            performanceInfo: DiagnosticInfo.PerformanceInfo(
                cpuUsagePercent: 12.5,
                memoryUsedGB: 8.0,
                memoryTotalGB: 18.0,
                memoryPressure: "normal",
                swapUsedGB: 0.0,
                thermalState: "nominal",
                processorCount: 10,
                isLowPowerModeEnabled: false,
                powerSource: "AC",
                batteryLevel: 82
            ),
            emergencyCrashReports: ["Sample emergency report"],
            timestamp: Date(timeIntervalSince1970: 1_773_486_000)
        )
    }

    private func makePreviewDiagnostics() -> DiagnosticInfo {
        let base = makeSampleDiagnostics()

        let recentLogs = [
            "2026-03-13T11:57:00Z [FeedbackMemoryProfile] Retrace memory hierarchy:",
            "2026-03-13T11:58:01Z [FeedbackMemoryProfile] Retrace: now 512 MB | avg 480 MB | peak 600 MB",
            "2026-03-13T11:58:02Z [FeedbackMemoryProfile]   storage.videoEncoding: now 256 MB | avg 240 MB | peak 320 MB",
            "2026-03-13T11:58:03Z [FeedbackMemoryProfile]   storage.imageExtraction: now 128 MB | avg 120 MB | peak 160 MB",
            "2026-03-13T11:58:04Z [FeedbackMemoryProfile]   processing.ocr: now 96 MB | avg 92 MB | peak 104 MB",
            "2026-03-13T11:58:05Z [FeedbackMemoryProfile]   ui.caches: now 48 MB | avg 45 MB | peak 60 MB",
        ] + (1...6).map { index in
            "2026-03-13T11:59:0\(index)Z [INFO] Full log entry \(index)"
        }

        let primaryCrashReport = (1...12)
            .map { "Crash line \($0)" }
            .joined(separator: "\n")

        let settingsSnapshot = Dictionary(uniqueKeysWithValues: (1...25).map { index in
            ("settingKey\(index)", "value\(index)")
        })

        let recentMetricEvents = (1...100).map { index in
            FeedbackRecentMetricEvent(
                timestamp: Date(timeIntervalSince1970: 1_773_485_700 + TimeInterval(index)),
                metricType: "search_submitted",
                summary: "Search submitted",
                details: ["queryLength": "\(index % 7 + 1)"]
            )
        }

        return DiagnosticInfo(
            appVersion: base.appVersion,
            buildNumber: base.buildNumber,
            macOSVersion: base.macOSVersion,
            deviceModel: base.deviceModel,
            totalDiskSpace: base.totalDiskSpace,
            freeDiskSpace: base.freeDiskSpace,
            databaseStats: base.databaseStats,
            settingsSnapshot: settingsSnapshot,
            recentErrors: base.recentErrors,
            recentLogs: recentLogs,
            recentMetricEvents: recentMetricEvents,
            displayInfo: base.displayInfo,
            processInfo: base.processInfo,
            accessibilityInfo: base.accessibilityInfo,
            performanceInfo: base.performanceInfo,
            emergencyCrashReports: [
                primaryCrashReport,
                "Secondary crash report"
            ],
            timestamp: base.timestamp
        )
    }

    private func makeGroupedLogDiagnostics() -> DiagnosticInfo {
        let base = makeSampleDiagnostics()
        let compacted = FeedbackService.compactFeedbackLogEntries(groupedLogInputEntries())

        return DiagnosticInfo(
            appVersion: base.appVersion,
            buildNumber: base.buildNumber,
            macOSVersion: base.macOSVersion,
            deviceModel: base.deviceModel,
            totalDiskSpace: base.totalDiskSpace,
            freeDiskSpace: base.freeDiskSpace,
            databaseStats: base.databaseStats,
            settingsSnapshot: base.settingsSnapshot,
            recentErrors: base.recentErrors,
            recentLogs: base.recentLogs + compacted.retainedLogs,
            groupedRecentLogs: compacted.groupedLogs,
            recentMetricEvents: base.recentMetricEvents,
            displayInfo: base.displayInfo,
            processInfo: base.processInfo,
            accessibilityInfo: base.accessibilityInfo,
            performanceInfo: base.performanceInfo,
            emergencyCrashReports: base.emergencyCrashReports,
            timestamp: base.timestamp
        )
    }

    private func groupedLogInputEntries() -> [String] {
        [
            "[2026-04-05T01:05:25Z] [INFO] [Capture] CaptureManager.swift:729 - Deduplication analysis (trigger: interval, similarity: 99.91%, threshold: 99.85%, keepBySimilarity: false, keepByMouseMovement: false, outcome: deduplicated)",
            "[2026-04-05T01:06:32Z] [INFO] [Capture] CaptureManager.swift:729 - Deduplication analysis (trigger: mouse_click, similarity: 99.95%, threshold: 99.85%, keepBySimilarity: true, keepByMouseMovement: true, outcome: kept)",
            "[2026-04-05T01:05:35Z] [DEBUG] [Processing] ProcessingManager.swift:141 - [ProcessingManager] Region OCR: 24/64 tiles, 62% energy saved, 81.6ms",
            "[2026-04-05T01:05:40Z] [DEBUG] [Processing] ProcessingManager.swift:141 - [ProcessingManager] Region OCR: 8/64 tiles, 87% energy saved, 24.3ms",
            "[2026-04-05T01:05:42Z] [INFO] [Storage] HEVCEncoder.swift:559 - 📦 Fragment 18 written: +512KB (total: 6144KB, 12 frames flushed, video time: 5.0s) - frames now readable!",
            "[2026-04-05T01:05:48Z] [INFO] [Storage] HEVCEncoder.swift:559 - 📦 Fragment 19 written: +768KB (total: 6912KB, 18 frames flushed, video time: 7.5s) - frames now readable!",
            "[2026-04-05T01:05:50Z] [DEBUG] [UI] SimpleTimelineViewModel.swift:14366 - [Timeline-Scrub] started source=trackpad",
            "[2026-04-05T01:05:55Z] [DEBUG] [UI] SimpleTimelineViewModel.swift:14366 - [Timeline-Scrub] started source=mouse-wheel",
            "[2026-04-05T01:05:25Z] [INFO] [UI] SearchViewModel.swift:821 - [Search-Memory] results=0 visibleResults=0 thumbnails=0/Zero KB appIcons=0/Zero KB",
            "[2026-04-05T01:05:30Z] [INFO] [UI] SearchViewModel.swift:821 - [Search-Memory] results=0 visibleResults=0 thumbnails=1/Zero KB appIcons=2/Zero KB",
            "[2026-04-05T01:05:31Z] [INFO] [Processing] FrameProcessingQueue.swift:1156 - [Queue-DIAG] Worker 0 COMPLETED frame 51045031 in 0.45s",
            "[2026-04-05T01:05:32Z] [DEBUG] [UI] SimpleTimelineViewModel.swift:2065 - [SimpleTimelineViewModel] currentVideoInfo: frame 123 videoPath=/tmp/test, frameIndex=1, processingStatus=2",
            "[2026-04-05T01:05:33Z] [INFO] [Processing] FrameProcessingQueue.swift:1337 - [Queue-TIMING] Frame 123: prep=15ms frame=63ms ocr=604ms index=10ms total=692ms size=3024x1964",
            "[2026-04-05T01:05:34Z] [DEBUG] [Processing] FrameProcessingQueue.swift:724 - [Queue-Rewrite] Suspended pending segment rewrites (timeline-scrubbing); timelineVisible=true, scrubbing=true",
            "[2026-04-05T01:05:35Z] [DEBUG] [UI] SimpleTimelineView.swift:2001 - [VideoView] Released decoder resources (view removed from window)",
            "[2026-04-05T01:05:36Z] [INFO] [Storage] StorageManager.swift:681 - [VideoExtract] Invalidated stale cache for 1775357238907, creating fresh generator",
            "[2026-04-05T01:05:37Z] [DEBUG] [Database] DataAdapter.swift:1810 - [Filter] Query SQL:",
            "SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodedAt, f.processingStatus, f.redactionReason,",
            "FROM frame f",
        ]
    }
}

private func gunzip(_ data: Data) throws -> Data {
    var stream = z_stream()
    let initStatus = inflateInit2_(
        &stream,
        MAX_WBITS + 16,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
        throw FeedbackError.invalidData
    }
    defer {
        inflateEnd(&stream)
    }

    let chunkSize = 64 * 1024
    var output = Data()
    var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
    var inflateStatus: Int32 = Z_OK

    try data.withUnsafeBytes { rawInputBuffer in
        guard let inputBaseAddress = rawInputBuffer.bindMemory(to: Bytef.self).baseAddress else {
            throw FeedbackError.invalidData
        }

        stream.next_in = UnsafeMutablePointer(mutating: inputBaseAddress)
        stream.avail_in = uInt(data.count)

        repeat {
            let produced: Int = try outputBuffer.withUnsafeMutableBytes { rawOutputBuffer in
                guard let outputBaseAddress = rawOutputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    throw FeedbackError.invalidData
                }

                stream.next_out = outputBaseAddress
                stream.avail_out = uInt(chunkSize)
                inflateStatus = inflate(&stream, Z_NO_FLUSH)

                guard inflateStatus == Z_OK || inflateStatus == Z_STREAM_END else {
                    throw FeedbackError.invalidData
                }

                return chunkSize - Int(stream.avail_out)
            }

            if produced > 0 {
                output.append(outputBuffer, count: produced)
            }
        } while inflateStatus != Z_STREAM_END
    }

    return output
}
