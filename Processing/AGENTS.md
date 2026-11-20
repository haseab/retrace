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
│   ├── WindowOCR.swift          # Window ownership, shared OCR row order, crop masks and bounded cached recognition
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
│   ├── AccessibilityOCRCorrector.swift # Internal + independent outside anchors, window ownership and AX span bounds
│   ├── AccessibilityService.swift  # AccessibilityProtocol implementation
│   └── TextElementFilter.swift     # Filter relevant text elements
│
├── TextMerger/
│   └── TextMerger.swift            # Combine OCR + AX results
└── Tests/
    ├── AccessibilityCorrectionTests.swift # Recorded node sequences, neighbor bounds, ambiguity and exclusive text ownership
    ├── AccessibilityVisionIntegrationTests.swift # Real Vision fixture and Unicode normalization regressions
    ├── Fixtures/AXSmallText.rtf                 # Sanitized document used by Vision integration checks
    ├── WindowOCRTests.swift # Real Vision recognition, overlap masks, crop coordinates, exclusion and cache invalidation
    ├── ExtractRequestInstrumentationTests.swift # Region tail aggregation and coordinator helper coverage
    ├── InPageURLMetadataResolutionTests.swift # In-page URL metadata retry and rewrite scheduling regression coverage
    ├── MemoryLedgerPendingWriteBoundTests.swift # Controlled queue saturation, bounded awaited removals and ordered writes
    ├── OCRMemoryBackpressurePolicyTests.swift # OCR memory backpressure threshold/default coverage
    ├── PhraseLevelRedactionTests.swift        # Manual + automatic OCR phrase-level redaction coverage
    ├── RewriteRetryPolicyTests.swift          # Bounded automatic rewrite retry coverage
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
        request.usesLanguageCorrection = false

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

## Keyword redaction processing

Read `PhraseRedactionMode` once when protecting OCR output and store the mode per node. Permanent matches retain masked text and only the permanent marker, never encrypted originals. Scramble matches without a master key must fail before search indexing. Rewrite scheduling uses each stored target mode; permanent-only plans run without a key. Use the shared keyword settings parser (including legacy comma/newline rules). Purge stale timeline stills/search thumbnails in both normal commit and committed startup recovery after a successful video rewrite, before marking it complete, and publish `PhraseRedactionMode.didFinishNotification` to invalidate UI image caches.

Recovery scanning must wait for all active rewrites and block new rewrite reservations until the scan finishes. Recheck the scanning gate after database awaits before reserving an encoder.

### Batch enqueue

`FrameProcessingQueue.enqueueBatch` passes the whole ID list to `DatabaseManager.enqueueFramesForProcessing` in one await. Increase `currentQueueDepth` only after the database commits the whole batch; empty batches are no-ops and failures add nothing. `RewriteRetryPolicyTests.testEnqueueBatchIsAtomicAndUsesDatabaseBatch` exercises this wiring against migrated SQLite. This is maintenance of an existing action; no new daily metric is needed.

When checking whether a frame is unrecoverable, a failed video-row lookup must not authorize deletion. Only a successful missing-row result establishes that the video row is absent. `RewriteRetryPolicyTests.testDatabaseReadFailureDoesNotAuthorizeFrameDeletion` covers a denied read against real SQLite.

Capture-time AX: `Accessibility/AccessibilityOCRCorrector.swift` aligns individual OCR nodes with saved screenshot references, using neighboring nodes for context and preserving geometry and region order without appending unobserved exterior AX words. `Tests/AccessibilityCorrectionTests.swift` covers actual observed Vision errors, whole-passage wording adoption and ambiguity/location rejection. ProcessingManager must never sample live AX while processing historical frames. Correction runs before phrase protection, indexing and video rewriting.

`Tests/AccessibilityVisionIntegrationTests.swift` rasterizes the sanitized TextEdit `Tests/Fixtures/AXSmallText.rtf` fixture with CoreText and runs real production Vision/ProcessingManager extraction, checking captured metadata, geometry preservation and no AX-only completion. Tests require the full XCTest toolchain and access to macOS Vision services.

### Rewrite test isolation

