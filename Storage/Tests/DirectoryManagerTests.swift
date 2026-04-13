import Foundation
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                     DIRECTORY MANAGER TESTS                                  ║
// ║                                                                              ║
// ║  • Verify base directories are created (chunks, temp)                        ║
// ║  • Verify segment URL layout for encrypted and plain files                   ║
// ║  • Verify relative path calculation from storage root                        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class DirectoryManagerTests: XCTestCase {

    private var root: URL!
    private var directoryManager: DirectoryManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceStorageTests_\(UUID().uuidString)", isDirectory: true)
        directoryManager = DirectoryManager(storageRoot: root)
        try await directoryManager.ensureBaseDirectories()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        directoryManager = nil
        try await super.tearDown()
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                      Directory Management Tests                          │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testEnsureBaseDirectoriesCreatesExpectedFolders() async throws {
        let chunks = root.appendingPathComponent("chunks").path
        let temp = root.appendingPathComponent("temp").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunks))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp))
    }

    func testSegmentURLLayout() async throws {
        let date = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12))!
        let id = VideoSegmentID(value: 123456)

        let url = try await directoryManager.segmentURL(for: id, date: date)
        XCTAssertTrue(url.path.contains("chunks/202501/02"))
        XCTAssertEqual(url.lastPathComponent, id.stringValue)
    }

    func testRelativePathFromRoot() async throws {
        let url = root.appendingPathComponent("chunks/202501/02/foo.mp4")
        let rel = await directoryManager.relativePath(from: url)
        XCTAssertEqual(rel, "chunks/202501/02/foo.mp4")
    }
}
