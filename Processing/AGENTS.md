# PROCESSING Agent Instructions

You are responsible for the **Processing** module of Retrace. Your job is to implement text extraction from captured frames using Vision framework OCR and the Accessibility API.

**Status**: ✅ Vision OCR and Accessibility API fully implemented. **No audio transcription yet** (planned for future release).

## Your Directory

```
Processing/
├── ExtractMemoryInstrumentation.swift # Request-scoped extract residual/handoff instrumentation helper
├── ExtractRequestInstrumentation.swift # Request wrapper that drives extract-stage residual accounting
├── ProcessingManager.swift        # Main ProcessingProtocol implementation
├── FrameProcessingQueue.swift     # OCR pipeline orchestration + queue telemetry
├── URLExtractor.swift             # URL extraction from OCR text
├── OCR/
│   ├── VisionOCR.swift            # Vision framework OCR implementation
│   ├── VisionOCRHelpers.swift     # OCR output structs plus geometry/image helper methods
│   ├── VisionOCRInstrumentation.swift # OCR-local memory ledger runtime and tracker plumbing
│   ├── VisionOCRRequestConfig.swift # OCR request config type plus full-frame/region config builders
│   ├── VisionOCRResidualSupport.swift # OCR residual reset tables and reconciliation helpers
│   ├── FullFrameOCRCache.swift    # Cached full-frame OCR results for region re-OCR
│   ├── OCRTileCache.swift         # Tile cache support for region OCR
│   ├── RegionOCRMerger.swift      # Region OCR merge helpers
│   ├── RegionOCRResult.swift      # Region OCR result/stat models
│   ├── TileChangeDetector.swift   # Tile-based change detection
│   ├── TileGridConfig.swift       # Tile grid tuning
│   └── TileOCRProcessor.swift     # Tile OCR processing helpers
├── Accessibility/
│   ├── AccessibilityService.swift  # AccessibilityProtocol implementation
│   └── TextElementFilter.swift     # Filter relevant text elements
│
├── TextMerger/
│   └── TextMerger.swift            # Combine OCR + AX results
└── Tests/
    ├── ExtractRequestInstrumentationTests.swift # Region tail aggregation and coordinator helper coverage
    ├── InPageURLMetadataResolutionTests.swift # In-page URL metadata retry/resolve coverage
    ├── PhraseLevelRedactionTests.swift        # Manual + automatic OCR phrase-level redaction coverage
    ├── TestLogger.swift                       # Shared processing test logging helpers
    └── _future/
        ├── AccessibilityTests.swift
        └── VisionOCRTests.swift
```

## Protocols You Must Implement

### 1. `ProcessingProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Text extraction (combined OCR + Accessibility)
- Configuration

### 2. `OCRProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Vision framework text recognition

### 3. `AccessibilityProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Permission checking
- Text extraction from AX tree

## Key Implementation Details

### 1. Vision Framework OCR

```swift
import Vision

struct VisionOCR: OCRProtocol {
    func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        // Create CGImage from raw data
        guard let cgImage = createCGImage(from: imageData, width: width, height: height) else {
            throw ProcessingError.imageConversionFailed
        }

        // Create request
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = config.ocrAccuracyLevel == .accurate ? .accurate : .fast
        request.recognitionLanguages = config.recognitionLanguages
        request.usesLanguageCorrection = true

        // Perform recognition
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([request])

                guard let observations = request.results else {
                    continuation.resume(returning: [])
                    return
                }

                let regions = observations.compactMap { observation -> TextRegion? in
                    guard observation.confidence >= config.minimumConfidence else { return nil }

                    let text = observation.topCandidates(1).first?.string ?? ""
                    let box = observation.boundingBox

                    return TextRegion(
                        text: text,
                        confidence: observation.confidence,
                        boundingBox: NormalizedRect(
                            x: box.origin.x,
                            y: box.origin.y,
                            width: box.width,
                            height: box.height
                        ),
                        source: .ocr
                    )
                }

                continuation.resume(returning: regions)
            } catch {
                continuation.resume(throwing: ProcessingError.ocrFailed(underlying: error.localizedDescription))
            }
        }
    }

    private func createCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
```

### 2. Accessibility API Text Extraction

