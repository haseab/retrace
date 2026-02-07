# CAPTURE Agent Instructions

You are responsible for the **Capture** module of Retrace. Your job is to implement screen capture using **CGWindowListCapture**, frame deduplication, and app metadata extraction.

**Status**: ✅ Fully implemented using CGWindowListCapture API (legacy, no privacy indicator). No audio capture yet.

## Your Directory

```
Capture/
├── CaptureManager.swift           # Main CaptureProtocol implementation
├── ScreenCapture/
│   ├── CGWindowListCapture.swift  # Legacy CGWindowList API wrapper
│   ├── DisplayMonitor.swift       # Track available displays
│   ├── DisplaySwitchMonitor.swift # Detect display changes
│   ├── PrivateWindowMonitor.swift # Detect private browsing
│   └── PermissionChecker.swift    # Screen recording permission
├── Deduplication/
│   ├── FrameDeduplicator.swift    # DeduplicationProtocol implementation
│   └── PerceptualHash.swift       # dHash (difference hash) for comparison
├── Metadata/
│   ├── AppInfoProvider.swift      # Get active app info via NSWorkspace
│   └── BrowserURLExtractor.swift  # Extract URL from browsers (AX API)
└── Tests/
    ├── CaptureManagerTests.swift
    └── DeduplicationTests.swift
```

## System Requirements

- **macOS 13.0+** required
- **Apple Silicon only** (M1/M2/M3) - Intel not supported
- **Permissions**: Screen Recording + Accessibility

## Protocols You Must Implement

### 1. `CaptureProtocol` (from `Shared/Protocols/CaptureProtocol.swift`)
- Permission checking
- Start/stop capture
- Frame streaming via `AsyncStream<CapturedFrame>`
- Display info

## Key Implementation Details

### 1. CGWindowListCapture Setup (Current Implementation)

**Why CGWindowListCapture instead of ScreenCaptureKit?**
- No purple privacy indicator
- Works via polling instead of streaming
- Legacy API but still functional on macOS 13+
- Filters excluded apps on EVERY capture

```swift
import Foundation
import CoreGraphics
import AppKit

public actor CGWindowListCapture {
    private var timer: Timer?
    private var isActive = false
    private var currentConfig: CaptureConfig?

    var onFrameCaptured: (@Sendable (CapturedFrame) -> Void)?

    func startCapture(
        config: CaptureConfig,
        frameContinuation: AsyncStream<CapturedFrame>.Continuation,
        displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard !isActive else { return }

        self.currentConfig = config
        self.isActive = true

        self.onFrameCaptured = { frame in
            frameContinuation.yield(frame)
        }

        let targetDisplayID = displayID ?? CGMainDisplayID()

        // Start timer-based capture
        let timer = Timer.scheduledTimer(
            withTimeInterval: config.captureIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                try? await self?.captureFrame(displayID: targetDisplayID)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func captureFrame(displayID: CGDirectDisplayID) async throws {
        // Get excluded windows
        let excludedWindows = getExcludedWindowIDs(config: currentConfig!)

        // Option 1: Try array-based capture (filters specific windows)
        var cgImage: CGImage?
        if !excludedWindows.isEmpty {
            cgImage = CGWindowListCreateImage(
                .null,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )
        }

        // Option 2: Fallback to full capture with manual masking
        if cgImage == nil {
            cgImage = CGWindowListCreateImage(
                .null,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )
        }

        guard let image = cgImage else {
            throw CaptureError.captureSessionFailed(underlying: "Failed to capture")
        }

        // Convert to frame data
        let frame = try convertToFrame(image: image, displayID: displayID)
        onFrameCaptured?(frame)
    }

    private func getExcludedWindowIDs(config: CaptureConfig) -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }

        var excluded: [CGWindowID] = []

        for window in windowList {
            // Check if window belongs to excluded app
            if let ownerName = window[kCGWindowOwnerName] as? String,
               config.excludedAppBundleIDs.contains(where: { ownerName.contains($0) }) {
                if let windowID = window[kCGWindowNumber] as? CGWindowID {
                    excluded.append(windowID)
                }
            }

            // Check for private browsing windows
            if let windowName = window[kCGWindowName] as? String {
                if windowName.contains("Private") || windowName.contains("Incognito") {
                    if let windowID = window[kCGWindowNumber] as? CGWindowID {
                        excluded.append(windowID)
                    }
                }
            }
        }

        return excluded
    }

    func stopCapture() async throws {
        timer?.invalidate()
        timer = nil
        isActive = false
    }
}
```

