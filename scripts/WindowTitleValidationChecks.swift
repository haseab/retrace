import Foundation
import CoreGraphics
import SQLCipher
import Shared
import Database
import App
import Storage
@testable import Capture

/// Executable checks for Command Line Tools hosts without XCTest. Uses production
/// matcher/validator sources and a real temporary SQLCipher database.
@main struct WindowTitleValidationChecks {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        check(WindowTitleWords.matches("Validate OCR output with accessibility API",
              "Valldate OCR output with accessibllity API"), "Recorded OCR misspellings must match")
        check(!WindowTitleWords.matches("Validate OCR output with accessibility API",
              "Plan full Limitless data export"), "Recorded BB title mismatch must fail")
        check(!WindowTitleWords.matches("Build Slack notification and unread tracker",
              "Verify host machine for hasbook-bro"), "Historical mismatch must fail")
        check(WindowTitleWords.matches("Validate OCR output with accessibility API",
              "Valldate OCR output with accessibility APl"), "Recorded full-frame OCR API/APl confusion must match")
        check(!WindowTitleWords.matches("Deploy release 101", "Deploy release 102"), "Numbers must remain exact")
        check(!WindowTitleWords.matches("Archive project phoenix", "Archive project phoenix backup"), "Extra words must fail")
        let area = CGRect(x: 0.2, y: 0.025, width: 0.65, height: 0.025)
        let observation = WindowTitleObservation(pid: 31234, windowID: 3933,
            bounds: CGRect(x: 0, y: 30, width: 2560, height: 1410),
            title: "Validate OCR output with accessibility API", titleRegion: area)
        let evidence = WindowTitleEvidence(before: observation, after: observation)
        let id = FrameID(value: 1)
        let text = ExtractedText(frameID: id, timestamp: Date(), regions: [
            TextRegion(frameID: id, text: "Plan full Limitless data export",
                       bounds: CGRect(x: 716, y: 44, width: 307, height: 18)),
            TextRegion(frameID: id, text: observation.title,
                       bounds: CGRect(x: 51, y: 720, width: 384, height: 22))
        ])
        check(WindowTitleValidator.validate(evidence, text: text, width: 2560, height: 1440).confidence == 7,
              "Conflicting header must recover OCR title at confidence 7")
        let correct = ExtractedText(frameID: id, timestamp: Date(), regions: [], chromeRegions: [
            TextRegion(frameID: id, text: "Valldate OCR output with accessibllity API",
                       bounds: CGRect(x: 716, y: 44, width: 400, height: 18))
        ])
        check(WindowTitleValidator.validate(evidence, text: correct, width: 2560, height: 1440).title == observation.title,
              "Existing chrome OCR must verify the title")
        check(WindowTitleValidator.validate(.init(before: observation, after: nil), text: correct,
                                           width: 2560, height: 1440).confidence == 7, "One AX boundary plus OCR has confidence 7")
        let changed = WindowTitleObservation(pid: 31234, windowID: 3933, bounds: observation.bounds,
                                            title: "Plan full Limitless data export", titleRegion: area)
        check(WindowTitleValidator.validate(.init(before: observation, after: changed), text: correct,
                                           width: 2560, height: 1440).confidence == 10, "Changed AX chooses OCR-matched boundary at confidence 10")

