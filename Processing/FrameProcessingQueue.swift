import CoreGraphics
import Foundation
import Shared
import Database
import Search
import ImageIO

public enum PendingRewriteDeferralReason: String, Sendable, Equatable {
    case timelineInteraction
    case rewriteAlreadyInProgress
    case videoNotFinalized
    case videoRecordUnavailable
    case pendingOCR
    case missingMasterKey
}

public enum PendingRewriteDispatchOutcome: Sendable, Equatable {
    case noPendingWork
    case deferred(PendingRewriteDeferralReason)
    case completed
}

enum OCRStageMemoryLedger {
    private static let tracker = Tracker()
    private static let phaseResidualHoldSeconds: TimeInterval = 0.8
    private static let summaryIntervalSeconds: TimeInterval = 30
    private static let transientResidualSpecs: [(tag: String, function: String, kind: String)] = [
        ("processing.ocr.stageFrameLoadResidual", "processing.ocr.stage_load", "stage-frame-load-residual"),
        ("processing.ocr.stageExtractResidual", "processing.ocr.stage_extract", "stage-extract-residual"),
        ("processing.ocr.stageReleaseResidual", "processing.ocr.stage_release", "stage-release-residual"),
        ("processing.ocr.stageObservedResidual", "processing.ocr.stage", "stage-observed-residual"),
        ("processing.ocr.stageResidual", "processing.ocr.stage_residual", "stage-residual")
    ]

    static func measuredResidualBytes(
        before: MemoryLedger.Snapshot,
        after: MemoryLedger.Snapshot
    ) -> Int64 {
        let processDelta = after.footprintBytes > before.footprintBytes
            ? after.footprintBytes - before.footprintBytes
            : 0
        let trackedDelta = after.trackedMemoryBytes > before.trackedMemoryBytes
            ? after.trackedMemoryBytes - before.trackedMemoryBytes
            : 0
        let clampedTrackedDelta = UInt64(max(0, trackedDelta))

        guard processDelta > clampedTrackedDelta else { return 0 }
        let residualBytes = processDelta - clampedTrackedDelta
        return Int64(min(residualBytes, UInt64(Int64.max)))
    }

    static func currentUnattributedBytes(_ snapshot: MemoryLedger.Snapshot) -> Int64 {
        Int64(min(snapshot.unattributedBytes, UInt64(Int64.max)))
    }

    static func beginActiveFrame(bytes: Int64, reason: String) {
        tracker.begin(
            tag: "processing.ocr.activeFrames",
            function: "processing.ocr.pipeline",
            kind: "active-frame",
            note: "estimated",
            unit: "frames",
            bytes: bytes,
            reason: reason
        )
    }

    static func endActiveFrame(bytes: Int64, reason: String) {
        tracker.end(
            tag: "processing.ocr.activeFrames",
            bytes: bytes,
            reason: reason
        )
    }

    static func currentActiveFrameCount() -> Int {
        tracker.currentCount(tag: "processing.ocr.activeFrames")
    }

    static func currentTrackedBytes(tag: String) -> Int64 {
        tracker.currentBytes(tag: tag)
    }

    static func clearTransientStageResiduals(reason: String) {
        for spec in transientResidualSpecs {
            tracker.clear(
                tag: spec.tag,
                function: spec.function,
                kind: spec.kind,
                note: "cycle-reset",
                unit: "samples",
                reason: reason,
                emitSummary: false
            )
        }
    }

    static func setActiveFrameCountForTesting(
        _ count: Int,
        bytesPerFrame: Int64 = 1
    ) {
        tracker.setCountForTesting(
            tag: "processing.ocr.activeFrames",
            function: "processing.ocr.pipeline",
            kind: "active-frame",
            note: "estimated",
            unit: "frames",
            count: count,
            bytesPerUnit: bytesPerFrame
        )
    }

    static func beginJPEGDecodeSurface(width: Int, height: Int, reason: String) {
        tracker.begin(
            tag: "processing.ocr.jpegDecodeSurface",
            function: "processing.ocr.pipeline",
            kind: "jpeg-decode-surface",
            note: "estimated-native",
            unit: "surfaces",
            bytes: estimatedSurfaceBytes(width: width, height: height),
            reason: reason
        )
    }

    static func endJPEGDecodeSurface(width: Int, height: Int, reason: String) {
        tracker.end(
            tag: "processing.ocr.jpegDecodeSurface",
            bytes: estimatedSurfaceBytes(width: width, height: height),
            reason: reason
        )
    }

    static func emitObservedResidual(reason: String) async {
        let snapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let residualBytes = Int64(min(snapshot.unattributedBytes, UInt64(Int64.max)))
        tracker.setRetained(
            tag: "processing.ocr.stageResidual",
            function: "processing.ocr.stage_residual",
            kind: "stage-residual",
            note: "observed-unattributed",
            unit: "samples",
            bytes: residualBytes,
            reason: reason,
            delay: 0
        )
    }

    static func setResidual(
        tag: String,
        function: String,
        kind: String,
        note: String,
        bytes: Int64,
        reason: String,
        delay: TimeInterval = phaseResidualHoldSeconds,
        forceSummary: Bool = true
    ) {
        tracker.setRetained(
            tag: tag,
            function: function,
            kind: kind,
            note: note,
            unit: "samples",
            bytes: bytes,
            reason: reason,
            delay: delay,
            forceSummary: forceSummary
        )
    }

    static func fallbackStageResidualBytes(
        totalStageResidualBytes: Int64,
        frameLoadResidualBytes: Int64,
        extractResidualBytes: Int64,
        releaseResidualBytes: Int64,
        stageObservedResidualBytes: Int64,
        stageResidualExclusionBytes: Int64
    ) -> Int64 {
        max(
            0,
            totalStageResidualBytes -
                max(0, frameLoadResidualBytes) -
                max(0, extractResidualBytes) -
                max(0, releaseResidualBytes) -
                max(0, stageObservedResidualBytes) -
                max(0, stageResidualExclusionBytes)
        )
    }

    static func stageObservedResidualBytes(
        settledHandoffObservedResidualBytes: Int64,
        currentUnattributedBytes: Int64,
        activeOCRFrameCount: Int
    ) -> Int64 {
        guard settledHandoffObservedResidualBytes <= 0 else { return 0 }
        guard activeOCRFrameCount <= 0 else { return 0 }
        return max(0, currentUnattributedBytes)
    }

    private static func estimatedSurfaceBytes(width: Int, height: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        return max(0, Int64(width) * Int64(height) * 4)
    }

    private final class Tracker: @unchecked Sendable {
        private struct Entry {
            var bytes: Int64
            var count: Int
            var function: String
            var kind: String
            var note: String?
            var unit: String
            var category: MemoryLedger.ComponentCategory
        }

        private let lock = NSLock()
        private var entriesByTag: [String: Entry] = [:]
        private var retainedGenerationByTag: [String: UInt64] = [:]

