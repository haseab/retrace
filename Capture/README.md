# Capture Module

**Owner**: CAPTURE Agent
**Status**: ✅ Implementation Complete
**Instructions**: See [CLAUDE-CAPTURE.md](../CLAUDE-CAPTURE.md)

## Overview

The Capture module handles screen recording, frame deduplication, and metadata extraction for Retrace.

**Implemented Features**:
- ✅ ScreenCaptureKit integration for screen capture
- ✅ Perceptual hashing (dHash) for frame deduplication
- ✅ App metadata extraction (active app, window title, browser URL)
- ✅ Permission handling (screen recording + accessibility)
- ✅ Display monitoring and enumeration
- ✅ Comprehensive test coverage

## Quick Start

```swift
let manager = CaptureManager()

// Check permission
guard await manager.hasPermission() else {
    await manager.requestPermission()
    return
}

// Start capture
try await manager.startCapture(config: .default)

// Consume frames
let stream = await manager.frameStream
for await frame in stream {
    print("Frame: \(frame.width)x\(frame.height)")
    print("App: \(frame.metadata.appName ?? "unknown")")
}

// Stop capture
try await manager.stopCapture()
```

## Architecture

```
CaptureManager (actor) - Main coordinator
├── ScreenCaptureService - ScreenCaptureKit wrapper
│   └── StreamOutput - SCStream output handler
├── DisplayMonitor - Display tracking
├── FrameDeduplicator - Deduplication protocol implementation
│   └── PerceptualHash - dHash computation
└── AppInfoProvider - Metadata extraction
    └── BrowserURLExtractor - Browser URL extraction
```

## Implemented Files

```
Capture/
├── CaptureManager.swift              # ✅ Main coordinator (CaptureProtocol)
├── ScreenCapture/
│   ├── PermissionChecker.swift       # ✅ Permission handling
│   ├── DisplayMonitor.swift          # ✅ Display tracking
│   └── ScreenCaptureService.swift    # ✅ ScreenCaptureKit wrapper
├── Deduplication/
│   ├── FrameDeduplicator.swift       # ✅ DeduplicationProtocol impl
│   └── PerceptualHash.swift          # ✅ dHash algorithm
├── Metadata/
│   ├── AppInfoProvider.swift         # ✅ App metadata
│   └── BrowserURLExtractor.swift     # ✅ Browser URL extraction
└── Tests/
    ├── CaptureManagerTests.swift     # ✅ Manager tests
    └── DeduplicationTests.swift      # ✅ Deduplication tests
```

## Configuration

```swift
let config = CaptureConfig(
    captureIntervalSeconds: 2.0,        // Capture every 2 seconds
    adaptiveCaptureEnabled: true,        // Enable deduplication
    deduplicationThreshold: 0.98,        // 98% similarity = duplicate
    maxResolution: .uhd4K,               // Max 4K resolution
    excludedAppBundleIDs: [],            // Apps to exclude
    captureAllDisplays: false            // Main display only
)
```

## Protocols Implemented

- ✅ `CaptureProtocol` - Screen capture lifecycle and frame streaming
- ✅ `DeduplicationProtocol` - Frame comparison and hashing

## Integration Points

**Outputs to**:
- `STORAGE`: CapturedFrame objects for encoding and persistence
- `PROCESSING`: CapturedFrame objects for OCR and text extraction

**Receives from**:
- `APP`: CaptureConfig updates and lifecycle control

## Performance

- Hash computation: <5ms per 1080p frame
- Deduplication: <5ms per frame comparison
- CPU overhead: <10% during capture
- Memory: ~50MB baseline + 2-3 frame buffer

## Documentation

- **Implementation Guide**: [CLAUDE-CAPTURE.md](../CLAUDE-CAPTURE.md)
- **Progress Tracking**: [PROGRESS.md](PROGRESS.md)
- **Full API Documentation**: See inline documentation in source files

## Running Tests

```bash
swift test --filter CaptureTests
```

## Notes for Integration

1. **Frame Format**: BGRA (kCVPixelFormatType_32BGRA) with bytesPerRow alignment
2. **Deduplication**: Frames are pre-filtered - only significant changes are emitted
3. **Concurrency**: CaptureManager is an actor - use async/await
4. **Permissions**: Screen recording is required; Accessibility is optional but recommended
