import Foundation
import Shared

/// Write-Ahead Log Manager for crash-safe frame persistence
///
/// Writes raw captured frames to disk before video encoding, ensuring:
/// - No data loss on crash/termination
/// - Fast sequential writes (raw BGRA pixels)
/// - Recovery on app restart
///
/// Directory structure:
/// ~/Library/Application Support/Retrace/wal/
///   └── active_segment_{videoID}/
///       ├── frames.bin      # Binary: [FrameHeader|PixelData][FrameHeader|PixelData]...
///       └── metadata.json   # Segment metadata (videoID, startTime, frameCount)
public actor WALManager {
    private let walRootURL: URL

    public init(walRoot: URL) {
        self.walRootURL = walRoot
    }

    public func initialize() async throws {
        // Create WAL root directory if needed
        if !FileManager.default.fileExists(atPath: walRootURL.path) {
            try FileManager.default.createDirectory(
                at: walRootURL,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Write Operations

    /// Create a new WAL session for a video segment
    public func createSession(videoID: VideoSegmentID) async throws -> WALSession {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")

        // Create session directory
        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true
        )

        // Create empty frames.bin file
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        FileManager.default.createFile(atPath: framesURL.path, contents: nil)

        // Create metadata file
        let metadata = WALMetadata(
            videoID: videoID,
            startTime: Date(),
            frameCount: 0,
            width: 0,
            height: 0
        )
        try saveMetadata(metadata, to: sessionDir)

        return WALSession(
            videoID: videoID,
            sessionDir: sessionDir,
            framesURL: framesURL,
            metadata: metadata
        )
    }

    /// Append a frame to the WAL
    public func appendFrame(_ frame: CapturedFrame, to session: inout WALSession) async throws {
        // Open file handle for appending
        guard let fileHandle = FileHandle(forWritingAtPath: session.framesURL.path) else {
            throw StorageError.fileWriteFailed(
                path: session.framesURL.path,
                underlying: "Cannot open file for appending"
            )
        }
        defer { try? fileHandle.close() }

        // Seek to end
        if #available(macOS 10.15.4, *) {
            try fileHandle.seekToEnd()
        } else {
            fileHandle.seekToEndOfFile()
        }

        // Write frame header + pixel data
        let header = WALFrameHeader(
            timestamp: frame.timestamp.timeIntervalSince1970,
            width: UInt32(frame.width),
            height: UInt32(frame.height),
            bytesPerRow: UInt32(frame.bytesPerRow),
            dataSize: UInt32(frame.imageData.count),
            displayID: frame.metadata.displayID,
            appBundleIDLength: UInt16(frame.metadata.appBundleID?.utf8.count ?? 0),
            appNameLength: UInt16(frame.metadata.appName?.utf8.count ?? 0),
            windowNameLength: UInt16(frame.metadata.windowName?.utf8.count ?? 0),
            browserURLLength: UInt16(frame.metadata.browserURL?.utf8.count ?? 0)
        )

        // Write header
        var headerData = Data()
        withUnsafeBytes(of: header.timestamp) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.width) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.height) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.bytesPerRow) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.dataSize) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.displayID) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.appBundleIDLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.appNameLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.windowNameLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.browserURLLength) { headerData.append(contentsOf: $0) }

        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: headerData)
        } else {
            fileHandle.write(headerData)
        }

        // Write metadata strings
        if let appBundleID = frame.metadata.appBundleID?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: appBundleID)
            } else {
                fileHandle.write(appBundleID)
            }
        }
        if let appName = frame.metadata.appName?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: appName)
            } else {
                fileHandle.write(appName)
            }
        }
        if let windowName = frame.metadata.windowName?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: windowName)
            } else {
                fileHandle.write(windowName)
            }
        }
        if let browserURL = frame.metadata.browserURL?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: browserURL)
            } else {
                fileHandle.write(browserURL)
            }
        }

        // Write pixel data
        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: frame.imageData)
        } else {
            fileHandle.write(frame.imageData)
        }

        // Update session metadata
        session.metadata.frameCount += 1
        if session.metadata.width == 0 {
            session.metadata.width = frame.width
            session.metadata.height = frame.height
        }

        try saveMetadata(session.metadata, to: session.sessionDir)
    }

    /// Finalize a WAL session (after successful video encoding)
    public func finalizeSession(_ session: WALSession) async throws {
        // Delete the WAL directory - video is now safely encoded
        try FileManager.default.removeItem(at: session.sessionDir)
    }

    // MARK: - Recovery Operations

    /// List all active WAL sessions (for crash recovery)
    public func listActiveSessions() async throws -> [WALSession] {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: walRootURL,
            includingPropertiesForKeys: nil
        )

        var sessions: [WALSession] = []
        for dir in contents where dir.hasDirectoryPath {
            // Parse videoID from directory name: "active_segment_{videoID}"
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("active_segment_"),
                  let videoIDStr = dirName.split(separator: "_").last,
                  let videoIDValue = Int64(videoIDStr) else {
                continue
            }

            let framesURL = dir.appendingPathComponent("frames.bin")
            guard FileManager.default.fileExists(atPath: framesURL.path) else {
                continue
            }

            // Load metadata
            let metadata = try loadMetadata(from: dir)

            sessions.append(WALSession(
                videoID: VideoSegmentID(value: videoIDValue),
                sessionDir: dir,
                framesURL: framesURL,
                metadata: metadata
            ))
        }

        return sessions
    }

    /// Read all frames from a WAL session
    public func readFrames(from session: WALSession) async throws -> [CapturedFrame] {
        guard let fileHandle = FileHandle(forReadingAtPath: session.framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: session.framesURL.path,
                underlying: "Cannot open file for reading"
            )
        }
        defer { try? fileHandle.close() }

        var frames: [CapturedFrame] = []

        while true {
            // Read header
            let headerSize = 34 // 8+4+4+4+4+4+2+2+2+2
            guard let headerData = try? fileHandle.read(upToCount: headerSize),
                  headerData.count == headerSize else {
                break // End of file
            }

            let header = try parseFrameHeader(from: headerData)

            // Read metadata strings
            let appBundleID = try header.appBundleIDLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.appBundleIDLength))!, encoding: .utf8)
                : nil
            let appName = try header.appNameLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.appNameLength))!, encoding: .utf8)
                : nil
            let windowName = try header.windowNameLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.windowNameLength))!, encoding: .utf8)
                : nil
            let browserURL = try header.browserURLLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.browserURLLength))!, encoding: .utf8)
                : nil

            // Read pixel data
            guard let pixelData = try? fileHandle.read(upToCount: Int(header.dataSize)),
                  pixelData.count == Int(header.dataSize) else {
                throw StorageError.fileReadFailed(
                    path: session.framesURL.path,
                    underlying: "Incomplete frame data"
                )
            }

            let frame = CapturedFrame(
                timestamp: Date(timeIntervalSince1970: header.timestamp),
                imageData: pixelData,
                width: Int(header.width),
                height: Int(header.height),
                bytesPerRow: Int(header.bytesPerRow),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: browserURL,
                    displayID: header.displayID
                )
            )

            frames.append(frame)
        }

        return frames
    }

    // MARK: - Private Helpers

    private func saveMetadata(_ metadata: WALMetadata, to dir: URL) throws {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)
    }

    private func loadMetadata(from dir: URL) throws -> WALMetadata {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func parseFrameHeader(from data: Data) throws -> WALFrameHeader {
        var offset = 0

        func read<T>(_ type: T.Type) -> T {
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: type) }
            offset += MemoryLayout<T>.size
            return value
        }

        return WALFrameHeader(
            timestamp: read(Double.self),
            width: read(UInt32.self),
            height: read(UInt32.self),
            bytesPerRow: read(UInt32.self),
            dataSize: read(UInt32.self),
            displayID: read(UInt32.self),
            appBundleIDLength: read(UInt16.self),
            appNameLength: read(UInt16.self),
            windowNameLength: read(UInt16.self),
            browserURLLength: read(UInt16.self)
        )
    }
}

