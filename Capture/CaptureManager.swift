import Foundation
import CoreGraphics
import Shared

protocol ScreenCaptureBackend: Actor {
    func startCapture(config: CaptureConfig, displayID: CGDirectDisplayID?) async throws
    func stopCapture() async throws
    func updateConfig(_ config: CaptureConfig) async throws
    func captureFrame(displayID: CGDirectDisplayID) async -> CapturedFrame?
}

protocol CaptureDisplayMonitoring: Actor {
    func getAvailableDisplays() async throws -> [DisplayInfo]
    func getFocusedDisplay() async throws -> DisplayInfo?
    func getActiveDisplayID() -> UInt32
    func getActiveDisplayIDWithPermissionStatus() -> (UInt32, Bool)
}

protocol CaptureDisplaySwitchMonitoring: Actor {
    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?)
    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?)
    func setOnWindowChange(_ callback: (@Sendable () async -> Void)?)
    func startMonitoring(initialDisplayID: UInt32)
    func stopMonitoring() async
}

protocol CaptureMouseClickMonitoring: Actor {
    func setOnLeftMouseUp(_ callback: (@Sendable () async -> Void)?)
    func startMonitoring() async -> Bool
    func stopMonitoring() async
}

protocol CaptureAppInfoProviding: Sendable {
    func getFrontmostAppInfo(
        includeBrowserURL: Bool,
        preferredDisplayID: CGDirectDisplayID?
    ) async -> FrameMetadata
}

struct CaptureSchedulingConfiguration: Sendable {
    let minimumInterCaptureInterval: TimeInterval
    let mouseClickSettleDelay: TimeInterval
    let windowChangeSettleDelay: TimeInterval
    let startWithImmediateIntervalCapture: Bool

    static let production = CaptureSchedulingConfiguration(
        minimumInterCaptureInterval: 0.3,
        mouseClickSettleDelay: 0.06,
        windowChangeSettleDelay: 0.1,
        startWithImmediateIntervalCapture: true
    )
}