`FrameProcessingQueue` defaults to the Keychain-backed master-key provider. Rewrite tests inject a fixture key or an explicit missing key; never alter the user's Keychain to arrange a test. Preserve the distinction between scrambled rewrites (require a key) and permanent-only rewrites (do not). Async rewrite waits must have deadlines that return even when the underlying continuation ignores cancellation, and test storage gates must be released during teardown.

### Window-aware OCR

`OCR/WindowOCR.swift` uses saved front-to-back application-window bounds, with at most one crop/request per selected window. Earlier-window intersections are painted opaque white inside lower crops; no underlying-window image is captured. Results intersecting those masks are rejected. Dirty detection considers exposed pieces only, and cache ownership excludes preceding windows so overlapping crop bounds cannot duplicate cached text. Whole dirty windows are re-recognized; unaffected windows reuse the previous OCR cache. Results retain screenshot coordinates and window order. `OCRReadingOrder` groups same-line fragments by vertical-center proximity (half the smaller node height), then orders the row left-to-right with stable ties. Its first row box stays fixed to prevent offsets chaining across distinct lines. Apply this same helper to fresh crops, the cached/legacy results entering `ProcessingManager`, and AX correspondence. Reorder existing node values before building both `regions` and `fullText`, preserving identity/geometry and consistent downstream text offsets. Saved window ownership prevents rows from different windows being interleaved; unmatched nodes are preserved rather than filtered by the ordering helper. The global request limiter caps Vision crop requests across workers to two. Crop requests use the same language-correction setting as the legacy initial full-frame request, so segmentation comparisons do not silently change spelling correction. No live window/AX lookup is allowed during historical OCR.

`ProcessingManager` serializes complete cached frame extractions through async continuations because actors reenter across OCR awaits. Cache invalidation includes geometry, display ID, dimensions and foreground app. Missing/invalid geometry goes through the original pipeline, while an empty geometry list recognizes nothing. Failed/cancelled recognition must not publish partial cache results. Queue `window_ocr` metrics aggregate completed/failed frames, fallback frames, supplied rectangle counts and processing time, without text or geometry.

Crop telemetry cleanup awaits `MemoryLedger.remove` outside the autorelease pool on success and failure, including cancellation. Removal waits for the ledger's capacity instead of dropping cleanup or creating an unbounded task chain; keep it within the global two-request OCR limiter. Ledger admission regressions hold the real task queue with a DEBUG-only testing SPI barrier so saturation does not depend on scheduler speed.

### Anchored AX repair

