import Foundation
import XCTest
@testable import App

final class RetentionDeletionJournalTests: XCTestCase {
    func testUnavailableJournalPreventsDestructiveWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("video")
        try Data("retained".utf8).write(to: file)
        let journal = RetentionDeletionJournal(url: root.appendingPathComponent("missing/pending.json"))
        do {
            _ = try await journal.process(candidates: [7], deleteDatabase: { _ in
                try FileManager.default.removeItem(at: file)
                return true
            }, deleteFile: { _ in 0 })
            XCTFail("Missing journal directory must prevent deletion")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("retained".utf8))
    }

    func testDatabaseFailurePreservesFileAndJournalRetriesAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("video")
        try Data("recorded video".utf8).write(to: file)
        let journal = RetentionDeletionJournal(url: root.appendingPathComponent("pending.json"))
        let failed = try await journal.process(candidates: [7], deleteDatabase: { _ in
            throw CocoaError(.fileWriteUnknown)
        }, deleteFile: { _ in try FileManager.default.removeItem(at: file); return 14 })
        XCTAssertEqual(failed.deleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restarted = RetentionDeletionJournal(url: journal.url)
        let retried = try await restarted.process(candidates: [], deleteDatabase: { _ in true }, deleteFile: { _ in
            try FileManager.default.removeItem(at: file)
            return 14
        })
        XCTAssertEqual(retried.deleted, 1)
        XCTAssertEqual(retried.bytes, 14)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFileFailureRemainsPendingAndReferencedVideoIsNotDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = RetentionDeletionJournal(url: root.appendingPathComponent("pending.json"))
        let result = try await journal.process(candidates: [1, 2], deleteDatabase: { $0 != 1 }, deleteFile: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(result.deleted, 0)
        let pending = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: journal.url))
        XCTAssertEqual(pending, [2])
        let retried = try await journal.process(candidates: [], deleteDatabase: { _ in true }, deleteFile: { _ in 0 })
        XCTAssertEqual(retried.deleted, 1)
        XCTAssertEqual(try JSONDecoder().decode([Int64].self, from: Data(contentsOf: journal.url)), [])
    }
}
