import AppKit
import Foundation
import Darwin

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

    private static let maximumPayloadBytes = 32_768

    private static func validateID(_ id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else {
            throw CLIImageExportTransportError.invalidRequest
        }
    }

    private static func validateRequest(_ request: CLIImageExportRequest) throws {
        try validateID(request.requestID)
        let age = Date().timeIntervalSince(request.createdAt)
        guard request.frameID > 0, request.outputPath.hasPrefix("/"),
              !request.outputPath.contains("\u{0}"), age >= -10, age < 60 else {
            throw CLIImageExportTransportError.invalidRequest
        }
    }

    // Both IPC directories belong to this user and must never be symlinks.
    private static func prepareDirectory() throws {
        for directory in [ipcDirectoryURL.deletingLastPathComponent(), ipcDirectoryURL] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
                throw CLIImageExportTransportError.invalidRequest
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFDIR else {
                throw CLIImageExportTransportError.invalidRequest
            }
            guard chmod(directory.path, 0o700) == 0 else {
                throw CLIImageExportTransportError.invalidRequest
            }
        }
    }

    private static func readPayload(at url: URL) throws -> Data {
        try prepareDirectory()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLIImageExportTransportError.invalidRequest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumPayloadBytes else {
            throw CLIImageExportTransportError.invalidRequest
        }
        let data = try handle.read(upToCount: maximumPayloadBytes + 1) ?? Data()
        guard data.count <= maximumPayloadBytes else { throw CLIImageExportTransportError.invalidRequest }
        return data
    }

    private static func writePayload<T: Encodable>(_ payload: T, to url: URL) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        let data = try encoder.encode(payload)
        guard data.count <= maximumPayloadBytes else { throw CLIImageExportTransportError.invalidRequest }
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw CLIImageExportTransportError.invalidRequest }
    }

    public static func stageRequest(_ request: CLIImageExportRequest) throws -> URL {
        try validateRequest(request)
        let url = try requestFileURL(for: request.requestID)
        try writePayload(request, to: url)
        return url
    }

    public static func loadRequest(from requestURL: URL, expectedRequestID: String? = nil) throws -> CLIImageExportRequest {
        let id = String(requestURL.lastPathComponent.dropLast(".request.json".count))
        let expectedURL = try requestFileURL(for: id)
        guard requestURL.path == expectedURL.path, expectedRequestID == nil || expectedRequestID == id else {
            throw CLIImageExportTransportError.invalidRequest
        }
        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)
        let request = try decoder.decode(CLIImageExportRequest.self, from: readPayload(at: expectedURL))
        try validateRequest(request)
        guard request.requestID == id else { throw CLIImageExportTransportError.invalidRequest }
        return request
    }

    public static func writeResponse(_ response: CLIImageExportResponse) throws -> URL {
        let url = try responseFileURL(for: response.requestID)
        try writePayload(response, to: url)
        return url
    }

    public static func loadResponse(for requestID: String) throws -> CLIImageExportResponse {
        let url = try responseFileURL(for: requestID)
        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)
        let response = try decoder.decode(CLIImageExportResponse.self, from: readPayload(at: url))
        guard response.requestID == requestID else { throw CLIImageExportTransportError.invalidRequest }
        return response
    }

    public static func cleanup(requestID: String) {
        guard let requestURL = try? requestFileURL(for: requestID),
              let responseURL = try? responseFileURL(for: requestID),
              (try? prepareDirectory()) != nil else { return }
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: responseURL)
    }

    public static func postRequestNotification(requestID: String, requestURL: URL) {
        guard let expectedURL = try? requestFileURL(for: requestID), expectedURL == requestURL else { return }
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

    public static func requestFileURL(for requestID: String) throws -> URL {
        try validateID(requestID)
        return ipcDirectoryURL.appendingPathComponent("\(requestID).request.json", isDirectory: false)
    }

    public static func responseFileURL(for requestID: String) throws -> URL {
        try validateID(requestID)
        return ipcDirectoryURL.appendingPathComponent("\(requestID).response.json", isDirectory: false)
    }

    private static var ipcDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("io.retrace.app", isDirectory: true)
            .appendingPathComponent("cli-image-export", isDirectory: true)
    }

    fileprivate static func awaitResponse(for requestID: String) async throws -> CLIImageExportResponse {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: responseTimeout)
        let responseURL = try responseFileURL(for: requestID)

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
    case invalidRequest
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