// MARK: - Models

/// WAL session representing an active segment being recorded
public struct WALSession: Sendable {
    public let videoID: VideoSegmentID
    public let sessionDir: URL
    public let framesURL: URL
    public var metadata: WALMetadata

    public init(videoID: VideoSegmentID, sessionDir: URL, framesURL: URL, metadata: WALMetadata) {
        self.videoID = videoID
        self.sessionDir = sessionDir
        self.framesURL = framesURL
        self.metadata = metadata
    }
}

/// Metadata for a WAL session
public struct WALMetadata: Codable, Sendable {
    public let videoID: VideoSegmentID
    public let startTime: Date
    public var frameCount: Int
    public var width: Int
    public var height: Int

    public init(videoID: VideoSegmentID, startTime: Date, frameCount: Int, width: Int, height: Int) {
        self.videoID = videoID
        self.startTime = startTime
        self.frameCount = frameCount
        self.width = width
        self.height = height
    }
}

/// Frame header in WAL binary format (34 bytes fixed size + variable metadata strings)
private struct WALFrameHeader {
    let timestamp: Double           // 8 bytes - Unix timestamp
    let width: UInt32              // 4 bytes
    let height: UInt32             // 4 bytes
    let bytesPerRow: UInt32        // 4 bytes
    let dataSize: UInt32           // 4 bytes - pixel data size
    let displayID: UInt32          // 4 bytes
    let appBundleIDLength: UInt16  // 2 bytes
    let appNameLength: UInt16      // 2 bytes
    let windowNameLength: UInt16   // 2 bytes
    let browserURLLength: UInt16   // 2 bytes
    // Total: 34 bytes
    // Followed by: appBundleID, appName, windowName, browserURL (UTF-8 strings)
    // Followed by: pixel data (dataSize bytes)
}