```swift
import ApplicationServices

actor AccessibilityService: AccessibilityProtocol {
    func hasPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    func requestPermission() {
        // Open System Preferences to Accessibility
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func getFocusedAppText() async throws -> AccessibilityResult {
        guard hasPermission() else {
            throw ProcessingError.accessibilityPermissionDenied
        }

        // Get frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "No frontmost app")
        }

        return try await getAppText(bundleID: frontApp.bundleIdentifier ?? "")
    }

    func getAppText(bundleID: String) async throws -> AccessibilityResult {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "App not found: \(bundleID)")
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        let textElements = try extractTextElements(from: appRef)

        let appInfo = AppInfo(
            bundleID: bundleID,
            name: app.localizedName ?? "",
            windowTitle: getWindowTitle(from: appRef),
            browserURL: nil
        )

        return AccessibilityResult(
            appInfo: appInfo,
            textElements: textElements
        )
    }

    private func extractTextElements(from element: AXUIElement, depth: Int = 0) throws -> [AccessibilityTextElement] {
        guard depth < 10 else { return [] }  // Prevent infinite recursion

        var results: [AccessibilityTextElement] = []

        // Get role
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        // Get value (text content)
        var valueValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueValue)

        if let textValue = valueValue as? String, !textValue.isEmpty {
            results.append(AccessibilityTextElement(
                text: textValue,
                role: role,
                label: nil,
                isEditable: role == "AXTextField" || role == "AXTextArea"
            ))
        }

        // Get title (for buttons, labels, etc.)
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)

        if let title = titleValue as? String, !title.isEmpty {
            results.append(AccessibilityTextElement(
                text: title,
                role: role,
                label: "title",
                isEditable: false
            ))
        }

        // Recurse into children
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                results.append(contentsOf: try extractTextElements(from: child, depth: depth + 1))
            }
        }

        return results
    }

    private func getWindowTitle(from appRef: AXUIElement) -> String? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return nil }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return nil }

        return title
    }
}
```

### 3. Text Merger (Combine OCR + Accessibility)

```swift
struct TextMerger {
    func merge(ocrRegions: [TextRegion], accessibilityResult: AccessibilityResult?) -> ExtractedText {
        var allRegions: [TextRegion] = ocrRegions

        // Add accessibility text as regions
        if let axResult = accessibilityResult {
            for element in axResult.textElements {
                // Check if this text already exists in OCR results (dedup)
                let isDuplicate = ocrRegions.contains { region in
                    textSimilarity(region.text, element.text) > 0.9
                }

                if !isDuplicate {
                    allRegions.append(TextRegion(
                        text: element.text,
                        confidence: 1.0,  // AX text is always accurate
                        boundingBox: .zero,  // AX doesn't give positions
                        source: .accessibility
                    ))
                }
            }
        }

        // Build full text (prioritize AX text as it's more accurate)
        let axText = accessibilityResult?.textElements.map(\.text).joined(separator: " ") ?? ""
        let ocrText = ocrRegions.map(\.text).joined(separator: " ")

        // Combine: AX text first, then unique OCR text
        let fullText = mergeTexts(primary: axText, secondary: ocrText)

        return ExtractedText(
            frameID: FrameID(),  // Will be set by caller
            timestamp: Date(),
            regions: allRegions,
            fullText: fullText
        )
    }

    private func textSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " "))
        let setB = Set(b.lowercased().split(separator: " "))

        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count

        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private func mergeTexts(primary: String, secondary: String) -> String {
        // Simple merge: combine both, removing obvious duplicates
        let primaryWords = Set(primary.lowercased().split(separator: " ").map(String.init))
        let secondaryUniqueWords = secondary.split(separator: " ").filter { word in
            !primaryWords.contains(word.lowercased())
        }

        if secondaryUniqueWords.isEmpty {
            return primary
        }

        return primary + " " + secondaryUniqueWords.joined(separator: " ")
    }
}
```

### 4. Frame-ID Queueing

The live OCR pipeline does **not** queue raw `CapturedFrame` blobs in `ProcessingManager`.
Capture persists frames first, then `FrameProcessingQueue` schedules OCR by `frameID`, loading
image bytes from storage only when a worker is ready. Keep new queueing work in that style:
bounded, storage-backed, and keyed by lightweight identifiers rather than in-memory frame data.

### 5. Handling Different Image Formats

The CAPTURE module sends raw pixel data. You may need to handle different formats:

```swift
extension VisionOCR {
    func createCGImage(from frame: CapturedFrame) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Assume BGRA format from ScreenCaptureKit
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: (frame.imageData as NSData).bytes),
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bytesPerRow: frame.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
throw ProcessingError.accessibilityPermissionDenied
throw ProcessingError.imageConversionFailed
```

## Testing Strategy

1. Test OCR with sample images containing text
2. Test OCR with various languages
3. Test Accessibility extraction (mock AX APIs)
4. Test text merging with overlapping content
5. Test queue processing under load
6. Test with empty/blank frames

## Dependencies

- **Input from**: CAPTURE module (CapturedFrame)
- **Output to**: DATABASE (ExtractedText for indexing via SEARCH)
- **Uses types**: `CapturedFrame`, `ExtractedText`, `TextRegion`, `ProcessingConfig`, `AppInfo`

## DO NOT

- Modify any files outside `Processing/`
- Import from other module directories (only `Shared/`)
- Handle storage (that's STORAGE's job)
- Handle search indexing (that's SEARCH's job)
- Handle screen capture (that's CAPTURE's job)

## Performance Targets

- OCR: <500ms per frame on Apple Silicon
- Accessibility extraction: <50ms
- Memory: <200MB during OCR (Vision manages its own memory)
- Queue: Process frames without falling behind at 0.5fps

## Getting Started

1. Create `Processing/OCR/VisionOCR.swift` with Vision framework
2. Create `Processing/Accessibility/AccessibilityService.swift`
3. Create `Processing/TextMerger/TextMerger.swift`
4. Create `Processing/ProcessingManager.swift` conforming to `ProcessingProtocol`
5. Write tests with sample images

Start with Vision OCR since it's the core functionality, then add Accessibility support.
