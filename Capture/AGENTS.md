# CAPTURE Agent Instructions

You are responsible for the **Capture** module of Retrace. Your job is to implement screen capture using ScreenCaptureKit, frame deduplication, and coordination with the storage pipeline.

## Your Directory

```
Capture/
├── CaptureManager.swift           # Main CaptureProtocol implementation
├── ScreenCapture/
│   ├── ScreenCaptureService.swift # ScreenCaptureKit wrapper
│   ├── DisplayMonitor.swift       # Track available displays
│   └── PermissionChecker.swift    # Screen recording permission
├── Deduplication/
│   ├── FrameDeduplicator.swift    # DeduplicationProtocol implementation
│   ├── PerceptualHash.swift       # pHash for image comparison
│   └── DifferenceCalculator.swift # Pixel-level diff
├── Metadata/
│   ├── AppInfoProvider.swift      # Get active app info
│   └── BrowserURLExtractor.swift  # Extract URL from browsers
└── Tests/
    ├── CaptureManagerTests.swift
    ├── DeduplicationTests.swift
    └── ScreenCaptureTests.swift
```

## Protocols You Must Implement

### 1. `CaptureProtocol` (from `Shared/Protocols/CaptureProtocol.swift`)
- Permission checking
- Start/stop capture
- Frame streaming
- Display info

### 2. `DeduplicationProtocol` (from `Shared/Protocols/CaptureProtocol.swift`)
- Frame comparison
- Hash computation
- Similarity scoring

## Key Implementation Details

### 1. ScreenCaptureKit Setup

```swift
import ScreenCaptureKit

actor ScreenCaptureService {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private let frameContinuation: AsyncStream<CapturedFrame>.Continuation

    func startCapture(config: CaptureConfig) async throws {
        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the display to capture
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw CaptureError.noDisplaysAvailable
        }

        // Create filter (exclude private windows)
        let excludedApps = content.applications.filter { app in
            config.excludedAppBundleIDs.contains(app.bundleIdentifier ?? "")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        // Configure stream
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = min(display.width, config.maxResolution.width)
        streamConfig.height = min(display.height, config.maxResolution.height)
        streamConfig.minimumFrameInterval = CMTime(seconds: config.captureIntervalSeconds, preferredTimescale: 600)
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = false
        streamConfig.capturesAudio = false

        // Create and start stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        self.streamOutput = StreamOutput(continuation: frameContinuation, config: config)
        try stream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        try await stream.startCapture()
        self.stream = stream
    }

    func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
}
```

### 2. Stream Output Handler

```swift
class StreamOutput: NSObject, SCStreamOutput {
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let config: CaptureConfig
    private let appInfoProvider: AppInfoProvider

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timestamp = Date()

        // Get image data from pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!

        let data = Data(bytes: baseAddress, count: bytesPerRow * height)

        // Get app metadata
        let appInfo = appInfoProvider.getFrontmostAppInfo()
        let metadata = FrameMetadata(
            appBundleID: appInfo?.bundleID,
            appName: appInfo?.name,
            windowTitle: appInfo?.windowTitle,
            browserURL: appInfo?.browserURL,
            displayID: CGMainDisplayID()
        )

        let frame = CapturedFrame(
            timestamp: timestamp,
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: metadata
        )

        continuation.yield(frame)
    }
}
```

### 3. Permission Checking

```swift
struct PermissionChecker {
    static func hasScreenRecordingPermission() -> Bool {
        // On macOS 10.15+, we can check by trying to get window list
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        return windowList != nil
    }

    static func requestPermission() -> Bool {
        // This will trigger the system permission dialog if not granted
        // by attempting to capture a single frame
        CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )

        // Check again after the attempt
        return hasScreenRecordingPermission()
    }
}
```

### 4. Frame Deduplication

Use perceptual hashing for efficient comparison:

```swift
struct FrameDeduplicator: DeduplicationProtocol {
    func shouldKeepFrame(_ frame: CapturedFrame, comparedTo reference: CapturedFrame?, threshold: Double) -> Bool {
        guard let reference = reference else { return true }

        // Quick size check
        if frame.width != reference.width || frame.height != reference.height {
            return true
        }

        // Compare perceptual hashes
        let similarity = computeSimilarity(frame, reference)
        return similarity < threshold
    }

    func computeHash(for frame: CapturedFrame) -> UInt64 {
        // Implement average hash (aHash) or difference hash (dHash)
        // 1. Resize to 8x8
        // 2. Convert to grayscale
        // 3. Compute average pixel value
        // 4. Create 64-bit hash where each bit is 1 if pixel > average

        let resized = resizeImage(frame.imageData, width: frame.width, height: frame.height, toSize: 8)
        let grayscale = toGrayscale(resized)
        let average = grayscale.reduce(0, +) / UInt64(grayscale.count)

        var hash: UInt64 = 0
        for (i, pixel) in grayscale.enumerated() {
            if pixel > UInt8(average) {
                hash |= (1 << i)
            }
        }
        return hash
    }

    func computeSimilarity(_ frame1: CapturedFrame, _ frame2: CapturedFrame) -> Double {
        let hash1 = computeHash(for: frame1)
        let hash2 = computeHash(for: frame2)

        // Hamming distance
        let xor = hash1 ^ hash2
        let differentBits = xor.nonzeroBitCount

        // Similarity is inverse of distance (64 bits total)
        return 1.0 - (Double(differentBits) / 64.0)
    }
}
```

