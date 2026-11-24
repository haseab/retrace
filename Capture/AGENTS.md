# CAPTURE Agent Instructions

You are responsible for the **Capture** module of Retrace. Your job is to implement screen capture using **CGWindowListCapture**, frame deduplication, and app metadata extraction.

**Status**: ✅ Fully implemented using CGWindowListCapture API (legacy, no privacy indicator). No audio capture yet.

## Your Directory

```
Capture/
├── CaptureManager.swift           # Main CaptureProtocol implementation
├── BoundedFrameChannel.swift      # Awaited capture handoff, count and pixel-byte budgets
├── ScreenCapture/
│   ├── CaptureFrameCandidate.swift # Defer BGRA materialization for exact native duplicates
│   ├── CGWindowListCapture.swift  # Legacy CGWindowList API wrapper
│   ├── CapturePerformanceDiagnostics.swift # Bounded production stage timings, slow events, and process snapshots
│   ├── ExcludedWindowMasker.swift # Full-bounds masking; failure returns no screenshot
│   ├── PrivateWindowDetector.swift # Private-window accessibility heuristics
│   ├── ConferenceFaceBlurProcessor.swift # Vision face detection + irreversible conference-call face blur
│   ├── DisplayMonitor.swift       # Track available displays
│   ├── DisplaySwitchMonitor.swift # Detect display changes
│   ├── MouseClickMonitor.swift    # Post-dispatch left-click capture monitor
│   ├── ScreenLockStateMonitor.swift # Lock/screensaver state tracking
│   ├── PrivateWindowMonitor.swift # Detect private browsing
│   └── PermissionChecker.swift    # Screen recording permission
├── Deduplication/
│   └── FrameDeduplicator.swift    # Pixel-sampling DeduplicationProtocol implementation
├── Metadata/
│   ├── WindowOCRGeometry.swift # Front-to-back visible application-window crop bounds
│   ├── AccessibilitySnapshotCollector.swift # Bounded capture-time AX reference collection
│   ├── AccessibilityWindowMatcher.swift # Unique geometry/title window matching
│   ├── AppInfoProvider.swift      # Get active app info via NSWorkspace
│   ├── ForegroundWindowSelection.swift # Reject sharing helpers and background processes for attribution
│   ├── BrowserURLExtractor.swift  # Extract URL from browsers (AX API)
│   ├── ConferenceCallObservation.swift # Injectable observations and deterministic consent replay
│   ├── ConferenceWindowImageProvider.swift # Isolated window images and face-mask projection
│   ├── ConferenceCallActivityProvider.swift # Bounded window-specific active-call accessibility lookup
│   └── ConferenceSessionPrivacyPolicy.swift # Conferencing-session rules + session-scoped consent
└── Tests/
    ├── WindowOCRGeometryTests.swift # Fullscreen, overlap, exclusion, scaling and sliver selection checks
    ├── WindowLookupReuseTests.swift # Lookup reuse, failure handling and real graphics/file regression checks
    ├── AccessibilityWindowMatcherTests.swift # Recorded TextEdit window-selection regression
    ├── AccessibilityInspectorTest.swift
    ├── BrowserURLAppleScriptCoordinatorTests.swift
    ├── ExcludedWindowMaskerTests.swift # Pixel coverage and injected render-failure regression coverage
    ├── ForegroundWindowSelectionTests.swift
    ├── ConferencePrivacyPixelReplayTests.swift # Real Vision and rendering regressions using a controlled gallery
    ├── ConferenceCallObservationTests.swift # Consent recovery, expiry, and isolation
    ├── ConferenceROIPlannerTests.swift
    ├── ConferenceSessionPrivacyPolicyTests.swift
    ├── CaptureFrameCandidateTests.swift # Committed screenshot pixel/layout comparison
    ├── CapturePerformanceDiagnosticsTests.swift # Summary bounds, rate limits, and production log field retention
    ├── CaptureTriggerSchedulingTests.swift
    └── DeduplicationTests.swift
```

## Conference consent replay boundary

