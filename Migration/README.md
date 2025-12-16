# Migration Module

Handles importing screen recording data from third-party applications into Retrace.

## Supported Sources

| Source | Status | Implementation |
|--------|--------|----------------|
| Rewind AI | ✅ Complete | `Importers/RewindImporter.swift` |
| ScreenMemory | 🔮 Planned | - |
| TimeScroll | 🔮 Planned | - |
| Pensieve | 🔮 Planned | - |

## Architecture

```
Migration/
├── MigrationManager.swift      # Coordinates all importers
├── Importers/
│   └── RewindImporter.swift    # Rewind-specific import logic
├── State/
│   └── [Persisted state files]
└── Tests/
```

## Key Features

### Resumability
- State persisted to disk after each video
- Safe to quit, sleep, or restart
- Automatically resumes from last checkpoint

### Background Processing
- Runs at low CPU priority
- Batched database inserts
- Delays between batches to yield to other tasks

### Progress Reporting
- Real-time progress updates via delegate
- Videos processed / total
- Frames imported / deduplicated
- Estimated time remaining

## Usage

```swift
// Setup
let migration = MigrationManager(database: db, processing: proc)
await migration.setupDefaultImporters()

// Check available sources
let sources = await migration.getAvailableSources()

// Scan for statistics
let stats = try await migration.scan(source: .rewind)
print("Found \(stats.totalVideoFiles) videos")

// Start import with progress delegate
try await migration.startImport(source: .rewind, delegate: self)

// Or pause/cancel
await migration.pauseImport(source: .rewind)
await migration.cancelImport(source: .rewind)
```

## Rewind Data Format

Rewind stores data in:
```
~/Library/Application Support/com.memoryvault.MemoryVault/chunks/YYYYMM/DD/*.mp4
```

Each MP4:
- ~2-5 seconds of video at ~30 FPS
- But each frame was captured at 0.5 FPS (1 frame / 2 seconds real-time)
- So 60 video frames = ~2 minutes of real-world time

## Dependencies

- `DatabaseProtocol` - Insert imported frames/documents
- `ProcessingProtocol` - OCR text extraction
- `FrameSource` - Source type enum
