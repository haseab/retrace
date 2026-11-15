import Foundation
import XCTest
import Shared
@testable import Database

final class WindowTitleAttributionTests: XCTestCase {
    func testEvidenceSurvivesURLMetadataUpdatesAndCannotRenameNeighbourFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: directory.appendingPathComponent("test.db").path,
                                 storageRootPath: directory.path)
        do {
            try await db.initialize()
            let now = Date()
            let observation = WindowTitleObservation(pid: 31234, windowID: 3933,
                bounds: CGRect(x: 0, y: 30, width: 2560, height: 1410),
                title: "Agents - Plan full Limitless data export", titleRegion: CGRect(x: 0.2, y: 0.02, width: 0.7, height: 0.025))
            let evidence = WindowTitleEvidence(before: observation, after: observation)
            let segment = try await db.insertSegment(bundleID: "dev.bb.desktop", startDate: now,
                endDate: now, windowName: nil, browserUrl: nil, type: 0)
            func frame() -> FrameReference {
                FrameReference(id: FrameID(value: 0), timestamp: now, segmentID: AppSegmentID(value: segment),
                    frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "dev.bb.desktop", windowTitleEvidence: evidence))
            }
            let first = FrameID(value: try await db.insertFrame(frame()))
            try await db.updateFrameMetadata(frameID: first, metadataJSON: "{\"urls\":[]}")
            try await db.updateFrameMetadata(frameID: first, metadataJSON: nil)
            let loaded = try await db.getWindowTitleEvidence(frameID: first)
            XCTAssertEqual(loaded, evidence)
            try await db.resolveWindowTitle(frameID: first, title: observation.title, confidence: 10, outcome: "exact")
            let confirmed = try await db.getFrame(id: first)
            XCTAssertEqual(confirmed?.metadata.windowName, observation.title)
            let neighbour = FrameID(value: try await db.insertFrame(frame()))
            try await db.resolveWindowTitle(frameID: first, title: "Corrected title", confidence: 7, outcome: "ocr_recovered")
            let neighbourFrame = try await db.getFrame(id: neighbour)
            XCTAssertNil(neighbourFrame?.metadata.windowName)
            let session = try await db.getSegment(id: segment)
            XCTAssertNil(session?.windowName)
            let unchanged = try await db.getFrame(id: first)
            XCTAssertEqual(unchanged?.metadata.windowName, "Corrected title")
            XCTAssertEqual(unchanged?.metadata.windowTitleConfidence, 7)
            try await db.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await db.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