        func scored(_ line: String?, before: WindowTitleObservation? = observation,
                    after: WindowTitleObservation? = observation) -> WindowTitleValidator.Result {
            let regions = line.map { [TextRegion(frameID: id, text: $0,
                bounds: CGRect(x: 716, y: 44, width: 400, height: 18))] } ?? []
            return WindowTitleValidator.validate(.init(before: before, after: after, fallbackTitleRegion: area),
                text: ExtractedText(frameID: id, timestamp: Date(), regions: regions), width: 2560, height: 1440)
        }
        check(scored(observation.title).confidence == 10, "Exact caption = 10")
        check(scored("Valldate OCR output with accessibllity API").confidence == 9, "Spelling = 9")
        check(scored("Plan full Limitless data export").confidence == 7, "Conflicting caption = 7")
        check(scored(nil).confidence == 5, "Unreadable caption retains AX at 5")
        check(scored("Validate OCR output with accessib…").confidence == 10, "Explicit matching truncation = 10")
        check(scored(observation.title, after: changed).title == observation.title, "Pixels choose first boundary")
        check(scored(changed.title, after: changed).title == changed.title, "Pixels choose second boundary")
        check(scored(changed.title, before: nil, after: nil).confidence == 7, "OCR-only caption = 7")
        let otherWindow = WindowTitleObservation(pid: 222, windowID: 444, bounds: observation.bounds,
            title: changed.title, titleRegion: area)
        check(scored(otherWindow.title, after: otherWindow).confidence == 10, "Identity transition chooses matching title")
        let ambiguous = ExtractedText(frameID: id, timestamp: Date(), regions: [
            TextRegion(frameID: id, text: observation.title, bounds: CGRect(x: 716, y: 44, width: 400, height: 10)),
            TextRegion(frameID: id, text: "Valldate OCR output with accessibllity API", bounds: CGRect(x: 716, y: 54, width: 400, height: 10))
        ])
        check(WindowTitleValidator.validate(evidence, text: ambiguous, width: 2560, height: 1440).confidence == 5,
              "Multiple plausible caption candidates = 5")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("title-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.db").path
        let database = DatabaseManager(databasePath: path, storageRootPath: directory.path)
        do {
            try await database.initialize()
            let now = Date()
            let segment = try await database.insertSegment(bundleID: "dev.bb.desktop", startDate: now,
                endDate: now, windowName: observation.title, browserUrl: nil, type: 0)
            func frame(_ segment: Int64, evidence: WindowTitleEvidence?, offset: TimeInterval = 0) -> FrameReference {
                FrameReference(id: FrameID(value: 0), timestamp: now.addingTimeInterval(offset), segmentID: AppSegmentID(value: segment),
                    frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "dev.bb.desktop", windowTitleEvidence: evidence))
            }
            let first = FrameID(value: try await database.insertFrame(frame(segment, evidence: evidence)))
            try await database.updateFrameMetadata(frameID: first, metadataJSON: "{\"urls\":[]}")
            try await database.updateFrameMetadata(frameID: first, metadataJSON: nil)
            let loaded = try await database.getWindowTitleEvidence(frameID: first)
            check(loaded == evidence, "Evidence must survive independent URL metadata writes")
            let pending = try await database.getFrame(id: first)
            check(pending?.metadata.windowName == observation.title && pending?.metadata.windowTitleConfidence == 0, "Pending frame retains captured title at score 0")
            try await database.resolveWindowTitle(frameID: first, title: observation.title, confidence: 10, outcome: "exact")
            let verified = try await database.getFrame(id: first)
            check(verified?.metadata.windowName == observation.title, "Confirmed title must appear in normal reads")
            let second = FrameID(value: try await database.insertFrame(frame(segment, evidence: evidence, offset: 2)))
            try await database.resolveWindowTitle(frameID: first, title: "Plan full Limitless data export", confidence: 7, outcome: "ocr_recovered")
            let recovered = try await database.getFrame(id: first)
            let neighbour = try await database.getFrame(id: second)
            check(recovered?.metadata.windowName == "Plan full Limitless data export", "Recovery changes only this frame")
            check(neighbour?.metadata.windowName == observation.title, "Neighbour retains captured title")
            let storedSegment = try await database.getSegment(id: segment)
            check(storedSegment?.windowName == observation.title, "Validation must never rename shared segment")
            let otherSegment = try await database.insertSegment(bundleID: "dev.bb.desktop", startDate: now,
                endDate: now, windowName: "Legacy title", browserUrl: nil, type: 0)
            let legacy = FrameID(value: try await database.insertFrame(frame(otherSegment, evidence: nil, offset: 4)))
            let legacyEvidence = try await database.getWindowTitleEvidence(frameID: legacy)
            check(legacyEvidence == nil, "Legacy frames have no new evidence")
            // Real application read paths: shared segment, independent frame confidence, SQL filters.
            var raw: OpaquePointer?
            check(sqlite3_open(path, &raw) == SQLITE_OK, "Open fixture connection")
            check(sqlite3_exec(raw, "UPDATE frame SET windowTitleConfidence=11;", nil, nil, nil) != SQLITE_OK, "Reject out-of-range confidence")
            check(sqlite3_exec(raw, "UPDATE frame SET windowTitleConfidence=5.5;", nil, nil, nil) != SQLITE_OK, "Reject non-integer confidence")
            let connection = SQLiteConnection(db: raw)
            let pool = SQLiteReadConnectionPool(label: "title-checks", sharedConnection: connection)
            let adapter = DataAdapter(retraceConnection: connection, retraceReadConnectionPool: pool,
                retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: directory.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: directory.path), database: database)
            try await adapter.initialize()
            // Frame visibility normally changes after video encoding; mark fixture rows readable.
            check(sqlite3_exec(raw, "UPDATE frame SET processingStatus=2;", nil, nil, nil) == SQLITE_OK, "Mark readable")
            let unfiltered = try await adapter.getMostRecentFrames()
            check(unfiltered.count == 3, "All retained screenshots stay in unfiltered timeline")
            let lowOnly = try await adapter.getMostRecentFrames(filters: FilterCriteria(windowNameFilter: "Limitless"))
            check(lowOnly.isEmpty, "Score 7 cannot match a title filter")
            try await database.resolveWindowTitle(frameID: second, title: "Plan full Limitless data export", confidence: 9, outcome: "spelling")
            let highOnly = try await adapter.getMostRecentFrames(filters: FilterCriteria(windowNameFilter: "Limitless"))
            check(highOnly.map(\.id) == [second], "Only score >=9 appears in title-filtered timeline")
            let beforeFrames = try await adapter.getFramesBefore(timestamp: now.addingTimeInterval(10))
            let afterFrames = try await adapter.getFramesAfter(timestamp: now.addingTimeInterval(-1))
            check(beforeFrames.count == 3 && afterFrames.count == 3, "Unfiltered before/after queries retain resolved-title columns")
            let range = try await adapter.getFrames(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(10),
                filters: FilterCriteria(windowNameFilter: "Limitless"))
            check(range.map(\.id) == [second], "Range title filter also enforces confidence")
            // Real FTS: lower-confidence metadata must not create title-only hits;
            // OCR content is still searchable on those same frames.
            for frameID in [first, second] {
                _ = try await database.indexFrameText(mainText: "recorded OCR body", chromeText: nil,
                    windowTitle: "Limitless", segmentId: segment, frameId: frameID.value)
            }
            for mode in [SearchMode.all, .relevant] {
                let results = try await adapter.search(query: SearchQuery(text: "recorded",
                    filters: SearchFilters(windowNameFilter: "Limitless"), mode: mode))
                check(results.results.count == 1 && results.results.first?.id == second,
                      "Search mode must enforce title confidence")
            }
            let fts = FTSManager(databasePath: path)
            try await fts.initialize()
            let metadataHits = try await fts.search(query: "Limitless", limit: 20, offset: 0)
            check(metadataHits.count == 1 && metadataHits.first?.frameID == second, "FTS metadata-only hits require confidence >=9")
            let metadataCount = try await fts.getMatchCount(query: "Limitless", filters: .none)
            check(metadataCount == 1, "FTS count and results must use the same confidence policy")
            let bodyHits = try await fts.search(query: "recorded", limit: 20, offset: 0)
            check(bodyHits.count == 2, "Low-confidence title does not suppress OCR content hits")
            try await fts.close()
            let usage = try await database.getWindowUsageForApp(bundleID: "dev.bb.desktop", from: now.addingTimeInterval(-1), to: now.addingTimeInterval(10))
            check(usage.count == 1 && usage[0].windowName == "Plan full Limitless data export" && abs(usage[0].duration - 2) < 0.001, "Low-confidence interval must not stretch neighbouring title duration")
            let appUsage = try await database.getAppUsageStats(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(10))
            check(appUsage.count == 1 && abs(appUsage[0].duration - 4) < 0.001, "App usage must retain all intervals")
            _ = try await database.getBrowserTabUsage(bundleID: "com.google.Chrome", from: now.addingTimeInterval(-1), to: now.addingTimeInterval(10))
            await pool.close()
            sqlite3_close(raw)
            try await database.close()
            // Reopen to verify durable evidence and migration idempotency.
            try await database.initialize()
            let persisted = try await database.getWindowTitleEvidence(frameID: first)
            check(persisted == evidence, "Evidence must survive restart")
            try await database.close()
            var upgrade: OpaquePointer?
            check(sqlite3_open(path, &upgrade) == SQLITE_OK, "Open upgrade fixture")
            let downgrade = "ALTER TABLE frame DROP COLUMN resolvedWindowTitle; ALTER TABLE frame DROP COLUMN windowTitleConfidence; ALTER TABLE frame DROP COLUMN windowTitleValidationOutcome; DELETE FROM schema_migrations WHERE version=22;"
            check(sqlite3_exec(upgrade, downgrade, nil, nil, nil) == SQLITE_OK, "Reconstruct real V21 library")
            sqlite3_close(upgrade)
            try await database.initialize()
            let upgradedLegacy = try await database.getFrame(id: legacy)
            check(upgradedLegacy?.metadata.windowName == "Legacy title", "Migration preserves historical titles")
            check(upgradedLegacy?.metadata.windowTitleConfidence == 0, "Migration does not invent historical confidence")
            let preservedEvidence = try await database.getWindowTitleEvidence(frameID: first)
            check(preservedEvidence == evidence, "V22 preserves original boundary evidence")
            try await database.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        if CommandLine.arguments.dropFirst().first == "--live" {
            try await liveProbe()
        } else if CommandLine.arguments.count > 1 {
            try replay(path: CommandLine.arguments[1])
        }
        print("PASS: confidence cases, recorded OCR, real SQLite evidence, persistence, shared segments, and application timeline filters")
    }
    static func liveProbe() async throws {
        let capture = CGWindowListCapture()
        try await capture.startCapture(config: CaptureConfig(), displayID: CGMainDisplayID())
        let started = ProcessInfo.processInfo.systemUptime
        let candidate = await capture.captureCandidate(displayID: CGMainDisplayID())
        try await capture.stopCapture()
        guard let candidate else { fatalError("Live capture unavailable; check current privacy/permission state") }
        precondition(candidate.metadata.windowTitleConfidence == nil, "Live capture must not assert confidence before OCR")
        precondition(ProcessInfo.processInfo.systemUptime - started >= 0.15, "Post-image boundary wait was skipped")
        print("LIVE_CAPTURE pendingConfidence=true evidence=\(candidate.metadata.windowTitleEvidence != nil) beforeRegion=\(candidate.metadata.windowTitleEvidence?.before?.titleRegion != nil) afterRegion=\(candidate.metadata.windowTitleEvidence?.after?.titleRegion != nil)")
    }

    static func replay(path: String) throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        var outcomes: [String: Int] = [:]
        var acceptedWrong = 0
        for row in rows {
            func observation(_ key: String) -> WindowTitleObservation? {
                guard let a = row[key] as? [String: Any], let title = a["windowTitle"] as? String,
                      let b = a["windowBounds"] as? [Double], let pid = a["pid"] as? Int32,
                      let id = a["windowID"] as? UInt32 else { return nil }
                return WindowTitleObservation(pid: pid, windowID: id,
                    bounds: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), title: title,
                    titleRegion: CGRect(x: (b[0] + 80) / 2560, y: b[1] / 1440,
                                        width: (b[2] - 160) / 2560, height: 32.0 / 1440))
            }
            let id = FrameID(value: 1)
            let regions = (row["lines"] as! [[String: Any]]).map { line in
                TextRegion(frameID: id, text: line["text"] as! String,
                    bounds: CGRect(x: (line["x"] as! Double) * 2560, y: (line["y"] as! Double) * 1440,
                                   width: (line["width"] as! Double) * 2560, height: (line["height"] as! Double) * 1440))
            }
            let result = WindowTitleValidator.validate(.init(before: observation("before"), after: observation("after")),
                text: ExtractedText(frameID: id, timestamp: Date(), regions: regions), width: 2560, height: 1440)
            outcomes[result.outcome, default: 0] += 1
            if result.confidence >= 9, let title = result.title, WindowTitleWords.tokens(title) != WindowTitleWords.tokens(row["gold"] as! String) {
                acceptedWrong += 1
            }
        }
        print("REAL_BB_REPLAY samples=\(rows.count) outcomes=\(outcomes) wrongAccepted=\(acceptedWrong)")
        precondition(acceptedWrong == 0, "Production validator accepted an incorrect real BB title")
        precondition(!outcomes.isEmpty, "Replay did not exercise verified attribution")
    }

}
