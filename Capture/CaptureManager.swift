import Foundation
import CoreGraphics
import Shared

// Note: If ScreenCaptureKit import fails on older macOS, conditionally import
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {

    // MARK: - Properties

    // Toggle between ScreenCaptureKit and CGWindowList
    // Set to false to use CGWindowList (no purple indicator)
    private let useScreenCaptureKit: Bool

    private let screenCapture: ScreenCaptureService?
    private let cgWindowListCapture: CGWindowListCapture?
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

    /// Callback for accessibility permission warnings
    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?

    /// Callback when capture stops unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?

    // MARK: - Initialization

    public init(config: CaptureConfig = .default, useScreenCaptureKit: Bool = false) {
        self.currentConfig = config
        self.useScreenCaptureKit = useScreenCaptureKit

        if useScreenCaptureKit {
            self.screenCapture = ScreenCaptureService()
            self.cgWindowListCapture = nil
        } else {
            self.screenCapture = nil
            self.cgWindowListCapture = CGWindowListCapture()
        }

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

        // Create raw frame stream from ScreenCaptureService
        let (rawStream, rawContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.rawFrameContinuation = rawContinuation

        // Create deduped frame stream for consumers
        let (dedupedStream, dedupedContinuation) = AsyncStream<CapturedFrame>.makeStream()
        self.dedupedFrameContinuation = dedupedContinuation
        self._frameStream = dedupedStream

        // Start screen capture with appropriate backend
        if useScreenCaptureKit {
            // Set up callback for when stream stops unexpectedly (e.g., user clicks "Stop sharing")
            screenCapture?.onStreamStopped = { [weak self] in
                guard let self = self else { return }
                await self.handleStreamStopped()
            }

            // Start ScreenCaptureKit capture
            try await screenCapture?.startCapture(
                config: config,
                frameContinuation: rawContinuation
            )
        } else {
            // Start CGWindowList capture
            try await cgWindowListCapture?.startCapture(
                config: config,
                frameContinuation: rawContinuation
            )
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

        // Stop capture with appropriate backend
        if useScreenCaptureKit {
            try await screenCapture?.stopCapture()
        } else {
            try await cgWindowListCapture?.stopCapture()
        }

        _isCapturing = false
        rawFrameContinuation?.finish()
        dedupedFrameContinuation?.finish()
        rawFrameContinuation = nil
        dedupedFrameContinuation = nil
        lastKeptFrame = nil
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
        self.currentConfig = config

        if _isCapturing {
            if useScreenCaptureKit {
                try await screenCapture?.updateConfig(config)
            } else {
                try await cgWindowListCapture?.updateConfig(config)
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

        // Set up callback for private window detection AX permission denial
        screenCapture?.onAccessibilityPermissionDenied = {
            await self.handleAccessibilityPermissionDenied()
        }

        await displaySwitchMonitor.startMonitoring(initialDisplayID: initialDisplayID)
    }

    /// Handle display switch by restarting capture on the new display
    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        guard _isCapturing else { return }

        // logger.info("Switching capture from display \(oldDisplayID) to \(newDisplayID)")

        do {
            // Recreate raw frame continuation with same stream
            guard let continuation = rawFrameContinuation else { return }

            if useScreenCaptureKit {
                // Stop current capture
                try await screenCapture?.stopCapture()

                // Start capture on new display
                try await screenCapture?.startCapture(
                    config: currentConfig,
                    frameContinuation: continuation
                )
            } else {
                // Stop current capture
                try await cgWindowListCapture?.stopCapture()

                // Start capture on new display
                try await cgWindowListCapture?.startCapture(
                    config: currentConfig,
                    frameContinuation: continuation
                )
            }

            // logger.info("Successfully switched to display \(newDisplayID)")
        } catch {
            // logger.error("Failed to switch displays: \(error.localizedDescription)")
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
        lastKeptFrame = nil
        hasShownAccessibilityWarning = false

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
                } else {
                    // Frame was filtered out
                    stats = CaptureStatistics(
                        totalFramesCaptured: totalFrames,
                        framesDeduped: stats.framesDeduped + 1,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime,
                        lastFrameTime: stats.lastFrameTime
                    )
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
        // Get app info on main actor
        let metadata = await MainActor.run {
            appInfoProvider.getFrontmostAppInfo()
        }

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
}
