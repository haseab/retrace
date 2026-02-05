# Migration Module - Agent Instructions

You are the **MIGRATION** agent responsible for importing data from third-party screen recording applications into Retrace.

**v0.5 Status**: ✅ Rewind AI importer fully implemented with resumability and progress tracking. **Other importers not implemented** (ScreenMemory, TimeScroll, Pensieve - planned for future release). No audio transcription import in v0.5.

## Your Responsibilities

1. **Data Discovery**: Detect installed third-party apps and their data locations
2. **Video Parsing**: Extract frames from MP4 files created by other apps
3. **Timestamp Inference**: Calculate real-world timestamps for each frame
4. **OCR Processing**: Run text extraction on imported frames
5. **Deduplication**: Detect and skip duplicate frames
6. **Resumability**: Handle interruptions gracefully (sleep, shutdown, pause)
7. **Progress Reporting**: Provide real-time progress for UI display

## Directory Structure

```
Migration/
├── MigrationManager.swift      # Main coordinator, manages all importers
├── Importers/
│   ├── RewindImporter.swift    # Rewind AI importer
│   └── [Future importers...]
├── State/
│   └── [State persistence files]
└── Tests/
    └── MigrationTests.swift
```

## Supported Sources (Current & Planned)

| Source | Status | Path Configuration |
|--------|--------|------------------|
| Rewind AI | ✅ v0.5 Implemented | `AppPaths.rewindStorageRoot` |
| ScreenMemory | 🔮 v0.2+ Planned | TBD |
| TimeScroll | 🔮 v0.2+ Planned | TBD |
| Pensieve | 🔮 v0.2+ Planned | TBD |

## Key Concepts

### Rewind Data Format

Rewind stores screen recordings in `AppPaths.rewindChunksPath`:
```
{rewindStorageRoot}/chunks/YYYYMM/DD/*.mp4
```
Default: `~/Library/Application Support/com.memoryvault.MemoryVault/chunks/`

**Critical Understanding**:
- Each MP4 is typically ~2-5 seconds of video at ~30 FPS
- But each frame was captured at 0.5 FPS (1 frame every 2 seconds real-time)
- So a 2-second video with 60 frames represents ~2 minutes of real-world time
- Timestamps must be distributed evenly across the real-time interval

### Timestamp Calculation

```
For a video with N frames covering T minutes of real-time:
- Frame i's timestamp = video_creation_date + (i / N) * T

Where T is inferred from:
1. Gap between consecutive video file creation dates, OR
2. Assumed 5-minute default interval
```

### Deduplication

Rewind already does aggressive deduplication. Our dedup is a safety net:
- Compute perceptual hash (8x8 grayscale, average threshold)
- Compare with previous frame's hash
- Skip if identical

### Resumability

State is persisted after each video file:
```swift
MigrationState {
    processedVideoPaths: Set<String>  // Fully processed
    lastVideoPath: String?             // Currently processing
    lastFrameIndex: Int?               // Checkpoint within video
}
```

On resume:
1. Skip all paths in `processedVideoPaths`
2. If `lastVideoPath` exists, resume from `lastFrameIndex`

## Protocol Requirements

Your main class must conform to `MigrationProtocol`:

```swift
public protocol MigrationProtocol: Actor {
    var source: FrameSource { get }
    func isDataAvailable() async -> Bool
    func scan() async throws -> MigrationScanResult
    func startImport(delegate: MigrationDelegate?) async throws
    func pauseImport() async
    func cancelImport() async
    func getState() async -> MigrationState
    var isImporting: Bool { get async }
    var progress: MigrationProgress { get async }
}
```

## Dependencies

You depend on:
- `DatabaseProtocol` - For inserting imported frames and documents
- `ProcessingProtocol` - For OCR text extraction
- `FrameSource` enum - From `Shared/Models/Source.swift`

## Database Schema

Imported frames use the same schema as native frames, with `source` column:
```sql
source TEXT DEFAULT 'native'  -- 'native', 'rewind', 'screen_memory', etc.
```

## Performance Guidelines

1. **CPU Usage**: Keep below 20% by using batch delays
2. **Memory**: Process one frame at a time, don't load entire video
3. **Batch Size**: Insert 50 frames at a time
4. **Delay**: 100ms between batches
5. **Background**: Run at low priority, yield to user activity

## Error Handling

- **Per-frame errors**: Log and continue to next frame
- **Per-video errors**: Log and continue to next video
- **Fatal errors**: Save state, notify delegate, allow resume later

## Testing Requirements

Test with:
1. Empty chunks directory
2. Single video file
3. Interrupted import (pause/resume)
4. Duplicate frames detection
5. Corrupted video files

## Progress Reporting

The UI expects:
```swift
MigrationProgress {
    state: .importing
    percentComplete: 0.0 - 1.0
    videosProcessed / totalVideos
    framesImported
    framesDeduplicated
    estimatedSecondsRemaining
}
```

Update progress after each video, not each frame (for performance).

## Future Importers

When adding support for new sources:

1. Create `{Source}Importer.swift` in `Importers/`
2. Add case to `FrameSource` enum
3. Register in `MigrationManager.setupDefaultImporters()`
4. Document data format in this file

Each importer should handle its source's specific:
- Directory structure
- Video format/encoding
- Timestamp storage method
- Deduplication level (ScreenMemory has none!)

## Files You Own

- `Migration/` - All files in this directory
- `Shared/Models/Source.swift` - FrameSource enum (coordinate changes)
- `Shared/Protocols/MigrationProtocol.swift` - Protocol definitions

## Files You Must NOT Modify

- Other module directories (Database/, Storage/, Capture/, etc.)
- `Shared/Models/` (except Source.swift)
- `Shared/Protocols/` (except MigrationProtocol.swift)