- Vision language correction is disabled for full-frame, window-crop, legacy region, tile and live-screenshot requests. Recognition accuracy remains unchanged (`.accurate` by default); saved AX supplies the separate anchored correction pass.
- `AccessibilityOCRCorrector` has no dictionary dependency. Compare lowercase, canonical Unicode and typography-normalized non-whitespace characters, retaining original UTF-16 offsets. Adopt saved AX wording in NFC; never query the current foreground app for a historical frame.
- An OCR `TextRegion` retains its database ID, frame ID, bounds, confidence and creation time. `ProcessingManager` establishes shared reading order before correction; the corrector retains that input order. `ProcessingManager` passes validated saved window rectangles to the corrector. Partition OCR nodes and AX references using the existing front-to-back window pixel-ownership planner; another window cannot supply outside context. Invalid or unavailable ownership leaves affected nodes unchanged. Legacy frames without saved window rectangles use their original OCR geometry.
- Exact normalized whole-node/AX-reference matches pin correspondence before fuzzy work. Only literally unchanged wording gets a direct preservation proposal. Changing case or word spacing still requires outside evidence. This prevents an exact attribution from lending words to a different passage without allowing normalized equality to bypass correction checks.
- Locate text with unique six-character chunks extended into noncrossing anchor chains. Reuse an extended exact run for seeds covered on the same source/target diagonal, avoiding repeated full-run scans. Short fragments may use unique literal matches or two-character seeds. Select node paths whose OCR visual order agrees with increasing, non-overlapping AX intervals. Equal incompatible paths mark their affected nodes ambiguous. OCR bounds also keep unplaced nodes inside their neighboring text column.
- Every changed wording needs **both internal and outside anchors**. Internal exact chunks must exist within the proposed AX span. Outside evidence uses only the original OCR text of up to four neighboring nodes on each side in the same visual flow; the target's text never contributes to the outside identity check. Both sides must locate matching AX text when both are present. At a genuine flow edge, the available side may establish identity; an isolated node cannot authorize its own correction.
- Judge the outside passage as a whole, allowing several noisy/short neighbors to jointly establish identity. Require 24 exact anchor characters, 55% anchor coverage and 80% aggregate character agreement, in addition to the full-passage identity, ordering, word-boundary and ambiguity checks. There is no per-word or per-neighbor spelling/edit ceiling. No dictionary or numeric-only rule may veto wording once correspondence is established.
- Outside anchors bound the target's AX interval. Reject extra AX words/rows between a target and its outside anchors unless another existing node placement owns those characters. Internal similarity cannot choose between equally supported outside correspondences proposing different wording. Within one established outside correspondence, internal alignment ranks wording proposals.
- Traceback partitions text across existing nodes, including missing interior words, and keeps unmatched exterior text out at passage edges. OCR gutter noise must not consume punctuation from a neighboring node. Record each proposal's original AX element and character interval; reject overlapping ownership per affected node. Neighbor evidence always comes from uncorrected OCR, so accepted repairs do not bootstrap other repairs.
- Discover candidate AX bounds from the **last OCR node together with original preceding/following context**, retaining overlapping queries across earlier passages and separate visual flows. Keep local pairs/triples as well as up to four neighbors on each side: a split header may need its own local AX element even when a larger paragraph repeats its words. Index unique normalized six-character OCR chunks and scan all saved window-owned AX text; raw element 129 is eligible. Require the existing aggregate passage-identity checks to verify endpoints before detailed alignment. Retain every competing occurrence and preserve original AX element/character ownership when cropping. Merge overlapping verified intervals; unrelated AX prefixes/tails do not consume detailed alignment work. AX array order never establishes document order.
- Bound work to 16 saved windows, snapshot-sized raw text (131,072 UTF-16 units including a minimum cost per element), two passes over normalized AX context characters, 200,000 OCR query characters, 32,768 seed hits and 4,096 candidate bins per AX context. Discovery has its own 200,000 compared-character / 2-million-DP-cell budget; detailed alignment keeps the same per-window budget. Detailed work accepts at most 128 verified bounded contexts and 128 placements per context, 6,000 normalized OCR characters and 12,000 AX characters per comparison. ASCII normalization avoids per-character Foundation transformations; non-ASCII text retains canonical/typography normalization and original UTF-16 offsets. Cache repeated AX normalization within discovery. These are complete-search safeguards, never prefixes silently selected from the input. Any incomplete discovery/comparison, oversized candidate or exhausted budget preserves the affected window's original OCR; independently owned windows may still finish. Capture snapshots marked truncated remain ineligible. Capture's own traversal/time limits are unchanged, and missing captured AX text cannot be recovered here.
- `Tests/AccessibilityCorrectionTests.swift` replays recorded Vision text/geometry and deliberately incorrect references. Cover missing outside context, one-sided context when both sides exist, repeated outside passages, cross-window ownership, isolated-node abstention, and formatting changes. Recorded RXCASE015 regressions locate noisy final nodes after 140 unrelated AX elements and within a long AX reference, preserve split AX visual order, require preceding context, retain competing repeated endpoints, and discard earlier candidates after incomplete discovery. HOLD007 preserves local split-header bracket repair. Recorded invoice regressions cover late competitors, capture truncation, long references and independent correction beside an oversized window. Retain split-node RXCASE099, missing-word RXCASE059, native attribution/sidebar and code-gutter regressions. Character-alignment tests supply recorded outside context; real Vision and Unicode/SQLite offset integration remain in `AccessibilityVisionIntegrationTests.swift`.
- This changes existing OCR correction and adds no new user action or daily metric. Same-line fragment order is shared with OCR/full-text assembly. Complex column/paragraph reading order is still heuristic, and anchors do not prove that AX and screenshot content are synchronized; capture-time stability remains a separate concern.

`Tests/WindowOCRTests.swift` includes recorded RXCASE024 (the separate `36` node) and RXCASE039 mixed-height fragments. Assert exact node permutations, stable cached ordering, no node loss/duplication, and preservation of saved window order. Replays score final sequence order directly without consulting reference text or rendered ground-truth line rectangles for ordering.