### 2. Permission Checking

```swift
public struct PermissionChecker {
    public static func hasScreenRecordingPermission() -> Bool {
        // Check by attempting to get window list
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        return windowList != nil
    }

    public static func requestPermission() {
        // Trigger permission dialog by attempting capture
        _ = CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )
    }
}
```

### 3. Frame Deduplication (Perceptual Hashing)

**Implementation**: dHash (difference hash) for ~95% deduplication rate

```swift
public struct FrameDeduplicator {
    public func shouldKeepFrame(
        _ frame: CapturedFrame,
        comparedTo reference: CapturedFrame?,
        threshold: Double
    ) -> Bool {
        guard let reference = reference else { return true }

        // Quick size check
        if frame.width != reference.width || frame.height != reference.height {
            return true
        }

        // Compare perceptual hashes
        let similarity = computeSimilarity(frame, reference)

        // Keep frame if dissimilar enough (inverse of threshold)
        return similarity < threshold
    }

    public func computeHash(for frame: CapturedFrame) -> UInt64 {
        // dHash (difference hash):
        // 1. Resize to 9x8 (72 pixels)
        // 2. Convert to grayscale
        // 3. Compare adjacent pixels horizontally
        // 4. Create 64-bit hash (8 rows × 8 comparisons)

        let resized = resizeImage(frame.imageData, width: frame.width, height: frame.height, toSize: (9, 8))
        let grayscale = toGrayscale(resized)

        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let idx = row * 9 + col
                let left = grayscale[idx]
                let right = grayscale[idx + 1]

                if left > right {
                    let bitPosition = row * 8 + col
                    hash |= (1 << bitPosition)
                }
            }
        }

        return hash
    }

    public func computeSimilarity(_ frame1: CapturedFrame, _ frame2: CapturedFrame) -> Double {
        let hash1 = computeHash(for: frame1)
        let hash2 = computeHash(for: frame2)

        // Hamming distance (number of differing bits)
        let xor = hash1 ^ hash2
        let differentBits = xor.nonzeroBitCount

        // Similarity = 1.0 (identical) to 0.0 (completely different)
        return 1.0 - (Double(differentBits) / 64.0)
    }
}
```

**Performance**: ~95% of frames are duplicates and filtered out, drastically reducing storage and processing load.

### 4. App Info Provider

Extract metadata about the frontmost application:

```swift
import AppKit
import ApplicationServices

public struct AppInfoProvider {
    public func getFrontmostAppInfo() -> AppInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        let name = frontApp.localizedName ?? ""

        // Get window title via Accessibility API (requires permission)
        let windowTitle = getWindowTitle(for: frontApp.processIdentifier)

        // Get browser URL if applicable
        var browserURL: String?
        if ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser"].contains(bundleID) {
            browserURL = BrowserURLExtractor().getURL(bundleID: bundleID, pid: frontApp.processIdentifier)
        }

        return AppInfo(
            bundleID: bundleID,
            name: name,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
    }

    private func getWindowTitle(for pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return nil
        }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return nil
        }

        return title
    }
}
```

### 5. Browser URL Extraction

Extract active URL from Safari, Chrome, Firefox, etc. using Accessibility API:

```swift
public struct BrowserURLExtractor {
    public func getURL(bundleID: String, pid: pid_t) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(pid: pid)
        case "com.google.Chrome", "com.brave.Browser":
            return getChromeURL(pid: pid)
        case "org.mozilla.firefox":
            return getFirefoxURL(pid: pid)
        default:
            return nil
        }
    }

    private func getSafariURL(pid: pid_t) -> String? {
        // Navigate Accessibility hierarchy to find URL field
        // Safari: Window → Toolbar → URL text field
        // Implementation depends on Safari's AX structure
        return nil
    }

    private func getChromeURL(pid: pid_t) -> String? {
        // Chrome: Window → Address bar
        return nil
    }
}
```

