import XCTest
@testable import App

final class CLIImageExportIPCTests: XCTestCase {
    func testStageAndLoadRequestRoundTrip() throws {
        let request = CLIImageExportRequest(
            requestID: UUID().uuidString,
            frameID: 12345,
            outputPath: "/tmp/retrace-frame.jpg",
            overwrite: true
        )

        let requestURL = try CLIImageExportIPC.stageRequest(request)
        defer { CLIImageExportIPC.cleanup(requestID: request.requestID) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let loadedRequest = try CLIImageExportIPC.loadRequest(from: requestURL)
        XCTAssertEqual(loadedRequest.requestID, request.requestID)
        XCTAssertEqual(loadedRequest.frameID, request.frameID)
        XCTAssertEqual(loadedRequest.outputPath, request.outputPath)
        XCTAssertEqual(loadedRequest.overwrite, request.overwrite)
        XCTAssertLessThan(abs(loadedRequest.createdAt.timeIntervalSince(request.createdAt)), 0.01)
    }

    func testWriteAndLoadResponseRoundTrip() throws {
        let response = CLIImageExportResponse(
            requestID: UUID().uuidString,
            outputPath: "/tmp/retrace-frame.jpg",
            byteCount: 4096,
            errorMessage: nil
        )

        let responseURL = try CLIImageExportIPC.writeResponse(response)
        defer { CLIImageExportIPC.cleanup(requestID: response.requestID) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let loadedResponse = try CLIImageExportIPC.loadResponse(for: response.requestID)
        XCTAssertEqual(loadedResponse.requestID, response.requestID)
        XCTAssertEqual(loadedResponse.outputPath, response.outputPath)
        XCTAssertEqual(loadedResponse.byteCount, response.byteCount)
        XCTAssertEqual(loadedResponse.errorMessage, response.errorMessage)
        XCTAssertLessThan(abs(loadedResponse.completedAt.timeIntervalSince(response.completedAt)), 0.01)
    }
    func testRejectsTraversalAndExternalRequestPaths() throws {
        let request = CLIImageExportRequest(requestID: "../../outside", frameID: 1, outputPath: "/tmp/test.jpg", overwrite: false)
        XCTAssertThrowsError(try CLIImageExportIPC.stageRequest(request))
        XCTAssertThrowsError(try CLIImageExportIPC.writeResponse(CLIImageExportResponse(requestID: request.requestID, outputPath: "", byteCount: nil, errorMessage: "test")))
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONEncoder().encode(request).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        XCTAssertThrowsError(try CLIImageExportIPC.loadRequest(from: external))
    }

    func testRejectsMismatchedNotificationAndStaleRequests() throws {
        let request = CLIImageExportRequest(frameID: 1, outputPath: "/tmp/test.jpg", overwrite: false)
        let url = try CLIImageExportIPC.stageRequest(request)
        defer { CLIImageExportIPC.cleanup(requestID: request.requestID) }
        XCTAssertThrowsError(try CLIImageExportIPC.loadRequest(from: url, expectedRequestID: UUID().uuidString))
        let stale = CLIImageExportRequest(frameID: 1, outputPath: "/tmp/test.jpg", overwrite: false, createdAt: Date().addingTimeInterval(-300))
        XCTAssertThrowsError(try CLIImageExportIPC.stageRequest(stale))
        XCTAssertThrowsError(try CLIImageExportIPC.stageRequest(CLIImageExportRequest(frameID: 1, outputPath: "relative.jpg", overwrite: false)))
    }

    func testRejectsSymlinkAndOversizedPayloads() throws {
        let request = CLIImageExportRequest(frameID: 1, outputPath: "/tmp/test.jpg", overwrite: false)
        let url = try CLIImageExportIPC.stageRequest(request)
        defer { CLIImageExportIPC.cleanup(requestID: request.requestID) }
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{}".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        XCTAssertThrowsError(try CLIImageExportIPC.loadRequest(from: url))
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 32, count: 32769).write(to: url)
        XCTAssertThrowsError(try CLIImageExportIPC.loadRequest(from: url))
    }

    func testRejectsPayloadIDsThatDoNotMatchTheirFiles() throws {
        let request = CLIImageExportRequest(frameID: 1, outputPath: "/tmp/test.jpg", overwrite: false)
        let url = try CLIImageExportIPC.stageRequest(request)
        defer { CLIImageExportIPC.cleanup(requestID: request.requestID) }
        let other = CLIImageExportRequest(frameID: 2, outputPath: "/tmp/test.jpg", overwrite: false)
        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        try encoder.encode(other).write(to: url)
        XCTAssertThrowsError(try CLIImageExportIPC.loadRequest(from: url))

        let responseURL = try CLIImageExportIPC.writeResponse(CLIImageExportResponse(requestID: request.requestID, outputPath: "/tmp/test.jpg", byteCount: 1, errorMessage: nil))
        try encoder.encode(CLIImageExportResponse(requestID: other.requestID, outputPath: "/tmp/test.jpg", byteCount: 1, errorMessage: nil)).write(to: responseURL)
        XCTAssertThrowsError(try CLIImageExportIPC.loadResponse(for: request.requestID))
    }

}
