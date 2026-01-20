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
    private let walManager: WALManager

    public init(
        storageRoot: URL = URL(fileURLWithPath: StorageConfig.default.expandedStorageRootPath, isDirectory: true),
        encoderConfig: VideoEncoderConfig = .default
    ) {
        self.storageRootURL = storageRoot
        self.directoryManager = DirectoryManager(storageRoot: storageRoot)
        self.encoderConfig = encoderConfig

        // Initialize WAL manager in wal/ subdirectory
        let walRoot = storageRoot.appendingPathComponent("wal", isDirectory: true)
        self.walManager = WALManager(walRoot: walRoot)
    }

    public func initialize(config: StorageConfig) async throws {
        self.config = config
        let rootPath = config.expandedStorageRootPath
        storageRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        await directoryManager.updateRoot(storageRootURL)
        try await directoryManager.ensureBaseDirectories()

        // Initialize WAL
        try await walManager.initialize()
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

        // Use IncrementalSegmentWriter with WAL support
        return try IncrementalSegmentWriter(
            segmentID: tempID,
            fileURL: fileURL,
            relativePath: relative,
            walManager: walManager,
            encoderConfig: encoderConfig
        )
    }

    /// Get WAL manager for recovery operations
    public func getWALManager() -> WALManager {
        return walManager
    }

    public func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {

        // Get segment path - files are MP4 without extension (no decryption needed)
        let segmentURL = try await getSegmentPath(id: segmentID)

        // Check if file is empty or too small to be a valid video
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            // File is empty - likely incomplete/interrupted write. Delete it and throw.
            Log.warning("[StorageManager] Video file is empty (0 bytes), deleting: \(segmentURL.path)", category: .storage)
            try? FileManager.default.removeItem(at: segmentURL)
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Video file is empty (incomplete write)")
        }

        // Determine the URL to use for AVFoundation
        // If file already has .mp4 extension, use it directly
        // Otherwise, create a temporary symlink with .mp4 extension so AVFoundation can identify the format
        let assetURL: URL
        if segmentURL.pathExtension.lowercased() == "mp4" {
            // File already has .mp4 extension, use directly
            assetURL = segmentURL
        } else {
            // Create temporary symlink with .mp4 extension (for extensionless files)
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
            assetURL = symlinkPath
        }

        // Load asset (with .mp4 extension for format detection)
        let asset = AVAsset(url: assetURL)

        // Verify video track exists
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "No video track")
        }

        // Videos are encoded at fixed 30 FPS
        // Use integer arithmetic to avoid floating point precision issues
        // At 30fps with timescale 600: each frame = 20 time units (600/30 = 20)
        let time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)

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
        // Support both extensionless files and files with .mp4 extension
        if let match = files.first(where: {
            $0.lastPathComponent == id.stringValue ||
            $0.lastPathComponent == "\(id.stringValue).mp4"
        }) {
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

    /// Rename a video segment file (used when temporary ID is replaced with database ID)
    public func renameSegment(from oldID: VideoSegmentID, to newID: VideoSegmentID, date: Date) async throws {
        // Find old file
        guard let oldURL = try? await getSegmentPath(id: oldID) else {
            throw StorageError.fileNotFound(path: oldID.stringValue)
        }

        // Generate new path with same date structure
        let newURL = try await directoryManager.segmentURL(for: newID, date: date)

        // Rename file
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            Log.debug("[StorageManager] Renamed video segment: \(oldID.stringValue) -> \(newID.stringValue)", category: .storage)
        } catch {
            throw StorageError.fileWriteFailed(path: newURL.path, underlying: error.localizedDescription)
        }
    }

    public func getTotalStorageUsed() async throws -> Int64 {
        // Calculate size of chunks/ folder and retrace.db only
        let chunksURL = storageRootURL.appendingPathComponent("chunks", isDirectory: true)
        let dbURL = storageRootURL.appendingPathComponent("retrace.db")

        Log.debug("[StorageManager] Calculating storage - root: \(storageRootURL.path)", category: .storage)
        Log.debug("[StorageManager] Chunks URL: \(chunksURL.path)", category: .storage)
        Log.debug("[StorageManager] DB URL: \(dbURL.path)", category: .storage)

        var totalSize: Int64 = 0
        let chunksSize = calculateFolderSize(at: chunksURL)
        totalSize += chunksSize
        Log.debug("[StorageManager] Chunks size: \(chunksSize) bytes (\(Double(chunksSize) / 1_000_000_000) GB)", category: .storage)

        // Add database file size (actual disk allocation)
        if let dbSize = try? dbURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
            totalSize += Int64(dbSize)
            Log.debug("[StorageManager] DB size: \(dbSize) bytes (\(Double(dbSize) / 1_000_000_000) GB)", category: .storage)
        } else {
            Log.debug("[StorageManager] Could not get DB size", category: .storage)
        }

        Log.debug("[StorageManager] Total storage: \(totalSize) bytes (\(Double(totalSize) / 1_000_000_000) GB)", category: .storage)
        return totalSize
    }

    /// Recursively calculate the total size of a folder in bytes (actual disk allocation)
    private func calculateFolderSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if resourceValues.isRegularFile == true, let fileSize = resourceValues.totalFileAllocatedSize {
                    totalSize += Int64(fileSize)
                }
            } catch {
                // Skip files we can't read
                continue
            }
        }

        return totalSize
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
        // Files are named with just the Int64 ID (e.g., "12345") or with .mp4 extension (e.g., "12345.mp4")
        var name = url.lastPathComponent
        // Strip .mp4 extension if present
        if name.hasSuffix(".mp4") {
            name = String(name.dropLast(4))
        }
        guard let int64Value = Int64(name) else { return nil }
        return VideoSegmentID(value: int64Value)
    }
}
