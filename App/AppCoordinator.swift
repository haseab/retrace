import Foundation
import Shared
import Database
import Storage
import Capture
import Processing
import Search
import Migration
import CoreGraphics
import ImageIO

// MARK: - OCR Power Settings Notifications

public enum OCRPowerSettingsNotification {
    public static let didChange = Notification.Name("PowerSettingsDidChange")
}

/// Snapshot of OCR power settings, used to apply settings immediately without
/// relying on asynchronous UserDefaults propagation.
public struct OCRPowerSettingsSnapshot: Sendable {
    public let ocrEnabled: Bool
    public let pauseOnBattery: Bool
    public let pauseOnLowPowerMode: Bool
    public let processingLevel: Int
    public let appFilterModeRaw: String
    public let filteredAppsJSON: String

    public init(
        ocrEnabled: Bool,
        pauseOnBattery: Bool,
        pauseOnLowPowerMode: Bool,
        processingLevel: Int,
        appFilterModeRaw: String,
        filteredAppsJSON: String
    ) {
        self.ocrEnabled = ocrEnabled
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.processingLevel = processingLevel
        self.appFilterModeRaw = appFilterModeRaw
        self.filteredAppsJSON = filteredAppsJSON
    }

    public static func fromDefaults(
        _ defaults: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    ) -> OCRPowerSettingsSnapshot {
        OCRPowerSettingsSnapshot(
            ocrEnabled: defaults.object(forKey: "ocrEnabled") as? Bool ?? true,
            pauseOnBattery: defaults.bool(forKey: "ocrOnlyWhenPluggedIn"),
            pauseOnLowPowerMode: defaults.bool(forKey: "ocrPauseInLowPowerMode"),
            processingLevel: (defaults.object(forKey: "ocrProcessingLevel") as? NSNumber)?.intValue ?? 3,
            appFilterModeRaw: defaults.string(forKey: "ocrAppFilterMode") ?? "all",
            filteredAppsJSON: defaults.string(forKey: "ocrFilteredApps") ?? ""
        )
    }
}

// MARK: - Thread-Safe Status Holder

/// Thread-safe holder for pipeline status that can be read without actor isolation.
/// This prevents task pile-up when UI polls for status while the actor is busy.
public final class PipelineStatusHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _isRunning = false
    private var _framesProcessed = 0
    private var _errors = 0
    private var _startTime: Date?

    // Diagnostics for UI responsiveness tracking
    private var _pendingActorRequests = 0
    private var _maxPendingRequests = 0
    private var _slowResponseCount = 0
    private var _lastActorResponseTime: Date?

    public var status: PipelineStatus {
        lock.lock()
        defer { lock.unlock() }
        return PipelineStatus(
            isRunning: _isRunning,
            framesProcessed: _framesProcessed,
            errors: _errors,
            startTime: _startTime
        )
    }

    /// Diagnostics about actor responsiveness (for detecting potential UI freeze conditions)
    public var diagnostics: (pendingRequests: Int, maxPending: Int, slowResponses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_pendingActorRequests, _maxPendingRequests, _slowResponseCount)
    }

    func update(isRunning: Bool? = nil, framesProcessed: Int? = nil, errors: Int? = nil, startTime: Date?? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let isRunning = isRunning { _isRunning = isRunning }
        if let framesProcessed = framesProcessed { _framesProcessed = framesProcessed }
        if let errors = errors { _errors = errors }
        if let startTime = startTime { _startTime = startTime }
    }

    func incrementFrames() {
        lock.lock()
        defer { lock.unlock() }
        _framesProcessed += 1
    }

    func incrementErrors() {
        lock.lock()
        defer { lock.unlock() }
        _errors += 1
    }

    /// Track when an actor request starts (call before await)
    public func trackActorRequestStart() {
        lock.lock()
        defer { lock.unlock() }
        _pendingActorRequests += 1
        if _pendingActorRequests > _maxPendingRequests {
            _maxPendingRequests = _pendingActorRequests
        }
    }

    /// Track when an actor request completes (call after await returns)
    public func trackActorRequestEnd(startTime: Date) {
        lock.lock()
        defer { lock.unlock() }
        _pendingActorRequests = max(0, _pendingActorRequests - 1)
        _lastActorResponseTime = Date()

        // Track slow responses (> 100ms is concerning for UI)
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > 0.1 {
            _slowResponseCount += 1
        }
    }

    /// Reset diagnostic counters (call periodically, e.g., every hour)
    public func resetDiagnostics() {
        lock.lock()
        defer { lock.unlock() }
        _maxPendingRequests = _pendingActorRequests
        _slowResponseCount = 0
    }
}

/// Best-effort writer for prewarming capture-time timeline stills on disk.
/// This path is lossy by design: when disk/JPEG work falls behind, we prefer
/// dropping older pending stills over retaining unbounded raw frame memory.
actor TimelineStillDiskWriter {
    struct Diagnostics: Sendable {
        var enqueuedCount = 0
        var writtenCount = 0
        var droppedCount = 0
        var failureCount = 0
        var terminatedEnqueueCount = 0
    }

    private struct WriteRequest: Sendable {
        let frameID: Int64
        let frame: CapturedFrame
    }

    typealias DestinationResolver = @Sendable (Int64) -> URL
    typealias Encoder = @Sendable (CapturedFrame) throws -> Data
    typealias WarningLogger = @Sendable (String) -> Void

    private let destinationResolver: DestinationResolver
    private let encoder: Encoder
    private let warningLogger: WarningLogger
    private let stream: AsyncStream<WriteRequest>
    private let continuation: AsyncStream<WriteRequest>.Continuation

    private var workerTask: Task<Void, Never>?
    private var diagnostics = Diagnostics()
    private var isClosed = false

    init(
        bufferLimit: Int,
        destinationResolver: @escaping DestinationResolver,
        encoder: @escaping Encoder,
        warningLogger: @escaping WarningLogger
    ) {
        let (stream, continuation) = AsyncStream<WriteRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        self.destinationResolver = destinationResolver
        self.encoder = encoder
        self.warningLogger = warningLogger
        self.stream = stream
        self.continuation = continuation
    }

    func enqueue(frameID: Int64, frame: CapturedFrame) {
        guard !isClosed else { return }

        startWorkerIfNeeded()
        diagnostics.enqueuedCount += 1

        switch continuation.yield(WriteRequest(frameID: frameID, frame: frame)) {
        case .enqueued:
            break
        case .dropped(let droppedRequest):
            diagnostics.droppedCount += 1
            if diagnostics.droppedCount == 1 || diagnostics.droppedCount.isMultiple(of: 25) {
                warningLogger(
                    "[Timeline-DiskBuffer] Dropped backlogged capture-time still for frame \(droppedRequest.frameID) (dropped=\(diagnostics.droppedCount))"
                )
            }
        case .terminated:
            diagnostics.terminatedEnqueueCount += 1
        @unknown default:
            diagnostics.terminatedEnqueueCount += 1
        }
    }

    func shutdown() async {
        guard !isClosed else {
            if let workerTask {
                await workerTask.value
            }
            return
        }

        isClosed = true
        continuation.finish()
        if let workerTask {
            await workerTask.value
            self.workerTask = nil
        }
    }

    func diagnosticsSnapshot() -> Diagnostics {
        diagnostics
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }

        let stream = self.stream
        let destinationResolver = self.destinationResolver
        let encoder = self.encoder
        let warningLogger = self.warningLogger

        workerTask = Task.detached(priority: .utility) {
            for await request in stream {
                do {
                    let destinationURL = destinationResolver(request.frameID)
                    let jpegData = try encoder(request.frame)
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try jpegData.write(to: destinationURL, options: [.atomic])
                    await self.recordWriteSuccess()
                } catch {
                    await self.recordWriteFailure(
                        frameID: request.frameID,
                        error: error,
                        warningLogger: warningLogger
                    )
                }
            }
        }
    }

    private func recordWriteSuccess() {
        diagnostics.writtenCount += 1
    }

    private func recordWriteFailure(
        frameID: Int64,
        error: Error,
        warningLogger: WarningLogger
    ) {
        diagnostics.failureCount += 1
        warningLogger(
            "[Timeline-DiskBuffer] Failed to persist capture-time still for frame \(frameID): \(error.localizedDescription)"
        )
    }
}

