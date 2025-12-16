# Retrace - Agent Guide

> **Standard**: This file follows the [AGENTS.md](https://agents.md) specification - a vendor-agnostic standard for AI agent guidance. For human-readable project information, see [README.md](README.md).

Retrace is a local-first screen recording and search application for macOS, inspired by Rewind AI. It captures screens, extracts text via OCR, and makes everything searchable—all on-device with encryption.

---

## Quick Reference

- **Module-Specific Instructions**: Each module has its own `AGENTS.md` file in its directory
- **Human Documentation**: [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md)

---

## Project Commands

### Build & Test
```bash
# Build all targets
swift build

# Build specific module tests
swift build --target DatabaseTests

# Run all tests
swift test

# Run specific module tests
swift test --filter DatabaseTests

# Run specific test
swift test --filter testSpecificMethod
```

### Development Workflow
```bash
# Clean build artifacts
rm -rf .build/

# Check Swift version (requires 5.9+)
swift --version

# Format code (if using swift-format)
swift-format format --in-place --recursive .
```

---

## Project Structure

```
retrace/
├── AGENTS.md                    # This file - main agent coordination
├── README.md                    # Human-readable project overview
├── CONTRIBUTING.md              # Contribution guidelines
├── Package.swift                # Swift Package Manager configuration
│
├── Shared/                      # CRITICAL: Shared types and protocols
│   ├── Models/                  # Data types used across modules
│   │   ├── Frame.swift          # FrameID, CapturedFrame, VideoSegment
│   │   ├── Text.swift           # ExtractedText, OCRTextRegion
│   │   ├── Search.swift         # SearchQuery, SearchResult
│   │   ├── Config.swift         # Configuration types
│   │   └── Errors.swift         # Error types
│   └── Protocols/               # Module interfaces
│       ├── DatabaseProtocol.swift
│       ├── StorageProtocol.swift
│       ├── CaptureProtocol.swift
│       ├── ProcessingProtocol.swift
│       └── SearchProtocol.swift
│
├── Database/                    # SQLite + FTS5 storage
│   ├── AGENTS.md                # Module-specific agent instructions
│   ├── DatabaseManager.swift
│   ├── FTSManager.swift
│   ├── Migrations/
│   ├── Queries/
│   └── Tests/
│
├── Storage/                     # File I/O, HEVC encoding, encryption
│   ├── AGENTS.md
│   ├── StorageManager.swift
│   ├── Encryption/
│   ├── VideoEncoder/
│   └── Tests/
│
├── Capture/                     # ScreenCaptureKit integration
│   ├── AGENTS.md
│   ├── CaptureManager.swift
│   ├── ScreenCapture/
│   ├── Deduplication/
│   └── Tests/
│
├── Processing/                  # OCR and text extraction
│   ├── AGENTS.md
│   ├── ProcessingManager.swift
│   ├── OCR/
│   ├── Accessibility/
│   └── Tests/
│
├── Search/                      # Full-text search
│   ├── AGENTS.md
│   ├── SearchManager.swift
│   ├── QueryParser/
│   └── Tests/
│
├── Migration/                   # Import from other apps
│   ├── AGENTS.md
│   ├── MigrationManager.swift
│   └── Importers/
│
├── App/                         # Main application (future)
└── UI/                          # SwiftUI interface (future)
    └── AGENTS.md
```

---

## Module Ownership & Responsibilities

| Module | Directory | Agent File | Responsibility |
|--------|-----------|------------|----------------|
| **DATABASE** | `Database/` | `Database/AGENTS.md` | SQLite schema, FTS5, CRUD operations, migrations |
| **STORAGE** | `Storage/` | `Storage/AGENTS.md` | File I/O, HEVC video segments, encryption (AES-256-GCM) |
| **CAPTURE** | `Capture/` | `Capture/AGENTS.md` | ScreenCaptureKit integration, frame deduplication |
| **PROCESSING** | `Processing/` | `Processing/AGENTS.md` | Vision OCR, Accessibility API text extraction |
| **SEARCH** | `Search/` | `Search/AGENTS.md` | Query parsing, FTS queries, result ranking |
| **MIGRATION** | `Migration/` | `Migration/AGENTS.md` | Import from Rewind AI, ScreenMemory, etc. |
| **UI** | `UI/` | `UI/AGENTS.md` | SwiftUI interface (planned) |

**Rule**: Each agent should **ONLY** modify files in their assigned module directory. Cross-module changes require explicit coordination.

---

## Coding Conventions

### Language & Style
- **Language**: Swift 5.9+
- **Async/Await**: Required for all I/O operations
- **Actors**: Use for stateful classes needing synchronization
- **Sendable**: All public APIs must be `Sendable`
- **Value Types**: Prefer structs/enums over classes

### Module Boundaries
1. **Depend only on protocols** - Import from `Shared/Protocols/` only
2. **Use shared types** - All cross-module data uses `Shared/Models/`
3. **No direct imports** - Never import from another module's directory
4. **Protocol conformance** - Each module implements its protocol from `Shared/`

### Error Handling
- Use error types from `Shared/Models/Errors.swift`
- Throw specific errors, not generic ones
- Add new error cases to your module's directory only

### Testing (TDD Required)
- **Write tests first** - Follow RED → GREEN → REFACTOR cycle
- **Test locations**: `{Module}/Tests/`
- **Test against protocols** - Not implementations
- **Mock dependencies** - Using protocol conformance

### ⚠️ CRITICAL: Test with REAL Input Data, Not Fake Structures

**The Problem:**
Many tests "play cop and thief" - creating fake data structures and validating the fake data they created. This provides **zero confidence** about real system behavior.

**Example of USELESS Test:**
```swift
func testAccessibilityResultCreation() {
    let appInfo = AppInfo(bundleID: "com.apple.Safari", ...)  // WE CREATE THIS
    let result = AccessibilityResult(appInfo: appInfo, ...)
    XCTAssertEqual(result.appInfo.bundleID, "com.apple.Safari")  // WE VALIDATE WHAT WE CREATED
}
```

**Example of USEFUL Test:**
```swift
func testDatabaseSchemaExists() async throws {
    // REAL SQLite query
    let tables = try await database.getTables()
    // Validates ACTUAL schema in REAL database
    XCTAssertTrue(tables.contains("segment"))
}
```

**What Makes a Test Useful:**
1. ✅ Tests **real system APIs** (SQLite, FileManager, macOS Accessibility, Vision OCR)
2. ✅ Uses **real production input** (real screenshots, real audio, real OCR output)
3. ✅ Validates **end-to-end workflows** (screenshot → OCR → database → search)
4. ❌ **NOT** testing if Swift can assign struct fields
5. ❌ **NOT** testing string concatenation or boolean flags

**Testing Philosophy:**
- **Database tests**: Validate real SQLite behavior (SQL syntax, FTS5, migrations) ✅
- **Integration tests**: Use REAL input data (see `test_assets/` requirements) ✅
- **Avoid circular tests**: Don't create data and validate what you created ❌

See [TESTS_CLEANUP.md](TESTS_CLEANUP.md) and [TESTS_MIGRATION.md](TESTS_MIGRATION.md) for full details.

### Test Categories (All Modules)
Every module MUST have:
- **Schema/Config Validation**: Configuration is valid (SQL compiles, paths exist)
- **Real API Tests**: Test actual system APIs (SQLite, FileManager, Vision, etc.)
- **Edge Cases**: Boundaries, nulls, unicode, SQL injection
- **Integration Tests**: End-to-end workflows WITH real production input data

### Test Output Philosophy
**Keep test output clean, structured, and high-level:**

#### For simple/redundant checks (existence, counts):
```
Checking if 11/11 tables exist...
✅ All 11 tables exist
```

#### For edge cases and complex behavior:
```
Testing 3 FTS trigger behaviors
  ✓ Insert triggers auto-indexing
  ✓ Delete removes from index
  ✓ Update re-indexes content
```

**Principles:**
- High-level summary first
- Indented list of what was tested
- No verbose per-item logging unless it provides value
- Only print details when tests fail or for complex edge cases
- Consolidate related tests instead of creating many small ones
- **Always include negative tests** - verify that validation logic correctly detects failures (e.g., missing tables, non-existent columns, invalid data)

#### Verbose Mode & HTML Reports

Use the `runAsyncTest()` decorator for clean, reusable test logging:

```swift
func testFTSTriggers() async throws {
    try await runAsyncTest(
        description: "Testing FTS trigger behaviors",
        verboseSteps: { log in
            log.logStep(title: "Setup", details: "Running migration...")
        }
    ) {
        // Your test code here
        // Non-verbose: prints clean summary
        // Verbose (VERBOSE_TESTS=1): generates HTML report with detailed steps

        if logger.isVerbose {
            logger.logStep(title: "Step 1", details: "Input: ...\nExpected: ...\nActual: ...")
        }

        // XCTAssert statements...
    }
}
```

**Benefits:**
- Automatic test start/end handling
- Automatic HTML report generation in verbose mode
- Clean separation: verbose details in closures, test logic stays clean
- Reusable across all test files

**Usage:**
```bash
# Clean output
swift test --filter MigrationTests

# Detailed HTML report
VERBOSE_TESTS=1 swift test --filter MigrationTests
open test_report.html
```

---

## Architecture & Data Flow

### Screenshot → Database Pipeline (Every 2 Seconds)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    EVERY 2 SECONDS: SCREEN CAPTURE                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
        ┌───────────────────────────────────────────────────┐
        │  Layer 1: CAPTURE                                 │
        │  • ScreenCaptureKit → CGImage                     │
        │  • Perceptual hash → Deduplication (95%)          │
        │  • NSWorkspace → App metadata                     │
        └───────────────────────────────────────────────────┘
                                    ↓
                    ┌───────────────┴───────────────┐
                    ↓                               ↓
    ┌───────────────────────────┐   ┌───────────────────────────┐
    │  Layer 2A: VIDEO PATH     │   │  Layer 2B: OCR PATH       │
    │  Buffer 150 frames        │   │  Vision.framework         │
    │  (5 seconds @ 30 FPS)     │   │  Text extraction          │
    └───────────────────────────┘   └───────────────────────────┘
                    ↓                               ↓
    ┌───────────────────────────┐   ┌───────────────────────────┐
    │  Layer 3A: HEVC ENCODE    │   │  Layer 3B: NODE CREATION  │
    │  CVPixelBuffer            │   │  • Bounding boxes         │
    │  → H.265 compression      │   │  • Text offsets           │
    │  → .mp4 file (5-7 MB)     │   │  • Sequential ordering    │
    └───────────────────────────┘   └───────────────────────────┘
                    ↓                               ↓
                    └───────────────┬───────────────┘
                                    ↓
        ┌───────────────────────────────────────────────────┐
        │  Layer 4: DATABASE INSERTION (Multi-table)        │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.1 segment → segmentId                     │  │
        │  │     bundleID, windowName, browserUrl        │  │
        │  └─────────────────────────────────────────────┘  │
        │                      ↓                            │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.2 frame → frameId                         │  │
        │  │     segmentId FK, videoId FK, timestamp     │  │
        │  └─────────────────────────────────────────────┘  │
        │                      ↓                            │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.3 node (bulk insert 10-100 rows)          │  │
        │  │     frameId FK, bounds, textOffset          │  │
        │  └─────────────────────────────────────────────┘  │
        │                      ↓                            │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.4 searchRanking_content (FTS5) → docid    │  │
        │  │     Full merged text for search             │  │
        │  └─────────────────────────────────────────────┘  │
        │                      ↓                            │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.5 doc_segment (linking table)             │  │
        │  │     docid → frameId relationship            │  │
        │  └─────────────────────────────────────────────┘  │
        │                      ↓                            │
        │  ┌─────────────────────────────────────────────┐  │
        │  │ 4.6 video (metadata)                        │  │
        │  │     path, fileSize, resolution, frameRate   │  │
        │  └─────────────────────────────────────────────┘  │
        └───────────────────────────────────────────────────┘
                                    ↓
        ┌───────────────────────────────────────────────────┐
        │  Layer 5: SEARCH & RETRIEVAL                      │
        │  5.1 FTS query → docid                            │
        │  5.2 doc_segment → frameId                        │
        │  5.3 frame → segment + video metadata             │
        │  5.4 node → bounding boxes for highlighting       │
        │  5.5 video → extract image from .mp4              │
        └───────────────────────────────────────────────────┘
```

### Data Flow by Module

```
CAPTURE Module:
  Input:  ScreenCaptureKit API
  Output: CGImage + AppInfo metadata

STORAGE Module (Video Path):
  Input:  CGImage stream (150 frames)
  Output: .mp4 file → ~/Library/.../videos/{YYYYMM}/{DD}/{xid}.mp4

PROCESSING Module (OCR Path):
  Input:  CGImage
  Output: OCRRegion[] with bounds + text

DATABASE Module:
  Input:  AppInfo + OCRRegion[] + Video metadata
  Output: 6 tables written:
    • segment (app session)
    • frame (screenshot timestamp + links)
    • node (OCR bounding boxes, 10-100 per frame)
    • searchRanking_content (FTS5 index)
    • doc_segment (FTS → frame link)
    • video (file metadata)

SEARCH Module:
  Input:  Query string
  Output: SearchResult[] with frameId + snippet
```

### Database Relationships

```sql
segment (1) ──< (N) frame (N) >── (1) video
                    │
                    └──< (N) node

frame (1) ──< (1) doc_segment >── (1) searchRanking_content
```

### Architecture Diagram (Module Level)

```
                +---------------------------+
                |        App Layer          |
                |  (Integration + UI)       |
                +------------+--------------+
                             |
     +-----------------------+-----------------------+
     |                       |                       |
     v                       v                       v
+----------------+     +------------------+     +----------------+
|    Capture     |     |   Processing     |     |     Search     |
|    Module      |     |     Module       |     |     Module     |
+-------+--------+     +--------+---------+     +-------+--------+
        |                       |                       |
        v                       v                       v
+----------------+     +------------------+     +----------------+
|    Storage     |     |    Database      |     |    Database    |
|    Module      |     |     (FTS)        |     |   (Vectors)    |
+----------------+     +------------------+     +----------------+
```

---

## Tech Stack

| Component | Technology | Notes |
|-----------|------------|-------|
| Language | Swift 5.9+ | Actors, async/await, Sendable required |
| UI Framework | SwiftUI | Planned for future |
| Screen Capture | ScreenCaptureKit | macOS 13.0+ required |
| Video Encoding | VideoToolbox (HEVC) | Hardware encoding on Apple Silicon |
| OCR | Vision framework | macOS native OCR |
| Database | SQLite + FTS5 | Full-text search built-in |
| Encryption | CryptoKit (AES-256-GCM) | On-device encryption |
| Embeddings | CoreML | Optional semantic search |

---

## System Requirements

- **macOS**: 13.0+ (Ventura) for ScreenCaptureKit improvements
- **Hardware**: Apple Silicon recommended for hardware encoding/Neural Engine
- **Entitlements**:
  - `com.apple.security.device.screen-recording`
  - Accessibility permission (runtime request)

---

## Performance Targets

- **CPU**: <20% of single core during capture
- **Memory**: <1GB total app usage
- **Storage**: ~15-20GB per month of continuous use
- **Search**: <100ms for keyword search
- **OCR**: <500ms per frame on Apple Silicon

---

## Agent Workflow (Getting Started)

When working on this project:

1. **Read module-specific instructions**: Check `{Module}/AGENTS.md` for your assigned module
2. **Review protocols**: Understand interfaces in `Shared/Protocols/`
3. **Review shared types**: Check data models in `Shared/Models/`
4. **Write tests first**: Follow TDD (Test-Driven Development)
5. **Implement features**: Only in your assigned module directory
6. **Update PROGRESS.md**: Maintain continuity documentation (see below)

---

## Documentation Requirements

### PROGRESS.md (Critical for Continuity)

Each module should maintain a `PROGRESS.md` file for work continuity:

```markdown
# {Module} Progress

## Current Status
- [ ] Task 1
- [x] Task 2 (completed)

## Completed Work
- **File**: `path/to/file.swift` - Brief description

## In Progress
- Currently working on: {description}
- Blockers: {any issues}

## Design Decisions
- Decision 1: Why we chose X over Y

## Next Steps
1. Next immediate task

## Questions / Needs from Other Modules
- Need X from {MODULE} module

Last Updated: {timestamp}
```

**Update Rules**:
- CREATE `PROGRESS.md` as first action in a module
- UPDATE after completing each file/feature
- UPDATE before ending any session
- REMOVE outdated information regularly
- Keep concise - it's a handoff document, not a journal

---

## Communication Protocol

If you need something from another module:
1. Check if it exists in `Shared/Protocols/`
2. If not, document the need in `TODO.md` in your directory
3. Do NOT create cross-module dependencies directly

---

## TDD Philosophy

### Core Principle
**Deploy based solely on tests passing - no manual inspection needed.**

### The TDD Cycle
```
1. Write failing test (RED)
2. Write minimum code to pass (GREEN)
3. Refactor (REFACTOR)
4. Repeat
```

### Edge Cases to ALWAYS Test
- Empty state (no data)
- Null/nil optional fields
- Unicode and special characters
- SQL injection attempts (for database module)
- Boundary conditions (exact timestamps, limits)
- Duplicate handling
- Error conditions

### Test Checklist Before ANY PR
- [ ] All existing tests pass
- [ ] New feature has tests
- [ ] Edge cases covered
- [ ] Integration test if cross-module

---

## Third-Party Data Import

Retrace supports importing from other screen recording apps:

| Source | Status | Data Location |
|--------|--------|---------------|
| Rewind AI | Supported | `~/Library/Application Support/com.memoryvault.MemoryVault/chunks/` |
| ScreenMemory | Planned | TBD |
| TimeScroll | Planned | TBD |
| Pensieve | Planned | TBD |

### Import Features
- **Resumable**: Survives app quit, sleep, restart
- **Background**: Low CPU priority
- **Progress UI**: Real-time progress bar
- **Deduplication**: Skips duplicate frames

### Database Source Column
All frames/segments have a `source` column:
- `native` - Captured by Retrace
- `rewind` - Imported from Rewind AI
- `screen_memory`, `time_scroll`, `pensieve` - Future sources

See `Migration/AGENTS.md` for implementation details.

---

## Critical Rules for All Agents

### 1. Stay In Your Lane
- **ONLY** modify files in your assigned directory
- **NEVER** modify files in `Shared/` without explicit coordination
- **NEVER** modify another agent's directory

### 2. Depend Only on Protocols
- Import from `Shared/` only
- Never import from another module's directory
- Your implementation must conform to protocols in `Shared/Protocols/`

### 3. Use Shared Types
- All data passed between modules uses types from `Shared/Models/`
- Don't create duplicate types - use what exists
- If you need a new shared type, document the need (don't create it)

### 4. Testing is Mandatory
- Write tests BEFORE implementation (TDD)
- Test against protocols, not implementations
- Cover edge cases thoroughly
- All tests must pass before submitting changes

---

## Additional Resources

- **AGENTS.md Specification**: https://agents.md
- **Contribution Guide**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **Human README**: [README.md](README.md)

---

*This file follows the AGENTS.md standard for AI agent guidance. Last updated: 2025-12-13*
