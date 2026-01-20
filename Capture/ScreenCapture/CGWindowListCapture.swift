import Foundation
import CoreGraphics
import AppKit
import Shared

/// Service that uses legacy CGWindowList API for screen capture
/// Unlike ScreenCaptureKit, this approach:
/// - Does NOT show the purple privacy indicator
/// - Uses polling instead of streaming
/// - Works on older macOS versions
/// - Filters excluded apps and private windows on EVERY capture
public actor CGWindowListCapture {

    // MARK: - Properties

    nonisolated(unsafe) private var timer: Timer?
    private var isActive = false
    private var currentConfig: CaptureConfig?

    /// Track if array-based capture has been tested and found broken
    /// Once we know it's broken, skip directly to fallback masking
    private var arrayCaptureBroken = false

    /// Callback when frame is captured
    nonisolated(unsafe) var onFrameCaptured: (@Sendable (CapturedFrame) -> Void)?

    // MARK: - Lifecycle

    /// Start capturing frames with the given configuration
    /// - Parameters:
    ///   - config: Capture configuration
    ///   - frameContinuation: Continuation to yield captured frames
    ///   - displayID: The display to capture (defaults to main display if nil)
    func startCapture(
        config: CaptureConfig,
        frameContinuation: AsyncStream<CapturedFrame>.Continuation,
        displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard !isActive else { return }

        self.currentConfig = config
        self.isActive = true

        // Set up frame callback
        self.onFrameCaptured = { frame in
            frameContinuation.yield(frame)
        }

        // Use provided display ID or fall back to main display
        let targetDisplayID = displayID ?? CGMainDisplayID()

        // Start timer-based polling on main thread
        await MainActor.run {
            self.startPolling(displayID: targetDisplayID, interval: config.captureIntervalSeconds)
        }
    }

    /// Stop capturing frames
    func stopCapture() async throws {
        guard isActive else { return }

        isActive = false

        // Stop timer on main thread
        await MainActor.run {
            timer?.invalidate()
            timer = nil
        }

        onFrameCaptured = nil
    }

    /// Update capture configuration
    func updateConfig(_ config: CaptureConfig) async throws {
        self.currentConfig = config
        // No need to update excluded windows here - they're computed on every capture
    }

    /// Check if currently capturing
    var isCapturing: Bool {
        isActive
    }

    /// Get current configuration
    func getConfig() -> CaptureConfig? {
        currentConfig
    }

    // MARK: - Private Helpers

    /// Start polling for frames
    @MainActor
    private func startPolling(displayID: CGWindowID, interval: TimeInterval) {
        // Invalidate existing timer
        timer?.invalidate()

        // Create new timer
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.captureFrame(displayID: displayID)
            }
        }

        // Fire immediately
        Task {
            await self.captureFrame(displayID: displayID)
        }
    }

    /// Capture a single frame with real-time filtering of excluded apps and private windows
    private func captureFrame(displayID: CGWindowID) async {
        guard isActive, let config = currentConfig else { return }

        // Compute excluded window IDs for THIS capture (real-time filtering)
        let excludedIDs = computeExcludedWindowIDs(config: config)

        // Capture the frame using CGWindowList with filtering
        guard let cgImage = captureWithFiltering(displayID: displayID, excludedWindowIDs: excludedIDs) else {
            Log.warning("Failed to capture CGImage", category: .capture)
            return
        }

        // Convert CGImage to BGRA data format (matching ScreenCaptureKit output)
        guard let frameData = convertCGImageToBGRAData(cgImage) else {
            Log.warning("Failed to convert CGImage to BGRA data", category: .capture)
            return
        }

        // Get display info and captured image dimensions
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        Log.debug("[CGWindowListCapture] Frame captured: \(width)x\(height), excluded \(excludedIDs.count) windows", category: .capture)

        // Create captured frame
        let frame = CapturedFrame(
            timestamp: Date(),
            imageData: frameData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(displayID: UInt32(displayID))
        )

        // Yield frame
        onFrameCaptured?(frame)
    }

    /// Compute which window IDs should be excluded based on current config
    /// Called on EVERY capture to ensure real-time filtering
    private func computeExcludedWindowIDs(config: CaptureConfig) -> Set<CGWindowID> {
        var excludedIDs = Set<CGWindowID>()

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return excludedIDs
        }


        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "unknown"
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""

            // Check 1: Excluded app bundle IDs (check by bundle ID from PID)
            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
               let bundleID = bundleIDForPID(ownerPID) {
                if config.excludedAppBundleIDs.contains(bundleID) {
                    Log.info("[Exclusion] EXCLUDING app window: '\(windowName)' from \(ownerName) (bundleID: \(bundleID))", category: .capture)
                    excludedIDs.insert(windowID)
                    continue
                }
            }

            // Check 2: Private/incognito windows
            // TODO: Re-enable once private window detection is more reliable
            // Currently disabled because title-based detection has false positives
            // (e.g., pages with "private" in the title) and AX-based detection
            // doesn't reliably detect Chrome/Safari incognito windows
            // if config.excludePrivateWindows {
            //     if PrivateWindowDetector.isPrivateWindow(
            //         windowInfo: windowInfo,
            //         patterns: config.customPrivateWindowPatterns
            //     ) {
            //         excludedIDs.insert(windowID)
            //         Log.info("[PrivateDetect] EXCLUDING private window: '\(windowName)' from \(ownerName)", category: .capture)
            //     }
            // }
        }

        return excludedIDs
    }

    /// Get bundle ID for a process ID
    private func bundleIDForPID(_ pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.bundleIdentifier
    }

    /// Capture with window filtering using CGWindowListCreateImageFromArray
    private func captureWithFiltering(displayID: CGWindowID, excludedWindowIDs: Set<CGWindowID>) -> CGImage? {
        // If no exclusions, use simple display capture
        if excludedWindowIDs.isEmpty {
            return CGDisplayCreateImage(displayID)
        }

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return CGDisplayCreateImage(displayID)
        }

        // Build list of window IDs to include (everything except excluded)
        // CRITICAL: Only include windows with layer == 0 (normal app windows)
        // System windows with extreme layer values (e.g., -2147483601) can cause
        // CGWindowListCreateImageFromArray to return nil
        var includedWindowIDs: [CGWindowID] = []

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }

            // Filter out system/desktop/overlay windows by checking layer
            // Layer 0 = normal application windows
            // Non-zero layers are typically system windows that can break the API
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                Log.debug("[Filtering] Skipping window \(windowID) with layer \(layer)", category: .capture)
                continue
            }

            // Also verify window has valid properties
            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 0
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if alpha <= 0 || !isOnScreen {
                continue
            }

            if !excludedWindowIDs.contains(windowID) {
                includedWindowIDs.append(windowID)
            }
        }

        // If we filtered everything, capture just desktop
        if includedWindowIDs.isEmpty {
            return CGDisplayCreateImage(displayID)
        }

        let displayBounds = CGDisplayBounds(displayID)

        Log.info("[Filtering] Display bounds: \(displayBounds), displayID: \(displayID)", category: .capture)
        Log.info("[Filtering] Attempting to capture \(includedWindowIDs.count) windows, excluding \(excludedWindowIDs.count)", category: .capture)
        Log.info("[Filtering] Included window IDs: \(includedWindowIDs.prefix(10))...", category: .capture)
        Log.info("[Filtering] Excluded window IDs: \(excludedWindowIDs)", category: .capture)

        // Log details about included windows
        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
            if includedWindowIDs.contains(windowID) {
                let name = windowInfo[kCGWindowName as String] as? String ?? "(no name)"
                let owner = windowInfo[kCGWindowOwnerName as String] as? String ?? "(no owner)"
                let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
                let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
                let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? -1
                let onScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
                Log.debug("[Filtering] Including window \(windowID): '\(name)' from \(owner), layer=\(layer), alpha=\(alpha), onScreen=\(onScreen), bounds=\(bounds ?? [:])", category: .capture)
            }
        }

        // Create CFArray of window IDs properly - must be CGWindowID (UInt32) wrapped as NSNumber/CFNumber
        let windowNumbers: [NSNumber] = includedWindowIDs.map { NSNumber(value: $0) }
        let windowArray: CFArray = windowNumbers as CFArray

        Log.info("[Filtering] Created CFArray with \(CFArrayGetCount(windowArray)) elements", category: .capture)

        // If we already know array capture is broken on this system, skip straight to fallback
        if arrayCaptureBroken {
            return captureWithMasking(displayID: displayID, excludedWindowIDs: excludedWindowIDs, windowList: windowList)
        }

        // Try the array-based capture first
        if let image = CGImage(
            windowListFromArrayScreenBounds: displayBounds,
            windowArray: windowArray,
            imageOption: [.bestResolution]
        ) {
            Log.info("[Filtering] SUCCESS with array capture: \(image.width)x\(image.height)", category: .capture)
            return image
        }

        // Array capture failed - run diagnostic ONCE to log which windows fail
        Log.warning("[Filtering] Array capture failed on macOS, testing individual windows (one-time diagnostic)...", category: .capture)
        for windowID in includedWindowIDs {
            let singleArray: CFArray = [NSNumber(value: windowID)] as CFArray
            if CGImage(
                windowListFromArrayScreenBounds: displayBounds,
                windowArray: singleArray,
                imageOption: [.bestResolution]
            ) == nil {
                let info = windowList.first { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
                let name = info?[kCGWindowName as String] as? String ?? "(no name)"
                let owner = info?[kCGWindowOwnerName as String] as? String ?? "(no owner)"
                Log.error("[Filtering] Window \(windowID) FAILS individually: '\(name)' from \(owner)", category: .capture)
            }
        }

        // Mark as broken so we skip directly to fallback on future captures
        Log.warning("[Filtering] CGWindowListCreateImageFromArray is broken on this macOS version. Using masking fallback permanently.", category: .capture)
        arrayCaptureBroken = true

        // FALLBACK: Capture full screen and mask out excluded windows
        return captureWithMasking(displayID: displayID, excludedWindowIDs: excludedWindowIDs, windowList: windowList)
    }

    /// Fallback capture method: capture full screen and mask out VISIBLE portions of excluded windows
    /// This avoids the CGWindowListCreateImageFromArray API which is unreliable on macOS 14+
    /// Only masks regions that are actually visible (not covered by other windows)
    private func captureWithMasking(
        displayID: CGWindowID,
        excludedWindowIDs: Set<CGWindowID>,
        windowList: [[String: Any]]
    ) -> CGImage? {
        // Capture the full screen first
        guard let fullScreenImage = CGDisplayCreateImage(displayID) else {
            Log.error("[Masking] Failed to capture full screen", category: .capture)
            return nil
        }

        // If nothing to exclude, return the full screen capture
        if excludedWindowIDs.isEmpty {
            return fullScreenImage
        }

        let displayBounds = CGDisplayBounds(displayID)
        let scale = CGFloat(fullScreenImage.width) / displayBounds.width

        // Build ordered list of window bounds (front to back, as returned by CGWindowListCopyWindowInfo)
        // Windows earlier in the list are in front of windows later in the list
        var windowBoundsInOrder: [(windowID: CGWindowID, rect: CGRect, isExcluded: Bool)] = []

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else {
                continue
            }

            // Only consider layer 0 windows (normal app windows)
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            // Convert to image coordinates and scale
            let rect = CGRect(
                x: (x - displayBounds.origin.x) * scale,
                y: (y - displayBounds.origin.y) * scale,
                width: width * scale,
                height: height * scale
            )

            windowBoundsInOrder.append((windowID, rect, excludedWindowIDs.contains(windowID)))
        }

        // Calculate visible regions for each excluded window
        // For each excluded window, subtract all windows that are in front of it
        var visibleExcludedRects: [CGRect] = []

        for (index, window) in windowBoundsInOrder.enumerated() {
            guard window.isExcluded else { continue }

            // Start with the full window rect
            var visibleRegions = [window.rect]

            // Subtract all windows in front of this one (earlier in the list)
            for frontIndex in 0..<index {
                let frontWindow = windowBoundsInOrder[frontIndex]
                visibleRegions = subtractRect(frontWindow.rect, from: visibleRegions)
            }

            // Add remaining visible regions to mask list
            for region in visibleRegions where region.width > 1 && region.height > 1 {
                visibleExcludedRects.append(region)
                Log.debug("[Masking] Visible region for window \(window.windowID): \(region)", category: .capture)
            }
        }

        // If no visible regions to mask, return the full capture
        if visibleExcludedRects.isEmpty {
            Log.info("[Masking] Excluded windows are fully occluded, no masking needed", category: .capture)
            return fullScreenImage
        }

        // Create a new image with visible excluded regions blacked out
        let width = fullScreenImage.width
        let height = fullScreenImage.height

        guard let colorSpace = fullScreenImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            Log.error("[Masking] Failed to create graphics context", category: .capture)
            return fullScreenImage
        }

        // Draw the full screen image
        context.draw(fullScreenImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Black out visible excluded regions
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in visibleExcludedRects {
            // Flip Y coordinate for CGContext (origin is bottom-left)
            let flippedRect = CGRect(
                x: rect.origin.x,
                y: CGFloat(height) - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
            context.fill(flippedRect)
        }

        guard let maskedImage = context.makeImage() else {
            Log.error("[Masking] Failed to create masked image", category: .capture)
            return fullScreenImage
        }

        Log.info("[Masking] Successfully masked \(visibleExcludedRects.count) visible regions", category: .capture)
        return maskedImage
    }

    /// Subtract a rectangle from a list of rectangles, returning the remaining visible regions
    /// This handles the case where one rect partially or fully overlaps another
    private func subtractRect(_ subtractor: CGRect, from rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []

        for rect in rects {
            let intersection = rect.intersection(subtractor)

            // No overlap - keep the original rect
            if intersection.isNull || intersection.isEmpty {
                result.append(rect)
                continue
            }

            // Full overlap - rect is completely hidden
            if subtractor.contains(rect) {
                continue
            }

            // Partial overlap - split into up to 4 remaining rectangles
            // Top portion (above the intersection)
            if intersection.minY > rect.minY {
                result.append(CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: intersection.minY - rect.minY
                ))
            }

            // Bottom portion (below the intersection)
            if intersection.maxY < rect.maxY {
                result.append(CGRect(
                    x: rect.minX,
                    y: intersection.maxY,
                    width: rect.width,
                    height: rect.maxY - intersection.maxY
                ))
            }

            // Left portion (to the left of intersection, between top and bottom)
            if intersection.minX > rect.minX {
                result.append(CGRect(
                    x: rect.minX,
                    y: intersection.minY,
                    width: intersection.minX - rect.minX,
                    height: intersection.height
                ))
            }

            // Right portion (to the right of intersection, between top and bottom)
            if intersection.maxX < rect.maxX {
                result.append(CGRect(
                    x: intersection.maxX,
                    y: intersection.minY,
                    width: rect.maxX - intersection.maxX,
                    height: intersection.height
                ))
            }
        }

        return result
    }

    /// Convert CGImage to BGRA Data format (matching ScreenCaptureKit's kCVPixelFormatType_32BGRA)
    private func convertCGImageToBGRAData(_ cgImage: CGImage) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4 // BGRA = 4 bytes per pixel
        let dataSize = bytesPerRow * height

        // Allocate buffer
        var pixelData = Data(count: dataSize)

        // Create bitmap context and draw within the same closure to ensure pointer validity
        let success = pixelData.withUnsafeMutableBytes { rawBufferPointer -> Bool in
            guard let baseAddress = rawBufferPointer.baseAddress else { return false }

            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return false
            }

            // Draw the image into the context (converts to BGRA)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? pixelData : nil
    }
}
