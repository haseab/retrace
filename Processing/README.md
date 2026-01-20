# Processing Module

**Owner**: PROCESSING Agent
**Status**: ✅ Implementation Complete
**Instructions**: See [CLAUDE-PROCESSING.md](../CLAUDE-PROCESSING.md)

## Responsibility

Text extraction from frames including:
- Vision framework OCR
- Accessibility API text extraction
- Merging OCR and AX results
- Background processing queue

## Implementation Status

✅ All core components implemented and tested

### Completed Files

```
Processing/
├── ProcessingManager.swift              ✅ Main coordinator (ProcessingProtocol)
├── OCR/
│   └── VisionOCR.swift                  ✅ Vision framework integration
├── Accessibility/
│   └── AccessibilityService.swift       ✅ macOS AX API integration
├── TextMerger/
│   └── TextMerger.swift                 ✅ Merge + deduplicate results
└── Tests/
    ├── VisionOCRTests.swift             ✅ OCR test suite
    ├── AccessibilityTests.swift         ✅ AX test suite
    ├── TextMergerTests.swift            ✅ Merger test suite
    └── ProcessingManagerTests.swift     ✅ Integration tests
```

## Protocols Implemented

- ✅ `ProcessingProtocol` (ProcessingManager.swift)
- ✅ `OCRProtocol` (VisionOCR.swift)
- ✅ `AccessibilityProtocol` (AccessibilityService.swift)

## Quick Start

### Basic Usage

```swift
import Processing

// Initialize
let manager = ProcessingManager(config: .default)
try await manager.initialize(config: config)

// Extract text from frame
let extractedText = try await manager.extractText(from: frame)
print("Text: \(extractedText.fullText)")
```

### Configuration

```swift
let config = ProcessingConfig(
    accessibilityEnabled: true,
    ocrAccuracyLevel: .accurate,
    recognitionLanguages: ["en-US"],
    minimumConfidence: 0.7
)

await manager.updateConfig(config)
```

### Background Queue

```swift
await manager.queueFrame(frame) { result in
    switch result {
    case .success(let text):
        print("Extracted: \(text.fullText)")
    case .failure(let error):
        print("Error: \(error)")
    }
}

await manager.waitForQueueDrain()
```

## Key Features

- **Vision OCR**: Fast or accurate text recognition with multiple language support
- **Accessibility API**: Extract text from macOS UI elements with app context
- **Smart Merging**: Jaccard similarity-based deduplication
- **Queue Management**: Actor-based thread-safe background processing
- **Performance**: <500ms OCR, <50ms AX extraction on Apple Silicon

## Integration

**Input**: `CapturedFrame` from CAPTURE module
**Output**: `ExtractedText` to DATABASE module

## Testing

```bash
swift test --filter ProcessingTests
```

## See Also

- [PROGRESS.md](PROGRESS.md) - Detailed implementation progress
- [CLAUDE-PROCESSING.md](../CLAUDE-PROCESSING.md) - Agent instructions
- [ProcessingProtocol.swift](../Shared/Protocols/ProcessingProtocol.swift) - Protocol definitions
