import Foundation
import AVFoundation
import CoreImage
import AppKit
import Shared

/// Imports screen recording data from Rewind AI (com.memoryvault.MemoryVault)
///
/// Rewind stores data in:
/// ~/Library/Application Support/com.memoryvault.MemoryVault/chunks/YYYYMM/DD/*.mp4
///
/// Each MP4 contains frames captured at 0.5 FPS (1 frame every 2 seconds real-time),
/// but encoded at ~30 FPS. So a 2-second video contains ~60 frames representing
/// ~2 minutes of real-world time.
public actor RewindImporter: MigrationProtocol {

    // MARK: - Properties

    public let source: FrameSource = .rewind

    private let database: any DatabaseProtocol
    private let processing: any ProcessingProtocol
    private let stateStore: MigrationStateStore

    private var state: MigrationState
    private var currentProgress: MigrationProgress
    private var isCurrentlyImporting = false
    private var shouldCancel = false
    private var shouldPause = false

    private weak var delegate: MigrationDelegate?

    /// Real-time capture rate of Rewind (1 frame every 2 seconds)
    private let rewindCaptureIntervalSeconds: TimeInterval = 2.0

    /// Assumed duration each Rewind video covers in real-time (5 minutes)
    private let assumedVideoDurationMinutes: TimeInterval = 5.0

    /// Batch size for database inserts (for performance)
    private let batchSize = 50

    /// Delay between batches to avoid hogging CPU
    private let batchDelayMs: UInt64 = 100

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        processing: any ProcessingProtocol,
        stateStore: MigrationStateStore
    ) {
        self.database = database
        self.processing = processing
        self.stateStore = stateStore
        self.state = MigrationState(source: .rewind)
        self.currentProgress = MigrationProgress.initial(source: .rewind)
    }

    // MARK: - MigrationProtocol

    public var isImporting: Bool {
        isCurrentlyImporting
    }

    public var progress: MigrationProgress {
        currentProgress
    }

    public func isDataAvailable() async -> Bool {
        let chunksPath = getRewindChunksPath()
        return FileManager.default.fileExists(atPath: chunksPath.path)
    }

    public func scan() async throws -> MigrationScanResult {
        Log.info("Scanning Rewind data...", category: .app)
        updateProgress(state: .scanning)

        let chunksPath = getRewindChunksPath()
        guard FileManager.default.fileExists(atPath: chunksPath.path) else {
            throw MigrationError.sourceNotFound(path: chunksPath.path)
        }

        // Find all MP4 files
        let videoFiles = try findAllVideoFiles(in: chunksPath)
        guard !videoFiles.isEmpty else {
            throw MigrationError.noVideosFound
        }

        // Calculate statistics
        var totalSize: Int64 = 0
        var estimatedFrames = 0
        var earliestDate: Date?
        var latestDate: Date?

        for file in videoFiles {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            totalSize += (attrs[.size] as? Int64) ?? 0

            // Get creation date from file
            if let creationDate = attrs[.creationDate] as? Date {
                if earliestDate == nil || creationDate < earliestDate! {
                    earliestDate = creationDate
                }
                if latestDate == nil || creationDate > latestDate! {
                    latestDate = creationDate
                }
            }

            // Estimate frames: get video frame count
            let frameCount = try await getVideoFrameCount(at: file)
            estimatedFrames += frameCount
        }

        // Check already imported
        let existingState = try? await stateStore.loadState(for: .rewind)
        let alreadyImported = existingState?.processedVideoPaths.count ?? 0

        let dateRange: ClosedRange<Date>? = {
            guard let early = earliestDate, let late = latestDate else { return nil }
            return early...late
        }()

        let result = MigrationScanResult(
            source: .rewind,
            totalVideoFiles: videoFiles.count,
            totalSizeBytes: totalSize,
            estimatedFrameCount: estimatedFrames,
            dateRange: dateRange,
            alreadyImportedCount: alreadyImported
        )

        Log.info("Scan complete: \(videoFiles.count) videos, ~\(estimatedFrames) frames", category: .app)
        updateProgress(state: .idle)

        return result
    }

    public func startImport(delegate: MigrationDelegate?) async throws {
        guard !isCurrentlyImporting else {
            Log.warning("Import already in progress", category: .app)
            return
        }

        self.delegate = delegate
        isCurrentlyImporting = true
        shouldCancel = false
        shouldPause = false

        // Try to resume from existing state
        if let existingState = try? await stateStore.loadState(for: .rewind),
           existingState.progressState == .paused || existingState.progressState == .importing {
            self.state = existingState
            Log.info("Resuming import from checkpoint", category: .app)
        } else {
            self.state = MigrationState(source: .rewind)
        }

        state.progressState = .importing
        state.lastUpdatedAt = Date()
        if state.startedAt == state.lastUpdatedAt {
            // New import
        }

        do {
            try await performImport()
        } catch {
            state.progressState = .failed
            state.errorMessage = error.localizedDescription
            try? await stateStore.saveState(state)

            updateProgress(state: .failed)
            delegate?.migrationDidFail(error: error)
            isCurrentlyImporting = false
            throw error
        }

        isCurrentlyImporting = false
    }

    public func pauseImport() async {
        shouldPause = true
        Log.info("Pause requested", category: .app)
    }

    public func cancelImport() async {
        shouldCancel = true
        Log.info("Cancel requested", category: .app)
    }

    public func getState() async -> MigrationState {
        state
    }

    // MARK: - Private Implementation

    private func performImport() async throws {
        let chunksPath = getRewindChunksPath()
        let videoFiles = try findAllVideoFiles(in: chunksPath)
            .sorted { $0.path < $1.path } // Consistent ordering

        let totalVideos = videoFiles.count
        var videosProcessed = 0
        var totalFramesImported = state.totalFramesImported
        var totalFramesDeduplicated = state.totalFramesDeduplicated

        // Calculate total bytes for progress
        var totalBytes: Int64 = 0
        var bytesProcessed: Int64 = 0
        for file in videoFiles {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            totalBytes += (attrs[.size] as? Int64) ?? 0
        }

        updateProgress(
            state: .importing,
            totalVideos: totalVideos,
            totalFrames: 0, // Will update as we go
            totalBytes: totalBytes
        )

        let startTime = Date()

        for (index, videoFile) in videoFiles.enumerated() {
            // Check for pause/cancel
            if shouldCancel {
                state.progressState = .cancelled
                try await stateStore.saveState(state)
                updateProgress(state: .cancelled)
                throw MigrationError.cancelled
            }

            if shouldPause {
                state.progressState = .paused
                try await stateStore.saveState(state)
                updateProgress(state: .paused)
                Log.info("Import paused at video \(index + 1)/\(totalVideos)", category: .app)
                return
            }

            // Skip already processed files
            if state.processedVideoPaths.contains(videoFile.path) {
                videosProcessed += 1
                continue
            }

            delegate?.migrationDidStartProcessingVideo(
                at: videoFile.path,
                index: index + 1,
                total: totalVideos
            )

            do {
                let (imported, deduped) = try await processVideoFile(videoFile)
                totalFramesImported += imported
                totalFramesDeduplicated += deduped

                state.totalFramesImported = totalFramesImported
                state.totalFramesDeduplicated = totalFramesDeduplicated
                state.markVideoProcessed(videoFile.path)

                // Save checkpoint
                try await stateStore.saveState(state)

                delegate?.migrationDidFinishProcessingVideo(
                    at: videoFile.path,
                    framesImported: imported
                )

                Log.debug("Processed \(videoFile.lastPathComponent): \(imported) frames", category: .app)

            } catch {
                Log.error("Failed to process \(videoFile.lastPathComponent)", category: .app, error: error)
                delegate?.migrationDidFailProcessingVideo(at: videoFile.path, error: error)
                // Continue with next file instead of failing entire import
            }

            videosProcessed += 1

            // Update progress
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int64) ?? 0
            bytesProcessed += fileSize

            let elapsed = Date().timeIntervalSince(startTime)
            let rate = elapsed > 0 ? Double(videosProcessed) / elapsed : 0
            let remaining = rate > 0 ? Double(totalVideos - videosProcessed) / rate : nil

            currentProgress = MigrationProgress(
                state: .importing,
                source: .rewind,
                totalVideos: totalVideos,
                videosProcessed: videosProcessed,
                totalFrames: totalFramesImported + totalFramesDeduplicated,
                framesImported: totalFramesImported,
                framesDeduplicated: totalFramesDeduplicated,
                currentVideoPath: videoFile.path,
                bytesProcessed: bytesProcessed,
                totalBytes: totalBytes,
                startTime: startTime,
                estimatedSecondsRemaining: remaining
            )
            delegate?.migrationDidUpdateProgress(currentProgress)

            // Small delay to avoid hogging CPU
            try await Task.sleep(nanoseconds: batchDelayMs * 1_000_000)
        }

        // Complete!
        state.progressState = .completed
        try await stateStore.saveState(state)

        let duration = Date().timeIntervalSince(startTime)
        let result = MigrationResult(
            source: .rewind,
            success: true,
            videosProcessed: videosProcessed,
            framesImported: totalFramesImported,
            framesDeduplicated: totalFramesDeduplicated,
            durationSeconds: duration,
            errorMessage: nil,
            dateRange: nil // TODO: Calculate from imported data
        )

        updateProgress(state: .completed)
        delegate?.migrationDidComplete(result: result)

        Log.info("Import complete: \(totalFramesImported) frames in \(Int(duration))s", category: .app)
    }

    /// Process a single video file and import its frames
    private func processVideoFile(_ videoURL: URL) async throws -> (imported: Int, deduplicated: Int) {
        let asset = AVURLAsset(url: videoURL)

        // Get video properties
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MigrationError.videoReadError(path: videoURL.path, underlying: "No video track found")
        }

        let duration = try await asset.load(.duration)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(frameRate))

        // Get file creation date for timestamp calculation
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let creationDate = (fileAttrs[.creationDate] as? Date) ?? Date()

        // Calculate real-time duration this video represents
        // Each frame in Rewind was captured every 2 seconds real-time
        let realTimeDurationSeconds = Double(totalFrames) * rewindCaptureIntervalSeconds

        // Create image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var imported = 0
        var deduplicated = 0
        var previousImageHash: String?

        // Process each frame
        for frameIndex in 0..<totalFrames {
            // Calculate the time in the video for this frame
            let videoTime = CMTime(
                seconds: Double(frameIndex) / Double(frameRate),
                preferredTimescale: 600
            )

            // Calculate the real-world timestamp for this frame
            // Distribute frames evenly across the assumed real-time duration
            let realTimeOffset = (Double(frameIndex) / Double(max(1, totalFrames - 1))) * realTimeDurationSeconds
            let frameTimestamp = creationDate.addingTimeInterval(realTimeOffset)

            do {
                // Extract frame
                let cgImage = try generator.copyCGImage(at: videoTime, actualTime: nil)

                // Simple deduplication: compare image hash
                let imageHash = computeImageHash(cgImage)
                if imageHash == previousImageHash {
                    deduplicated += 1
                    continue
                }
                previousImageHash = imageHash

                // Convert to data for processing
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                guard let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    continue
                }

                // Create CapturedFrame for processing
                let capturedFrame = CapturedFrame(
                    timestamp: frameTimestamp,
                    imageData: pngData,
                    width: cgImage.width,
                    height: cgImage.height,
                    bytesPerRow: cgImage.bytesPerRow
                )

                // Run OCR
                let extractedText = try await processing.extractText(from: capturedFrame)

                // Create unique IDs
                let frameID = capturedFrame.id
                let segmentID = SegmentID() // Each Rewind video is its own segment

                // Insert frame into database
                let frameRef = FrameReference(
                    id: frameID,
                    timestamp: frameTimestamp,
                    segmentID: segmentID,
                    sessionID: nil,  // Rewind doesn't have session data
                    frameIndexInSegment: frameIndex,
                    metadata: extractedText.metadata,
                    source: .rewind
                )
                try await database.insertFrame(frameRef)

                // Insert text regions (OCR bounding boxes)
                for region in extractedText.regions {
                    try await database.insertTextRegion(region)
                }

                // Index text for search
                let document = IndexedDocument(
                    id: 0,  // Will be auto-assigned by DB
                    frameID: frameID,
                    timestamp: frameTimestamp,
                    content: extractedText.fullText,
                    appName: extractedText.metadata.appName,
                    windowTitle: extractedText.metadata.windowTitle,
                    browserURL: extractedText.metadata.browserURL
                )
                _ = try await database.insertDocument(document)

                imported += 1

                // Update checkpoint periodically
                if imported % batchSize == 0 {
                    state.updateCheckpoint(videoPath: videoURL.path, frameIndex: frameIndex)
                    try await stateStore.saveState(state)

                    // Yield to other tasks
                    try await Task.sleep(nanoseconds: batchDelayMs * 1_000_000)
                }

            } catch {
                Log.warning("Failed to extract frame \(frameIndex): \(error.localizedDescription)", category: .app)
                // Continue with next frame
            }
        }

        return (imported, deduplicated)
    }

    /// Compute a simple perceptual hash of an image for deduplication
    private func computeImageHash(_ image: CGImage) -> String {
        // Simplified hash: resize to 8x8, convert to grayscale, compute average
        // This is a basic perceptual hash - could be improved
        let size = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return UUID().uuidString // Fallback to unique hash
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else {
            return UUID().uuidString
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)
        var hash = ""
        let avg = (0..<(size * size)).reduce(0) { $0 + Int(pixels[$1]) } / (size * size)

        for i in 0..<(size * size) {
            hash += pixels[i] >= avg ? "1" : "0"
        }

        return hash
    }

    /// Get the path to Rewind's chunks directory
    private func getRewindChunksPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        return appSupport
            .appendingPathComponent("com.memoryvault.MemoryVault")
            .appendingPathComponent("chunks")
    }

    /// Find all MP4 files recursively in a directory
    private func findAllVideoFiles(in directory: URL) throws -> [URL] {
        var files: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "mp4" {
                files.append(url)
            }
        }

        return files
    }

    /// Get the frame count from a video file
    private func getVideoFrameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }

        let frameRate = try await track.load(.nominalFrameRate)
        return Int(CMTimeGetSeconds(duration) * Double(frameRate))
    }

    /// Update progress state and notify delegate
    private func updateProgress(
        state: MigrationProgressState,
        totalVideos: Int? = nil,
        totalFrames: Int? = nil,
        totalBytes: Int64? = nil
    ) {
        currentProgress = MigrationProgress(
            state: state,
            source: .rewind,
            totalVideos: totalVideos ?? currentProgress.totalVideos,
            videosProcessed: currentProgress.videosProcessed,
            totalFrames: totalFrames ?? currentProgress.totalFrames,
            framesImported: currentProgress.framesImported,
            framesDeduplicated: currentProgress.framesDeduplicated,
            currentVideoPath: currentProgress.currentVideoPath,
            bytesProcessed: currentProgress.bytesProcessed,
            totalBytes: totalBytes ?? currentProgress.totalBytes,
            startTime: currentProgress.startTime,
            estimatedSecondsRemaining: currentProgress.estimatedSecondsRemaining
        )
        delegate?.migrationDidUpdateProgress(currentProgress)
    }
}
