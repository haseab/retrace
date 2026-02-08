import Foundation
import CoreGraphics
import AppKit
import Shared

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
/// Supports both single-display (default) and multi-display capture modes
public actor CaptureManager: CaptureProtocol {

    private struct DisplayBoundsInfo {
        let id: UInt32
        let bounds: CGRect
    }

    private struct WindowSnapshot {
        let pid: pid_t
        let ownerName: String
        let windowName: String?
        let bounds: CGRect
    }

    /// Tracks a multi-display capture cycle so all frames in the same cycle share one timestamp.
    private struct MultiDisplayTimestampBatch {
        var canonicalTimestamp: Date
        var firstFrameArrival: Date
        var seenDisplayIDs: Set<UInt32>
    }

    // MARK: - Properties

    /// Single capture instance (used in single-display mode)
    private var singleCapture: CGWindowListCapture?
    /// Multiple capture instances keyed by displayID (used in multi-display mode)
    private var captureInstances: [UInt32: CGWindowListCapture] = [:]

    private let displayMonitor: DisplayMonitor
    private let displaySwitchMonitor: DisplaySwitchMonitor
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: AppInfoProvider

    private var currentConfig: CaptureConfig
    /// Per-display deduplication state for multi-display mode
    private var lastKeptFrameByDisplay: [UInt32: CapturedFrame] = [:]
    /// Legacy single-display dedup state
    private var lastKeptFrame: CapturedFrame?
    private var _isCapturing: Bool = false

    /// Tracks the currently focused display ID (updated on display switch)
    private var currentFocusedDisplayID: UInt32 = 0
    /// Cached top-window metadata per display to avoid querying CGWindowList for every frame
    private var cachedTopWindowMetadataByDisplay: [UInt32: FrameMetadata] = [:]
    /// Last refresh timestamp for top-window metadata cache
    private var lastTopWindowMetadataRefresh: Date = .distantPast
    /// Cache TTL for top-window metadata queries (milliseconds-level staleness is acceptable)
    private let topWindowMetadataCacheTTL: TimeInterval = 0.25
    /// Max wall-clock window to keep grouping frames into a shared multi-display timestamp batch.
    /// Chosen to be short enough to avoid cross-cycle leakage while accommodating per-display jitter.
    private let multiDisplayTimestampBatchWindow: TimeInterval = 0.35
    private var multiDisplayTimestampBatch: MultiDisplayTimestampBatch?

    // Frame stream management
    private var rawFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?

    // Display connect/disconnect observer
    private var screenChangeObserver: NSObjectProtocol?

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

    /// Callback for accessibility permission warnings
    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?

    /// Callback when capture stops unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?

    // MARK: - Initialization

    public init(config: CaptureConfig = .default) {
        self.currentConfig = config
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

        // Create raw frame stream (shared by all capture instances)
        let (rawStream, rawContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.rawFrameContinuation = rawContinuation

        // Create deduped frame stream for consumers
        let (dedupedStream, dedupedContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.dedupedFrameContinuation = dedupedContinuation
        self._frameStream = dedupedStream

        // Get the active display
        let activeDisplayID = await displayMonitor.getActiveDisplayID()
        self.currentFocusedDisplayID = activeDisplayID

        if config.recordAllDisplays {
            // Multi-display mode: start one capture per connected display
            try await startMultiDisplayCapture(config: config, continuation: rawContinuation)
        } else {
            // Single-display mode: capture only the active display (current behavior)
            let capture = CGWindowListCapture()
            try await capture.startCapture(
                config: config,
                frameContinuation: rawContinuation,
                displayID: activeDisplayID
            )
            self.singleCapture = capture
        }

        _isCapturing = true
        stats = CaptureStatistics(
            totalFramesCaptured: 0,
            framesDeduped: 0,
            averageFrameSizeBytes: 0,
            captureStartTime: Date(),
            lastFrameTime: nil
        )

        // Start monitoring for display switches
        await startDisplaySwitchMonitoring(initialDisplayID: activeDisplayID)

        // Listen for display connect/disconnect in multi-display mode
        if config.recordAllDisplays {
            startScreenChangeMonitoring()
        }

        // Process raw frames with deduplication
        Task {
            await processFrameStream(rawStream: rawStream)
        }
    }

    public func stopCapture() async throws {
        guard _isCapturing else { return }

        // Stop display switch monitoring
        await displaySwitchMonitor.stopMonitoring()

        // Stop screen change monitoring
        stopScreenChangeMonitoring()

        // Stop all capture instances
        if let single = singleCapture {
            try await single.stopCapture()
            singleCapture = nil
        }
        for (_, capture) in captureInstances {
            try await capture.stopCapture()
        }
        captureInstances.removeAll()

        _isCapturing = false
        rawFrameContinuation?.finish()
        dedupedFrameContinuation?.finish()
        rawFrameContinuation = nil
        dedupedFrameContinuation = nil
        lastKeptFrame = nil
        lastKeptFrameByDisplay.removeAll()
        cachedTopWindowMetadataByDisplay.removeAll()
        lastTopWindowMetadataRefresh = .distantPast
        multiDisplayTimestampBatch = nil
        hasShownAccessibilityWarning = false
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
        let oldConfig = self.currentConfig
        self.currentConfig = config

        if _isCapturing {
            // If multi-display mode changed, restart capture entirely
            if oldConfig.recordAllDisplays != config.recordAllDisplays {
                try await stopCapture()
                try await startCapture(config: config)
                return
            }

            // Update config on all active capture instances
            if let single = singleCapture {
                try await single.updateConfig(config)
            }
            for (_, capture) in captureInstances {
                try await capture.updateConfig(config)
            }
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

    // MARK: - Multi-Display Capture

    /// Start one CGWindowListCapture per connected display
    private func startMultiDisplayCapture(config: CaptureConfig, continuation: AsyncStream<CapturedFrame>.Continuation) async throws {
        let displays = try await displayMonitor.getAvailableDisplays()

        for display in displays {
            let capture = CGWindowListCapture()
            try await capture.startCapture(
                config: config,
                frameContinuation: continuation,
                displayID: CGDirectDisplayID(display.id)
            )
            captureInstances[display.id] = capture
            Log.info("[CaptureManager] Started capture for display \(display.id) (\(display.name ?? "unknown") \(display.width)x\(display.height))", category: .capture)
        }

        Log.info("[CaptureManager] Multi-display capture started with \(displays.count) displays", category: .capture)
    }

    /// Handle display connect/disconnect by adding/removing capture instances
    private func handleScreenParametersChanged() async {
        guard _isCapturing, currentConfig.recordAllDisplays else { return }
        guard let continuation = rawFrameContinuation else { return }

        do {
            let displays = try await displayMonitor.getAvailableDisplays()
            let currentDisplayIDs = Set(displays.map { $0.id })
            let activeDisplayIDs = Set(captureInstances.keys)

            // Start capture on newly connected displays
            for display in displays where !activeDisplayIDs.contains(display.id) {
                let capture = CGWindowListCapture()
                try await capture.startCapture(
                    config: currentConfig,
                    frameContinuation: continuation,
                    displayID: CGDirectDisplayID(display.id)
                )
                captureInstances[display.id] = capture
                Log.info("[CaptureManager] Display connected: \(display.id) - started capture", category: .capture)
            }

            // Stop capture on disconnected displays
            for displayID in activeDisplayIDs where !currentDisplayIDs.contains(displayID) {
                if let capture = captureInstances.removeValue(forKey: displayID) {
                    try await capture.stopCapture()
                    lastKeptFrameByDisplay.removeValue(forKey: displayID)
                    multiDisplayTimestampBatch = nil
                    Log.info("[CaptureManager] Display disconnected: \(displayID) - stopped capture", category: .capture)
                }
            }
        } catch {
            Log.error("[CaptureManager] Failed to handle screen change: \(error.localizedDescription)", category: .capture)
        }
    }

    // MARK: - Screen Change Monitoring

    private func startScreenChangeMonitoring() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.handleScreenParametersChanged()
            }
        }
        self.screenChangeObserver = observer
    }

    private func stopScreenChangeMonitoring() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
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
            await self?.handleWindowChange()
        }

        await displaySwitchMonitor.startMonitoring(initialDisplayID: initialDisplayID)
    }

    /// Handle window change - capture immediately and reset timer if enabled
    private func handleWindowChange() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        // Get current window info
        let currentInfo = await MainActor.run {
            appInfoProvider.getFrontmostAppInfo()
        }
        let currentTitle = currentInfo.windowName ?? ""
        let currentBundleID = currentInfo.appBundleID ?? ""

        // Check if this is a meaningful title change
        // Skip if titles are related (one contains the other) - handles "Messenger" vs "Messenger (1)"
        if let lastTitle = lastNormalizedTitle,
           let lastBundle = lastBundleID,
           lastBundle == currentBundleID {  // Same app
            let titlesRelated = lastTitle.contains(currentTitle) || currentTitle.contains(lastTitle)
            if titlesRelated && !lastTitle.isEmpty && !currentTitle.isEmpty {
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

        // In multi-display mode, trigger immediate capture on all displays concurrently.
        // This keeps per-display timers aligned after window-change driven captures.
        if currentConfig.recordAllDisplays {
            let activeCaptures = captureInstances
            await withTaskGroup(of: Void.self) { group in
                for (_, capture) in activeCaptures {
                    group.addTask {
                        await capture.captureImmediateAndResetTimer()
                    }
                }
            }
        } else {
            // Single-display mode
            if let single = singleCapture {
                await single.captureImmediateAndResetTimer()
            }
        }

        Log.debug("[CaptureManager] Window changed - captured frame and reset timer (title: '\(currentTitle)')", category: .capture)
    }

    /// Handle display switch
    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        // Update focused display tracking
        currentFocusedDisplayID = newDisplayID

        // Notify listeners that display switched (used by TimelineWindowController to reposition window)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .activeDisplayDidChange,
                object: nil,
                userInfo: ["displayID": newDisplayID]
            )
        }

        guard _isCapturing else { return }

        if currentConfig.recordAllDisplays {
            // Multi-display mode: don't restart capture, just update focused display
            // The isFocused flag will be set during metadata enrichment
            Log.debug("[CaptureManager] Display focus changed \(oldDisplayID) → \(newDisplayID) (multi-display mode, no restart needed)", category: .capture)
        } else {
            // Single-display mode: restart capture on the new display
            do {
                guard let continuation = rawFrameContinuation else { return }

                // Stop current capture
                if let single = singleCapture {
                    try await single.stopCapture()
                }

                // Start capture on new display
                let newCapture = CGWindowListCapture()
                try await newCapture.startCapture(
                    config: currentConfig,
                    frameContinuation: continuation,
                    displayID: newDisplayID
                )
                self.singleCapture = newCapture
            } catch {
                Log.error("Failed to switch displays: \(error.localizedDescription)", category: .capture)
            }
        }
    }

    /// Handle accessibility permission denial
    private func handleAccessibilityPermissionDenied() async {
        // Only show warning once per session
        guard !hasShownAccessibilityWarning else { return }
        hasShownAccessibilityWarning = true

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
        lastKeptFrame = nil
        lastKeptFrameByDisplay.removeAll()
        hasShownAccessibilityWarning = false
        singleCapture = nil
        captureInstances.removeAll()
        multiDisplayTimestampBatch = nil
        cachedTopWindowMetadataByDisplay.removeAll()
        lastTopWindowMetadataRefresh = .distantPast

        // Stop display switch monitoring
        await displaySwitchMonitor.stopMonitoring()
        stopScreenChangeMonitoring()

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
            frame = normalizeTimestampForCurrentCaptureCycle(frame)

            totalFrames += 1
            totalBytes += Int64(frame.imageData.count)

            // Enrich with app metadata and isFocused flag
            frame = await enrichFrameMetadata(frame)

            // Apply per-display deduplication if enabled
            if currentConfig.adaptiveCaptureEnabled {
                let displayID = frame.metadata.displayID

                if currentConfig.recordAllDisplays {
                    // Per-display deduplication
                    let lastFrame = lastKeptFrameByDisplay[displayID]
                    let similarity = lastFrame != nil ? deduplicator.computeSimilarity(frame, lastFrame!) : 0.0
                    let shouldKeep = deduplicator.shouldKeepFrame(
                        frame,
                        comparedTo: lastFrame,
                        threshold: currentConfig.deduplicationThreshold
                    )

                    if shouldKeep {
                        lastKeptFrameByDisplay[displayID] = frame
                        dedupedFrameContinuation?.yield(frame)
                        updateStats(totalFrames: totalFrames, totalBytes: totalBytes, frameTime: frame.timestamp, deduped: false)
                    } else {
                        updateStats(totalFrames: totalFrames, totalBytes: totalBytes, frameTime: nil, deduped: true)
                    }
                } else {
                    // Single-display deduplication (original behavior)
                    let similarity = lastKeptFrame != nil ? deduplicator.computeSimilarity(frame, lastKeptFrame!) : 0.0
                    let shouldKeep = deduplicator.shouldKeepFrame(
                        frame,
                        comparedTo: lastKeptFrame,
                        threshold: currentConfig.deduplicationThreshold
                    )

                    if shouldKeep {
                        lastKeptFrame = frame
                        dedupedFrameContinuation?.yield(frame)
                        updateStats(totalFrames: totalFrames, totalBytes: totalBytes, frameTime: frame.timestamp, deduped: false)
                        Log.debug("Frame kept (similarity: \(String(format: "%.2f%%", similarity * 100)))", category: .capture)
                    } else {
                        updateStats(totalFrames: totalFrames, totalBytes: totalBytes, frameTime: nil, deduped: true)
                        Log.info("Frame deduplicated (similarity: \(String(format: "%.2f%%", similarity * 100)), threshold: \(String(format: "%.2f%%", currentConfig.deduplicationThreshold * 100)))", category: .capture)
                    }
                }
            } else {
                // No deduplication - pass through all frames
                dedupedFrameContinuation?.yield(frame)
                updateStats(totalFrames: totalFrames, totalBytes: totalBytes, frameTime: frame.timestamp, deduped: false)
            }
        }

        // Stream ended
        multiDisplayTimestampBatch = nil
        dedupedFrameContinuation?.finish()
    }

    /// In multi-display mode, assign one canonical timestamp to all frames that belong to
    /// the same capture cycle (one frame per display). This makes display pairing deterministic.
    private func normalizeTimestampForCurrentCaptureCycle(_ frame: CapturedFrame) -> CapturedFrame {
        guard currentConfig.recordAllDisplays else { return frame }

        let displayID = frame.metadata.displayID
        let arrivalTime = frame.timestamp

        if var batch = multiDisplayTimestampBatch {
            let isDuplicateDisplay = batch.seenDisplayIDs.contains(displayID)
            let batchExpired = arrivalTime.timeIntervalSince(batch.firstFrameArrival) > multiDisplayTimestampBatchWindow

            if isDuplicateDisplay || batchExpired {
                batch = MultiDisplayTimestampBatch(
                    canonicalTimestamp: arrivalTime,
                    firstFrameArrival: arrivalTime,
                    seenDisplayIDs: [displayID]
                )
            } else {
                batch.seenDisplayIDs.insert(displayID)
            }

            multiDisplayTimestampBatch = batch
            return CapturedFrame(
                timestamp: batch.canonicalTimestamp,
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                metadata: frame.metadata
            )
        }

        let newBatch = MultiDisplayTimestampBatch(
            canonicalTimestamp: arrivalTime,
            firstFrameArrival: arrivalTime,
            seenDisplayIDs: [displayID]
        )
        multiDisplayTimestampBatch = newBatch

        return CapturedFrame(
            timestamp: newBatch.canonicalTimestamp,
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: frame.metadata
        )
    }

    /// Update capture statistics
    private func updateStats(totalFrames: Int, totalBytes: Int64, frameTime: Date?, deduped: Bool) {
        stats = CaptureStatistics(
            totalFramesCaptured: totalFrames,
            framesDeduped: deduped ? stats.framesDeduped + 1 : stats.framesDeduped,
            averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
            captureStartTime: stats.captureStartTime,
            lastFrameTime: frameTime ?? stats.lastFrameTime
        )
    }

    /// Enrich frame with app metadata and isFocused flag.
    /// In multi-display mode we resolve top-window metadata per display using CGWindowList,
    /// so each display can be assigned its own segment identity.
    private func enrichFrameMetadata(_ frame: CapturedFrame) async -> CapturedFrame {
        let runtimeDisplayID = frame.metadata.displayID
        let stableID = stableDisplayID(forRuntimeDisplayID: runtimeDisplayID)
        let focusedStableDisplayID = stableDisplayID(forRuntimeDisplayID: currentFocusedDisplayID)
        let isFocused = stableID == focusedStableDisplayID || !currentConfig.recordAllDisplays

        if !currentConfig.recordAllDisplays {
            // Single-display mode: preserve existing frontmost-app behavior.
            let metadata = await MainActor.run {
                appInfoProvider.getFrontmostAppInfo()
            }

            let enrichedMetadata = FrameMetadata(
                appBundleID: metadata.appBundleID,
                appName: metadata.appName,
                windowName: metadata.windowName,
                browserURL: metadata.browserURL,
                displayID: stableID,
                isFocused: true
            )

            return CapturedFrame(
                timestamp: frame.timestamp,
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                metadata: enrichedMetadata
            )
        }

        let metadataByDisplay = refreshTopWindowMetadataByDisplayIfNeeded()

        if let perDisplayMetadata = metadataByDisplay[runtimeDisplayID] {
            let enrichedMetadata = FrameMetadata(
                appBundleID: perDisplayMetadata.appBundleID,
                appName: perDisplayMetadata.appName,
                windowName: perDisplayMetadata.windowName,
                browserURL: perDisplayMetadata.browserURL,
                displayID: stableID,
                isFocused: isFocused
            )

            return CapturedFrame(
                timestamp: frame.timestamp,
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                metadata: enrichedMetadata
            )
        }

        // Fallback when CGWindowList snapshot has no window for this display.
        if isFocused {
            let metadata = await MainActor.run {
                appInfoProvider.getFrontmostAppInfo()
            }

            let fallbackMetadata = FrameMetadata(
                appBundleID: metadata.appBundleID,
                appName: metadata.appName,
                windowName: metadata.windowName,
                browserURL: metadata.browserURL,
                displayID: stableID,
                isFocused: true
            )

            return CapturedFrame(
                timestamp: frame.timestamp,
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                metadata: fallbackMetadata
            )
        }

        return CapturedFrame(
            timestamp: frame.timestamp,
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: FrameMetadata(displayID: stableID, isFocused: false)
        )
    }

    private func refreshTopWindowMetadataByDisplayIfNeeded() -> [UInt32: FrameMetadata] {
        let now = Date()
        if now.timeIntervalSince(lastTopWindowMetadataRefresh) < topWindowMetadataCacheTTL {
            return cachedTopWindowMetadataByDisplay
        }

        cachedTopWindowMetadataByDisplay = captureTopWindowMetadataByDisplay()
        lastTopWindowMetadataRefresh = now
        return cachedTopWindowMetadataByDisplay
    }

    private func captureTopWindowMetadataByDisplay() -> [UInt32: FrameMetadata] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [:] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        let displays: [DisplayBoundsInfo] = displayIDs.map {
            DisplayBoundsInfo(id: $0, bounds: CGDisplayBounds($0))
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            return [:]
        }

        var bestWindowByDisplay: [UInt32: WindowSnapshot] = [:]

        for window in rawList {
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.05 {
                continue
            }

            guard
                let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }

            if bounds.width < 80 || bounds.height < 80 {
                continue
            }

            let pidValue = (window[kCGWindowOwnerPID as String] as? Int) ?? -1
            if pidValue <= 0 {
                continue
            }

            guard let displayID = displayIDForWindow(bounds: bounds, displays: displays) else {
                continue
            }

            if bestWindowByDisplay[displayID] != nil {
                continue
            }

            let ownerName = (window[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            let windowNameRaw = window[kCGWindowName as String] as? String
            let windowName = (windowNameRaw?.isEmpty == false) ? windowNameRaw : nil

            bestWindowByDisplay[displayID] = WindowSnapshot(
                pid: pid_t(pidValue),
                ownerName: ownerName,
                windowName: windowName,
                bounds: bounds
            )

            if bestWindowByDisplay.count == displays.count {
                break
            }
        }

        var metadataByDisplay: [UInt32: FrameMetadata] = [:]

        for (displayID, window) in bestWindowByDisplay {
            let runningApp = NSRunningApplication(processIdentifier: window.pid)
            metadataByDisplay[displayID] = FrameMetadata(
                appBundleID: runningApp?.bundleIdentifier,
                appName: runningApp?.localizedName ?? window.ownerName,
                windowName: window.windowName,
                browserURL: nil,
                displayID: displayID,
                isFocused: false
            )
        }

        return metadataByDisplay
    }

    private func displayIDForWindow(bounds: CGRect, displays: [DisplayBoundsInfo]) -> UInt32? {
        var bestDisplayID: UInt32?
        var bestArea: CGFloat = 0

        for display in displays {
            let intersection = display.bounds.intersection(bounds)
            if intersection.isNull || intersection.isEmpty {
                continue
            }

            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestDisplayID = display.id
            }
        }

        return bestDisplayID
    }

    /// Convert runtime CGDirectDisplayID into a stable hardware-derived ID for persistence.
    /// The capture pipeline still uses runtime IDs internally; only persisted metadata uses this value.
    private func stableDisplayID(forRuntimeDisplayID runtimeDisplayID: UInt32) -> UInt32 {
        let cgDisplayID = CGDirectDisplayID(runtimeDisplayID)
        let vendor = CGDisplayVendorNumber(cgDisplayID)
        let model = CGDisplayModelNumber(cgDisplayID)
        let serial = CGDisplaySerialNumber(cgDisplayID)

        let fingerprint: String
        if vendor == 0 && model == 0 && serial == 0 {
            // Conservative fallback: unknown hardware identity, keep runtime ID scoped to session.
            fingerprint = "runtime:\(runtimeDisplayID)"
        } else if serial != 0 {
            fingerprint = "\(vendor):\(model):\(serial)"
        } else {
            // Some displays report serial=0; include pixel dimensions to reduce collisions.
            let width = CGDisplayPixelsWide(cgDisplayID)
            let height = CGDisplayPixelsHigh(cgDisplayID)
            fingerprint = "\(vendor):\(model):\(width)x\(height)"
        }

        var hash: UInt32 = 2_166_136_261 // FNV-1a 32-bit offset basis
        for byte in fingerprint.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }

        // Keep IDs Int32-compatible because persistence code still binds/reads displayID as Int32.
        // This avoids runtime traps like "Not enough bits to represent the passed value".
        let int32SafeHash = hash & 0x7FFF_FFFF
        return int32SafeHash == 0 ? 1 : int32SafeHash
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when the active display changes (user switched to app on different monitor)
    static let activeDisplayDidChange = Notification.Name("activeDisplayDidChange")
}