- `ConferenceCallObserving` supplies active, ended, or unknown observations. The AX adapter treats missing controls and failed lookups as unknown.
- Capture injects the observer and observation clock; `ConferenceCallConsentState.observe` accepts explicit time for deterministic replay tests without live calls.
- Unknown observations retain existing consent for a bounded interval from the last verified active observation, but apply blur and cannot accept new consent. Recovery of the same identity restores bypass; expiration, disappearance, confirmed end, and reset revoke it.
- Capture uses `max(8 seconds, 3 capture intervals)` for observation freshness and uncertainty retention. Repeated unknown results never extend the interval.
- `applyConferencePrivacy` accepts image/window/display inputs for pixel-stage replay; the pixel tests build a controlled gallery from the existing CreatorProfile photo asset. Optional measurements use `RETRACE_MEASURE_FACE_BLUR=1`.
- When an unconsented window overlaps a consented foreground window, detect faces in its isolated window image and project masks back to the desktop. Bracket the desktop capture with source snapshots; only unchanged pixel content, owner PID, and geometry may supply masks or a no-face result. Capture at most two source surfaces per frame. Missing, changed, or transparently unreadable sources retain desktop-ROI protection. Preserve unclipped ellipse bounds for partially off-screen windows.
- Window identity changes and independent windows remain isolated; this boundary does not infer that sibling windows belong to one call.
- Run `swift test --filter 'ConferenceCallObservationTests|ConferenceSessionPrivacyPolicyTests|ConferenceROIPlannerTests'` for consent and ROI coverage.

## Production capture performance diagnostics

- `[CapturePerf]` messages use only fixed labels and numeric/boolean values, with no titles, URLs, call/window IDs, or pixels. They use the normal production log and remain in feedback exports when full logs are included.
- Native capture and the outer pipeline each aggregate one minute of counters. Latency distributions retain at most 256 samples per stage; p50/p95 describe that recent sample window, while maxima and counts span the whole reporting interval. Stage timings are summed per capture, including all URL lookups or call windows in that capture. A final partial summary is flushed on stop.
- Native summaries cover metadata, URL AX versus AppleScript fallback, call observation outcomes, source snapshots, screenshot capture, OCR geometry, capture-time AX, Vision detection, rendering, and consent bypass/fallback counts. The outer pipeline adds scheduling lateness, pixel comparison/materialization, frame handling, trigger mix, and kept/not-kept counts.
- Slow events are limited to one every 30 seconds per recorder; later reports show suppressed event counts. The thresholds are diagnostic only and never change privacy decisions or skip work.
- CPU and current RSS are sampled only when native reports emit. CPU uses `getrusage` timeval seconds and is expressed as percent of one core over the stated process window, including all Retrace work. It does not measure Zoom/browser CPU, GPU/ANE time, or prove another application's slowdown. Thermal codes: 0 nominal, 1 fair, 2 serious, 3 critical.
- Timings use a monotonic clock. Keep per-frame collection to clocks and bounded numeric counters; never scan other processes or add per-frame disk logging for these diagnostics.

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

### 3. Frame Deduplication (Pixel Sampling)

`FrameDeduplicator.swift` implements `DeduplicationProtocol` using direct pixel sampling:

- `shouldKeepFrame` keeps the first frame and frames whose dimensions change, then compares similarity against the configured threshold.
- `computeSimilarity` samples a uniform two-dimensional grid of pixels and compares RGB channel differences with a tolerance.
- `computeHash` provides a lightweight checksum of sampled RGB values for the protocol's hash API. It is not a dHash implementation.

Capture deduplication is implemented entirely in `FrameDeduplicator`.

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
2. Read `FrameDeduplicator.swift` - pixel-sampling deduplication logic
3. Read `AppInfoProvider.swift` - metadata extraction
4. Read `CaptureManager.swift` - protocol conformance + pipeline

The implementation is complete. Focus on understanding the existing code rather than rewriting.

- CaptureFrameCandidate is module-local and contains the already privacy-filtered CGImage. Only exact pixel/render-property equality permits BGRA reuse. Keep near-duplicate thresholds and mouse-movement decisions unchanged; account for the single retained native image.

### Capture window-list reuse

Exclusion classification collects normal on-screen, non-transparent window IDs from its all-window snapshot, in window-server order, and removes excluded IDs before array capture. The successful array path does not fetch a second window list. Do not reuse old bounds for masking: privacy/AX checks can suspend while windows move. Forced masking, known-broken arrays, empty included arrays, and array failure must fetch fresh on-screen geometry and drop the frame if unavailable. No snapshot is cached across captures. Existing full-bounds masking and masking-failure behavior remain unchanged.

