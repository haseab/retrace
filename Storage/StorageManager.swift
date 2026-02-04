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

    /// Cache for AVAssetImageGenerator instances, keyed by video path
    /// Reusing generators avoids expensive AVAsset initialization per frame
    private var generatorCache: [String: GeneratorCacheEntry] = [:]

    /// Maximum number of generators to keep cached
    private let maxCachedGenerators = 10

    /// Cached AVAssetImageGenerator entry
    private struct GeneratorCacheEntry {
        let generator: AVAssetImageGenerator
        let symlinkURL: URL?  // Keep symlink alive while generator is cached
        var lastAccessTime: Date
    }

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
        // Get segment path
        let segmentURL = try await getSegmentPath(id: segmentID)

        // Use fast single-frame extraction
        return try await extractSingleFrame(from: segmentURL, frameIndex: frameIndex)
    }

    /// Fast single-frame extraction using AVAssetImageGenerator
    /// This is much faster than decoding all frames - AVFoundation handles B-frame decoding internally
    /// Generator instances are cached per video path for efficient scrubbing
    private func extractSingleFrame(from videoURL: URL, frameIndex: Int, frameRate: Double = 30.0) async throws -> Data {
        let cacheKey = videoURL.path

        // Get or create cached generator
        let imageGenerator: AVAssetImageGenerator
        if var entry = generatorCache[cacheKey] {
            entry.lastAccessTime = Date()
            generatorCache[cacheKey] = entry
            imageGenerator = entry.generator
        } else {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw StorageError.fileNotFound(path: videoURL.path)
            }

            // Check if file is empty
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
            if fileSize == 0 {
                throw StorageError.fileReadFailed(path: videoURL.path, underlying: "Video file is empty (still being written)")
            }

            // Handle extensionless files by creating symlink
            let assetURL: URL
            var symlinkURL: URL? = nil

            if videoURL.pathExtension.lowercased() == "mp4" {
                assetURL = videoURL
            } else {
                // Create symlink with .mp4 extension (kept alive in cache)
                let tempPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                symlinkURL = tempPath

                try FileManager.default.createSymbolicLink(
                    at: tempPath,
                    withDestinationURL: videoURL
                )
                assetURL = tempPath
            }

            // Create and configure the generator
            let asset = AVAsset(url: assetURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceAfter = .zero
            generator.requestedTimeToleranceBefore = .zero

            // Cache the generator
            generatorCache[cacheKey] = GeneratorCacheEntry(
                generator: generator,
                symlinkURL: symlinkURL,
                lastAccessTime: Date()
            )
            imageGenerator = generator

            // Evict old generators if needed
            evictOldGenerators()
        }

        // Calculate CMTime from frame index
        let time: CMTime
        if frameRate == 30.0 {
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            let timeInSeconds = Double(frameIndex) / frameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

        // Extract frame using cached generator
        let cgImage: CGImage
        do {
            cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
        } catch {
            // Invalidate cache on error and clean up symlink
            if let entry = generatorCache.removeValue(forKey: cacheKey),
               let symlinkURL = entry.symlinkURL {
                try? FileManager.default.removeItem(at: symlinkURL)
            }
            throw StorageError.fileReadFailed(
                path: videoURL.path,
                underlying: "Frame extraction failed: \(error.localizedDescription)"
            )
        }

        return try convertCGImageToJPEG(cgImage)
    }

    /// Evict oldest generators when cache is full
    private func evictOldGenerators() {
        guard generatorCache.count > maxCachedGenerators else { return }

        // Sort by last access time and remove oldest
        let sorted = generatorCache.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
        let toRemove = sorted.prefix(generatorCache.count - maxCachedGenerators)

        for (key, entry) in toRemove {
            generatorCache.removeValue(forKey: key)
            // Clean up symlink
            if let symlinkURL = entry.symlinkURL {
                try? FileManager.default.removeItem(at: symlinkURL)
            }
        }
    }

    /// Read a frame from a video at a specific path
    /// Uses fast single-frame extraction via AVAssetImageGenerator
    public func readFrameFromPath(videoPath: String, frameIndex: Int) async throws -> Data {
        let videoURL = URL(fileURLWithPath: videoPath)
        return try await extractSingleFrame(from: videoURL, frameIndex: frameIndex)
    }

    // MARK: - Legacy decode-all methods (kept for easy rollback if B-frame issues occur)

    /// Read a frame using the old decode-all-frames approach (SLOW - decodes entire video)
    /// This was the original implementation before the AVAssetImageGenerator optimization.
    /// Kept for easy rollback if B-frame issues are discovered.
    /// To rollback: change readFrame() to call this instead of extractSingleFrame()
    public func readFrameDecodeAll(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        let segmentIDValue = segmentID.value

        // Check cache first
        if let cacheEntry = frameCache[segmentIDValue] {
            var updatedEntry = cacheEntry
            updatedEntry.lastAccessTime = Date()
            frameCache[segmentIDValue] = updatedEntry

            if frameIndex < cacheEntry.frames.count {
                let frame = cacheEntry.frames[frameIndex]
                return try convertCGImageToJPEG(frame.image)
            }
        }

        let segmentURL = try await getSegmentPath(id: segmentID)

        guard FileManager.default.fileExists(atPath: segmentURL.path) else {
            throw StorageError.fileNotFound(path: segmentURL.path)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Video file is empty (still being written)")
        }

        let frames = try await decodeAllFrames(from: segmentURL, segmentID: segmentIDValue)

        let cacheEntry = FrameCacheEntry(
            segmentID: segmentIDValue,
            frames: frames,
            lastAccessTime: Date(),
            totalFrameCount: frames.count
        )
        frameCache[segmentIDValue] = cacheEntry
        evictOldCacheEntries()

        guard frameIndex < frames.count else {
            frameCache.removeValue(forKey: segmentIDValue)
            throw StorageError.fileReadFailed(
                path: segmentURL.path,
                underlying: "Frame index \(frameIndex) out of range (0..<\(frames.count))"
            )
        }

        return try convertCGImageToJPEG(frames[frameIndex].image)
    }

    /// Read a frame from path using the old decode-all-frames approach (SLOW)
    /// Kept for easy rollback if B-frame issues are discovered.
    public func readFrameFromPathDecodeAll(videoPath: String, frameIndex: Int) async throws -> Data {
        let cacheKey = Int64(videoPath.hashValue)

        if let cacheEntry = frameCache[cacheKey] {
            var updatedEntry = cacheEntry
            updatedEntry.lastAccessTime = Date()
            frameCache[cacheKey] = updatedEntry

            if frameIndex < cacheEntry.frames.count {
                let frame = cacheEntry.frames[frameIndex]
                return try convertCGImageToJPEG(frame.image)
            }
        }

        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw StorageError.fileNotFound(path: videoPath)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoPath)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            throw StorageError.fileReadFailed(path: videoPath, underlying: "Video file is empty")
        }

        let segmentURL = URL(fileURLWithPath: videoPath)
        let frames = try await decodeAllFrames(from: segmentURL, segmentID: cacheKey)

        let cacheEntry = FrameCacheEntry(
            segmentID: cacheKey,
            frames: frames,
            lastAccessTime: Date(),
            totalFrameCount: frames.count
        )
        frameCache[cacheKey] = cacheEntry
        evictOldCacheEntries()

        guard frameIndex < frames.count else {
            frameCache.removeValue(forKey: cacheKey)
            throw StorageError.fileReadFailed(
                path: videoPath,
                underlying: "Frame index \(frameIndex) out of range (0..<\(frames.count))"
            )
        }

        return try convertCGImageToJPEG(frames[frameIndex].image)
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

        // CRITICAL: Create CIContext ONCE outside the loop to avoid memory leak
        // Each CIContext allocates 20-50MB of Metal/GPU resources
        // Creating one per frame caused 40GB+ memory usage in VTDecoderXPCService
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                Log.warning("[StorageManager] Skipping frame - no image buffer at PTS \(String(format: "%.3f", pts.seconds))s, segment \(segmentID)", category: .storage)
                continue
            }

            // Convert CVPixelBuffer to CGImage using shared context
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
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
