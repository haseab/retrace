import Foundation
import XCTest
@testable import Retrace

final class ProcessUsageLogCleanupTests: XCTestCase {
    func testRemovesLargeLegacyLogWithoutChangingTallyOrRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = logs.appendingPathComponent("cpu_process_usage.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        // Reproduce the reported logical size with a sparse file, not 25.6 GB of writes.
        try handle.truncate(atOffset: 25_600_000_000)
        try handle.close()
        XCTAssertEqual(try log.resourceValues(forKeys: [.fileSizeKey]).fileSize, 25_600_000_000)

        let preservedFiles = [
            logs.appendingPathComponent("cpu_process_usage_tally.json"),
            logs.appendingPathComponent("cpu_process_groups.json"),
            logs.appendingPathComponent("other.log"),
            root.appendingPathComponent("recording.mp4"),
            root.appendingPathComponent("retrace.db")
        ]
        let contents = Data("preserve this data".utf8)
        for file in preservedFiles {
            try contents.write(to: file)
        }

        try ProcessUsageLogCleanup.removeLegacyLog(storageRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        for file in preservedFiles {
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
        // Repeated launches must also succeed after cleanup.
        XCTAssertNoThrow(try ProcessUsageLogCleanup.removeLegacyLog(storageRoot: root))
    }

    func testMissingStorageDoesNotCreateLogOrDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNoThrow(try ProcessUsageLogCleanup.removeLegacyLog(storageRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
