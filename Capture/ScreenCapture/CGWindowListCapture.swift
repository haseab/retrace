import Foundation
import CoreGraphics
import AppKit
import CoreImage
import Shared

private enum CaptureScreenResidualMemoryLedger {
    private static let tracker = Tracker()
    private static let concurrentResidualTag = "concurrent.captureProcessing.observedResidual"
    private static let concurrentResidualFunction = "concurrent.capture_processing"
    private static let processingOwnedResidualFunctions: Set<String> = [
        "processing.extract_text.residual",
        "processing.extract_text.ocr_call",
        "processing.extract_text.handoff",
        "processing.extract_text.ocr_tail",
        "processing.ocr.region_reocr",
        "processing.ocr.full_frame",
        "processing.ocr.stage"
    ]

    static func emitObservedResidual(
        reason: String,
        residualEpoch: MemoryLedger.ResidualEpoch
    ) async {
        let snapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let activeProcessingResidualBytes = snapshot.functions
            .filter { processingOwnedResidualFunctions.contains($0.function) }
            .reduce(into: Int64(0)) { runningTotal, summary in
                if runningTotal > Int64.max - summary.trackedBytes {
                    runningTotal = Int64.max
                } else {
                    runningTotal += max(0, summary.trackedBytes)
                }
            }
        let requestedBytes = max(
            0,
            Int64(min(snapshot.unattributedBytes, UInt64(Int64.max))) - activeProcessingResidualBytes
        )
        await MemoryLedger.flushPendingUpdates()
        let claim = await MemoryLedger.claimCurrentUnattributed(
            epoch: residualEpoch,
            requestedBytes: requestedBytes
        )

        let tag: String
        let function: String
        let kind: String
        let note: String

        switch claim.target {
        case .owner:
            tag = "capture.screenCapture.observedResidual"
            function = "capture.screen_capture"
            kind = "screen-capture-residual"
            note = "epoch-arbited-current-unattributed"
        case .concurrent:
            tag = concurrentResidualTag
            function = concurrentResidualFunction
            kind = "concurrent-capture-processing-residual"
            note = "epoch-arbited-current-unattributed"
        case .none:
            return
        }

        tracker.setRetained(
            tag: tag,
            function: function,
            kind: kind,
            note: note,
            unit: "samples",
            bytes: claim.bytes,
            reason: reason,
            delay: 0
        )
    }

    private final class Tracker: @unchecked Sendable {
        private struct Entry {
            var bytes: Int64
            var count: Int
            var function: String
            var kind: String
            var note: String?
            var unit: String
        }

        private let lock = NSLock()
        private var entriesByTag: [String: Entry] = [:]
        private var retainedGenerationByTag: [String: UInt64] = [:]

        func setRetained(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            unit: String,
            bytes: Int64,
            reason: String,
            delay: TimeInterval
        ) {
            let generation: UInt64

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note,
                unit: unit
            )
            entry.bytes = max(0, bytes)
            entry.count = entry.bytes > 0 ? 1 : 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entry.unit = unit
            entriesByTag[tag] = entry
            generation = (retainedGenerationByTag[tag] ?? 0) + 1
            retainedGenerationByTag[tag] = generation
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .capture,
                minIntervalSeconds: 1,
                force: true
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
                function: "capture.screen_capture",
                kind: "screen-capture-residual",
                note: "observed-unattributed",
                unit: "samples"
            )
            entry.bytes = 0
            entry.count = 0
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .capture,
                minIntervalSeconds: 1
            )
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
                category: .inferred
            )
        }
    }
}