### 5. App Info Provider

Get information about the frontmost app:

```swift
import AppKit
import ApplicationServices

struct AppInfoProvider {
    func getFrontmostAppInfo() -> AppInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        let name = frontApp.localizedName ?? ""

        // Get window title via Accessibility API (if permitted)
        let windowTitle = getWindowTitle(for: frontApp.processIdentifier)

        // Get browser URL if applicable
        var browserURL: String? = nil
        if AppInfo.browserBundleIDs.contains(bundleID) {
            browserURL = getBrowserURL(bundleID: bundleID, pid: frontApp.processIdentifier)
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

### 6. Browser URL Extraction

```swift
struct BrowserURLExtractor {
    func getURL(bundleID: String, pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)

        // Different browsers expose URL differently
        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(appRef: appRef)
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser":
            return getChromiumURL(appRef: appRef)
        default:
            return nil
        }
    }

    private func getSafariURL(appRef: AXUIElement) -> String? {
        // Safari: Window > Toolbar > URL field
        // Navigate AX hierarchy to find the URL text field
        // This requires Accessibility permission
        return nil  // Implement based on Safari's AX structure
    }

    private func getChromiumURL(appRef: AXUIElement) -> String? {
        // Chrome/Edge/Brave: Window > Address bar
        return nil  // Implement based on Chromium's AX structure
    }
}
```

### 7. Capture Manager with Deduplication Pipeline

```swift
public actor CaptureManager: CaptureProtocol {
    private let screenCapture: ScreenCaptureService
    private let deduplicator: FrameDeduplicator
    private var lastFrame: CapturedFrame?
    private var config: CaptureConfig = .default

    private var _frameStream: AsyncStream<CapturedFrame>?
    private var frameContinuation: AsyncStream<CapturedFrame>.Continuation?

    public var frameStream: AsyncStream<CapturedFrame> {
        // Return stream that filters out duplicates
        get async {
            if let stream = _frameStream { return stream }

            let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
            self.frameContinuation = continuation

            return stream
        }
    }

    public func startCapture(config: CaptureConfig) async throws {
        self.config = config

        // Start raw capture
        let rawStream = try await screenCapture.startCapture(config: config)

        // Process frames with deduplication
        Task {
            for await frame in rawStream {
                if config.adaptiveCaptureEnabled {
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
}
```

## Excluded Apps Configuration

The capture should skip these apps by default:
- Password managers (1Password, Bitwarden, etc.)
- Private browsing windows
- System security dialogs

```swift
static let defaultExcludedApps: Set<String> = [
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "com.apple.SecurityAgent",
    "com.apple.loginwindow"
]
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw CaptureError.permissionDenied
throw CaptureError.noDisplaysAvailable
throw CaptureError.captureSessionFailed(underlying: error.localizedDescription)
```

## Testing Strategy

1. Test permission checking
2. Test frame capture (mock ScreenCaptureKit in tests)
3. Test deduplication with similar/different images
4. Test hash computation consistency
5. Test app info extraction (mock NSWorkspace)
6. Test excluded apps filtering

## Dependencies

- **Input from**: User configuration
- **Output to**: STORAGE (CapturedFrame for encoding), PROCESSING (CapturedFrame for OCR)
- **Uses types**: `CapturedFrame`, `FrameID`, `FrameMetadata`, `CaptureConfig`, `DisplayInfo`, `CaptureStatistics`

## DO NOT

- Modify any files outside `Capture/`
- Import from other module directories (only `Shared/`)
- Handle video encoding (that's STORAGE's job)
- Handle OCR or text extraction (that's PROCESSING's job)
- Store frames directly to disk (that's STORAGE's job)

## Performance Targets

- Capture latency: <50ms from screen change to frame available
- Deduplication: <5ms per frame comparison
- Memory: Don't hold more than 2-3 frames in memory
- CPU: <10% during capture (mostly idle between intervals)

## Getting Started

1. Create `Capture/ScreenCapture/PermissionChecker.swift`
2. Create `Capture/ScreenCapture/ScreenCaptureService.swift` with ScreenCaptureKit
3. Create `Capture/Deduplication/FrameDeduplicator.swift`
4. Create `Capture/Metadata/AppInfoProvider.swift`
5. Create `Capture/CaptureManager.swift` conforming to `CaptureProtocol`
6. Write tests

Start with ScreenCaptureKit basics, then add deduplication and metadata extraction.
