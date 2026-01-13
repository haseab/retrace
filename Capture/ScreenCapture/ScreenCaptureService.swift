import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Shared

/// Service that manages ScreenCaptureKit stream and captures frames
actor ScreenCaptureService {

    // MARK: - Properties

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var currentConfig: CaptureConfig?
    private var privateWindowMonitor: PrivateWindowMonitor?
    private var currentDisplay: SCDisplay?
    private var currentContent: SCShareableContent?

    /// Callback when accessibility permission is denied
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?

    /// Callback when stream stops unexpectedly (e.g., user clicks "Stop sharing" in macOS)
    nonisolated(unsafe) var onStreamStopped: (@Sendable () async -> Void)?

    // MARK: - Lifecycle

    /// Start capturing frames with the given configuration
    /// - Parameter config: Capture configuration
    /// - Parameter frameContinuation: Continuation to yield captured frames to
    func startCapture(
        config: CaptureConfig,
        frameContinuation: AsyncStream<CapturedFrame>.Continuation
    ) async throws {
        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Store content for later use
        self.currentContent = content

        // Find the display to capture (use active display based on focused window)
        let displayMonitor = DisplayMonitor()
        let activeDisplayID = await displayMonitor.getActiveDisplayID()

        // Get the target display
        // Note: We always capture only the active display. The DisplaySwitchMonitor
        // will automatically switch to a different display when the user changes focus.
        guard let targetDisplay = content.displays.first(where: { $0.displayID == activeDisplayID }) else {
            throw CaptureError.noDisplaysAvailable
        }

        self.currentDisplay = targetDisplay

        // Filter out excluded applications
        let excludedApps = content.applications.filter { app in
            config.excludedAppBundleIDs.contains(app.bundleIdentifier)
        }

        // Detect private/incognito windows using Accessibility API
        var privateWindows: [SCWindow] = []
        if config.excludePrivateWindows {
            privateWindows = content.windows.filter { window in
                PrivateWindowDetector.isPrivateWindow(window)
            }
        }

        // Combine excluded apps' windows with private windows for complete exclusion list
        let excludedAppBundleIDs = Set(excludedApps.map { $0.bundleIdentifier })
        let excludedAppWindows = content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
            return excludedAppBundleIDs.contains(bundleID)
        }

        let allExcludedWindows = Array(Set(excludedAppWindows + privateWindows))

        // Create content filter using excludingWindows initializer
        // This properly excludes specific windows from the display capture
        let filter = SCContentFilter(
            display: targetDisplay,
            excludingWindows: allExcludedWindows
        )

        // Configure the stream
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = min(targetDisplay.width, config.maxResolution.width)
        streamConfig.height = min(targetDisplay.height, config.maxResolution.height)
        streamConfig.minimumFrameInterval = CMTime(
            seconds: config.captureIntervalSeconds,
            preferredTimescale: 600
        )
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = false
        streamConfig.capturesAudio = false
        streamConfig.queueDepth = 3

        // Create output handler (also serves as stream delegate for lifecycle events)
        let output = StreamOutput(
            continuation: frameContinuation,
            displayID: activeDisplayID,
            onStreamStopped: self.onStreamStopped
        )
        self.streamOutput = output

        // Create stream with output as delegate to receive stop notifications
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: output)

        // Add output handler to stream
        try newStream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )

        // Start capture
        try await newStream.startCapture()

        self.stream = newStream
        self.currentConfig = config

        // Start monitoring for private windows (if enabled)
        if config.excludePrivateWindows {
            let monitor = PrivateWindowMonitor(checkIntervalSeconds: 30.0)
            self.privateWindowMonitor = monitor

            // Set up callback for when private windows change
            monitor.onPrivateWindowsChanged = { [weak self] privateWindows in
                await self?.updateExcludedWindows(newPrivateWindows: privateWindows)
            }

            // Set up callback for AX permission denial
            monitor.onAccessibilityPermissionDenied = { [weak self] in
                guard let self = self else { return }
                if let callback = self.onAccessibilityPermissionDenied {
                    await callback()
                }
            } as @Sendable () async -> Void

            await monitor.startMonitoring(config: config)
            Log.info("Private window monitoring started", category: .capture)
        }
    }

    /// Stop capturing frames
    func stopCapture() async throws {
        guard let stream = stream else { return }

        // Stop private window monitoring
        if let monitor = privateWindowMonitor {
            await monitor.stopMonitoring()
            privateWindowMonitor = nil
        }

        try await stream.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        self.currentConfig = nil
        self.currentDisplay = nil
        self.currentContent = nil
    }

    /// Update capture configuration
    /// - Parameter config: New configuration
    func updateConfig(_ config: CaptureConfig) async throws {
        guard let stream = stream else { return }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.maxResolution.width
        streamConfig.height = config.maxResolution.height
        streamConfig.minimumFrameInterval = CMTime(
            seconds: config.captureIntervalSeconds,
            preferredTimescale: 600
        )

        try await stream.updateConfiguration(streamConfig)
        self.currentConfig = config
    }

    /// Check if currently capturing
    var isCapturing: Bool {
        stream != nil
    }

    /// Get current configuration
    func getConfig() -> CaptureConfig? {
        currentConfig
    }

    // MARK: - Private Window Updates

    /// Update the stream filter to exclude newly detected private windows
    /// - Parameter newPrivateWindows: List of private windows detected
    private func updateExcludedWindows(newPrivateWindows: [SCWindow]) async {
        guard let stream = stream,
              let config = currentConfig,
              let display = currentDisplay,
              let content = currentContent else {
            Log.warning("Cannot update excluded windows - stream not active", category: .capture)
            return
        }

        // Combine excluded apps' windows with private windows
        let excludedApps = content.applications.filter { app in
            config.excludedAppBundleIDs.contains(app.bundleIdentifier)
        }

        let excludedAppBundleIDs = Set(excludedApps.map { $0.bundleIdentifier })
        let excludedAppWindows = content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
            return excludedAppBundleIDs.contains(bundleID)
        }

        let allExcludedWindows = Array(Set(excludedAppWindows + newPrivateWindows))

        Log.info("Updating stream filter: excluding \(allExcludedWindows.count) windows (\(newPrivateWindows.count) private)", category: .capture)

        // Create new content filter
        let newFilter = SCContentFilter(
            display: display,
            excludingWindows: allExcludedWindows
        )

        // Update stream filter
        do {
            try await stream.updateContentFilter(newFilter)
            Log.info("Stream filter updated successfully", category: .capture)
        } catch {
            Log.error("Failed to update stream filter: \(error)", category: .capture)
        }
    }
}