/// Service that uses legacy CGWindowList API for screen capture
/// Unlike ScreenCaptureKit, this approach:
/// - Does NOT show the purple privacy indicator
/// - Uses polling driven by CaptureManager
/// - Works on older macOS versions
/// - Filters excluded apps and private windows on EVERY capture
public actor CGWindowListCapture {
    private static let memoryLedgerDisplaySurfaceTag = "capture.screenCapture.displaySurface"
    private static let memoryLedgerIOSurfacePoolTag = "capture.screenCapture.ioSurfacePool"
    private static let memoryLedgerCompositorBackingTag = "capture.screenCapture.compositorBacking"
    private static let memoryLedgerRedactionSurfaceTag = "capture.screenCapture.redactionSurface"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 5

    // MARK: - Properties

    nonisolated(unsafe) private var currentDisplayID: CGWindowID?
    private var isActive = false
    private var currentConfig: CaptureConfig?
    private let screenLockStateMonitor = ScreenLockStateMonitor()
    private var lastCaptureBlockReason: String?

    /// Track if array-based capture has been tested and found broken
    /// Once we know it's broken, skip directly to fallback masking
    private var arrayCaptureBroken = false

    private struct RedactionWindowContext: Sendable {
        let reason: String
        let appBundleID: String?
        let appName: String?
    }

    private struct RedactionSummary: Sendable {
        let reason: String
        let appBundleID: String?
        let appName: String?
    }

    private struct VisibleWindowContext: Sendable {
        let appBundleID: String?
        let appName: String?
        let windowName: String?
    }

    private struct ExclusionComputationResult: Sendable {
        let excludedWindowIDs: Set<CGWindowID>
        let redactedWindowIDs: Set<CGWindowID>
        let redactionContextByWindowID: [CGWindowID: RedactionWindowContext]
        let redactionWindowOrder: [CGWindowID]
        let visibleWindowContext: VisibleWindowContext?
        let captureBlockReason: String?
    }

    private struct FilteredCaptureResult {
        let image: CGImage
        let visibleExcludedWindowIDs: Set<CGWindowID>
    }

    private struct PrivateWindowDecisionState: Sendable {
        let ownerPID: pid_t
        let isPrivate: Bool
        let observedAt: Date
    }

    /// Positive private detections are retained briefly to avoid one-frame leaks during AX title transitions.
    private var privateWindowDecisionStateByWindowID: [CGWindowID: PrivateWindowDecisionState] = [:]
    private let privateWindowPositiveGraceInterval: TimeInterval = 6
    private let privateWindowStateRetentionInterval: TimeInterval = 90

    private let redactionBlurRadius: Double = 400
    private let redactionMaskCornerRadius: CGFloat = 12
    private let redactionBorderWidth: CGFloat = 2
    private let redactionCIContext = CIContext()
    private var lastDisplaySurfaceBytes: Int64 = 0

    // MARK: - Lifecycle

    /// Start capturing frames with the given configuration
    /// - Parameters:
    ///   - config: Capture configuration
    ///   - displayID: The display to capture (defaults to main display if nil)
    func startCapture(
        config: CaptureConfig,
        displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard !isActive else { return }

        self.currentConfig = config
        self.isActive = true
        self.lastCaptureBlockReason = nil
        self.screenLockStateMonitor.start()

        // Use provided display ID or fall back to main display
        self.currentDisplayID = displayID ?? CGMainDisplayID()
    }

    /// Stop capturing frames
    func stopCapture() async throws {
        guard isActive else { return }

        isActive = false
        lastCaptureBlockReason = nil
        screenLockStateMonitor.stop()
        lastDisplaySurfaceBytes = 0
        updatePersistentCaptureNativeLedger()
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

    func captureFrame(displayID: CGDirectDisplayID) async -> CapturedFrame? {
        currentDisplayID = displayID
        return await captureFrameInternal(displayID: displayID)
    }

    /// Capture a single frame with real-time filtering of excluded apps and private windows
    private func captureFrameInternal(displayID: CGWindowID) async -> CapturedFrame? {
        guard isActive, let config = currentConfig else { return nil }
        let residualEpoch = await MemoryLedger.beginResidualEpoch(
            ownerFunction: "capture.screen_capture",
            candidateConcurrentFunctions: [
                "processing.ocr.region_reocr",
                "processing.ocr.full_frame",
                "processing.extract_text",
                "processing.ocr.stage"
            ]
        )
        defer {
            Task(priority: .utility) {
                await MemoryLedger.endResidualEpoch(residualEpoch)
            }
        }

        // Compute excluded window IDs for THIS capture (real-time filtering)
        let exclusionResult = await computeExcludedWindowIDs(config: config, displayID: displayID)
        let excludedIDs = exclusionResult.excludedWindowIDs

        if let captureBlockReason = screenLockStateMonitor.captureBlockReason() ?? exclusionResult.captureBlockReason {
            logCapturePauseIfNeeded(reason: captureBlockReason)
            return nil
        }
        logCaptureResumeIfNeeded()

        // Capture the frame using CGWindowList with filtering
        guard let captureResult = captureWithFiltering(
            displayID: displayID,
            excludedWindowIDs: excludedIDs,
            forceMasking: !exclusionResult.redactedWindowIDs.isEmpty
        ) else {
            Log.warning("[CGWindowListCapture] Failed to capture CGImage for displayID=\(displayID), excludedCount=\(excludedIDs.count)", category: .capture)
            return nil
        }
        let cgImage = captureResult.image
        let displaySurfaceBytes = Self.estimatedImageSurfaceBytes(width: cgImage.width, height: cgImage.height)
        lastDisplaySurfaceBytes = displaySurfaceBytes
        updatePersistentCaptureNativeLedger()
        MemoryLedger.set(
            tag: Self.memoryLedgerDisplaySurfaceTag,
            bytes: displaySurfaceBytes,
            count: displaySurfaceBytes > 0 ? 1 : 0,
            unit: "surfaces",
            function: "capture.screen_capture",
            kind: "cgimage-surface",
            note: "estimated-native"
        )
        await CaptureScreenResidualMemoryLedger.emitObservedResidual(
            reason: "capture.screen_capture.memory",
            residualEpoch: residualEpoch
        )
        defer {
            MemoryLedger.set(
                tag: Self.memoryLedgerDisplaySurfaceTag,
                bytes: 0,
                count: 0,
                unit: "surfaces",
                function: "capture.screen_capture",
                kind: "cgimage-surface",
                note: "estimated-native"
            )
        }

        // Convert CGImage to BGRA data format (matching ScreenCaptureKit output)
        guard let frameData = convertCGImageToBGRAData(cgImage) else {
            Log.warning("[CGWindowListCapture] Failed to convert CGImage to BGRA data for displayID=\(displayID)", category: .capture)
            return nil
        }

        // Get display info and captured image dimensions
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        Log.verbose("[CGWindowListCapture] Frame captured: \(width)x\(height), excluded \(excludedIDs.count) windows", category: .capture)

        let visibleRedactedWindowIDs = captureResult
            .visibleExcludedWindowIDs
            .intersection(exclusionResult.redactedWindowIDs)
        let redactionSummary = summarizeRedaction(
            for: visibleRedactedWindowIDs,
            contextByWindowID: exclusionResult.redactionContextByWindowID,
            redactionOrder: exclusionResult.redactionWindowOrder
        )
        let visibleWindowContext = exclusionResult.visibleWindowContext
        let resolvedAppBundleID = redactionSummary?.appBundleID ?? visibleWindowContext?.appBundleID
        let resolvedAppName = redactionSummary?.appName ?? visibleWindowContext?.appName
        let resolvedWindowName = redactionSummary == nil ? visibleWindowContext?.windowName : nil

        // Create captured frame
        let frame = CapturedFrame(
            timestamp: Date(),
            imageData: frameData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: resolvedAppBundleID,
                appName: resolvedAppName,
                windowName: resolvedWindowName,
                redactionReason: redactionSummary?.reason,
                displayID: UInt32(displayID)
            )
        )

        return frame
    }

    /// Compute which window IDs should be excluded based on current config
    /// Called on EVERY capture to ensure real-time filtering
    private func computeExcludedWindowIDs(
        config: CaptureConfig,
        displayID: CGWindowID
    ) async -> ExclusionComputationResult {
        var excludedIDs = Set<CGWindowID>()
        var redactedWindowIDs = Set<CGWindowID>()
        var redactionContextByWindowID: [CGWindowID: RedactionWindowContext] = [:]
        var redactionWindowOrder: [CGWindowID] = []
        var visibleWindowContext: VisibleWindowContext?
        var captureBlockReason: String?

        enum BrowserURLLookupResult {
            case found(String)
            case unavailable
        }

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return ExclusionComputationResult(
                excludedWindowIDs: excludedIDs,
                redactedWindowIDs: redactedWindowIDs,
                redactionContextByWindowID: redactionContextByWindowID,
                redactionWindowOrder: redactionWindowOrder,
                visibleWindowContext: visibleWindowContext,
                captureBlockReason: captureBlockReason
            )
        }

        let windowTitlePatterns = normalizedPatterns(config.redactWindowTitlePatterns)
        let browserURLPatterns = normalizedPatterns(config.redactBrowserURLPatterns)

        let hasWindowTitlePatterns = !windowTitlePatterns.isEmpty
        let hasBrowserURLPatterns = !browserURLPatterns.isEmpty

        var bundleIDCache: [pid_t: String] = [:]
        var pidsWithoutBundleID = Set<pid_t>()
        var browserURLCache: [String: BrowserURLLookupResult] = [:]
        var privateWindowRedactionCache: [String: Bool] = [:]
        var privateModeByPID: [pid_t: Bool] = [:]
        var privateModeMissByPID = Set<pid_t>()
        var privateBrowserPIDs = Set<pid_t>()
        var privateCompanionCandidatesByPID: [pid_t: [(windowID: CGWindowID, bundleID: String?, ownerName: String)]] = [:]
        var seenWindowIDs = Set<CGWindowID>()
        let decisionTimestamp = Date()
        let displayBounds = CGDisplayBounds(displayID)

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard shouldConsiderWindowForCapture(windowInfo, displayBounds: displayBounds) else { continue }
            seenWindowIDs.insert(windowID)

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "unknown"
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""

            var ownerPID: pid_t?
            var bundleID: String?
            if let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
                ownerPID = pid
                if let cachedBundleID = bundleIDCache[pid] {
                    bundleID = cachedBundleID
                } else if !pidsWithoutBundleID.contains(pid), let resolvedBundleID = bundleIDForPID(pid) {
                    bundleID = resolvedBundleID
                    bundleIDCache[pid] = resolvedBundleID
                } else {
                    pidsWithoutBundleID.insert(pid)
                }
            }

            if captureBlockReason == nil {
                captureBlockReason = Self.captureBlockReason(ownerName: ownerName, bundleID: bundleID)
            }

            if visibleWindowContext == nil {
                visibleWindowContext = VisibleWindowContext(
                    appBundleID: bundleID,
                    appName: appDisplayName(ownerName: ownerName, bundleID: bundleID),
                    windowName: normalizedWindowTitle(windowName)
                )
            }

            if let ownerPID,
               let bundleID,
               BrowserURLExtractor.isBrowser(bundleID),
               windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                privateCompanionCandidatesByPID[ownerPID, default: []].append(
                    (windowID: windowID, bundleID: bundleID, ownerName: ownerName)
                )
            }

            // Check 1: Excluded app bundle IDs (check by bundle ID from PID)
            if let bundleID, config.excludedAppBundleIDs.contains(bundleID) {
                Log.info("[Exclusion] EXCLUDING app window: '\(windowName)' from \(ownerName) (bundleID: \(bundleID))", category: .capture)
                excludedIDs.insert(windowID)
                redactedWindowIDs.insert(windowID)
                if redactionContextByWindowID[windowID] == nil {
                    redactionWindowOrder.append(windowID)
                    let displayName = appDisplayName(ownerName: ownerName, bundleID: bundleID)
                    redactionContextByWindowID[windowID] = RedactionWindowContext(
                        reason: "Excluded app: \(displayName)",
                        appBundleID: bundleID,
                        appName: displayName
                    )
                }
                continue
            }

            // Check 2: Private/incognito redaction via AXTitle markers.
            if config.excludePrivateWindows,
               let ownerPID,
               let bundleID,
               BrowserURLExtractor.isBrowser(bundleID) {
                let windowCacheKey = normalizedWindowCacheKey(windowName: windowName, ownerName: ownerName)
                let privateCacheKey = "\(ownerPID)|\(windowCacheKey.lowercased())"

                let usedCache: Bool
                let usedPIDModeCache: Bool
                let rawAXDetectionResult: Bool?
                let rawAppleScriptModeDetectionResult: Bool?
                let detectedByAXOrCache: Bool
                if let cached = privateWindowRedactionCache[privateCacheKey] {
                    usedCache = true
                    usedPIDModeCache = false
                    rawAXDetectionResult = cached
                    rawAppleScriptModeDetectionResult = nil
                    detectedByAXOrCache = cached
                } else {
                    usedCache = false
                    rawAXDetectionResult = PrivateWindowDetector.isPrivateWindowViaAXTitle(
                        pid: ownerPID,
                        windowTitle: windowName,
                        bundleID: bundleID
                    )
                    let axDetected = rawAXDetectionResult ?? false
                    if axDetected {
                        usedPIDModeCache = false
                        rawAppleScriptModeDetectionResult = nil
                    } else if let cachedModeResult = privateModeByPID[ownerPID] {
                        usedPIDModeCache = true
                        rawAppleScriptModeDetectionResult = cachedModeResult
                    } else if privateModeMissByPID.contains(ownerPID) {
                        usedPIDModeCache = true
                        rawAppleScriptModeDetectionResult = nil
                    } else {
                        usedPIDModeCache = false
                        rawAppleScriptModeDetectionResult = await BrowserURLExtractor.isPrivateModeViaAppleScript(
                            bundleID: bundleID,
                            pid: ownerPID,
                            windowCacheKey: windowCacheKey
                        )
                        if let modeResult = rawAppleScriptModeDetectionResult {
                            privateModeByPID[ownerPID] = modeResult
                        } else {
                            privateModeMissByPID.insert(ownerPID)
                        }
                    }
                    let detected = axDetected || (rawAppleScriptModeDetectionResult ?? false)
                    privateWindowRedactionCache[privateCacheKey] = detected
                    detectedByAXOrCache = detected
                }

                var sourceLabel = usedCache ? "cache" : "ax"
                if !usedCache, rawAXDetectionResult != true, rawAppleScriptModeDetectionResult == true {
                    sourceLabel = "applescript-mode"
                } else if !usedCache, rawAXDetectionResult == false, rawAppleScriptModeDetectionResult == false {
                    sourceLabel = "ax+applescript-mode"
                } else if !usedCache, rawAXDetectionResult == false, rawAppleScriptModeDetectionResult == nil, usedPIDModeCache {
                    sourceLabel = "ax+applescript-mode-miss-cache"
                }
                if !usedCache, usedPIDModeCache, sourceLabel == "applescript-mode" || sourceLabel == "ax+applescript-mode" {
                    sourceLabel += "+pid-cache"
                }
                var shouldRedactPrivateWindow = detectedByAXOrCache
                let existingState = privateWindowDecisionStateByWindowID[windowID]

                if detectedByAXOrCache {
                    privateWindowDecisionStateByWindowID[windowID] = PrivateWindowDecisionState(
                        ownerPID: ownerPID,
                        isPrivate: true,
                        observedAt: decisionTimestamp
                    )
                } else if let existingState,
                          existingState.ownerPID == ownerPID,
                          existingState.isPrivate,
                          decisionTimestamp.timeIntervalSince(existingState.observedAt) <= privateWindowPositiveGraceInterval {
                    shouldRedactPrivateWindow = true
                    sourceLabel += "+sticky"
                    tracePrivateRedaction(
                        "sticky-hit windowID=\(windowID) pid=\(ownerPID) age=\(String(format: "%.2fs", decisionTimestamp.timeIntervalSince(existingState.observedAt)))"
                    )
                } else {
                    privateWindowDecisionStateByWindowID[windowID] = PrivateWindowDecisionState(
                        ownerPID: ownerPID,
                        isPrivate: false,
                        observedAt: decisionTimestamp
                    )
                }

                tracePrivateRedaction(
                    "windowID=\(windowID) pid=\(ownerPID) bundleID=\(bundleID) title='\(tracePreview(windowName))' source=\(sourceLabel) axResult=\(rawAXDetectionResult.map { String($0) } ?? "nil") modeResult=\(rawAppleScriptModeDetectionResult.map { String($0) } ?? "nil") redact=\(shouldRedactPrivateWindow)"
                )

                if shouldRedactPrivateWindow {
                    privateBrowserPIDs.insert(ownerPID)
                    excludedIDs.insert(windowID)
                    redactedWindowIDs.insert(windowID)
                    if redactionContextByWindowID[windowID] == nil {
                        redactionWindowOrder.append(windowID)
                        redactionContextByWindowID[windowID] = RedactionWindowContext(
                            reason: "Private/incognito browsing window",
                            appBundleID: bundleID,
                            appName: appDisplayName(ownerName: ownerName, bundleID: bundleID)
                        )
                    }
                    Log.info("[Redaction] Redacting private/incognito window \(windowID) via \(sourceLabel)", category: .capture)
                    continue
                }
            }

            // Check 3: Explicit window title redaction rules (case-insensitive substring)
            if hasWindowTitlePatterns,
               let matchedPattern = firstMatchingPattern(in: windowName, patterns: windowTitlePatterns) {
                excludedIDs.insert(windowID)
                redactedWindowIDs.insert(windowID)
                if redactionContextByWindowID[windowID] == nil {
                    redactionWindowOrder.append(windowID)
                    redactionContextByWindowID[windowID] = RedactionWindowContext(
                        reason: "Window title matches '\(matchedPattern)'",
                        appBundleID: bundleID,
                        appName: appDisplayName(ownerName: ownerName, bundleID: bundleID)
                    )
                }
                Log.info("[Redaction] Redacting window \(windowID) by title rule '\(matchedPattern)'", category: .capture)
                continue
            }

            guard hasBrowserURLPatterns else {
                continue
            }

            // Fast path: if URL rule text appears in the visible window title, redact immediately.
            if let matchedPattern = firstMatchingPattern(in: windowName, patterns: browserURLPatterns) {
                excludedIDs.insert(windowID)
                redactedWindowIDs.insert(windowID)
                if redactionContextByWindowID[windowID] == nil {
                    redactionWindowOrder.append(windowID)
                    redactionContextByWindowID[windowID] = RedactionWindowContext(
                        reason: "Browser URL matches '\(matchedPattern)'",
                        appBundleID: bundleID,
                        appName: appDisplayName(ownerName: ownerName, bundleID: bundleID)
                    )
                }
                Log.info("[Redaction] Redacting window \(windowID) by URL rule text in title '\(matchedPattern)'", category: .capture)
                continue
            }

            // Slow path: query browser URL for this visible browser window.
            guard let ownerPID, let bundleID, BrowserURLExtractor.isBrowser(bundleID) else {
                continue
            }

            let windowCacheKey = normalizedWindowCacheKey(windowName: windowName, ownerName: ownerName)
            let browserURLCacheKey = "\(ownerPID)|\(windowCacheKey.lowercased())"

            let browserURL: String?
            if let cachedResult = browserURLCache[browserURLCacheKey] {
                switch cachedResult {
                case let .found(cachedURL):
                    browserURL = cachedURL
                case .unavailable:
                    browserURL = nil
                }
            } else {
                let fetchedURL = await BrowserURLExtractor.getURL(
                    bundleID: bundleID,
                    pid: ownerPID,
                    windowCacheKey: windowCacheKey
                )
                if let fetchedURL, !fetchedURL.isEmpty {
                    browserURLCache[browserURLCacheKey] = .found(fetchedURL)
                    browserURL = fetchedURL
                } else {
                    browserURLCache[browserURLCacheKey] = .unavailable
                    browserURL = nil
                }
            }

            guard let browserURL,
                  let matchedPattern = firstMatchingPattern(in: browserURL, patterns: browserURLPatterns) else {
                continue
            }

            excludedIDs.insert(windowID)
            redactedWindowIDs.insert(windowID)
            if redactionContextByWindowID[windowID] == nil {
                redactionWindowOrder.append(windowID)
                redactionContextByWindowID[windowID] = RedactionWindowContext(
                    reason: "Browser URL matches '\(matchedPattern)'",
                    appBundleID: bundleID,
                    appName: appDisplayName(ownerName: ownerName, bundleID: bundleID)
                )
            }
            Log.info("[Redaction] Redacting window \(windowID) by URL rule '\(matchedPattern)'", category: .capture)

        }

        for ownerPID in privateBrowserPIDs {
            guard let candidates = privateCompanionCandidatesByPID[ownerPID] else { continue }
            for candidate in candidates {
                guard !excludedIDs.contains(candidate.windowID) else { continue }

                excludedIDs.insert(candidate.windowID)
                redactedWindowIDs.insert(candidate.windowID)
                if redactionContextByWindowID[candidate.windowID] == nil {
                    redactionWindowOrder.append(candidate.windowID)
                    redactionContextByWindowID[candidate.windowID] = RedactionWindowContext(
                        reason: "Private/incognito companion window",
                        appBundleID: candidate.bundleID,
                        appName: appDisplayName(ownerName: candidate.ownerName, bundleID: candidate.bundleID)
                    )
                }

                tracePrivateRedaction(
                    "companion-redaction windowID=\(candidate.windowID) pid=\(ownerPID)"
                )
                Log.info(
                    "[Redaction] Redacting private/incognito companion window \(candidate.windowID) for pid \(ownerPID)",
                    category: .capture
                )
            }
        }

        privateWindowDecisionStateByWindowID = privateWindowDecisionStateByWindowID.filter { windowID, state in
            if seenWindowIDs.contains(windowID) {
                return true
            }

            return decisionTimestamp.timeIntervalSince(state.observedAt) <= privateWindowStateRetentionInterval
        }

        return ExclusionComputationResult(
            excludedWindowIDs: excludedIDs,
            redactedWindowIDs: redactedWindowIDs,
            redactionContextByWindowID: redactionContextByWindowID,
            redactionWindowOrder: redactionWindowOrder,
            visibleWindowContext: visibleWindowContext,
            captureBlockReason: captureBlockReason
        )
    }

    /// Get bundle ID for a process ID
    private func bundleIDForPID(_ pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.bundleIdentifier
    }

    private func shouldConsiderWindowForCapture(
        _ windowInfo: [String: Any],
        displayBounds: CGRect
    ) -> Bool {
        let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { return false }

        let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 0
        guard alpha > 0 else { return false }

        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
        guard isOnScreen else { return false }

        guard let windowBounds = windowBounds(from: windowInfo), windowBounds.intersects(displayBounds) else {
            return false
        }

        return true
    }

    private func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat,
              width > 1,
              height > 1 else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func normalizedPatterns(_ patterns: [String]) -> [String] {
        patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { patternHasContent($0) }
    }

    private func firstMatchingPattern(in value: String, patterns: [String]) -> String? {
        guard !value.isEmpty else { return nil }
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard patternHasContent(pattern) else { continue }

            if value.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return pattern
            }
        }
        return nil
    }

    private func patternHasContent(_ pattern: String) -> Bool {
        pattern.contains(where: { !$0.isWhitespace })
    }

    private func tracePrivateRedaction(_ : String) {}

    private func tracePreview(_ value: String, limit: Int = 180) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if collapsed.count <= limit {
            return collapsed
        }

        return String(collapsed.prefix(limit)) + "..."
    }

    private func normalizedWindowCacheKey(windowName: String, ownerName: String) -> String {
        let trimmedWindowName = windowName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWindowName.isEmpty {
            return trimmedWindowName
        }
        return ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedWindowTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    private func appDisplayName(ownerName: String, bundleID: String?) -> String {
        let normalizedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedOwnerName.isEmpty, normalizedOwnerName.lowercased() != "unknown" {
            return normalizedOwnerName
        }

        if let bundleID {
            let fallbackName = bundleID
                .split(separator: ".")
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let fallbackName, !fallbackName.isEmpty {
                return fallbackName
            }
        }

        return "this app"
    }

    private func logCapturePauseIfNeeded(reason: String) {
        guard lastCaptureBlockReason != reason else { return }
        lastCaptureBlockReason = reason
        Log.info("[CapturePause] Skipping capture while screen state is blocked (\(reason))", category: .capture)
    }

    private func logCaptureResumeIfNeeded() {
        guard let previousReason = lastCaptureBlockReason else { return }
        lastCaptureBlockReason = nil
        Log.info("[CapturePause] Resuming capture after blocked state ended (\(previousReason))", category: .capture)
    }

    nonisolated static func captureBlockReason(ownerName: String, bundleID: String?) -> String? {
        let normalizedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedOwnerName == "loginwindow" || normalizedBundleID == "com.apple.loginwindow" {
            return "loginwindow-visible"
        }

        if normalizedOwnerName == "screensaverengine" ||
            normalizedOwnerName == "screen saver engine" ||
            normalizedBundleID == "com.apple.screensaver.engine" ||
            normalizedBundleID == "com.apple.screensaver.engine.legacyscreensaver" {
            return "screensaver-visible"
        }

        return nil
    }

    private func summarizeRedaction(
        for visibleRedactedWindowIDs: Set<CGWindowID>,
        contextByWindowID: [CGWindowID: RedactionWindowContext],
        redactionOrder: [CGWindowID]
    ) -> RedactionSummary? {
        let orderedVisibleWindowIDs = redactionOrder.filter { visibleRedactedWindowIDs.contains($0) }
        guard let firstWindowID = orderedVisibleWindowIDs.first else { return nil }

        let firstContext = contextByWindowID[firstWindowID] ?? RedactionWindowContext(
            reason: "Redaction rule matched",
            appBundleID: nil,
            appName: nil
        )

        let firstReason = firstContext.reason
        let additionalCount = max(0, orderedVisibleWindowIDs.count - 1)
        guard additionalCount > 0 else {
            return RedactionSummary(
                reason: firstReason,
                appBundleID: firstContext.appBundleID,
                appName: firstContext.appName
            )
        }

        let windowLabel = additionalCount == 1 ? "window" : "windows"
        return RedactionSummary(
            reason: "\(firstReason) (+\(additionalCount) more \(windowLabel))",
            appBundleID: firstContext.appBundleID,
            appName: firstContext.appName
        )
    }

    /// Capture with window filtering using CGWindowListCreateImageFromArray
    private func captureWithFiltering(
        displayID: CGWindowID,
        excludedWindowIDs: Set<CGWindowID>,
        forceMasking: Bool
    ) -> FilteredCaptureResult? {
        // If no exclusions, use simple display capture
        if excludedWindowIDs.isEmpty {
            guard let image = CGDisplayCreateImage(displayID) else { return nil }
            return FilteredCaptureResult(image: image, visibleExcludedWindowIDs: [])
        }

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            guard let image = CGDisplayCreateImage(displayID) else { return nil }
            return FilteredCaptureResult(image: image, visibleExcludedWindowIDs: [])
        }

        if forceMasking {
            return captureWithMasking(displayID: displayID, excludedWindowIDs: excludedWindowIDs, windowList: windowList)
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
            guard let image = CGDisplayCreateImage(displayID) else { return nil }
            return FilteredCaptureResult(image: image, visibleExcludedWindowIDs: [])
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
            return FilteredCaptureResult(image: image, visibleExcludedWindowIDs: [])
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
    ) -> FilteredCaptureResult? {
        // Capture the full screen first
        guard let fullScreenImage = CGDisplayCreateImage(displayID) else {
            Log.error("[Masking] Failed to capture full screen", category: .capture)
            return nil
        }

        // If nothing to exclude, return the full screen capture
        if excludedWindowIDs.isEmpty {
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        let redactionSurfaceBytes = Self.estimatedImageSurfaceBytes(
            width: fullScreenImage.width,
            height: fullScreenImage.height,
            copies: 3
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerRedactionSurfaceTag,
            bytes: redactionSurfaceBytes,
            count: redactionSurfaceBytes > 0 ? 3 : 0,
            unit: "surfaces",
            function: "capture.screen_capture",
            kind: "redaction-surface",
            note: "estimated-native"
        )
        defer {
            MemoryLedger.set(
                tag: Self.memoryLedgerRedactionSurfaceTag,
                bytes: 0,
                count: 0,
                unit: "surfaces",
                function: "capture.screen_capture",
                kind: "redaction-surface",
                note: "estimated-native"
            )
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
        var visibleExcludedRegions: [(windowID: CGWindowID, rect: CGRect)] = []

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
                visibleExcludedRegions.append((window.windowID, region))
                Log.debug("[Masking] Visible region for window \(window.windowID): \(region)", category: .capture)
            }
        }

        // If no visible regions to mask, return the full capture
        if visibleExcludedRegions.isEmpty {
            Log.info("[Masking] Excluded windows are fully occluded, no masking needed", category: .capture)
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        // Create a new image with visible excluded regions blurred
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
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        // Draw the full screen image
        context.draw(fullScreenImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let fullImageRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let blurredImage = makeBlurredRedactionImage(from: fullScreenImage) else {
            Log.error("[Masking] Failed to create blurred redaction image", category: .capture)
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        var maskPaths: [CGPath] = []
        for (_, rect) in visibleExcludedRegions {
            // Flip Y coordinate for CGContext (origin is bottom-left)
            let flippedRect = CGRect(
                x: rect.origin.x,
                y: CGFloat(height) - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )

            let strokeInset = redactionBorderWidth / 2
            let blurRect = flippedRect.insetBy(dx: strokeInset, dy: strokeInset)
            guard blurRect.width > 1, blurRect.height > 1 else { continue }

            let maskPath = CGPath(
                roundedRect: blurRect,
                cornerWidth: redactionMaskCornerRadius,
                cornerHeight: redactionMaskCornerRadius,
                transform: nil
            )
            maskPaths.append(maskPath)
        }

        if maskPaths.isEmpty {
            Log.info("[Masking] Visible regions were too small after insetting, skipping blur masking", category: .capture)
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        // Composite the blurred source once using a combined clip across all masked regions.
        context.saveGState()
        for maskPath in maskPaths {
            context.addPath(maskPath)
        }
        context.clip()
        context.draw(blurredImage, in: fullImageRect)
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.setLineWidth(redactionBorderWidth)
        for maskPath in maskPaths {
            context.addPath(maskPath)
        }
        context.strokePath()
        context.restoreGState()

        guard let maskedImage = context.makeImage() else {
            Log.error("[Masking] Failed to create masked image", category: .capture)
            return FilteredCaptureResult(image: fullScreenImage, visibleExcludedWindowIDs: [])
        }

        let visibleExcludedWindowIDs = Set(visibleExcludedRegions.map { $0.windowID })
        Log.info("[Masking] Successfully masked \(visibleExcludedRegions.count) visible regions", category: .capture)
        return FilteredCaptureResult(image: maskedImage, visibleExcludedWindowIDs: visibleExcludedWindowIDs)
    }

    private func makeBlurredRedactionImage(from image: CGImage) -> CGImage? {
        let inputImage = CIImage(cgImage: image)
        guard let gaussianBlur = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }

        gaussianBlur.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
        gaussianBlur.setValue(redactionBlurRadius, forKey: kCIInputRadiusKey)

        guard let blurredOutput = gaussianBlur.outputImage?.cropped(to: inputImage.extent) else {
            return nil
        }

        return redactionCIContext.createCGImage(blurredOutput, from: inputImage.extent)
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

    private static func estimatedImageSurfaceBytes(width: Int, height: Int, copies: Int64 = 1) -> Int64 {
        guard width > 0, height > 0, copies > 0 else { return 0 }
        let rowBytes = Int64(width) * 4
        let bytes = rowBytes * Int64(height)
        return max(0, bytes * copies)
    }

    private func updatePersistentCaptureNativeLedger() {
        let displaySurfaceBytes = max(0, lastDisplaySurfaceBytes)
        let ioSurfacePoolBytes = displaySurfaceBytes > 0 ? displaySurfaceBytes * 2 : 0
        let compositorBackingBytes = displaySurfaceBytes

        MemoryLedger.set(
            tag: Self.memoryLedgerIOSurfacePoolTag,
            bytes: ioSurfacePoolBytes,
            count: ioSurfacePoolBytes > 0 ? 2 : 0,
            unit: "surfaces",
            function: "capture.screen_capture",
            kind: "iosurface-pool",
            note: "proxy-native"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerCompositorBackingTag,
            bytes: compositorBackingBytes,
            count: compositorBackingBytes > 0 ? 1 : 0,
            unit: "surfaces",
            function: "capture.screen_capture",
            kind: "compositor-backing",
            note: "proxy-native"
        )
    }
}
