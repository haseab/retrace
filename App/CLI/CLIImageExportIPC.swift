import AppKit
import Foundation

public struct CLIImageExportRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let frameID: Int64
    public let outputPath: String
    public let overwrite: Bool
    public let createdAt: Date

    public init(
        requestID: String = UUID().uuidString,
        frameID: Int64,
        outputPath: String,
        overwrite: Bool,
        createdAt: Date = Date()
    ) {
        self.requestID = requestID
        self.frameID = frameID
        self.outputPath = outputPath
        self.overwrite = overwrite
        self.createdAt = createdAt
    }
}

public struct CLIImageExportResponse: Codable, Sendable, Equatable {
    public let requestID: String
    public let outputPath: String
    public let byteCount: Int?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        requestID: String,
        outputPath: String,
        byteCount: Int?,
        errorMessage: String?,
        completedAt: Date = Date()
    ) {
        self.requestID = requestID
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }

    public var succeeded: Bool {
        errorMessage == nil
    }
}

public enum CLIImageExportIPC {
    public static let appBundleIdentifier = "io.retrace.app"
    public static let requestNotification = Notification.Name("io.retrace.app.cliImageExportRequested")

    private static let requestPathUserInfoKey = "requestPath"
    private static let requestIDUserInfoKey = "requestID"
    private static let responsePollInterval: Duration = .milliseconds(100)
    private static let responseTimeout: Duration = .seconds(30)

    public static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).isEmpty
    }

    public static func stageRequest(_ request: CLIImageExportRequest) throws -> URL {
        let requestURL = requestFileURL(for: request.requestID)
        try FileManager.default.createDirectory(at: ipcDirectoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        let data = try encoder.encode(request)
        try data.write(to: requestURL, options: .atomic)
        return requestURL
    }

    public static func loadRequest(from requestURL: URL) throws -> CLIImageExportRequest {
        let data = try Data(contentsOf: requestURL)
        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)
        return try decoder.decode(CLIImageExportRequest.self, from: data)
    }

    public static func writeResponse(_ response: CLIImageExportResponse) throws -> URL {
        let responseURL = responseFileURL(for: response.requestID)
        try FileManager.default.createDirectory(at: ipcDirectoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        let data = try encoder.encode(response)
        try data.write(to: responseURL, options: .atomic)
        return responseURL
    }

    public static func loadResponse(for requestID: String) throws -> CLIImageExportResponse {
        let data = try Data(contentsOf: responseFileURL(for: requestID))
        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)
        return try decoder.decode(CLIImageExportResponse.self, from: data)
    }

    public static func cleanup(requestID: String) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: requestFileURL(for: requestID))
        try? fileManager.removeItem(at: responseFileURL(for: requestID))
    }

    public static func postRequestNotification(requestID: String, requestURL: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            requestNotification,
            object: nil,
            userInfo: [
                requestIDUserInfoKey: requestID,
                requestPathUserInfoKey: requestURL.path
            ],
            deliverImmediately: true
        )
    }

    public static func requestPath(from notification: Notification) -> String? {
        notification.userInfo?[requestPathUserInfoKey] as? String
    }

    public static func requestID(from notification: Notification) -> String? {
        notification.userInfo?[requestIDUserInfoKey] as? String
    }

    public static func requestFileURL(for requestID: String) -> URL {
        ipcDirectoryURL.appendingPathComponent("\(requestID).request.json", isDirectory: false)
    }

    public static func responseFileURL(for requestID: String) -> URL {
        ipcDirectoryURL.appendingPathComponent("\(requestID).response.json", isDirectory: false)
    }

    private static var ipcDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("io.retrace.app", isDirectory: true)
            .appendingPathComponent("cli-image-export", isDirectory: true)
    }

    fileprivate static func awaitResponse(for requestID: String) async throws -> CLIImageExportResponse {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: responseTimeout)
        let responseURL = responseFileURL(for: requestID)

        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                return try loadResponse(for: requestID)
            }

            try await Task.sleep(for: responsePollInterval, clock: .continuous)
        }

        throw CLIImageExportTransportError.timeout(requestID)
    }
}

enum CLIImageExportTransportError: Error, Sendable, Equatable {
    case timeout(String)
}

protocol CLIImageExportHosting: Sendable {
    func isAppRunning() -> Bool
    func exportImage(
        frameID: Int64,
        outputPath: String,
        overwrite: Bool
    ) async throws -> CLIImageExportResponse
}

struct AppHostedCLIImageExportHost: CLIImageExportHosting {
    func isAppRunning() -> Bool {
        CLIImageExportIPC.isAppRunning()
    }

    func exportImage(
        frameID: Int64,
        outputPath: String,
        overwrite: Bool
    ) async throws -> CLIImageExportResponse {
        let request = CLIImageExportRequest(
            frameID: frameID,
            outputPath: outputPath,
            overwrite: overwrite
        )
        let requestURL = try CLIImageExportIPC.stageRequest(request)

        do {
            CLIImageExportIPC.postRequestNotification(requestID: request.requestID, requestURL: requestURL)
            let response = try await CLIImageExportIPC.awaitResponse(for: request.requestID)
            CLIImageExportIPC.cleanup(requestID: request.requestID)
            return response
        } catch {
            CLIImageExportIPC.cleanup(requestID: request.requestID)
            throw error
        }
    }
}