// MARK: - Stream Output Handler

/// Handles sample buffers and lifecycle events from ScreenCaptureKit stream
class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // MARK: - Properties

    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let displayID: UInt32
    private let onStreamStopped: (@Sendable () async -> Void)?

    // MARK: - Initialization

    init(
        continuation: AsyncStream<CapturedFrame>.Continuation,
        displayID: UInt32,
        onStreamStopped: (@Sendable () async -> Void)? = nil
    ) {
        self.continuation = continuation
        self.displayID = displayID
        self.onStreamStopped = onStreamStopped
        super.init()
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Only process screen output
        guard type == .screen else { return }

        // Get pixel buffer from sample buffer
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Extract frame data
        let timestamp = Date()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        // Copy image data
        let data = Data(bytes: baseAddress, count: bytesPerRow * height)

        // Get app metadata (this would normally use AppInfoProvider, but we'll add that later)
        let metadata = FrameMetadata(
            displayID: self.displayID
        )

        // Create captured frame
        let frame = CapturedFrame(
            timestamp: timestamp,
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: metadata
        )

        // Yield frame to continuation
        continuation.yield(frame)
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: Error
    ) {
        // Stream stopped - finish the continuation
        continuation.finish()

        // Notify that stream stopped unexpectedly (e.g., user clicked "Stop sharing")
        if let callback = onStreamStopped {
            Task {
                await callback()
            }
        }
    }
}
