import Foundation
import Shared
import Database
import Storage
import Capture
import Processing
import Search
import Migration
import CoreGraphics

/// Main coordinator that wires all modules together
/// Implements the core data pipeline: Capture → Storage → Processing → Database → Search
/// Owner: APP integration
public actor AppCoordinator {

    // MARK: - Properties

    private let services: ServiceContainer
    private var captureTask: Task<Void, Never>?
    // ⚠️ RELEASE 2 ONLY
    // private var audioTask: Task<Void, Never>?
    private var isRunning = false

    // Statistics
    private var pipelineStartTime: Date?
    private var totalFramesProcessed = 0
    private var totalErrors = 0

    // Segment tracking (app focus sessions - Rewind compatible)
    private var currentSegmentID: Int64?

    // Idle detection - track last frame timestamp to detect gaps
    private var lastFrameTimestamp: Date?

    // Timeline visibility tracking - pause capture when timeline is open
    private var isTimelineVisible = false

    // Signal to flush pending frames to the OCR queue
    private var shouldFlushPendingFrames = false

    // Storage accessibility monitoring - stops recording if storage becomes unavailable
    private var storageMonitorTask: Task<Void, Never>?

    // Permission monitoring - stops recording gracefully if permissions are revoked
    private var permissionMonitorSetup = false

    // MARK: - Initialization

    public init(services: ServiceContainer) {
        self.services = services
        Log.info("AppCoordinator created", category: .app)
    }

    /// Convenience initializer with default configuration
    public init() {
        self.services = ServiceContainer()
        Log.info("AppCoordinator created with default services", category: .app)
    }

    // MARK: - Public Accessors

    nonisolated public var onboardingManager: OnboardingManager {
        services.onboardingManager
    }

    nonisolated public var modelManager: ModelManager {
        services.modelManager
    }

    /// Get current capture configuration
    public func getCaptureConfig() async -> CaptureConfig {
        await services.capture.getConfig()
    }

    /// Update capture configuration
    public func updateCaptureConfig(_ config: CaptureConfig) async throws {
        try await services.capture.updateConfig(config)
    }

    // MARK: - Timeline Visibility

    /// Set whether the timeline is currently visible (pauses frame processing when true)
    public func setTimelineVisible(_ visible: Bool) {
        isTimelineVisible = visible
        // When timeline becomes visible, signal to flush any buffered frames to OCR queue
        if visible {
            shouldFlushPendingFrames = true
        }
        Log.info("Timeline visibility changed: \(visible) - frame processing \(visible ? "paused" : "resumed")", category: .app)
    }

    // MARK: - Lifecycle

    /// Initialize all services
    public func initialize() async throws {
        Log.info("Initializing AppCoordinator...", category: .app)
        try await services.initialize()

        // Run crash recovery from WAL in background (non-blocking)
        Task {
            do {
                try await recoverFromCrash()
            } catch {
                Log.error("[AppCoordinator] Background crash recovery failed", category: .app, error: error)
            }
        }

        Log.info("AppCoordinator initialized successfully", category: .app)

        // Log auto-start state for debugging
        let shouldAutoStart = Self.shouldAutoStartRecording()
        Log.info("Auto-start recording check: shouldAutoStartRecording=\(shouldAutoStart)", category: .app)
    }

    /// Recover frames from write-ahead log (WAL) after a crash
    private func recoverFromCrash() async throws {
        // Skip crash recovery during first launch (onboarding) - there's nothing to recover
        // and the database may not be fully ready yet
        guard await services.onboardingManager.hasCompletedOnboarding else {
            Log.info("Skipping crash recovery during onboarding (first launch)", category: .app)
            return
        }

        Log.info("Checking for crash recovery...", category: .app)

        // Cast to concrete StorageManager to access WAL
        guard let storageManager = services.storage as? StorageManager else {
            Log.warning("Storage not using WAL-enabled StorageManager, skipping recovery", category: .app)
            return
        }

        let walManager = await storageManager.getWALManager()
        let recoveryManager = RecoveryManager(
            walManager: walManager,
            storage: services.storage,
            database: services.database,
            processing: services.processing,
            search: services.search
        )

        // Set callback for enqueueing recovered frames
        if let queue = await services.processingQueue {
            await recoveryManager.setFrameEnqueueCallback { frameIDs in
                try await queue.enqueueBatch(frameIDs: frameIDs)
            }
        }

        let result = try await recoveryManager.recoverAll()

        // Finalize any orphaned videos (processingState=1 but no active WAL session)
        // This cleans up videos left unfinalised due to dev restarts or crashes
        let activeWALSessions = try await walManager.listActiveSessions()
        let activeVideoIDs = Set(activeWALSessions.map { $0.videoID.value })
        let orphanedVideosFinalized = try await services.database.finalizeOrphanedVideos(activeVideoIDs: activeVideoIDs)
        if orphanedVideosFinalized > 0 {
            Log.warning("[Recovery] Finalized \(orphanedVideosFinalized) orphaned videos (processingState was stuck at 1)", category: .app)
        }

        // Re-enqueue frames that were processing during crash
        if let queue = await services.processingQueue {
            try await queue.requeueCrashedFrames()
        }

        if result.sessionsRecovered > 0 {
            Log.warning("Crash recovery completed: \(result.sessionsRecovered) sessions, \(result.framesRecovered) frames recovered", category: .app)
        } else {
            Log.info("No crash recovery needed", category: .app)
        }

        // Re-enqueue orphaned frames (processingStatus=0 but not in queue)
        // These are frames that were captured but never enqueued due to app restart
        await reEnqueueOrphanedFrames()
    }

    /// Re-enqueue frames that have processingStatus=0 but are not in the processing queue
    /// This happens when the app restarts before buffered frames were enqueued
    private func reEnqueueOrphanedFrames() async {
        guard let queue = await services.processingQueue else {
            Log.warning("[ORPHAN-RECOVERY] Processing queue not available", category: .app)
            return
        }

        do {
            let orphanedCount = try await services.database.countPendingFramesNotInQueue()
            if orphanedCount == 0 {
                Log.info("[ORPHAN-RECOVERY] No orphaned frames found", category: .app)
                return
            }

            Log.info("[ORPHAN-RECOVERY] Found \(orphanedCount) orphaned frames (pending but not in queue)", category: .app)

            // Process in batches to avoid memory issues
            let batchSize = 500
            var totalEnqueued = 0

            while true {
                let frameIDs = try await services.database.getPendingFrameIDsNotInQueue(limit: batchSize)
                if frameIDs.isEmpty {
                    break
                }

                for frameID in frameIDs {
                    // Enqueue without frame data (will extract from video)
                    try await queue.enqueue(frameID: frameID, priority: -1) // Low priority so new frames process first
                }

                totalEnqueued += frameIDs.count
                Log.info("[ORPHAN-RECOVERY] Enqueued batch of \(frameIDs.count) frames (total: \(totalEnqueued)/\(orphanedCount))", category: .app)

                // Small delay between batches to avoid overwhelming the queue
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            Log.info("[ORPHAN-RECOVERY] Completed - enqueued \(totalEnqueued) orphaned frames for OCR processing", category: .app)
        } catch {
            Log.error("[ORPHAN-RECOVERY] Failed to re-enqueue orphaned frames", category: .app, error: error)
        }
    }

    /// Register Rewind data source if enabled
    /// Should be called after onboarding completes if user opted in
    public func registerRewindSourceIfEnabled() async throws {
        try await services.registerRewindSourceIfEnabled()
    }

    /// Set Rewind data source enabled/disabled
    /// Updates UserDefaults and connects/disconnects the data source immediately
    public func setRewindSourceEnabled(_ enabled: Bool) async {
        await services.setRewindSourceEnabled(enabled)
    }

    /// Setup callback for accessibility permission warnings
    public func setupAccessibilityWarningCallback(_ callback: @escaping @Sendable () -> Void) async {
        services.capture.onAccessibilityPermissionWarning = callback
    }

    // MARK: - Recording State Persistence

    private static let recordingStateKey = "shouldAutoStartRecording"
    /// Use a fixed suite name so it works regardless of how the app is launched (swift build vs .app bundle)
    private static let userDefaultsSuite = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Save recording state to UserDefaults for persistence across app restarts
    private nonisolated func saveRecordingState(_ isRecording: Bool) {
        Self.userDefaultsSuite.set(isRecording, forKey: Self.recordingStateKey)
        Self.userDefaultsSuite.synchronize()  // Force immediate write to disk
        Log.debug("[AppCoordinator] saveRecordingState(\(isRecording)) - saved to UserDefaults", category: .app)
    }

    /// Check if recording should auto-start based on previous state
    public nonisolated static func shouldAutoStartRecording() -> Bool {
        let value = userDefaultsSuite.bool(forKey: recordingStateKey)
        Log.debug("[AppCoordinator] shouldAutoStartRecording() checking key '\(recordingStateKey)' in suite 'Retrace' = \(value)", category: .app)
        return value
    }

    /// Start the capture pipeline
    public func startPipeline() async throws {
        guard !isRunning else {
            Log.warning("Pipeline already running", category: .app)
            return
        }

        Log.info("Starting capture pipeline...", category: .app)

        // Check permissions first
        guard await services.capture.hasPermission() else {
            Log.error("Screen recording permission not granted", category: .app)
            throw AppError.permissionDenied(permission: "screen recording")
        }

        // Set up callback for when capture stops unexpectedly (e.g., user clicks "Stop sharing")
        services.capture.onCaptureStopped = { [weak self] in
            guard let self = self else { return }
            await self.handleCaptureStopped()
        }

        // Start screen capture
        try await services.capture.startCapture(config: await services.capture.getConfig())

        // Start permission monitoring to detect if user revokes permissions while recording
        await startPermissionMonitoring()

        // ⚠️ RELEASE 2 ONLY - Audio capture commented out
        // // Start audio capture
        // let audioConfig = AudioCaptureConfig.default
        // try await services.audioCapture.startCapture(config: audioConfig)
        // Log.info("Audio capture started", category: .app)

        // Start processing pipelines
        isRunning = true
        pipelineStartTime = Date()
        captureTask = Task {
            await runPipeline()
        }
        // ⚠️ RELEASE 2 ONLY
        // audioTask = Task {
        //     await runAudioPipeline()
        // }

        // Save recording state for persistence across restarts
        saveRecordingState(true)

        // Start storage accessibility monitoring (detects disconnected drives)
        startStorageMonitoring()

        Log.info("Capture pipeline started successfully", category: .app)
    }

    /// Stop the capture pipeline
    /// - Parameter persistState: If true, saves recording state as stopped. Set to false during shutdown
    ///   so the app remembers recording was active and auto-starts on next launch.
    public func stopPipeline(persistState: Bool = true) async throws {
        guard isRunning else {
            Log.warning("Pipeline not running", category: .app)
            return
        }

        Log.info("Stopping capture pipeline...", category: .app)

        // Stop permission monitoring
        await stopPermissionMonitoring()

        // Stop storage accessibility monitoring
        stopStorageMonitoring()

        // Stop screen capture
        try await services.capture.stopCapture()

        // ⚠️ RELEASE 2 ONLY
        // // Stop audio capture
        // try await services.audioCapture.stopCapture()

        // Cancel pipeline tasks
        captureTask?.cancel()
        captureTask = nil
        // ⚠️ RELEASE 2 ONLY
        // audioTask?.cancel()
        // audioTask = nil

        // Wait for processing queue to drain
        await services.processing.waitForQueueDrain()
        // Audio processing drains automatically when stream ends

        isRunning = false

        // Only save recording state as stopped if explicitly requested (user clicked stop)
        // During shutdown, we want to preserve the "recording" state so it auto-starts next launch
        if persistState {
            saveRecordingState(false)
        }

        Log.info("Capture pipeline stopped successfully", category: .app)
    }

    /// Shutdown all services
    public func shutdown() async throws {
        if isRunning {
            // Don't persist state as stopped - we want to auto-start on next launch
            try await stopPipeline(persistState: false)
        }

        Log.info("Shutting down AppCoordinator...", category: .app)
        try await services.shutdown()
        Log.info("AppCoordinator shutdown complete", category: .app)
    }

    /// Handle capture stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleCaptureStopped() async {
        guard isRunning else { return }

        Log.info("Capture stopped unexpectedly, cleaning up pipeline...", category: .app)

        // Cancel pipeline tasks
        captureTask?.cancel()
        captureTask = nil

        // Wait for processing queue to drain
        await services.processing.waitForQueueDrain()

        isRunning = false
        Log.info("Pipeline cleanup complete after unexpected stop", category: .app)
    }

    // MARK: - Storage Accessibility Monitoring

    /// Monitor storage accessibility and stop recording if storage becomes unavailable
    /// (e.g., external drive disconnected)
    private func startStorageMonitoring() {
        storageMonitorTask?.cancel()

        storageMonitorTask = Task { [weak self] in
            let checkInterval: UInt64 = 5_000_000_000 // 5 seconds

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkInterval)
                guard !Task.isCancelled else { break }

                let storagePath = AppPaths.expandedStorageRoot
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: storagePath, isDirectory: &isDirectory)

                if !exists || !isDirectory.boolValue {
                    Log.error("[AppCoordinator] Storage path inaccessible: \(storagePath) - stopping recording", category: .app)

                    guard let self = self else { break }
                    try? await self.stopPipeline()

                    // Post notification so UI can alert user
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("StorageInaccessible"),
                            object: nil
                        )
                    }
                    break
                }
            }
        }
    }

    private func stopStorageMonitoring() {
        storageMonitorTask?.cancel()
        storageMonitorTask = nil
    }

    // MARK: - Permission Monitoring

    /// Start monitoring for permission changes while recording
    /// Gracefully stops the pipeline if permissions are revoked
    private func startPermissionMonitoring() async {
        guard !permissionMonitorSetup else { return }
        permissionMonitorSetup = true

        // Set up callbacks for permission revocation
        PermissionMonitor.shared.onScreenRecordingRevoked = { [weak self] in
            guard let self = self else { return }
            Log.error("[AppCoordinator] Screen recording permission revoked - stopping pipeline gracefully", category: .app)
            try? await self.stopPipeline()

            // Post notification so UI can alert user
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ScreenRecordingPermissionRevoked"),
                    object: nil
                )
            }
        }

        PermissionMonitor.shared.onAccessibilityRevoked = {
            Log.warning("[AppCoordinator] Accessibility permission revoked - display switching disabled", category: .app)

            // Post notification so UI can alert user
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("AccessibilityPermissionRevoked"),
                    object: nil
                )
            }
        }

        // Start the periodic permission check
        await PermissionMonitor.shared.startMonitoring()
        Log.info("[AppCoordinator] Permission monitoring started", category: .app)
    }

    /// Stop monitoring for permission changes
    private func stopPermissionMonitoring() async {
        await PermissionMonitor.shared.stopMonitoring()
        permissionMonitorSetup = false
        Log.info("[AppCoordinator] Permission monitoring stopped", category: .app)
    }

    // MARK: - Pipeline Implementation

    /// Buffered frame entry - stores both the frame ID and captured frame data
    private struct BufferedFrame {
        let frameID: Int64
        let capturedFrame: CapturedFrame
        /// The frame's index in the video segment (0-based)
        let frameIndexInSegment: Int
    }

    /// State for tracking a video writer by resolution
    private struct VideoWriterState {
        var writer: SegmentWriter
        var videoDBID: Int64
        var frameCount: Int
        var isReadable: Bool
        /// Buffer for frames waiting to be confirmed flushed to disk before marking readable
        var pendingFrames: [BufferedFrame]
        var width: Int
        var height: Int
    }

    /// Main pipeline: Capture → Storage → Processing → Database → Search
    /// Uses Rewind-style multi-resolution video writing
    private func runPipeline() async {
        Log.info("Pipeline processing started", category: .app)

        let frameStream = await services.capture.frameStream
        var writersByResolution: [String: VideoWriterState] = [:]
        let maxFramesPerSegment = 150
        let videoUpdateInterval = 5
        for await frame in frameStream {
            Log.debug("[Pipeline] Received frame from stream: \(frame.width)x\(frame.height), app=\(frame.metadata.appName)", category: .app)

            if Task.isCancelled {
                Log.info("Pipeline task cancelled", category: .app)
                break
            }

            // Skip frames entirely when loginwindow is frontmost (lock screen, login, etc.)
            if frame.metadata.appBundleID == "com.apple.loginwindow" {
                continue
            }

            // Skip frames when timeline is visible (don't record while user is viewing timeline)
            if isTimelineVisible {
                // Check if we need to flush pending frames before pausing
                if shouldFlushPendingFrames {
                    shouldFlushPendingFrames = false
                    if let processingQueue = await services.processingQueue {
                        for (resKey, state) in writersByResolution {
                            let pendingCount = state.pendingFrames.count
                            if pendingCount > 0 {
                                Log.info("[FLUSH] Timeline opened - enqueueing \(pendingCount) pending frames for OCR (keeping in buffer for later readable marking)", category: .app)
                                // Enqueue frames for OCR (uses cached pixel data, not video file)
                                // DON'T clear pendingFrames - they still need to be marked readable later
                                // when the fragment actually flushes to disk
                                for bufferedFrame in state.pendingFrames {
                                    try? await processingQueue.enqueue(frameID: bufferedFrame.frameID, capturedFrame: bufferedFrame.capturedFrame)
                                }
                                // Note: NOT clearing pendingFrames here - frames will be marked readable
                                // when flushedCount catches up in the normal pipeline flow
                            }
                        }
                    }
                }
                continue
            }

            do {
                let resolutionKey = "\(frame.width)x\(frame.height)"
                var writerState: VideoWriterState

                if var existingState = writersByResolution[resolutionKey] {
                    if existingState.frameCount >= maxFramesPerSegment {
                        try await finalizeWriter(&existingState, processingQueue: await services.processingQueue)
                        writersByResolution.removeValue(forKey: resolutionKey)
                        writerState = try await createNewWriterState(width: frame.width, height: frame.height)
                        writersByResolution[resolutionKey] = writerState
                    } else {
                        writerState = existingState
                    }
                } else {
                    if let unfinalised = try await services.database.getUnfinalisedVideoByResolution(
                        width: frame.width,
                        height: frame.height
                    ) {
                        Log.info("Resuming unfinalised video \(unfinalised.id) for resolution \(resolutionKey)", category: .app)
                        writerState = try await resumeWriterState(from: unfinalised)
                    } else {
                        writerState = try await createNewWriterState(width: frame.width, height: frame.height)
                    }
                    writersByResolution[resolutionKey] = writerState
                }

                try await writerState.writer.appendFrame(frame)

                // Verify encoder actually wrote the frame by checking its frame count
                // This detects if the encoder silently failed or auto-finalized
                let actualEncoderFrameCount = await writerState.writer.frameCount
                if actualEncoderFrameCount != writerState.frameCount + 1 {
                    Log.error("[ENCODER-MISMATCH] Encoder frame count (\(actualEncoderFrameCount)) != expected (\(writerState.frameCount + 1)) - encoder may have failed/finalized. Removing broken writer for videoDBID=\(writerState.videoDBID), resolution=\(resolutionKey)", category: .app)
                    try? await writerState.writer.cancel()
                    writersByResolution.removeValue(forKey: resolutionKey)
                    continue
                }

                writerState.frameCount += 1

                if writerState.width == 0 {
                    writerState.width = await writerState.writer.frameWidth
                    writerState.height = await writerState.writer.frameHeight
                }

                try await trackSessionChange(frame: frame)

                guard let appSegmentID = currentSegmentID else {
                    Log.warning("No current app segment ID for frame insertion", category: .app)
                    writersByResolution[resolutionKey] = writerState
                    continue
                }

                let frameIndexInSegment = writerState.frameCount - 1
                let frameRef = FrameReference(
                    id: FrameID(value: 0),
                    timestamp: frame.timestamp,
                    segmentID: AppSegmentID(value: appSegmentID),
                    videoID: VideoSegmentID(value: writerState.videoDBID),
                    frameIndexInSegment: frameIndexInSegment,
                    metadata: frame.metadata,
                    source: .native
                )
                let frameID = try await services.database.insertFrame(frameRef)

                Log.debug("[CAPTURE-DEBUG] Captured frameID=\(frameID), videoDBID=\(writerState.videoDBID), frameIndexInSegment=\(frameIndexInSegment), app=\(frame.metadata.appName)", category: .app)

                if writerState.frameCount % videoUpdateInterval == 0 {
                    let width = await writerState.writer.frameWidth
                    let height = await writerState.writer.frameHeight
                    let fileSize = await writerState.writer.currentFileSize
                    try await services.database.updateVideoSegment(
                        id: writerState.videoDBID,
                        width: width,
                        height: height,
                        fileSize: fileSize,
                        frameCount: writerState.frameCount
                    )
                }

                guard let processingQueue = await services.processingQueue else {
                    Log.error("Processing queue not initialized", category: .app)
                    writersByResolution[resolutionKey] = writerState
                    continue
                }

                // Create buffered frame entry with both ID, raw pixel data, and frame index
                let bufferedFrame = BufferedFrame(frameID: frameID, capturedFrame: frame, frameIndexInSegment: frameIndexInSegment)

                // Add frame to the pending buffer
                writerState.pendingFrames.append(bufferedFrame)

                // Check if first fragment has been written (makes video readable at all)
                if !writerState.isReadable {
                    writerState.isReadable = await writerState.writer.hasFragmentWritten
                    if writerState.isReadable {
                        Log.info("First video fragment written for \(resolutionKey) - frames now readable from disk", category: .app)
                    }
                }

                // Get the count of frames confirmed flushed to disk
                // Frames with frameIndex < flushedCount are guaranteed to be readable
                let flushedCount = await writerState.writer.framesFlushedToDisk

                // Mark frames as readable and enqueue for OCR if they've been flushed to disk
                while let firstFrame = writerState.pendingFrames.first,
                      firstFrame.frameIndexInSegment < flushedCount {
                    let frameToEnqueue = writerState.pendingFrames.removeFirst()
                    // DEBUG: Log to file when marking readable
                    let debugMsg = "[READABLE] frameID=\(frameToEnqueue.frameID) frameIndex=\(frameToEnqueue.frameIndexInSegment) flushedCount=\(flushedCount) videoDBID=\(writerState.videoDBID) writerFrameCount=\(writerState.frameCount)\n"
                    if let data = debugMsg.data(using: .utf8) {
                        let fileHandle = FileHandle(forWritingAtPath: "/tmp/retrace_debug.log") ?? {
                            FileManager.default.createFile(atPath: "/tmp/retrace_debug.log", contents: nil)
                            return FileHandle(forWritingAtPath: "/tmp/retrace_debug.log")!
                        }()
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                    // Mark frame as readable now that it's confirmed flushed to video file
                    try await services.database.markFrameReadable(frameID: frameToEnqueue.frameID)
                    // Pass the original captured frame pixels directly to OCR
                    try await processingQueue.enqueue(frameID: frameToEnqueue.frameID, capturedFrame: frameToEnqueue.capturedFrame)
                }

                writersByResolution[resolutionKey] = writerState
                totalFramesProcessed += 1

                if totalFramesProcessed % 10 == 0 {
                    Log.debug("Pipeline processed \(totalFramesProcessed) frames, \(writersByResolution.count) active writers", category: .app)
                }

            } catch let error as StorageError {
                totalErrors += 1
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)

                // If it's a file write failure, the writer is broken - remove it so a fresh one is created
                if case .fileWriteFailed = error {
                    let resolutionKey = "\(frame.width)x\(frame.height)"
                    if let brokenWriter = writersByResolution[resolutionKey] {
                        Log.warning("Removing broken writer for \(resolutionKey) due to write failure - will create fresh writer", category: .app)
                        try? await brokenWriter.writer.cancel()
                        writersByResolution.removeValue(forKey: resolutionKey)
                    }
                }
                continue
            } catch {
                totalErrors += 1
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)
                continue
            }
        }

        // Save all remaining writers (unfinalised - can be resumed later)
        for (resolutionKey, var writerState) in writersByResolution {
            do {
                let finalWidth = await writerState.writer.frameWidth
                let finalHeight = await writerState.writer.frameHeight
                let finalSize = await writerState.writer.currentFileSize
                try await services.database.updateVideoSegment(
                    id: writerState.videoDBID,
                    width: finalWidth,
                    height: finalHeight,
                    fileSize: finalSize,
                    frameCount: writerState.frameCount
                )
                _ = try await writerState.writer.finalize()
                Log.info("Video segment for \(resolutionKey) saved (unfinalised, \(writerState.frameCount) frames)", category: .app)

                // After finalization, all frames are readable - mark them and enqueue for OCR
                if let processingQueue = await services.processingQueue {
                    for bufferedFrame in writerState.pendingFrames {
                        try await services.database.markFrameReadable(frameID: bufferedFrame.frameID)
                        try await processingQueue.enqueue(frameID: bufferedFrame.frameID, capturedFrame: bufferedFrame.capturedFrame)
                    }
                }
            } catch {
                Log.error("[Pipeline] Failed to save video segment for \(resolutionKey)", category: .app, error: error)
            }
        }

        if let segmentID = currentSegmentID {
            try? await services.database.updateSegmentEndDate(id: segmentID, endDate: Date())
            currentSegmentID = nil
        }

        Log.info("Pipeline processing completed. Total frames: \(totalFramesProcessed), Errors: \(totalErrors)", category: .app)
    }

    private func createNewWriterState(width: Int, height: Int) async throws -> VideoWriterState {
        let writer = try await services.storage.createSegmentWriter()
        let relativePath = await writer.relativePath

        let placeholderSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date(),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: relativePath,
            width: width,
            height: height
        )
        let videoDBID = try await services.database.insertVideoSegment(placeholderSegment)
        Log.debug("New video segment created with DB ID: \(videoDBID) for resolution \(width)x\(height)", category: .app)

        return VideoWriterState(
            writer: writer,
            videoDBID: videoDBID,
            frameCount: 0,
            isReadable: false,
            pendingFrames: [],
            width: width,
            height: height
        )
    }

    private func resumeWriterState(from unfinalised: UnfinalisedVideo) async throws -> VideoWriterState {
        let writer = try await services.storage.createSegmentWriter()

        // Get file size from filesystem for the old video
        let storageDir = await services.storage.getStorageDirectory()
        let oldVideoPath = storageDir.appendingPathComponent(unfinalised.relativePath).appendingPathExtension("mp4")
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: oldVideoPath.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        // Clean up WAL session for the old unfinalised video (frames are already in the video file)
        // The WAL directory is named with the segment timestampID (from relativePath), not the database ID
        // relativePath format: "chunks/YYYYMM/DD/{timestampID}" - extract the timestampID from the last component
        let timestampID = URL(fileURLWithPath: unfinalised.relativePath).lastPathComponent
        let walDir = storageDir.deletingLastPathComponent().appendingPathComponent("wal")
            .appendingPathComponent("active_segment_\(timestampID)")
        if FileManager.default.fileExists(atPath: walDir.path) {
            try? FileManager.default.removeItem(at: walDir)
            Log.info("Cleaned up WAL session for unfinalised video \(unfinalised.id) (timestampID: \(timestampID))", category: .app)
        }

        // Mark old video as finalized and start fresh
        // WARNING: This uses the frameCount from the database, which may differ from actual video file frames
        // if the app crashed before database was updated
        try await services.database.markVideoFinalized(id: unfinalised.id, frameCount: unfinalised.frameCount, fileSize: fileSize)
        Log.warning("[RESUME-DEBUG] Marked unfinalised video \(unfinalised.id) as finalized with DB frameCount=\(unfinalised.frameCount), fileSize=\(fileSize) bytes - NOTE: actual video frames may differ if app crashed!", category: .app)

        let relativePath = await writer.relativePath
        let placeholderSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date(),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: relativePath,
            width: unfinalised.width,
            height: unfinalised.height
        )
        let videoDBID = try await services.database.insertVideoSegment(placeholderSegment)

        return VideoWriterState(
            writer: writer,
            videoDBID: videoDBID,
            frameCount: 0,
            isReadable: false,
            pendingFrames: [],
            width: unfinalised.width,
            height: unfinalised.height
        )
    }

    private func finalizeWriter(_ writerState: inout VideoWriterState, processingQueue: FrameProcessingQueue?) async throws {
        // IMPORTANT: Finalize writer FIRST to ensure file is fully flushed to disk,
        // THEN mark as finalized in database. This prevents a race condition where
        // the timeline reads an incomplete video file before it's fully written.

        // Log before finalization for debugging
        let encoderFrameCount = await writerState.writer.frameCount
        Log.info("[FINALIZE-DEBUG] About to finalize videoDBID=\(writerState.videoDBID), writerState.frameCount=\(writerState.frameCount), encoderFrameCount=\(encoderFrameCount)", category: .app)

        _ = try await writerState.writer.finalize()
        let fileSize = await writerState.writer.currentFileSize
        try await services.database.markVideoFinalized(id: writerState.videoDBID, frameCount: writerState.frameCount, fileSize: fileSize)
        Log.info("[FINALIZE-DEBUG] Marked videoDBID=\(writerState.videoDBID) as finalized with frameCount=\(writerState.frameCount), fileSize=\(fileSize) bytes", category: .app)

        // After finalization, all frames are now readable from the video file
        // Mark them as readable and enqueue for OCR processing
        if let processingQueue = processingQueue {
            // Enqueue any pending frames that weren't yet marked readable
            if !writerState.pendingFrames.isEmpty {
                Log.debug("Enqueueing \(writerState.pendingFrames.count) pending frames after finalization", category: .app)
                for bufferedFrame in writerState.pendingFrames {
                    try await services.database.markFrameReadable(frameID: bufferedFrame.frameID)
                    try await processingQueue.enqueue(frameID: bufferedFrame.frameID, capturedFrame: bufferedFrame.capturedFrame)
                }
                writerState.pendingFrames = []
            }
        }
    }

    /// Track app/window changes and create/close segments accordingly
    /// Also handles idle detection - if no frames for longer than idleThresholdSeconds,
    /// closes the current segment and creates a new one on the next frame
    private func trackSessionChange(frame: CapturedFrame) async throws {
        let metadata = frame.metadata
        let captureConfig = await services.capture.getConfig()

        // Get current segment if exists
        var currentSegment: Segment? = nil
        if let segID = currentSegmentID {
            currentSegment = try await services.database.getSegment(id: segID)
        }

        // Check if app or window changed
        let appChanged = currentSegment?.bundleID != metadata.appBundleID
        let windowChanged = currentSegment?.windowName != metadata.windowName

        // Check for idle gap - if time since last frame exceeds threshold, treat as idle
        var idleDetected = false
        if let lastTimestamp = lastFrameTimestamp,
           captureConfig.idleThresholdSeconds > 0,
           currentSegment != nil {
            let timeSinceLastFrame = frame.timestamp.timeIntervalSince(lastTimestamp)
            if timeSinceLastFrame > captureConfig.idleThresholdSeconds {
                idleDetected = true
                Log.info("Idle detected: \(Int(timeSinceLastFrame))s gap (threshold: \(Int(captureConfig.idleThresholdSeconds))s)", category: .app)
            }
        }

        if appChanged || windowChanged || currentSegment == nil || idleDetected {
            // Close previous segment
            if let segID = currentSegmentID {
                // For idle detection, set end date to last frame timestamp + a small buffer
                // This prevents the segment from appearing to span the idle period
                let segmentEndDate: Date
                if idleDetected, let lastTimestamp = lastFrameTimestamp {
                    segmentEndDate = lastTimestamp
                } else {
                    segmentEndDate = frame.timestamp
                }
                try await services.database.updateSegmentEndDate(id: segID, endDate: segmentEndDate)
                Log.debug("Closed segment: \(currentSegment?.bundleID ?? "unknown") - \(currentSegment?.windowName ?? "nil")", category: .app)
            }

            // Create new segment
            let newSegmentID = try await services.database.insertSegment(
                bundleID: metadata.appBundleID ?? "unknown",
                startDate: frame.timestamp,
                endDate: frame.timestamp,  // Will be updated as frames are captured
                windowName: metadata.windowName,
                browserUrl: metadata.browserURL,
                type: 0  // 0 = screen capture
            )

            currentSegmentID = newSegmentID
            Log.debug("Started segment: \(metadata.appBundleID ?? "unknown") - \(metadata.windowName ?? "nil")", category: .app)
        }

        // Update last frame timestamp for idle detection
        lastFrameTimestamp = frame.timestamp
    }

    /// Audio pipeline: AudioCapture → AudioProcessing (whisper.cpp) → Database
    // ⚠️ RELEASE 2 ONLY - Audio pipeline commented out
    // private func runAudioPipeline() async {
    //     Log.info("Audio pipeline processing started", category: .app)
    //
    //     // Get the audio stream from capture
    //     let audioStream = await services.audioCapture.audioStream
    //
    //     // Start processing the stream (this will run until the stream ends)
    //     await services.audioProcessing.startProcessing(audioStream: audioStream)
    //
    //     Log.info("Audio pipeline processing completed", category: .app)
    // }

    // MARK: - Search Interface

    /// Get all distinct app bundle IDs from the database for filter UI
    /// Caller should use AppNameResolver.shared.resolveAll() to get display names
    public func getDistinctAppBundleIDs() async throws -> [String] {
        guard let adapter = await services.dataAdapter else {
            return []
        }
        return try await adapter.getDistinctAppBundleIDs()
    }

    /// Search for text across all captured frames
    public func search(query: String, limit: Int = 50) async throws -> SearchResults {
        let searchQuery = SearchQuery(text: query, filters: .none, limit: limit, offset: 0)
        return try await search(query: searchQuery)
    }

    /// Advanced search with filters
    /// Routes to DataAdapter which prioritizes Rewind data source
    public func search(query: SearchQuery) async throws -> SearchResults {
        // Try DataAdapter first (routes to Rewind if available)
        if let adapter = await services.dataAdapter {
            do {
                return try await adapter.search(query: query)
            } catch {
                Log.warning("[AppCoordinator] DataAdapter search failed, falling back to FTS: \(error)", category: .app)
            }
        }

        // Fallback to native FTS search
        return try await services.search.search(query: query)
    }

    // MARK: - Frame Retrieval

    /// Get a specific frame image by timestamp
    /// Uses real timestamps for accurate seeking (works correctly with deduplication)
    /// Automatically routes to appropriate source via DataAdapter
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        guard let adapter = await services.dataAdapter else {
            // Fallback to storage if adapter not available - need to query frame index from database
            let frames = try await services.database.getFrames(from: timestamp, to: timestamp, limit: 1)
            guard let frame = frames.first else {
                throw NSError(domain: "AppCoordinator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Frame not found"])
            }
            return try await services.storage.readFrame(segmentID: segmentID, frameIndex: frame.frameIndexInSegment)
        }

        return try await adapter.getFrameImage(segmentID: segmentID, timestamp: timestamp)
    }

    /// Get video info for a frame (returns nil if not video-based)
    /// For Rewind frames, returns path/index to display video directly
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date, source: FrameSource) async throws -> FrameVideoInfo? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, source: source)
    }

    /// Get frame image by exact videoID and frameIndex (more reliable than timestamp matching)
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int, source: FrameSource) async throws -> Data {
        guard let adapter = await services.dataAdapter else {
            throw NSError(domain: "AppCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "DataAdapter not initialized"])
        }

        return try await adapter.getFrameImageByIndex(videoID: videoID, frameIndex: frameIndex, source: source)
    }

    /// Get frame image directly using filename-based videoID (optimized, no database lookup)
    /// Use this when you already have the video filename from a JOIN query (e.g., FrameVideoInfo)
    /// - Parameters:
    ///   - filenameID: The Int64 filename (e.g., 1768624554519) extracted from the video path
    ///   - frameIndex: The frame index within the video segment
    /// - Returns: JPEG image data for the frame
    public func getFrameImageDirect(filenameID: Int64, frameIndex: Int) async throws -> Data {
        // Call storage directly with the filename-based ID - no database lookup needed!
        let videoSegmentID = VideoSegmentID(value: filenameID)
        return try await services.storage.readFrame(segmentID: videoSegmentID, frameIndex: frameIndex)
    }

    /// Get frame image from a full video path (used for Rewind frames with string-based IDs)
    public func getFrameImageFromPath(videoPath: String, frameIndex: Int) async throws -> Data {
        return try await services.storage.readFrameFromPath(videoPath: videoPath, frameIndex: frameIndex)
    }

    /// Get frames in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
        }

        return try await adapter.getFrames(from: startDate, to: endDate, limit: limit, filters: filters)
    }

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    /// This is the preferred method for timeline views to avoid N+1 queries
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit, filters: filters)
    }

    /// Get the most recent frames across all sources
    /// Returns frames sorted by timestamp descending (newest first)
    public func getMostRecentFrames(limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getMostRecentFrames(limit: limit)
        }

        return try await adapter.getMostRecentFrames(limit: limit, filters: filters)
    }

    /// Get the most recent frames with video info (optimized - single query with JOINs)
    public func getMostRecentFramesWithVideoInfo(limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getMostRecentFrames(limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
    }

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames sorted by timestamp descending (newest first of the older batch)
    public func getFramesBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesBefore(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames with video info before a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames sorted by timestamp ascending (oldest first of the newer batch)
    public func getFramesAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesAfter(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames with video info after a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get the timestamp of the most recent frame across all sources
    /// Returns nil if no frames exist in any source
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database - get most recent frame
            let frames = try await services.database.getMostRecentFrames(limit: 1)
            return frames.first?.timestamp
        }

        return try await adapter.getMostRecentFrameTimestamp()
    }

    /// Get a single frame by ID with video info (optimized - single query with JOINs)
    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFrameWithVideoInfoByID(id: id)
        }

        return try await adapter.getFrameWithVideoInfoByID(id: id)
    }

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus (0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable)
    public func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        return try await services.database.getFrameProcessingStatuses(frameIDs: frameIDs)
    }

    // MARK: - Segment Retrieval

    /// Get segments in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getSegments(from: startDate, to: endDate)
        }

        return try await adapter.getSegments(from: startDate, to: endDate)
    }

    /// Get the most recent segment
    public func getMostRecentSegment() async throws -> Segment? {
        try await services.database.getMostRecentSegment()
    }

    /// Get segments for a specific app
    public func getSegments(bundleID: String, limit: Int = 100) async throws -> [Segment] {
        try await services.database.getSegments(bundleID: bundleID, limit: limit)
    }

    /// Get segments for a specific app within a time range with pagination
    public func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        try await services.database.getSegments(
            bundleID: bundleID,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get segments filtered by bundle ID, time range, and window name or domain with pagination
    /// For browsers, filters by domain extracted from browserUrl; for other apps, filters by windowName
    public func getSegments(
        bundleID: String,
        windowNameOrDomain: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        try await services.database.getSegments(
            bundleID: bundleID,
            windowNameOrDomain: windowNameOrDomain,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get aggregated app usage stats (duration and unique window/domain count) for a time range
    /// For browsers, counts unique domains; for other apps, counts unique windowNames
    public func getAppUsageStats(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        try await services.database.getAppUsageStats(from: startDate, to: endDate)
    }

    /// Get window usage aggregated by windowName or domain for a specific app
    /// For browsers: returns websites (from browserUrl) first, then windowName fallbacks
    /// For non-browsers: returns windows by windowName
    /// Returns items sorted by type (websites first) then duration descending
    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, isWebsite: Bool, duration: TimeInterval)] {
        try await services.database.getWindowUsageForApp(bundleID: bundleID, from: startDate, to: endDate)
    }

    /// Get browser tab usage aggregated by windowName (tab title) with full URL
    /// Returns tabs sorted by duration descending
    public func getBrowserTabUsage(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        try await services.database.getBrowserTabUsage(bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsageForDomain(
        bundleID: String,
        domain: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        try await services.database.getBrowserTabUsageForDomain(bundleID: bundleID, domain: domain, from: startDate, to: endDate)
    }

    // MARK: - Tag Operations

    /// Get all tags
    public func getAllTags() async throws -> [Tag] {
        try await services.database.getAllTags()
    }

    /// Create a new tag
    public func createTag(name: String) async throws -> Tag {
        try await services.database.createTag(name: name)
    }

    /// Get a tag by name
    public func getTag(name: String) async throws -> Tag? {
        try await services.database.getTag(name: name)
    }

    /// Add a tag to a segment
    public func addTagToSegment(segmentId: SegmentID, tagId: TagID) async throws {
        try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Add a tag to multiple segments
    public func addTagToSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        for segmentId in segmentIds {
            try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
        }
        Log.info("[AppCoordinator] Added tag \(tagId.value) to \(segmentIds.count) segments", category: .app)
    }

    /// Remove a tag from a segment
    public func removeTagFromSegment(segmentId: SegmentID, tagId: TagID) async throws {
        try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Remove a tag from multiple segments
    public func removeTagFromSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        for segmentId in segmentIds {
            try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
        }
        Log.info("[AppCoordinator] Removed tag \(tagId.value) from \(segmentIds.count) segments", category: .app)
    }

    /// Get all tags for a segment
    public func getTagsForSegment(segmentId: SegmentID) async throws -> [Tag] {
        try await services.database.getTagsForSegment(segmentId: segmentId)
    }

    /// Delete a tag entirely
    public func deleteTag(tagId: TagID) async throws {
        try await services.database.deleteTag(tagId: tagId)
        Log.info("[AppCoordinator] Deleted tag \(tagId.value)", category: .app)
    }

    /// Get the count of segments that have a specific tag
    public func getSegmentCountForTag(tagId: TagID) async throws -> Int {
        try await services.database.getSegmentCountForTag(tagId: tagId)
    }

    /// Get all segment IDs that have the "hidden" tag
    public func getHiddenSegmentIds() async throws -> Set<SegmentID> {
        return try await services.database.getHiddenSegmentIds()
    }

    /// Get a map of segment IDs to their tag IDs for efficient filtering
    public func getSegmentTagsMap() async throws -> [Int64: Set<Int64>] {
        try await services.database.getSegmentTagsMap()
    }

    /// Hide a segment by adding the "hidden" tag
    public func hideSegment(segmentId: SegmentID) async throws {
        try await hideSegments(segmentIds: [segmentId])
    }

    /// Hide multiple segments by adding the "hidden" tag to each
    public func hideSegments(segmentIds: [SegmentID]) async throws {
        guard !segmentIds.isEmpty else { return }

        // Get or create the hidden tag
        let hiddenTag: Tag
        if let existing = try await services.database.getTag(name: Tag.hiddenTagName) {
            hiddenTag = existing
        } else {
            hiddenTag = try await services.database.createTag(name: Tag.hiddenTagName)
        }

        // Add the tag to all segments
        for segmentId in segmentIds {
            try await services.database.addTagToSegment(segmentId: segmentId, tagId: hiddenTag.id)
        }
        Log.info("[AppCoordinator] Hidden \(segmentIds.count) segments", category: .app)
    }

    // MARK: - Text Region Retrieval

    /// Get text regions for a frame (OCR bounding boxes)
    public func getTextRegions(frameID: FrameID) async throws -> [TextRegion] {
        // Get frame dimensions first
        // For now, use default dimensions - this should be improved to get actual frame size
        let nodes = try await services.database.getNodes(frameID: frameID, frameWidth: 1920, frameHeight: 1080)

        // Convert OCRNode to TextRegion
        return nodes.map { node in
            TextRegion(
                id: node.id,
                frameID: frameID,
                text: "", // Text not available from getNodes, use getNodesWithText if needed
                bounds: node.bounds,
                confidence: nil,
                createdAt: Date() // Not stored in node
            )
        }
    }

    // MARK: - Frame Deletion

    /// Delete a single frame from the database
    /// Note: For Rewind data, this only removes the database entry. Video files remain on disk.
    public func deleteFrame(frameID: FrameID, timestamp: Date, source: FrameSource) async throws {
        guard let adapter = await services.dataAdapter else {
            // Fallback to direct database deletion for native frames
            if source == .native {
                try await services.database.deleteFrame(id: frameID)
                Log.info("[AppCoordinator] Deleted native frame \(frameID.stringValue)", category: .app)
                return
            }
            throw AppError.notInitialized
        }

        // For Rewind frames, use timestamp-based deletion (more reliable than synthetic UUIDs)
        if source == .rewind {
            try await adapter.deleteFrameByTimestamp(timestamp, source: source)
        } else {
            try await adapter.deleteFrame(frameID: frameID, source: source)
        }

        Log.info("[AppCoordinator] Deleted frame from \(source.displayName)", category: .app)
    }

    /// Delete multiple frames from the database
    /// Groups by source and uses appropriate deletion method for each
    public func deleteFrames(_ frames: [FrameReference]) async throws {
        guard !frames.isEmpty else { return }

        // For Rewind frames, delete by timestamp (more reliable)
        // For native frames, delete by ID
        for frame in frames {
            try await deleteFrame(
                frameID: frame.id,
                timestamp: frame.timestamp,
                source: frame.source
            )
        }

        Log.info("[AppCoordinator] Deleted \(frames.count) frames", category: .app)
    }

    // MARK: - URL Bounding Box Detection

    /// Get the bounding box of a browser URL on screen for a given frame
    /// Returns the bounding box with normalized coordinates (0.0-1.0) if found
    /// Use this to highlight clickable URLs in the timeline view
    public func getURLBoundingBox(timestamp: Date, source: FrameSource) async throws -> URLBoundingBox? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getURLBoundingBox(timestamp: timestamp, source: source)
    }

    // MARK: - OCR Node Detection (for text selection)

    /// Get all OCR nodes for a given frame by timestamp
    /// Returns array of nodes with normalized bounding boxes (0.0-1.0) and text content
    /// Use this to enable text selection highlighting in the timeline view
    public func getAllOCRNodes(timestamp: Date, source: FrameSource) async throws -> [OCRNodeWithText] {
        guard let adapter = await services.dataAdapter else {
            return []
        }

        return try await adapter.getAllOCRNodes(timestamp: timestamp, source: source)
    }

    /// Get all OCR nodes for a given frame by frameID (more reliable than timestamp)
    /// Returns array of nodes with normalized bounding boxes (0.0-1.0) and text content
    /// Use this for search results where you have the exact frameID
    public func getAllOCRNodes(frameID: FrameID, source: FrameSource) async throws -> [OCRNodeWithText] {
        guard let adapter = await services.dataAdapter else {
            return []
        }

        return try await adapter.getAllOCRNodes(frameID: frameID, source: source)
    }

    // MARK: - OCR Status

    /// Get the OCR processing status for a specific frame
    /// Returns the processing status combined with queue information
    public func getOCRStatus(frameID: FrameID) async throws -> OCRProcessingStatus {
        let statusInt = try await services.database.getFrameProcessingStatus(frameID: frameID.value)

        guard let status = statusInt else {
            return .unknown
        }

        switch status {
        case 0: // pending
            // Check if in queue and get position
            let queuePosition = try await services.database.getFrameQueuePosition(frameID: frameID.value)
            if queuePosition != nil {
                return .queued(position: queuePosition, depth: nil)
            }
            return .pending
        case 1: // processing
            return .processing
        case 2: // completed
            return .completed
        case 3: // failed
            return .failed
        default:
            return .unknown
        }
    }

    // MARK: - OCR Reprocessing

    /// Reprocess OCR for a specific frame
    /// This clears existing OCR data and re-enqueues the frame for processing
    public func reprocessOCR(frameID: FrameID) async throws {
        Log.info("[OCR-REPROCESS] Starting reprocess for frame \(frameID.value)", category: .processing)

        // Record OCR reprocess metric
        try? await recordMetricEvent(metricType: .ocrReprocessRequests, metadata: "\(frameID.value)")

        // Clear existing OCR nodes for this frame
        try await services.database.deleteNodes(frameID: frameID)
        Log.info("[OCR-REPROCESS] Deleted nodes for frame \(frameID.value)", category: .processing)

        // Clear existing FTS entry for this frame
        try await services.database.deleteFTSContent(frameId: frameID.value)
        Log.info("[OCR-REPROCESS] Deleted FTS content for frame \(frameID.value)", category: .processing)

        // Reset processingStatus to 0 (pending) so frame can be re-enqueued
        try await services.database.updateFrameProcessingStatus(frameID: frameID.value, status: 0)
        Log.info("[OCR-REPROCESS] Reset processingStatus to pending for frame \(frameID.value)", category: .processing)

        // Enqueue for reprocessing with high priority
        guard let queue = await services.processingQueue else {
            Log.error("[OCR-REPROCESS] Processing queue not available!", category: .processing)
            throw AppError.processingQueueNotAvailable
        }

        // Check queue depth before enqueue
        let depthBefore = try await queue.getQueueDepth()
        Log.info("[OCR-REPROCESS] Queue depth before enqueue: \(depthBefore)", category: .processing)

        try await queue.enqueue(frameID: frameID.value, priority: 100)

        // Check queue depth after enqueue
        let depthAfter = try await queue.getQueueDepth()
        Log.info("[OCR-REPROCESS] Frame \(frameID.value) enqueued with priority 100, queue depth now: \(depthAfter)", category: .processing)
    }

    // MARK: - Migration

    /// Import data from Rewind AI
    public func importFromRewind(
        chunkDirectory: String,
        progressHandler: @escaping @Sendable (MigrationProgress) -> Void
    ) async throws {
        Log.info("Starting Rewind import from: \(chunkDirectory)", category: .app)

        // Setup migration manager with default importers (includes RewindImporter)
        await services.migration.setupDefaultImporters()

        // Create delegate to forward progress
        let delegate = MigrationProgressDelegate(progressHandler: progressHandler)

        // Start import
        try await services.migration.startImport(
            source: .rewind,
            delegate: delegate
        )

        Log.info("Rewind import completed", category: .app)
    }

    // MARK: - Calendar Support

    /// Get all distinct dates that have frames (for calendar display)
    /// Uses filesystem (chunks folder structure) instead of slow database queries
    /// Checks both Retrace chunks and Rewind chunks (if Rewind is connected)
    public func getDistinctDates() async throws -> [Date] {
        var allDates = Set<Date>()

        // Get dates from Retrace chunks folder
        let retraceRoot = await services.storage.getStorageDirectory()
        let retraceDates = getDatesFromChunksFolder(at: retraceRoot.appendingPathComponent("chunks"))
        allDates.formUnion(retraceDates)

        // Get dates from Rewind chunks folder if connected
        // Uses rewindStorageRootPath which returns nil if Rewind not connected
        if let adapter = await services.dataAdapter,
           let rewindPath = await adapter.rewindStorageRootPath {
            let rewindChunks = URL(fileURLWithPath: rewindPath).appendingPathComponent("chunks")
            let rewindDates = getDatesFromChunksFolder(at: rewindChunks)
            allDates.formUnion(rewindDates)
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    /// Extract dates from chunks folder structure (chunks/YYYYMM/DD/)
    private func getDatesFromChunksFolder(at chunksURL: URL) -> Set<Date> {
        var dates = Set<Date>()
        let fileManager = FileManager.default
        let calendar = Calendar.current

        guard let yearMonthFolders = try? fileManager.contentsOfDirectory(
            at: chunksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return dates
        }

        for yearMonthFolder in yearMonthFolders {
            let yearMonthStr = yearMonthFolder.lastPathComponent
            guard yearMonthStr.count == 6,
                  let year = Int(yearMonthStr.prefix(4)),
                  let month = Int(yearMonthStr.suffix(2)) else {
                continue
            }

            guard let dayFolders = try? fileManager.contentsOfDirectory(
                at: yearMonthFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for dayFolder in dayFolders {
                let dayStr = dayFolder.lastPathComponent
                guard let day = Int(dayStr) else { continue }

                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                    dates.insert(date)
                }
            }
        }

        return dates
    }

    // MARK: - Storage Statistics

    /// Get total storage used in bytes (Retrace + Rewind if enabled)
    public func getTotalStorageUsed() async throws -> Int64 {
        // Check if Rewind is enabled via DataAdapter
        let includeRewind = await services.dataAdapter?.rewindStorageRootPath != nil
        return try await services.storage.getTotalStorageUsed(includeRewind: includeRewind)
    }

    /// Get storage used for a specific date range
    public func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        try await services.storage.getStorageUsedForDateRange(from: startDate, to: endDate)
    }

    /// Get total captured duration across all Retrace segments in seconds
    /// Only counts time captured by Retrace (excludes imported Rewind data)
    public func getTotalCapturedDuration() async throws -> TimeInterval {
        try await services.database.getTotalCapturedDuration()
    }

    /// Get captured duration for Retrace segments starting after a given date
    public func getCapturedDurationAfter(date: Date) async throws -> TimeInterval {
        try await services.database.getCapturedDurationAfter(date: date)
    }

    /// Get distinct hours for a specific date that have frames
    /// Uses DataAdapter to query the appropriate database (Retrace or Rewind) based on date
    public func getDistinctHoursForDate(_ date: Date) async throws -> [Date] {
        if let adapter = await services.dataAdapter {
            return try await adapter.getDistinctHoursForDate(date)
        }
        // Fallback to Retrace-only query
        return try await services.database.getDistinctHoursForDate(date)
    }

    // MARK: - Daily Metrics

    /// Record a single metric event (timeline open, search, text copy)
    public func recordMetricEvent(
        metricType: DailyMetricsQueries.MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) async throws {
        try await services.database.recordMetricEvent(
            metricType: metricType,
            timestamp: timestamp,
            metadata: metadata
        )
    }

    /// Get daily counts for a metric type (for 7-day graphs)
    /// Returns array of (date, count) tuples sorted by date ascending
    public func getDailyMetrics(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await services.database.getDailyMetrics(
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get daily screen time totals (for 7-day graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await services.database.getDailyScreenTime(
            from: startDate,
            to: endDate
        )
    }

    // MARK: - Statistics & Monitoring

    /// Check if screen capture is currently active
    public func isCapturing() async -> Bool {
        await services.capture.isCapturing
    }

    /// Get comprehensive app statistics
    public func getStatistics() async throws -> AppStatistics {
        let dbStats = try await services.getDatabaseStats()
        let searchStats = await services.getSearchStats()
        let captureStats = await services.getCaptureStats()
        let processingStats = await services.getProcessingStats()

        let uptime: TimeInterval?
        if let startTime = pipelineStartTime {
            uptime = Date().timeIntervalSince(startTime)
        } else {
            uptime = nil
        }

        return AppStatistics(
            isRunning: isRunning,
            uptime: uptime,
            totalFramesProcessed: totalFramesProcessed,
            totalErrors: totalErrors,
            database: dbStats,
            search: searchStats,
            capture: captureStats,
            processing: processingStats
        )
    }

    /// Get database statistics for feedback/diagnostics
    public func getDatabaseStatistics() async throws -> DatabaseStatistics {
        try await services.getDatabaseStats()
    }

    /// Get app session count (distinct from video segment count)
    public func getAppSessionCount() async throws -> Int {
        try await services.getAppSessionCount()
    }

    /// Get quick database statistics (single query, for feedback diagnostics)
    public func getDatabaseStatisticsQuick() async throws -> (frameCount: Int, sessionCount: Int) {
        try await services.getDatabaseStatsQuick()
    }

    /// Get current pipeline status
    public func getStatus() -> PipelineStatus {
        PipelineStatus(
            isRunning: isRunning,
            framesProcessed: totalFramesProcessed,
            errors: totalErrors,
            startTime: pipelineStartTime
        )
    }

    // MARK: - Maintenance

    /// Cleanup old data (older than specified date)
    public func cleanupOldData(olderThan date: Date) async throws -> CleanupResult {
        Log.info("Starting cleanup for data older than \(date)", category: .app)

        // Delete old frames from database
        let deletedFrameCount = try await services.database.deleteFrames(olderThan: date)

        // Delete old segments from storage
        let deletedSegmentIDs = try await services.storage.cleanupOldSegments(olderThan: date)

        // Delete corresponding segments from database
        for segmentID in deletedSegmentIDs {
            try await services.database.deleteVideoSegment(id: segmentID)
        }

        // Vacuum database to reclaim space
        try await services.database.vacuum()

        Log.info("Cleanup complete. Deleted \(deletedFrameCount) frames, \(deletedSegmentIDs.count) segments", category: .app)

        return CleanupResult(
            deletedFrames: deletedFrameCount,
            deletedSegments: deletedSegmentIDs.count,
            reclaimedBytes: 0 // TODO: Calculate actual reclaimed space
        )
    }

    /// Delete recent data (newer than specified date) - used for quick delete feature
    /// This deletes all frames captured after the cutoff date
    public func deleteRecentData(newerThan date: Date) async throws -> CleanupResult {
        Log.info("Starting quick delete for data newer than \(date)", category: .app)

        // Delete recent frames from database
        let deletedFrameCount = try await services.database.deleteFrames(newerThan: date)

        // Note: Video segments are not deleted here because they may contain older frames too
        // The storage cleanup based on retention policy will handle orphaned segments

        // Vacuum database to reclaim space
        try await services.database.vacuum()

        Log.info("Quick delete complete. Deleted \(deletedFrameCount) frames", category: .app)

        return CleanupResult(
            deletedFrames: deletedFrameCount,
            deletedSegments: 0, // Segments are not deleted in quick delete
            reclaimedBytes: 0
        )
    }

    /// Rebuild the search index
    public func rebuildSearchIndex() async throws {
        Log.info("Rebuilding search index...", category: .app)
        try await services.search.rebuildIndex()
        Log.info("Search index rebuild complete", category: .app)
    }

    /// Run database maintenance (checkpoint WAL, analyze)
    public func runDatabaseMaintenance() async throws {
        Log.info("Running database maintenance...", category: .app)

        try await services.database.checkpoint()
        try await services.database.analyze()

        Log.info("Database maintenance complete", category: .app)
    }

    /// Get database schema description for debugging
    public func getDatabaseSchemaDescription() async throws -> String {
        try await services.database.getSchemaDescription()
    }
}

// MARK: - Supporting Types

public struct AppStatistics: Sendable {
    public let isRunning: Bool
    public let uptime: TimeInterval?
    public let totalFramesProcessed: Int
    public let totalErrors: Int
    public let database: DatabaseStatistics
    public let search: SearchStatistics
    public let capture: CaptureStatistics
    public let processing: ProcessingStatistics
}

public struct PipelineStatus: Sendable {
    public let isRunning: Bool
    public let framesProcessed: Int
    public let errors: Int
    public let startTime: Date?
}

public struct CleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedSegments: Int
    public let reclaimedBytes: Int64
}

/// OCR processing status for a frame
/// Provides detailed status information for UI display
public struct OCRProcessingStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// OCR completed successfully - text is available
        case completed
        /// Frame is pending but not yet in processing queue
        case pending
        /// Frame is in the processing queue waiting to be processed
        case queued
        /// Frame is currently being processed (OCR in progress)
        case processing
        /// OCR failed permanently
        case failed
        /// Frame not found or status unknown
        case unknown
    }

    public let state: State
    /// Position in queue (1 = next to be processed), nil if not in queue
    public let queuePosition: Int?
    /// Total items in the queue
    public let queueDepth: Int?

    public init(state: State, queuePosition: Int? = nil, queueDepth: Int? = nil) {
        self.state = state
        self.queuePosition = queuePosition
        self.queueDepth = queueDepth
    }

    /// Human-readable description for display
    public var displayText: String {
        switch state {
        case .completed: return "OCR Complete"
        case .pending: return "Indexing text..."
        case .queued:
            if let position = queuePosition {
                return "Queued #\(position)"
            }
            return "Queued"
        case .processing: return "Indexing..."
        case .failed: return "OCR Failed"
        case .unknown: return ""
        }
    }

    /// Whether OCR is still in progress (queued or processing)
    public var isInProgress: Bool {
        switch state {
        case .queued, .processing, .pending:
            return true
        case .completed, .failed, .unknown:
            return false
        }
    }

    // Convenience static constructors
    public static let completed = OCRProcessingStatus(state: .completed)
    public static let pending = OCRProcessingStatus(state: .pending)
    public static let processing = OCRProcessingStatus(state: .processing)
    public static let failed = OCRProcessingStatus(state: .failed)
    public static let unknown = OCRProcessingStatus(state: .unknown)

    public static func queued(position: Int?, depth: Int?) -> OCRProcessingStatus {
        OCRProcessingStatus(state: .queued, queuePosition: position, queueDepth: depth)
    }
}

public enum AppError: Error {
    case permissionDenied(permission: String)
    case notInitialized
    case alreadyRunning
    case notRunning
    case processingQueueNotAvailable
}

// MARK: - Migration Delegate

/// Simple delegate wrapper to forward progress updates to a closure
private final class MigrationProgressDelegate: MigrationDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (MigrationProgress) -> Void

    init(progressHandler: @escaping @Sendable (MigrationProgress) -> Void) {
        self.progressHandler = progressHandler
    }

    func migrationDidUpdateProgress(_ progress: MigrationProgress) {
        progressHandler(progress)
    }

    func migrationDidStartProcessingVideo(at path: String, index: Int, total: Int) {
        Log.debug("Started processing video \(index)/\(total): \(path)", category: .app)
    }

    func migrationDidFinishProcessingVideo(at path: String, framesImported: Int) {
        Log.debug("Finished processing video: \(path) (\(framesImported) frames)", category: .app)
    }

    func migrationDidFailProcessingVideo(at path: String, error: Error) {
        Log.error("[Migration] Failed processing video: \(path)", category: .app, error: error)
    }

    func migrationDidComplete(result: MigrationResult) {
        Log.info("Migration completed: \(result.framesImported) frames imported", category: .app)
    }

    func migrationDidFail(error: Error) {
        Log.error("[Migration] Failed", category: .app, error: error)
    }
}