/// Main coordinator that wires all modules together
/// Implements the core data pipeline: Capture → Storage → Processing → Database → Search
/// Owner: APP integration
public actor AppCoordinator {
    public struct MissingMasterKeyRedactionState: Sendable {
        public let hasMasterKey: Bool
        public let phraseLevelRedactionEnabled: Bool
        public let hasProtectedRedactionData: Bool
        public let hasPendingRedactionRewrites: Bool

        public init(
            hasMasterKey: Bool,
            phraseLevelRedactionEnabled: Bool,
            hasProtectedRedactionData: Bool,
            hasPendingRedactionRewrites: Bool
        ) {
            self.hasMasterKey = hasMasterKey
            self.phraseLevelRedactionEnabled = phraseLevelRedactionEnabled
            self.hasProtectedRedactionData = hasProtectedRedactionData
            self.hasPendingRedactionRewrites = hasPendingRedactionRewrites
        }

        public var requiresRecoveryPrompt: Bool {
            !hasMasterKey && (
                phraseLevelRedactionEnabled
                    || hasProtectedRedactionData
                    || hasPendingRedactionRewrites
            )
        }
    }

    public struct SegmentCommentCreateResult: Sendable {
        public let comment: SegmentComment
        public let linkedSegmentIDs: [SegmentID]
        public let skippedSegmentIDs: [SegmentID]
        public let failedSegmentIDs: [SegmentID]

        public init(
            comment: SegmentComment,
            linkedSegmentIDs: [SegmentID],
            skippedSegmentIDs: [SegmentID],
            failedSegmentIDs: [SegmentID]
        ) {
            self.comment = comment
            self.linkedSegmentIDs = linkedSegmentIDs
            self.skippedSegmentIDs = skippedSegmentIDs
            self.failedSegmentIDs = failedSegmentIDs
        }
    }

    public typealias LinkedSegmentComment = Database.LinkedSegmentComment

    public struct FrameInPageURLRow: Sendable, Equatable {
        public let order: Int
        public let url: String
        public let nodeID: Int

        public init(order: Int, url: String, nodeID: Int) {
            self.order = order
            self.url = url
            self.nodeID = nodeID
        }
    }

    public struct FrameInPageURLState: Sendable, Equatable {
        public let mouseX: Double?
        public let mouseY: Double?
        public let scrollX: Double?
        public let scrollY: Double?
        public let videoCurrentTime: Double?

        public init(
            mouseX: Double?,
            mouseY: Double?,
            scrollX: Double?,
            scrollY: Double?,
            videoCurrentTime: Double?
        ) {
            self.mouseX = mouseX
            self.mouseY = mouseY
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.videoCurrentTime = videoCurrentTime
        }
    }

    struct DBStorageSnapshotLogState: Equatable {
        let localDay: Date
        let dbBytes: Int64
        let walBytes: Int64
        let sampledAt: Date
    }

    struct DBStorageSnapshotDeltaSummary: Equatable {
        let dbDeltaBytes: Int64?
        let walDeltaBytes: Int64?
    }

    // MARK: - Properties

    private nonisolated let services: ServiceContainer
    private var captureTask: Task<Void, Never>?
    // ⚠️ RELEASE 2 ONLY
    // private var audioTask: Task<Void, Never>?
    private var isRunning = false

    // Statistics
    private var pipelineStartTime: Date?
    private var totalFramesProcessed = 0
    private var totalErrors = 0

    /// Thread-safe status holder for UI polling without actor hop
    public nonisolated let statusHolder = PipelineStatusHolder()

    // Segment tracking (app focus sessions - Rewind compatible)
    private var currentSegmentID: Int64?

    private struct RecentClosedNilBrowserURLSegment: Sendable {
        let segmentID: Int64
        let bundleID: String
        let normalizedWindowName: String
        let closedAt: Date
    }

    private var recentClosedNilBrowserURLSegments: [RecentClosedNilBrowserURLSegment] = []
    private let recentClosedSegmentBackfillWindowSeconds: TimeInterval = 3.0

    // Idle detection - track last frame timestamp to detect gaps
    private var lastFrameTimestamp: Date?

    // Timeline visibility tracking - pause capture when timeline is open
    private var isTimelineVisible = false

    // Signal to flush pending frames to the OCR queue
    private var shouldFlushPendingFrames = false
    private var pendingVideoWriterRotationReason: String?

    // Permission monitoring - stops recording gracefully if permissions are revoked
    private var permissionMonitorSetup = false

    // Storage health notifications (volume mount, used to trigger cache validation)
    private var storageHealthObserverTokens: [NSObjectProtocol] = []

    // Critical crash recovery can start in the background during launch, but capture
    // start must join the same task so WAL recovery and live writes never overlap.
    // Best-effort orphaned-frame re-enqueue is deferred to a separate background task.
    private var crashRecoveryTask: Task<Bool, Error>?
    private var hasCompletedCrashRecoverySinceLaunch = false
    private var orphanedFrameRecoveryTask: Task<Void, Never>?

    // Periodic task to finalize orphaned videos (processingState stuck at 1)
    private var orphanedVideoCleanupTask: Task<Void, Never>?
    private var dbStorageSnapshotTask: Task<Void, Never>?
    private var lastLoggedDBStorageSnapshot: DBStorageSnapshotLogState?
    private static let pipelineMemoryLogInterval: TimeInterval = 5.0
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    private static let memoryLedgerPendingRawFramesTag = "app.capture.pendingRawFrames"
    private static let memoryLedgerActiveWritersTag = "app.capture.activeWriters"
    private static let dbStorageSnapshotIntervalNanoseconds: Int64 = 60_000_000_000
    private static let timelineDiskCacheJPEGCompressionQuality: CGFloat = 0.80
    private static let timelineStillWriterBufferLimit = 4

    private let timelineStillDiskWriter: TimelineStillDiskWriter

    // MARK: - Initialization

    public init(services: ServiceContainer) {
        self.services = services
        self.timelineStillDiskWriter = TimelineStillDiskWriter(
            bufferLimit: Self.timelineStillWriterBufferLimit,
            destinationResolver: { frameID in
                Self.timelineDiskFrameBufferURL(for: frameID)
            },
            encoder: { frame in
                try Self.encodeCapturedFrameAsJPEG(frame)
            },
            warningLogger: { message in
                Log.warning(message, category: .app)
            }
        )
        Log.info("AppCoordinator created", category: .app)
    }

    /// Convenience initializer with default configuration
    public init() {
        self.services = ServiceContainer()
        self.timelineStillDiskWriter = TimelineStillDiskWriter(
            bufferLimit: Self.timelineStillWriterBufferLimit,
            destinationResolver: { frameID in
                Self.timelineDiskFrameBufferURL(for: frameID)
            },
            encoder: { frame in
                try Self.encodeCapturedFrameAsJPEG(frame)
            },
            warningLogger: { message in
                Log.warning(message, category: .app)
            }
        )
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

    public func updateCaptureConfig(
        _ transform: @Sendable (CaptureConfig) -> CaptureConfig
    ) async throws {
        try await services.capture.updateConfig(transform)
    }

    public func updateVideoQuality(
        _ quality: Double,
        source: String = "settings_capture_card"
    ) async {
        let clampedQuality = min(max(quality, 0.0), 1.0)
        let currentConfig = await services.storage.getVideoEncoderConfig()
        let currentQuality = Double(currentConfig.quality)
        guard abs(currentQuality - clampedQuality) > 0.0001 else { return }

        let newConfig = VideoEncoderConfig(
            codec: currentConfig.codec,
            targetBitrate: currentConfig.targetBitrate,
            keyframeInterval: currentConfig.keyframeInterval,
            useHardwareEncoder: currentConfig.useHardwareEncoder,
            quality: Float(clampedQuality)
        )

        await services.storage.updateVideoEncoderConfig(newConfig)
        await recordVideoQualityMetricIfNeeded(
            quality: clampedQuality,
            source: source,
            isRunning: isRunning
        )

        if isRunning {
            pendingVideoWriterRotationReason = "video_quality_update"
            Log.info(
                "[AppCoordinator] Video quality updated to \(clampedQuality); active video writers will rotate on the next frame",
                category: .app
            )
        } else {
            Log.info("[AppCoordinator] Video quality updated to \(clampedQuality)", category: .app)
        }
    }

    private static func privateRedactionTracePreview(_ value: String?, limit: Int = 180) -> String {
        guard let value else { return "nil" }

        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return "(empty)" }
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "..."
    }

    // MARK: - Timeline Visibility

    /// Set whether the timeline is currently visible (pauses frame processing when true)
    public func setTimelineVisible(_ visible: Bool) async {
        isTimelineVisible = visible
        // When timeline becomes visible, signal to flush any buffered frames to OCR queue
        if visible {
            shouldFlushPendingFrames = true
        }
        if let queue = await services.processingQueue {
            await queue.setTimelineVisibleForRewriteScheduling(visible)
        }
        Log.info("Timeline visibility changed: \(visible) - frame processing \(visible ? "paused" : "resumed")", category: .app)
    }

    public func setTimelineScrubbing(_ scrubbing: Bool) async {
        if let queue = await services.processingQueue {
            await queue.setTimelineScrubbingForRewriteScheduling(scrubbing)
        }
    }

    /// Release cached AVFoundation decode state after timeline/search teardown.
    public func purgeVideoDecodingCaches(reason: String) async {
        await services.storage.purgeFrameExtractionCaches(reason: reason)
        if let adapter = await services.dataAdapter {
            await adapter.purgeFrameExtractionCaches(reason: reason)
        }
        Log.info("[AppCoordinator] Purged video decoding caches (\(reason))", category: .app)
    }

    // MARK: - Lifecycle

    /// Initialize all services
    public func initialize() async throws {
        Log.info("Initializing AppCoordinator...", category: .app)
        try await services.initialize()

        if await services.storage.isWALReady() {
            _ = scheduleCrashRecoveryIfNeeded(
                skipOnboardingCheck: false,
                logFailures: true
            )
        } else {
            Log.warning(
                "[AppCoordinator] Skipping crash recovery because WAL storage is currently unavailable",
                category: .app
            )
        }

        Log.info("AppCoordinator initialized successfully", category: .app)

        // Apply power-aware OCR settings
        await applyPowerSettings()

        // Start periodic orphaned video cleanup (runs every 60s)
        startOrphanedVideoCleanup()
        await recordDBStorageSnapshot(reason: "initialize")
        startDBStorageSnapshotTask()

        // Log auto-start state for debugging
        let shouldAutoStart = Self.shouldAutoStartRecording()
        Log.info("Auto-start recording check: shouldAutoStartRecording=\(shouldAutoStart)", category: .app)
    }

    func runCrashRecoveryForTesting() async throws {
        _ = scheduleCrashRecoveryIfNeeded(
            skipOnboardingCheck: true,
            logFailures: false
        )
        _ = try await awaitCrashRecoveryIfNeeded()
    }

    @discardableResult
    func scheduleCrashRecoveryIfNeeded(
        skipOnboardingCheck: Bool,
        logFailures: Bool
    ) -> Bool {
        guard crashRecoveryTask == nil else {
            return false
        }

        let task = Task { [self] in
            try await performCrashRecovery(skipOnboardingCheck: skipOnboardingCheck)
        }
        crashRecoveryTask = task

        if logFailures {
            Task {
                do {
                    _ = try await task.value
                } catch {
                    Log.error("[AppCoordinator] Background crash recovery failed", category: .app, error: error)
                }
            }
        }

        return true
    }

    @discardableResult
    func awaitCrashRecoveryIfNeeded() async throws -> Bool {
        guard let task = crashRecoveryTask else {
            return hasCompletedCrashRecoverySinceLaunch
        }

        defer {
            crashRecoveryTask = nil
        }

        let didRun = try await task.value
        if didRun {
            hasCompletedCrashRecoverySinceLaunch = true
        }
        return didRun
    }

    func prepareForPipelineStart() async throws {
        try await services.storage.validateCaptureReadiness()
        try await runCrashRecoveryBeforePipelineStartIfNeeded()
    }

    private func runCrashRecoveryBeforePipelineStartIfNeeded() async throws {
        guard !hasCompletedCrashRecoverySinceLaunch, await services.storage.isWALReady() else {
            return
        }

        _ = scheduleCrashRecoveryIfNeeded(
            skipOnboardingCheck: false,
            logFailures: true
        )
        let didRunRecovery = try await awaitCrashRecoveryIfNeeded()

        if !didRunRecovery, !hasCompletedCrashRecoverySinceLaunch, await services.storage.isWALReady() {
            _ = scheduleCrashRecoveryIfNeeded(
                skipOnboardingCheck: false,
                logFailures: true
            )
            _ = try await awaitCrashRecoveryIfNeeded()
        }
    }

    private func performCrashRecovery(skipOnboardingCheck: Bool) async throws -> Bool {
        // Skip crash recovery during first launch (onboarding) - there's nothing to recover
        // and the database may not be fully ready yet
        if !skipOnboardingCheck {
            let hasCompletedOnboarding = await services.onboardingManager.hasCompletedOnboarding
            guard hasCompletedOnboarding else {
                Log.info("Skipping crash recovery during onboarding (first launch)", category: .app)
                return false
            }
        }

        Log.info("Checking for crash recovery...", category: .app)

        // Cast to concrete StorageManager to access WAL
        guard let storageManager = services.storage as? StorageManager else {
            Log.warning("Storage not using WAL-enabled StorageManager, skipping recovery", category: .app)
            return false
        }

        let walManager = await storageManager.getWALManager()
        let recoveryManager = RecoveryManager(
            walManager: walManager,
            storage: services.storage,
            database: services.database
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
        let activeVideoIDs = try await resolveActiveDatabaseVideoIDs(from: activeWALSessions)
        if !activeWALSessions.isEmpty && activeVideoIDs.isEmpty {
            Log.warning(
                "[Recovery] Skipping orphan video finalization: \(activeWALSessions.count) active WAL sessions but no matching unfinalised DB video IDs",
                category: .app
            )
        } else {
            let orphanedVideosFinalized = try await services.database.finalizeOrphanedVideos(activeVideoIDs: activeVideoIDs)
            if orphanedVideosFinalized > 0 {
                Log.warning("[Recovery] Finalized \(orphanedVideosFinalized) orphaned videos (processingState was stuck at 1)", category: .app)
            }
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

        // Re-enqueueing pending frames that were never queued is best-effort work and
        // should not hold startup-critical readers behind a long anti-join.
        scheduleOrphanedFrameRecoveryIfNeeded()
        return true
    }

    private func scheduleOrphanedFrameRecoveryIfNeeded() {
        guard orphanedFrameRecoveryTask == nil else { return }

        orphanedFrameRecoveryTask = Task.detached(priority: .background) { [weak self] in
            await self?.reEnqueueOrphanedFrames()
            await self?.clearOrphanedFrameRecoveryTask()
        }

        Log.info("[ORPHAN-RECOVERY] Scheduled background orphaned-frame re-enqueue", category: .app)
    }

    private func clearOrphanedFrameRecoveryTask() {
        orphanedFrameRecoveryTask = nil
    }

    private func stopOrphanedFrameRecovery() {
        orphanedFrameRecoveryTask?.cancel()
        orphanedFrameRecoveryTask = nil
    }

    /// Re-enqueue frames that have processingStatus=0 but are not in the processing queue
    /// This happens when the app restarts before buffered frames were enqueued
    private func reEnqueueOrphanedFrames() async {
        guard let queue = await services.processingQueue else {
            Log.warning("[ORPHAN-RECOVERY] Processing queue not available", category: .app)
            return
        }

        do {
            let batchSize = 500
            var totalEnqueued = 0
            var hasLoggedDiscovery = false

            while true {
                guard !Task.isCancelled else {
                    Log.info("[ORPHAN-RECOVERY] Background orphaned-frame re-enqueue cancelled", category: .app)
                    return
                }

                let frameIDs = try await services.database.getPendingFrameIDsNotInQueue(limit: batchSize)
                if frameIDs.isEmpty {
                    break
                }

                if !hasLoggedDiscovery {
                    Log.info("[ORPHAN-RECOVERY] Found orphaned frames; starting background re-enqueue", category: .app)
                    hasLoggedDiscovery = true
                }

                try await queue.enqueueBatch(frameIDs: frameIDs, priority: -1)
                totalEnqueued += frameIDs.count
                Log.info("[ORPHAN-RECOVERY] Enqueued batch of \(frameIDs.count) frames (total: \(totalEnqueued))", category: .app)

                // Small delay between batches to avoid overwhelming the queue.
                try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous) // 100ms
            }

            if totalEnqueued == 0 {
                Log.info("[ORPHAN-RECOVERY] No orphaned frames found", category: .app)
                return
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

    @discardableResult
    public func refreshRewindCutoffDate() async -> Bool {
        await services.refreshRewindCutoffDate()
    }

    /// Setup callback for accessibility permission warnings
    public func setupAccessibilityWarningCallback(_ callback: @escaping @Sendable () -> Void) async {
        services.capture.onAccessibilityPermissionWarning = callback
    }

    // MARK: - Recording State Persistence

    private static let recordingStateKey = "shouldAutoStartRecording"
    private static let phraseLevelRedactionEnabledKey = "phraseLevelRedactionEnabled"
    private static let abandonedMissingMasterKeyRewritePurpose = "redaction_missing_master_key_abandoned"
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

        // Join any in-flight crash recovery and ensure WAL writes are available
        // before we start capture.
        try await prepareForPipelineStart()

        // Check permissions before starting capture
        guard await services.capture.hasPermission() else {
            Log.error("Screen recording permission not granted", category: .app)
            throw AppError.permissionDenied(permission: "screen recording")
        }

        // Set up callback for when capture stops unexpectedly (e.g., user clicks "Stop sharing")
        services.capture.onCaptureStopped = { [weak self] in
            guard let self = self else { return }
            await self.handleCaptureStopped()
        }
        services.capture.onMouseClickCaptureOutcome = { [weak self] outcome, timestamp in
            guard let self else { return }
            await self.recordMouseClickCaptureMetricIfNeeded(
                outcome: outcome,
                timestamp: timestamp
            )
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
        statusHolder.update(isRunning: true, startTime: pipelineStartTime)
        captureTask = Task {
            await runPipeline()
        }
        // ⚠️ RELEASE 2 ONLY
        // audioTask = Task {
        //     await runAudioPipeline()
        // }

        // Save recording state for persistence across restarts
        saveRecordingState(true)

        // Start unified storage health monitoring (disk space, I/O latency, volume events, keep-alive)
        startStorageHealthNotifications()
        let storageRoot = await services.storage.getStorageDirectory().path
        StorageHealthMonitor.shared.startMonitoring(
            storagePath: storageRoot,
            onCriticalError: { [weak self] in
                await self?.handleStorageCriticalError()
            }
        )

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

        // Stop storage health monitoring
        StorageHealthMonitor.shared.stopMonitoring()
        stopStorageHealthNotifications()

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

        isRunning = false
        statusHolder.update(isRunning: false)

        // Only save recording state as stopped if explicitly requested (user clicked stop)
        // During shutdown, we want to preserve the "recording" state so it auto-starts next launch
        if persistState {
            saveRecordingState(false)
        }

        Log.info("Capture pipeline stopped successfully", category: .app)
    }

    // MARK: - Storage Health Notifications

    private func startStorageHealthNotifications() {
        stopStorageHealthNotifications()

        let center = NotificationCenter.default
        let mounted = center.addObserver(forName: .storageVolumeMounted, object: nil, queue: .main) { [weak self] notification in
            Task { await self?.handleStorageVolumeMounted(notification) }
        }
        storageHealthObserverTokens.append(mounted)
    }

    private func stopStorageHealthNotifications() {
        let center = NotificationCenter.default
        for token in storageHealthObserverTokens {
            center.removeObserver(token)
        }
        storageHealthObserverTokens.removeAll()
    }

    private func handleStorageVolumeMounted(_ notification: Notification) async {
        Log.info("[AppCoordinator] Storage volume mounted - validating StorageManager caches", category: .app)
        await services.storage.validateCaches()
    }

    private func handleStorageCriticalError() async {
        Log.error("[AppCoordinator] Storage critical error - invalidating StorageManager caches and stopping pipeline", category: .app)
        await services.storage.invalidateAllCaches()
        try? await stopPipeline()
    }

    /// Shutdown all services
    public func shutdown() async throws {
        if isRunning {
            // Don't persist state as stopped - we want to auto-start on next launch
            try await stopPipeline(persistState: false)
        }

        // Stop periodic cleanup tasks
        stopOrphanedFrameRecovery()
        stopOrphanedVideoCleanup()
        stopDBStorageSnapshotTask()
        await recordDBStorageSnapshot(reason: "shutdown")
        await timelineStillDiskWriter.shutdown()

        Log.info("Shutting down AppCoordinator...", category: .app)
        try await services.shutdown()
        Log.info("AppCoordinator shutdown complete", category: .app)
    }

    // MARK: - Power Settings

    /// Apply power-aware OCR settings to the processing queue
    /// Called on startup, when settings change, and when power source changes
    public func applyPowerSettings() async {
        let snapshot = OCRPowerSettingsSnapshot.fromDefaults()
        await applyPowerSettings(snapshot: snapshot)
    }

    /// Apply power-aware OCR settings from an explicit snapshot.
    /// This path avoids races where UserDefaults writes are not immediately visible.
    public func applyPowerSettings(snapshot: OCRPowerSettingsSnapshot) async {
        let ocrEnabled = snapshot.ocrEnabled
        let pauseOnBattery = snapshot.pauseOnBattery
        let pauseOnLowPowerMode = snapshot.pauseOnLowPowerMode
        let processingLevel = min(max(snapshot.processingLevel, 1), 5)

        // Parse app filter mode and filtered apps
        let filterModeRaw = snapshot.appFilterModeRaw
        let filterMode = OCRAppFilterMode(rawValue: filterModeRaw) ?? .allApps

        var excludedBundleIDs: Set<String> = []
        var includedBundleIDs: Set<String> = []

        // ocrFilteredApps is stored as JSON array of {bundleID, name, iconPath} objects
        struct FilteredAppInfo: Codable {
            let bundleID: String
        }
        let appsString = snapshot.filteredAppsJSON
        Log.info("[AppCoordinator] Raw ocrFilteredApps from snapshot: '\(appsString)'", category: .app)
        Log.info("[AppCoordinator] Raw ocrAppFilterMode from snapshot: '\(filterModeRaw)'", category: .app)

        if !appsString.isEmpty,
           let data = appsString.data(using: .utf8),
           let apps = try? JSONDecoder().decode([FilteredAppInfo].self, from: data) {
            let bundleIDs = apps.map(\.bundleID)
            Log.info("[AppCoordinator] Parsed bundleIDs: \(bundleIDs)", category: .app)
            switch filterMode {
            case .allApps:
                Log.info("[AppCoordinator] Filter mode is allApps, not applying any filter", category: .app)
                break // No filtering
            case .onlyTheseApps:
                includedBundleIDs = Set(bundleIDs)
                Log.info("[AppCoordinator] Filter mode is onlyTheseApps, includedBundleIDs=\(includedBundleIDs)", category: .app)
            case .allExceptTheseApps:
                excludedBundleIDs = Set(bundleIDs)
                Log.info("[AppCoordinator] Filter mode is allExceptTheseApps, excludedBundleIDs=\(excludedBundleIDs)", category: .app)
            }
        } else {
            Log.info("[AppCoordinator] No filtered apps configured or failed to parse", category: .app)
        }

        // Get current power source
        let powerSource = PowerStateMonitor.shared.getCurrentPowerSource()
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Derive priority, FPS limit, and worker count from processing level
        // Level 1: Efficiency  - background, 0.5 FPS, 1 worker
        // Level 2: Light       - background, no limit, 2 workers
        // Level 3: Balanced    - utility, no limit, 1 worker
        // Level 4: Performance - medium, no limit, 1 worker
        // Level 5: Max         - high, no limit, 2 workers
        let taskPriority: TaskPriority
        let maxFPS: Double
        let workerCount: Int
        switch processingLevel {
        case 1:
            taskPriority = .background; maxFPS = 0.5; workerCount = 1
        case 2:
            taskPriority = .background; maxFPS = 0; workerCount = 2
        case 4:
            taskPriority = .medium; maxFPS = 0; workerCount = 1
        case 5:
            taskPriority = .high; maxFPS = 0; workerCount = 2
        default: // 3 = Balanced (default)
            taskPriority = .utility; maxFPS = 0; workerCount = 1
        }

        // Update processing config - always prefer background processing for VNRecognizeTextRequest
        let currentConfig = await services.processing.getConfig()
        let preferBackground = true
        if currentConfig.preferBackgroundProcessing != preferBackground {
            let updatedConfig = ProcessingConfig(
                accessibilityEnabled: currentConfig.accessibilityEnabled,
                ocrAccuracyLevel: currentConfig.ocrAccuracyLevel,
                recognitionLanguages: currentConfig.recognitionLanguages,
                minimumConfidence: currentConfig.minimumConfidence,
                preferBackgroundProcessing: preferBackground
            )
            await services.processing.updateConfig(updatedConfig)
        }

        // Apply to processing queue
        if let queue = await services.processingQueue {
            await queue.updatePowerConfig(
                ocrEnabled: ocrEnabled,
                pauseOnBattery: pauseOnBattery,
                pauseOnLowPowerMode: pauseOnLowPowerMode,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                currentPowerSource: powerSource,
                maxFPS: maxFPS,
                workerCount: workerCount,
                taskPriority: taskPriority,
                excludedBundleIDs: excludedBundleIDs,
                includedBundleIDs: includedBundleIDs
            )
        } else {
            Log.warning("[AppCoordinator] processingQueue is nil, cannot apply power config", category: .app)
        }

        Log.info(
            "[AppCoordinator] Applied power settings: ocrEnabled=\(ocrEnabled), level=\(processingLevel), workers=\(workerCount), priority=\(taskPriority), maxFPS=\(maxFPS), preferBgProcessing=\(preferBackground), pauseOnBattery=\(pauseOnBattery), pauseOnLowPowerMode=\(pauseOnLowPowerMode), isLowPowerModeEnabled=\(isLowPowerModeEnabled), power=\(powerSource)",
            category: .app
        )
    }

    /// Handle capture stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleCaptureStopped() async {
        guard isRunning else { return }

        Log.info("Capture stopped unexpectedly, cleaning up pipeline...", category: .app)

        // Cancel pipeline tasks
        captureTask?.cancel()
        captureTask = nil

        isRunning = false
        statusHolder.update(isRunning: false)
        Log.info("Pipeline cleanup complete after unexpected stop", category: .app)
    }

    // MARK: - Storage Health (delegated to StorageHealthMonitor)
    // Storage monitoring is now handled by StorageHealthMonitor.shared which provides:
    // - Volume mount/unmount detection (instant via NSWorkspace notifications)
    // - Disk space monitoring with thresholds
    // - I/O latency tracking
    // - Keep-alive writes to prevent drive spindown
    // - Periodic health check every 30 seconds as fallback

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

        PermissionMonitor.shared.onListenEventAccessGranted = { [weak self] in
            guard let self else { return }
            Log.info("[AppCoordinator] Listen-event access granted - retrying mouse click capture monitoring", category: .app)
            await self.services.capture.retryMouseClickMonitoringIfNeeded()
        }

        PermissionMonitor.shared.onListenEventAccessRevoked = { [weak self] in
            guard let self else { return }
            Log.warning("[AppCoordinator] Listen-event access revoked - suspending mouse click capture monitoring", category: .app)
            await self.services.capture.suspendMouseClickMonitoringForPermissionLoss()
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

    // MARK: - Orphaned Video Cleanup

    /// Start periodic cleanup of orphaned videos (processingState stuck at 1)
    /// Runs every 60 seconds to catch videos that weren't finalized properly
    private func startOrphanedVideoCleanup() {
        orphanedVideoCleanupTask?.cancel()

        orphanedVideoCleanupTask = Task { [weak self] in
            let cleanupInterval: UInt64 = 60_000_000_000 // 60 seconds

            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Int64(cleanupInterval)), clock: .continuous)
                guard !Task.isCancelled else { break }

                await self?.cleanupOrphanedVideos()
            }
        }

        Log.info("[AppCoordinator] Orphaned video cleanup task started (60s interval)", category: .app)
    }

    /// Stop the orphaned video cleanup task
    private func stopOrphanedVideoCleanup() {
        orphanedVideoCleanupTask?.cancel()
        orphanedVideoCleanupTask = nil
    }

    // MARK: - DB Storage Snapshot Sampling

    private func startDBStorageSnapshotTask() {
        dbStorageSnapshotTask?.cancel()

        dbStorageSnapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .nanoseconds(Self.dbStorageSnapshotIntervalNanoseconds),
                    clock: .continuous
                )
                guard !Task.isCancelled else { break }

                await self?.recordDBStorageSnapshot(reason: "periodic")
            }
        }

        Log.info("[AppCoordinator] DB storage snapshot task started (60s interval)", category: .app)
    }

    private func stopDBStorageSnapshotTask() {
        dbStorageSnapshotTask?.cancel()
        dbStorageSnapshotTask = nil
    }

    private func recordDBStorageSnapshot(reason: String) async {
        do {
            try await services.database.recordDBStorageSnapshot()
            if let snapshot = try await currentDBStorageSnapshotLogState() {
                let deltaSummary = Self.dbStorageSnapshotDeltaSummary(
                    current: snapshot,
                    previous: lastLoggedDBStorageSnapshot
                )
                lastLoggedDBStorageSnapshot = snapshot
                Log.info(
                    Self.dbStorageSnapshotLogMessage(
                        snapshot: snapshot,
                        deltaSummary: deltaSummary,
                        reason: reason
                    ),
                    category: .app
                )
            } else {
                Log.debug("[AppCoordinator] Recorded DB storage snapshot (\(reason))", category: .app)
            }
        } catch {
            Log.warning("[AppCoordinator] Failed to record DB storage snapshot (\(reason)): \(error)", category: .app)
        }
    }

    private func currentDBStorageSnapshotLogState() async throws -> DBStorageSnapshotLogState? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let snapshots = try await services.database.getDBStorageSnapshots(from: today, to: today)
        guard let snapshot = snapshots.last else {
            return nil
        }
        return DBStorageSnapshotLogState(
            localDay: calendar.startOfDay(for: snapshot.date),
            dbBytes: snapshot.dbBytes,
            walBytes: snapshot.walBytes,
            sampledAt: snapshot.sampledAt
        )
    }

    /// Finalize any orphaned videos that have processingState=1 but no active WAL session
    private func cleanupOrphanedVideos() async {
        do {
            // Get active WAL sessions to exclude currently-being-written videos
            guard let storageManager = services.storage as? StorageManager else {
                return
            }

            let walManager = await storageManager.getWALManager()
            let activeWALSessions = try await walManager.listActiveSessions()
            let activeVideoIDs = try await resolveActiveDatabaseVideoIDs(from: activeWALSessions)

            if !activeWALSessions.isEmpty && activeVideoIDs.isEmpty {
                Log.warning(
                    "[OrphanCleanup] Skipping orphan finalization: \(activeWALSessions.count) active WAL sessions but no matching unfinalised DB video IDs",
                    category: .app
                )
                return
            }

            let orphanedCount = try await services.database.finalizeOrphanedVideos(activeVideoIDs: activeVideoIDs)
            if orphanedCount > 0 {
                Log.warning("[OrphanCleanup] Finalized \(orphanedCount) orphaned videos (processingState was stuck at 1)", category: .app)
            }
        } catch {
            Log.error("[OrphanCleanup] Failed to cleanup orphaned videos", category: .app, error: error)
        }
    }

    /// Map active WAL session path IDs to active DB video IDs.
    /// WAL sessions are keyed by timestamp-based path IDs, while `video.id` is DB autoincrement.
    func resolveActiveDatabaseVideoIDs(from activeWALSessions: [WALSession]) async throws -> Set<Int64> {
        guard !activeWALSessions.isEmpty else { return [] }

        let activeWALPathIDs = Set(activeWALSessions.map { $0.videoID.value })
        let unfinalisedVideos = try await services.database.getAllUnfinalisedVideos()

        var activeDBVideoIDs: Set<Int64> = []
        var matchedWALPathIDs: Set<Int64> = []

        for video in unfinalisedVideos {
            guard let pathID = pathVideoID(for: video.relativePath)?.value else { continue }
            if activeWALPathIDs.contains(pathID) {
                activeDBVideoIDs.insert(video.id)
                matchedWALPathIDs.insert(pathID)
            }
        }

        let unmatchedWALPathIDs = activeWALPathIDs.subtracting(matchedWALPathIDs)
        if !unmatchedWALPathIDs.isEmpty {
            let sample = unmatchedWALPathIDs
                .sorted()
                .prefix(3)
                .map(String.init)
                .joined(separator: ", ")
            Log.warning(
                "[OrphanCleanup] \(unmatchedWALPathIDs.count) active WAL sessions had no matching unfinalised DB video path IDs (sample: \(sample))",
                category: .app
            )
        }

        return activeDBVideoIDs
    }

    // MARK: - Pipeline Implementation

    /// Buffered frame entry - tracks frames pending readability confirmation
    private struct BufferedFrame {
        let frameID: Int64
        /// The frame's index in the video segment (0-based)
        let frameIndexInSegment: Int
    }

    /// State for tracking a video writer by resolution
    private struct VideoWriterState {
        var writer: SegmentWriter
        var videoDBID: Int64
        var frameCount: Int
        var isReadable: Bool
        var persistedReadableFrameCount: Int
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
        var lastPipelineMemoryLogAt = Date.distantPast
        let maxFramesPerSegment = 150
        let videoUpdateInterval = 5

        func maybeLogPipelineMemory(reason: String) {
            let now = Date()
            guard now.timeIntervalSince(lastPipelineMemoryLogAt) >= Self.pipelineMemoryLogInterval else { return }
            lastPipelineMemoryLogAt = now
            logPipelineMemorySnapshot(writersByResolution: writersByResolution, reason: reason)
        }

        for await frame in frameStream {
            Log.verbose("[Pipeline] Received frame from stream: \(frame.width)x\(frame.height), app=\(frame.metadata.appName)", category: .app)

            if Task.isCancelled {
                Log.info("Pipeline task cancelled", category: .app)
                break
            }

            await rotateActiveVideoWritersIfNeeded(&writersByResolution)

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
                        for (_, state) in writersByResolution {
                            let pendingCount = state.pendingFrames.count
                            if pendingCount > 0 {
                                Log.info("[FLUSH] Timeline opened - enqueueing \(pendingCount) pending frames for OCR", category: .app)
                                // DON'T clear pendingFrames here - they still need to be marked readable
                                // when the fragment actually flushes to disk.
                                for bufferedFrame in state.pendingFrames {
                                    try? await processingQueue.enqueue(frameID: bufferedFrame.frameID)
                                }
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
                    ), try await shouldResumeUnfinalisedVideo(unfinalised) {
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
                    await cancelBrokenWriterPreservingRecoveryData(writerState.writer)
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
                await persistGlobalMousePositionIfNeeded(
                    frameID: frameID,
                    capturedFrame: frame
                )
                await writeCapturedFrameStillToTimelineDiskCache(
                    frameID: frameID,
                    frame: frame
                )
                scheduleInPageURLMetadataCaptureIfNeeded(
                    frameID: frameID,
                    frameMetadata: frame.metadata
                )

                // Persist WAL mapping for exact frameID -> raw frame lookup while segment is unfinalized.
                if let storageManager = services.storage as? StorageManager {
                    let walVideoID = await writerState.writer.segmentID
                    let walManager = await storageManager.getWALManager()
                    do {
                        try await walManager.registerFrameID(
                            videoID: walVideoID,
                            frameID: frameID,
                            frameIndex: frameIndexInSegment
                        )
                    } catch {
                        Log.warning(
                            "[WAL] Failed to register frameID mapping for frame \(frameID) (video \(walVideoID.value), index \(frameIndexInSegment)): \(error)",
                            category: .app
                        )
                    }
                }

                let appNameForLog = frame.metadata.appName ?? "nil"
                let appBundleIDForLog = frame.metadata.appBundleID ?? "nil"
                let windowNameForLog = Self.privateRedactionTracePreview(frame.metadata.windowName)
                let redactionReasonForLog = frame.metadata.redactionReason ?? "none"

                Log.verbose(
                    "[CAPTURE-DEBUG] Captured frameID=\(frameID), videoDBID=\(writerState.videoDBID), frameIndexInSegment=\(frameIndexInSegment), bundleID=\(appBundleIDForLog), app=\(appNameForLog), window=\(windowNameForLog), redactionReason=\(redactionReasonForLog)",
                    category: .app
                )

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

                // Track frame in pending buffer until it's confirmed flushed/readable.
                let bufferedFrame = BufferedFrame(frameID: frameID, frameIndexInSegment: frameIndexInSegment)

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
                    // Mark frame as readable now that it's confirmed flushed to video file
                    try await services.database.markFrameReadable(frameID: frameToEnqueue.frameID)
                    try await processingQueue.enqueue(frameID: frameToEnqueue.frameID)
                }

                if flushedCount > writerState.persistedReadableFrameCount {
                    let storageManager = services.storage
                    let walVideoID = await writerState.writer.segmentID
                    let walManager = await storageManager.getWALManager()
                    let durableFileSizeBytes: Int64
                    if let incrementalWriter = writerState.writer as? IncrementalSegmentWriter {
                        durableFileSizeBytes = await incrementalWriter.durableFileSizeBytes
                    } else {
                        durableFileSizeBytes = await writerState.writer.currentFileSize
                    }

                    do {
                        try await walManager.updateDurableVideoState(
                            videoID: walVideoID,
                            readableFrameCount: flushedCount,
                            durableVideoFileSizeBytes: durableFileSizeBytes
                        )
                        writerState.persistedReadableFrameCount = flushedCount
                    } catch {
                        Log.warning(
                            "[WAL] Failed to persist durable video frontier for video \(walVideoID.value) at flushedCount=\(flushedCount): \(error)",
                            category: .app
                        )
                    }
                }

                writersByResolution[resolutionKey] = writerState
                maybeLogPipelineMemory(reason: "steady-state")
                totalFramesProcessed += 1
                statusHolder.incrementFrames()

                if totalFramesProcessed % 10 == 0 {
                    Log.debug("Pipeline processed \(totalFramesProcessed) frames, \(writersByResolution.count) active writers", category: .app)
                }

            } catch let error as StorageError {
                totalErrors += 1
                statusHolder.incrementErrors()
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)

                if case .insufficientDiskSpace = error {
                    Task { @MainActor in
                        NotificationCenter.default.post(
                            name: .storageCriticalLow,
                            object: ["availableGB": 0.0, "shouldStop": true]
                        )
                    }
                    Task { [weak self] in
                        await self?.handleStorageCriticalError()
                    }
                    continue
                }

                // If it's a file write failure, the writer is broken - remove it so a fresh one is created
                if case .fileWriteFailed = error {
                    let resolutionKey = "\(frame.width)x\(frame.height)"
                    if let brokenWriter = writersByResolution[resolutionKey] {
                        Log.warning("Removing broken writer for \(resolutionKey) due to write failure - will create fresh writer", category: .app)
                        await cancelBrokenWriterPreservingRecoveryData(brokenWriter.writer)
                        writersByResolution.removeValue(forKey: resolutionKey)
                    }
                }
                continue
            } catch {
                totalErrors += 1
                statusHolder.incrementErrors()
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)
                continue
            }
        }

        logPipelineMemorySnapshot(writersByResolution: writersByResolution, reason: "pipeline-ending")

        // Save and finalize all remaining writers
        for (resolutionKey, var writerState) in writersByResolution {
            do {
                // Use finalizeWriter to properly mark video as finalized (processingState = 0)
                // This ensures frames can be OCR processed even if pipeline stops mid-video
                try await finalizeWriter(&writerState, processingQueue: await services.processingQueue)
                Log.info("Video segment for \(resolutionKey) finalized (\(writerState.frameCount) frames)", category: .app)
            } catch {
                Log.error("[Pipeline] Failed to finalize video segment for \(resolutionKey)", category: .app, error: error)
            }
        }

        if let segmentID = currentSegmentID {
            let shutdownEndDate = Self.segmentEndDateForShutdown(
                lastFrameTimestamp: lastFrameTimestamp,
                shutdownTimestamp: Date()
            )
            try? await services.database.updateSegmentEndDate(id: segmentID, endDate: shutdownEndDate)
            currentSegmentID = nil
        }

        Log.info("Pipeline processing completed. Total frames: \(totalFramesProcessed), Errors: \(totalErrors)", category: .app)
    }

    private func rotateActiveVideoWritersIfNeeded(
        _ writersByResolution: inout [String: VideoWriterState]
    ) async {
        guard let reason = pendingVideoWriterRotationReason else { return }
        pendingVideoWriterRotationReason = nil

        guard !writersByResolution.isEmpty else {
            Log.info("[Pipeline] No active video writers to rotate for \(reason)", category: .app)
            return
        }

        let processingQueue = await services.processingQueue

        for (resolutionKey, var writerState) in writersByResolution {
            do {
                try await finalizeWriter(&writerState, processingQueue: processingQueue)
                Log.info("[Pipeline] Rotated video writer for \(resolutionKey) due to \(reason)", category: .app)
            } catch {
                Log.error(
                    "[Pipeline] Failed to rotate video writer for \(resolutionKey) due to \(reason)",
                    category: .app,
                    error: error
                )
                await cancelBrokenWriterPreservingRecoveryData(writerState.writer)
            }
        }

        writersByResolution.removeAll()
    }

    private func logPipelineMemorySnapshot(writersByResolution: [String: VideoWriterState], reason: String) {
        var totalPendingFrames = 0
        var totalPendingBytes: Int64 = 0
        var perResolutionParts: [String] = []

        for (resolutionKey, writerState) in writersByResolution {
            let pendingFrames = writerState.pendingFrames.count
            guard pendingFrames > 0 else { continue }

            let pendingBytes: Int64 = 0
            totalPendingFrames += pendingFrames
            totalPendingBytes += pendingBytes
            perResolutionParts.append("\(resolutionKey):\(pendingFrames)f/\(Self.formatBytes(pendingBytes))")
        }

        let perResolutionSummary = perResolutionParts.isEmpty ? "none" : perResolutionParts.sorted().joined(separator: ", ")

        Log.info(
            "[Pipeline-Memory] reason=\(reason) pendingRawFrames=\(totalPendingFrames) pendingRawBytes=\(Self.formatBytes(totalPendingBytes)) activeWriters=\(writersByResolution.count) byResolution=[\(perResolutionSummary)]",
            category: .app
        )

        MemoryLedger.set(
            tag: Self.memoryLedgerPendingRawFramesTag,
            bytes: totalPendingBytes,
            count: totalPendingFrames,
            unit: "frames",
            function: "capture.pipeline",
            kind: "pending-raw-frames"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerActiveWritersTag,
            bytes: 0,
            count: writersByResolution.count,
            unit: "writers",
            function: "capture.pipeline",
            kind: "writer-pool",
            note: "count-only"
        )
        MemoryLedger.emitSummary(
            reason: "capture.pipeline.memory",
            category: .app,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
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

    private static func formatLocalDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func dbStorageSnapshotDeltaSummary(
        current: DBStorageSnapshotLogState,
        previous: DBStorageSnapshotLogState?
    ) -> DBStorageSnapshotDeltaSummary {
        guard let previous else {
            return DBStorageSnapshotDeltaSummary(dbDeltaBytes: nil, walDeltaBytes: nil)
        }

        let calendar = Calendar.current
        guard calendar.isDate(previous.localDay, inSameDayAs: current.localDay) else {
            return DBStorageSnapshotDeltaSummary(dbDeltaBytes: nil, walDeltaBytes: nil)
        }

        return DBStorageSnapshotDeltaSummary(
            dbDeltaBytes: current.dbBytes - previous.dbBytes,
            walDeltaBytes: current.walBytes - previous.walBytes
        )
    }

    private static func dbStorageSnapshotLogMessage(
        snapshot: DBStorageSnapshotLogState,
        deltaSummary: DBStorageSnapshotDeltaSummary,
        reason: String
    ) -> String {
        let localDay = formatLocalDay(snapshot.localDay)
        let sampledAt = Log.timestamp(from: snapshot.sampledAt)
        var message = "[AppCoordinator] Recorded DB storage snapshot (\(reason)) day=\(localDay) sampledAt=\(sampledAt)"
        message += " db=\(snapshot.dbBytes) (\(formatBytes(snapshot.dbBytes)))"
        message += " wal=\(snapshot.walBytes) (\(formatBytes(snapshot.walBytes)))"

        if let dbDeltaBytes = deltaSummary.dbDeltaBytes {
            let dbDeltaPrefix = dbDeltaBytes >= 0 ? "+" : ""
            message += " dbDelta=\(dbDeltaPrefix)\(dbDeltaBytes) (\(formatBytes(abs(dbDeltaBytes))))"
        }

        if let walDeltaBytes = deltaSummary.walDeltaBytes {
            let walDeltaPrefix = walDeltaBytes >= 0 ? "+" : ""
            message += " walDelta=\(walDeltaPrefix)\(walDeltaBytes) (\(formatBytes(abs(walDeltaBytes))))"
        }

        return message
    }

    private static func timelineDiskFrameBufferDirectoryURL() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("io.retrace.app", isDirectory: true)
            .appendingPathComponent("TimelineFrameBuffer", isDirectory: true)
    }

    private static func timelineDiskFrameBufferURL(for frameID: Int64) -> URL {
        timelineDiskFrameBufferDirectoryURL()
            .appendingPathComponent("\(frameID)")
            .appendingPathExtension("jpg")
    }

    private func writeCapturedFrameStillToTimelineDiskCache(
        frameID: Int64,
        frame: CapturedFrame
    ) async {
        await timelineStillDiskWriter.enqueue(frameID: frameID, frame: frame)
    }

    private static func encodeCapturedFrameAsJPEG(_ frame: CapturedFrame) throws -> Data {
        guard frame.width > 0, frame.height > 0, frame.bytesPerRow > 0 else {
            throw NSError(
                domain: "AppCoordinator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frame dimensions for JPEG encode"]
            )
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: frame.imageData as CFData),
              let cgImage = CGImage(
                  width: frame.width,
                  height: frame.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: frame.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw NSError(
                domain: "AppCoordinator",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build CGImage from captured frame data"]
            )
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "AppCoordinator",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create JPEG image destination"]
            )
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: Self.timelineDiskCacheJPEGCompressionQuality,
        ] as CFDictionary

        CGImageDestinationAddImage(destination, cgImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "AppCoordinator",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize JPEG image destination"]
            )
        }

        return outputData as Data
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
            persistedReadableFrameCount: 0,
            pendingFrames: [],
            width: width,
            height: height
        )
    }

    private func cancelBrokenWriterPreservingRecoveryData(_ writer: SegmentWriter) async {
        if let incrementalWriter = writer as? IncrementalSegmentWriter {
            try? await incrementalWriter.cancelPreservingRecoveryData()
        } else {
            try? await writer.cancel()
        }
    }

    private func resumeWriterState(from unfinalised: UnfinalisedVideo) async throws -> VideoWriterState {
        let writer = try await services.storage.createSegmentWriter()
        try await finalizeUnfinalisedVideoBeforeResuming(unfinalised)

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
            persistedReadableFrameCount: 0,
            pendingFrames: [],
            width: unfinalised.width,
            height: unfinalised.height
        )
    }

    func shouldResumeUnfinalisedVideo(_ unfinalised: UnfinalisedVideo) async throws -> Bool {
        if let pathVideoID = pathVideoID(for: unfinalised.relativePath) {
            let walManager = await services.storage.getWALManager()
            let activeSessions = try await walManager.listActiveSessions()
            if activeSessions.contains(where: { $0.videoID == pathVideoID }) {
                Log.warning(
                    "[WAL] Skipping resume of unfinalised video \(unfinalised.id) for path video \(pathVideoID.value) because an active WAL session still exists",
                    category: .app
                )
                return false
            }

            do {
                if let recoverableFrameCount = try await walManager.recoverableFrameCountIfPresent(videoID: pathVideoID),
                   recoverableFrameCount > 0 {
                    Log.warning(
                        "[WAL] Skipping resume of unfinalised video \(unfinalised.id) for path video \(pathVideoID.value) because stale WAL directory still contains \(recoverableFrameCount) recoverable frame(s); deferring cleanup until crash recovery processes WAL",
                        category: .app
                    )
                    return false
                }
            } catch {
                Log.warning(
                    "[WAL] Skipping resume of unfinalised video \(unfinalised.id) for path video \(pathVideoID.value) because stale WAL validation failed: \(error.localizedDescription)",
                    category: .app
                )
                return false
            }

            if !(try await services.storage.segmentExists(id: pathVideoID)) {
                Log.warning(
                    "[WAL] Skipping resume of unfinalised video \(unfinalised.id) because segment file \(pathVideoID.value) is missing",
                    category: .app
                )
                return false
            }

            return true
        }

        let resolvedPath = try await resolvedPathForUnfinalisedVideo(
            unfinalised,
            pathVideoID: nil
        )
        let exists = FileManager.default.fileExists(atPath: resolvedPath.path)
        if !exists {
            Log.warning(
                "[WAL] Skipping resume of unfinalised video \(unfinalised.id) because backing file is missing at \(resolvedPath.path)",
                category: .app
            )
        }
        return exists
    }

    func finalizeUnfinalisedVideoBeforeResuming(_ unfinalised: UnfinalisedVideo) async throws {
        let pathVideoID = pathVideoID(for: unfinalised.relativePath)
        let oldVideoPath = try await resolvedPathForUnfinalisedVideo(
            unfinalised,
            pathVideoID: pathVideoID
        )
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: oldVideoPath.path)[.size] as? Int64) ?? 0

        if let pathVideoID {
            await finalizeStaleWALSessionIfPresent(pathVideoID: pathVideoID)
        }

        let finalizedFrameCount: Int
        if let pathVideoID {
            finalizedFrameCount = try await services.storage.countFramesInSegment(id: pathVideoID)
        } else {
            finalizedFrameCount = unfinalised.frameCount
        }

        if let pathVideoID, finalizedFrameCount != unfinalised.frameCount {
            Log.warning(
                "[RESUME-DEBUG] Finalizing unfinalised video \(unfinalised.id) using actual readable frameCount=\(finalizedFrameCount) from path video \(pathVideoID.value) instead of stale DB frameCount=\(unfinalised.frameCount)",
                category: .app
            )
        }

        try await services.database.markVideoFinalized(
            id: unfinalised.id,
            frameCount: finalizedFrameCount,
            fileSize: fileSize
        )
    }

    private func pathVideoID(for relativePath: String) -> VideoSegmentID? {
        let stem = URL(fileURLWithPath: relativePath)
            .deletingPathExtension()
            .lastPathComponent
        guard let value = Int64(stem) else {
            return nil
        }
        return VideoSegmentID(value: value)
    }

    private func resolvedPathForUnfinalisedVideo(
        _ unfinalised: UnfinalisedVideo,
        pathVideoID: VideoSegmentID?
    ) async throws -> URL {
        if let pathVideoID {
            return try await services.storage.getSegmentPath(id: pathVideoID)
        }

        let storageDir = await services.storage.getStorageDirectory()
        let directPath = storageDir.appendingPathComponent(unfinalised.relativePath)
        if FileManager.default.fileExists(atPath: directPath.path) {
            return directPath
        }

        return directPath.appendingPathExtension("mp4")
    }

    private func finalizeStaleWALSessionIfPresent(pathVideoID: VideoSegmentID) async {
        guard let storageManager = services.storage as? StorageManager else {
            return
        }

        let walManager = await storageManager.getWALManager()
        let recoverableFrameCount: Int?
        do {
            recoverableFrameCount = try await walManager.recoverableFrameCountIfPresent(videoID: pathVideoID)
        } catch {
            Log.warning(
                "[WAL] Skipping stale WAL cleanup for unfinalised video \(pathVideoID.value) because recoverability validation failed: \(error.localizedDescription)",
                category: .app
            )
            return
        }

        guard let recoverableFrameCount else {
            return
        }

        guard recoverableFrameCount == 0 else {
            Log.warning(
                "[WAL] Preserving stale WAL directory for unfinalised video \(pathVideoID.value): contains \(recoverableFrameCount) recoverable frame(s). Cleanup deferred to crash recovery.",
                category: .app
            )
            return
        }

        do {
            let removed = try await walManager.finalizeSessionDirectoryIfPresent(videoID: pathVideoID)
            if removed {
                Log.info(
                    "Cleaned up WAL session for unfinalised video \(pathVideoID.value)",
                    category: .app
                )
            }
        } catch {
            Log.warning(
                "[WAL] Failed to clean up stale WAL directory for unfinalised video \(pathVideoID.value): \(error.localizedDescription)",
                category: .app
            )
        }
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
                    try await processingQueue.enqueue(frameID: bufferedFrame.frameID)
                }
                writerState.pendingFrames = []
            }

            // Trigger segment-level video rewrites for any p=5 frames now that the file is finalized.
            try? await processingQueue.processPendingRedactions(for: writerState.videoDBID)
        }
    }

    public func recoverPendingPhraseRedactionRewritesIfPossible() async {
        if let processingQueue = await services.processingQueue {
            await processingQueue.recoverPendingRedactionsIfPossible()
        }
    }

    public func missingMasterKeyRedactionState() async -> MissingMasterKeyRedactionState {
        let defaults = Self.userDefaultsSuite
        let hasMasterKey = MasterKeyManager.hasMasterKey()
        let phraseLevelRedactionEnabled =
            defaults.object(forKey: Self.phraseLevelRedactionEnabledKey) as? Bool ?? false

        var hasProtectedRedactionData = false
        var hasPendingRedactionRewrites = false

        do {
            hasProtectedRedactionData = try await services.database.hasProtectedPhraseRedactionData()
        } catch {
            Log.error(
                "[AppCoordinator] Failed to inspect protected phrase-redaction data state: \(error.localizedDescription)",
                category: .app
            )
        }

        do {
            let pendingVideoIDs = try await services.database.getVideoIDsWithPendingNodeRedactions(
                includeRetryableFailures: true
            )
            hasPendingRedactionRewrites = !pendingVideoIDs.isEmpty
        } catch {
            Log.error(
                "[AppCoordinator] Failed to inspect pending phrase-redaction rewrites: \(error.localizedDescription)",
                category: .app
            )
        }

        // TODO(master-key-recovery): Extend this startup decision tree once database encryption
        // is formally wired into the master-key UX. That branch needs to distinguish a missing
        // phrase-redaction key from a missing SQLCipher database key and may need to block DB open.
        return MissingMasterKeyRedactionState(
            hasMasterKey: hasMasterKey,
            phraseLevelRedactionEnabled: phraseLevelRedactionEnabled,
            hasProtectedRedactionData: hasProtectedRedactionData,
            hasPendingRedactionRewrites: hasPendingRedactionRewrites
        )
    }

    @discardableResult
    public func abandonPendingPhraseRedactionRewritesForFreshKey() async -> Int {
        do {
            return try await services.database.abandonPendingNodeRedactions(
                missingKeyRewritePurpose: Self.abandonedMissingMasterKeyRewritePurpose
            )
        } catch {
            Log.error(
                "[AppCoordinator] Failed to abandon pending phrase-redaction rewrites for fresh key: \(error.localizedDescription)",
                category: .app
            )
            return 0
        }
    }

    /// Track app/window changes and create/close segments accordingly
    /// Also handles idle detection - if no frames for longer than idleThresholdSeconds,
    /// closes the current segment and creates a new one on the next frame
    private func trackSessionChange(frame: CapturedFrame) async throws {
        let metadata = frame.metadata
        let captureConfig = await services.capture.getConfig()
        let normalizedBrowserURL: String?
        if let rawBrowserURL = metadata.browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBrowserURL.isEmpty {
            normalizedBrowserURL = rawBrowserURL
        } else {
            normalizedBrowserURL = nil
        }
        pruneRecentClosedNilBrowserURLSegments(referenceTime: frame.timestamp)

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
                // If we crossed an idle boundary, close at the last observed frame.
                // Otherwise close at the current transition frame timestamp.
                let segmentEndDate = Self.segmentEndDateForSessionTransition(
                    lastFrameTimestamp: lastFrameTimestamp,
                    transitionTimestamp: frame.timestamp,
                    idleDetected: idleDetected
                )
                try await services.database.updateSegmentEndDate(id: segID, endDate: segmentEndDate)
                Log.debug("Closed segment: \(currentSegment?.bundleID ?? "unknown") - \(currentSegment?.windowName ?? "nil")", category: .app)

                if let closedSegment = currentSegment,
                   closedSegment.browserUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let normalizedWindowName = normalizedWindowNameForStrictBackfill(closedSegment.windowName) {
                    recentClosedNilBrowserURLSegments.append(
                        RecentClosedNilBrowserURLSegment(
                            segmentID: segID,
                            bundleID: closedSegment.bundleID,
                            normalizedWindowName: normalizedWindowName,
                            closedAt: segmentEndDate
                        )
                    )
                    pruneRecentClosedNilBrowserURLSegments(referenceTime: frame.timestamp)
                }
            }

            // Create new segment
            let newSegmentID = try await services.database.insertSegment(
                bundleID: metadata.appBundleID ?? "unknown",
                startDate: frame.timestamp,
                endDate: frame.timestamp,  // Will be updated as frames are captured
                windowName: metadata.windowName,
                browserUrl: normalizedBrowserURL,
                type: 0  // 0 = screen capture
            )

            currentSegmentID = newSegmentID
            Log.debug(
                "Started segment: \(metadata.appBundleID ?? "unknown") - \(metadata.windowName ?? "nil") [segmentID=\(newSegmentID), browserURL=\(normalizedBrowserURL == nil ? "nil" : "present")]",
                category: .app
            )
            if let browserURL = normalizedBrowserURL {
                try await backfillRecentClosedNilBrowserURLSegments(
                    bundleID: metadata.appBundleID,
                    windowName: metadata.windowName,
                    browserURL: browserURL,
                    referenceTime: frame.timestamp
                )
            }
        } else if let segID = currentSegmentID,
                  let browserURL = normalizedBrowserURL {
            let existingBrowserURL: String?
            if let rawBrowserURL = currentSegment?.browserUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawBrowserURL.isEmpty {
                existingBrowserURL = rawBrowserURL
            } else {
                existingBrowserURL = nil
            }

            if existingBrowserURL == nil {
                try await services.database.updateSegmentBrowserURL(
                    id: segID,
                    browserURL: browserURL,
                    onlyIfNull: true
                )
                let host = URL(string: browserURL)?.host ?? browserURL
                Log.info(
                    "[SegmentURL] Backfilled browserUrl for segmentID=\(segID), bundle=\(metadata.appBundleID ?? "unknown"), host=\(host)",
                    category: .app
                )
                try await backfillRecentClosedNilBrowserURLSegments(
                    bundleID: metadata.appBundleID,
                    windowName: metadata.windowName,
                    browserURL: browserURL,
                    referenceTime: frame.timestamp
                )
            } else if existingBrowserURL != browserURL {
                try await services.database.updateSegmentBrowserURL(
                    id: segID,
                    browserURL: browserURL,
                    onlyIfNull: false
                )
                let previousLength = existingBrowserURL?.count ?? 0
                let newLength = browserURL.count
                Log.debug(
                    "[SegmentURL] Corrected browserUrl for segmentID=\(segID), bundle=\(metadata.appBundleID ?? "unknown"), oldLen=\(previousLength), newLen=\(newLength)",
                    category: .app
                )
            }
        }

        // Update last frame timestamp for idle detection
        lastFrameTimestamp = frame.timestamp
    }

    /// Computes segment end time when transitioning between sessions.
    /// Idle transitions close at the last observed frame (no idle credit).
    nonisolated static func segmentEndDateForSessionTransition(
        lastFrameTimestamp: Date?,
        transitionTimestamp: Date,
        idleDetected: Bool
    ) -> Date {
        if idleDetected, let lastFrameTimestamp {
            return lastFrameTimestamp
        }
        return transitionTimestamp
    }

    /// Computes segment end time when capture pipeline shuts down.
    /// Prefer the last observed frame to avoid synthetic tail time.
    nonisolated static func segmentEndDateForShutdown(
        lastFrameTimestamp: Date?,
        shutdownTimestamp: Date
    ) -> Date {
        lastFrameTimestamp ?? shutdownTimestamp
    }

    private func normalizedWindowNameForStrictBackfill(_ windowName: String?) -> String? {
        guard let windowName else { return nil }
        let normalized = windowName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func pruneRecentClosedNilBrowserURLSegments(referenceTime: Date) {
        recentClosedNilBrowserURLSegments.removeAll { entry in
            referenceTime.timeIntervalSince(entry.closedAt) > recentClosedSegmentBackfillWindowSeconds
        }
    }

    private func backfillRecentClosedNilBrowserURLSegments(
        bundleID: String?,
        windowName: String?,
        browserURL: String,
        referenceTime: Date
    ) async throws {
        guard let bundleID,
              let normalizedWindowName = normalizedWindowNameForStrictBackfill(windowName) else {
            return
        }

        pruneRecentClosedNilBrowserURLSegments(referenceTime: referenceTime)

        let matchingEntries = recentClosedNilBrowserURLSegments.filter { entry in
            entry.bundleID == bundleID && entry.normalizedWindowName == normalizedWindowName
        }
        guard !matchingEntries.isEmpty else { return }

        let matchingSegmentIDs = Set(matchingEntries.map(\.segmentID))
        for segmentID in matchingSegmentIDs {
            try await services.database.updateSegmentBrowserURL(id: segmentID, browserURL: browserURL)
        }

        recentClosedNilBrowserURLSegments.removeAll { matchingSegmentIDs.contains($0.segmentID) }
        let host = URL(string: browserURL)?.host ?? browserURL
        Log.info(
            "[SegmentURL] Backfilled browserUrl for \(matchingSegmentIDs.count) recently-closed segment(s), bundle=\(bundleID), windowName=\(windowName ?? "nil"), host=\(host)",
            category: .app
        )
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

    // MARK: - Queue Monitoring

    /// Get current OCR processing queue statistics
    public func getQueueStatistics() async -> QueueStatistics? {
        guard let queue = await services.processingQueue else {
            return nil
        }
        return await queue.getStatistics()
    }

    /// Get current power state for monitoring display
    nonisolated public func getCurrentPowerState() -> (source: PowerStateMonitor.PowerSource, isPaused: Bool) {
        let snapshot = OCRPowerSettingsSnapshot.fromDefaults()
        let source = PowerStateMonitor.shared.getCurrentPowerSource()
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        let isPaused =
            (snapshot.pauseOnBattery && source == .battery) ||
            (snapshot.pauseOnLowPowerMode && isLowPowerModeEnabled)
        return (source, isPaused)
    }

    /// Get frames processed per minute for the last N minutes
    /// Returns dictionary of [minuteOffset: count] where minuteOffset 0 = current minute
    public func getFramesProcessedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await services.database.getFramesProcessedPerMinute(lastMinutes: lastMinutes)
    }

    /// Get frames encoded/readable per minute for the last N minutes.
    /// Returns dictionary of [minuteOffset: count] where minuteOffset 0 = current minute.
    public func getFramesEncodedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await services.database.getFramesEncodedPerMinute(lastMinutes: lastMinutes)
    }

    /// Get frames rewritten per minute for the last N minutes.
    /// Returns dictionary of [minuteOffset: count] where minuteOffset 0 = current minute.
    public func getFramesRewrittenPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await services.database.getFramesRewrittenPerMinute(lastMinutes: lastMinutes)
    }

    /// Get current frame-encoding buffer backlog.
    /// The backlog is derived from frames that were created recently but are still not readable
    /// from the encoded video file, so the counts describe short-lived buffer lag rather than a
    /// durable worker queue.
    public func getEncodingStatistics() async -> (
        queueDepth: Int,
        pendingCount: Int
    )? {
        // Intentionally use a short recency window here. `processingStatus = 4` currently
        // conflates "buffered but still flushing to disk" with "older frame that may be stuck
        // or otherwise never became readable." For the System Monitor card we want a signal for
        // recent encoder buffer pressure, not a durable count that can stay pinned forever because
        // of one stale unreadable frame. Once buffering/stalled states are modeled separately,
        // this heuristic window should be replaced with explicit state-based accounting.
        let backlogWindowMinutes = 5

        guard let queueDepth = try? await services.database.getUnreadableFrameCount(withinLastMinutes: backlogWindowMinutes) else {
            return nil
        }

        return (
            queueDepth: queueDepth,
            pendingCount: queueDepth
        )
    }

    // MARK: - Search Interface

    /// Get distinct app bundle IDs from the database for filter UI.
    /// When `source` is `nil`, returns the union across all connected sources.
    /// Caller should use AppNameResolver.shared.resolveAll() to get display names.
    public nonisolated func getDistinctAppBundleIDs(source: FrameSource? = nil) async throws -> [String] {
        guard let adapter = await services.dataAdapter else {
            return []
        }
        return try await adapter.getDistinctAppBundleIDs(source: source)
    }

    /// Search for text across all captured frames
    public nonisolated func search(query: String, limit: Int = 50) async throws -> SearchResults {
        let searchQuery = SearchQuery(text: query, filters: .none, limit: limit, offset: 0)
        return try await search(query: searchQuery)
    }

    /// Advanced search with filters
    /// Routes to DataAdapter which prioritizes Rewind data source
    public nonisolated func search(query: SearchQuery) async throws -> SearchResults {
        // Try DataAdapter first (routes to Rewind if available)
        if let adapter = await services.dataAdapter {
            do {
                return try await adapter.search(query: query)
            } catch {
                Log.warning(
                    "[AppCoordinator] DataAdapter search failed, falling back to FTS: \(error)",
                    category: .app
                )
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

    /// Get frame image as CGImage without JPEG encode/decode round-trips.
    public func getFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?, source: FrameSource) async throws -> CGImage {
        guard let adapter = await services.dataAdapter else {
            throw NSError(domain: "AppCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "DataAdapter not initialized"])
        }

        return try await adapter.getFrameCGImage(
            videoPath: videoPath,
            frameIndex: frameIndex,
            frameRate: frameRate,
            source: source
        )
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

    /// Get frame image from a full video path (used for Rewind frames with string-based IDs).
    /// When not explicitly provided, strict timestamp matching follows timeline visibility:
    /// strict while visible, relaxed while hidden.
    public func getFrameImageFromPath(
        videoPath: String,
        frameIndex: Int,
        enforceTimestampMatch: Bool? = nil
    ) async throws -> Data {
        let shouldEnforceTimestampMatch = enforceTimestampMatch ?? isTimelineVisible
        return try await services.storage.readFrameFromPath(
            videoPath: videoPath,
            frameIndex: frameIndex,
            enforceTimestampMatch: shouldEnforceTimestampMatch
        )
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
    /// For browsers: returns websites (from browserUrl) first, then windowName fallbacks, with tab counts per website
    /// For non-browsers: returns windows by windowName
    /// Returns items sorted by type (websites first) then duration descending
    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil
    ) async throws -> [(windowName: String?, isWebsite: Bool, duration: TimeInterval, tabCount: Int?, totalCount: Int, totalDuration: TimeInterval)] {
        try await services.database.getWindowUsageForApp(bundleID: bundleID, from: startDate, to: endDate, limit: limit)
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
        // Prevent tagging Rewind data
        if try await isRewindSegment(segmentId: segmentId) {
            Log.warning("[AppCoordinator] Cannot add tag to Rewind segment \(segmentId.value)", category: .app)
            return
        }
        try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Add a tag to multiple segments
    public func addTagToSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        var addedCount = 0
        for segmentId in segmentIds {
            // Skip Rewind segments
            if try await isRewindSegment(segmentId: segmentId) {
                Log.debug("[AppCoordinator] Skipping tag add for Rewind segment \(segmentId.value)", category: .app)
                continue
            }
            try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
            addedCount += 1
        }
        Log.info("[AppCoordinator] Added tag \(tagId.value) to \(addedCount) segments (skipped \(segmentIds.count - addedCount) Rewind segments)", category: .app)
    }

    /// Remove a tag from a segment
    public func removeTagFromSegment(segmentId: SegmentID, tagId: TagID) async throws {
        // Prevent removing tags from Rewind data
        if try await isRewindSegment(segmentId: segmentId) {
            Log.warning("[AppCoordinator] Cannot remove tag from Rewind segment \(segmentId.value)", category: .app)
            return
        }
        try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Remove a tag from multiple segments
    public func removeTagFromSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        var removedCount = 0
        for segmentId in segmentIds {
            // Skip Rewind segments
            if try await isRewindSegment(segmentId: segmentId) {
                Log.debug("[AppCoordinator] Skipping tag removal for Rewind segment \(segmentId.value)", category: .app)
                continue
            }
            try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
            removedCount += 1
        }
        Log.info("[AppCoordinator] Removed tag \(tagId.value) from \(removedCount) segments (skipped \(segmentIds.count - removedCount) Rewind segments)", category: .app)
    }

    /// Check if a segment is from Rewind data (before the cutoff date)
    private func isRewindSegment(segmentId: SegmentID) async throws -> Bool {
        guard let adapter = await services.dataAdapter else {
            return false // No Rewind source configured
        }

        guard let cutoffDate = await adapter.rewindCutoffDate else {
            return false // No cutoff date means no Rewind data
        }

        // Get segment to check its start date
        guard let segment = try await services.database.getSegment(id: segmentId.value) else {
            return false // Segment doesn't exist
        }

        // If segment starts before cutoff, it's from Rewind
        return segment.startDate < cutoffDate
    }

    /// Get the Rewind cutoff date (for UI to check if data is from Rewind)
    public func getRewindCutoffDate() async -> Date? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }
        return await adapter.rewindCutoffDate
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

    /// Get a map of segment IDs to linked comment counts for timeline comment indicators.
    public func getSegmentCommentCountsMap() async throws -> [Int64: Int] {
        try await services.database.getSegmentCommentCountsMap()
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

    // MARK: - Segment Comment Operations

    /// Create a comment and apply it to all provided segments (bulk by default)
    /// Rewind segments are skipped to preserve read-only semantics.
    public func createCommentForSegments(
        body: String,
        segmentIds: [SegmentID],
        attachments: [SegmentCommentAttachment] = [],
        frameID: FrameID? = nil,
        author: String? = nil
    ) async throws -> SegmentCommentCreateResult {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw DatabaseError.constraintViolation(underlying: "Comment body cannot be empty")
        }

        let resolvedAuthor = resolvedCommentAuthor(author)
        let comment = try await services.database.createSegmentComment(
            body: trimmedBody,
            author: resolvedAuthor,
            attachments: attachments,
            frameID: frameID
        )

        var linkedSegmentIDs: [SegmentID] = []
        var skippedSegmentIDs: [SegmentID] = []
        var failedSegmentIDs: [SegmentID] = []

        for segmentId in segmentIds {
            do {
                if try await isRewindSegment(segmentId: segmentId) {
                    skippedSegmentIDs.append(segmentId)
                    continue
                }
                try await services.database.addCommentToSegment(segmentId: segmentId, commentId: comment.id)
                linkedSegmentIDs.append(segmentId)
            } catch {
                failedSegmentIDs.append(segmentId)
                Log.warning(
                    "[AppCoordinator] Failed linking comment \(comment.id.value) to segment \(segmentId.value): \(error)",
                    category: .app
                )
            }
        }

        if linkedSegmentIDs.isEmpty {
            // No eligible segments were linked, clean up the newly-created comment (and attachments).
            do {
                try await services.database.deleteSegmentComment(commentId: comment.id)
            } catch {
                Log.warning(
                    "[AppCoordinator] Failed cleanup for unlinked comment \(comment.id.value): \(error)",
                    category: .app
                )
            }
            throw DatabaseError.constraintViolation(underlying: "No eligible segments to attach comment")
        }

        Log.info(
            "[AppCoordinator] Created comment \(comment.id.value): linked=\(linkedSegmentIDs.count), skipped=\(skippedSegmentIDs.count), failed=\(failedSegmentIDs.count)",
            category: .app
        )
        return SegmentCommentCreateResult(
            comment: comment,
            linkedSegmentIDs: linkedSegmentIDs,
            skippedSegmentIDs: skippedSegmentIDs,
            failedSegmentIDs: failedSegmentIDs
        )
    }

    /// Link an existing comment to multiple segments
    public func addCommentToSegments(segmentIds: [SegmentID], commentId: SegmentCommentID) async throws {
        var linkedCount = 0
        for segmentId in segmentIds {
            if try await isRewindSegment(segmentId: segmentId) {
                continue
            }
            try await services.database.addCommentToSegment(segmentId: segmentId, commentId: commentId)
            linkedCount += 1
        }
        Log.info("[AppCoordinator] Linked comment \(commentId.value) to \(linkedCount) segments", category: .app)
    }

    /// Remove a comment link from multiple segments
    public func removeCommentFromSegments(segmentIds: [SegmentID], commentId: SegmentCommentID) async throws {
        var removedCount = 0
        for segmentId in segmentIds {
            if try await isRewindSegment(segmentId: segmentId) {
                continue
            }
            try await services.database.removeCommentFromSegment(segmentId: segmentId, commentId: commentId)
            removedCount += 1
        }
        Log.info("[AppCoordinator] Removed comment \(commentId.value) from \(removedCount) segments", category: .app)
    }

    private func withDatabaseActorTrace<T>(
        _ operation: String,
        _ body: () async throws -> T
    ) async throws -> T {
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        let traceID = String(UUID().uuidString.prefix(8))

        return try await DatabaseActorTraceContext.$requestEnqueuedAt.withValue(enqueuedAt) {
            try await DatabaseActorTraceContext.$operationName.withValue(operation) {
                try await DatabaseActorTraceContext.$traceID.withValue(traceID) {
                    try await body()
                }
            }
        }
    }

    /// Get comments linked to a segment
    public func getCommentsForSegment(segmentId: SegmentID) async throws -> [SegmentComment] {
        try await withDatabaseActorTrace("get_comments_for_segment") {
            try await services.database.getCommentsForSegment(segmentId: segmentId)
        }
    }

    /// Get unique comments linked to any of the provided segments, keeping the earliest
    /// requested segment as the preferred fallback target for each comment.
    public func getCommentsForSegments(segmentIds: [SegmentID]) async throws -> [LinkedSegmentComment] {
        let orderedSegmentIDs = segmentIds.uniquePreservingOrder()
        guard !orderedSegmentIDs.isEmpty else { return [] }

        return try await withDatabaseActorTrace("get_comments_for_segments") {
            try await services.database.getCommentsForSegments(segmentIds: orderedSegmentIDs)
        }
    }

    /// Get all linked comments with representative segment context (Retrace DB only).
    public func getAllCommentTimelineEntries() async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        try await services.database.getAllCommentTimelineEntries()
    }

    /// Search comments by body text (server-side, capped result set).
    public func searchSegmentComments(query: String, limit: Int = 10, offset: Int = 0) async throws -> [SegmentComment] {
        try await services.database.searchSegmentComments(query: query, limit: limit, offset: offset)
    }

    /// Search comments with representative segment context (All Comments view).
    public func searchCommentTimelineEntries(
        query: String,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        try await services.database.searchCommentTimelineEntries(query: query, limit: limit, offset: offset)
    }

    /// Update an existing comment
    public func updateSegmentComment(
        commentId: SegmentCommentID,
        body: String,
        attachments: [SegmentCommentAttachment],
        author: String? = nil
    ) async throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw DatabaseError.constraintViolation(underlying: "Comment body cannot be empty")
        }

        try await services.database.updateSegmentComment(
            commentId: commentId,
            body: trimmedBody,
            author: resolvedCommentAuthor(author),
            attachments: attachments
        )
    }

    /// Delete a comment and all of its segment links
    public func deleteSegmentComment(commentId: SegmentCommentID) async throws {
        try await services.database.deleteSegmentComment(commentId: commentId)
    }

    /// Get the number of linked segments for a comment
    public func getSegmentCountForComment(commentId: SegmentCommentID) async throws -> Int {
        try await services.database.getSegmentCountForComment(commentId: commentId)
    }

    /// Resolve the oldest linked segment for a comment.
    public func getFirstLinkedSegmentForComment(commentId: SegmentCommentID) async throws -> SegmentID? {
        try await services.database.getFirstLinkedSegmentForComment(commentId: commentId)
    }

    /// Resolve the oldest frame in a segment.
    public func getFirstFrameForSegment(segmentId: SegmentID) async throws -> FrameID? {
        try await services.database.getFirstFrameForSegment(segmentId: segmentId)
    }

    private nonisolated func resolvedCommentAuthor(_ proposedAuthor: String?) -> String {
        if let proposedAuthor {
            let trimmed = proposedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let fallback = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Unknown User" : fallback
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

    /// Persist optional per-frame metadata JSON payload.
    public func saveFrameMetadata(frameID: FrameID, metadataJSON: String?) async throws {
        try await services.database.updateFrameMetadata(frameID: frameID, metadataJSON: metadataJSON)
    }

    /// Load per-frame metadata JSON payload.
    public func getFrameMetadata(frameID: FrameID) async throws -> String? {
        try await services.database.getFrameMetadata(frameID: frameID)
    }

    public func replaceFrameInPageURLData(
        frameID: FrameID,
        state: FrameInPageURLState?,
        rows: [FrameInPageURLRow]
    ) async throws {
        let dbState = state.map {
            Database.FrameInPageURLState(
                mouseX: $0.mouseX,
                mouseY: $0.mouseY,
                scrollX: $0.scrollX,
                scrollY: $0.scrollY,
                videoCurrentTime: $0.videoCurrentTime
            )
        }
        let dbRows = rows.map {
            Database.FrameInPageURLRow(
                order: $0.order,
                url: $0.url,
                nodeID: $0.nodeID
            )
        }
        try await services.database.replaceFrameInPageURLData(
            frameID: frameID,
            state: dbState,
            rows: dbRows
        )
    }

    public func getFrameInPageURLRows(frameID: FrameID) async throws -> [FrameInPageURLRow] {
        let rows = try await services.database.getFrameInPageURLRows(frameID: frameID)
        return rows.map {
            FrameInPageURLRow(
                order: $0.order,
                url: $0.url,
                nodeID: $0.nodeID
            )
        }
    }

    public func getFrameInPageURLState(frameID: FrameID) async throws -> FrameInPageURLState? {
        let state = try await services.database.getFrameInPageURLState(frameID: frameID)
        return state.map {
            FrameInPageURLState(
                mouseX: $0.mouseX,
                mouseY: $0.mouseY,
                scrollX: $0.scrollX,
                scrollY: $0.scrollY,
                videoCurrentTime: $0.videoCurrentTime
            )
        }
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
        case 2, 7: // completed
            return .completed
        case 3, 8: // failed
            return .failed
        case 5, 6: // rewrite pending/processing
            return .rewriting
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

        let existingNodes = try await services.database.getOCRNodesWithText(frameID: frameID)
        if existingNodes.contains(where: \.isRedacted) {
            Log.warning(
                "[OCR-REPROCESS] Refusing to reprocess frame \(frameID.value) because it contains redacted OCR nodes",
                category: .processing
            )
            throw AppError.ocrReprocessBlockedForRedactedFrame(frameID: frameID.value)
        }

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

    /// Get all distinct dates that have frames for calendar display.
    /// When active filters are provided, the returned dates reflect the filtered timeline.
    /// Unfiltered calls keep using the fast filesystem path.
    public func getDistinctDates(filters: FilterCriteria? = nil) async throws -> [Date] {
        if let filters, filters.hasActiveFilters, let adapter = await services.dataAdapter {
            return try await adapter.getDistinctDates(filters: filters)
        }

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

    /// Get distinct hours for a specific date that have frames.
    /// When active filters are provided, the returned hours reflect the filtered timeline.
    public func getDistinctHoursForDate(_ date: Date, filters: FilterCriteria? = nil) async throws -> [Date] {
        if let adapter = await services.dataAdapter {
            return try await adapter.getDistinctHoursForDate(date, filters: filters)
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

    private func recordMouseClickCaptureMetricIfNeeded(
        outcome: MouseClickCaptureOutcome,
        timestamp: Date
    ) async {
        let metadata = Self.captureTriggerMetricMetadata([
            "trigger": "mouse_click",
            "outcome": outcome.rawValue,
            "button": "left"
        ])

        try? await recordMetricEvent(
            metricType: .mouseClickCapture,
            timestamp: timestamp,
            metadata: metadata
        )
    }

    private func recordVideoQualityMetricIfNeeded(
        quality: Double,
        source: String,
        isRunning: Bool
    ) async {
        let metadata = Self.captureTriggerMetricMetadata([
            "quality": quality,
            "source": source,
            "isRunning": isRunning
        ])

        try? await recordMetricEvent(
            metricType: .videoQualityUpdated,
            metadata: metadata
        )
    }

    private static func captureTriggerMetricMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
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

    public func getRecentMetricEvents(
        limit: Int
    ) async throws -> [FeedbackRecentMetricEvent] {
        let rawEvents = try await services.database.getRecentMetricEvents(
            limit: FeedbackRecentMetricSupport.rawEventFetchLimit(
                forDisplayedLimit: limit
            ),
            excluding: FeedbackRecentMetricSupport.excludedMetricTypes
        )
        return FeedbackRecentMetricSupport.sanitize(
            rawEvents,
            limit: limit
        )
    }

    /// Get daily screen time totals (for 7-day graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await services.database.getDailyScreenTime(from: startDate, to: endDate)
    }

    /// Estimate per-day durable DB growth from daily snapshots.
    /// Uses adjacent local-day rows directly because each day only stores one latest snapshot.
    /// WAL growth is intentionally ignored here because it is transient journal churn rather than
    /// retained storage growth.
    public func getDailyDBStorageEstimatedBytes(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard let snapshotStart = calendar.date(byAdding: .day, value: -1, to: startDay) else {
            return []
        }

        let snapshots = try await services.database.getDBStorageSnapshots(
            from: snapshotStart,
            to: endDay
        )
        guard snapshots.count >= 2 else {
            return []
        }

        let snapshotsByDay = Dictionary(
            uniqueKeysWithValues: snapshots.map { (calendar.startOfDay(for: $0.date), $0) }
        )

        var results: [(date: Date, value: Int64)] = []
        var currentDay = startDay
        while currentDay <= endDay {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: currentDay),
                  let currentSnapshot = snapshotsByDay[currentDay],
                  let previousSnapshot = snapshotsByDay[previousDay] else {
                currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
                continue
            }

            let currentTotal = currentSnapshot.dbBytes
            let previousTotal = previousSnapshot.dbBytes
            let estimatedGrowth = max(0, currentTotal - previousTotal)
            results.append((date: currentDay, value: estimatedGrowth))

            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
        }

        return results
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

    // MARK: - In-Page URL Metadata Capture

    private static let inPageURLCollectionExperimentalKey = "collectInPageURLsExperimental"
    private static let captureMousePositionKey = "captureMousePosition"
    private static let inPageURLChromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.sigmaos.sigmaos.macos",
        "com.nicklockwood.Thorium",
    ]
    private static let inPageURLChromiumHostBundleIDPrefixes: [String] = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.sigmaos.sigmaos.macos",
        "com.nicklockwood.Thorium",
    ]
    private static let inPageURLRawLinkLimit = 100
    private static let inPageURLAppleScriptTimeoutSeconds: TimeInterval = 4
    private static let inPageURLNoMatchingWindowToken = "__NO_MATCHING_WINDOW__"
    private static let inPageURLCaptureCoordinator = InPageURLCaptureCoordinator()

    private actor InPageURLCaptureCoordinator {
        private struct CaptureKey: Hashable {
            let bundleID: String
            let preferredURLNeedle: String
        }

        private struct BundleTaskState {
            let token: UUID
            let task: Task<String?, Error>
        }

        private var inFlightByKey: [CaptureKey: Task<String?, Error>] = [:]
        private var inFlightByBundle: [String: BundleTaskState] = [:]

        func capture(
            bundleID: String,
            preferredURL: String?,
            operation: @escaping @Sendable () async throws -> String?
        ) async throws -> String? {
            let key = CaptureKey(
                bundleID: bundleID,
                preferredURLNeedle: AppCoordinator.preferredURLNeedle(from: preferredURL) ?? ""
            )

            if let existingTask = inFlightByKey[key] {
                return try await existingTask.value
            }

            // Arc/Safari automation can time out when multiple in-page scripts hit the same
            // browser concurrently. Serialize execution per bundle while still coalescing by key.
            while let activeBundleTask = inFlightByBundle[bundleID] {
                _ = try? await activeBundleTask.task.value
                if inFlightByBundle[bundleID]?.token == activeBundleTask.token {
                    inFlightByBundle[bundleID] = nil
                }
                if let existingTask = inFlightByKey[key] {
                    return try await existingTask.value
                }
            }

            let token = UUID()
            let task = Task<String?, Error> {
                try await operation()
            }
            inFlightByKey[key] = task
            inFlightByBundle[bundleID] = BundleTaskState(token: token, task: task)
            defer {
                inFlightByKey[key] = nil
                if inFlightByBundle[bundleID]?.token == token {
                    inFlightByBundle[bundleID] = nil
                }
            }
            return try await task.value
        }
    }

    private struct InPageCapturedDOMLink: Codable, Sendable {
        let href: String
        let text: String
        let left: Double
        let top: Double
        let width: Double
        let height: Double
    }

    private struct InPageCapturedDOMMousePosition: Codable, Sendable {
        let x: Double
        let y: Double
    }

    private struct InPageCapturedDOMScrollPosition: Codable, Sendable {
        let x: Double
        let y: Double
    }

    private struct InPageCapturedDOMVideoPosition: Codable, Sendable {
        let currentTime: Double
    }

    private struct InPageCapturedDOMPayload: Decodable, Sendable {
        let pageUrl: String
        let links: [InPageCapturedDOMLink]
        let mousePosition: InPageCapturedDOMMousePosition?
        let scrollPosition: InPageCapturedDOMScrollPosition?
        let videoPosition: InPageCapturedDOMVideoPosition?
    }

    private struct PendingInPageURLMetadataRect: Codable, Sendable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    private struct PendingInPageURLMetadataResolvedURL: Codable, Sendable {
        let url: String
        let nid: Int
        let p: PendingInPageURLMetadataRect
    }

    private struct PendingInPageURLMetadataRawLink: Codable, Sendable {
        let url: String
        let text: String
        let left: Double
        let top: Double
        let width: Double
        let height: Double
    }

    private struct PendingInPageURLMetadataPoint: Codable, Sendable {
        let x: Double
        let y: Double
    }

    private struct PendingInPageURLMetadataVideoPosition: Codable, Sendable {
        let currenttime: Double
    }

    private struct PendingInPageURLMetadataPayload: Codable, Sendable {
        let pageurl: String
        let rawlinks: [PendingInPageURLMetadataRawLink]
        let urls: [PendingInPageURLMetadataResolvedURL]
        let mouseposition: PendingInPageURLMetadataPoint?
        let scrollposition: PendingInPageURLMetadataPoint?
        let videoposition: PendingInPageURLMetadataVideoPosition?
    }

    private enum InPageURLCaptureError: Error {
        case unsupportedBundleID
        case noWindows
        case noMatchingWindow
        case scriptFailed(String)
        case invalidOutput(String)
    }

    private func persistGlobalMousePositionIfNeeded(
        frameID: Int64,
        capturedFrame: CapturedFrame
    ) async {
        guard Self.isMousePositionCollectionEnabled(),
              let mousePosition = Self.globalMousePosition(in: capturedFrame) else {
            return
        }

        do {
            try await services.database.replaceFrameInPageURLData(
                frameID: FrameID(value: frameID),
                state: Database.FrameInPageURLState(
                    mouseX: mousePosition.x,
                    mouseY: mousePosition.y,
                    scrollX: nil,
                    scrollY: nil,
                    videoCurrentTime: nil
                ),
                rows: []
            )
        } catch {
            Log.warning(
                "[MousePosition] Failed to persist mouse position for frame \(frameID): \(error)",
                category: .app
            )
        }
    }

    private func scheduleInPageURLMetadataCaptureIfNeeded(
        frameID: Int64,
        frameMetadata: FrameMetadata
    ) {
        guard Self.isInPageURLCollectionEnabled(),
              let bundleID = frameMetadata.appBundleID,
              Self.isInPageURLCaptureSupported(bundleID: bundleID) else {
            return
        }

        let database = services.database
        let services = self.services
        let frameIDValue = frameID
        let preferredURL = frameMetadata.browserURL
        let preferredURLNeedle = Self.preferredURLNeedle(from: preferredURL) ?? "<none>"

        Task.detached(priority: .utility) {
            do {
                guard let metadataJSON = try await Self.inPageURLCaptureCoordinator.capture(
                    bundleID: bundleID,
                    preferredURL: preferredURL,
                    operation: {
                        try await Self.capturePendingInPageURLMetadataJSON(
                            bundleID: bundleID,
                            preferredURL: preferredURL
                        )
                    }
                ) else {
                    return
                }

                try await database.updateFrameMetadata(
                    frameID: FrameID(value: frameIDValue),
                    metadataJSON: metadataJSON
                )

                if let processingQueue = await services.processingQueue {
                    try await processingQueue.resolveInPageURLMetadataIfPossible(frameID: frameIDValue)
                }
            } catch {
                Log.debug(
                    "[InPageURL][Capture] Pending metadata capture failed for frameID=\(frameIDValue), bundleID=\(bundleID), needle=\(preferredURLNeedle): \(error)",
                    category: .app
                )
            }
        }
    }

    private static func isInPageURLCollectionEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard defaults.object(forKey: inPageURLCollectionExperimentalKey) != nil else {
            return false
        }
        return defaults.bool(forKey: inPageURLCollectionExperimentalKey)
    }

    private static func isMousePositionCollectionEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard defaults.object(forKey: captureMousePositionKey) != nil else {
            return true
        }
        return defaults.bool(forKey: captureMousePositionKey)
    }

    private static func globalMousePosition(in frame: CapturedFrame) -> PendingInPageURLMetadataPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }

        guard let event = CGEvent(source: nil) else { return nil }
        let location = event.location
        let displayID = CGDirectDisplayID(frame.metadata.displayID)
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0,
              displayBounds.height > 0,
              displayBounds.contains(location) else {
            return nil
        }

        let relativeX = location.x - displayBounds.origin.x
        let relativeY = location.y - displayBounds.origin.y
        let scaleX = Double(frame.width) / Double(displayBounds.width)
        let scaleY = Double(frame.height) / Double(displayBounds.height)

        // CGEvent.location is already top-down in display coordinates.
        // Store top-down frame coordinates so timeline overlays can map directly.
        let x = relativeX * scaleX
        let y = relativeY * scaleY

        let clampedX = min(max(x, 0), Double(frame.width - 1))
        let clampedY = min(max(y, 0), Double(frame.height - 1))

        return PendingInPageURLMetadataPoint(
            x: roundedMetadataCoordinate(clampedX),
            y: roundedMetadataCoordinate(clampedY)
        )
    }

    private static func isInPageURLCaptureSupported(bundleID: String) -> Bool {
        if bundleID == "com.apple.Safari" {
            return true
        }
        if inPageURLChromiumBundleIDs.contains(bundleID) {
            return true
        }
        return inPageURLChromiumHostBundleIDPrefixes.contains { prefix in
            bundleID.hasPrefix(prefix + ".app.")
        }
    }

    static func inPageURLHostBrowserBundleID(for bundleID: String) -> String? {
        if inPageURLChromiumBundleIDs.contains(bundleID) {
            return bundleID
        }

        for prefix in inPageURLChromiumHostBundleIDPrefixes where bundleID.hasPrefix(prefix + ".app.") {
            return prefix
        }

        return nil
    }

    private static func isInPageURLChromiumAppShimBundleID(_ bundleID: String) -> Bool {
        guard let hostBrowserBundleID = inPageURLHostBrowserBundleID(for: bundleID) else {
            return false
        }
        return hostBrowserBundleID != bundleID
    }

    private static func capturePendingInPageURLMetadataJSON(
        bundleID: String,
        preferredURL: String?
    ) async throws -> String? {
        let scriptLines = try inPageURLCaptureScriptLines(
            bundleID: bundleID,
            preferredURL: preferredURL
        )
        let rawOutput = try await runInPageURLAppleScript(lines: scriptLines)
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "__NO_WINDOWS__" {
            throw InPageURLCaptureError.noWindows
        }
        if trimmed == inPageURLNoMatchingWindowToken {
            throw InPageURLCaptureError.noMatchingWindow
        }

        let payload: InPageCapturedDOMPayload
        do {
            payload = try decodeInPageCapturedDOMPayload(from: trimmed)
        } catch {
            var preview = trimmed.replacingOccurrences(of: "\n", with: "\\n")
            if preview.count > 160 {
                preview = String(preview.prefix(160)) + "..."
            }
            throw InPageURLCaptureError.invalidOutput("json decode failed: \(error), outputPreview=\(preview)")
        }

        var dedupedRawLinks: [PendingInPageURLMetadataRawLink] = []
        dedupedRawLinks.reserveCapacity(min(payload.links.count, inPageURLRawLinkLimit))
        var seenKeys: Set<String> = []
        seenKeys.reserveCapacity(min(payload.links.count, inPageURLRawLinkLimit))
        for link in payload.links {
            if dedupedRawLinks.count >= inPageURLRawLinkLimit {
                break
            }

            let url = link.href.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !text.isEmpty else { continue }

            let roundedLeft = roundedMetadataCoordinate(link.left)
            let roundedTop = roundedMetadataCoordinate(link.top)
            let roundedWidth = roundedMetadataCoordinate(link.width)
            let roundedHeight = roundedMetadataCoordinate(link.height)
            guard roundedWidth > 0, roundedHeight > 0 else { continue }

            let key = "\(url)|\(text)|\(roundedLeft)|\(roundedTop)|\(roundedWidth)|\(roundedHeight)"
            guard seenKeys.insert(key).inserted else { continue }

            dedupedRawLinks.append(
                PendingInPageURLMetadataRawLink(
                    url: url,
                    text: text,
                    left: roundedLeft,
                    top: roundedTop,
                    width: roundedWidth,
                    height: roundedHeight
                )
            )
        }

        let metadataPayload = PendingInPageURLMetadataPayload(
            pageurl: payload.pageUrl,
            rawlinks: dedupedRawLinks,
            urls: [],
            mouseposition: nil,
            scrollposition: payload.scrollPosition.map {
                PendingInPageURLMetadataPoint(
                    x: roundedMetadataCoordinate($0.x),
                    y: roundedMetadataCoordinate($0.y)
                )
            },
            videoposition: payload.videoPosition.map {
                PendingInPageURLMetadataVideoPosition(
                    currenttime: $0.currentTime
                )
            }
        )

        let encodedData = try JSONEncoder().encode(metadataPayload)
        return String(data: encodedData, encoding: .utf8)
    }

    private static func decodeInPageCapturedDOMPayload(
        from rawOutput: String
    ) throws -> InPageCapturedDOMPayload {
        guard let data = rawOutput.data(using: .utf8) else {
            throw InPageURLCaptureError.invalidOutput("utf8 conversion failed")
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(InPageCapturedDOMPayload.self, from: data)
        } catch let directError {
            // Arc can return JSON-stringified payloads wrapped as a string literal.
            if let wrappedJSONString = try? decoder.decode(String.self, from: data),
               let wrappedData = wrappedJSONString.data(using: .utf8),
               let payload = try? decoder.decode(InPageCapturedDOMPayload.self, from: wrappedData) {
                return payload
            }
            throw directError
        }
    }

    private static func inPageURLCaptureScriptLines(
        bundleID: String,
        preferredURL: String?
    ) throws -> [String] {
        let escapedJS = appleScriptEscaped(inPageURLCaptureJavaScript)
        let preferredNeedle = appleScriptEscaped(preferredURLNeedle(from: preferredURL) ?? "")

        if bundleID == "com.apple.Safari" {
            return [
                "set __retraceNeedle to \"\(preferredNeedle)\"",
                "tell application id \"com.apple.Safari\"",
                "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
                "set t to missing value",
                "if __retraceNeedle is not \"\" then",
                "repeat with w in windows",
                "repeat with candidateTab in tabs of w",
                "try",
                "set tabURL to URL of candidateTab",
                "if tabURL contains __retraceNeedle then",
                "set t to candidateTab",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "if t is not missing value then exit repeat",
                "end repeat",
                "end if",
                "if t is missing value then set t to current tab of front window",
                "with timeout of \(Int(inPageURLAppleScriptTimeoutSeconds)) seconds",
                "return do JavaScript \"\(escapedJS)\" in t",
                "end timeout",
                "end tell",
            ]
        }

        guard isInPageURLCaptureSupported(bundleID: bundleID) else {
            throw InPageURLCaptureError.unsupportedBundleID
        }

        if isInPageURLChromiumAppShimBundleID(bundleID),
           let hostBrowserBundleID = inPageURLHostBrowserBundleID(for: bundleID) {
            return chromiumAppShimInPageURLCaptureScriptLines(
                appShimBundleID: bundleID,
                hostBrowserBundleID: hostBrowserBundleID,
                preferredNeedle: preferredNeedle,
                escapedJS: escapedJS
            )
        }

        if bundleID == "company.thebrowser.Browser" {
            // Arc returns UUID-backed object references that can fail when coerced via
            // intermediate tab variables; resolve through tab id within front window.
            return [
                "set __retraceNeedle to \"\(preferredNeedle)\"",
                "tell application id \"\(bundleID)\"",
                "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
                "set targetTabID to id of active tab of front window",
                "if __retraceNeedle is not \"\" then",
                "repeat with candidateTab in tabs of front window",
                "try",
                "set tabURL to URL of candidateTab",
                "if tabURL contains __retraceNeedle then",
                "set targetTabID to id of candidateTab",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "end if",
                "with timeout of \(Int(inPageURLAppleScriptTimeoutSeconds)) seconds",
                "return execute (tab id targetTabID of front window) javascript \"\(escapedJS)\"",
                "end timeout",
                "end tell",
            ]
        }

        return chromiumInPageURLCaptureScriptLines(
            bundleID: bundleID,
            preferredNeedle: preferredNeedle,
            escapedJS: escapedJS
        )
    }

    private static func chromiumInPageURLCaptureScriptLines(
        bundleID: String,
        preferredNeedle: String,
        escapedJS: String
    ) -> [String] {
        [
            "set __retraceNeedle to \"\(preferredNeedle)\"",
            "tell application id \"\(bundleID)\"",
            "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
            "set t to active tab of front window",
            "if __retraceNeedle is not \"\" then",
            "try",
            "set activeTabURL to URL of t",
            "if activeTabURL does not contain __retraceNeedle then set t to missing value",
            "on error",
            "set t to missing value",
            "end try",
            "if t is missing value then",
            "repeat with w in windows",
            "repeat with candidateTab in tabs of w",
            "try",
            "set tabURL to URL of candidateTab",
            "if tabURL contains __retraceNeedle then",
            "set t to candidateTab",
            "exit repeat",
            "end if",
            "end try",
            "end repeat",
            "if t is not missing value then exit repeat",
            "end repeat",
            "end if",
            "end if",
            "if t is missing value then set t to active tab of front window",
            "with timeout of \(Int(inPageURLAppleScriptTimeoutSeconds)) seconds",
            "return execute t javascript \"\(escapedJS)\"",
            "end timeout",
            "end tell",
        ]
    }

    private static func chromiumAppShimInPageURLCaptureScriptLines(
        appShimBundleID: String,
        hostBrowserBundleID: String,
        preferredNeedle: String,
        escapedJS: String
    ) -> [String] {
        [
            "set __retraceNeedle to \"\(preferredNeedle)\"",
            "set __retraceWindowTitle to \"\"",
            "tell application id \"\(appShimBundleID)\"",
            "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
            "try",
            "set __retraceWindowTitle to name of front window",
            "end try",
            "end tell",
            "tell application id \"\(hostBrowserBundleID)\"",
            "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
            "set targetWindowIndex to -1",
            "set targetTabIndex to -1",
            "set wIndex to 1",
            "repeat with w in windows",
            "set tIndex to 1",
            "repeat with candidateTab in tabs of w",
            "set tabURL to \"\"",
            "set tabTitle to \"\"",
            "try",
            "set tabURL to URL of candidateTab",
            "set tabTitle to title of candidateTab",
            "end try",
            "if targetTabIndex is -1 and __retraceNeedle is not \"\" and tabURL is not \"\" then",
            "if tabURL contains __retraceNeedle then",
            "set targetWindowIndex to wIndex",
            "set targetTabIndex to tIndex",
            "exit repeat",
            "end if",
            "end if",
            "if targetTabIndex is -1 and __retraceWindowTitle is not \"\" and tabTitle is not \"\" then",
            "if __retraceWindowTitle is equal to tabTitle then",
            "set targetWindowIndex to wIndex",
            "set targetTabIndex to tIndex",
            "exit repeat",
            "end if",
            "if __retraceWindowTitle ends with (\" - \" & tabTitle) then",
            "set targetWindowIndex to wIndex",
            "set targetTabIndex to tIndex",
            "exit repeat",
            "end if",
            "end if",
            "set tIndex to tIndex + 1",
            "end repeat",
            "if targetTabIndex is not -1 then exit repeat",
            "set wIndex to wIndex + 1",
            "end repeat",
            "if targetTabIndex is -1 then return \"\(inPageURLNoMatchingWindowToken)\"",
            "with timeout of \(Int(inPageURLAppleScriptTimeoutSeconds)) seconds",
            "return execute (tab targetTabIndex of window targetWindowIndex) javascript \"\(escapedJS)\"",
            "end timeout",
            "end tell",
        ]
    }

    static func preferredURLNeedle(from rawURL: String?) -> String? {
        guard let rawURL,
              let parsed = URL(string: rawURL),
              let host = parsed.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            return normalizedHost
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = components.percentEncodedQuery?.trimmingCharacters(in: .whitespacesAndNewlines)

        var needle = normalizedHost
        if !path.isEmpty, path != "/" {
            needle += path
        } else if let query, !query.isEmpty {
            needle += "/"
        }

        if let query, !query.isEmpty {
            needle += "?\(query)"
        }

        return needle
    }

    private static func runInPageURLAppleScript(lines: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let startTime = CFAbsoluteTimeGetCurrent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = lines.flatMap { ["-e", $0] }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            let deadline = Date().addingTimeInterval(inPageURLAppleScriptTimeoutSeconds + 1)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20), clock: .continuous)
            }

            if process.isRunning {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000.0
                process.terminate()
                process.waitUntilExit()
                throw InPageURLCaptureError.scriptFailed(
                    "Timed out waiting for browser response after \(inPageURLAppleScriptTimeoutSeconds)s (elapsed=\(String(format: "%.1f", elapsedMs))ms)"
                )
            }

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errors = String(data: errorData, encoding: .utf8) ?? ""
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000.0

            if process.terminationStatus != 0 {
                throw InPageURLCaptureError.scriptFailed(
                    errors.isEmpty
                    ? "exit \(process.terminationStatus), elapsed=\(String(format: "%.1f", elapsedMs))ms"
                    : "\(errors) (elapsed=\(String(format: "%.1f", elapsedMs))ms)"
                )
            }

            if elapsedMs >= 1_000 {
                Log.debug(
                    "[InPageURL][Capture] AppleScript slow-path elapsed=\(String(format: "%.1f", elapsedMs))ms outputBytes=\(outputData.count)",
                    category: .app
                )
            }

            return output
        }.value
    }

    private static func roundedMetadataCoordinate(_ value: Double) -> Double {
        let rounded = (value * 1_000.0).rounded() / 1_000.0
        if rounded == -0 {
            return 0
        }
        return rounded
    }

    private static var inPageURLCaptureJavaScript: String {
        """
        (function() {
            const links = document.links;
            const maxLinks = \(inPageURLRawLinkLimit);
            const maxScannedLinks = 800;
            const scanBudgetMs = 1200;
            const scanStartTime = (window.performance && typeof window.performance.now === 'function')
                ? window.performance.now()
                : Date.now();
            const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
            const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
            const out = [];

            for (let index = 0; index < links.length; index += 1) {
                if (out.length >= maxLinks) break;
                if (index >= maxScannedLinks) break;
                const scanNow = (window.performance && typeof window.performance.now === 'function')
                    ? window.performance.now()
                    : Date.now();
                if ((scanNow - scanStartTime) > scanBudgetMs) break;
                const link = links[index];
                if (!link) continue;
                const href = (link.href || '').trim();
                if (!href) continue;

                const rect = link.getBoundingClientRect();
                if (!rect || rect.width <= 1 || rect.height <= 1) continue;
                if (rect.bottom < 0 || rect.right < 0 || rect.top > viewportHeight || rect.left > viewportWidth) continue;
                const visibleLeft = Math.max(0, rect.left);
                const visibleTop = Math.max(0, rect.top);
                const visibleRight = Math.min(viewportWidth, rect.right);
                const visibleBottom = Math.min(viewportHeight, rect.bottom);
                const visibleWidth = visibleRight - visibleLeft;
                const visibleHeight = visibleBottom - visibleTop;
                if (visibleWidth <= 1 || visibleHeight <= 1) continue;

                const text = ((link.textContent || link.innerText || '').replace(/\\s+/g, ' ').trim());
                if (!text) continue;

                out.push({
                    href: href,
                    text: text,
                    left: visibleLeft,
                    top: visibleTop,
                    width: visibleWidth,
                    height: visibleHeight
                });
            }

            let scrollPosition = (() => {
                const rawX = Number(window.scrollX);
                const fallbackX = Number(window.pageXOffset);
                const rawY = Number(window.scrollY);
                const fallbackY = Number(window.pageYOffset);
                return {
                    x: Number.isFinite(rawX) ? rawX : (Number.isFinite(fallbackX) ? fallbackX : 0),
                    y: Number.isFinite(rawY) ? rawY : (Number.isFinite(fallbackY) ? fallbackY : 0)
                };
            })();

            let videoPosition = null;
            const videos = document.getElementsByTagName('video');
            for (let index = 0; index < videos.length; index += 1) {
                const video = videos[index];
                if (!video) continue;
                const rect = video.getBoundingClientRect();
                if (!rect) continue;
                if (rect.width <= 1 || rect.height <= 1) continue;
                if (rect.bottom < 0 || rect.right < 0 || rect.top > viewportHeight || rect.left > viewportWidth) continue;

                const currentTime = Number(video.currentTime);
                if (!Number.isFinite(currentTime)) continue;

                const durationRaw = Number(video.duration);
                const duration = Number.isFinite(durationRaw) ? durationRaw : null;
                videoPosition = {
                    currentTime: currentTime,
                    duration: duration,
                    paused: !!video.paused
                };
                break;
            }

            return JSON.stringify({
                pageUrl: location.href,
                links: out,
                scrollPosition: scrollPosition,
                videoPosition: videoPosition
            });
        })();
        """
    }

    private static func appleScriptEscaped(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
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
        /// OCR is complete and frame is queued for a video rewrite / re-encode.
        case rewriting
        /// OCR or a follow-up rewrite failed permanently
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
        case .rewriting: return "Re-encoding..."
        case .failed: return "Processing Failed"
        case .unknown: return ""
        }
    }

    /// Whether OCR is still in progress (queued or processing)
    public var isInProgress: Bool {
        switch state {
        case .queued, .processing, .pending, .rewriting:
            return true
        case .completed, .failed, .unknown:
            return false
        }
    }

    // Convenience static constructors
    public static let completed = OCRProcessingStatus(state: .completed)
    public static let pending = OCRProcessingStatus(state: .pending)
    public static let processing = OCRProcessingStatus(state: .processing)
    public static let rewriting = OCRProcessingStatus(state: .rewriting)
    public static let failed = OCRProcessingStatus(state: .failed)
    public static let unknown = OCRProcessingStatus(state: .unknown)

    public static func queued(position: Int?, depth: Int?) -> OCRProcessingStatus {
        OCRProcessingStatus(state: .queued, queuePosition: position, queueDepth: depth)
    }
}

public enum AppError: Error {
    case permissionDenied(permission: String)
    case storageUnavailable(reason: String)
    case notInitialized
    case alreadyRunning
    case notRunning
    case processingQueueNotAvailable
    case ocrReprocessBlockedForRedactedFrame(frameID: Int64)
}

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let permission):
            return "Missing required permission: \(permission)."
        case .storageUnavailable(let reason):
            return "Storage is unavailable: \(reason)"
        case .notInitialized:
            return "Retrace is not initialized yet."
        case .alreadyRunning:
            return "Recording is already running."
        case .notRunning:
            return "Recording is not running."
        case .processingQueueNotAvailable:
            return "The processing queue is not available."
        case .ocrReprocessBlockedForRedactedFrame(let frameID):
            return "OCR refresh is not available for frame \(frameID) because it contains protected redacted text."
        }
    }
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
