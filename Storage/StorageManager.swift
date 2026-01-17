import AppKit
import AVFoundation
import Foundation
import Shared

/// Main StorageProtocol implementation.
public actor StorageManager: StorageProtocol {
    private var config: StorageConfig?
    private var storageRootURL: URL
    private let directoryManager: DirectoryManager
    private let encoderConfig: VideoEncoderConfig

    public init(
        storageRoot: URL = URL(fileURLWithPath: StorageConfig.default.expandedStorageRootPath, isDirectory: true),
        encoderConfig: VideoEncoderConfig = .default
    ) {
        self.storageRootURL = storageRoot
        self.directoryManager = DirectoryManager(storageRoot: storageRoot)
        self.encoderConfig = encoderConfig
    }

    public func initialize(config: StorageConfig) async throws {
        self.config = config
        let rootPath = config.expandedStorageRootPath
        storageRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        await directoryManager.updateRoot(storageRootURL)
        try await directoryManager.ensureBaseDirectories()
    }

    public func createSegmentWriter() async throws -> SegmentWriter {
        guard config != nil else {
            throw StorageError.directoryCreationFailed(path: "Storage not initialized")
        }

        // Generate a unique temporary ID based on current time (milliseconds since epoch)
        // This will be replaced with the real database ID after finalization
        let now = Date()
        let tempID = VideoSegmentID(value: Int64(now.timeIntervalSince1970 * 1000))
        let fileURL = try await directoryManager.segmentURL(for: tempID, date: now)
        let relative = await directoryManager.relativePath(from: fileURL)

        return try SegmentWriterImpl(
            segmentID: tempID,
            fileURL: fileURL,
            relativePath: relative,
            encoderConfig: encoderConfig
        )
    }

    public func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        Log.debug("[StorageManager] readFrame called: segmentID=\(segmentID.value), frameIndex=\(frameIndex)", category: .storage)

        // Get segment path - files are MP4 without extension (no decryption needed)
        let segmentURL = try await getSegmentPath(id: segmentID)

        // Create temporary symlink with .mp4 extension so AVFoundation can identify the file format
        // (Rewind-compatible storage: files don't have extensions)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = segmentURL.lastPathComponent
        let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4")

        // Create symlink if it doesn't exist
        if !FileManager.default.fileExists(atPath: symlinkPath.path) {
            do {
                try FileManager.default.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: segmentURL.path
                )
            } catch {
                throw StorageError.fileReadFailed(
                    path: segmentURL.path,
                    underlying: "Failed to create symlink: \(error.localizedDescription)"
                )
            }
        }

        // Load asset from symlink (with .mp4 extension for format detection)
        let asset = AVAsset(url: symlinkPath)

        // Verify video track exists
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "No video track")
        }

        // Videos are encoded at fixed 30 FPS
        // Frame N is at time N/30.0 seconds (frame 0 = 0s, frame 1 = 0.033s, etc.)
        let frameTimeSeconds = Double(frameIndex) / 30.0
        let time = CMTime(seconds: frameTimeSeconds, preferredTimescale: 600)

        Log.debug("[StorageManager] Extracting frame at time=\(frameTimeSeconds)s (frameIndex=\(frameIndex)) from \(segmentURL.lastPathComponent)", category: .storage)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var actualTime: CMTime = .zero
        let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)

        // Calculate what frame we actually got vs what we requested
        let actualSeconds = actualTime.seconds
        let actualFrameIndex = Int(round(actualSeconds * 30.0))

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Failed to convert frame")
        }

        Log.debug("[StorageManager] ✅ Extracted frame: requested=\(frameIndex), actual=\(actualFrameIndex) (time=\(String(format: "%.3f", actualSeconds))s), size=\(cgImage.width)x\(cgImage.height), jpegSize=\(jpegData.count) bytes", category: .storage)

        return jpegData
    }

    public func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        let files = try await directoryManager.listAllSegmentFiles()
        // CRITICAL: Use exact match, not substring! Files are named with Int64 ID (e.g., "1768624554519")
        // .contains() would match "8" in "1768624603374" - must use == for exact match
        if let match = files.first(where: { $0.lastPathComponent == id.stringValue }) {
            return match
        }
        throw StorageError.fileNotFound(path: id.stringValue)
    }

    public func deleteSegment(id: VideoSegmentID) async throws {
        let url = try await getSegmentPath(id: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StorageError.fileWriteFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    public func segmentExists(id: VideoSegmentID) async throws -> Bool {
        (try? await getSegmentPath(id: id)) != nil
    }


    public func getTotalStorageUsed() async throws -> Int64 {
        let files = try await directoryManager.listAllSegmentFiles()
        var total: Int64 = 0
        for url in files {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    public func getAvailableDiskSpace() async throws -> Int64 {
        try DiskSpaceMonitor.availableBytes(at: storageRootURL)
    }

    public func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] {
        let files = try await directoryManager.listAllSegmentFiles()
        var deleted: [VideoSegmentID] = []

        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modDate = values?.contentModificationDate ?? Date.distantFuture
            guard modDate < date else { continue }

            if let id = parseSegmentID(from: url) {
                deleted.append(id)
            }
            try? FileManager.default.removeItem(at: url)
        }

        return deleted
    }

    public func getStorageDirectory() -> URL {
        storageRootURL
    }

    // MARK: - Private helpers

    private func parseSegmentID(from url: URL) -> VideoSegmentID? {
        // Files are named with just the Int64 ID (e.g., "12345")
        let name = url.lastPathComponent
        guard let int64Value = Int64(name) else { return nil }
        return VideoSegmentID(value: int64Value)
    }
}
