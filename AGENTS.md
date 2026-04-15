# Retrace - Agent Guide

> **Standard**: This file follows the [AGENTS.md](https://agents.md) specification - a vendor-agnostic standard for AI agent guidance. For human-readable project information, see [README.md](README.md).

Retrace is a local-first screen recording and search application for macOS, inspired by Rewind AI. It captures screens, extracts text via OCR, and makes everything searchable—all locally on-device.

**Status**: Core screen capture (CGWindowListCapture), OCR (Vision), full-text search (FTS5), HEVC encoding, and Rewind import are working. Audio transcription and vector search are planned for future releases.

---

## Quick Reference

- **Module-Specific Instructions**: Each module has its own `AGENTS.md` file in its directory
- **Human Documentation**: [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md), [AI_ISSUE_TEMPLATE.md](AI_ISSUE_TEMPLATE.md), and [TODO.MD](TODO.MD)
- **Issue Reporting**: Use `AI_ISSUE_TEMPLATE.md` and `gh issue create --body-file ...` for AI-authored GitHub issues
- **Bug Fixes by Non-Owners**: If the user is fixing a bug/crash and does not appear to be the repo owner, encourage them to create or link a GitHub issue before making code changes
- **Technical Audit Docs**: `local/docs/` (includes deep-dive implementation and performance audit notes)

---

## Project Commands

### Build & Test

```bash
# Build all targets
swift build

# Run all tests
swift test

# Run specific module tests
swift test --filter DatabaseTests

# Run specific test
swift test --filter testSpecificMethod

# Clean build artifacts
rm -rf .build/
```

---

## Project Structure

```
retrace/
├── AGENTS.md                    # This file - main agent coordination
├── .env.example                 # Template for local release credentials (copy to .env)
├── .github/                     # GitHub configuration
│   ├── CODEOWNERS
│   ├── FUNDING.yml
│   └── ISSUE_TEMPLATE/
│       └── bug_report.yml       # GitHub bug report form aligned with AI issue template
├── AI_ISSUE_TEMPLATE.md         # Canonical markdown template for AI-authored bug reports
├── TODO.MD                      # Migration plan for refactoring the fullscreen timeline view and view model
├── README.md                    # Human-readable project overview
├── CONTRIBUTING.md              # Contribution guidelines
├── Package.swift                # Swift Package Manager configuration
├── scripts/                     # Build/release/validation scripts
│   ├── release.sh               # End-to-end release automation
│   ├── create-release.sh        # Release build + packaging helper
│   ├── check_no_nanoseconds_sleep.sh # Guardrail for Task.sleep(nanoseconds:)
│   ├── validate_sleep_wake_stability.sh # Sleep/wake soak validation workflow
│   └── validate_darkwake_watchdog.sh # Automated darkwake watchdog regression validation
│
├── Shared/                      # CRITICAL: Shared types and protocols
│   ├── Logging.swift            # Central log utility (Log.debug/info/warning/error)
│   ├── AppPaths.swift           # Application path configuration
│   ├── BGRAImageUtilities.swift # Shared BGRA conversion + patch extraction helpers
│   ├── MasterKeyManager.swift   # Keychain-backed master key creation + recovery phrase export
│   ├── ReversibleOCRScrambler.swift # Deterministic reversible OCR patch scrambling + text protection
│   ├── Models/                  # Data types used across modules
│   │   ├── Frame.swift          # FrameID, CapturedFrame, VideoSegment
│   │   ├── Text.swift           # ExtractedText, OCRTextRegion
│   │   ├── TextRegion.swift     # OCR text region types
│   │   ├── Search.swift         # SearchQuery, SearchResult
│   │   ├── Segment.swift        # Segment data model
│   │   ├── Config.swift         # Configuration types
│   │   ├── Errors.swift         # Error types
│   │   ├── Audio.swift          # Audio model types (Release 2)
│   │   ├── FilterCriteria.swift # Timeline/search filter criteria
│   │   ├── Source.swift         # Data source enum (native, rewind, etc.)
│   │   ├── Tag.swift            # Tag model types
│   │   └── Comment.swift        # Segment comment and attachment models
│   └── Protocols/               # Module interfaces
│       ├── DatabaseProtocol.swift
│       ├── StorageProtocol.swift
│       ├── CaptureProtocol.swift
│       ├── ProcessingProtocol.swift
│       ├── SearchProtocol.swift
│       └── MigrationProtocol.swift
│
├── Database/                    # SQLite + FTS5 storage
│   ├── AGENTS.md                # Module-specific agent instructions
│   ├── DatabaseManager.swift    # Main database coordinator
│   ├── DatabaseConnection.swift # SQLite connection management
│   ├── DatabaseConfig.swift     # Database configuration
│   ├── FTSManager.swift         # Full-text search management
│   ├── IDMappingService.swift   # ID mapping between sources
│   ├── Schema.swift             # Current schema definition
│   ├── Migrations/              # Schema migration scripts
│   ├── Queries/                 # Query implementations
│   └── Tests/
│
├── Storage/                     # File I/O, HEVC encoding
│   ├── AGENTS.md
│   ├── StorageManager.swift
│   ├── ImageExtractor.swift     # Extract frames from video files
│   ├── IncrementalSegmentWriter.swift
│   ├── SegmentWriterImpl.swift
│   ├── FileManager/             # File system utilities
│   ├── VideoEncoder/            # HEVC video encoding
│   ├── WAL/                     # Write-Ahead Log (WALManager, RecoveryManager)
│   └── Tests/
│
├── Capture/                     # CGWindowListCapture integration
│   ├── AGENTS.md
│   ├── CaptureManager.swift
│   ├── ScreenCapture/           # Screen capture implementation
│   ├── Deduplication/           # Perceptual hash deduplication
│   ├── Metadata/                # AppInfoProvider, BrowserURLExtractor
│   └── Tests/
│
├── Processing/                  # OCR and text extraction
│   ├── AGENTS.md
│   ├── ProcessingManager.swift
│   ├── FrameProcessingQueue.swift # Async frame processing queue
│   ├── URLExtractor.swift       # URL extraction from OCR text
│   ├── OCR/                     # Vision framework OCR
│   ├── Accessibility/           # Accessibility API integration
│   ├── TextMerger/              # Text merging utilities
│   └── Tests/
│
├── Search/                      # Full-text search
│   ├── AGENTS.md
│   ├── SearchManager.swift
│   ├── IngestionManager.swift   # Search index ingestion
│   ├── QueryParser/             # Query parsing (app:, date:, -exclude)
│   ├── Ranking/                 # Result ranking implementation
│   ├── VectorSearchTODO/        # Planned for Release 2 (excluded from build)
│   └── Tests/
│
├── Migration/                   # Import from other apps
│   ├── AGENTS.md
│   ├── MigrationManager.swift
│   └── Importers/               # Source-specific importers (Rewind)
│
├── App/                         # Main application coordinator
│   ├── AppCoordinator.swift     # Central coordinator (orchestrates all modules)
│   ├── DataAdapter.swift        # Data layer adapter (DB queries, transformations)
│   ├── FeedbackRecentMetricSupport.swift # Shared feedback-export metric models and sanitization helpers
│   ├── ServiceContainer.swift   # Dependency injection container
│   ├── AppLifecycle.swift       # App lifecycle management
│   ├── ModelManager.swift       # Model management
│   ├── OnboardingManager.swift  # First-run onboarding flow
│   ├── RetentionManager.swift   # Data retention policies
│   └── Tests/
│       ├── FeedbackRecentMetricSupportTests.swift # Feedback-export metric sanitization coverage
│       ├── InPageURLCaptureRoutingTests.swift
│       ├── MasterKeyManagerTests.swift
│       ├── TestLogger.swift
│       ├── TimelineStillDiskWriterTests.swift
│       └── UnexpectedRecordingStopHeuristicTests.swift # Unexpected-stop watchdog heuristic coverage
│
└── UI/                          # SwiftUI interface
    ├── AGENTS.md
    ├── RetraceApp.swift         # App entry point
    ├── ContentView.swift        # Root content view
    ├── CrashRecoveryHelper/     # Bundled crash-recovery XPC helper executable
    ├── CrashRecoverySupport/    # Shared crash-recovery support code for app + helper targets
    ├── LaunchAgents/            # Embedded SMAppService launch-agent plists
    ├── Components/              # Reusable UI components (MenuBarManager, HotkeyManager, etc.)
    │   ├── MasterKeyRedactionFlowCoordinator.swift # Shared missing-master-key prompt/recovery coordinator
    │   ├── HoverLatchedScrollMonitor.swift # Shared nested-scroll latch helper for hover-routed inner scroll regions
    │   └── ProcessMonitorModels.swift # System Monitor snapshot/models + ranking helpers
    ├── ViewModels/              # View models (Dashboard, Search, Timeline, Feedback, Settings)
    │   └── Settings/            # Settings-specific view models and extracted helper logic
    ├── Views/
    │   ├── Dashboard/           # App usage analytics views
    │   ├── FullscreenTimeline/  # Timeline scrubbing & playback (10 views)
    │   ├── Search/              # Search UI (SearchView, ResultRow, FrameViewer)
    │   ├── Settings/            # Settings shell, support components, and extracted section/action files
    │   │   └── Sections/        # Concern-split settings sections, verification flows, and shared actions
    │   ├── Onboarding/          # Onboarding flow
    │   └── Feedback/            # Feedback form, diagnostics presentation, and submission/export helpers
    └── Tests/
        ├── Dashboard/           # Dashboard-specific XCTestCase files
        ├── MenuBar/             # Menu bar XCTestCase files
        ├── Search/              # Search/deeplink XCTestCase files
        ├── Settings/            # Settings XCTestCase files
        ├── Support/             # Shared XCTest helpers and support-only tests
        ├── SystemMonitor/       # System monitor XCTestCase files
        └── Timeline/            # Timeline XCTestCase files
```

---

## Module Ownership & Responsibilities

| Module         | Directory     | Agent File             | Responsibility                                                     |
| -------------- | ------------- | ---------------------- | ------------------------------------------------------------------ |
| **DATABASE**   | `Database/`   | `Database/AGENTS.md`   | SQLite schema, FTS5, CRUD operations, migrations                   |
| **STORAGE**    | `Storage/`    | `Storage/AGENTS.md`    | File I/O, HEVC video encoding (working, not optimized), encryption |
| **CAPTURE**    | `Capture/`    | `Capture/AGENTS.md`    | CGWindowListCapture API, frame deduplication, metadata extraction  |
| **PROCESSING** | `Processing/` | `Processing/AGENTS.md` | Vision OCR, Accessibility API (no audio transcription yet)         |
| **SEARCH**     | `Search/`     | `Search/AGENTS.md`     | Query parsing, FTS5 queries, result ranking (no vector search yet) |
| **MIGRATION**  | `Migration/`  | `Migration/AGENTS.md`  | Import from Rewind AI (Rewind only, others planned)                |
| **APP**        | `App/`        | —                      | Coordinator, DI container, data adapter, lifecycle management      |
| **UI**         | `UI/`         | `UI/AGENTS.md`         | SwiftUI interface (timeline, dashboard, settings, search)          |

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

### Testing

- **Write tests first when behavior changes in a meaningful, testable way** - Follow TDD: RED -> GREEN -> REFACTOR when a reliable behavioral test exists
- **Test locations**: `{Module}/Tests/`
- **Test against protocols** - Not implementations
- **Mock dependencies** - Using protocol conformance
- **Do not widen tiny fixes into test work by default** - Single-line fixes, constant/default/threshold changes, disabling a debug guardrail, log-only changes, copy edits, formatting, and straightforward wiring corrections usually should not get new tests unless they add new branching logic or there is a clear regression case worth locking down
- **Do not add contrived tests for insignificant or non-behavioral edits** - Skip tests for copy tweaks, comments, formatting, tiny visual polish, mechanical renames, or other changes where no meaningful behavioral assertion exists
- **Prefer existing verification for narrow fixes** - For small changes, run the closest existing targeted tests or build checks first; add a new test only when it materially reduces recurrence risk
- **If tests are skipped, say why briefly** - Note that the change is insignificant or not behaviorally testable

### ⚠️ CRITICAL: Test with REAL Input Data, Not Fake Structures

Many tests "play cop and thief" - creating fake data structures and validating the fake data they created. This provides **zero confidence** about real system behavior.

**USELESS** — tests that Swift can assign struct fields:

```swift
let appInfo = AppInfo(bundleID: "com.apple.Safari", ...)
let result = AccessibilityResult(appInfo: appInfo, ...)
XCTAssertEqual(result.appInfo.bundleID, "com.apple.Safari")  // circular
```

**USEFUL** — tests that exercise real system APIs:

```swift
let tables = try await database.getTables()
XCTAssertTrue(tables.contains("segment"))  // validates real SQLite schema
```

**What makes a test useful:**

- ✅ Tests real system APIs (SQLite, FileManager, Vision OCR)
- ✅ Uses real production input (real screenshots, real OCR output)
- ✅ Validates end-to-end workflows (screenshot → OCR → database → search)
- ❌ NOT testing struct field assignment or string concatenation
- ❌ NOT adding low-signal tests just to satisfy policy for insignificant or non-behavioral edits

---

## Architecture & Data Flow

### Data Flow by Module

```
CAPTURE Module:
  Input:  CGWindowListCapture API (every 2 seconds)
  Output: CGImage + AppInfo metadata → deduplication (~95% filtered)

STORAGE Module (Video Path):
  Input:  CGImage stream
  Output: .mp4 file (HEVC encoded) → {AppPaths.storageRoot}/videos/

PROCESSING Module (OCR Path):
  Input:  CGImage
  Output: ExtractedText with OCRRegion[] (bounds + text)

DATABASE Module:
  Input:  AppInfo + ExtractedText + Video metadata
  Output: Core tables:
    • segment (app/window context)
    • frame (screenshot metadata)
    • node (OCR bounding boxes)
    • searchRanking (FTS5 full-text index)
    • doc_segment (linking table)
    • video (file metadata)

SEARCH Module:
  Input:  Query string (with filters: app:, date:, -exclude)
  Output: SearchResult[] with frameId + snippet + highlighting
```

### Database Relationships

```sql
segment (1) ──< (N) frame (N) >── (1) video
                    │
                    └──< (N) node

frame (1) ──< (1) doc_segment >── (1) searchRanking_content
```

### Architecture Diagram

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

| Component           | Technology              | Notes                                  |
| ------------------- | ----------------------- | -------------------------------------- |
| Language            | Swift 5.9+              | Actors, async/await, Sendable required |
| UI Framework        | SwiftUI                 | Fully implemented                      |
| Screen Capture      | CGWindowListCapture     | Legacy API, no privacy indicator       |
| Video Encoding      | VideoToolbox (HEVC)     | Hardware encoding on Apple Silicon     |
| OCR                 | Vision framework        | macOS native OCR                       |
| Database            | SQLite + FTS5           | Full-text search built-in              |
| Encryption          | CryptoKit (AES-256-GCM) | Optional on-device encryption          |
| Audio Transcription | whisper.cpp             | Planned (bundled but disabled)         |
| Vector Search       | llama.cpp               | Planned (prepared but not active)      |

---

## System Requirements

- **macOS**: 13.0+ (Ventura or later)
- **Hardware**: **Apple Silicon required** (M1/M2/M3) - Intel not supported
- **Permissions**:
  - Screen Recording permission (required)
  - Accessibility permission (required for app context extraction)

---

## Performance Targets

- **CPU**: <20% of single core during capture
- **Memory**: <1GB total app usage
- **Storage**: ~15-20GB per month of continuous use
- **Search**: <100ms for keyword search
- **OCR**: <500ms per frame on Apple Silicon

---

## Debug Logging

Use `Shared/Logging.swift` (`Log.debug`, `Log.info`, `Log.warning`, `Log.error`) with the correct category.

### Writing Debug Logs

```swift
Log.debug("[TIMELINE] Play button tapped", category: .ui)
Log.info("[TIMELINE] Playback started at \(position)", category: .ui)
```

### Best Practice: Scope Logs to User Actions

Prefer event-scoped logging over high-frequency frame-by-frame logging during normal debugging.

### Debugging Philosophy: Trace Execution First

**When debugging, add logging to trace the actual execution path BEFORE making assumptions.**

Don't assume you know which code is running. Add logs at each layer to verify:

```swift
Log.debug("[VM] Calling coordinator", category: .ui)
Log.debug("[COORDINATOR] Calling adapter", category: .app)
Log.debug("[ADAPTER] Taking FILTERED path", category: .database)  // Reveals which path
```

Then check which path actually executes and fix the right code.

---

## Critical Rules for All Agents

### 0. Issue-First Guidance for External Contributors

- If the user is fixing a **bug or crash** and does **not** appear to be the repo owner/maintainer, encourage them to create or link a GitHub issue before making code changes
- If an issue does not exist yet, point them to [AI_ISSUE_TEMPLATE.md](AI_ISSUE_TEMPLATE.md) and suggest `gh issue create --title ... --body-file ...` if they want to post it directly
- If ownership is unclear, make the recommendation as a lightweight prompt rather than a blocker

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

### 4. Testing is Required for Meaningful Behavior Changes

- Write tests BEFORE implementation when the change has meaningful, behaviorally testable impact
- Test against protocols, not implementations
- Cover edge cases thoroughly when behavior changes
- Do not treat every behavior-affecting tweak as a new-test trigger; one-line fixes and config/default/threshold flips should usually rely on existing coverage unless the bug has a stable reproducer or the new test is obviously high-value
- Do not add contrived tests for insignificant or non-behavioral edits
- All relevant tests must pass before submitting changes

### 5. Keep AGENTS.md Up-to-Date

- **Whenever you add, rename, move, or delete files/directories**, update the relevant `AGENTS.md` (root or module-level) in the **same commit**
- This includes: new Swift files, new subdirectories, new model/protocol types in `Shared/`, and changes to module structure
- If you notice AGENTS.md is out of date while working, fix it immediately — don't leave it for later
- The project structure tree, module ownership table, and shared type listings must always reflect reality

### 6. Main Thread & Hang Prevention (Mandatory)

- Treat the main thread as **UI-only**: state publication, view updates, input handling, and presentation.
- **Never** do blocking work on main for timeline/search open paths, startup checks, or settings pickers.
- Move heavy work off main (`Task.detached`, actors, background queues): SQLite/file validation, OCR, screenshot capture, metadata/icon lookup, image decode, and large layout calculations.
- **Do not use blocking primitives on UI paths**: `DispatchSemaphore.wait()`, `DispatchQueue.sync`, `Thread.sleep`, or equivalent blocking waits.
- For duplicate triggers (`onAppear` + controller calls), **coalesce** with an in-flight task/join pattern; do not silently skip important loads.
- In SwiftUI render paths (`body`, cell builders), avoid synchronous system/file APIs (`NSWorkspace`, `FileManager`, SQLite, image decoding). Use async caches/view models.
- Keep list/grid identity stable (`result.id`, model IDs). Avoid index-based IDs and avoid forcing full subtree recreation via generation `.id(...)` on large containers.
- Guard geometry/preference-driven state writes with an epsilon to prevent layout/preference feedback loops.
- Cache expensive derived layout data (timeline/treemap block geometry) with explicit invalidation keys (snapshot revision, frame count, zoom, etc.).
- Prefer natural `@Published` updates; avoid manual broad invalidation (`objectWillChange.send()`) unless there is a documented, minimal-scope reason.
- Instrument critical UX paths with `Log.recordLatency` and watch p50/p95 (timeline open, search open, live screenshot/OCR, picker validation). Regressions should block merge.
- Required smoke checks before merge for UI/perf-sensitive changes:
  - Timeline close → reopen (prerendered path): no stale tape, no hitching.
  - Search overlay open and navigate: no full-grid teardown thrash.
  - Settings/storage picker validation: no UI freeze while verifying paths.

### 7. Daily Metrics Instrumentation (Mandatory)

- **Any newly added feature or user action must add `daily_metrics` instrumentation in the same change**.
- Add a new `DailyMetricsQueries.MetricType` (and metadata schema) when no existing metric accurately represents the action.
- Wire the metric emission at the action entry/outcome points (for example: opened, submitted, succeeded, failed/no-results where applicable).

---

## Additional Resources

- **AGENTS.md Specification**: https://agents.md
- **Contribution Guide**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **Human README**: [README.md](README.md)

---

_This file follows the AGENTS.md standard for AI agent guidance. Last updated: 2026-04-04_
