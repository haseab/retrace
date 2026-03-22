import AppKit
import AVFoundation
import Foundation
import Shared
import CoreMedia

public struct WALAvailabilityIssue: Sendable, Equatable {
    public let walRootPath: String
    public let operation: String
    public let reason: String
    public let detectedAt: Date
    public let reportPath: String?
}

fileprivate struct SegmentRewriteArtifacts: Sendable {
    let segmentID: VideoSegmentID
    let segmentURL: URL
    var tempURL: URL?
    var backupURL: URL?
}

fileprivate struct SegmentRewriteRequest: Sendable {
    let segmentID: VideoSegmentID
    let segmentURL: URL
    let tempURL: URL
    let backupURL: URL
    let targetsByFrameIndex: [Int: [SegmentRedactionTarget]]
    let secret: String
}

fileprivate func ensureNoConflictingSegmentRewriteArtifactsOnDisk(
    segmentID: VideoSegmentID,
    segmentURL: URL,
    tempURL: URL,
    backupURL: URL
) throws {
    if FileManager.default.fileExists(atPath: tempURL.path) {
        removeItemIfExistsOnDisk(at: tempURL)
    }

    if FileManager.default.fileExists(atPath: backupURL.path) {
        Log.warning(
            "[StorageManager] Removing stale rewrite backup before starting new rewrite for segment \(segmentID.value): \(backupURL.lastPathComponent)",
            category: .storage
        )
        removeItemIfExistsOnDisk(at: backupURL)
    }

    guard FileManager.default.fileExists(atPath: segmentURL.path) else {
        throw StorageError.fileNotFound(path: segmentURL.path)
    }
}

fileprivate func swapRewrittenSegmentIntoPlaceOnDisk(
    segmentURL: URL,
    tempURL: URL,
    backupURL: URL
) throws {
    let fileManager = FileManager.default

    try fileManager.moveItem(at: segmentURL, to: backupURL)
    do {
        try fileManager.moveItem(at: tempURL, to: segmentURL)
    } catch {
        if fileManager.fileExists(atPath: backupURL.path),
           !fileManager.fileExists(atPath: segmentURL.path) {
            try? fileManager.moveItem(at: backupURL, to: segmentURL)
        }
        throw error
    }
}

fileprivate func inferSegmentRewriteRecoveryModeFromDisk(
    segmentURL: URL,
    tempURL: URL?,
    backupURL: URL?
) -> SegmentRedactionRecoveryAction.Mode {
    let fileManager = FileManager.default
    let segmentExists = fileManager.fileExists(atPath: segmentURL.path)
    let tempExists = tempURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
    let backupExists = backupURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

    if segmentExists && backupExists {
        return .markCompleted
    }

    if backupExists || tempExists {
        return .rollbackToPending
    }

    return .rollbackToPending
}

fileprivate func rollbackInterruptedSegmentRewriteIfNeededOnDisk(
    segmentURL: URL,
    tempURL: URL?,
    backupURL: URL?
) {
    let fileManager = FileManager.default

    if let backupURL, fileManager.fileExists(atPath: backupURL.path) {
        do {
            if fileManager.fileExists(atPath: segmentURL.path) {
                _ = try fileManager.replaceItemAt(
                    segmentURL,
                    withItemAt: backupURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: backupURL, to: segmentURL)
            }
        } catch {
            Log.error(
                "[StorageManager] Failed to roll back interrupted segment rewrite at \(segmentURL.lastPathComponent): \(error.localizedDescription)",
                category: .storage
            )
        }
    }

    if let tempURL {
        removeItemIfExistsOnDisk(at: tempURL)
    }
}

fileprivate func removeItemIfExistsOnDisk(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try? FileManager.default.removeItem(at: url)
}

