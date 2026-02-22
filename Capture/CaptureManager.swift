import Foundation
import CoreGraphics
import Shared

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {

    // MARK: - Properties

    private let cgWindowListCapture: CGWindowListCapture
    private let displayMonitor: DisplayMonitor
    private let displaySwitchMonitor: DisplaySwitchMonitor
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: AppInfoProvider

    private var currentConfig: CaptureConfig
    private var lastKeptFrame: CapturedFrame?
    private var _isCapturing: Bool = false

    // Frame stream management
    private var rawFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?

    // Statistics
    private var stats = CaptureStatistics(
        totalFramesCaptured: 0,
        framesDeduped: 0,
        averageFrameSizeBytes: 0,
        captureStartTime: nil,
        lastFrameTime: nil
    )

    // Permission warnings
    private var hasShownAccessibilityWarning = false

    // Window change debouncing and title tracking
    private var lastWindowChangeCaptureTime: Date?
    private var lastNormalizedTitle: String?
    private var lastBundleID: String?
    private var windowChangeCaptureTask: Task<Void, Never>?
    private let windowChangeSettleDelayMilliseconds = 120
    private let windowChangeSettlePollMilliseconds = 40
    private let windowChangeSettleTimeoutSeconds: TimeInterval = 0.45
    private var deferredDisplaySyncTask: Task<Void, Never>?
    private var currentCaptureDisplayID: UInt32?
    private var isDisplaySwitchInFlight = false

    /// Callback for accessibility permission warnings
    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?

    /// Callback when capture stops unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?

    // MARK: - Initialization

    public init(config: CaptureConfig = .default) {
        self.currentConfig = config
        self.cgWindowListCapture = CGWindowListCapture()
        self.displayMonitor = DisplayMonitor()
        self.displaySwitchMonitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = AppInfoProvider()
    }

    // MARK: - CaptureProtocol - Lifecycle

    public func hasPermission() async -> Bool {
        await PermissionChecker.hasScreenRecordingPermission()
    }

    public func requestPermission() async -> Bool {
        await PermissionChecker.requestPermission()
    }

    public func startCapture(config: CaptureConfig) async throws {
        guard !_isCapturing else { return }

        // Check permission first
        guard await hasPermission() else {
            throw CaptureError.permissionDenied
        }

        self.currentConfig = config

        // Create raw frame stream
        let (rawStream, rawContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.rawFrameContinuation = rawContinuation

        // Create deduped frame stream for consumers
        let (dedupedStream, dedupedContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.dedupedFrameContinuation = dedupedContinuation
        self._frameStream = dedupedStream

        // Get the active display (the one containing the focused window)
        let activeDisplayID = await displayMonitor.getActiveDisplayID()
        currentCaptureDisplayID = activeDisplayID

        // Start CGWindowList capture on the active display
        try await cgWindowListCapture.startCapture(
            config: config,
            frameContinuation: rawContinuation,
            displayID: activeDisplayID
        )

        _isCapturing = true
        stats = CaptureStatistics(
            totalFramesCaptured: 0,
            framesDeduped: 0,
            averageFrameSizeBytes: 0,
            captureStartTime: Date(),
            lastFrameTime: nil
        )

        // Start monitoring for display switches
        let initialDisplayID = await displayMonitor.getActiveDisplayID()
        await startDisplaySwitchMonitoring(initialDisplayID: initialDisplayID)

        // Process raw frames with deduplication
        Task {
            await processFrameStream(rawStream: rawStream)
        }
    }

    public func stopCapture() async throws {
        guard _isCapturing else { return }

        // Stop display switch monitoring
        await displaySwitchMonitor.stopMonitoring()

        // Stop capture
        try await cgWindowListCapture.stopCapture()

        _isCapturing = false
        rawFrameContinuation?.finish()
        dedupedFrameContinuation?.finish()
        rawFrameContinuation = nil
        dedupedFrameContinuation = nil
        windowChangeCaptureTask?.cancel()
        windowChangeCaptureTask = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        lastKeptFrame = nil
        hasShownAccessibilityWarning = false
        currentCaptureDisplayID = nil
        isDisplaySwitchInFlight = false
    }

    public var isCapturing: Bool {
        _isCapturing
    }

    // MARK: - CaptureProtocol - Frame Stream

    public var frameStream: AsyncStream<CapturedFrame> {
        if let stream = _frameStream {
            return stream
        }

        // Create new stream if none exists
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        self.dedupedFrameContinuation = continuation
        self._frameStream = stream
        return stream
    }

    // MARK: - CaptureProtocol - Configuration

    public func updateConfig(_ config: CaptureConfig) async throws {
        self.currentConfig = config

        if _isCapturing {
            try await cgWindowListCapture.updateConfig(config)
        }
    }

    public func getConfig() async -> CaptureConfig {
        currentConfig
    }

    // MARK: - CaptureProtocol - Display Info

    public func getAvailableDisplays() async throws -> [DisplayInfo] {
        try await displayMonitor.getAvailableDisplays()
    }

    public func getFocusedDisplay() async throws -> DisplayInfo? {
        try await displayMonitor.getFocusedDisplay()
    }

    // MARK: - Statistics

    /// Get current capture statistics
    public func getStatistics() -> CaptureStatistics {
        stats
    }

    // MARK: - Private Helpers - Display Switching

    /// Start monitoring for display switches
    private func startDisplaySwitchMonitoring(initialDisplayID: UInt32) async {
        // Set up display switch callback
        displaySwitchMonitor.onDisplaySwitch = { oldDisplayID, newDisplayID in
            await self.handleDisplaySwitch(from: oldDisplayID, to: newDisplayID)
        }

        // Set up accessibility permission warning callback
        displaySwitchMonitor.onAccessibilityPermissionDenied = {
            await self.handleAccessibilityPermissionDenied()
        }

        // Set up window change callback for immediate capture
        displaySwitchMonitor.onWindowChange = { [weak self] in
            await self?.handleWindowChangeCoalesced()
        }

        await displaySwitchMonitor.startMonitoring(initialDisplayID: initialDisplayID)
    }

    /// Coalesce duplicate window-change events while a capture refresh is in flight.
    private func handleWindowChangeCoalesced() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        if let task = windowChangeCaptureTask {
            await task.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleWindowChange()
        }
        windowChangeCaptureTask = task
        await task.value
        windowChangeCaptureTask = nil
    }

    /// Handle window change - capture immediately and reset timer if enabled
    private func handleWindowChange() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        // Keyboard-driven monitor moves can race with display-change notifications.
        // Reconcile active display before capture so we don't keep polling a stale display.
        await syncCaptureDisplayIfNeeded()

        // Wait briefly for app/window activation to settle so we capture the new window,
        // not a compositor transition frame.
        let initialMetadata = await appInfoProvider.getFrontmostAppInfo(includeBrowserURL: false)
        let currentMetadata = await waitForSettledWindowMetadata(initialMetadata: initialMetadata)
        let currentTitle = currentMetadata.windowName ?? ""
        let currentBundleID = currentMetadata.appBundleID ?? ""

        // Check if this is a meaningful title change
        // Skip if titles are related (one contains the other) - handles "Messenger" vs "Messenger (1)"
        if let lastTitle = lastNormalizedTitle,
           let lastBundle = lastBundleID,
           lastBundle == currentBundleID {  // Same app
            let titlesRelated = lastTitle.contains(currentTitle) || currentTitle.contains(lastTitle)
            if titlesRelated && !lastTitle.isEmpty && !currentTitle.isEmpty {
                // Titles are related, skip capture - let regular timer handle it
                // Log.debug("[CaptureManager] Window title change skipped (related titles): '\(lastTitle)' -> '\(currentTitle)'", category: .capture)
                return
            }
        }

        // Debounce: minimum 200ms between window-change captures
        if let lastTime = lastWindowChangeCaptureTime,
           Date().timeIntervalSince(lastTime) < 0.2 {
            return
        }
        lastWindowChangeCaptureTime = Date()

        // Update tracked title/bundle
        lastNormalizedTitle = currentTitle
        lastBundleID = currentBundleID

        // Trigger immediate capture and reset timer
        await cgWindowListCapture.captureImmediateAndResetTimer()
        await syncCaptureDisplayIfNeeded()
        scheduleDisplaySyncCheck()
    }

    /// Handle display switch by restarting capture on the new display
    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        // Notify listeners that display switched (used by TimelineWindowController to reposition window)
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
        guard !isDisplaySwitchInFlight else { return }

        isDisplaySwitchInFlight = true
        defer { isDisplaySwitchInFlight = false }

        do {
            // Recreate raw frame continuation with same stream
            guard let continuation = rawFrameContinuation else { return }

            // Stop current capture
            try await cgWindowListCapture.stopCapture()

            // Start capture on new display
            try await cgWindowListCapture.startCapture(
                config: currentConfig,
                frameContinuation: continuation,
                displayID: newDisplayID
            )
            currentCaptureDisplayID = newDisplayID
        } catch {
            Log.error("Failed to switch displays: \(error.localizedDescription)", category: .capture)
        }
    }

    /// Handle accessibility permission denial
    private func handleAccessibilityPermissionDenied() async {
        // Only show warning once per session
        guard !hasShownAccessibilityWarning else { return }
        hasShownAccessibilityWarning = true

        // logger.warning("Accessibility permission denied - display switching disabled")

        // Notify UI layer
        onAccessibilityPermissionWarning?()
    }

    /// Handle stream stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleStreamStopped() async {
        guard _isCapturing else { return }

        Log.info("Screen capture stream stopped unexpectedly", category: .capture)

        // Reset capture state
        _isCapturing = false
        rawFrameContinuation?.finish()
        dedupedFrameContinuation?.finish()
        rawFrameContinuation = nil
        dedupedFrameContinuation = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        lastKeptFrame = nil
        hasShownAccessibilityWarning = false
        currentCaptureDisplayID = nil
        isDisplaySwitchInFlight = false

        // Stop display switch monitoring
        await displaySwitchMonitor.stopMonitoring()

        // Notify listeners
        if let callback = onCaptureStopped {
            await callback()
        }
    }

    // MARK: - Private Helpers - Frame Processing

    /// Process the raw frame stream with deduplication and metadata enrichment
    private func processFrameStream(rawStream: AsyncStream<CapturedFrame>) async {
        var totalBytes: Int64 = 0
        var totalFrames = 0

        for await var frame in rawStream {
            totalFrames += 1
            totalBytes += Int64(frame.imageData.count)

            // Enrich with app metadata (if we can get it on main actor)
            frame = await enrichFrameMetadata(frame)

            // Apply deduplication if enabled
            if currentConfig.adaptiveCaptureEnabled {
                let similarity = lastKeptFrame != nil ? deduplicator.computeSimilarity(frame, lastKeptFrame!) : 0.0
                let shouldKeep = deduplicator.shouldKeepFrame(
                    frame,
                    comparedTo: lastKeptFrame,
                    threshold: currentConfig.deduplicationThreshold
                )

                if shouldKeep {
                    lastKeptFrame = frame
                    dedupedFrameContinuation?.yield(frame)

                    // Update stats
                    stats = CaptureStatistics(
                        totalFramesCaptured: totalFrames,
                        framesDeduped: stats.framesDeduped,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime,
                        lastFrameTime: frame.timestamp
                    )

                    Log.verbose("Frame kept (similarity: \(String(format: "%.2f%%", similarity * 100)))", category: .capture)
                } else {
                    // Frame was filtered out
                    stats = CaptureStatistics(
                        totalFramesCaptured: totalFrames,
                        framesDeduped: stats.framesDeduped + 1,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime,
                        lastFrameTime: stats.lastFrameTime
                    )

                    Log.info("Frame deduplicated (similarity: \(String(format: "%.2f%%", similarity * 100)), threshold: \(String(format: "%.2f%%", currentConfig.deduplicationThreshold * 100)))", category: .capture)
                }
            } else {
                // No deduplication - pass through all frames
                dedupedFrameContinuation?.yield(frame)

                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: 0,
                    averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: frame.timestamp
                )
            }
        }

        // Stream ended
        dedupedFrameContinuation?.finish()
    }

    /// Enrich frame with app metadata
    private func enrichFrameMetadata(_ frame: CapturedFrame) async -> CapturedFrame {
        // Get app info in a single metadata fetch.
        let metadata = await appInfoProvider.getFrontmostAppInfo(includeBrowserURL: true)

        // Create new frame with enriched metadata
        return CapturedFrame(
            timestamp: frame.timestamp,
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: metadata
        )
    }

    /// Compare active display vs capture display and force a switch when they drift apart.
    private func syncCaptureDisplayIfNeeded() async {
        guard _isCapturing else { return }
        guard !isDisplaySwitchInFlight else { return }

        let (activeDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard hasAXPermission else { return }

        guard let captureDisplayID = currentCaptureDisplayID else {
            currentCaptureDisplayID = activeDisplayID
            return
        }

        guard activeDisplayID != captureDisplayID else { return }
        await handleDisplaySwitch(from: captureDisplayID, to: activeDisplayID)
    }

    /// Schedule one delayed drift check to catch async display updates after keyboard window moves.
    private func scheduleDisplaySyncCheck(delayMilliseconds: UInt64 = 300) {
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delayMilliseconds)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.syncCaptureDisplayIfNeeded()
        }
    }

    /// Sample frontmost app/window until it stabilizes or timeout is reached.
    private func waitForSettledWindowMetadata(initialMetadata: FrameMetadata) async -> FrameMetadata {
        var latestMetadata = initialMetadata
        var lastIdentity = windowIdentity(from: initialMetadata)
        let deadline = Date().addingTimeInterval(windowChangeSettleTimeoutSeconds)

        try? await Task.sleep(for: .milliseconds(windowChangeSettleDelayMilliseconds), clock: .continuous)

        while Date() < deadline {
            guard !Task.isCancelled else { return latestMetadata }

            let nextMetadata = await appInfoProvider.getFrontmostAppInfo(includeBrowserURL: false)
            let nextIdentity = windowIdentity(from: nextMetadata)

            latestMetadata = nextMetadata
            if nextIdentity == lastIdentity {
                break
            }
            lastIdentity = nextIdentity

            try? await Task.sleep(for: .milliseconds(windowChangeSettlePollMilliseconds), clock: .continuous)
        }

        return latestMetadata
    }

    private func windowIdentity(from metadata: FrameMetadata) -> (bundleID: String, windowName: String) {
        (metadata.appBundleID ?? "", metadata.windowName ?? "")
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when the active display changes (user switched to app on different monitor)
    static let activeDisplayDidChange = Notification.Name("activeDisplayDidChange")
}
