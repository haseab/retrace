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
}
