import AppKit
import AVFoundation
import Foundation
import Shared
import CoreMedia

/// Main StorageProtocol implementation.
public actor StorageManager: StorageProtocol {
    private var config: StorageConfig?
    private var storageRootURL: URL
    private let directoryManager: DirectoryManager
    private let encoderConfig: VideoEncoderConfig
    private let walManager: WALManager

    /// Counter to ensure unique segment IDs even if created within same millisecond
    private var segmentCounter: Int = 0

    /// Cache for decoded frames from B-frame videos, keyed by segment ID
    /// Each entry contains frames sorted by PTS (presentation order)
    private var frameCache: [Int64: FrameCacheEntry] = [:]

    /// Maximum number of segments to keep in cache
    private let maxCachedSegments = 3

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

    /// Entry in the frame cache containing decoded frames sorted by PTS
    private struct FrameCacheEntry {
        let segmentID: Int64
        var frames: [DecodedFrame]  // Sorted by PTS (presentation order)
        var lastAccessTime: Date
        let totalFrameCount: Int
    }

    /// A decoded frame with its presentation timestamp
    private struct DecodedFrame {
        let pts: CMTime
        let image: CGImage
        let presentationIndex: Int  // Index in presentation order (0, 1, 2, ...)
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
        // Add a counter to ensure uniqueness even if two writers are created in the same millisecond
        // This prevents race conditions between recovery and main pipeline
        let now = Date()
        segmentCounter += 1
        let baseID = Int64(now.timeIntervalSince1970 * 1000)
        let tempID = VideoSegmentID(value: baseID + Int64(segmentCounter % 1000))
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
        let segmentIDValue = segmentID.value

        // Check if we have this segment cached
        if let cacheEntry = frameCache[segmentIDValue] {
            // Update access time
            var updatedEntry = cacheEntry
            updatedEntry.lastAccessTime = Date()
            frameCache[segmentIDValue] = updatedEntry

            // Check if requested frame is in cache
            if frameIndex < cacheEntry.frames.count {
                let frame = cacheEntry.frames[frameIndex]
                let jpegData = try convertCGImageToJPEG(frame.image)
                Log.debug("[StorageManager] ✅ Cache hit: segmentID=\(segmentIDValue), frameIndex=\(frameIndex), pts=\(frame.pts.seconds)s", category: .storage)
                return jpegData
            }
        }

        // Not in cache - need to decode the video
        let segmentURL = try await getSegmentPath(id: segmentID)

        // Check if file is empty or too small to be a valid video
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            Log.warning("[StorageManager] Video file is empty (0 bytes), still being written: \(segmentURL.path)", category: .storage)
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Video file is empty (still being written)")
        }

        // Decode all frames from the video using AVAssetReader
        let frames = try await decodeAllFrames(from: segmentURL, segmentID: segmentIDValue)

        // Store in cache
        let cacheEntry = FrameCacheEntry(
            segmentID: segmentIDValue,
            frames: frames,
            lastAccessTime: Date(),
            totalFrameCount: frames.count
        )
        frameCache[segmentIDValue] = cacheEntry

        // Evict old cache entries if needed
        evictOldCacheEntries()

        // Return requested frame
        guard frameIndex < frames.count else {
            throw StorageError.fileReadFailed(
                path: segmentURL.path,
                underlying: "Frame index \(frameIndex) out of range (0..<\(frames.count))"
            )
        }

        let frame = frames[frameIndex]
        let jpegData = try convertCGImageToJPEG(frame.image)
        Log.debug("[StorageManager] ✅ Decoded and cached: segmentID=\(segmentIDValue), frameIndex=\(frameIndex)/\(frames.count), pts=\(String(format: "%.3f", frame.pts.seconds))s", category: .storage)

        return jpegData
    }

    /// Decode all frames from a video file using AVAssetReader, sorted by PTS (presentation order)
    private func decodeAllFrames(from url: URL, segmentID: Int64) async throws -> [DecodedFrame] {
        // Handle extensionless files by creating symlink
        let assetURL: URL
        if url.pathExtension.lowercased() == "mp4" {
            assetURL = url
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = url.lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4")

            if !FileManager.default.fileExists(atPath: symlinkPath.path) {
                try FileManager.default.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: url.path
                )
            }
            assetURL = symlinkPath
        }

        let asset = AVAsset(url: assetURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "No video track")
        }

        // Create asset reader
        let reader = try AVAssetReader(asset: asset)

        // Configure output to decompress frames
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "Cannot add track output to reader")
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            let errorDesc = reader.error?.localizedDescription ?? "Unknown error"
            throw StorageError.fileReadFailed(path: url.path, underlying: "Failed to start reading: \(errorDesc)")
        }

        // Read all frames with their PTS
        var framesWithPTS: [(pts: CMTime, image: CGImage)] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Convert CVPixelBuffer to CGImage
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                continue
            }

            framesWithPTS.append((pts: pts, image: cgImage))
        }

        // Check for read errors
        if reader.status == .failed {
            let errorDesc = reader.error?.localizedDescription ?? "Unknown error"
            throw StorageError.fileReadFailed(path: url.path, underlying: "Reader failed: \(errorDesc)")
        }

        // Sort by PTS to get presentation order
        framesWithPTS.sort { $0.pts.seconds < $1.pts.seconds }

        // Convert to DecodedFrame with presentation indices
        let decodedFrames = framesWithPTS.enumerated().map { index, frame in
            DecodedFrame(pts: frame.pts, image: frame.image, presentationIndex: index)
        }

        Log.info("[StorageManager] Decoded \(decodedFrames.count) frames from segment \(segmentID), sorted by PTS", category: .storage)

        // Log PTS sequence for debugging
        if decodedFrames.count > 0 {
            let firstPTS = decodedFrames.first!.pts.seconds
            let lastPTS = decodedFrames.last!.pts.seconds
            Log.debug("[StorageManager] PTS range: \(String(format: "%.3f", firstPTS))s - \(String(format: "%.3f", lastPTS))s", category: .storage)
        }

        return decodedFrames
    }

    /// Convert CGImage to JPEG data
    private func convertCGImageToJPEG(_ cgImage: CGImage) throws -> Data {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw StorageError.fileReadFailed(path: "", underlying: "Failed to convert CGImage to JPEG")
        }
        return jpegData
    }

    /// Evict oldest cache entries to keep memory usage bounded
    private func evictOldCacheEntries() {
        while frameCache.count > maxCachedSegments {
            // Find oldest entry
            let oldest = frameCache.min { $0.value.lastAccessTime < $1.value.lastAccessTime }
            if let oldestKey = oldest?.key {
                frameCache.removeValue(forKey: oldestKey)
                Log.debug("[StorageManager] Evicted cache entry for segment \(oldestKey)", category: .storage)
            }
        }
    }

    /// Clear the frame cache (useful when video files are modified)
    public func clearFrameCache() {
        frameCache.removeAll()
        Log.info("[StorageManager] Frame cache cleared", category: .storage)
    }

    /// Clear cache for a specific segment (call when segment is finalized or modified)
    public func clearFrameCache(for segmentID: VideoSegmentID) {
        frameCache.removeValue(forKey: segmentID.value)
        Log.debug("[StorageManager] Cleared cache for segment \(segmentID.value)", category: .storage)
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
