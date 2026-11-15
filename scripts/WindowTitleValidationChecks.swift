import Foundation
import CoreGraphics
import SQLCipher
import Shared
import Database
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
        check(WindowTitleValidator.validate(evidence, text: text, width: 2560, height: 1440).title == nil,
              "Body/sidebar mentions must not confirm a wrong header")
        let correct = ExtractedText(frameID: id, timestamp: Date(), regions: [], chromeRegions: [
            TextRegion(frameID: id, text: "Valldate OCR output with accessibllity API",
                       bounds: CGRect(x: 716, y: 44, width: 400, height: 18))
        ])
        check(WindowTitleValidator.validate(evidence, text: correct, width: 2560, height: 1440).title == observation.title,
              "Existing chrome OCR must verify the title")
        check(WindowTitleValidator.validate(.init(before: observation, after: nil), text: correct,
                                           width: 2560, height: 1440).title == nil, "Missing AX stays unassigned")
        let changed = WindowTitleObservation(pid: 31234, windowID: 3933, bounds: observation.bounds,
                                            title: "Plan full Limitless data export", titleRegion: area)
        check(WindowTitleValidator.validate(.init(before: observation, after: changed), text: correct,
                                           width: 2560, height: 1440).title == nil, "Changed AX stays unassigned")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("title-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.db").path
        let database = DatabaseManager(databasePath: path, storageRootPath: directory.path)
        do {
            try await database.initialize()
            let now = Date()
            let segment = try await database.insertSegment(bundleID: "dev.bb.desktop", startDate: now,
                endDate: now, windowName: nil, browserUrl: nil, type: 0)
            func frame(_ segment: Int64, evidence: WindowTitleEvidence?) -> FrameReference {
                FrameReference(id: FrameID(value: 0), timestamp: now, segmentID: AppSegmentID(value: segment),
                    frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "dev.bb.desktop", windowTitleEvidence: evidence))
            }
            let first = FrameID(value: try await database.insertFrame(frame(segment, evidence: evidence)))
            try await database.updateFrameMetadata(frameID: first, metadataJSON: "{\"urls\":[]}")
            try await database.updateFrameMetadata(frameID: first, metadataJSON: nil)
            let loaded = try await database.getWindowTitleEvidence(frameID: first)
            check(loaded == evidence, "Evidence must survive independent URL metadata writes")
            let pending = try await database.getFrame(id: first)
            check(pending?.metadata.windowName == nil, "Pending frame must not expose a title")
            try await database.resolveWindowTitle(frameID: first, title: observation.title)
            let verified = try await database.getFrame(id: first)
            check(verified?.metadata.windowName == observation.title, "Confirmed title must appear in normal reads")
            _ = try await database.insertFrame(frame(segment, evidence: evidence))
            var refusedSharedSegment = false
            do { try await database.resolveWindowTitle(frameID: first, title: "Wrong neighbour") }
            catch { refusedSharedSegment = true }
            check(refusedSharedSegment, "Must refuse to rename a segment shared by other frames")
            let otherSegment = try await database.insertSegment(bundleID: "dev.bb.desktop", startDate: now,
                endDate: now, windowName: "Legacy title", browserUrl: nil, type: 0)
            let legacy = FrameID(value: try await database.insertFrame(frame(otherSegment, evidence: nil)))
            let legacyEvidence = try await database.getWindowTitleEvidence(frameID: legacy)
            check(legacyEvidence == nil, "Legacy frames have no new evidence")
            try await database.close()
            // Reopen to verify durable evidence and migration idempotency.
            try await database.initialize()
            let persisted = try await database.getWindowTitleEvidence(frameID: first)
            check(persisted == evidence, "Evidence must survive restart")
            try await database.close()
            // Reconstruct an actual V20 library, then run the production migration.
            var raw: OpaquePointer?
            guard sqlite3_open(path, &raw) == SQLITE_OK, let raw else { fatalError("Cannot open temporary fixture") }
            let upgradeSQL = "ALTER TABLE frame DROP COLUMN captureWindowTitleEvidence; DELETE FROM schema_migrations WHERE version=21;"
            let upgraded = sqlite3_exec(raw, upgradeSQL, nil, nil, nil)
            sqlite3_close(raw)
            check(upgraded == SQLITE_OK, "Could not reconstruct V20 library")
            try await database.initialize()
            let legacyAfterUpgrade = try await database.getFrame(id: legacy)
            check(legacyAfterUpgrade?.metadata.windowName == "Legacy title", "Migration must preserve historical titles")
            let oldEvidence = try await database.getWindowTitleEvidence(frameID: first)
            check(oldEvidence == nil, "Migration must not invent historical boundary evidence")
            let countAfterUpgrade = try await database.getFrameCount()
            check(countAfterUpgrade == 3, "Migration must preserve all frames")
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
        print("PASS: recorded OCR pairs, region selection, boundary guards, real SQLite evidence, persistence, V20 upgrade, and segment isolation")
    }
    static func liveProbe() async throws {
        let capture = CGWindowListCapture()
        try await capture.startCapture(config: .default, displayID: CGMainDisplayID())
        let started = ProcessInfo.processInfo.systemUptime
        let candidate = await capture.captureCandidate(displayID: CGMainDisplayID())
        try await capture.stopCapture()
        guard let candidate else { fatalError("Live capture unavailable; check current privacy/permission state") }
        precondition(candidate.metadata.windowName == nil, "Live capture must not assert an unverified title")
        precondition(ProcessInfo.processInfo.systemUptime - started >= 0.15, "Post-image boundary wait was skipped")
        print("LIVE_CAPTURE pendingTitle=true evidence=\(candidate.metadata.windowTitleEvidence != nil) beforeRegion=\(candidate.metadata.windowTitleEvidence?.before?.titleRegion != nil) afterRegion=\(candidate.metadata.windowTitleEvidence?.after?.titleRegion != nil)")
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
            if let title = result.title, WindowTitleWords.tokens(title) != WindowTitleWords.tokens(row["gold"] as! String) {
                acceptedWrong += 1
            }
        }
        print("REAL_BB_REPLAY samples=\(rows.count) outcomes=\(outcomes) wrongAccepted=\(acceptedWrong)")
        precondition(acceptedWrong == 0, "Production validator accepted an incorrect real BB title")
        precondition((outcomes["verified"] ?? 0) > 0, "Replay did not exercise verified attribution")
    }

}
