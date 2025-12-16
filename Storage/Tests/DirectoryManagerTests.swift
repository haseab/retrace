import Foundation
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                     DIRECTORY MANAGER TESTS                                  ║
// ║                                                                              ║
// ║  • Verify base directories are created (segments, temp)                      ║
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
        let segments = root.appendingPathComponent("segments").path
        let temp = root.appendingPathComponent("temp").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: segments))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp))
    }

    func testSegmentURLLayout() async throws {
        let date = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12))!
        let uuid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id = SegmentID(value: uuid)

        let url = try await directoryManager.segmentURL(for: id, date: date)
        XCTAssertTrue(url.path.contains("segments/2025/01/02"))
        XCTAssertEqual(url.lastPathComponent, "segment_\(uuid.uuidString)")
    }

    func testRelativePathFromRoot() async throws {
        let url = root.appendingPathComponent("segments/2025/01/02/foo.mp4")
        let rel = await directoryManager.relativePath(from: url)
        XCTAssertEqual(rel, "segments/2025/01/02/foo.mp4")
    }
}