        func begin(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            unit: String,
            bytes: Int64,
            reason: String
        ) {
            guard bytes > 0 else { return }

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note,
                unit: unit,
                category: .explicit
            )
            entry.bytes += bytes
            entry.count += 1
            entry.function = function
            entry.kind = kind
            entry.note = note
            entry.unit = unit
            entry.category = .explicit
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: OCRStageMemoryLedger.summaryIntervalSeconds
            )
        }

        func end(tag: String, bytes: Int64, reason: String) {
            guard bytes > 0 else { return }

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: "processing.ocr.pipeline",
                kind: "active-frame",
                note: nil,
                unit: "items",
                category: .explicit
            )
            entry.bytes = max(0, entry.bytes - bytes)
            entry.count = max(0, entry.count - 1)
            entry.category = .explicit
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: OCRStageMemoryLedger.summaryIntervalSeconds
            )
        }

        func setRetained(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            unit: String,
            bytes: Int64,
            reason: String,
            delay: TimeInterval,
            forceSummary: Bool = false
        ) {
            let generation: UInt64

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note,
                unit: unit,
                category: .inferred
            )
            entry.bytes = max(0, bytes)
            entry.count = entry.bytes > 0 ? 1 : 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entry.unit = unit
            entry.category = .inferred
            entriesByTag[tag] = entry
            generation = (retainedGenerationByTag[tag] ?? 0) + 1
            retainedGenerationByTag[tag] = generation
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: OCRStageMemoryLedger.summaryIntervalSeconds
            )

            let boundedDelay = max(0, delay)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + boundedDelay) { [self] in
                clearRetainedIfCurrent(tag: tag, generation: generation, reason: reason)
            }
        }

        private func clearRetainedIfCurrent(tag: String, generation: UInt64, reason: String) {
            lock.lock()
            guard retainedGenerationByTag[tag] == generation else {
                lock.unlock()
                return
            }

            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: "processing.ocr.stage_residual",
                kind: "stage-residual",
                note: "observed-unattributed",
                unit: "samples",
                category: .inferred
            )
            entry.bytes = 0
            entry.count = 0
            entry.category = .inferred
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: OCRStageMemoryLedger.summaryIntervalSeconds
            )
        }

        func currentCount(tag: String) -> Int {
            lock.lock()
            let count = entriesByTag[tag]?.count ?? 0
            lock.unlock()
            return count
        }

        func currentBytes(tag: String) -> Int64 {
            lock.lock()
            let bytes = entriesByTag[tag]?.bytes ?? 0
            lock.unlock()
            return bytes
        }

        func clear(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            unit: String,
            reason: String,
            emitSummary: Bool
        ) {
            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note,
                unit: unit,
                category: .inferred
            )
            entry.bytes = 0
            entry.count = 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entry.unit = unit
            entry.category = .inferred
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            guard emitSummary else { return }
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: OCRStageMemoryLedger.summaryIntervalSeconds
            )
        }

        func setCountForTesting(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            unit: String,
            count: Int,
            bytesPerUnit: Int64
        ) {
            let sanitizedCount = max(0, count)
            let sanitizedBytesPerUnit = max(0, bytesPerUnit)
            let totalBytes: Int64
            if sanitizedCount == 0 || sanitizedBytesPerUnit == 0 {
                totalBytes = 0
            } else {
                let (product, overflowed) = Int64(sanitizedCount).addingReportingOverflow(0)
                if overflowed {
                    totalBytes = Int64.max
                } else {
                    let (multiplied, didOverflow) = product.multipliedReportingOverflow(by: sanitizedBytesPerUnit)
                    totalBytes = didOverflow ? Int64.max : multiplied
                }
            }

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note,
                unit: unit,
                category: .explicit
            )
            entry.bytes = totalBytes
            entry.count = sanitizedCount
            entry.function = function
            entry.kind = kind
            entry.note = note
            entry.unit = unit
            entry.category = .explicit
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
        }

        private func publish(tag: String, entry: Entry) {
            MemoryLedger.set(
                tag: tag,
                bytes: entry.bytes,
                count: entry.count,
                unit: entry.unit,
                function: entry.function,
                kind: entry.kind,
                note: entry.note,
                category: entry.category
            )
        }
    }
}

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
    private var totalRewritten: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0
    private var ocrPendingCount: Int = 0
    private var ocrProcessingCount: Int = 0
    private var rewritePendingCount: Int = 0
    private var rewriteProcessingCount: Int = 0

    private let memoryReportIntervalNs: UInt64 = 5_000_000_000
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    private static let memoryLedgerQueueTag = "processing.ocr.queueDepth"
    private static let memoryLedgerWorkersTag = "processing.ocr.workers"
    private static let rewriteResumeDebounceNs: UInt64 = 300_000_000
    private static let defaultRetryableRewriteRetryDelayNs: UInt64 = 5_000_000_000
    private static let phraseRedactionPhrasesDefaultsKey = "phraseLevelRedactionPhrases"
    private static let phraseRedactionEnabledDefaultsKey = "phraseLevelRedactionEnabled"
    private static let phraseRedactionExtraTokenSlack = 2
    private static let phraseRedactionMaxNodeSpan = 8
    private var isPausedForMemoryPressure = false
    private var activeRewriteVideoIDs: Set<Int64> = []
    private var rewriteVideosNeedingRedrain: Set<Int64> = []
    private var isRewriteTimelineVisible = false
    private var isRewriteTimelineScrubbing = false
    private var rewriteResumeTask: Task<Void, Never>?
    private var retryableRewriteRetryTask: Task<Void, Never>?
    private var startupRewriteRecoveryPending = false
    private var exhaustedAutomaticRewriteRetryVideoIDs: Set<Int64> = []

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

    // MARK: - Rewrite Scheduling

    private var isRewriteSchedulingSuspended: Bool {
        isRewriteTimelineVisible || isRewriteTimelineScrubbing
    }

    public func setTimelineVisibleForRewriteScheduling(_ visible: Bool) {
        guard isRewriteTimelineVisible != visible else { return }
        isRewriteTimelineVisible = visible
        handleRewriteSchedulingStateChange(
            trigger: visible ? "timeline-visible" : "timeline-hidden"
        )
    }

    public func setTimelineScrubbingForRewriteScheduling(_ scrubbing: Bool) {
        guard isRewriteTimelineScrubbing != scrubbing else { return }
        isRewriteTimelineScrubbing = scrubbing
        handleRewriteSchedulingStateChange(
            trigger: scrubbing ? "timeline-scrubbing" : "timeline-scrub-idle"
        )
    }

    private func handleRewriteSchedulingStateChange(trigger: String) {
        rewriteResumeTask?.cancel()
        rewriteResumeTask = nil

        if isRewriteSchedulingSuspended {
            Log.info(
                "[Queue-Rewrite] Suspended pending segment rewrites (\(trigger)); timelineVisible=\(isRewriteTimelineVisible), scrubbing=\(isRewriteTimelineScrubbing)",
                category: .processing
            )
            return
        }

        let delayNs = Self.rewriteResumeDebounceNs
        rewriteResumeTask = Task { [delayNs] in
            try? await Task.sleep(for: .nanoseconds(Int64(delayNs)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self.resumePendingRedactionsAfterInteractiveTimeline(trigger: trigger)
        }

        Log.debug(
            "[Queue-Rewrite] Scheduling pending segment rewrite resume in \(delayNs / 1_000_000)ms (\(trigger))",
            category: .processing
        )
    }

    private func resumePendingRedactionsAfterInteractiveTimeline(trigger: String) async {
        guard !isRewriteSchedulingSuspended else { return }

        if await performStartupRewriteRecoveryIfPending(trigger: "interactive-idle:\(trigger)") {
            return
        }

        await drainPendingRewritesIfPossible(
            includeInProgressJobs: false,
            includeRetryableFailures: false,
            trigger: "interactive-idle:\(trigger)"
        )
    }

    @discardableResult
    private func performStartupRewriteRecoveryIfPending(trigger: String) async -> Bool {
        guard startupRewriteRecoveryPending else { return false }
        guard !isRewriteSchedulingSuspended else {
            Log.debug(
                "[Queue-Rewrite] Startup rewrite recovery still deferred while timeline is active (\(trigger))",
                category: .processing
            )
            return false
        }

        startupRewriteRecoveryPending = false

        do {
            await reconcileInterruptedSegmentRewritesOnStartup()

            let pendingVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: true
            )
            guard !pendingVideoIDs.isEmpty else { return true }

            Log.info(
                "[Queue-Rewrite] Startup recovery found \(pendingVideoIDs.count) video(s) with pending rewrites (\(trigger))",
                category: .processing
            )

            for videoID in pendingVideoIDs {
                do {
                    _ = try await processPendingRewrites(
                        for: videoID,
                        includeInProgressJobs: true,
                        includeRetryableFailures: true
                    )
                } catch {
                    Log.error(
                        "[Queue-Rewrite] Startup recovery failed for video \(videoID): \(error.localizedDescription)",
                        category: .processing
                    )
                }
            }
        } catch {
            Log.error(
                "[Queue-Rewrite] Failed to scan pending rewrites on startup: \(error.localizedDescription)",
                category: .processing
            )
        }

        return true
    }

    private func drainPendingRewritesIfPossible(
        includeInProgressJobs: Bool,
        includeRetryableFailures: Bool,
        trigger: String
    ) async {
        guard !isRewriteSchedulingSuspended else {
            Log.debug(
                "[Queue-Rewrite] Skipping pending rewrite drain while timeline interaction is active (\(trigger))",
                category: .processing
            )
            return
        }

        do {
            let pendingVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: includeRetryableFailures
            )
            guard !pendingVideoIDs.isEmpty else { return }

            Log.info(
                "[Queue-Rewrite] Draining \(pendingVideoIDs.count) pending rewrite video(s), includeRetryableFailures=\(includeRetryableFailures), trigger=\(trigger)",
                category: .processing
            )

            for videoID in pendingVideoIDs {
                do {
                    _ = try await processPendingRewrites(
                        for: videoID,
                        includeInProgressJobs: includeInProgressJobs,
                        includeRetryableFailures: includeRetryableFailures
                    )
                } catch {
                    Log.error(
                        "[Queue-Rewrite] Pending rewrite drain failed for video \(videoID): \(error.localizedDescription), trigger=\(trigger)",
                        category: .processing
                    )
                }
            }
        } catch {
            Log.error(
                "[Queue-Rewrite] Failed to scan pending rewrites for drain: \(error.localizedDescription), trigger=\(trigger)",
                category: .processing
            )
        }
    }

    private func schedulePendingRewriteRedrainIfNeeded(for videoID: Int64) {
        guard rewriteVideosNeedingRedrain.remove(videoID) != nil else { return }

        Log.debug(
            "[Queue-Rewrite] Scheduling follow-up rewrite drain after active rewrite finished for video \(videoID)",
            category: .processing
        )

        Task {
            await self.drainPendingRewritesIfPossible(
                includeInProgressJobs: false,
                includeRetryableFailures: false,
                trigger: "post-active-rewrite:\(videoID)"
            )
        }
    }

    private func scheduleRetryableRewriteRetry(
        trigger: String,
        delayNs: UInt64? = nil
    ) {
        retryableRewriteRetryTask?.cancel()
        let effectiveDelayNs = delayNs ?? config.retryableRewriteRetryDelayNs

        retryableRewriteRetryTask = Task { [effectiveDelayNs] in
            if effectiveDelayNs > 0 {
                try? await Task.sleep(for: .nanoseconds(Int64(effectiveDelayNs)), clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            await self.drainRetryableFailedRewritesIfPossible(trigger: trigger)
        }
    }

    private func drainRetryableFailedRewritesIfPossible(trigger: String) async {
        guard !isRewriteSchedulingSuspended else {
            Log.debug(
                "[Queue-Rewrite] Deferring retryable failed rewrite drain while timeline interaction is active (\(trigger))",
                category: .processing
            )
            scheduleRetryableRewriteRetry(trigger: "\(trigger)-timeline-active")
            return
        }

        guard !startupRewriteRecoveryPending else {
            Log.debug(
                "[Queue-Rewrite] Skipping retryable failed rewrite drain because startup recovery is still pending (\(trigger))",
                category: .processing
            )
            return
        }

        do {
            let standardPendingVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: false
            )
            guard standardPendingVideoIDs.isEmpty else {
                Log.debug(
                    "[Queue-Rewrite] Delaying retryable failed rewrite drain until \(standardPendingVideoIDs.count) standard rewrite video(s) clear (\(trigger))",
                    category: .processing
                )
                scheduleRetryableRewriteRetry(trigger: "\(trigger)-standard-pending")
                return
            }

            let retryableFailedVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: true
            )
            let eligibleRetryableFailedVideoIDs = retryableFailedVideoIDs.filter {
                !exhaustedAutomaticRewriteRetryVideoIDs.contains($0)
            }
            guard !eligibleRetryableFailedVideoIDs.isEmpty else {
                Log.debug(
                    "[Queue-Rewrite] No eligible retryable failed rewrites remain after one automatic retry (\(trigger))",
                    category: .processing
                )
                return
            }

            Log.info(
                "[Queue-Rewrite] Retrying \(eligibleRetryableFailedVideoIDs.count) retryable failed rewrite video(s) (\(trigger))",
                category: .processing
            )

            for videoID in eligibleRetryableFailedVideoIDs {
                do {
                    let outcome = try await processPendingRewrites(
                        for: videoID,
                        includeRetryableFailures: true,
                        isAutomaticRetryOfFailedRewrite: true
                    )
                    if case .deferred(let reason) = outcome {
                        Log.debug(
                            "[Queue-Rewrite] Retryable failed rewrite for video \(videoID) deferred during retry drain: \(reason.rawValue)",
                            category: .processing
                        )
                    }
                } catch {
                    Log.error(
                        "[Queue-Rewrite] Retryable failed rewrite retry failed for video \(videoID): \(error.localizedDescription), trigger=\(trigger)",
                        category: .processing
                    )
                }
            }

            let remainingStandardVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: false
            )
            let remainingRetryableVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: true
            )
            let remainingStandardSet = Set(remainingStandardVideoIDs)
            if remainingRetryableVideoIDs.contains(where: {
                !remainingStandardSet.contains($0) &&
                    !exhaustedAutomaticRewriteRetryVideoIDs.contains($0)
            }) {
                scheduleRetryableRewriteRetry(trigger: "\(trigger)-remaining")
            }
        } catch {
            Log.error(
                "[Queue-Rewrite] Failed to drain retryable failed rewrites: \(error.localizedDescription), trigger=\(trigger)",
                category: .processing
            )
            scheduleRetryableRewriteRetry(trigger: "\(trigger)-scan-failed")
        }
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
            ocrPendingCount = counts.ocrPending
            ocrProcessingCount = counts.ocrProcessing
            rewritePendingCount = counts.rewritePending
            rewriteProcessingCount = counts.rewriteProcessing
            currentQueueDepth = counts.ocrPending + counts.ocrProcessing
        }

        let priority = workerPriority
        for workerID in 0..<config.workerCount {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }

        // Recovery can leave rewrite-pending/in-progress frames stranded after OCR
        // completed. Sweep and finish those rewrites on startup.
        startupRewriteRecoveryPending = true
        Task {
            _ = await performStartupRewriteRecoveryIfPending(trigger: "startup")
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
        rewriteResumeTask?.cancel()
        rewriteResumeTask = nil
        retryableRewriteRetryTask?.cancel()
        retryableRewriteRetryTask = nil
        exhaustedAutomaticRewriteRetryVideoIDs.removeAll()

        MemoryLedger.set(
            tag: Self.memoryLedgerWorkersTag,
            bytes: 0,
            count: 0,
            unit: "workers",
            function: "processing.ocr",
            kind: "worker-pool"
        )

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
                        // Dequeue now moves frames to `.processing` atomically, so deferred work
                        // must explicitly return the frame to pending before re-enqueueing it.
                        try await updateFrameProcessingStatus(queuedFrame.frameID, status: .pending)

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

        let phraseRedactionResult = applyPhraseLevelRedaction(
            to: ocrStage.extractedText,
            actualFrameID: frameID
        )
        let indexedText = phraseRedactionResult.sanitizedText
        let hasRedactedNodes = !phraseRedactionResult.redactedCombinedNodeOrders.isEmpty

        let docid = try await search.index(
            text: indexedText,
            segmentId: frameRef.segmentID.value,
            frameId: frameID
        )

        // Insert OCR nodes for both main and chrome regions so any FTS hit can be highlighted.
        let hasAnyOCRRegions = !indexedText.regions.isEmpty || !indexedText.chromeRegions.isEmpty
        if hasAnyOCRRegions && (docid > 0 || hasRedactedNodes) {
            // Delete any existing nodes first to prevent duplicates
            // (can happen if frame is reprocessed without going through reprocessOCR)
            try await databaseManager.deleteNodes(frameID: FrameID(value: frameID))

            var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []
            nodeData.reserveCapacity(indexedText.regions.count + indexedText.chromeRegions.count)

            // c0 offsets: main OCR text joined with single-space separators.
            var mainOffset = 0
            for region in indexedText.regions {
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
            var chromeOffset = indexedText.fullText.count
            for region in indexedText.chromeRegions {
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
                encryptedTexts: phraseRedactionResult.encryptedRedactedTexts,
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

        if phraseRedactionResult.redactedCombinedNodeOrders.isEmpty {
            try await updateFrameProcessingStatus(frameID, status: .completed)
        } else {
            try await updateFrameProcessingStatus(
                frameID,
                status: .rewritePending,
                rewritePurpose: "redaction"
            )
        }

        // Video rewrites run only on finalized segments. Defer the actual rewrite
        // until OCR has quiesced for the whole video so we only re-encode once.
        if frameWithInfo.videoInfo?.isVideoFinalized ?? true {
            _ = try? await processPendingRewrites(for: frameRef.videoID.value)
        }

        return .success
    }

    private func performOCRStage(
        frameID: Int64,
        frameRef: FrameReference,
        frameWithInfo: FrameWithVideoInfo,
        videoSegment: VideoSegment,
        actualSegmentID: VideoSegmentID
    ) async throws -> OCRStageResult {
        let residualEpoch = await MemoryLedger.beginResidualEpoch(
            ownerFunction: "processing.ocr.stage",
            candidateConcurrentFunctions: ["capture.screen_capture"]
        )
        OCRStageMemoryLedger.clearTransientStageResiduals(reason: "processing.ocr.stage")
        let stageBaselineSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)

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
                await MemoryLedger.endResidualEpoch(residualEpoch)
                return .failedPermanently
            }

            let frameData = try await storage.readFrame(
                segmentID: actualSegmentID,
                frameIndex: frameRef.frameIndexInSegment
            )

            guard let convertedFrame = try convertJPEGToCapturedFrame(frameData, frameRef: frameRef) else {
                Log.error("[Queue-DIAG] Frame \(frameID) image conversion failed!", category: .processing)
                await MemoryLedger.endResidualEpoch(residualEpoch)
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
                await MemoryLedger.endResidualEpoch(residualEpoch)
                return .deferred
            }
            capturedFrame = walFrame
            processedFrameWidth = walFrame.width
            processedFrameHeight = walFrame.height
        }

        let postFrameLoadSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let frameLoadResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
            before: stageBaselineSnapshot,
            after: postFrameLoadSnapshot
        )
        OCRStageMemoryLedger.setResidual(
            tag: "processing.ocr.stageFrameLoadResidual",
            function: "processing.ocr.stage_load",
            kind: "stage-frame-load-residual",
            note: "observed-footprint-delta",
            bytes: frameLoadResidualBytes,
            reason: "processing.ocr.stage_frame_load"
        )

        let ocrStartTime = CFAbsoluteTimeGetCurrent()
        let activeFrameBytes = Int64(capturedFrame.imageData.count)
        OCRStageMemoryLedger.beginActiveFrame(
            bytes: activeFrameBytes,
            reason: "processing.ocr.stage"
        )
        let extractedText: ExtractedText
        do {
            extractedText = try await processing.extractText(from: capturedFrame)
            let postExtractSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
            let extractResidualBytes = max(
                0,
                OCRStageMemoryLedger.measuredResidualBytes(
                before: postFrameLoadSnapshot,
                after: postExtractSnapshot
                ) - ProcessingExtractMemoryLedger.currentStageResidualExclusionBytes()
            )
            await ProcessingExtractMemoryLedger.clearObservedResidualsForHandoff(
                reason: "processing.ocr.stage_extract"
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageExtractResidual",
                function: "processing.ocr.stage_extract",
                kind: "stage-extract-residual",
                note: "observed-footprint-delta-net-active-extract-residuals",
                bytes: extractResidualBytes,
                reason: "processing.ocr.stage_extract"
            )
            OCRStageMemoryLedger.endActiveFrame(
                bytes: activeFrameBytes,
                reason: "processing.ocr.stage"
            )
            let postReleaseSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
            let releaseResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
                before: postExtractSnapshot,
                after: postReleaseSnapshot
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageReleaseResidual",
                function: "processing.ocr.stage_release",
                kind: "stage-release-residual",
                note: "observed-footprint-delta",
                bytes: releaseResidualBytes,
                reason: "processing.ocr.stage_release"
            )
            _ = ProcessingExtractMemoryLedger.settleObservedResidualAtStageRelease(
                snapshot: postReleaseSnapshot,
                reason: "processing.ocr.stage_release"
            )
            let settledHandoffObservedResidualBytes =
                ProcessingExtractMemoryLedger.currentHandoffObservedResidualBytes()
            let stageObservedResidualBytes = OCRStageMemoryLedger.stageObservedResidualBytes(
                settledHandoffObservedResidualBytes: settledHandoffObservedResidualBytes,
                currentUnattributedBytes: OCRStageMemoryLedger.currentUnattributedBytes(postReleaseSnapshot),
                activeOCRFrameCount: OCRStageMemoryLedger.currentActiveFrameCount()
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageObservedResidual",
                function: "processing.ocr.stage",
                kind: "stage-observed-residual",
                note: "observed-current-unattributed-after-stage-release",
                bytes: stageObservedResidualBytes,
                reason: "processing.ocr.stage_release",
                delay: 0.8
            )
            let totalStageResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
                before: stageBaselineSnapshot,
                after: postReleaseSnapshot
            )
            let fallbackStageResidualBytes = OCRStageMemoryLedger.fallbackStageResidualBytes(
                totalStageResidualBytes: totalStageResidualBytes,
                frameLoadResidualBytes: frameLoadResidualBytes,
                extractResidualBytes: extractResidualBytes,
                releaseResidualBytes: releaseResidualBytes,
                stageObservedResidualBytes: stageObservedResidualBytes,
                stageResidualExclusionBytes: ProcessingExtractMemoryLedger.currentStageResidualExclusionBytes()
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageResidual",
                function: "processing.ocr.stage_residual",
                kind: "stage-residual",
                note: "observed-stage-remainder",
                bytes: fallbackStageResidualBytes,
                reason: "processing.ocr.stage"
            )
        } catch {
            OCRStageMemoryLedger.endActiveFrame(
                bytes: activeFrameBytes,
                reason: "processing.ocr.stage"
            )
            let postFailureSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
            let extractResidualBytes = max(
                0,
                OCRStageMemoryLedger.measuredResidualBytes(
                before: postFrameLoadSnapshot,
                after: postFailureSnapshot
                ) - ProcessingExtractMemoryLedger.currentStageResidualExclusionBytes()
            )
            await ProcessingExtractMemoryLedger.clearObservedResidualsForHandoff(
                reason: "processing.ocr.stage_extract"
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageExtractResidual",
                function: "processing.ocr.stage_extract",
                kind: "stage-extract-residual",
                note: "observed-footprint-delta-net-active-extract-residuals",
                bytes: extractResidualBytes,
                reason: "processing.ocr.stage_extract"
            )
            let totalStageResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
                before: stageBaselineSnapshot,
                after: postFailureSnapshot
            )
            _ = ProcessingExtractMemoryLedger.settleObservedResidualAtStageRelease(
                snapshot: postFailureSnapshot,
                reason: "processing.ocr.stage_extract"
            )
            let settledHandoffObservedResidualBytes =
                ProcessingExtractMemoryLedger.currentHandoffObservedResidualBytes()
            let stageObservedResidualBytes = OCRStageMemoryLedger.stageObservedResidualBytes(
                settledHandoffObservedResidualBytes: settledHandoffObservedResidualBytes,
                currentUnattributedBytes: OCRStageMemoryLedger.currentUnattributedBytes(postFailureSnapshot),
                activeOCRFrameCount: OCRStageMemoryLedger.currentActiveFrameCount()
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageObservedResidual",
                function: "processing.ocr.stage",
                kind: "stage-observed-residual",
                note: "observed-current-unattributed-after-stage-failure",
                bytes: stageObservedResidualBytes,
                reason: "processing.ocr.stage_extract",
                delay: 0.8
            )
            let fallbackStageResidualBytes = OCRStageMemoryLedger.fallbackStageResidualBytes(
                totalStageResidualBytes: totalStageResidualBytes,
                frameLoadResidualBytes: frameLoadResidualBytes,
                extractResidualBytes: extractResidualBytes,
                releaseResidualBytes: 0,
                stageObservedResidualBytes: stageObservedResidualBytes,
                stageResidualExclusionBytes: ProcessingExtractMemoryLedger.currentStageResidualExclusionBytes()
            )
            OCRStageMemoryLedger.setResidual(
                tag: "processing.ocr.stageResidual",
                function: "processing.ocr.stage_residual",
                kind: "stage-residual",
                note: "observed-stage-remainder",
                bytes: fallbackStageResidualBytes,
                reason: "processing.ocr.stage"
            )
            await MemoryLedger.endResidualEpoch(residualEpoch)
            throw error
        }

        await MemoryLedger.endResidualEpoch(residualEpoch)
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

            OCRStageMemoryLedger.beginJPEGDecodeSurface(
                width: cgImage.width,
                height: cgImage.height,
                reason: "processing.ocr.jpeg_decode"
            )
            defer {
                OCRStageMemoryLedger.endJPEGDecodeSurface(
                    width: cgImage.width,
                    height: cgImage.height,
                    reason: "processing.ocr.jpeg_decode"
                )
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
        do {
            return try await storage.readFrameFromWAL(
                segmentID: segmentID,
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

        // Browser-provided mouse coordinates are viewport-relative and can be stale across captures.
        // Preserve only capture-derived mouse position already stored on the frame.
        let existingState = try await databaseManager.getFrameInPageURLState(frameID: frameID)

        let state = FrameInPageURLState(
            mouseX: existingState?.mouseX,
            mouseY: existingState?.mouseY,
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

    // MARK: - Phrase-Level Redaction

    private struct PhraseLevelRedactionResult {
        let sanitizedText: ExtractedText
        let redactedCombinedNodeOrders: Set<Int>
        let encryptedRedactedTexts: [Int: String]
    }

    private struct NormalizedPhraseRedactionPhrase {
        let normalizedText: String
        let compactText: String
        let tokenCount: Int
    }

    private struct IndexedPhraseRedactionToken {
        let token: String
        let combinedNodeOrder: Int
    }

    private func applyPhraseLevelRedaction(
        to extracted: ExtractedText,
        actualFrameID: Int64? = nil
    ) -> PhraseLevelRedactionResult {
        let defaults = UserDefaults(suiteName: ReversibleOCRScrambler.settingsSuiteName) ?? .standard
        let preliminaryResult = Self.applyPhraseLevelRedaction(
            to: extracted,
            phrases: loadPhraseLevelRedactionPhrases(defaults: defaults)
        )

        guard !preliminaryResult.redactedCombinedNodeOrders.isEmpty else {
            return preliminaryResult
        }

        let secret = ReversibleOCRScrambler.currentAppWideSecret()
        let effectiveFrameID = actualFrameID ?? extracted.frameID.value
        let finalResult = Self.finalizedPhraseLevelRedactionResult(
            extracted: extracted,
            preliminaryResult: preliminaryResult,
            secret: secret,
            actualFrameID: effectiveFrameID
        )
        if secret != nil {
            return finalResult
        }

        Log.warning(
            "[PhraseRedaction] Skipping phrase-level redaction for frame \(effectiveFrameID) because no master key exists",
            category: .processing
        )
        return finalResult
    }

    static func applyPhraseLevelRedactionForTesting(
        to extracted: ExtractedText,
        phrases: [String],
        redactionSecret: String? = "test-secret",
        actualFrameID: Int64? = nil
    ) -> (
        sanitizedText: ExtractedText,
        redactedCombinedNodeOrders: Set<Int>,
        encryptedRedactedTexts: [Int: String]
    ) {
        let preliminaryResult = applyPhraseLevelRedaction(
            to: extracted,
            phrases: normalizedRedactionPhrases(phrases)
        )
        let finalResult = finalizedPhraseLevelRedactionResult(
            extracted: extracted,
            preliminaryResult: preliminaryResult,
            secret: redactionSecret,
            actualFrameID: actualFrameID ?? extracted.frameID.value
        )
        return (
            finalResult.sanitizedText,
            finalResult.redactedCombinedNodeOrders,
            finalResult.encryptedRedactedTexts
        )
    }

    private static func applyPhraseLevelRedaction(
        to extracted: ExtractedText,
        phrases: [NormalizedPhraseRedactionPhrase]
    ) -> PhraseLevelRedactionResult {
        var redactedNodeOrders: Set<Int> = []

        if !phrases.isEmpty {
            redactedNodeOrders.formUnion(
                redactedCombinedNodeOrders(in: extracted.regions, offset: 0, phrases: phrases)
            )
            redactedNodeOrders.formUnion(
                redactedCombinedNodeOrders(
                    in: extracted.chromeRegions,
                    offset: extracted.regions.count,
                    phrases: phrases
                )
            )
        }

        guard !redactedNodeOrders.isEmpty else {
            return PhraseLevelRedactionResult(
                sanitizedText: extracted,
                redactedCombinedNodeOrders: [],
                encryptedRedactedTexts: [:]
            )
        }

        let maskedMainRegions: [TextRegion] = extracted.regions.enumerated().map { index, region in
            guard redactedNodeOrders.contains(index) else { return region }
            return TextRegion(
                id: region.databaseID,
                frameID: region.frameID,
                text: maskedTextPreservingLength(region.text),
                bounds: region.bounds,
                confidence: region.confidence,
                createdAt: region.createdAt
            )
        }

        let chromeBaseOrder = extracted.regions.count
        let maskedChromeRegions: [TextRegion] = extracted.chromeRegions.enumerated().map { index, region in
            guard redactedNodeOrders.contains(chromeBaseOrder + index) else { return region }
            return TextRegion(
                id: region.databaseID,
                frameID: region.frameID,
                text: maskedTextPreservingLength(region.text),
                bounds: region.bounds,
                confidence: region.confidence,
                createdAt: region.createdAt
            )
        }

        let sanitized = ExtractedText(
            frameID: extracted.frameID,
            timestamp: extracted.timestamp,
            regions: maskedMainRegions,
            chromeRegions: maskedChromeRegions,
            fullText: maskedMainRegions.map(\.text).joined(separator: " "),
            chromeText: maskedChromeRegions.map(\.text).joined(separator: " "),
            metadata: extracted.metadata
        )

        return PhraseLevelRedactionResult(
            sanitizedText: sanitized,
            redactedCombinedNodeOrders: redactedNodeOrders,
            encryptedRedactedTexts: [:]
        )
    }

    private static func encryptedRedactedTexts(
        from extracted: ExtractedText,
        redactedCombinedNodeOrders: Set<Int>,
        frameID: Int64,
        secret: String
    ) -> [Int: String] {
        guard !redactedCombinedNodeOrders.isEmpty else {
            return [:]
        }

        var encryptedTexts: [Int: String] = [:]

        for (index, region) in extracted.regions.enumerated() {
            guard redactedCombinedNodeOrders.contains(index) else { continue }
            guard let encryptedText = ReversibleOCRScrambler.encryptOCRText(
                region.text,
                frameID: frameID,
                nodeOrder: index,
                secret: secret
            ) else {
                continue
            }
            encryptedTexts[index] = encryptedText
        }

        let chromeBaseOrder = extracted.regions.count
        for (index, region) in extracted.chromeRegions.enumerated() {
            let combinedNodeOrder = chromeBaseOrder + index
            guard redactedCombinedNodeOrders.contains(combinedNodeOrder) else { continue }
            guard let encryptedText = ReversibleOCRScrambler.encryptOCRText(
                region.text,
                frameID: frameID,
                nodeOrder: combinedNodeOrder,
                secret: secret
            ) else {
                continue
            }
            encryptedTexts[combinedNodeOrder] = encryptedText
        }

        return encryptedTexts
    }

    private static func finalizedPhraseLevelRedactionResult(
        extracted: ExtractedText,
        preliminaryResult: PhraseLevelRedactionResult,
        secret: String?,
        actualFrameID: Int64
    ) -> PhraseLevelRedactionResult {
        guard !preliminaryResult.redactedCombinedNodeOrders.isEmpty else {
            return preliminaryResult
        }
        guard let secret else {
            return PhraseLevelRedactionResult(
                sanitizedText: extracted,
                redactedCombinedNodeOrders: [],
                encryptedRedactedTexts: [:]
            )
        }
        let encryptedTexts = encryptedRedactedTexts(
            from: extracted,
            redactedCombinedNodeOrders: preliminaryResult.redactedCombinedNodeOrders,
            frameID: actualFrameID,
            secret: secret
        )
        return PhraseLevelRedactionResult(
            sanitizedText: preliminaryResult.sanitizedText,
            redactedCombinedNodeOrders: preliminaryResult.redactedCombinedNodeOrders,
            encryptedRedactedTexts: encryptedTexts
        )
    }

    private func loadPhraseLevelRedactionPhrases(defaults: UserDefaults) -> [NormalizedPhraseRedactionPhrase] {
        guard let raw = defaults.string(forKey: Self.phraseRedactionPhrasesDefaultsKey),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard Self.isPhraseLevelRedactionEnabled(defaults: defaults, hasStoredPhrases: true) else { return [] }

        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return Self.normalizedRedactionPhrases(decoded)
        }

        let fallback = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map(String.init)
        return Self.normalizedRedactionPhrases(fallback)
    }

    private static func isPhraseLevelRedactionEnabled(
        defaults: UserDefaults,
        hasStoredPhrases: Bool
    ) -> Bool {
        if let storedEnabled = defaults.object(forKey: Self.phraseRedactionEnabledDefaultsKey) as? Bool {
            return storedEnabled
        }

        // Preserve legacy behavior for installs created before the explicit toggle existed.
        return hasStoredPhrases
    }

    private static func normalizedRedactionPhrases(_ phrases: [String]) -> [NormalizedPhraseRedactionPhrase] {
        var unique: Set<String> = []
        var ordered: [NormalizedPhraseRedactionPhrase] = []
        ordered.reserveCapacity(phrases.count)

        for phrase in phrases {
            let normalized = normalizePhraseRedactionText(phrase)
            let compact = compactPhraseRedactionText(normalized)
            guard !normalized.isEmpty, !compact.isEmpty else { continue }
            guard unique.insert(compact).inserted else { continue }
            ordered.append(
                NormalizedPhraseRedactionPhrase(
                    normalizedText: normalized,
                    compactText: compact,
                    tokenCount: phraseRedactionTokens(from: normalized).count
                )
            )
        }

        return ordered
    }

    private static func redactedCombinedNodeOrders(
        in regions: [TextRegion],
        offset: Int,
        phrases: [NormalizedPhraseRedactionPhrase],
        allowApproximateMatching: Bool = true
    ) -> Set<Int> {
        let tokenStream = indexedPhraseRedactionTokens(in: regions, offset: offset)
        guard !tokenStream.isEmpty else { return [] }

        var redactedNodeOrders: Set<Int> = []

        for phrase in phrases {
            let maxWindowLength = min(
                tokenStream.count,
                max(1, phrase.tokenCount + phraseRedactionExtraTokenSlack)
            )

            for start in tokenStream.indices {
                let upperBound = min(tokenStream.count, start + maxWindowLength)
                guard upperBound > start else { continue }

                for endExclusive in (start + 1)...upperBound {
                    let candidate = tokenStream[start..<endExclusive]
                    let candidateNodeOrders = Set(candidate.map(\.combinedNodeOrder))
                    guard !candidateNodeOrders.isEmpty else { continue }
                    guard candidateNodeOrders.count <= max(phrase.tokenCount + phraseRedactionExtraTokenSlack, 1) else { continue }
                    guard candidateNodeOrders.count <= phraseRedactionMaxNodeSpan else { continue }

                    if phraseMatchesCandidate(
                        candidate,
                        phrase: phrase,
                        allowApproximateMatching: allowApproximateMatching
                    ) {
                        redactedNodeOrders.formUnion(candidateNodeOrders)
                    }
                }
            }
        }

        return redactedNodeOrders
    }

    private static func indexedPhraseRedactionTokens(
        in regions: [TextRegion],
        offset: Int
    ) -> [IndexedPhraseRedactionToken] {
        var indexedTokens: [IndexedPhraseRedactionToken] = []

        for (index, region) in regions.enumerated() {
            let normalizedText = normalizePhraseRedactionText(region.text)
            let tokens = phraseRedactionTokens(from: normalizedText)
            guard !tokens.isEmpty else { continue }

            let combinedNodeOrder = offset + index
            indexedTokens.append(
                contentsOf: tokens.map {
                    IndexedPhraseRedactionToken(token: $0, combinedNodeOrder: combinedNodeOrder)
                }
            )
        }

        return indexedTokens
    }

    private static func phraseMatchesCandidate(
        _ candidate: ArraySlice<IndexedPhraseRedactionToken>,
        phrase: NormalizedPhraseRedactionPhrase,
        allowApproximateMatching: Bool
    ) -> Bool {
        let candidateTokens = candidate.map(\.token)
        guard !candidateTokens.isEmpty else { return false }

        let candidateNormalized = candidateTokens.joined(separator: " ")
        let candidateCompact = candidateTokens.joined()
        guard !candidateCompact.isEmpty else { return false }

        if candidateNormalized == phrase.normalizedText || candidateCompact == phrase.compactText {
            return true
        }

        let candidateNodeOrders = Set(candidate.map(\.combinedNodeOrder))
        if candidateNodeOrders.count == 1,
           (candidateNormalized.contains(phrase.normalizedText) || candidateCompact.contains(phrase.compactText)) {
            return true
        }

        guard allowApproximateMatching else { return false }

        let maxLength = max(candidateCompact.count, phrase.compactText.count)
        let minLength = min(candidateCompact.count, phrase.compactText.count)
        let maxDistance = maximumPhraseRedactionEditDistance(for: maxLength)
        guard maxLength - minLength <= maxDistance else { return false }

        let distance = levenshteinDistance(candidateCompact, phrase.compactText)
        let similarity = normalizedLevenshteinSimilarity(
            distance: distance,
            lhsLength: candidateCompact.count,
            rhsLength: phrase.compactText.count
        )
        return distance <= maxDistance && similarity >= minimumPhraseRedactionSimilarity(for: maxLength)
    }

    private static func normalizePhraseRedactionText(_ text: String) -> String {
        normalizeInPageText(text)
    }

    private static func phraseRedactionTokens(from normalizedText: String) -> [String] {
        normalizedText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func compactPhraseRedactionText(_ normalizedText: String) -> String {
        normalizedText.replacingOccurrences(of: " ", with: "")
    }

    private static func minimumPhraseRedactionSimilarity(for length: Int) -> Double {
        switch length {
        case ...3:
            return 1.0
        case 4...5:
            return 0.80
        case 6...8:
            return 0.75
        case 9...12:
            return 0.72
        default:
            return 0.70
        }
    }

    private static func maximumPhraseRedactionEditDistance(for length: Int) -> Int {
        switch length {
        case ...3:
            return 0
        case 4...6:
            return 1
        case 7...12:
            return 2
        default:
            return 3
        }
    }

    private static func normalizedLevenshteinSimilarity(
        distance: Int,
        lhsLength: Int,
        rhsLength: Int
    ) -> Double {
        let scale = max(lhsLength, rhsLength)
        guard scale > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(scale))
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)

        var previousRow = Array(0...rhsCharacters.count)
        var currentRow = Array(repeating: 0, count: rhsCharacters.count + 1)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            currentRow[0] = lhsIndex + 1

            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let substitutionCost = lhsCharacter == rhsCharacter ? 0 : 1
                currentRow[rhsIndex + 1] = min(
                    min(previousRow[rhsIndex + 1] + 1, currentRow[rhsIndex] + 1),
                    previousRow[rhsIndex] + substitutionCost
                )
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[rhsCharacters.count]
    }

    private static func maskedTextPreservingLength(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return String(repeating: " ", count: text.count)
    }

    public func processPendingRewrites(
        for videoDatabaseID: Int64,
        includeInProgressJobs: Bool = false,
        includeRetryableFailures: Bool = false,
        isAutomaticRetryOfFailedRewrite: Bool = false
    ) async throws -> PendingRewriteDispatchOutcome {
        if isRewriteSchedulingSuspended {
            Log.debug(
                "[Queue-Rewrite] Deferring segment rewrite for video \(videoDatabaseID) while timeline interaction is active",
                category: .processing
            )
            return .deferred(.timelineInteraction)
        }

        guard let plan = try await databaseManager.buildVideoRewritePlan(
            videoID: videoDatabaseID,
            includeInProgressJobs: includeInProgressJobs,
            includeRetryableFailures: includeRetryableFailures
        ), plan.hasAnyRewrite else {
            return .noPendingWork
        }

        if try await databaseManager.videoHasFramesAwaitingOCR(videoID: videoDatabaseID) {
            let pendingFrameCount = plan.deletions.count + plan.redactions.count
            Log.debug(
                "[Queue-Rewrite] Deferring rewrite for video \(videoDatabaseID) until OCR quiesces; pendingRewriteFrames=\(pendingFrameCount), purpose=\(rewritePurposeSummary(for: plan))",
                category: .processing
            )
            return .deferred(.pendingOCR)
        }

        guard !activeRewriteVideoIDs.contains(videoDatabaseID) else {
            rewriteVideosNeedingRedrain.insert(videoDatabaseID)
            Log.debug(
                "[Queue-Rewrite] Deferring rewrite for video \(videoDatabaseID) because another rewrite is active; scheduling a follow-up drain",
                category: .processing
            )
            return .deferred(.rewriteAlreadyInProgress)
        }
        activeRewriteVideoIDs.insert(videoDatabaseID)
        defer {
            activeRewriteVideoIDs.remove(videoDatabaseID)
            schedulePendingRewriteRedrainIfNeeded(for: videoDatabaseID)
        }

        guard try await databaseManager.isVideoFinalized(videoID: videoDatabaseID) else {
            Log.debug(
                "[Queue-Rewrite] Deferring rewrite for video \(videoDatabaseID) until finalization completes",
                category: .processing
            )
            return .deferred(.videoNotFinalized)
        }

        guard let videoSegment = try await databaseManager.getVideoSegment(
            id: VideoSegmentID(value: videoDatabaseID)
        ) else {
            return .deferred(.videoRecordUnavailable)
        }

        let actualSegmentID = try parseActualSegmentID(from: videoSegment.relativePath)
        let secret = ReversibleOCRScrambler.currentAppWideSecret()
        let executablePlan: VideoRewritePlan

        if plan.hasRedactionTargets && secret == nil {
            if plan.hasDeletionTargets {
                executablePlan = plan.droppingRedactions()
                Log.warning(
                    "[Queue-Rewrite] Running deletion-only rewrite for video \(videoDatabaseID) because no master key exists for pending redactions",
                    category: .processing
                )
            } else {
                try await databaseManager.resetVideoRewritePlanToPending(plan)
                Log.warning(
                    "[Queue-Rewrite] Deferring rewrite for video \(videoDatabaseID) because no master key exists for redaction work",
                    category: .processing
                )
                return .deferred(.missingMasterKey)
            }
        } else {
            executablePlan = plan
        }

        if isAutomaticRetryOfFailedRewrite {
            exhaustedAutomaticRewriteRetryVideoIDs.insert(videoDatabaseID)
        }

        var rewriteCommitted = false
        do {
            try await markVideoRewritePlanStatus(
                executablePlan,
                status: .rewriteProcessing
            )

            try await storage.applySegmentRewrite(
                segmentID: actualSegmentID,
                plan: executablePlan.segmentRewritePlan,
                secret: secret
            )
            rewriteCommitted = true
            try await databaseManager.finalizeVideoRewrite(executablePlan)
            totalRewritten += executablePlan.deletions.count + executablePlan.redactions.count

            do {
                try await storage.finishInterruptedSegmentRewriteRecovery(segmentID: actualSegmentID)
            } catch {
                Log.warning(
                    "[Queue-Rewrite] Completed rewrite for video \(videoDatabaseID) but failed to remove rewrite artifacts for segment \(actualSegmentID.value): \(error.localizedDescription)",
                    category: .processing
                )
            }

            await recordRewriteOutcomeBestEffort(plan: executablePlan, outcome: "success")
            exhaustedAutomaticRewriteRetryVideoIDs.remove(videoDatabaseID)
            Log.info(
                "[Queue-Rewrite] Completed segment rewrite for video \(videoDatabaseID), purpose=\(rewritePurposeSummary(for: executablePlan)), frames=\(executablePlan.deletions.count + executablePlan.redactions.count)",
                category: .processing
            )
            return .completed
        } catch {
            if rewriteCommitted {
                await recordRewriteOutcomeBestEffort(plan: executablePlan, outcome: "db_finalize_failed")
                Log.error(
                    "[Queue-Rewrite] Segment rewrite for video \(videoDatabaseID) committed to disk but DB completion failed; leaving rewrite artifacts for startup reconciliation: \(error.localizedDescription)",
                    category: .processing
                )
            } else {
                try? await markVideoRewritePlanStatus(
                    executablePlan,
                    status: .rewriteFailed
                )
                await recordRewriteOutcomeBestEffort(plan: executablePlan, outcome: "file_mutation_failed")
                if !exhaustedAutomaticRewriteRetryVideoIDs.contains(videoDatabaseID) {
                    scheduleRetryableRewriteRetry(trigger: "rewrite-failed:\(videoDatabaseID)")
                }
            }
            let failureSummary = rewriteCommitted
                ? "segment bytes are committed; rewrite artifacts retained for startup reconciliation"
                : exhaustedAutomaticRewriteRetryVideoIDs.contains(videoDatabaseID)
                    ? "marked jobs failed after exhausting the one automatic retry"
                    : "marked jobs retryable-failed"
            Log.error(
                "[Queue-Rewrite] Failed segment rewrite for video \(videoDatabaseID); \(failureSummary): \(error.localizedDescription), purpose=\(rewritePurposeSummary(for: executablePlan))",
                category: .processing
            )
            throw error
        }
    }

    private func recoverPendingRewritesOnStartup() async {
        _ = await performStartupRewriteRecoveryIfPending(trigger: "startup-manual")
    }

    public func recoverPendingRewritesIfPossible() async {
        if await performStartupRewriteRecoveryIfPending(trigger: "manual-request") {
            return
        }

        await drainPendingRewritesIfPossible(
            includeInProgressJobs: true,
            includeRetryableFailures: true,
            trigger: "manual-request"
        )
    }

    private func reconcileInterruptedSegmentRewritesOnStartup() async {
        do {
            let actions = try await storage.recoverInterruptedSegmentRewrites()
            guard !actions.isEmpty else { return }

            Log.warning(
                "[Queue-Rewrite] Startup reconciliation found \(actions.count) interrupted rewrite artifact set(s)",
                category: .processing
            )

            let pendingVideoIDs = try await databaseManager.getVideoIDsWithPendingRewrites(
                includeRetryableFailures: true
            )
            var videoIDBySegmentID: [Int64: Int64] = [:]
            for videoID in pendingVideoIDs {
                guard let videoSegment = try await databaseManager.getVideoSegment(
                    id: VideoSegmentID(value: videoID)
                ) else {
                    continue
                }
                guard let actualSegmentID = try? parseActualSegmentID(from: videoSegment.relativePath) else {
                    continue
                }
                videoIDBySegmentID[actualSegmentID.value] = videoID
            }

            for action in actions {
                guard let videoID = videoIDBySegmentID[action.segmentID.value],
                      let plan = try await databaseManager.buildVideoRewritePlan(
                        videoID: videoID,
                        includeInProgressJobs: true,
                        includeRetryableFailures: true
                      ) else {
                    do {
                        try await storage.finishInterruptedSegmentRewriteRecovery(segmentID: action.segmentID)
                    } catch {
                        Log.error(
                            "[Queue-Rewrite] Failed to clean stale interrupted rewrite artifacts for segment \(action.segmentID.value): \(error.localizedDescription)",
                            category: .processing
                        )
                    }
                    continue
                }

                do {
                    switch action.mode {
                    case .rollbackToPending:
                        try await databaseManager.resetVideoRewritePlanToPending(plan)
                    case .finalizeCommitted:
                        try await databaseManager.finalizeVideoRewrite(plan)
                    }
                } catch {
                    Log.error(
                        "[Queue-Rewrite] Failed to persist startup rewrite reconciliation for segment \(action.segmentID.value): \(error.localizedDescription)",
                        category: .processing
                    )
                    continue
                }

                do {
                    try await storage.finishInterruptedSegmentRewriteRecovery(segmentID: action.segmentID)
                } catch {
                    Log.error(
                        "[Queue-Rewrite] Failed to clean interrupted rewrite artifacts for segment \(action.segmentID.value): \(error.localizedDescription)",
                        category: .processing
                    )
                }
            }
        } catch {
            Log.error(
                "[Queue-Rewrite] Failed to reconcile interrupted rewrite artifacts on startup: \(error.localizedDescription)",
                category: .processing
            )
        }
    }

    private func markVideoRewritePlanStatus(
        _ plan: VideoRewritePlan,
        status: FrameProcessingStatus
    ) async throws {
        for deletion in plan.deletions {
            try await updateFrameProcessingStatus(
                deletion.frameID,
                status: status,
                rewritePurpose: "deletion"
            )
        }

        for redaction in plan.redactions {
            try await updateFrameProcessingStatus(
                redaction.frameID,
                status: status,
                rewritePurpose: "redaction"
            )
        }
    }

    private func rewritePurposeSummary(for plan: VideoRewritePlan) -> String {
        if plan.hasDeletionTargets && plan.hasRedactionTargets {
            return "mixed"
        }
        if plan.hasDeletionTargets {
            return "deletion"
        }
        return "redaction"
    }

    private func recordRewriteOutcomeBestEffort(
        plan: VideoRewritePlan,
        outcome: String
    ) async {
        let frameCount = plan.deletions.count + plan.redactions.count
        let metadata = """
            {"purpose":"\(rewritePurposeSummary(for: plan))","outcome":"\(outcome)","frameCount":\(frameCount),"videoCount":1}
            """
        do {
            try await databaseManager.recordMetricEvent(
                metricType: .videoRewriteOutcome,
                metadata: metadata
            )
        } catch {
            Log.warning(
                "[Queue-Rewrite] Failed to record rewrite metric for video \(plan.videoID): \(error.localizedDescription)",
                category: .processing
            )
        }
    }

    // MARK: - Status Management

    /// Update frame processing status
    private func updateFrameProcessingStatus(
        _ frameID: Int64,
        status: FrameProcessingStatus,
        rewritePurpose: String? = nil
    ) async throws {
        try await databaseManager.updateFrameProcessingStatus(
            frameID: frameID,
            status: status.rawValue,
            rewritePurpose: rewritePurpose
        )
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
        var ocrPending = ocrPendingCount
        var ocrProcessing = ocrProcessingCount
        var rewritePending = rewritePendingCount
        var rewriteProcessing = rewriteProcessingCount
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            ocrPending = counts.ocrPending
            ocrProcessing = counts.ocrProcessing
            rewritePending = counts.rewritePending
            rewriteProcessing = counts.rewriteProcessing
        }

        return QueueStatistics(
            ocrQueueDepth: ocrPending + ocrProcessing,
            ocrPendingCount: ocrPending,
            ocrProcessingCount: ocrProcessing,
            rewriteQueueDepth: rewritePending + rewriteProcessing,
            rewritePendingCount: rewritePending,
            rewriteProcessingCount: rewriteProcessing,
            totalProcessed: totalProcessed,
            totalRewritten: totalRewritten,
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
        let processSnapshot = ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()
        MemoryLedger.setProcessSnapshot(
            footprintBytes: processSnapshot?.physFootprintBytes,
            residentBytes: processSnapshot?.residentBytes,
            internalBytes: processSnapshot?.internalBytes,
            compressedBytes: processSnapshot?.compressedBytes
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerQueueTag,
            bytes: 0,
            count: counts.ocrDepth,
            unit: "frames",
            function: "processing.ocr",
            kind: "queue-depth",
            note: "count-only"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerWorkersTag,
            bytes: 0,
            count: workers.count,
            unit: "workers",
            function: "processing.ocr",
            kind: "worker-pool",
            note: "count-only"
        )
        MemoryLedger.emitSummary(
            reason: "processing.ocr.memory",
            category: .processing,
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

    private func refreshLiveQueueCounts() async -> (
        ocrPending: Int,
        ocrProcessing: Int,
        rewritePending: Int,
        rewriteProcessing: Int,
        ocrDepth: Int
    ) {
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            ocrPendingCount = counts.ocrPending
            ocrProcessingCount = counts.ocrProcessing
            rewritePendingCount = counts.rewritePending
            rewriteProcessingCount = counts.rewriteProcessing
            currentQueueDepth = counts.ocrPending + counts.ocrProcessing
        }
        return (
            ocrPending: ocrPendingCount,
            ocrProcessing: ocrProcessingCount,
            rewritePending: rewritePendingCount,
            rewriteProcessing: rewriteProcessingCount,
            ocrDepth: ocrPendingCount + ocrProcessingCount
        )
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
        let baseMessage = "footprint=\(ProcessingMemoryDiagnostics.formatFootprint(snapshot)) pauseAt=\(ProcessingMemoryDiagnostics.formatBytes(policy.pauseThresholdBytes)) resumeBelow=\(ProcessingMemoryDiagnostics.formatBytes(policy.resumeThresholdBytes)) ocrQueueDepth=\(counts.ocrDepth) ocrPending=\(counts.ocrPending) ocrProcessing=\(counts.ocrProcessing) rewritePending=\(counts.rewritePending) rewriteProcessing=\(counts.rewriteProcessing)"

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
            ? false
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
    public let retryableRewriteRetryDelayNs: UInt64

    public init(
        workerCount: Int = 1,
        maxRetryAttempts: Int = 3,
        maxQueueSize: Int = 1000,
        retryableRewriteRetryDelayNs: UInt64 = 5_000_000_000
    ) {
        self.workerCount = workerCount
        self.maxRetryAttempts = maxRetryAttempts
        self.maxQueueSize = maxQueueSize
        self.retryableRewriteRetryDelayNs = retryableRewriteRetryDelayNs
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
    // 4 is reserved for "not yet readable" (set by frame insert path)
    case rewritePending = 5
    case rewriteProcessing = 6
    case rewriteCompleted = 7
    case rewriteFailed = 8
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
    public let ocrQueueDepth: Int
    public let ocrPendingCount: Int
    public let ocrProcessingCount: Int
    public let rewriteQueueDepth: Int
    public let rewritePendingCount: Int
    public let rewriteProcessingCount: Int
    public let totalProcessed: Int
    public let totalRewritten: Int
    public let totalFailed: Int
    public let workerCount: Int
}