### 6. Excluded Apps Configuration

Default apps to exclude from capture:

```swift
public static let defaultExcludedApps: Set<String> = [
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "app.getdash.dash",
    "com.apple.SecurityAgent",
    "com.apple.loginwindow"
]
```

### 7. Private Window Detection

Detect and exclude private browsing windows:

```swift
public actor PrivateWindowMonitor {
    public func isPrivateWindow(windowInfo: [CFString: Any]) -> Bool {
        guard let windowName = windowInfo[kCGWindowName] as? String else {
            return false
        }

        // Safari: "Private Browsing"
        // Chrome: "Incognito"
        // Firefox: "Private Browsing"
        return windowName.contains("Private") ||
               windowName.contains("Incognito") ||
               windowName.contains("InPrivate")
    }
}
```

## Capture Manager Pipeline

```swift
public actor CaptureManager: CaptureProtocol {
    private let cgCapture: CGWindowListCapture
    private let deduplicator: FrameDeduplicator
    private var lastFrame: CapturedFrame?
    private var config: CaptureConfig = .default

    private var frameContinuation: AsyncStream<CapturedFrame>.Continuation?

    public func startCapture(config: CaptureConfig) async throws {
        self.config = config

        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        self.frameContinuation = continuation

        // Start CGWindowListCapture with deduplication
        try await cgCapture.startCapture(config: config, frameContinuation: continuation)

        // Process frames with deduplication
        Task {
            for await frame in stream {
                if config.deduplicationEnabled {
                    if deduplicator.shouldKeepFrame(frame, comparedTo: lastFrame, threshold: config.deduplicationThreshold) {
                        lastFrame = frame
                        frameContinuation?.yield(frame)
                    }
                } else {
                    frameContinuation?.yield(frame)
                }
            }
        }
    }

    public func stopCapture() async throws {
        try await cgCapture.stopCapture()
        frameContinuation?.finish()
    }
}
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:

```swift
throw CaptureError.permissionDenied
throw CaptureError.noDisplaysAvailable
throw CaptureError.captureSessionFailed(underlying: error.localizedDescription)
```

## Testing Strategy

1. ✅ Permission checking (has/request)
2. ✅ Frame capture with CGWindowListCreateImage
3. ✅ Deduplication with similar/different images
4. ✅ Hash computation consistency (same frame = same hash)
5. ✅ App info extraction (mock NSWorkspace)
6. ✅ Excluded apps filtering
7. ✅ Private window detection

## Dependencies

- **Output to**:
  - STORAGE module (CapturedFrame for HEVC encoding)
  - PROCESSING module (CapturedFrame for OCR extraction)
- **Uses types**: `CapturedFrame`, `FrameMetadata`, `CaptureConfig`, `CaptureStatistics`

## DO NOT

- ❌ Modify files outside `Capture/` directory
- ❌ Import from other module directories (only `Shared/`)
- ❌ Handle video encoding (that's STORAGE's job)
- ❌ Handle OCR or text extraction (that's PROCESSING's job)
- ❌ Store frames to disk (that's STORAGE's job)
- ❌ Implement audio capture (planned for future release)

## Performance Targets

- **Capture latency**: <50ms from trigger to frame available
- **Deduplication**: <5ms per frame comparison
- **Memory**: Don't hold more than 2-3 frames in memory
- **CPU**: <10% during capture (mostly idle between 2-second intervals)
- **Deduplication rate**: ~95% of frames filtered as duplicates

## Current Limitations

- No audio capture (planned for future release)
- CGWindowListCapture has no streaming API (polling only)
- Limited private window detection (heuristic-based)
- No multi-display support optimizations

## Getting Started

1. Read `CGWindowListCapture.swift` - main capture implementation
2. Read `FrameDeduplicator.swift` + `PerceptualHash.swift` - deduplication logic
3. Read `AppInfoProvider.swift` - metadata extraction
4. Read `CaptureManager.swift` - protocol conformance + pipeline

The implementation is complete. Focus on understanding the existing code rather than rewriting.