fileprivate actor SegmentRewriteExecutor {
    private struct DecodedFrame {
        let pts: CMTime
        let image: CGImage
    }

    private let encoderConfig: VideoEncoderConfig

    init(encoderConfig: VideoEncoderConfig) {
        self.encoderConfig = encoderConfig
    }

    func rewrite(_ request: SegmentRewriteRequest) async throws {
        let decodedFrames = try await decodeAllFrames(
            from: request.segmentURL,
            segmentID: request.segmentID.value
        )
        guard !decodedFrames.isEmpty else { return }

        let width = decodedFrames[0].image.width
        let height = decodedFrames[0].image.height
        guard width > 0, height > 0 else { return }

        var encoder: HEVCEncoder?
        do {
            try ensureNoConflictingSegmentRewriteArtifactsOnDisk(
                segmentID: request.segmentID,
                segmentURL: request.segmentURL,
                tempURL: request.tempURL,
                backupURL: request.backupURL
            )

            let newEncoder = HEVCEncoder()
            encoder = newEncoder
            try await newEncoder.initialize(
                width: width,
                height: height,
                config: encoderConfig,
                outputURL: request.tempURL,
                segmentStartTime: Date()
            )

            var loggedTargets = 0
            for (frameIndex, decodedFrame) in decodedFrames.enumerated() {
                var bgra = try StorageManager.makeBGRAData(from: decodedFrame.image)
                if let targets = request.targetsByFrameIndex[frameIndex], !targets.isEmpty {
                    for target in targets {
                        let pixelRect = BGRAImageUtilities.pixelRect(
                            from: target.normalizedRect,
                            imageWidth: width,
                            imageHeight: height
                        )
                        guard pixelRect.width > 1, pixelRect.height > 1 else { continue }
                        if loggedTargets < 20 {
                            Log.debug(
                                "[PhraseRedaction][Storage] Scramble mapping node=\(target.nodeID) frame=\(target.frameID) normalized=(\(String(format: "%.4f", target.normalizedRect.origin.x)),\(String(format: "%.4f", target.normalizedRect.origin.y)),\(String(format: "%.4f", target.normalizedRect.width)),\(String(format: "%.4f", target.normalizedRect.height))) pixelRect=(x=\(Int(pixelRect.origin.x)),y=\(Int(pixelRect.origin.y)),w=\(Int(pixelRect.width)),h=\(Int(pixelRect.height))) image=\(width)x\(height)",
                                category: .storage
                            )
                            loggedTargets += 1
                        }
                        guard var patch = BGRAImageUtilities.extractPatch(
                            from: bgra,
                            frameBytesPerRow: width * 4,
                            rect: pixelRect
                        ) else {
                            continue
                        }
                        ReversibleOCRScrambler.scramblePatchBGRA(
                            &patch.data,
                            width: patch.width,
                            height: patch.height,
                            bytesPerRow: patch.bytesPerRow,
                            frameID: target.frameID,
                            nodeID: target.nodeID,
                            secret: request.secret
                        )
                        BGRAImageUtilities.writePatch(
                            patch,
                            into: &bgra,
                            frameBytesPerRow: width * 4,
                            rect: pixelRect
                        )
                    }
                }

                let frame = CapturedFrame(
                    timestamp: Date(),
                    imageData: bgra,
                    width: width,
                    height: height,
                    bytesPerRow: width * 4
                )
                let pixelBuffer = try FrameConverter.createPixelBuffer(from: frame)
                let timestamp = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
                try await newEncoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
            }

            try await newEncoder.finalize()
            try swapRewrittenSegmentIntoPlaceOnDisk(
                segmentURL: request.segmentURL,
                tempURL: request.tempURL,
                backupURL: request.backupURL
            )
        } catch {
            await encoder?.reset()
            rollbackInterruptedSegmentRewriteIfNeededOnDisk(
                segmentURL: request.segmentURL,
                tempURL: request.tempURL,
                backupURL: request.backupURL
            )
            throw error
        }
    }

    private func decodeAllFrames(from url: URL, segmentID: Int64) async throws -> [DecodedFrame] {
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
                Log.error(
                    "[StorageManager] Failed to create symlink for segment \(segmentID): \(symlinkPath.path)",
                    category: .storage,
                    error: error
                )
                throw StorageError.fileWriteFailed(
                    path: symlinkPath.path,
                    underlying: error.localizedDescription
                )
            }
            assetURL = symlinkPath
        }

        let asset = AVAsset(url: assetURL)
        _ = try await asset.load(.duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "No video track")
        }

        let trackDuration = try await videoTrack.load(.timeRange)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let estimatedFrameCount = Int(trackDuration.duration.seconds * Double(nominalFrameRate))
        Log.debug(
            "[StorageManager] Video track: trackDuration=\(String(format: "%.3f", trackDuration.duration.seconds))s, frameRate=\(nominalFrameRate), estimatedFrames=\(estimatedFrameCount)",
            category: .storage
        )

        let reader = try AVAssetReader(asset: asset)
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

        var framesWithPTS: [(pts: CMTime, image: CGImage)] = []
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                Log.warning(
                    "[StorageManager] Skipping frame - no image buffer at PTS \(String(format: "%.3f", pts.seconds))s, segment \(segmentID)",
                    category: .storage
                )
                continue
            }

            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                Log.warning(
                    "[StorageManager] Failed to create CGImage at PTS \(String(format: "%.3f", pts.seconds))s, segment \(segmentID)",
                    category: .storage
                )
                continue
            }

            framesWithPTS.append((pts: pts, image: cgImage))
        }

        if reader.status == .failed {
            let errorDesc = reader.error?.localizedDescription ?? "Unknown error"
            Log.error(
                "[StorageManager] AVAssetReader failed: \(errorDesc), segmentID=\(segmentID)",
                category: .storage
            )
            throw StorageError.fileReadFailed(path: url.path, underlying: "Reader failed: \(errorDesc)")
        }

        Log.debug(
            "[StorageManager] Read \(framesWithPTS.count) frames from AVAssetReader, expected ~\(estimatedFrameCount)",
            category: .storage
        )

        framesWithPTS.sort { $0.pts.seconds < $1.pts.seconds }

        let decodedFrames = framesWithPTS.map { frame in
            DecodedFrame(pts: frame.pts, image: frame.image)
        }

        Log.info(
            "[StorageManager] Decoded \(decodedFrames.count) frames from segment \(segmentID), sorted by PTS",
            category: .storage
        )

        if let firstPTS = decodedFrames.first?.pts.seconds,
           let lastPTS = decodedFrames.last?.pts.seconds {
            Log.debug(
                "[StorageManager] PTS range: \(String(format: "%.3f", firstPTS))s - \(String(format: "%.3f", lastPTS))s",
                category: .storage
            )
        }

        return decodedFrames
    }
}