public enum MouseClickCaptureOutcome: String, Sendable {
    case captured
    case debounced
    case superseded
    case monitorUnavailable = "monitor_unavailable"
    case deduped
}

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {
    private static let automaticTriggerConfigurationErrorReason =
        "At least one automatic capture trigger must be enabled."

    private enum CaptureTrigger: Sendable, Equatable {
        case mouseClick
        case windowChange
        case interval

        var priority: Int {
            switch self {
            case .mouseClick: return 3
            case .windowChange: return 2
            case .interval: return 1
            }
        }

        func settleDelay(using configuration: CaptureSchedulingConfiguration) -> TimeInterval {
            switch self {
            case .mouseClick:
                return configuration.mouseClickSettleDelay
            case .windowChange:
                return configuration.windowChangeSettleDelay
            case .interval:
                return 0
            }
        }

    }

    private struct PendingCapture: Sendable {
        let trigger: CaptureTrigger
        let fireTime: Date
    }

    private let cgWindowListCapture: any ScreenCaptureBackend
    private let displayMonitor: any CaptureDisplayMonitoring
    private let displaySwitchMonitor: any CaptureDisplaySwitchMonitoring
    private let mouseClickMonitor: any CaptureMouseClickMonitoring
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: any CaptureAppInfoProviding
    private let schedulingConfiguration: CaptureSchedulingConfiguration
    private let now: @Sendable () -> Date

    private var currentConfig: CaptureConfig
    private var lastKeptFrame: CapturedFrame?
    private var lastKeptMousePosition: CGPoint?
    private var _isCapturing = false

    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?

    private var stats = CaptureStatistics(
        totalFramesCaptured: 0,
        framesDeduped: 0,
        averageFrameSizeBytes: 0,
        captureStartTime: nil,
        lastFrameTime: nil
    )
    private var totalCapturedBytes: Int64 = 0

    private var hasShownAccessibilityWarning = false
    private var hasReportedMouseMonitorUnavailable = false
    private var mouseClickMonitoringNeedsRetry = false

    private var lastNormalizedTitle: String?
    private var lastBundleID: String?
    private var windowChangeEvaluationTask: Task<Void, Never>?
    private var deferredDisplaySyncTask: Task<Void, Never>?
    private var scheduledCaptureTask: Task<Void, Never>?
    private var pendingCapture: PendingCapture?
    private var lastActualCaptureTime: Date?
    private var currentCaptureDisplayID: UInt32?
    private var isCaptureExecutionInFlight = false
    private static let dedupedFrameBufferLimit = 8
    private static let memoryLedgerCurrentFrameTag = "capture.stream.currentFrame"
    private static let memoryLedgerLastKeptFrameTag = "capture.dedup.lastKeptFrame"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 5

    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?
    nonisolated(unsafe) public var onMouseClickCaptureOutcome: (@Sendable (MouseClickCaptureOutcome, Date) async -> Void)?

    public init(config: CaptureConfig = .default) {
        let displayMonitor = DisplayMonitor()
        self.currentConfig = config
        self.cgWindowListCapture = CGWindowListCapture()
        self.displayMonitor = displayMonitor
        self.displaySwitchMonitor = DisplaySwitchMonitor(displayMonitor: displayMonitor)
        self.mouseClickMonitor = MouseClickMonitor()
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = AppInfoProvider()
        self.schedulingConfiguration = .production
        self.now = { Date() }
    }

    init(
        config: CaptureConfig,
        cgWindowListCapture: any ScreenCaptureBackend,
        displayMonitor: any CaptureDisplayMonitoring,
        displaySwitchMonitor: any CaptureDisplaySwitchMonitoring,
        mouseClickMonitor: any CaptureMouseClickMonitoring,
        deduplicator: FrameDeduplicator = FrameDeduplicator(),
        appInfoProvider: any CaptureAppInfoProviding = AppInfoProvider(),
        schedulingConfiguration: CaptureSchedulingConfiguration = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.currentConfig = config
        self.cgWindowListCapture = cgWindowListCapture
        self.displayMonitor = displayMonitor
        self.displaySwitchMonitor = displaySwitchMonitor
        self.mouseClickMonitor = mouseClickMonitor
        self.deduplicator = deduplicator
        self.appInfoProvider = appInfoProvider
        self.schedulingConfiguration = schedulingConfiguration
        self.now = now
    }

    public func hasPermission() async -> Bool {
        await PermissionChecker.hasScreenRecordingPermission()
    }

    public func requestPermission() async -> Bool {
        await PermissionChecker.requestPermission()
    }

    public func startCapture(config: CaptureConfig) async throws {
        guard !_isCapturing else { return }
        try validateCaptureConfiguration(config)

        guard await hasPermission() else {
            throw CaptureError.permissionDenied
        }

        self.currentConfig = config

        let (dedupedStream, dedupedContinuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.dedupedFrameBufferLimit)
        )
        self.dedupedFrameContinuation = dedupedContinuation
        self._frameStream = dedupedStream

        let activeDisplayID = await displayMonitor.getActiveDisplayID()
        currentCaptureDisplayID = activeDisplayID

        try await cgWindowListCapture.startCapture(
            config: config,
            displayID: activeDisplayID
        )

        _isCapturing = true
        resetCaptureState()

        await startDisplaySwitchMonitoring(initialDisplayID: activeDisplayID)
        await configureMouseClickMonitoring(enabled: config.captureOnMouseClick)

        if intervalCaptureEnabled(), schedulingConfiguration.startWithImmediateIntervalCapture {
            enqueueCapture(trigger: .interval, requestedAt: now())
        } else if intervalCaptureEnabled() {
            scheduleNextIntervalCapture(from: now())
        }
    }

    public func stopCapture() async throws {
        guard _isCapturing else { return }

        _isCapturing = false

        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil
        windowChangeEvaluationTask?.cancel()
        windowChangeEvaluationTask = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        pendingCapture = nil

        await displaySwitchMonitor.stopMonitoring()
        await mouseClickMonitor.stopMonitoring()
        try await cgWindowListCapture.stopCapture()

        dedupedFrameContinuation?.finish()
        dedupedFrameContinuation = nil
        _frameStream = nil

        lastKeptFrame = nil
        lastKeptMousePosition = nil
        lastNormalizedTitle = nil
        lastBundleID = nil
        updateCaptureMemoryLedger(currentFrameBytes: 0)
        currentCaptureDisplayID = nil
        lastActualCaptureTime = nil
        totalCapturedBytes = 0
        hasShownAccessibilityWarning = false
        hasReportedMouseMonitorUnavailable = false
        isCaptureExecutionInFlight = false
    }

    public var isCapturing: Bool {
        _isCapturing
    }

    public var frameStream: AsyncStream<CapturedFrame> {
        if let stream = _frameStream {
            return stream
        }

        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.dedupedFrameBufferLimit)
        )
        self.dedupedFrameContinuation = continuation
        self._frameStream = stream
        return stream
    }

    public func updateConfig(_ config: CaptureConfig) async throws {
        try await applyConfigUpdate(config)
    }

    public func updateConfig(
        _ transform: @Sendable (CaptureConfig) -> CaptureConfig
    ) async throws {
        try await applyConfigUpdate(transform(currentConfig))
    }

    private func applyConfigUpdate(_ config: CaptureConfig) async throws {
        try validateCaptureConfiguration(config)
        currentConfig = config

        if _isCapturing {
            try await cgWindowListCapture.updateConfig(config)
            await configureMouseClickMonitoring(enabled: config.captureOnMouseClick)
            cancelDisabledPendingRequestIfNeeded()
            scheduleNextIntervalCapture(from: lastActualCaptureTime ?? now())
        }
    }

    public func getConfig() async -> CaptureConfig { currentConfig }

    public func getAvailableDisplays() async throws -> [DisplayInfo] {
        try await displayMonitor.getAvailableDisplays()
    }

    public func getFocusedDisplay() async throws -> DisplayInfo? {
        try await displayMonitor.getFocusedDisplay()
    }

    public func getStatistics() -> CaptureStatistics {
        stats
    }

    private func validateCaptureConfiguration(_ config: CaptureConfig) throws {
        guard config.captureIntervalSeconds > 0 || config.captureOnWindowChange || config.captureOnMouseClick else {
            throw CaptureError.invalidConfiguration(
                reason: Self.automaticTriggerConfigurationErrorReason
            )
        }
    }

    private func resetCaptureState() {
        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil
        pendingCapture = nil
        windowChangeEvaluationTask?.cancel()
        windowChangeEvaluationTask = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        lastKeptFrame = nil
        lastKeptMousePosition = nil
        lastNormalizedTitle = nil
        lastBundleID = nil
        updateCaptureMemoryLedger(currentFrameBytes: 0)
        totalCapturedBytes = 0
        lastActualCaptureTime = nil
        hasShownAccessibilityWarning = false
        hasReportedMouseMonitorUnavailable = false
        mouseClickMonitoringNeedsRetry = false
        isCaptureExecutionInFlight = false
        stats = CaptureStatistics(
            totalFramesCaptured: 0,
            framesDeduped: 0,
            averageFrameSizeBytes: 0,
            captureStartTime: now(),
            lastFrameTime: nil
        )
    }

    private func startDisplaySwitchMonitoring(initialDisplayID: UInt32) async {
        await displaySwitchMonitor.setOnDisplaySwitch { [weak self] oldDisplayID, newDisplayID in
            await self?.handleDisplaySwitch(from: oldDisplayID, to: newDisplayID)
        }
        await displaySwitchMonitor.setOnAccessibilityPermissionDenied { [weak self] in
            await self?.handleAccessibilityPermissionDenied()
        }
        await displaySwitchMonitor.setOnWindowChange { [weak self] in
            await self?.handleWindowChangeCoalesced()
        }
        await displaySwitchMonitor.startMonitoring(initialDisplayID: initialDisplayID)
    }

    private func configureMouseClickMonitoring(enabled: Bool) async {
        if enabled && _isCapturing {
            await mouseClickMonitor.setOnLeftMouseUp { [weak self] in
                await self?.handleMouseClick()
            }
            let hasFullCoverage = await mouseClickMonitor.startMonitoring()
            if hasFullCoverage {
                hasReportedMouseMonitorUnavailable = false
                mouseClickMonitoringNeedsRetry = false
            } else if !hasReportedMouseMonitorUnavailable {
                mouseClickMonitoringNeedsRetry = true
                hasReportedMouseMonitorUnavailable = true
                reportMouseClickOutcome(.monitorUnavailable)
            } else {
                mouseClickMonitoringNeedsRetry = true
            }
        } else {
            await mouseClickMonitor.setOnLeftMouseUp(nil)
            await mouseClickMonitor.stopMonitoring()
            hasReportedMouseMonitorUnavailable = false
            mouseClickMonitoringNeedsRetry = false
        }
    }

    public func retryMouseClickMonitoringIfNeeded() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }
        guard mouseClickMonitoringNeedsRetry else { return }

        await configureMouseClickMonitoring(enabled: true)
    }

    public func suspendMouseClickMonitoringForPermissionLoss() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }

        mouseClickMonitoringNeedsRetry = true
        await mouseClickMonitor.stopMonitoring()
    }

    private func handleMouseClick() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }

        enqueueCapture(trigger: .mouseClick, requestedAt: now())
    }

    private func handleWindowChangeCoalesced() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        if let task = windowChangeEvaluationTask {
            await task.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.evaluateWindowChange()
        }
        windowChangeEvaluationTask = task
        await task.value
        windowChangeEvaluationTask = nil
    }

    private func evaluateWindowChange() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        await syncCaptureDisplayIfNeeded()

        let currentMetadata = await appInfoProvider.getFrontmostAppInfo(
            includeBrowserURL: false,
            preferredDisplayID: nil
        )
        let currentTitle = currentMetadata.windowName ?? ""
        let currentBundleID = currentMetadata.appBundleID ?? ""

        if let lastTitle = lastNormalizedTitle,
           let lastBundle = lastBundleID,
           lastBundle == currentBundleID {
            let titlesRelated = lastTitle.contains(currentTitle) || currentTitle.contains(lastTitle)
            if titlesRelated && !lastTitle.isEmpty && !currentTitle.isEmpty {
                return
            }
        }

        lastNormalizedTitle = currentTitle
        lastBundleID = currentBundleID

        enqueueCapture(trigger: .windowChange, requestedAt: now())
    }

    private func enqueueCapture(trigger: CaptureTrigger, requestedAt: Date) {
        let capture = PendingCapture(
            trigger: trigger,
            fireTime: requestedAt.addingTimeInterval(
                trigger.settleDelay(using: schedulingConfiguration)
            )
        )
        enqueueCapture(capture)
    }

    private func enqueueCapture(
        _ capture: PendingCapture,
        bypassRefractoryDrop: Bool = false
    ) {
        guard _isCapturing else { return }
        guard !shouldDropRequestDuringRefractory(
            capture,
            bypassRefractoryDrop: bypassRefractoryDrop
        ) else {
            if capture.trigger == .mouseClick {
                reportMouseClickOutcome(.debounced)
            }
            return
        }

        if let existing = pendingCapture {
            guard shouldReplacePendingCapture(existing: existing, with: capture) else {
                return
            }

            if existing.trigger == .mouseClick {
                reportMouseClickOutcome(.superseded)
            }
        }

        pendingCapture = capture
        reschedulePendingCaptureTask()
    }

    private func shouldReplacePendingCapture(
        existing: PendingCapture,
        with incoming: PendingCapture
    ) -> Bool {
        if incoming.trigger.priority > existing.trigger.priority {
            return true
        }
        if incoming.trigger.priority < existing.trigger.priority {
            return false
        }
        return incoming.fireTime >= existing.fireTime
    }

    private func reschedulePendingCaptureTask() {
        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil

        guard let capture = pendingCapture else { return }

        scheduledCaptureTask = Task { [weak self] in
            guard let self else { return }

            let delay = capture.fireTime.timeIntervalSince(self.now())
            if delay > 0 {
                try? await Task.sleep(for: Self.sleepDuration(seconds: delay), clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            await self.executePendingCapture()
        }
    }

    private func executePendingCapture() async {
        guard let capture = pendingCapture else { return }
        guard !isCaptureExecutionInFlight else { return }

        pendingCapture = nil
        scheduledCaptureTask = nil
        isCaptureExecutionInFlight = true
        defer {
            isCaptureExecutionInFlight = false
            if _isCapturing {
                reschedulePendingCaptureTask()
            }
        }

        if capture.trigger == .windowChange {
            await syncCaptureDisplayIfNeeded()
        }

        let captureAttemptStartedAt = now()
        let displayID = await displayIDForCapture(trigger: capture.trigger)
        currentCaptureDisplayID = displayID

        let frame = await cgWindowListCapture.captureFrame(displayID: displayID)
        let captureAttemptCompletedAt = now()
        if let frame {
            lastActualCaptureTime = captureAttemptCompletedAt
            await handleCapturedFrame(frame, trigger: capture.trigger)
            scheduleNextIntervalCapture(from: captureAttemptCompletedAt)
        } else {
            scheduleNextIntervalCapture(from: max(captureAttemptStartedAt, captureAttemptCompletedAt))
        }

        if capture.trigger == .windowChange {
            await syncCaptureDisplayIfNeeded()
            scheduleDisplaySyncCheck()
        }
    }

    private func displayIDForCapture(trigger: CaptureTrigger) async -> UInt32 {
        switch trigger {
        case .mouseClick:
            let (activeDisplayID, hasPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
            if hasPermission {
                return activeDisplayID
            }
            if let currentCaptureDisplayID {
                return currentCaptureDisplayID
            }
            return activeDisplayID
        case .windowChange, .interval:
            if let currentCaptureDisplayID {
                return currentCaptureDisplayID
            }
            return await displayMonitor.getActiveDisplayID()
        }
    }

    private func scheduleNextIntervalCapture(from referenceTime: Date) {
        guard _isCapturing else { return }
        guard intervalCaptureEnabled() else { return }

        let capture = PendingCapture(
            trigger: .interval,
            fireTime: referenceTime.addingTimeInterval(currentConfig.captureIntervalSeconds)
        )
        enqueueCapture(capture, bypassRefractoryDrop: true)
    }

    private func shouldDropRequestDuringRefractory(
        _ capture: PendingCapture,
        bypassRefractoryDrop: Bool = false
    ) -> Bool {
        guard bypassRefractoryDrop || !isCaptureExecutionInFlight else {
            return true
        }
        guard let lastActualCaptureTime else {
            return false
        }

        let refractoryEndsAt = lastActualCaptureTime.addingTimeInterval(
            schedulingConfiguration.minimumInterCaptureInterval
        )
        return capture.fireTime < refractoryEndsAt
    }

    private func cancelDisabledPendingRequestIfNeeded() {
        guard let pendingCapture else { return }

        let shouldCancel: Bool
        switch pendingCapture.trigger {
        case .mouseClick:
            shouldCancel = !currentConfig.captureOnMouseClick
        case .windowChange:
            shouldCancel = !currentConfig.captureOnWindowChange
        case .interval:
            shouldCancel = !intervalCaptureEnabled()
        }

        guard shouldCancel else { return }
        self.pendingCapture = nil
        reschedulePendingCaptureTask()
    }

    private func intervalCaptureEnabled() -> Bool {
        currentConfig.captureIntervalSeconds > 0
    }

    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .activeDisplayDidChange,
                object: nil,
                userInfo: ["displayID": newDisplayID]
            )
        }

        guard _isCapturing else { return }
        guard oldDisplayID != newDisplayID else {
            currentCaptureDisplayID = newDisplayID
            return
        }

        currentCaptureDisplayID = newDisplayID
    }

    private func handleAccessibilityPermissionDenied() async {
        guard !hasShownAccessibilityWarning else { return }
        hasShownAccessibilityWarning = true
        onAccessibilityPermissionWarning?()
    }

    private func handleCapturedFrame(
        _ frame: CapturedFrame,
        trigger: CaptureTrigger
    ) async {
        updateCaptureMemoryLedger(currentFrameBytes: Int64(frame.imageData.count))
        defer {
            updateCaptureMemoryLedger(currentFrameBytes: 0)
        }

        let triggerDescription = Self.triggerLogDescription(for: trigger)
        totalCapturedBytes += Int64(frame.imageData.count)
        let totalFrames = stats.totalFramesCaptured + 1
        let currentMousePosition = currentConfig.keepFramesOnMouseMovement
            ? Self.mousePositionWithinCapturedFrame(frame)
            : nil

        if currentConfig.adaptiveCaptureEnabled {
            let similarity = lastKeptFrame != nil ? deduplicator.computeSimilarity(frame, lastKeptFrame!) : 0.0
            let keepBySimilarity = deduplicator.shouldKeepFrame(
                frame,
                comparedTo: lastKeptFrame,
                threshold: currentConfig.deduplicationThreshold
            )
            let keepByMouseMovement = Self.shouldKeepFrameForMouseMovement(
                enabled: currentConfig.keepFramesOnMouseMovement,
                previousMousePosition: lastKeptMousePosition,
                currentMousePosition: currentMousePosition
            )
            let shouldKeep = keepBySimilarity || keepByMouseMovement

            if shouldKeep {
                lastKeptFrame = frame
                lastKeptMousePosition = currentMousePosition
                let enrichedFrame = await enrichFrameMetadata(frame, trigger: trigger)
                dedupedFrameContinuation?.yield(enrichedFrame)

                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: stats.framesDeduped,
                    averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: enrichedFrame.timestamp
                )

                if trigger == .mouseClick {
                    reportMouseClickOutcome(.captured)
                }

                if keepByMouseMovement && !keepBySimilarity {
                    Log.verbose(
                        "Frame kept (trigger: \(triggerDescription), mouse moved, similarity: \(String(format: "%.2f%%", similarity * 100)))",
                        category: .capture
                    )
                } else {
                    Log.verbose(
                        "Frame kept (trigger: \(triggerDescription), similarity: \(String(format: "%.2f%%", similarity * 100)))",
                        category: .capture
                    )
                }
            } else {
                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: stats.framesDeduped + 1,
                    averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: stats.lastFrameTime
                )

                if trigger == .mouseClick {
                    reportMouseClickOutcome(.deduped)
                }

                Log.info(
                    "Frame deduplicated (similarity: \(String(format: "%.2f%%", similarity * 100)), threshold: \(String(format: "%.2f%%", currentConfig.deduplicationThreshold * 100)))",
                    category: .capture
                )
            }
        } else {
            let enrichedFrame = await enrichFrameMetadata(frame, trigger: trigger)
            dedupedFrameContinuation?.yield(enrichedFrame)

            stats = CaptureStatistics(
                totalFramesCaptured: totalFrames,
                framesDeduped: 0,
                averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                captureStartTime: stats.captureStartTime,
                lastFrameTime: enrichedFrame.timestamp
            )
            lastKeptFrame = frame
            lastKeptMousePosition = currentMousePosition

            if trigger == .mouseClick {
                reportMouseClickOutcome(.captured)
            }

            Log.verbose(
                "Frame kept (trigger: \(triggerDescription), deduplication: disabled)",
                category: .capture
            )
        }
    }

    private func reportMouseClickOutcome(_ outcome: MouseClickCaptureOutcome) {
        guard let onMouseClickCaptureOutcome else { return }
        let timestamp = now()
        Task {
            await onMouseClickCaptureOutcome(outcome, timestamp)
        }
    }

    private func updateCaptureMemoryLedger(currentFrameBytes: Int64) {
        let normalizedCurrentFrameBytes = max(0, currentFrameBytes)
        let lastKeptFrameBytes = Int64(lastKeptFrame?.imageData.count ?? 0)

        MemoryLedger.set(
            tag: Self.memoryLedgerCurrentFrameTag,
            bytes: normalizedCurrentFrameBytes,
            count: normalizedCurrentFrameBytes > 0 ? 1 : 0,
            unit: "frames",
            function: "capture.stream",
            kind: "current-frame"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerLastKeptFrameTag,
            bytes: lastKeptFrameBytes,
            count: lastKeptFrame == nil ? 0 : 1,
            unit: "frames",
            function: "capture.deduplication",
            kind: "reference-frame",
            note: "estimated"
        )
        MemoryLedger.emitSummary(
            reason: "capture.stream.memory",
            category: .capture,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    static func shouldKeepFrameForMouseMovement(
        enabled: Bool,
        previousMousePosition: CGPoint?,
        currentMousePosition: CGPoint?,
        minimumMovementPoints: CGFloat = 1.0
    ) -> Bool {
        guard enabled else { return false }

        switch (previousMousePosition, currentMousePosition) {
        case (nil, nil):
            return false
        case (.some, nil), (nil, .some):
            return true
        case let (.some(previous), .some(current)):
            let distance = hypot(current.x - previous.x, current.y - previous.y)
            return distance >= minimumMovementPoints
        }
    }

    private static func triggerLogDescription(for trigger: CaptureTrigger) -> String {
        switch trigger {
        case .mouseClick:
            return "mouse_click"
        case .windowChange:
            return "window_change"
        case .interval:
            return "interval"
        }
    }

    private static func mousePositionWithinCapturedFrame(_ frame: CapturedFrame) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard let event = CGEvent(source: nil) else { return nil }

        let location = event.location
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(frame.metadata.displayID))
        guard displayBounds.width > 0,
              displayBounds.height > 0,
              displayBounds.contains(location) else {
            return nil
        }

        let relativeX = location.x - displayBounds.origin.x
        let relativeY = location.y - displayBounds.origin.y
        let scaleX = CGFloat(frame.width) / displayBounds.width
        let scaleY = CGFloat(frame.height) / displayBounds.height

        let x = relativeX * scaleX
        let y = relativeY * scaleY

        return CGPoint(
            x: min(max(x, 0), CGFloat(frame.width - 1)),
            y: min(max(y, 0), CGFloat(frame.height - 1))
        )
    }

    private func enrichFrameMetadata(
        _ frame: CapturedFrame,
        trigger: CaptureTrigger
    ) async -> CapturedFrame {
        let preferredDisplayID = frame.metadata.displayID == 0 ? nil : frame.metadata.displayID
        let shouldLookupBrowserURL: Bool = {
            guard frame.metadata.redactionReason == nil else { return false }
            guard let capturedBundleID = frame.metadata.appBundleID else { return true }
            return BrowserURLExtractor.isBrowser(capturedBundleID) || capturedBundleID == "com.apple.finder"
        }()
        let frontmostMetadata = await appInfoProvider.getFrontmostAppInfo(
            includeBrowserURL: shouldLookupBrowserURL,
            preferredDisplayID: preferredDisplayID
        )
        let redactionReason = frame.metadata.redactionReason
        let preservedDisplayID = frame.metadata.displayID != 0 ? frame.metadata.displayID : frontmostMetadata.displayID
        let captureTrigger = frame.metadata.captureTrigger ?? Self.storedCaptureTrigger(for: trigger)

        let enrichedMetadata: FrameMetadata
        if redactionReason == nil {
            enrichedMetadata = FrameMetadata(
                appBundleID: frame.metadata.appBundleID ?? frontmostMetadata.appBundleID,
                appName: frame.metadata.appName ?? frontmostMetadata.appName,
                windowName: frame.metadata.windowName ?? frontmostMetadata.windowName,
                browserURL: frame.metadata.browserURL ?? frontmostMetadata.browserURL,
                redactionReason: redactionReason,
                captureTrigger: captureTrigger,
                displayID: preservedDisplayID
            )
        } else {
            enrichedMetadata = FrameMetadata(
                appBundleID: frame.metadata.appBundleID ?? frontmostMetadata.appBundleID,
                appName: frame.metadata.appName ?? frontmostMetadata.appName,
                windowName: nil,
                browserURL: nil,
                redactionReason: redactionReason,
                captureTrigger: captureTrigger,
                displayID: preservedDisplayID
            )
        }

        return CapturedFrame(
            timestamp: frame.timestamp,
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: enrichedMetadata
        )
    }

    private static func storedCaptureTrigger(for trigger: CaptureTrigger) -> FrameCaptureTrigger {
        switch trigger {
        case .mouseClick:
            return .mouse
        case .windowChange:
            return .window
        case .interval:
            return .interval
        }
    }

    private func syncCaptureDisplayIfNeeded() async {
        guard _isCapturing else { return }

        let (activeDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard hasAXPermission else { return }

        guard let captureDisplayID = currentCaptureDisplayID else {
            currentCaptureDisplayID = activeDisplayID
            return
        }

        guard activeDisplayID != captureDisplayID else { return }
        await handleDisplaySwitch(from: captureDisplayID, to: activeDisplayID)
    }

    private func scheduleDisplaySyncCheck(delayMilliseconds: UInt64 = 300) {
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delayMilliseconds)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.syncCaptureDisplayIfNeeded()
        }
    }

    private static func sleepDuration(seconds: TimeInterval) -> Duration {
        let nanoseconds = max(Int64((seconds * 1_000_000_000).rounded()), 0)
        return .nanoseconds(nanoseconds)
    }
}

extension CGWindowListCapture: ScreenCaptureBackend {}

extension DisplayMonitor: CaptureDisplayMonitoring {}

extension DisplaySwitchMonitor: CaptureDisplaySwitchMonitoring {
    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?) {
        onDisplaySwitch = callback
    }

    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?) {
        onAccessibilityPermissionDenied = callback
    }

    func setOnWindowChange(_ callback: (@Sendable () async -> Void)?) {
        onWindowChange = callback
    }
}

extension AppInfoProvider: CaptureAppInfoProviding {}

extension MouseClickMonitor: CaptureMouseClickMonitoring {}

public extension Notification.Name {
    static let activeDisplayDidChange = Notification.Name("activeDisplayDidChange")
}
