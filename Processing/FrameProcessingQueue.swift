import Foundation
import Shared
import Database
import Storage
import Search
import AppKit

/// Asynchronous frame processing queue with SQLite-backed durability
///
/// Features:
/// - Durable queue (survives app restarts)
/// - Concurrent worker pool for OCR processing
/// - Automatic retry on failure
/// - Backpressure monitoring
public actor FrameProcessingQueue {

    // MARK: - Properties

    private let databaseManager: DatabaseManager
    private let storage: StorageProtocol
    private let processing: ProcessingProtocol
    private let search: SearchProtocol

    private let config: ProcessingQueueConfig
    private var workers: [Task<Void, Never>] = []
    private var isRunning = false

    // Statistics
    private var totalProcessed: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0
    private var pendingCount: Int = 0      // Frames with status 0
    private var processingCount: Int = 0   // Frames with status 1

    // Frame data cache - stores raw captured frames to avoid B-frame timing issues
    // When a frame is enqueued with its CapturedFrame data, we cache it here.
    // Workers use cached data directly instead of extracting from video.
    // This bypasses B-frame reordering issues in fragmented MP4s.
    private var frameDataCache: [Int64: CapturedFrame] = [:]

    // Maximum number of frames to keep in cache to prevent unbounded memory growth
    // Each CapturedFrame is ~10-30MB, so 50 frames = 500MB-1.5GB max
    // If processing falls behind, oldest frames will be evicted
    private let maxFrameDataCacheSize = 50

    // MARK: - Power-Aware Processing Control

    /// Whether OCR processing is enabled globally
    private var ocrEnabled = true

    /// Whether to pause OCR when on battery power
    private var pauseOnBattery = false

    /// Current power source (updated by AppCoordinator)
    private var currentPowerSource: PowerStateMonitor.PowerSource = .unknown

    /// Whether currently paused due to battery (computed from pauseOnBattery && currentPowerSource)
    private var isPausedForBattery: Bool {
        pauseOnBattery && currentPowerSource == .battery
    }

    /// Minimum delay between processing frames (for rate limiting)
    /// 0 = no delay (unlimited), otherwise nanoseconds between frames
    private var minDelayBetweenFramesNs: UInt64 = 0

    /// Task priority for worker tasks
    private var workerPriority: TaskPriority = .utility

    /// Bundle IDs to exclude from OCR (when ocrAppFilterMode == .allExceptTheseApps)
    private var ocrExcludedBundleIDs: Set<String> = []

    /// Bundle IDs to include for OCR (when ocrAppFilterMode == .onlyTheseApps)
    /// Empty set means all apps (default behavior)
    private var ocrIncludedBundleIDs: Set<String> = []

    /// Whether we're in deferred mode (pauseOnBattery is enabled)
    /// In deferred mode, we don't cache raw frames and must wait for video finalization
    private var isDeferredMode: Bool {
        pauseOnBattery
    }

    /// Reduced cache size when in deferred mode (raw frames won't be used)
    private let deferredModeCacheSize = 4

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageProtocol,
        processing: ProcessingProtocol,
        search: SearchProtocol,
        config: ProcessingQueueConfig = .default
    ) {
        self.databaseManager = database
        self.storage = storage
        self.processing = processing
        self.search = search
        self.config = config
    }

    // MARK: - Power Configuration

    /// Update power-aware processing configuration
    /// Called by AppCoordinator when power state or settings change
    public func updatePowerConfig(
        ocrEnabled: Bool,
        pauseOnBattery: Bool,
        currentPowerSource: PowerStateMonitor.PowerSource,
        maxFPS: Double,
        workerCount: Int,
        taskPriority: TaskPriority,
        excludedBundleIDs: Set<String>,
        includedBundleIDs: Set<String>
    ) {
        self.ocrEnabled = ocrEnabled
        self.pauseOnBattery = pauseOnBattery
        self.currentPowerSource = currentPowerSource
        self.ocrExcludedBundleIDs = excludedBundleIDs
        self.ocrIncludedBundleIDs = includedBundleIDs

        // Convert FPS to nanosecond delay (0 = unlimited)
        if maxFPS > 0 {
            self.minDelayBetweenFramesNs = UInt64(1_000_000_000.0 / maxFPS)
        } else {
            self.minDelayBetweenFramesNs = 0
        }

        // Update priority and restart workers if priority changed
        let priorityChanged = self.workerPriority != taskPriority
        self.workerPriority = taskPriority

        // Adjust worker count or restart if priority changed
        if isRunning {
            if priorityChanged {
                // Must restart all workers to apply new priority
                restartWorkers(count: workerCount)
            } else if workers.count != workerCount {
                adjustWorkerCount(to: workerCount)
            }
        }

        Log.info("[Queue] Power config updated: ocrEnabled=\(ocrEnabled), pauseOnBattery=\(pauseOnBattery), power=\(currentPowerSource), maxFPS=\(maxFPS), workers=\(workers.count), priority=\(taskPriority), paused=\(isPausedForBattery)", category: .processing)
    }

    /// Adjust the number of running workers to the desired count
    private func adjustWorkerCount(to desired: Int) {
        let current = workers.count
        if desired > current {
            // Spawn additional workers
            for workerID in current..<desired {
                let priority = workerPriority
                let task = Task(priority: priority) {
                    await runWorker(id: workerID)
                }
                workers.append(task)
            }
            Log.info("[Queue] Scaled up workers: \(current) → \(desired)", category: .processing)
        } else if desired < current {
            // Cancel excess workers from the end
            for _ in desired..<current {
                workers.removeLast().cancel()
            }
            Log.info("[Queue] Scaled down workers: \(current) → \(desired)", category: .processing)
        }
    }

    /// Restart all workers with current priority and desired count
    private func restartWorkers(count: Int) {
        // Cancel all existing workers
        for worker in workers {
            worker.cancel()
        }
        workers.removeAll()

        // Spawn new workers with updated priority
        let priority = workerPriority
        for workerID in 0..<count {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }
        Log.info("[Queue] Restarted \(count) workers with priority \(priority)", category: .processing)
    }

    /// Check if OCR should be processed for a specific bundle ID
    private func shouldProcessOCR(forBundleID bundleID: String?) -> Bool {
        guard let bundleID = bundleID else {
            Log.debug("[Queue-Filter] bundleID is nil, allowing OCR", category: .processing)
            return true
        }

        // If inclusion list is set (onlyTheseApps mode), only process those apps
        if !ocrIncludedBundleIDs.isEmpty {
            let allowed = ocrIncludedBundleIDs.contains(bundleID)
            Log.debug("[Queue-Filter] Include mode: bundleID=\(bundleID), allowed=\(allowed), includedApps=\(ocrIncludedBundleIDs)", category: .processing)
            return allowed
        }

        // Otherwise, process all except excluded apps
        let allowed = !ocrExcludedBundleIDs.contains(bundleID)
        if !ocrExcludedBundleIDs.isEmpty {
            Log.debug("[Queue-Filter] Exclude mode: bundleID=\(bundleID), allowed=\(allowed), excludedApps=\(ocrExcludedBundleIDs)", category: .processing)
        }
        return allowed
    }

    // MARK: - Queue Operations

    /// Enqueue a frame for processing
    /// - Parameters:
    ///   - frameID: The database ID of the frame
    ///   - priority: Processing priority (higher = processed first)
    ///   - capturedFrame: Optional raw frame data. If provided, OCR uses this directly
    ///                    instead of extracting from video, avoiding B-frame timing issues.
    ///                    In deferred mode (pauseOnBattery enabled), raw frames are NOT cached
    ///                    since we'll extract from finalized video later.
    public func enqueue(frameID: Int64, priority: Int = 0, capturedFrame: CapturedFrame? = nil) async throws {
        // Log.info("[Queue-DIAG] Attempting to enqueue frame \(frameID) with priority \(priority), hasFrameData: \(capturedFrame != nil)", category: .processing)

        // In deferred mode, don't cache raw frames - we'll extract from encoded video later
        // This saves memory when OCR is deferred until plugged in
        let effectiveCacheSize = isDeferredMode ? deferredModeCacheSize : maxFrameDataCacheSize

        // Cache the frame data if provided and not in deferred mode (or cache not full in deferred mode)
        if let frame = capturedFrame {
            // Evict oldest frames if cache is at capacity to prevent unbounded memory growth
            // This can happen if OCR processing falls behind the capture rate
            if frameDataCache.count >= effectiveCacheSize {
                // Remove oldest entries (lowest frame IDs, since IDs are sequential)
                let sortedKeys = frameDataCache.keys.sorted()
                let keysToRemove = sortedKeys.prefix(frameDataCache.count - effectiveCacheSize + 1)
                for key in keysToRemove {
                    frameDataCache.removeValue(forKey: key)
                }
                if !isDeferredMode {
                    Log.warning("[Queue-DIAG] Frame data cache at capacity (\(effectiveCacheSize)), evicted \(keysToRemove.count) oldest frames", category: .processing)
                }
            }

            frameDataCache[frameID] = frame
            // Log.debug("[Queue-DIAG] Cached frame data for frameID \(frameID), cache size: \(frameDataCache.count)", category: .processing)
        }

        try await databaseManager.enqueueFrameForProcessing(frameID: frameID, priority: priority)
        currentQueueDepth += 1
        // Log.info("[Queue-DIAG] Successfully enqueued frame \(frameID), local depth: \(currentQueueDepth), isRunning: \(isRunning)", category: .processing)
    }

    /// Enqueue multiple frames (batch operation)
    public func enqueueBatch(frameIDs: [Int64], priority: Int = 0) async throws {
        for frameID in frameIDs {
            try await enqueue(frameID: frameID, priority: priority)
        }
    }

    /// Dequeue the next frame for processing
    private func dequeue() async throws -> QueuedFrame? {
        guard let result = try await databaseManager.dequeueFrameForProcessing() else {
            return nil // Queue empty
        }
        currentQueueDepth -= 1
        return QueuedFrame(queueID: result.queueID, frameID: result.frameID, retryCount: result.retryCount)
    }

    /// Get current queue depth
    public func getQueueDepth() async throws -> Int {
        return try await databaseManager.getProcessingQueueDepth()
    }

    // MARK: - Worker Pool

    /// Start processing workers
    public func startWorkers() async {
        guard !isRunning else {
            // Log.warning("[Queue-DIAG] Workers already running, skipping startWorkers()", category: .processing)
            return
        }

        isRunning = true

        // Initialize counts from actual frame statuses
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pendingCount = counts.pending
            processingCount = counts.processing
            currentQueueDepth = counts.pending + counts.processing
        }

        // Log.info("[Queue-DIAG] Starting \(config.workerCount) processing workers, isRunning=\(isRunning)", category: .processing)

        let priority = workerPriority
        for workerID in 0..<config.workerCount {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
            // Log.info("[Queue-DIAG] Worker \(workerID) task created", category: .processing)
        }
        // Log.info("[Queue-DIAG] All \(workers.count) worker tasks created", category: .processing)
    }

    /// Stop processing workers
    public func stopWorkers() async {
        guard isRunning else { return }

        isRunning = false

        Log.info("[Queue] Stopping workers...", category: .processing)

        for worker in workers {
            worker.cancel()
        }

        workers.removeAll()

        Log.info("[Queue] Workers stopped", category: .processing)
    }

    /// Worker loop - processes frames from queue
    private func runWorker(id: Int) async {
        Log.info("[Queue] Worker \(id) STARTED (total workers: \(workers.count))", category: .processing)

        // Initial delay to ensure database is fully stable
        // This prevents race conditions on first launch after onboarding
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms - increased for stability

        while isRunning && !Task.isCancelled {
            // Check if OCR is disabled globally
            guard ocrEnabled else {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s poll when disabled
                if Task.isCancelled { break }
                continue
            }

            // Check if paused due to battery power
            guard !isPausedForBattery else {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s poll when paused for battery
                if Task.isCancelled { break }
                continue
            }

            // Wait for database to be ready before attempting any operations
            guard await databaseManager.isReady() else {
                // Log.debug("[Queue-DIAG] Worker \(id) waiting for database to be ready", category: .processing)
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                if Task.isCancelled { break }
                continue
            }

            do {
                // Try to dequeue a frame
                guard let queuedFrame = try await dequeue() else {
                    // Queue empty - wait before polling again
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }

                // Log.info("[Queue-DIAG] Worker \(id) dequeued frame \(queuedFrame.frameID) for processing", category: .processing)

                // Process the frame
                let startTime = Date()
                do {
                    let result = try await processFrame(queuedFrame)

                    // Handle deferred processing result
                    if case .deferredNotFinalized = result {
                        // Frame's video not finalized yet - re-enqueue for later
                        try await databaseManager.enqueueFrameForProcessing(frameID: queuedFrame.frameID, priority: -1)
                        currentQueueDepth += 1
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms before next attempt
                        continue
                    }

                    totalProcessed += 1

                    let elapsed = Date().timeIntervalSince(startTime)
                    Log.info("[Queue-DIAG] Worker \(id) COMPLETED frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", category: .processing)

                    // Apply rate limiting delay after successful processing
                    if minDelayBetweenFramesNs > 0 {
                        try? await Task.sleep(nanoseconds: minDelayBetweenFramesNs)
                    }

                } catch {
                    totalFailed += 1

                    // Check if this is an unrecoverable error (damaged/missing video file)
                    // These errors won't be fixed by retrying, so fail immediately
                    let isUnrecoverableError = isUnrecoverableVideoError(error)

                    if isUnrecoverableError {
                        // Expected for frames still being written - use warning, not error
                        Log.warning("[Queue] Frame \(queuedFrame.frameID) skipped (video not ready)", category: .processing)
                        try await markFrameAsFailed(queuedFrame.frameID, error: error, skipRetries: true)
                    } else if queuedFrame.retryCount < config.maxRetryAttempts {
                        // Retry if under limit for recoverable errors
                        try await retryFrame(queuedFrame, error: error)
                    } else {
                        // Mark as failed permanently
                        try await markFrameAsFailed(queuedFrame.frameID, error: error)
                    }
                }

            } catch is CancellationError {
                Log.debug("[Queue] Worker \(id) cancelled", category: .processing)
                break
            } catch {
                Log.error("[Queue-DIAG] Worker \(id) error: \(error)", category: .processing)
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s backoff
            }
        }

        Log.debug("[Queue] Worker \(id) stopped", category: .processing)
    }

    // MARK: - Frame Processing

    /// Process a single frame (OCR + FTS + Nodes)
    /// Returns ProcessFrameResult indicating success, skip, or deferral
    private func processFrame(_ queuedFrame: QueuedFrame) async throws -> ProcessFrameResult {
        let frameID = queuedFrame.frameID
        let t0 = CFAbsoluteTimeGetCurrent()

        // Get frame with video info (includes isVideoFinalized and bundleID in metadata)
        guard let frameWithInfo = try await databaseManager.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
            Log.error("[Queue-DIAG] Frame \(frameID) not found in database!", category: .processing)
            throw DatabaseError.queryFailed(query: "getFrame", underlying: "Frame \(frameID) not found")
        }
        let frameRef = frameWithInfo.frame

        // Check app filter - skip OCR for excluded apps (bundleID is in metadata from JOIN)
        let bundleID = frameRef.metadata.appBundleID
        if !shouldProcessOCR(forBundleID: bundleID) {
            // Mark as completed (no OCR needed for this app)
            try await updateFrameProcessingStatus(frameID, status: .completed)
            Log.debug("[Queue] Frame \(frameID) skipped - app \(bundleID ?? "unknown") excluded from OCR", category: .processing)
            return .skippedByAppFilter
        }

        // In deferred mode (no cached frame data), check if video is finalized
        // We need presentation-order frames, which requires finalized video
        let hasCachedFrame = frameDataCache[frameID] != nil
        if !hasCachedFrame, let videoInfo = frameWithInfo.videoInfo, !videoInfo.isVideoFinalized {
            // Video not finalized yet - defer processing until it is
            // Don't mark status, leave as pending so it gets re-queued
            Log.debug("[Queue] Frame \(frameID) deferred - video not finalized yet", category: .processing)
            return .deferredNotFinalized
        }

        // Mark as processing
        try await updateFrameProcessingStatus(frameID, status: .processing)

        // Get video segment for dimensions (needed for node insertion)
        guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
            Log.error("[Queue-DIAG] Video segment \(frameRef.videoID.value) not found!", category: .processing)
            throw DatabaseError.queryFailed(query: "getVideoSegment", underlying: "Video segment \(frameRef.videoID) not found")
        }

        // CRITICAL: Verify video file exists before attempting any extraction
        // This prevents infinite retry loops when database points to missing files
        let storageRoot = await storage.getStorageDirectory()
        let videoFullPath = storageRoot.appendingPathComponent(videoSegment.relativePath).path
        if !FileManager.default.fileExists(atPath: videoFullPath) {
            Log.error("[Queue] Video file not found for frame \(frameID): \(videoFullPath)", category: .processing)
            Log.error("[Queue] This suggests database/storage path mismatch. Check AppPaths.storageRoot setting.", category: .processing)

            // Mark as failed permanently - don't retry endlessly for missing files
            try await updateFrameProcessingStatus(frameID, status: .failed)
            return .success // Return success to not re-queue (it's a permanent failure)
        }

        let tPrep = CFAbsoluteTimeGetCurrent()

        // Check if we have cached frame data (avoids B-frame timing issues)
        let capturedFrame: CapturedFrame
        if let cachedFrame = frameDataCache[frameID] {
            // Use cached frame data directly - guaranteed correct
            capturedFrame = cachedFrame
            frameDataCache.removeValue(forKey: frameID)  // Clear from cache after use
        } else {
            // Fallback: extract from video (used for deferred mode, reprocessOCR, or crash recovery)
            // At this point we've verified the video is finalized, so presentation order is correct

            // Extract the actual segment ID from the path (last path component is the timestamp-based ID)
            let pathComponents = videoSegment.relativePath.split(separator: "/")
            guard let lastComponent = pathComponents.last,
                  let actualSegmentID = Int64(lastComponent) else {
                Log.error("[Queue-DIAG] Invalid video path for frame \(frameID): \(videoSegment.relativePath)", category: .processing)
                throw ProcessingError.invalidVideoPath(path: videoSegment.relativePath)
            }

            // Load frame image from video using the actual segment ID from the filename
            let frameData = try await storage.readFrame(
                segmentID: VideoSegmentID(value: actualSegmentID),
                frameIndex: frameRef.frameIndexInSegment
            )

            // Convert JPEG data to CapturedFrame for OCR
            guard let convertedFrame = try convertJPEGToCapturedFrame(frameData, frameRef: frameRef) else {
                Log.error("[Queue-DIAG] Frame \(frameID) image conversion failed!", category: .processing)
                throw ProcessingError.imageConversionFailed
            }
            capturedFrame = convertedFrame
        }

        let tFrame = CFAbsoluteTimeGetCurrent()

        // Run OCR
        let extractedText = try await processing.extractText(from: capturedFrame)

        let tOCR = CFAbsoluteTimeGetCurrent()

        // Index in FTS
        let docid = try await search.index(
            text: extractedText,
            segmentId: frameRef.segmentID.value,
            frameId: frameID
        )

        // Insert OCR nodes
        if docid > 0 && !extractedText.regions.isEmpty {
            // Delete any existing nodes first to prevent duplicates
            // (can happen if frame is reprocessed without going through reprocessOCR)
            try await databaseManager.deleteNodes(frameID: FrameID(value: frameID))

            var currentOffset = 0
            var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []

            for region in extractedText.regions {
                let textLength = region.text.count
                nodeData.append((
                    textOffset: currentOffset,
                    textLength: textLength,
                    bounds: region.bounds,
                    windowIndex: nil
                ))
                currentOffset += textLength + 1
            }

            // Use videoSegment we already fetched above (no redundant query)
            try await databaseManager.insertNodes(
                frameID: FrameID(value: frameID),
                nodes: nodeData,
                frameWidth: videoSegment.width,
                frameHeight: videoSegment.height
            )
        }

        // Mark as completed
        try await updateFrameProcessingStatus(frameID, status: .completed)

        let tDone = CFAbsoluteTimeGetCurrent()
        Log.info("[Queue-TIMING] Frame \(frameID): prep=\(String(format: "%.0f", (tPrep-t0)*1000))ms frame=\(String(format: "%.0f", (tFrame-tPrep)*1000))ms ocr=\(String(format: "%.0f", (tOCR-tFrame)*1000))ms index=\(String(format: "%.0f", (tDone-tOCR)*1000))ms total=\(String(format: "%.0f", (tDone-t0)*1000))ms size=\(capturedFrame.width)x\(capturedFrame.height)", category: .processing)

        return .success
    }

    /// Convert JPEG data back to CapturedFrame for OCR
    private func convertJPEGToCapturedFrame(_ jpegData: Data, frameRef: FrameReference) throws -> CapturedFrame? {
        guard let nsImage = NSImage(data: jpegData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        // Create BGRA bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        var pixelData = Data(count: bytesPerRow * height)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return CapturedFrame(
            timestamp: frameRef.timestamp,
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: frameRef.metadata
        )
    }

    // MARK: - Status Management

    /// Update frame processing status
    private func updateFrameProcessingStatus(_ frameID: Int64, status: FrameProcessingStatus) async throws {
        try await databaseManager.updateFrameProcessingStatus(frameID: frameID, status: status.rawValue)
    }

    /// Retry a failed frame
    private func retryFrame(_ queuedFrame: QueuedFrame, error: Error) async throws {
        // Reset status to pending so it can be dequeued again
        try await updateFrameProcessingStatus(queuedFrame.frameID, status: .pending)
        try await databaseManager.retryFrameProcessing(
            frameID: queuedFrame.frameID,
            retryCount: queuedFrame.retryCount + 1,
            errorMessage: error.localizedDescription
        )
        Log.warning("[Queue] Retrying frame \(queuedFrame.frameID), attempt \(queuedFrame.retryCount + 1)", category: .processing)
    }

    /// Mark frame as permanently failed, or delete if truly unrecoverable
    /// SAFETY: Only deletes frames after verifying the video is genuinely unrecoverable
    private func markFrameAsFailed(_ frameID: Int64, error: Error, skipRetries: Bool = false) async throws {
        if skipRetries {
            // Potential unrecoverable video error - verify before deleting
            let shouldDelete = await verifyFrameIsUnrecoverable(frameID: frameID, error: error)

            if shouldDelete {
                try await databaseManager.deleteFrame(id: FrameID(value: frameID))
                Log.warning("[Queue] Frame \(frameID) deleted (verified unrecoverable)", category: .processing)
            } else {
                // Not confirmed unrecoverable - mark as failed instead of deleting
                try await updateFrameProcessingStatus(frameID, status: .failed)
                Log.warning("[Queue] Frame \(frameID) marked as failed (deletion skipped - could not verify unrecoverable)", category: .processing)
            }
        } else {
            // Actual processing failure after retries - mark as failed
            try await updateFrameProcessingStatus(frameID, status: .failed)
            Log.error("[Queue] Frame \(frameID) marked as failed after max retries: \(error)", category: .processing)
        }
    }

    /// Verify a frame is truly unrecoverable before deletion
    /// Returns true only if we're certain the video data cannot be recovered
    private func verifyFrameIsUnrecoverable(frameID: Int64, error: Error) async -> Bool {
        let errorDesc = error.localizedDescription

        // SAFETY CHECK 1: Only delete for specific known-unrecoverable error types
        let isKnownUnrecoverableError =
            errorDesc.contains("Frame index") && errorDesc.contains("out of range") ||  // Frame index doesn't exist in video
            errorDesc.contains("Video file is empty")  // 0-byte video file

        guard isKnownUnrecoverableError else {
            return false
        }

        // SAFETY CHECK 2: Verify the frame actually exists and get its video info
        guard let frameRef = try? await databaseManager.getFrame(id: FrameID(value: frameID)) else {
            return false
        }

        // SAFETY CHECK 3: Verify the video segment exists in DB
        guard let videoSegment = try? await databaseManager.getVideoSegment(id: frameRef.videoID) else {
            return true  // Video record doesn't exist, frame is orphaned
        }

        // SAFETY CHECK 4: Extract segment ID and verify file state
        let pathComponents = videoSegment.relativePath.split(separator: "/")
        guard let lastComponent = pathComponents.last,
              let _ = Int64(lastComponent) else {
            return false
        }

        // SAFETY CHECK 5: For "frame index out of range" - verify the video has fewer frames than expected
        if errorDesc.contains("Frame index") && errorDesc.contains("out of range") {
            // The error message format is: "Frame index X out of range (0..<Y)"
            // We've already failed to read this frame, so we know it's out of range
            return true
        }

        // SAFETY CHECK 6: For "empty file" - verify file is actually 0 bytes
        if errorDesc.contains("Video file is empty") {
            if let exists = try? await storage.segmentExists(id: VideoSegmentID(value: Int64(pathComponents.last!)!)), !exists {
                return true
            }
            // File exists but we got empty error - this is suspicious, don't delete
            return false
        }

        return false
    }

    /// Re-enqueue frames that were processing during a crash
    /// Only re-enqueues frames whose video files are readable (finalized)
    public func requeueCrashedFrames() async throws {
        let frameIDs = try await databaseManager.getCrashedProcessingFrameIDs()

        guard !frameIDs.isEmpty else {
            return
        }

        Log.warning("[Queue] Found \(frameIDs.count) frames that crashed during processing, verifying video files...", category: .processing)

        var validFrameIDs: [Int64] = []
        var invalidFrameIDs: [Int64] = []

        for frameID in frameIDs {
            // Get the frame reference to find its video segment
            guard let frameRef = try await databaseManager.getFrame(id: FrameID(value: frameID)) else {
                Log.warning("[Queue] Crashed frame \(frameID) not found in database, marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Get the video segment to check if the file is readable
            guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
                Log.warning("[Queue] Video segment \(frameRef.videoID.value) not found for crashed frame \(frameID), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Check if the video file exists and is readable
            // Extract the actual segment ID from the path (last path component is the timestamp-based ID)
            let pathComponents = videoSegment.relativePath.split(separator: "/")
            guard let lastComponent = pathComponents.last,
                  let actualSegmentID = Int64(lastComponent) else {
                Log.warning("[Queue] Invalid video path for crashed frame \(frameID): \(videoSegment.relativePath), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Try to verify the video file exists and is accessible
            let videoExists = try await storage.segmentExists(id: VideoSegmentID(value: actualSegmentID))

            if !videoExists {
                Log.warning("[Queue] Video file missing for crashed frame \(frameID) (segment \(actualSegmentID)), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            validFrameIDs.append(frameID)
        }

        // Mark invalid frames as failed (they can't be processed without valid video)
        for frameID in invalidFrameIDs {
            try await updateFrameProcessingStatus(frameID, status: .failed)
        }

        if !invalidFrameIDs.isEmpty {
            Log.warning("[Queue] Marked \(invalidFrameIDs.count) crashed frames as failed (video files missing/unreadable)", category: .processing)
        }

        if !validFrameIDs.isEmpty {
            // Reset valid crashed frames back to pending status before re-enqueueing
            for frameID in validFrameIDs {
                try await updateFrameProcessingStatus(frameID, status: .pending)
            }
            Log.info("[Queue] Reset \(validFrameIDs.count) crashed frames to pending status", category: .processing)

            Log.info("[Queue] Re-enqueueing \(validFrameIDs.count) crashed frames with valid video files", category: .processing)
            try await enqueueBatch(frameIDs: validFrameIDs)
        }
    }

    /// Check if an error indicates an unrecoverable video file issue
    /// These errors (damaged/missing files) won't be fixed by retrying
    private func isUnrecoverableVideoError(_ error: Error) -> Bool {
        let errorDescription = error.localizedDescription.lowercased()
        let nsError = error as NSError

        // AVFoundation error codes for damaged/unreadable media
        // -11829 = AVErrorFileFormatNotRecognized / Cannot Open
        // -12848 = NSOSStatusErrorDomain - file format issue
        if nsError.domain == "AVFoundationErrorDomain" && nsError.code == -11829 {
            return true
        }

        // NSCocoaErrorDomain Code=516 = file already exists (temp symlink conflict)
        // This happens when multiple workers try to extract from same video simultaneously
        // Retrying won't help - need to fix the temp file handling, but don't spam retries
        if nsError.domain == "NSCocoaErrorDomain" && nsError.code == 516 {
            return true
        }

        // Check error message for common indicators
        if errorDescription.contains("cannot open") ||
           errorDescription.contains("media may be damaged") ||
           errorDescription.contains("file not found") ||
           errorDescription.contains("no such file") ||
           errorDescription.contains("file with the same name already exists") {
            return true
        }

        // Check for StorageError.fileNotFound
        if let storageError = error as? StorageError {
            switch storageError {
            case .fileNotFound, .fileReadFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    // MARK: - Statistics

    public func getStatistics() async -> QueueStatistics {
        // Query live counts from database for accuracy
        var pending = pendingCount
        var processing = processingCount
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pending = counts.pending
            processing = counts.processing
        }

        return QueueStatistics(
            queueDepth: pending + processing,
            pendingCount: pending,
            processingCount: processing,
            totalProcessed: totalProcessed,
            totalFailed: totalFailed,
            workerCount: workers.count
        )
    }
}

// MARK: - Models

public struct ProcessingQueueConfig: Sendable {
    public let workerCount: Int
    public let maxRetryAttempts: Int
    public let maxQueueSize: Int

    public init(workerCount: Int = 1, maxRetryAttempts: Int = 3, maxQueueSize: Int = 1000) {
        self.workerCount = workerCount
        self.maxRetryAttempts = maxRetryAttempts
        self.maxQueueSize = maxQueueSize
    }

    public static let `default` = ProcessingQueueConfig()
}

private struct QueuedFrame {
    let queueID: Int64
    let frameID: Int64
    let retryCount: Int
}

public enum FrameProcessingStatus: Int, Sendable {
    case pending = 0
    case processing = 1
    case completed = 2
    case failed = 3
    // Note: 4 = "not yet readable" (used elsewhere, don't add new values here)
}

/// Internal result of processing a frame
private enum ProcessFrameResult {
    case success
    case skippedByAppFilter      // Frame skipped due to app filter, mark as completed (no OCR)
    case deferredNotFinalized    // Video not finalized yet, re-queue for later
}

public struct QueueStatistics: Sendable {
    public let queueDepth: Int
    public let pendingCount: Int      // Frames waiting in queue (status 0)
    public let processingCount: Int   // Frames currently being processed (status 1)
    public let totalProcessed: Int
    public let totalFailed: Int
    public let workerCount: Int
}
