import Foundation
import XCTest
@testable import Storage

final class TemporaryVideoLinkTests: XCTestCase {
    func testExistingMP4IsNeverRemovedByLinkCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        try Data("video bytes".utf8).write(to: video)
        let link = try TemporaryVideoLink(source: video, directory: root.appendingPathComponent("unused"))
        link.cleanup()
        XCTAssertEqual(try Data(contentsOf: video), Data("video bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path))
    }

    func testScopedLinkIsRemovedOnSuccessAndFailureWithoutDeletingVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("extensionless-video")
        try Data("video bytes".utf8).write(to: video)
        var linkURL: URL!
        do {
            let link = try TemporaryVideoLink(source: video, directory: root.appendingPathComponent("links"))
            linkURL = link.url
            XCTAssertEqual(try Data(contentsOf: link.url), try Data(contentsOf: video))
            link.cleanup()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertThrowsError(try { () -> Void in
            let link = try TemporaryVideoLink(source: video, directory: root.appendingPathComponent("links"))
            linkURL = link.url
            defer { link.cleanup() }
            throw CocoaError(.fileReadCorruptFile)
        }())
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }
}
