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

        // Generate a unique ID based on current time (milliseconds since epoch)
        // Add a counter to ensure uniqueness even if two writers are created in the same millisecond
        // This prevents race conditions between recovery and main pipeline
        let now = Date()
        segmentCounter += 1
        let baseID = Int64(now.timeIntervalSince1970 * 1000)
        let timestampID = VideoSegmentID(value: baseID + Int64(segmentCounter % 1000))
        let fileURL = try await directoryManager.segmentURL(for: timestampID, date: now)
        let relative = await directoryManager.relativePath(from: fileURL)

        // Use IncrementalSegmentWriter with WAL support
        return try IncrementalSegmentWriter(
            segmentID: timestampID,
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

    /// Clear all WAL sessions (used when changing database location)
    /// WARNING: This deletes unrecovered frame data!
    public func clearWALSessions() async throws {
        try await walManager.clearAllSessions()
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
                return jpegData
            }
        }

        // Not in cache - need to decode the video
        let segmentURL: URL
        do {
            segmentURL = try await getSegmentPath(id: segmentID)
        } catch {
            throw error
        }

        // Check if file exists
        let fileExists = FileManager.default.fileExists(atPath: segmentURL.path)
        if !fileExists {
            throw StorageError.fileNotFound(path: segmentURL.path)
        }

        // Check if file is empty or too small to be a valid video
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Video file is empty (still being written)")
        }

        // Decode all frames from the video using AVAssetReader
        let frames: [DecodedFrame]
        do {
            frames = try await decodeAllFrames(from: segmentURL, segmentID: segmentIDValue)
        } catch {
            throw error
        }

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
            // Frame not yet available in video file - this can happen with actively-written fragmented MP4s
            // where the database has more frame records than AVAssetReader can decode from the file.
            // Don't cache this incomplete result - clear cache so next read re-decodes.
            frameCache.removeValue(forKey: segmentIDValue)
            Log.warning("[StorageManager] Frame index \(frameIndex) out of range (0..<\(frames.count)) for segment \(segmentID.value) - video may still be writing, cache cleared", category: .storage)
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

    /// Read a frame from a video at a specific path (used for Rewind frames with string-based IDs)
    public func readFrameFromPath(videoPath: String, frameIndex: Int) async throws -> Data {

        // Use path hash as cache key since Rewind paths are strings not Int64
        let cacheKey = Int64(videoPath.hashValue)

        // Check if we have this segment cached
        if let cacheEntry = frameCache[cacheKey] {
            // Update access time
            var updatedEntry = cacheEntry
            updatedEntry.lastAccessTime = Date()
            frameCache[cacheKey] = updatedEntry

            // Check if requested frame is in cache
            if frameIndex < cacheEntry.frames.count {
                let frame = cacheEntry.frames[frameIndex]
                let jpegData = try convertCGImageToJPEG(frame.image)
                return jpegData
            }
        }

        // Check if file exists
        let fileExists = FileManager.default.fileExists(atPath: videoPath)
        if !fileExists {
            throw StorageError.fileNotFound(path: videoPath)
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            throw StorageError.fileReadFailed(path: videoPath, underlying: "Video file is empty")
        }

        // Decode all frames from the video
        let segmentURL = URL(fileURLWithPath: videoPath)
        let frames: [DecodedFrame]
        do {
            frames = try await decodeAllFrames(from: segmentURL, segmentID: cacheKey)
        } catch {
            throw error
        }

        // Store in cache
        let cacheEntry = FrameCacheEntry(
            segmentID: cacheKey,
            frames: frames,
            lastAccessTime: Date(),
            totalFrameCount: frames.count
        )
        frameCache[cacheKey] = cacheEntry

        // Evict old cache entries if needed
        evictOldCacheEntries()

        // Return requested frame
        guard frameIndex < frames.count else {
            frameCache.removeValue(forKey: cacheKey)
            Log.warning("[StorageManager] Frame index \(frameIndex) out of range (0..<\(frames.count)) for path \(videoPath)", category: .storage)
            throw StorageError.fileReadFailed(
                path: videoPath,
                underlying: "Frame index \(frameIndex) out of range (0..<\(frames.count))"
            )
        }

        let frame = frames[frameIndex]
        let jpegData = try convertCGImageToJPEG(frame.image)

        return jpegData
    }

    /// Decode all frames from a video file using AVAssetReader, sorted by PTS (presentation order)
    private func decodeAllFrames(from url: URL, segmentID: Int64) async throws -> [DecodedFrame] {

        // Handle extensionless files by creating symlink
        // Use UUID to avoid conflicts when multiple workers process same video
        // Note: We don't delete symlinks immediately as AVAsset may still need them
        let assetURL: URL
        if url.pathExtension.lowercased() == "mp4" {
            assetURL = url
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let symlinkPath = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")

            do {
                try FileManager.default.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: url.path
                )
            } catch {
                Log.error("[StorageManager] Failed to create symlink for segment \(segmentID): \(symlinkPath.path)", category: .storage, error: error)
                throw StorageError.fileWriteFailed(path: symlinkPath.path, underlying: error.localizedDescription)
            }
            assetURL = symlinkPath
        }

        let asset = AVAsset(url: assetURL)

        // Load asset duration (validates asset is readable)
        _ = try await asset.load(.duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "No video track")
        }

        // Log video track info for debugging
        let trackDuration = try await videoTrack.load(.timeRange)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let estimatedFrameCount = Int(trackDuration.duration.seconds * Double(nominalFrameRate))
        Log.debug("[StorageManager] Video track: trackDuration=\(String(format: "%.3f", trackDuration.duration.seconds))s, frameRate=\(nominalFrameRate), estimatedFrames=\(estimatedFrameCount)", category: .storage)

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
                Log.warning("[StorageManager] Skipping frame - no image buffer at PTS \(String(format: "%.3f", pts.seconds))s, segment \(segmentID)", category: .storage)
                continue
            }

            // Convert CVPixelBuffer to CGImage
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                Log.warning("[StorageManager] Failed to create CGImage at PTS \(String(format: "%.3f", pts.seconds))s, segment \(segmentID)", category: .storage)
                continue
            }

            framesWithPTS.append((pts: pts, image: cgImage))
        }

        // Check for read errors
        if reader.status == .failed {
            let errorDesc = reader.error?.localizedDescription ?? "Unknown error"
            Log.error("[StorageManager] AVAssetReader failed: \(errorDesc), segmentID=\(segmentID)", category: .storage)
            throw StorageError.fileReadFailed(path: url.path, underlying: "Reader failed: \(errorDesc)")
        }

        // Log actual frame count vs expected for debugging
        Log.debug("[StorageManager] Read \(framesWithPTS.count) frames from AVAssetReader, expected ~\(estimatedFrameCount)", category: .storage)

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

    /// Count the number of readable frames in an existing video file
    /// Returns 0 if the file doesn't exist or is unreadable
    public func countFramesInSegment(id: VideoSegmentID) async throws -> Int {
        guard let segmentURL = try? await getSegmentPath(id: id) else {
            return 0
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            return 0
        }

        // Handle extensionless files by creating symlink
        // Use UUID to avoid conflicts when multiple workers process same video
        let assetURL: URL
        if segmentURL.pathExtension.lowercased() == "mp4" {
            assetURL = segmentURL
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let symlinkPath = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")

            try FileManager.default.createSymbolicLink(
                atPath: symlinkPath.path,
                withDestinationPath: segmentURL.path
            )
            assetURL = symlinkPath
        }

        let asset = AVAsset(url: assetURL)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }

        // Create asset reader to count frames
        guard let reader = try? AVAssetReader(asset: asset) else {
            return 0
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            return 0
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            return 0
        }

        // Count frames without fully decoding them
        var frameCount = 0
        while trackOutput.copyNextSampleBuffer() != nil {
            frameCount += 1
        }

        return frameCount
    }

    /// Check if a video file has valid timestamps (first frame dts=0)
    /// Returns false if the video was not properly finalized (crash recovery case)
    public func isVideoValid(id: VideoSegmentID) async throws -> Bool {
        guard let segmentURL = try? await getSegmentPath(id: id) else {
            return false
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            return false
        }

        // Handle extensionless files by creating symlink
        // Use UUID to avoid conflicts when multiple workers process same video
        let assetURL: URL
        if segmentURL.pathExtension.lowercased() == "mp4" {
            assetURL = segmentURL
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let symlinkPath = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")

            try FileManager.default.createSymbolicLink(
                atPath: symlinkPath.path,
                withDestinationPath: segmentURL.path
            )
            assetURL = symlinkPath
        }

        let asset = AVAsset(url: assetURL)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return false
        }

        // Create asset reader to check first frame's timestamp
        guard let reader = try? AVAssetReader(asset: asset) else {
            return false
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            return false
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            return false
        }

        // Check first frame's presentation time
        guard let firstSample = trackOutput.copyNextSampleBuffer() else {
            return false
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(firstSample)

        // Valid videos start at pts=0 (or very close to it)
        // Crashed/unfinalized videos start at pts=20/600 or later
        return pts.value == 0
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

    public func getTotalStorageUsed(includeRewind: Bool = false) async throws -> Int64 {
        var totalSize: Int64 = 0
        var fileCount = 0

        // Retrace storage: chunks/ folder + retrace.db
        let retraceChunksURL = storageRootURL.appendingPathComponent("chunks", isDirectory: true)
        let retraceDbURL = storageRootURL.appendingPathComponent("retrace.db")
        let (retraceChunksSize, retraceFileCount) = calculateFolderSizeWithCount(at: retraceChunksURL)
        totalSize += retraceChunksSize
        fileCount += retraceFileCount

        if let dbSize = try? retraceDbURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
            totalSize += Int64(dbSize)
        }

        // Rewind storage: only include if enabled
        if includeRewind {
            let rewindURL = URL(fileURLWithPath: AppPaths.expandedRewindStorageRoot)
            let rewindChunksURL = rewindURL.appendingPathComponent("chunks", isDirectory: true)
            let rewindDbURL = rewindURL.appendingPathComponent("db-enc.sqlite3")
            let (rewindChunksSize, rewindFileCount) = calculateFolderSizeWithCount(at: rewindChunksURL)
            totalSize += rewindChunksSize
            fileCount += rewindFileCount

            if let dbSize = try? rewindDbURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                totalSize += Int64(dbSize)
            }
        }

        logStorageTiming("  getTotalStorageUsed enumerated \(fileCount) files")
        return totalSize
    }

    public func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        let chunksURL = storageRootURL.appendingPathComponent("chunks", isDirectory: true)
        let fileManager = FileManager.default
        let calendar = Calendar.current

        guard fileManager.fileExists(atPath: chunksURL.path) else { return 0 }

        var totalSize: Int64 = 0
        var currentDate = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        // Iterate through each day in the range
        while currentDate <= endDay {
            let year = calendar.component(.year, from: currentDate)
            let month = calendar.component(.month, from: currentDate)
            let day = calendar.component(.day, from: currentDate)

            let yearMonth = String(format: "%04d%02d", year, month)
            let dayStr = String(format: "%02d", day)

            let dayFolderURL = chunksURL
                .appendingPathComponent(yearMonth, isDirectory: true)
                .appendingPathComponent(dayStr, isDirectory: true)

            if fileManager.fileExists(atPath: dayFolderURL.path) {
                totalSize += calculateFolderSize(at: dayFolderURL)
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return totalSize
    }

    /// Get the total allocated size of a folder (fast version using du)
    private func calculateFolderSize(at url: URL) -> Int64 {
        // Use du -sk for fast kernel-level size calculation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]  // -s = summary, -k = kilobytes

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let sizeStr = output.split(separator: "\t").first,
               let sizeKB = Int64(sizeStr) {
                return sizeKB * 1024  // Convert KB to bytes
            }
        } catch {
            // Fallback on error
        }

        return calculateFolderSizeFallback(at: url)
    }

    /// Fallback: enumerate files if du fails
    private func calculateFolderSizeFallback(at url: URL) -> Int64 {
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
                continue
            }
        }

        return totalSize
    }

    /// Get folder size with file count (for diagnostics only)
    private func calculateFolderSizeWithCount(at url: URL) -> (size: Int64, fileCount: Int) {
        let size = calculateFolderSize(at: url)
        // For file count, we still need to enumerate but this is only used for diagnostics
        let fileManager = FileManager.default
        var fileCount = 0

        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == true {
                    fileCount += 1
                }
            }
        }

        return (size, fileCount)
    }

    /// Log to dashboard timing file for performance diagnostics
    private func logStorageTiming(_ message: String) {
        let logPath = "/tmp/dashboard_timing.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    public func getAvailableDiskSpace() async throws -> Int64 {
        try DiskSpaceMonitor.availableBytes(at: storageRootURL)
    }

    /// Returns video segment IDs that are older than the given date WITHOUT deleting them.
    /// Use deleteSegment() to actually delete after filtering for exclusions.
    public func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] {
        let files = try await directoryManager.listAllSegmentFiles()
        var candidates: [VideoSegmentID] = []

        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modDate = values?.contentModificationDate ?? Date.distantFuture
            guard modDate < date else { continue }

            if let id = parseSegmentID(from: url) {
                candidates.append(id)
            }
            // NOTE: Do NOT delete here - let caller filter for exclusions first, then call deleteSegment()
        }

        return candidates
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