/// Main StorageProtocol implementation.
public actor StorageManager: StorageProtocol {
    private static let discardableQuarantinedWALRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private var config: StorageConfig?
    private var storageRootURL: URL
    private let directoryManager: DirectoryManager
    private let encoderConfig: VideoEncoderConfig
    private let walRootURL: URL
    private let walManager: WALManager
    private let crashReportDirectory: String
    private let segmentRewriteExecutor: SegmentRewriteExecutor
    private var walAvailabilityIssue: WALAvailabilityIssue?

    /// Counter to ensure unique segment IDs even if created within same millisecond
    private var segmentCounter: Int = 0

    /// Cache for decoded frames from B-frame videos, keyed by segment ID
    /// Each entry contains frames sorted by PTS (presentation order)
    private var frameCache: [Int64: FrameCacheEntry] = [:]

    /// Maximum number of segments to keep in cache
    private let maxCachedSegments = 3

    /// Cache for AVAssetImageGenerator instances, keyed by video path
    /// Reusing generators avoids expensive AVAsset initialization per frame
    /// Cache is invalidated on time mismatch to handle growing video files
    private var generatorCache: [String: GeneratorCacheEntry] = [:]

    /// Maximum number of generators to keep cached
    private let maxCachedGenerators = 10

    /// Cached AVAssetImageGenerator entry
    private struct GeneratorCacheEntry {
        let generator: AVAssetImageGenerator
        let symlinkURL: URL?  // Keep symlink alive while generator is cached
        var lastAccessTime: Date
    }

    /// Cache for segment file paths, keyed by segment ID
    /// Avoids expensive directory enumeration on every frame read
    private var segmentPathCache: [Int64: URL] = [:]

    public init(
        storageRoot: URL = URL(fileURLWithPath: StorageConfig.default.expandedStorageRootPath, isDirectory: true),
        encoderConfig: VideoEncoderConfig = .default,
        crashReportDirectory: String = EmergencyDiagnostics.crashReportDirectory
    ) {
        self.storageRootURL = storageRoot
        self.directoryManager = DirectoryManager(storageRoot: storageRoot)
        self.encoderConfig = encoderConfig
        self.crashReportDirectory = crashReportDirectory

        // Initialize WAL manager in wal/ subdirectory
        let walRoot = storageRoot.appendingPathComponent("wal", isDirectory: true)
        self.walRootURL = walRoot
        self.walManager = WALManager(walRoot: walRoot)
        self.segmentRewriteExecutor = SegmentRewriteExecutor(encoderConfig: encoderConfig)
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
        if await ensureWALReady(operation: "startup_initialization") {
            _ = await walManager.cleanupQuarantinedSessions(
                olderThan: Date().addingTimeInterval(-Self.discardableQuarantinedWALRetentionInterval)
            )
        }
    }

    public func createSegmentWriter() async throws -> SegmentWriter {
        guard config != nil else {
            throw StorageError.directoryCreationFailed(path: "Storage not initialized")
        }
        guard await ensureWALReady(operation: "capture_writer_prepare") else {
            let reason = walAvailabilityIssue?.reason ?? "unknown WAL initialization failure"
            throw StorageError.walUnavailable(reason: reason)
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

    public func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame? {
        try await walManager.readFrame(
            videoID: segmentID,
            frameID: frameID,
            fallbackFrameIndex: fallbackFrameIndex
        )
    }

    public func validateCaptureReadiness() async throws {
        guard config != nil else {
            throw StorageError.directoryCreationFailed(path: "Storage not initialized")
        }

        guard await ensureWALReady(operation: "capture_start") else {
            let reason = walAvailabilityIssue?.reason ?? "unknown WAL initialization failure"
            throw StorageError.walUnavailable(reason: reason)
        }
    }

    public func currentWALAvailabilityIssue() -> WALAvailabilityIssue? {
        walAvailabilityIssue
    }

    public func isWALReady() -> Bool {
        walAvailabilityIssue == nil
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
    /// Generator instances are cached per video path for efficient scrubbing.
    /// Cache is automatically invalidated on time mismatch (stale duration) and retried with a fresh generator in strict mode.
    private func extractSingleFrame(
        from videoURL: URL,
        frameIndex: Int,
        frameRate: Double = 30.0,
        enforceTimestampMatch: Bool = true
    ) async throws -> Data {
        let cacheKey = videoURL.path

        // Check if file exists
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw StorageError.fileNotFound(path: videoURL.path)
        }

        // Check if file is empty
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            throw StorageError.fileReadFailed(path: videoURL.path, underlying: "Video file is empty (still being written)")
        }

        // Calculate CMTime from frame index
        let time: CMTime
        if frameRate == 30.0 {
            time = CMTime(value: Int64(frameIndex) * 20, timescale: 600)
        } else {
            let timeInSeconds = Double(frameIndex) / frameRate
            time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        }

        // Try with cached generator first, retry with fresh generator on time mismatch
        for attempt in 0..<2 {
            let useCached = (attempt == 0)

            let imageGenerator: AVAssetImageGenerator
            var symlinkURL: URL? = nil

            if useCached, var entry = generatorCache[cacheKey] {
                // Use cached generator
                entry.lastAccessTime = Date()
                generatorCache[cacheKey] = entry
                imageGenerator = entry.generator
            } else {
                // Create fresh generator - invalidate cache first if this is a retry
                if attempt > 0 {
                    if let entry = generatorCache.removeValue(forKey: cacheKey),
                       let oldSymlink = entry.symlinkURL {
                        try? FileManager.default.removeItem(at: oldSymlink)
                    }
                    Log.info("[VideoExtract] Invalidated stale cache for \(videoURL.lastPathComponent), creating fresh generator", category: .storage)
                }

                // Handle extensionless files by creating symlink
                let assetURL: URL
                if videoURL.pathExtension.lowercased() == "mp4" {
                    assetURL = videoURL
                } else {
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

            // Extract frame
            var actualTime = CMTime.zero
            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: &actualTime)

                // Check for time mismatch
                let requestedSeconds = time.seconds
                let actualSeconds = actualTime.seconds
                let diffMs = abs(requestedSeconds - actualSeconds) * 1000

                if enforceTimestampMatch, diffMs > 10 { // More than 10ms difference
                    if useCached {
                        // Cached generator returned wrong frame - retry with fresh generator
                        Log.warning("[VideoExtract] ⚠️ TIME MISMATCH (cached): frameIndex=\(frameIndex), requested=\(String(format: "%.3f", requestedSeconds))s, actual=\(String(format: "%.3f", actualSeconds))s, retrying with fresh generator", category: .storage)
                        continue // Retry with fresh generator
                    } else {
                        // Fresh generator also returned wrong frame in strict mode.
                        // Treat this as unavailable so callers can fall back to capture-time stills.
                        Log.warning("[VideoExtract] ⚠️ TIME MISMATCH (fresh): frameIndex=\(frameIndex), requested=\(String(format: "%.3f", requestedSeconds))s, actual=\(String(format: "%.3f", actualSeconds))s, video=\(videoURL.lastPathComponent)", category: .storage)
                        throw StorageError.fileReadFailed(
                            path: videoURL.path,
                            underlying: "Timestamp mismatch: requested=\(String(format: "%.3f", requestedSeconds))s actual=\(String(format: "%.3f", actualSeconds))s frameIndex=\(frameIndex)"
                        )
                    }
                }

                return try convertCGImageToJPEG(cgImage)
            } catch {
                // Invalidate cache on error
                if let entry = generatorCache.removeValue(forKey: cacheKey),
                   let oldSymlink = entry.symlinkURL {
                    try? FileManager.default.removeItem(at: oldSymlink)
                }
                throw StorageError.fileReadFailed(
                    path: videoURL.path,
                    underlying: "Frame extraction failed: \(error.localizedDescription)"
                )
            }
        }

        // Should never reach here, but just in case
        throw StorageError.fileReadFailed(path: videoURL.path, underlying: "Frame extraction failed after retries")
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
    public func readFrameFromPath(
        videoPath: String,
        frameIndex: Int,
        enforceTimestampMatch: Bool = true
    ) async throws -> Data {
        let videoURL = URL(fileURLWithPath: videoPath)
        return try await extractSingleFrame(
            from: videoURL,
            frameIndex: frameIndex,
            enforceTimestampMatch: enforceTimestampMatch
        )
    }

    /// Rewrite a finalized segment by encoding a new file to a temp path, then swapping it into
    /// the original segment location once complete.
    public func rewriteSegmentForRedaction(
        segmentID: VideoSegmentID,
        frameIDs: [Int64],
        targetsByFrameIndex: [Int: [SegmentRedactionTarget]],
        secret: String
    ) async throws {
        guard !targetsByFrameIndex.isEmpty else { return }
        guard !frameIDs.isEmpty else { return }

        let segmentURL = try await getSegmentPath(id: segmentID)
        let tempURL = segmentRewriteTempURL(for: segmentURL, segmentID: segmentID)
        let backupURL = segmentRewriteBackupURL(for: segmentURL, segmentID: segmentID)
        let request = SegmentRewriteRequest(
            segmentID: segmentID,
            segmentURL: segmentURL,
            tempURL: tempURL,
            backupURL: backupURL,
            targetsByFrameIndex: targetsByFrameIndex,
            secret: secret
        )

        try await Task.detached(priority: .utility) { [segmentRewriteExecutor] in
            try await segmentRewriteExecutor.rewrite(request)
        }.value

        clearFrameCache(for: segmentID)
        generatorCache.removeValue(forKey: segmentURL.path)

        Log.info(
            "[StorageManager] Rewrote segment \(segmentID.value) with reversible OCR scrambling (\(targetsByFrameIndex.count) frame(s))",
            category: .storage
        )
    }

    public func recoverInterruptedSegmentRedactions() async throws -> [SegmentRedactionRecoveryAction] {
        let artifacts = try findInterruptedSegmentRewriteArtifacts()
        var actions: [SegmentRedactionRecoveryAction] = []
        for artifact in artifacts {
            let tempURL = artifact.tempURL
            let backupURL = artifact.backupURL
            let recoveryMode = inferSegmentRewriteRecoveryMode(
                segmentURL: artifact.segmentURL,
                tempURL: tempURL,
                backupURL: backupURL
            )

            if recoveryMode == .rollbackToPending {
                rollbackInterruptedSegmentRewriteIfNeeded(
                    segmentURL: artifact.segmentURL,
                    tempURL: tempURL,
                    backupURL: backupURL
                )
            } else if let tempURL {
                removeItemIfExists(at: tempURL)
            }

            clearFrameCache(for: artifact.segmentID)
            generatorCache.removeValue(forKey: artifact.segmentURL.path)
            actions.append(
                SegmentRedactionRecoveryAction(
                    mode: recoveryMode,
                    segmentID: artifact.segmentID
                )
            )
        }

        return actions
    }

    public func finishInterruptedSegmentRedactionRecovery(segmentID: VideoSegmentID) async throws {
        guard let artifact = try findInterruptedSegmentRewriteArtifacts(segmentID: segmentID).first else {
            return
        }

        if let tempURL = artifact.tempURL {
            removeItemIfExists(at: tempURL)
        }
        if let backupURL = artifact.backupURL {
            removeItemIfExists(at: backupURL)
        }
    }

    func forceRollbackSegmentRewriteStateForTesting(segmentID: VideoSegmentID) async throws {
        guard let artifact = try findInterruptedSegmentRewriteArtifacts(segmentID: segmentID).first,
              artifact.backupURL != nil else {
            throw StorageError.fileNotFound(path: "rollback-artifacts-\(segmentID.value)")
        }

        let segmentURL = artifact.segmentURL
        let tempURL = artifact.tempURL ?? segmentRewriteTempURL(for: segmentURL, segmentID: segmentID)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: segmentURL.path) {
            if fileManager.fileExists(atPath: tempURL.path) {
                removeItemIfExists(at: tempURL)
            }
            try fileManager.moveItem(at: segmentURL, to: tempURL)
        }
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

    static func makeBGRAData(from image: CGImage) throws -> Data {
        do {
            return try BGRAImageUtilities.makeData(from: image)
        } catch {
            throw StorageError.fileReadFailed(path: "", underlying: "Failed to create BGRA bitmap context")
        }
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
        segmentPathCache.removeAll()
        Log.info("[StorageManager] Frame and segment path caches cleared", category: .storage)
    }

    /// Clear cache for a specific segment (call when segment is finalized or modified)
    public func clearFrameCache(for segmentID: VideoSegmentID) {
        frameCache.removeValue(forKey: segmentID.value)
        segmentPathCache.removeValue(forKey: segmentID.value)
        Log.debug("[StorageManager] Cleared cache for segment \(segmentID.value)", category: .storage)
    }

    public func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        // Check cache first to avoid expensive directory enumeration
        if let cached = segmentPathCache[id.value] {
            // Verify file still exists (could have been deleted)
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            // File was deleted, remove from cache
            segmentPathCache.removeValue(forKey: id.value)
        }

        // Cache miss - enumerate directory
        let files = try await directoryManager.listAllSegmentFiles()
        // CRITICAL: Use exact match, not substring! Files are named with Int64 ID (e.g., "1768624554519")
        // .contains() would match "8" in "1768624603374" - must use == for exact match
        // Support both extensionless files and files with .mp4 extension
        if let match = files.first(where: {
            $0.lastPathComponent == id.stringValue ||
            $0.lastPathComponent == "\(id.stringValue).mp4"
        }) {
            // Cache the result
            segmentPathCache[id.value] = match
            return match
        }
        throw StorageError.fileNotFound(path: id.stringValue)
    }

    public func deleteSegment(id: VideoSegmentID) async throws {
        let url = try await getSegmentPath(id: id)
        do {
            try FileManager.default.removeItem(at: url)
            // Invalidate cache entry
            segmentPathCache.removeValue(forKey: id.value)
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
                totalSize += calculateImmediateChildrenAllocatedSize(at: dayFolderURL)
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return totalSize
    }

    /// Sum allocated sizes of immediate files in a day folder (non-recursive).
    /// Ignores nested directories and their contents.
    private func calculateImmediateChildrenAllocatedSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            ) else {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                totalSize += Int64(allocated)
            }
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

    @discardableResult
    private func ensureWALReady(operation: String) async -> Bool {
        do {
            try await walManager.initialize()

            if walAvailabilityIssue != nil {
                Log.info("[WAL] WAL storage repaired during \(operation)", category: .storage)
            }

            walAvailabilityIssue = nil
            return true
        } catch {
            let reason = error.localizedDescription
            let detectedAt = Date()
            let reportPath: String?
            if walAvailabilityIssue?.reason == reason {
                reportPath = walAvailabilityIssue?.reportPath
            } else {
                reportPath = writeWALUnavailableReport(
                    operation: operation,
                    error: error,
                    detectedAt: detectedAt
                )
            }

            walAvailabilityIssue = WALAvailabilityIssue(
                walRootPath: walRootURL.path,
                operation: operation,
                reason: reason,
                detectedAt: detectedAt,
                reportPath: reportPath
            )

            Log.error(
                "[WAL] WAL unavailable during \(operation): \(reason). Crash recovery was skipped and new WAL session creation may fail until the storage path is repaired.",
                category: .storage
            )
            return false
        }
    }

    private func writeWALUnavailableReport(
        operation: String,
        error: Error,
        detectedAt: Date
    ) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let nsError = error as NSError
        var report = ""
        report += "=== RETRACE EMERGENCY DIAGNOSTIC ===\n"
        report += "Trigger: wal_unavailable\n"
        report += "Timestamp: \(formatter.string(from: detectedAt))\n"
        report += "Operation: \(operation)\n\n"

        report += "--- SUMMARY ---\n"
        report += "Retrace could not initialize the write-ahead log (WAL).\n"
        report += "Startup recovery was skipped, and Retrace will retry WAL setup the next time it needs a new session.\n\n"

        report += "--- FAILURE ---\n"
        report += "Storage Root: \(storageRootURL.path)\n"
        report += "WAL Root: \(walRootURL.path)\n"
        report += "Error Type: \(String(reflecting: type(of: error)))\n"
        report += "Error Description: \(error.localizedDescription)\n"
        report += "NSError Domain: \(nsError.domain)\n"
        report += "NSError Code: \(nsError.code)\n"
        if let failureReason = nsError.localizedFailureReason {
            report += "Failure Reason: \(failureReason)\n"
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion {
            report += "Recovery Suggestion: \(recoverySuggestion)\n"
        }
        report += "\n"

        report += "--- WAL ROOT STATE ---\n"
        report += describeFilesystemItem(at: walRootURL)
        report += "\n--- WAL PARENT STATE ---\n"
        report += describeFilesystemItem(at: walRootURL.deletingLastPathComponent())

        report += "\n--- IMPACT ---\n"
        report += "Skipped: WAL crash recovery for active sessions during startup.\n"
        report += "May fail later: creating a new WAL session if the storage path is still broken.\n"
        report += "Should still work: existing timeline/search data and reads from finalized video files.\n\n"

        report += "--- SELF-HEALING ---\n"
        report += "Retrace will retry WAL initialization the next time recording is started.\n"
        report += "If the filesystem issue is fixed, recording can recover without deleting existing data.\n\n"

        report += "--- REPAIR ACTIONS ---\n"
        report += "1. Reconnect the configured storage volume if it is unavailable.\n"
        report += "2. Ensure Retrace can create and write files under the storage root.\n"
        report += "3. Remove or rename any non-directory item occupying the WAL path if one still exists.\n"

        return EmergencyDiagnostics.writeReport(
            trigger: "wal_unavailable",
            body: report,
            directory: crashReportDirectory
        )
    }

    private func segmentRewriteTempURL(for segmentURL: URL, segmentID: VideoSegmentID) -> URL {
        segmentURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(segmentURL.lastPathComponent).redaction-working-\(segmentID.value).mp4")
    }

    private func segmentRewriteBackupName(for segmentURL: URL, segmentID: VideoSegmentID) -> String {
        ".\(segmentURL.lastPathComponent).redaction-backup-\(segmentID.value)"
    }

    private func segmentRewriteBackupURL(for segmentURL: URL, segmentID: VideoSegmentID) -> URL {
        segmentURL
            .deletingLastPathComponent()
            .appendingPathComponent(segmentRewriteBackupName(for: segmentURL, segmentID: segmentID))
    }

    private func findInterruptedSegmentRewriteArtifacts(
        segmentID targetSegmentID: VideoSegmentID? = nil
    ) throws -> [SegmentRewriteArtifacts] {
        let chunksRoot = storageRootURL.appendingPathComponent("chunks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: chunksRoot.path) else {
            return []
        }

        let enumerator = FileManager.default.enumerator(
            at: chunksRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )

        var artifactsByPath: [String: SegmentRewriteArtifacts] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let artifact = parseSegmentRewriteArtifact(at: url) else {
                continue
            }
            if let targetSegmentID, artifact.segmentID != targetSegmentID {
                continue
            }

            var merged = artifactsByPath[artifact.segmentURL.path] ?? SegmentRewriteArtifacts(
                segmentID: artifact.segmentID,
                segmentURL: artifact.segmentURL,
                tempURL: nil,
                backupURL: nil
            )
            if let tempURL = artifact.tempURL {
                merged.tempURL = tempURL
            }
            if let backupURL = artifact.backupURL {
                merged.backupURL = backupURL
            }
            artifactsByPath[artifact.segmentURL.path] = merged
        }

        return artifactsByPath.values.sorted { lhs, rhs in
            if lhs.segmentID.value == rhs.segmentID.value {
                return lhs.segmentURL.path < rhs.segmentURL.path
            }
            return lhs.segmentID.value < rhs.segmentID.value
        }
    }

    private func parseSegmentRewriteArtifact(at url: URL) -> SegmentRewriteArtifacts? {
        let name = url.lastPathComponent
        guard name.hasPrefix(".") else { return nil }

        let hiddenStart = name.index(after: name.startIndex)

        if let markerRange = name.range(of: ".redaction-working-", options: .backwards),
           name.hasSuffix(".mp4") {
            let originalName = String(name[hiddenStart..<markerRange.lowerBound])
            let idEnd = name.index(name.endIndex, offsetBy: -4)
            guard !originalName.isEmpty,
                  markerRange.upperBound < idEnd,
                  let rawID = Int64(name[markerRange.upperBound..<idEnd]) else {
                return nil
            }
            let segmentURL = url.deletingLastPathComponent().appendingPathComponent(originalName)
            return SegmentRewriteArtifacts(
                segmentID: VideoSegmentID(value: rawID),
                segmentURL: segmentURL,
                tempURL: url,
                backupURL: nil
            )
        }

        if let markerRange = name.range(of: ".redaction-backup-", options: .backwards) {
            let originalName = String(name[hiddenStart..<markerRange.lowerBound])
            guard !originalName.isEmpty,
                  let rawID = Int64(name[markerRange.upperBound...]) else {
                return nil
            }
            let segmentURL = url.deletingLastPathComponent().appendingPathComponent(originalName)
            return SegmentRewriteArtifacts(
                segmentID: VideoSegmentID(value: rawID),
                segmentURL: segmentURL,
                tempURL: nil,
                backupURL: url
            )
        }

        return nil
    }

    private func inferSegmentRewriteRecoveryMode(
        segmentURL: URL,
        tempURL: URL?,
        backupURL: URL?
    ) -> SegmentRedactionRecoveryAction.Mode {
        inferSegmentRewriteRecoveryModeFromDisk(
            segmentURL: segmentURL,
            tempURL: tempURL,
            backupURL: backupURL
        )
    }

    private func rollbackInterruptedSegmentRewriteIfNeeded(
        segmentURL: URL,
        tempURL: URL?,
        backupURL: URL?
    ) {
        rollbackInterruptedSegmentRewriteIfNeededOnDisk(
            segmentURL: segmentURL,
            tempURL: tempURL,
            backupURL: backupURL
        )
    }

    private func removeItemIfExists(at url: URL) {
        removeItemIfExistsOnDisk(at: url)
    }

    private func describeFilesystemItem(at url: URL) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        var lines = [
            "Path: \(url.path)",
            "Exists: \(exists)"
        ]

        guard exists else {
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("Kind: \(isDirectory.boolValue ? "directory" : "file")")
        lines.append("Readable: \(FileManager.default.isReadableFile(atPath: url.path))")
        lines.append("Writable: \(FileManager.default.isWritableFile(atPath: url.path))")

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let fileType = attributes[.type] as? FileAttributeType {
                lines.append("File Type: \(fileType.rawValue)")
            }
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                lines.append(String(format: "POSIX Permissions: %03o", permissions.intValue))
            }
            if let size = attributes[.size] as? NSNumber {
                lines.append("Size Bytes: \(size.int64Value)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Cache Management

    /// Invalidate all caches. Call when storage path may have changed (e.g., volume unmount/remount).
    public func invalidateAllCaches() {
        frameCache.removeAll()
        segmentPathCache.removeAll()

        // Clean up generator cache and remove any symlinks
        for (_, entry) in generatorCache {
            if let symlinkURL = entry.symlinkURL {
                try? FileManager.default.removeItem(at: symlinkURL)
            }
        }
        generatorCache.removeAll()

        Log.info("[StorageManager] All caches invalidated", category: .storage)
    }

    /// Purge cached AVFoundation decode state without dropping path lookups.
    public func purgeFrameExtractionCaches(reason: String) {
        frameCache.removeAll()

        for (_, entry) in generatorCache {
            if let symlinkURL = entry.symlinkURL {
                try? FileManager.default.removeItem(at: symlinkURL)
            }
        }
        generatorCache.removeAll()

        Log.info("[StorageManager] Purged frame extraction caches (\(reason))", category: .storage)
    }

    /// Validate cached paths still exist. Call after drive reconnection to clean stale entries.
    public func validateCaches() {
        var invalidSegmentIDs: [Int64] = []

        // Check segment path cache
        for (segmentID, url) in segmentPathCache {
            if !FileManager.default.fileExists(atPath: url.path) {
                invalidSegmentIDs.append(segmentID)
            }
        }

        // Remove invalid segment entries
        for id in invalidSegmentIDs {
            segmentPathCache.removeValue(forKey: id)
            frameCache.removeValue(forKey: id)
        }

        // Validate generator cache
        var invalidPaths: [String] = []
        for (path, entry) in generatorCache {
            if !FileManager.default.fileExists(atPath: path) {
                invalidPaths.append(path)
                if let symlinkURL = entry.symlinkURL {
                    try? FileManager.default.removeItem(at: symlinkURL)
                }
            }
        }
        for path in invalidPaths {
            generatorCache.removeValue(forKey: path)
        }

        if !invalidSegmentIDs.isEmpty || !invalidPaths.isEmpty {
            Log.warning("[StorageManager] Invalidated \(invalidSegmentIDs.count) segment cache entries and \(invalidPaths.count) generator cache entries", category: .storage)
        }
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
