import CoreGraphics
import Foundation
import Shared
import Database
import Storage
import Search
import ImageIO

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
    private var memoryReportTask: Task<Void, Never>?

    // Statistics
    private var totalProcessed: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0
    private var pendingCount: Int = 0      // Frames with status 0
    private var processingCount: Int = 0   // Frames with status 1

    private let memoryReportIntervalNs: UInt64 = 5_000_000_000
    private var isPausedForMemoryPressure = false

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
        workerCount: Int,
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

        Log.info(
            "[Queue] Power config updated: ocrEnabled=\(ocrEnabled), pauseOnBattery=\(pauseOnBattery), pauseOnLowPowerMode=\(pauseOnLowPowerMode), isLowPowerModeEnabled=\(isLowPowerModeEnabled), power=\(currentPowerSource), maxFPS=\(maxFPS), workers=\(workers.count), priority=\(taskPriority), paused=\(isPausedForPowerState)",
            category: .processing
        )
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
    public func enqueue(frameID: Int64, priority: Int = 0) async throws {
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

        let priority = workerPriority
        for workerID in 0..<config.workerCount {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }

        startMemoryReporting()

        Log.info("[Queue] Started \(workers.count) workers (priority=\(priority))", category: .processing)
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
        memoryReportTask?.cancel()
        memoryReportTask = nil

        Log.info("[Queue] Workers stopped", category: .processing)
    }

    /// Worker loop - processes frames from queue
    private func runWorker(id: Int) async {
        Log.info("[Queue] Worker \(id) STARTED (total workers: \(workers.count))", category: .processing)

        // Initial delay to ensure database is fully stable
        // This prevents race conditions on first launch after onboarding
        try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms - increased for stability

        while isRunning && !Task.isCancelled {
            // Check if OCR is disabled globally
            guard ocrEnabled else {
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous) // 1s poll when disabled
                if Task.isCancelled { break }
                continue
            }

            // Check if paused due to battery/low-power policy
            guard !isPausedForPowerState else {
                try? await Task.sleep(for: .nanoseconds(Int64(2_000_000_000)), clock: .continuous) // 2s poll when paused by power policy
                if Task.isCancelled { break }
                continue
            }

            if await applyMemoryBackpressureIfNeeded() {
                try? await Task.sleep(
                    for: .nanoseconds(Int64(OCRMemoryBackpressurePolicy.current().pollIntervalNs)),
                    clock: .continuous
                )
                if Task.isCancelled { break }
                continue
            }

            // Wait for database to be ready before attempting any operations
            guard await databaseManager.isReady() else {
                // Log.debug("[Queue-DIAG] Worker \(id) waiting for database to be ready", category: .processing)
                try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms
                if Task.isCancelled { break }
                continue
            }

            do {
                // Try to dequeue a frame
                guard let queuedFrame = try await dequeue() else {
                    // Queue empty - wait before polling again
                    try await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous) // 100ms
                    continue
                }

                // Log.info("[Queue-DIAG] Worker \(id) dequeued frame \(queuedFrame.frameID) for processing", category: .processing)

                // Process the frame
                let startTime = Date()
                do {
                    let result = try await processFrame(queuedFrame)

                    // Handle deferred processing result
                    if case .deferredSourceNotReady = result {
                        // Frame's source is not readable yet (e.g. WAL write still catching up) - re-enqueue for later
                        try await databaseManager.enqueueFrameForProcessing(frameID: queuedFrame.frameID, priority: -1)
                        currentQueueDepth += 1
                        try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms before next attempt
                        continue
                    }

                    totalProcessed += 1

                    let elapsed = Date().timeIntervalSince(startTime)
                    Log.info("[Queue-DIAG] Worker \(id) COMPLETED frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", category: .processing)

                    // Apply rate limiting delay after successful processing
                    if minDelayBetweenFramesNs > 0 {
                        try? await Task.sleep(for: .nanoseconds(Int64(minDelayBetweenFramesNs)), clock: .continuous)
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
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous) // 1s backoff
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

        // Get video segment for dimensions (needed for node insertion)
        guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
            Log.error("[Queue-DIAG] Video segment \(frameRef.videoID.value) not found!", category: .processing)
            throw DatabaseError.queryFailed(query: "getVideoSegment", underlying: "Video segment \(frameRef.videoID) not found")
        }

        let tPrep = CFAbsoluteTimeGetCurrent()

        // Resolve segment ID encoded in the video file path (WAL and storage use this ID).
        let actualSegmentID = try parseActualSegmentID(from: videoSegment.relativePath)
        let ocrStageResult = try await performOCRStage(
            frameID: frameID,
            frameRef: frameRef,
            frameWithInfo: frameWithInfo,
            videoSegment: videoSegment,
            actualSegmentID: actualSegmentID
        )
        let ocrStage: OCRStageOutput
        switch ocrStageResult {
        case .deferred:
            return .deferredSourceNotReady
        case .failedPermanently:
            return .success
        case .ready(let stage):
            ocrStage = stage
        }
        let tFrame = ocrStage.ocrStartTime
        let tOCR = CFAbsoluteTimeGetCurrent()

        // Index in FTS
        let docid = try await search.index(
            text: ocrStage.extractedText,
            segmentId: frameRef.segmentID.value,
            frameId: frameID
        )

        // Insert OCR nodes for both main and chrome regions so any FTS hit can be highlighted.
        let hasAnyOCRRegions = !ocrStage.extractedText.regions.isEmpty || !ocrStage.extractedText.chromeRegions.isEmpty
        if docid > 0 && hasAnyOCRRegions {
            // Delete any existing nodes first to prevent duplicates
            // (can happen if frame is reprocessed without going through reprocessOCR)
            try await databaseManager.deleteNodes(frameID: FrameID(value: frameID))

            var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []
            nodeData.reserveCapacity(ocrStage.extractedText.regions.count + ocrStage.extractedText.chromeRegions.count)

            // c0 offsets: main OCR text joined with single-space separators.
            var mainOffset = 0
            for region in ocrStage.extractedText.regions {
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
            var chromeOffset = ocrStage.extractedText.fullText.count
            for region in ocrStage.extractedText.chromeRegions {
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

        do {
            try await resolveInPageURLMetadataIfPossible(
                frameID: frameID,
                frameWidth: videoSegment.width,
                frameHeight: videoSegment.height
            )
        } catch {
            Log.warning(
                "[Queue] Failed to resolve pending in-page metadata for frame \(frameID): \(error.localizedDescription)",
                category: .processing
            )
        }

        // Mark as completed
        try await updateFrameProcessingStatus(frameID, status: .completed)

        let tDone = CFAbsoluteTimeGetCurrent()
        Log.info("[Queue-TIMING] Frame \(frameID): prep=\(String(format: "%.0f", (tPrep-t0)*1000))ms frame=\(String(format: "%.0f", (tFrame-tPrep)*1000))ms ocr=\(String(format: "%.0f", (tOCR-tFrame)*1000))ms index=\(String(format: "%.0f", (tDone-tOCR)*1000))ms total=\(String(format: "%.0f", (tDone-t0)*1000))ms size=\(ocrStage.frameWidth)x\(ocrStage.frameHeight)", category: .processing)

        return .success
    }

    private func performOCRStage(
        frameID: Int64,
        frameRef: FrameReference,
        frameWithInfo: FrameWithVideoInfo,
        videoSegment: VideoSegment,
        actualSegmentID: VideoSegmentID
    ) async throws -> OCRStageResult {
        // Source select:
        // - finalized video -> decode frame from encoded segment file
        // - non-finalized video -> read raw frame directly from WAL by frame index
        let capturedFrame: CapturedFrame
        let processedFrameWidth: Int
        let processedFrameHeight: Int
        let isVideoFinalized = frameWithInfo.videoInfo?.isVideoFinalized ?? true

        if isVideoFinalized {
            let storageRoot = await storage.getStorageDirectory()
            let videoFullPath = storageRoot.appendingPathComponent(videoSegment.relativePath).path
            if !FileManager.default.fileExists(atPath: videoFullPath) {
                Log.error("[Queue] Video file not found for frame \(frameID): \(videoFullPath)", category: .processing)
                Log.error("[Queue] This suggests database/storage path mismatch. Check AppPaths.storageRoot setting.", category: .processing)

                try await updateFrameProcessingStatus(frameID, status: .failed)
                return .failedPermanently
            }

            let frameData = try await storage.readFrame(
                segmentID: actualSegmentID,
                frameIndex: frameRef.frameIndexInSegment
            )

            guard let convertedFrame = try convertJPEGToCapturedFrame(frameData, frameRef: frameRef) else {
                Log.error("[Queue-DIAG] Frame \(frameID) image conversion failed!", category: .processing)
                throw ProcessingError.imageConversionFailed
            }
            capturedFrame = convertedFrame
            processedFrameWidth = convertedFrame.width
            processedFrameHeight = convertedFrame.height
        } else {
            guard let walFrame = try await readFrameFromWAL(
                frameID: frameID,
                segmentID: actualSegmentID,
                frameIndex: frameRef.frameIndexInSegment
            ) else {
                return .deferred
            }
            capturedFrame = walFrame
            processedFrameWidth = walFrame.width
            processedFrameHeight = walFrame.height
        }

        try await updateFrameProcessingStatus(frameID, status: .processing)
        let ocrStartTime = CFAbsoluteTimeGetCurrent()

        let extractedText = try await processing.extractText(from: capturedFrame)

        return .ready(OCRStageOutput(
            extractedText: extractedText,
            frameWidth: processedFrameWidth,
            frameHeight: processedFrameHeight,
            ocrStartTime: ocrStartTime
        ))
    }

    /// Convert JPEG data back to CapturedFrame for OCR
    private func convertJPEGToCapturedFrame(_ jpegData: Data, frameRef: FrameReference) throws -> CapturedFrame? {
        autoreleasepool {
            let sourceOptions = [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary
            let imageOptions = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary

            guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, sourceOptions),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, imageOptions) else {
                return nil
            }

            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = width * 4

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

    // MARK: - In-Page URL Metadata Resolution

    private static let inPageURLMinimumMatchScore = 78
    private static let inPageURLMinimumMatchScoreMultiToken = 68
    private static let inPageURLMinimumMatchScoreLongPhrase = 64
    private static let inPageURLNodeReuseLimit = 2
    private static let inPageURLTextStopwords: Set<String> = [
        "edit", "view", "talk", "history", "jump", "search", "help", "more", "log", "in", "out"
    ]

    private struct InPageURLMetadataResolvedURL: Codable, Sendable {
        let url: String
        let nid: Int

        private enum CodingKeys: String, CodingKey {
            case url
            case nid
            case nodeid
        }

        init(url: String, nid: Int) {
            self.url = url
            self.nid = nid
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)

            if let compactNodeID = try container.decodeIfPresent(Int.self, forKey: .nid) {
                nid = compactNodeID
            } else {
                nid = try container.decode(Int.self, forKey: .nodeid)
            }

        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(url, forKey: .url)
            try container.encode(nid, forKey: .nid)
        }
    }

    private struct InPageURLMetadataRawLink: Codable, Sendable {
        let url: String
        let text: String
        let left: Double
        let top: Double
        let width: Double
        let height: Double
    }

    private struct InPageURLMetadataPoint: Codable, Sendable {
        let x: Double
        let y: Double
    }

    private struct InPageURLMetadataVideoPosition: Codable, Sendable {
        let currenttime: Double
    }

    private struct InPageURLMetadataPayload: Codable, Sendable {
        var pageurl: String?
        var rawlinks: [InPageURLMetadataRawLink]
        var urls: [InPageURLMetadataResolvedURL]
        var mouseposition: InPageURLMetadataPoint?
        var scrollposition: InPageURLMetadataPoint?
        var videoposition: InPageURLMetadataVideoPosition?

        private enum CodingKeys: String, CodingKey {
            case pageurl
            case rawlinks
            case urls
            case mouseposition
            case scrollposition
            case videoposition
        }

        init(
            pageurl: String?,
            rawlinks: [InPageURLMetadataRawLink],
            urls: [InPageURLMetadataResolvedURL],
            mouseposition: InPageURLMetadataPoint?,
            scrollposition: InPageURLMetadataPoint?,
            videoposition: InPageURLMetadataVideoPosition?
        ) {
            self.pageurl = pageurl
            self.rawlinks = rawlinks
            self.urls = urls
            self.mouseposition = mouseposition
            self.scrollposition = scrollposition
            self.videoposition = videoposition
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pageurl = try container.decodeIfPresent(String.self, forKey: .pageurl)
            rawlinks = try container.decodeIfPresent([InPageURLMetadataRawLink].self, forKey: .rawlinks) ?? []
            urls = try container.decodeIfPresent([InPageURLMetadataResolvedURL].self, forKey: .urls) ?? []
            mouseposition = try container.decodeIfPresent(InPageURLMetadataPoint.self, forKey: .mouseposition)
            scrollposition = try container.decodeIfPresent(InPageURLMetadataPoint.self, forKey: .scrollposition)
            videoposition = try container.decodeIfPresent(InPageURLMetadataVideoPosition.self, forKey: .videoposition)
        }
    }

    private struct PreparedInPageOCRNode: Sendable {
        let nodeID: Int
        let nodeOrder: Int
        let normalizedText: String
        let tokenSet: Set<String>
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    public func resolveInPageURLMetadataIfPossible(frameID: Int64) async throws {
        try await resolveInPageURLMetadataIfPossible(
            frameID: frameID,
            frameWidth: nil,
            frameHeight: nil
        )
    }

    private func resolveInPageURLMetadataIfPossible(
        frameID: Int64,
        frameWidth: Int?,
        frameHeight: Int?
    ) async throws {
        let frameIDRef = FrameID(value: frameID)
        guard let metadataJSON = try await databaseManager.getFrameMetadata(frameID: frameIDRef),
              !metadataJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let existingRows = try await databaseManager.getFrameInPageURLRows(frameID: frameIDRef)
        if !existingRows.isEmpty {
            try await databaseManager.updateFrameMetadata(
                frameID: frameIDRef,
                metadataJSON: nil
            )
            return
        }

        let resolvedFrameWidth: Int
        let resolvedFrameHeight: Int
        if let frameWidth, let frameHeight, frameWidth > 0, frameHeight > 0 {
            resolvedFrameWidth = frameWidth
            resolvedFrameHeight = frameHeight
        } else if let dimensions = try await inPageURLFrameDimensions(frameID: frameIDRef) {
            resolvedFrameWidth = dimensions.width
            resolvedFrameHeight = dimensions.height
        } else {
            return
        }

        try await resolvePendingInPageURLMetadataIfNeeded(
            frameID: frameIDRef,
            metadataJSON: metadataJSON,
            frameWidth: resolvedFrameWidth,
            frameHeight: resolvedFrameHeight
        )
    }

    private func inPageURLFrameDimensions(frameID: FrameID) async throws -> (width: Int, height: Int)? {
        if let frameWithInfo = try await databaseManager.getFrameWithVideoInfoByID(id: frameID) {
            if let width = frameWithInfo.videoInfo?.width,
               let height = frameWithInfo.videoInfo?.height,
               width > 0,
               height > 0 {
                return (width, height)
            }

            let videoID = frameWithInfo.frame.videoID
            if videoID.value > 0,
               let videoSegment = try await databaseManager.getVideoSegment(id: videoID),
               videoSegment.width > 0,
               videoSegment.height > 0 {
                return (videoSegment.width, videoSegment.height)
            }
        }

        if let frame = try await databaseManager.getFrame(id: frameID),
           frame.videoID.value > 0,
           let videoSegment = try await databaseManager.getVideoSegment(id: frame.videoID),
           videoSegment.width > 0,
           videoSegment.height > 0 {
            return (videoSegment.width, videoSegment.height)
        }

        return nil
    }

    private func resolvePendingInPageURLMetadataIfNeeded(
        frameID: FrameID,
        metadataJSON: String,
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        guard let data = metadataJSON.data(using: .utf8) else {
            return
        }

        var payload: InPageURLMetadataPayload
        do {
            payload = try JSONDecoder().decode(InPageURLMetadataPayload.self, from: data)
        } catch {
            return
        }

        let hasInPagePayload =
            payload.pageurl != nil ||
            payload.mouseposition != nil ||
            payload.scrollposition != nil ||
            payload.videoposition != nil ||
            !payload.rawlinks.isEmpty ||
            !payload.urls.isEmpty
        guard hasInPagePayload else {
            return
        }

        let resolvedURLs: [InPageURLMetadataResolvedURL]
        if !payload.urls.isEmpty {
            resolvedURLs = payload.urls
        } else if !payload.rawlinks.isEmpty {
            let nodesWithText = try await databaseManager.getNodesWithText(
                frameID: frameID,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
            guard !nodesWithText.isEmpty else {
                return
            }
            resolvedURLs = Self.resolveInPageRawLinks(
                payload.rawlinks,
                nodesWithText: nodesWithText,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
            guard !resolvedURLs.isEmpty else {
                return
            }
        } else {
            resolvedURLs = []
        }

        var mouseX = payload.mouseposition?.x
        var mouseY = payload.mouseposition?.y
        if mouseX == nil, mouseY == nil,
           let existingState = try await databaseManager.getFrameInPageURLState(frameID: frameID) {
            mouseX = existingState.mouseX
            mouseY = existingState.mouseY
        }

        let state = FrameInPageURLState(
            mouseX: mouseX,
            mouseY: mouseY,
            scrollX: payload.scrollposition?.x,
            scrollY: payload.scrollposition?.y,
            videoCurrentTime: payload.videoposition?.currenttime
        )
        let rows: [FrameInPageURLRow] = resolvedURLs.enumerated().map { index, resolved in
            FrameInPageURLRow(
                order: index,
                url: Self.compactInPageURL(resolved.url, pageURL: payload.pageurl),
                nodeID: resolved.nid
            )
        }

        try await databaseManager.replaceFrameInPageURLData(
            frameID: frameID,
            state: state,
            rows: rows
        )

        try await databaseManager.updateFrameMetadata(
            frameID: frameID,
            metadataJSON: nil
        )
    }

    private static func resolveInPageRawLinks(
        _ rawLinks: [InPageURLMetadataRawLink],
        nodesWithText: [(node: OCRNode, text: String)],
        frameWidth: Int,
        frameHeight: Int
    ) -> [InPageURLMetadataResolvedURL] {
        guard frameWidth > 0, frameHeight > 0, !rawLinks.isEmpty, !nodesWithText.isEmpty else {
            return []
        }

        let preparedNodes: [PreparedInPageOCRNode] = nodesWithText.compactMap { entry in
            let normalizedText = normalizeInPageText(entry.text)
            let tokenSet = inPageURLTokenSet(normalizedText)
            guard !normalizedText.isEmpty || !tokenSet.isEmpty else {
                return nil
            }

            let nodeID: Int
            if let rawNodeID = entry.node.id,
               let resolvedNodeID = Int(exactly: rawNodeID) {
                nodeID = resolvedNodeID
            } else {
                nodeID = entry.node.nodeOrder
            }
            let nodeOrder = entry.node.nodeOrder
            let normalizedX = clampInPageCoordinate(Double(entry.node.bounds.origin.x) / Double(frameWidth))
            let normalizedY = clampInPageCoordinate(Double(entry.node.bounds.origin.y) / Double(frameHeight))
            let normalizedWidth = clampInPageCoordinate(Double(entry.node.bounds.width) / Double(frameWidth))
            let normalizedHeight = clampInPageCoordinate(Double(entry.node.bounds.height) / Double(frameHeight))
            guard normalizedWidth > 0, normalizedHeight > 0 else {
                return nil
            }

            return PreparedInPageOCRNode(
                nodeID: nodeID,
                nodeOrder: nodeOrder,
                normalizedText: normalizedText,
                tokenSet: tokenSet,
                x: normalizedX,
                y: normalizedY,
                width: normalizedWidth,
                height: normalizedHeight
            )
        }
        guard !preparedNodes.isEmpty else {
            return []
        }

        var assignedNodeUseCount: [Int: Int] = [:]
        assignedNodeUseCount.reserveCapacity(preparedNodes.count)

        var resolved: [InPageURLMetadataResolvedURL] = []
        resolved.reserveCapacity(min(rawLinks.count, 160))
        var seenResolvedKeys: Set<String> = []
        seenResolvedKeys.reserveCapacity(min(rawLinks.count, 160))

        for rawLink in rawLinks {
            if resolved.count >= 160 {
                break
            }

            let url = rawLink.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = rawLink.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !text.isEmpty else { continue }

            let normalizedCandidateText = normalizeInPageText(text)
            let candidateTokens = inPageURLTokenSet(normalizedCandidateText)
            guard !normalizedCandidateText.isEmpty || !candidateTokens.isEmpty else { continue }

            var bestNode: PreparedInPageOCRNode?
            var bestScore = Int.min

            for node in preparedNodes {
                let usageCount = assignedNodeUseCount[node.nodeID, default: 0]
                guard usageCount < inPageURLNodeReuseLimit else { continue }

                let score = inPageURLMatchScore(
                    nodeNormalizedText: node.normalizedText,
                    nodeTokens: node.tokenSet,
                    candidateNormalizedText: normalizedCandidateText,
                    candidateTokens: candidateTokens,
                    candidateURL: url
                )

                if score > bestScore {
                    bestScore = score
                    bestNode = node
                }
            }

            guard let bestNode else { continue }
            let minimumScore = inPageURLMinimumScore(forCandidateTokenCount: candidateTokens.count)
            guard bestScore >= minimumScore else { continue }

            let dedupeKey = "\(bestNode.nodeID)|\(url)"
            guard seenResolvedKeys.insert(dedupeKey).inserted else { continue }

            resolved.append(
                InPageURLMetadataResolvedURL(
                    url: url,
                    nid: bestNode.nodeID
                )
            )
            assignedNodeUseCount[bestNode.nodeID, default: 0] += 1
        }

        return resolved
    }

    private static func inPageURLMatchScore(
        nodeNormalizedText: String,
        nodeTokens: Set<String>,
        candidateNormalizedText: String,
        candidateTokens: Set<String>,
        candidateURL: String
    ) -> Int {
        var score = 0

        if nodeNormalizedText == candidateNormalizedText {
            score += 125
        } else {
            let containsRelation = nodeNormalizedText.contains(candidateNormalizedText)
                || candidateNormalizedText.contains(nodeNormalizedText)
            if containsRelation {
                score += 85
                let lengthDelta = abs(nodeNormalizedText.count - candidateNormalizedText.count)
                score -= min(lengthDelta, 20)
            }
        }

        let commonTokenCount = approximateInPageTokenOverlapCount(lhs: nodeTokens, rhs: candidateTokens)
        if commonTokenCount > 0 {
            let overlapBase = max(nodeTokens.count, candidateTokens.count)
            let ratio = Double(commonTokenCount) / Double(max(overlapBase, 1))
            score += Int(ratio * 95.0)

            let candidateCoverage = Double(commonTokenCount) / Double(max(candidateTokens.count, 1))
            score += Int(candidateCoverage * 72.0)
        }

        if candidateURL.hasPrefix("https://") {
            score += 4
        }

        return score
    }

    private static func approximateInPageTokenOverlapCount(lhs: Set<String>, rhs: Set<String>) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        var consumedRHS: Set<String> = []
        var overlapCount = 0

        let orderedLHS = lhs.sorted { left, right in
            if left.count != right.count {
                return left.count > right.count
            }
            return left < right
        }

        for lhsToken in orderedLHS {
            if rhs.contains(lhsToken), !consumedRHS.contains(lhsToken) {
                consumedRHS.insert(lhsToken)
                overlapCount += 1
                continue
            }

            if let fuzzyMatch = rhs
                .filter({ !consumedRHS.contains($0) })
                .sorted(by: { $0.count > $1.count })
                .first(where: { rhsToken in
                    inPageURLTokensLikelyMatch(lhsToken, rhsToken)
                }) {
                consumedRHS.insert(fuzzyMatch)
                overlapCount += 1
            }
        }

        return overlapCount
    }

    private static func inPageURLTokensLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let minimumLength = min(lhs.count, rhs.count)
        guard minimumLength >= 4 else { return false }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private static func inPageURLMinimumScore(forCandidateTokenCount tokenCount: Int) -> Int {
        if tokenCount >= 4 {
            return inPageURLMinimumMatchScoreLongPhrase
        }
        if tokenCount >= 2 {
            return inPageURLMinimumMatchScoreMultiToken
        }
        return inPageURLMinimumMatchScore
    }

    private static func normalizeInPageText(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        var normalized = ""
        normalized.reserveCapacity(folded.count)
        var lastWasSpace = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                normalized.append(" ")
                lastWasSpace = true
            }
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inPageURLTokenSet(_ normalizedText: String) -> Set<String> {
        Set(
            normalizedText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { $0.count >= 2 && !inPageURLTextStopwords.contains($0) }
        )
    }

    private static func roundedInPageCoordinate(_ value: Double) -> Double {
        let rounded = (value * 1_000.0).rounded() / 1_000.0
        if rounded == -0 {
            return 0
        }
        return rounded
    }

    private static func clampInPageCoordinate(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private static func compactInPageURL(_ urlString: String, pageURL: String?) -> String {
        guard let pageURL,
              let url = URL(string: urlString),
              let page = URL(string: pageURL),
              url.scheme?.lowercased() == page.scheme?.lowercased(),
              normalizeHost(url.host) == normalizeHost(page.host),
              (url.port ?? defaultPort(forScheme: url.scheme)) == (page.port ?? defaultPort(forScheme: page.scheme))
        else {
            return urlString
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlString
        }

        var compact = components.percentEncodedPath
        if compact.isEmpty {
            compact = "/"
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            compact += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            compact += "#\(fragment)"
        }
        return compact
    }

    private static func normalizeHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("www.") {
            return String(trimmed.dropFirst(4)).lowercased()
        }
        return trimmed.lowercased()
    }

    private static func defaultPort(forScheme scheme: String?) -> Int? {
        guard let scheme else { return nil }
        switch scheme.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
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

    private func logMemorySnapshot() async {
        let counts = await refreshLiveQueueCounts()
        let processFields = ProcessingMemoryDiagnostics.currentProcessMemorySnapshot().map {
            "footprint=\(ProcessingMemoryDiagnostics.formatBytes($0.physFootprintBytes)) resident=\(ProcessingMemoryDiagnostics.formatBytes($0.residentBytes)) internal=\(ProcessingMemoryDiagnostics.formatBytes($0.internalBytes)) compressed=\(ProcessingMemoryDiagnostics.formatBytes($0.compressedBytes)) "
        } ?? ""

        Log.info(
            "[Queue-Memory] \(processFields)rawCacheFrames=0 rawCacheBytes=0 KB queueDepth=\(counts.depth) pending=\(counts.pending) processing=\(counts.processing) workers=\(workers.count) memoryPaused=\(isPausedForMemoryPressure)",
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

    private func refreshLiveQueueCounts() async -> (pending: Int, processing: Int, depth: Int) {
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pendingCount = counts.pending
            processingCount = counts.processing
            currentQueueDepth = counts.pending + counts.processing
        }
        return (pendingCount, processingCount, pendingCount + processingCount)
    }

    private func applyMemoryBackpressureIfNeeded() async -> Bool {
        let policy = OCRMemoryBackpressurePolicy.current()
        guard policy.enabled else {
            if isPausedForMemoryPressure {
                isPausedForMemoryPressure = false
                let snapshot = ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()
                Log.info(
                    "[Queue-Backpressure] disabled footprint=\(ProcessingMemoryDiagnostics.formatFootprint(snapshot))",
                    category: .processing
                )
            }
            return false
        }

        let snapshot = ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()
        let shouldPause = policy.shouldPause(
            footprintBytes: snapshot?.physFootprintBytes ?? 0,
            currentlyPaused: isPausedForMemoryPressure
        )

        guard shouldPause != isPausedForMemoryPressure else {
            return shouldPause
        }

        isPausedForMemoryPressure = shouldPause
        let counts = await refreshLiveQueueCounts()
        let baseMessage = "footprint=\(ProcessingMemoryDiagnostics.formatFootprint(snapshot)) pauseAt=\(ProcessingMemoryDiagnostics.formatBytes(policy.pauseThresholdBytes)) resumeBelow=\(ProcessingMemoryDiagnostics.formatBytes(policy.resumeThresholdBytes)) queueDepth=\(counts.depth) pending=\(counts.pending) processing=\(counts.processing)"

        if shouldPause {
            Log.warning("[Queue-Backpressure] paused \(baseMessage)", category: .processing)
        } else {
            Log.info("[Queue-Backpressure] resumed \(baseMessage)", category: .processing)
        }

        return shouldPause
    }
}

struct ProcessingProcessMemorySnapshot: Sendable {
    let physFootprintBytes: UInt64
    let residentBytes: UInt64
    let internalBytes: UInt64
    let compressedBytes: UInt64
}

struct OCRMemoryBackpressurePolicy: Sendable {
    private static let oneMiB: UInt64 = 1024 * 1024

    static let enabledDefaultsKey = "retrace.debug.ocrMemoryBackpressureEnabled"
    static let pauseThresholdDefaultsKey = "retrace.debug.ocrMemoryPauseThresholdMB"
    static let resumeThresholdDefaultsKey = "retrace.debug.ocrMemoryResumeThresholdMB"
    static let pollIntervalDefaultsKey = "retrace.debug.ocrMemoryBackpressurePollMs"

    static let defaultPauseThresholdMB = 1_536
    static let defaultResumeThresholdMB = 1_434
    static let defaultPauseThresholdBytes: UInt64 = UInt64(defaultPauseThresholdMB) * oneMiB
    static let defaultResumeThresholdBytes: UInt64 = UInt64(defaultResumeThresholdMB) * oneMiB
    static let defaultPollIntervalNs: UInt64 = 1_000_000_000
    static let referenceDisplayPixelCount: UInt64 = 2_560 * 1_440
    static let maximumAutoScaleFactor: Double = 2.0

    let enabled: Bool
    let pauseThresholdBytes: UInt64
    let resumeThresholdBytes: UInt64
    let pollIntervalNs: UInt64

    static func current(
        defaults: UserDefaults = .standard,
        largestDisplayPixelCount: UInt64? = nil
    ) -> OCRMemoryBackpressurePolicy {
        let enabled = defaults.object(forKey: enabledDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: enabledDefaultsKey)

        let detectedLargestDisplayPixelCount = largestDisplayPixelCount
            ?? OCRDisplayGeometry.currentLargestActiveDisplayPixelCount()

        let scaledDefaultPauseThresholdMB = scaledDefaultThresholdMB(
            baseThresholdMB: defaultPauseThresholdMB,
            largestDisplayPixelCount: detectedLargestDisplayPixelCount
        )
        let scaledDefaultResumeThresholdMB = scaledDefaultThresholdMB(
            baseThresholdMB: defaultResumeThresholdMB,
            largestDisplayPixelCount: detectedLargestDisplayPixelCount
        )

        let pauseThresholdMB = defaults.object(forKey: pauseThresholdDefaultsKey) == nil
            ? scaledDefaultPauseThresholdMB
            : defaults.integer(forKey: pauseThresholdDefaultsKey)

        let resumeThresholdMB = defaults.object(forKey: resumeThresholdDefaultsKey) == nil
            ? scaledDefaultResumeThresholdMB
            : defaults.integer(forKey: resumeThresholdDefaultsKey)

        let pollIntervalMs = defaults.object(forKey: pollIntervalDefaultsKey) == nil
            ? Int(defaultPollIntervalNs / 1_000_000)
            : max(defaults.integer(forKey: pollIntervalDefaultsKey), 100)

        return OCRMemoryBackpressurePolicy(
            enabled: enabled,
            pauseThresholdBytes: UInt64(max(pauseThresholdMB, 1)) * oneMiB,
            resumeThresholdBytes: UInt64(max(min(resumeThresholdMB, pauseThresholdMB - 1), 1)) * oneMiB,
            pollIntervalNs: UInt64(pollIntervalMs) * 1_000_000
        )
    }

    private static func scaledDefaultThresholdMB(
        baseThresholdMB: Int,
        largestDisplayPixelCount: UInt64?
    ) -> Int {
        guard let largestDisplayPixelCount,
              largestDisplayPixelCount > referenceDisplayPixelCount else {
            return baseThresholdMB
        }

        let displayRatio = Double(largestDisplayPixelCount) / Double(referenceDisplayPixelCount)
        let scaleFactor = min(sqrt(displayRatio), maximumAutoScaleFactor)
        return max(Int((Double(baseThresholdMB) * scaleFactor).rounded()), 1)
    }

    func shouldPause(footprintBytes: UInt64, currentlyPaused: Bool) -> Bool {
        if !enabled {
            return false
        }
        if currentlyPaused {
            return footprintBytes >= resumeThresholdBytes
        }
        return footprintBytes >= pauseThresholdBytes
    }
}

enum OCRDisplayGeometry {
    static func currentLargestActiveDisplayPixelCount() -> UInt64? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return nil
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        let result = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }

        guard result == .success else {
            return nil
        }

        return displayIDs.prefix(Int(displayCount)).reduce(0) { currentMax, displayID in
            let pixelCount = UInt64(CGDisplayPixelsWide(displayID)) * UInt64(CGDisplayPixelsHigh(displayID))
            return max(currentMax, pixelCount)
        }
    }
}

enum ProcessingMemoryDiagnostics {
    private typealias ProcPidRusageFunction = @convention(c) (pid_t, Int32, UnsafeMutableRawPointer?) -> Int32

    private static let procPidRusageFunction: ProcPidRusageFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pid_rusage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ProcPidRusageFunction.self)
    }()

    static func currentProcessMemorySnapshot() -> ProcessingProcessMemorySnapshot? {
        let usage = currentRusageInfo()
        let taskInfo = currentTaskVMInfo()
        guard usage != nil || taskInfo != nil else { return nil }

        return ProcessingProcessMemorySnapshot(
            physFootprintBytes: usage?.ri_phys_footprint ?? taskInfo?.phys_footprint ?? 0,
            residentBytes: taskInfo?.resident_size ?? 0,
            internalBytes: taskInfo?.internal ?? 0,
            compressedBytes: taskInfo?.compressed ?? 0
        )
    }

    static func formatFootprint(_ snapshot: ProcessingProcessMemorySnapshot?) -> String {
        guard let snapshot else { return "n/a" }
        return formatBytes(snapshot.physFootprintBytes)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func currentRusageInfo() -> rusage_info_v4? {
        guard let procPidRusageFunction else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            procPidRusageFunction(
                ProcessInfo.processInfo.processIdentifier,
                Int32(RUSAGE_INFO_V4),
                UnsafeMutableRawPointer(pointer)
            )
        }
        return result == 0 ? info : nil
    }

    private static func currentTaskVMInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let kernResult = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard kernResult == KERN_SUCCESS else { return nil }
        return info
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
    case deferredSourceNotReady  // Source payload not readable yet (WAL write in progress), re-queue for later
}

private enum OCRStageResult {
    case ready(OCRStageOutput)
    case deferred
    case failedPermanently
}

private struct OCRStageOutput {
    let extractedText: ExtractedText
    let frameWidth: Int
    let frameHeight: Int
    let ocrStartTime: CFAbsoluteTime
}

public struct QueueStatistics: Sendable {
    public let queueDepth: Int
    public let pendingCount: Int      // Frames waiting in queue (status 0)
    public let processingCount: Int   // Frames currently being processed (status 1)
    public let totalProcessed: Int
    public let totalFailed: Int
    public let workerCount: Int
}