Capture-time AX: `Metadata/AccessibilitySnapshotCollector.swift` reads the matched primary window immediately after screenshot capture, before face processing. The AX window is selected by unique bounds/title match across the app’s bounded window list, rather than assuming its focused window is the captured window. Title matching removes the known owner application suffix (for example, " - Google Chrome") and normalizes whitespace/case while preserving document identity. Ambiguous matches are rejected. Snapshot bounds are screenshot pixels; window identity/geometry is rechecked. Secure, hidden, offscreen, and excluded primary-window content is skipped. Rectangle overlaps alone do not establish opacity: overlapping text regions must match opaque pixels in the actual captured frame and a window-only image. Missing/misaligned images or exhausted verification budgets reject those regions. Verification allows only a two-level per-channel rendering tolerance, checks every pixel, and is bounded to two million region pixels plus a best-effort 50 ms loop. AX runs on the capture actor, with a short messaging timeout and bounded best-effort work. `CaptureFrameCandidate` and metadata enrichment preserve the snapshot.

Automatic browser URL AppleScripts preflight Apple Events authorization without prompting. Missing/denied grants fall back to AX instead of blocking screenshot capture behind a 45-second permission dialog. Explicit permission requests remain in onboarding/settings. `BrowserURLAppleScriptCoordinatorTests` includes the real missing-target preflight case.

### Window-aware OCR geometry

`Metadata/WindowOCRGeometry.swift` selects at most 16 meaningfully visible layer-zero application windows in front-to-back order. Each entry is the full clipped window bounds in normalized top-left screenshot coordinates; entries may overlap. Fully covered windows, exposed slivers below 1% of the window area, tiny windows and non-normal system/status-item layers do not create OCR jobs. No background fragments are appended. Screen-sized surfaces owned by background accessory/system processes are ignored as crops and occluders; the captured primary application and Retrace itself remain eligible, including with a hidden Dock icon. This ownership check caches each PID once per frame and never overrides privacy exclusions. Excluded windows consume visible area but are never selected; capture's privacy-masked screenshot remains the only pixel source. Processing masks preceding windows inside each lower crop, preserving one Vision request per selected window. Geometry over budget falls back to legacy OCR.

The privacy array helper still avoids extra lookups. The OCR feature separately takes one best-effort on-screen geometry snapshot immediately after image acquisition, before slow AX/face work; it must never replace the fresh bounds used by privacy masking. The window list and screenshot are separate Window Server calls, so fast motion can race them. Only already privacy-filtered screenshot pixels are passed to OCR; no individual window image is captured.

## Capture backpressure

- The capture-to-storage channel queues at most eight frames and 64 MiB of pixel data. Screenshots larger than the byte budget use direct consumer handoff. The sole capture producer may retain one additional screenshot while suspended; the consumer and per-display dedup/native-image caches have separate memory costs.
- Await channel sends inside the existing single capture batch. Never create a Task per screenshot or accumulate blocked producers. Pending triggers coalesce into one request while capture waits.
- The AsyncStream adapter uses unfolding/pull semantics, with no second prefetch buffer. Deduplication state and captured outcomes advance only after channel admission succeeds.
- Production capture awaits capture-time WAL persistence before channel admission. Normal coordinator stop waits for the in-flight admission and drains the channel; emergency/consumer cancellation aborts it. Aborted receipt-bearing frames remain recoverable from WAL. Session generations prevent an old resumed capture from mutating a restarted session.
- Run `swift test --filter 'BoundedFrameChannelTests|testFullQueuePausesCapture'` for screenshot FIFO, byte limits, oversized handoff, cancellation, capture pause/resume and stop/restart checks.

- Periodic scheduling occurs once after the complete display batch, including empty discovery and backend failures. Never make the next retry depend on successfully capturing a display.
- The coordinator installs the persistence handler before starting capture. Journal failures stop capture instead of falling back to unjournaled delivery. Standalone capture tests can omit the handler.

- With simultaneous multi-monitor recording enabled, primary window metadata comes from the first eligible on-screen application window on each captured display in front-to-back order, independent of global app focus. Single-display mode retains foreground-app selection. Keep desktop, hidden, transparent, overlay, and Computer Use window exclusions; an empty display must not borrow app metadata from a neighbour.

### Display writer lifecycle

The coordinator consumes `CaptureManager.eventStream` instead of simultaneously consuming
`frameStream`. Display-set changes share the bounded FIFO with screenshots, after all
previously accepted receipts. Retire journal ownership before publishing that change;
finalize encoding only on the consumer side. Empty display discovery must still publish
an empty set, without waiting for a subsequent screenshot. Lifecycle events count toward
the queue item limit and never spawn additional producers.
