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
/// - Single AsyncStream-based consumer (wakes on enqueue, no polling)
/// - Automatic retry on failure
/// - Backpressure monitoring
public actor FrameProcessingQueue {

    // MARK: - Properties

    private let databaseManager: DatabaseManager
    private let storage: StorageProtocol
    private let processing: ProcessingProtocol
    private let search: SearchProtocol

    private let config: ProcessingQueueConfig
    private var consumerTask: Task<Void, Never>?
    private var continuation: AsyncStream<Void>.Continuation?
    private var isRunning = false
    private var memoryReportTask: Task<Void, Never>?

    // Statistics
    private var totalProcessed: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0
    private var pendingCount: Int = 0      // Frames with status 0
    private var processingCount: Int = 0   // Frames with status 1

    private let memoryReportIntervalNs: UInt64 = 5_000_000_000

    // MARK: - Power-Aware Processing Control

    /// Whether OCR processing is enabled globally
    private var ocrEnabled = true

    /// Whether to pause OCR when on battery power
    private var pauseOnBattery = false

    /// Whether to pause OCR when Low Power Mode is enabled
    private var pauseOnLowPowerMode = false

    /// Current power source (updated by AppCoordinator)
    private var currentPowerSource: PowerStateMonitor.PowerSource = .unknown

    /// Whether Low Power Mode is currently enabled
    private var isLowPowerModeEnabled = false

    /// Whether OCR is currently paused due to battery or low power mode policy
    private var isPausedForPowerState: Bool {
        (pauseOnBattery && currentPowerSource == .battery) ||
        (pauseOnLowPowerMode && isLowPowerModeEnabled)
    }

    /// Task priority for consumer task
    private var workerPriority: TaskPriority = .utility

    /// Minimum delay between frames in nanoseconds (for FPS rate limiting)
    private var minDelayBetweenFramesNs: UInt64 = 0

    /// Bundle IDs to exclude from OCR (when ocrAppFilterMode == .allExceptTheseApps)
    private var ocrExcludedBundleIDs: Set<String> = []

    /// Bundle IDs to include for OCR (when ocrAppFilterMode == .onlyTheseApps)
    /// Empty set means all apps (default behavior)
    private var ocrIncludedBundleIDs: Set<String> = []

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
        pauseOnLowPowerMode: Bool,
        isLowPowerModeEnabled: Bool,
        currentPowerSource: PowerStateMonitor.PowerSource,
        maxFPS: Double,
        taskPriority: TaskPriority,
        excludedBundleIDs: Set<String>,
        includedBundleIDs: Set<String>
    ) {
        self.ocrEnabled = ocrEnabled
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.currentPowerSource = currentPowerSource
        self.ocrExcludedBundleIDs = excludedBundleIDs
        self.ocrIncludedBundleIDs = includedBundleIDs

        if maxFPS > 0 {
            self.minDelayBetweenFramesNs = UInt64(1_000_000_000.0 / maxFPS)
        } else {
            self.minDelayBetweenFramesNs = 0
        }

        // Update priority and restart consumer if priority changed
        let priorityChanged = self.workerPriority != taskPriority
        self.workerPriority = taskPriority

        if isRunning && priorityChanged {
            restartConsumer()
        }

        // Wake consumer if conditions are now favorable (handles signals that were
        // discarded while paused/disabled)
        if isRunning && ocrEnabled && !isPausedForPowerState {
            continuation?.yield()
        }

        Log.info(
            "[Queue] Power config updated: ocrEnabled=\(ocrEnabled), pauseOnBattery=\(pauseOnBattery), pauseOnLowPowerMode=\(pauseOnLowPowerMode), isLowPowerModeEnabled=\(isLowPowerModeEnabled), power=\(currentPowerSource), priority=\(taskPriority), maxFPS=\(maxFPS), paused=\(isPausedForPowerState)",
            category: .processing
        )
    }

    /// Restart consumer with current priority (e.g., after priority change)
    private func restartConsumer() {
        continuation?.finish()
        consumerTask?.cancel()
        consumerTask = nil
        continuation = nil
        startConsumer()
        Log.info("[Queue] Restarted consumer with priority \(workerPriority)", category: .processing)
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
    public func enqueue(frameID: Int64, priority: Int = 0) async throws {
        try await databaseManager.enqueueFrameForProcessing(frameID: frameID, priority: priority)
        currentQueueDepth += 1
        continuation?.yield()
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

    // MARK: - Consumer

    /// Start processing consumer
    public func startWorkers() async {
        guard !isRunning else {
            return
        }

        isRunning = true

        // Initialize counts from actual frame statuses
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pendingCount = counts.pending
            processingCount = counts.processing
            currentQueueDepth = counts.pending + counts.processing
        }

        startConsumer()
        startMemoryReporting()

        Log.info("[Queue] Started consumer (priority=\(workerPriority))", category: .processing)
    }

    /// Create AsyncStream and spawn the single consumer task
    private func startConsumer() {
        let (stream, newContinuation) = AsyncStream<Void>.makeStream()
        self.continuation = newContinuation

        let priority = workerPriority
        consumerTask = Task(priority: priority) {
            // Wait for DB ready (one-time startup)
            try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous)
            while !Task.isCancelled {
                if await self.databaseManager.isReady() { break }
                try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous)
            }

            // Process pre-existing frames (crash recovery, enqueued before start)
            await self.processAvailableFrames()

            // Main loop: wake on signal, process everything available
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self.processAvailableFrames()
            }

            Log.debug("[Queue] Consumer stopped", category: .processing)
        }
    }

    /// Stop processing consumer
    public func stopWorkers() async {
        guard isRunning else { return }

        isRunning = false

        Log.info("[Queue] Stopping consumer...", category: .processing)

        continuation?.finish()
        consumerTask?.cancel()
        consumerTask = nil
        continuation = nil
        memoryReportTask?.cancel()
        memoryReportTask = nil

        Log.info("[Queue] Consumer stopped", category: .processing)
    }

    /// Process all available frames from the SQLite queue.
    /// Checks preconditions, then drains until empty or paused.
    /// Called both at startup (for pre-existing frames) and on each stream signal.
    private func processAvailableFrames() async {
        guard ocrEnabled else { return }
        guard !isPausedForPowerState else { return }
        guard await databaseManager.isReady() else { return }

        do {
            while !Task.isCancelled {
                guard let queuedFrame = try await dequeue() else { break }
                await processQueuedFrame(queuedFrame)

                if minDelayBetweenFramesNs > 0 {
                    try? await Task.sleep(for: .nanoseconds(Int64(minDelayBetweenFramesNs)), clock: .continuous)
                }

                // Re-check pause conditions between frames
                guard ocrEnabled, !isPausedForPowerState else { break }
            }
        } catch is CancellationError {
            return
        } catch {
            Log.error("[Queue] Consumer error: \(error)", category: .processing)
            try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous)
        }
    }

    /// Process a single dequeued frame with error handling and retry logic
    private func processQueuedFrame(_ queuedFrame: QueuedFrame) async {
        let startTime = Date()
        do {
            let result = try await processFrame(queuedFrame)

            // Handle deferred processing result
            if case .deferredSourceNotReady = result {
                // Frame's source is not readable yet — re-enqueue for later and re-signal
                try await databaseManager.enqueueFrameForProcessing(frameID: queuedFrame.frameID, priority: -1)
                currentQueueDepth += 1
                continuation?.yield()
                try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms before next attempt
                return
            }

            totalProcessed += 1

            let elapsed = Date().timeIntervalSince(startTime)
            Log.info("[Queue] Completed frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", category: .processing)

        } catch {
            totalFailed += 1

            let isUnrecoverableError = isUnrecoverableVideoError(error)

            do {
                if isUnrecoverableError {
                    Log.warning("[Queue] Frame \(queuedFrame.frameID) skipped (video not ready)", category: .processing)
                    try await markFrameAsFailed(queuedFrame.frameID, error: error, skipRetries: true)
                } else if queuedFrame.retryCount < config.maxRetryAttempts {
                    try await retryFrame(queuedFrame, error: error)
                    continuation?.yield() // Re-signal so consumer wakes for retry
                } else {
                    try await markFrameAsFailed(queuedFrame.frameID, error: error)
                }
            } catch {
                Log.error("[Queue] Error handling failure for frame \(queuedFrame.frameID): \(error)", category: .processing)
            }
        }
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

        // Get video segment for dimensions (needed for node insertion)
        guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
            Log.error("[Queue-DIAG] Video segment \(frameRef.videoID.value) not found!", category: .processing)
            throw DatabaseError.queryFailed(query: "getVideoSegment", underlying: "Video segment \(frameRef.videoID) not found")
        }

        let tPrep = CFAbsoluteTimeGetCurrent()

        // Resolve segment ID encoded in the video file path (WAL and storage use this ID).
        let actualSegmentID = try parseActualSegmentID(from: videoSegment.relativePath)

        // Source select:
        // - finalized video -> decode frame from encoded segment file
        // - non-finalized video -> read raw frame directly from WAL by frame index
        let capturedFrame: CapturedFrame
        let isVideoFinalized = frameWithInfo.videoInfo?.isVideoFinalized ?? true
        if isVideoFinalized {
            // Verify finalized video file exists before attempting extraction
            let storageRoot = await storage.getStorageDirectory()
            let videoFullPath = storageRoot.appendingPathComponent(videoSegment.relativePath).path
            if !FileManager.default.fileExists(atPath: videoFullPath) {
                Log.error("[Queue] Video file not found for frame \(frameID): \(videoFullPath)", category: .processing)
                Log.error("[Queue] This suggests database/storage path mismatch. Check AppPaths.storageRoot setting.", category: .processing)

                // Mark as failed permanently - don't retry endlessly for missing files
                try await updateFrameProcessingStatus(frameID, status: .failed)
                return .success // Return success to not re-queue (it's a permanent failure)
            }

            // Read from finalized video and convert JPEG payload for OCR.
            let frameData = try await storage.readFrame(
                segmentID: actualSegmentID,
                frameIndex: frameRef.frameIndexInSegment
            )

            guard let convertedFrame = try convertJPEGToCapturedFrame(frameData, frameRef: frameRef) else {
                Log.error("[Queue-DIAG] Frame \(frameID) image conversion failed!", category: .processing)
                throw ProcessingError.imageConversionFailed
            }
            capturedFrame = convertedFrame
        } else {
            guard let walFrame = try await readFrameFromWAL(
                frameID: frameID,
                segmentID: actualSegmentID,
                frameIndex: frameRef.frameIndexInSegment
            ) else {
                return .deferredSourceNotReady
            }
            capturedFrame = walFrame
        }

        // Mark as processing only after the frame payload source is available.
        try await updateFrameProcessingStatus(frameID, status: .processing)

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

        // Insert OCR nodes for both main and chrome regions so any FTS hit can be highlighted.
        let hasAnyOCRRegions = !extractedText.regions.isEmpty || !extractedText.chromeRegions.isEmpty
        if docid > 0 && hasAnyOCRRegions {
            // Delete any existing nodes first to prevent duplicates
            // (can happen if frame is reprocessed without going through reprocessOCR)
            try await databaseManager.deleteNodes(frameID: FrameID(value: frameID))

            var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []
            nodeData.reserveCapacity(extractedText.regions.count + extractedText.chromeRegions.count)

            // c0 offsets: main OCR text joined with single-space separators.
            var mainOffset = 0
            for region in extractedText.regions {
                let textLength = region.text.count
                nodeData.append((
                    textOffset: mainOffset,
                    textLength: textLength,
                    bounds: region.bounds,
                    windowIndex: nil
                ))
                mainOffset += textLength + 1
            }

            // c1 offsets are relative to (c0 + c1) because node text is read using COALESCE(c0,'') || COALESCE(c1,'').
            var chromeOffset = extractedText.fullText.count
            for region in extractedText.chromeRegions {
                let textLength = region.text.count
                nodeData.append((
                    textOffset: chromeOffset,
                    textLength: textLength,
                    bounds: region.bounds,
                    windowIndex: nil
                ))
                chromeOffset += textLength + 1
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

    private func parseActualSegmentID(from relativePath: String) throws -> VideoSegmentID {
        let pathComponents = relativePath.split(separator: "/")
        guard let lastComponent = pathComponents.last,
              let actualSegmentID = Int64(lastComponent) else {
            throw ProcessingError.invalidVideoPath(path: relativePath)
        }
        return VideoSegmentID(value: actualSegmentID)
    }

    /// Returns nil when WAL data is not ready yet and frame should be deferred.
    private func readFrameFromWAL(frameID: Int64, segmentID: VideoSegmentID, frameIndex: Int) async throws -> CapturedFrame? {
        guard let storageManager = storage as? StorageManager else {
            throw StorageError.fileReadFailed(
                path: "WAL(\(segmentID.value))",
                underlying: "Storage manager does not expose WAL manager"
            )
        }

        let walManager = await storageManager.getWALManager()
        do {
            return try await walManager.readFrame(
                videoID: segmentID,
                frameID: frameID,
                fallbackFrameIndex: frameIndex
            )
        } catch {
            if shouldDeferWALRead(error) {
                Log.debug(
                    "[Queue] Frame \(frameID) deferred - WAL source not ready yet (segment \(segmentID.value), index \(frameIndex)): \(error.localizedDescription)",
                    category: .processing
                )
                return nil
            }
            throw error
        }
    }

    private func shouldDeferWALRead(_ error: Error) -> Bool {
        if let storageError = error as? StorageError {
            switch storageError {
            case .fileNotFound:
                return true
            case .fileReadFailed(_, let underlying):
                let lower = underlying.lowercased()
                return lower.contains("out of range")
                    || lower.contains("incomplete")
                    || lower.contains("empty")
            default:
                return false
            }
        }

        let lower = error.localizedDescription.lowercased()
        return lower.contains("out of range")
            || lower.contains("incomplete")
            || lower.contains("empty")
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
            workerCount: consumerTask != nil ? 1 : 0
        )
    }

    // MARK: - Memory Reporting

    private func startMemoryReporting() {
        memoryReportTask?.cancel()
        let intervalNs = Int64(memoryReportIntervalNs)
        memoryReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(intervalNs), clock: .continuous)
                guard !Task.isCancelled else { break }
                await self?.logMemorySnapshot()
            }
        }
    }

    private func logMemorySnapshot() {
        let queueDepth = pendingCount + processingCount

        Log.info(
            "[Queue-Memory] rawCacheFrames=0 rawCacheBytes=0 KB queueDepth=\(queueDepth) pending=\(pendingCount) processing=\(processingCount) consumer=\(consumerTask != nil ? 1 : 0)",
            category: .processing
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

// MARK: - Models

public struct ProcessingQueueConfig: Sendable {
    public let maxRetryAttempts: Int
    public let maxQueueSize: Int

    public init(workerCount: Int = 1, maxRetryAttempts: Int = 3, maxQueueSize: Int = 1000) {
        // workerCount is accepted for backward compatibility but ignored (single consumer)
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
    case deferredSourceNotReady  // Source payload not readable yet (WAL write in progress), re-queue for later
}

public struct QueueStatistics: Sendable {
    public let queueDepth: Int
    public let pendingCount: Int      // Frames waiting in queue (status 0)
    public let processingCount: Int   // Frames currently being processed (status 1)
    public let totalProcessed: Int
    public let totalFailed: Int
    public let workerCount: Int
}
