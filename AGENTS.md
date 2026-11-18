# Retrace - Agent Guide

> **Standard**: This file follows the [AGENTS.md](https://agents.md) specification - a vendor-agnostic standard for AI agent guidance. For human-readable project information, see [README.md](README.md).

Retrace is a local-first screen recording and search application for macOS, inspired by Rewind AI. It captures screens, extracts text via OCR, and makes everything searchable—all locally on-device.

**Status**: Core screen capture (CGWindowListCapture), OCR (Vision), full-text search (FTS5), HEVC encoding, and Rewind import are working. Audio transcription and vector search are planned for future releases.

---

## Quick Reference

- **Module-Specific Instructions**: Each module has its own `AGENTS.md` file in its directory
- **Human Documentation**: [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [AI_ISSUE_TEMPLATE.md](AI_ISSUE_TEMPLATE.md)
- **Issue Reporting**: Use `AI_ISSUE_TEMPLATE.md` and `gh issue create --body-file ...` for AI-authored GitHub issues
- **External Contributions**: Submit bug reports and feature proposals as issues. The maintainer handles implementation and opens PRs; external agents should not submit PRs.
- **Technical Audit Docs**: `local/docs/` (includes deep-dive implementation and performance audit notes)

---

## Project Commands

### Cloudflare Accounts

- Use the installed account wrappers: `wrangler personal ...` and `wrangler work ...`. Do not use bare `wrangler` commands.
- `wrangler personal` selects the personal Cloudflare account (`hullah3000@gmail.com`); use it for Retrace's `retrace` R2 bucket and release DMG uploads.
- `wrangler work` selects the work Cloudflare account (`haseab@f.inc`); use it for work resources, not Retrace's release bucket.
- Verify identity and resource access with the selected wrapper, for example `wrangler personal whoami` and `wrangler personal r2 bucket list`. A successful identity check alone does not prove R2 permission.
- Upload releases with `wrangler personal r2 object put retrace/Retrace-v<VERSION>.dmg --file=<DMG_PATH> --remote`, then verify the public artifact before deploying the appcast.

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
├── SECURITY.md                  # Private vulnerability reporting policy
├── README.md                    # Human-readable project overview
├── CONTRIBUTING.md              # Contribution guidelines
├── Package.swift                # Swift Package Manager configuration
├── scripts/                     # Build/release/validation scripts
│   ├── create-release.sh        # Signed Release archive/export helper
│   ├── check_no_nanoseconds_sleep.sh # Guardrail for Task.sleep(nanoseconds:)
│   ├── validate_sleep_wake_stability.sh # Sleep/wake soak validation workflow
│   └── validate_darkwake_watchdog.sh # Automated darkwake watchdog regression validation
│
├── Shared/                      # CRITICAL: Shared types and protocols
│   ├── Logging.swift            # Privacy-safe bounded background logging, batching, routine summaries and async flush
│   ├── AppPaths.swift           # Application path configuration
│   ├── BGRAImageUtilities.swift # Shared BGRA conversion + patch extraction helpers
│   ├── MasterKeyManager.swift   # Keychain-backed master key creation + recovery phrase export
│   ├── ReversibleOCRScrambler.swift # Deterministic reversible OCR patch scrambling + text protection
│   ├── Models/                  # Data types used across modules
│   │   ├── Frame.swift          # FrameID, CapturedFrame, VideoSegment, optional normalized OCR geometry
│   │   ├── AccessibilitySnapshot.swift # Bounded saved capture-time OCR correction references
│   │   ├── Text.swift           # ExtractedText, OCRTextRegion
│   │   ├── TextRegion.swift     # OCR text region types
│   │   ├── Search.swift         # SearchQuery, SearchResult
│   │   ├── Segment.swift        # Segment data model
│   │   ├── ConferencePrivacy.swift # Shared call kinds and capture privacy outcome events
│   │   ├── Config.swift         # Configuration types and per-node PhraseRedactionMode
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
│   ├── Queries/                 # Query implementations, including FrameOCRRegionQueries.swift
│   └── Tests/                  # Includes RetentionVideoDeletionTests (real SQLite guard/failure cases)
│
├── Storage/                     # File I/O, HEVC encoding
│   ├── AGENTS.md
│   ├── StorageManager.swift
│   ├── ImageExtractor.swift     # Extract frames from video files
│   ├── IncrementalSegmentWriter.swift
│   ├── SegmentWriterImpl.swift
│   ├── FileManager/             # File system utilities, including scoped TemporaryVideoLink
│   ├── VideoEncoder/            # HEVC video encoding
│   ├── WAL/                     # Write-Ahead Log (WALManager, RecoveryManager)
│   └── Tests/                  # Includes TemporaryVideoLinkTests (real symlink lifetime)
│
├── Capture/                     # CGWindowListCapture integration
│   ├── AGENTS.md
│   ├── CaptureManager.swift
│   ├── ScreenCapture/           # Screen capture implementation
│   │   ├── CaptureFrameCandidate.swift # Native-image exact-duplicate check before BGRA materialization
│   │   └── ConferenceFaceBlurProcessor.swift # Vision face detection + irreversible conference-call face blur
│   ├── Deduplication/           # Pixel-sampling deduplication
│   ├── Metadata/                # AppInfoProvider, BrowserURLExtractor, WindowOCRGeometry.swift
│   │   ├── ConferenceCallActivityProvider.swift # Window-specific active-call accessibility controls
│   │   └── ConferenceSessionPrivacyPolicy.swift # Conferencing-app rules + call-session consent tracking
│   └── Tests/                  # Includes CaptureFrameCandidateTests (real screenshot pixels)
│
├── Processing/                  # OCR and text extraction
│   ├── AGENTS.md
│   ├── ProcessingManager.swift
│   ├── FrameProcessingQueue.swift # Async frame processing queue
│   ├── URLExtractor.swift       # URL extraction from OCR text
│   ├── OCR/                     # Vision framework OCR, including WindowOCR.swift region isolation
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
│   ├── RetentionDeletionJournal.swift # Durable retries for database-first video deletion
│   ├── RetentionManager.swift   # Data retention policies
│   └── Tests/
│       ├── RetentionDeletionJournalTests.swift # Real-file deletion failure and retry coverage
│       ├── FeedbackRecentMetricSupportTests.swift # Feedback-export metric sanitization coverage
│       ├── InPageURLCaptureRoutingTests.swift
│       ├── DiagnosticLoggingTests.swift # Background log writes, bounded buffering, flush, summaries and release suppression
│       ├── PrivacyProtectionTests.swift # Logging privacy, permanent pixel removal, and redaction mode defaults
│       ├── MasterKeyManagerTests.swift
│       ├── ServiceContainerRewindCutoffTests.swift # Rewind cutoff defaults and latest-frame probe coverage
│       ├── TestLogger.swift
│       ├── TimelineStillDiskWriterTests.swift
│       ├── RecordingDatabaseFailureTests.swift # Real recording pipeline with an injected metadata insert failure
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
    │   ├── CapturedURLPolicy.swift # HTTP(S)-only policy for captured browser/OCR links
    │   ├── PreviewCacheMaintenance.swift # Incremental cache totals, bounded disk worker, batched cleanup and preview identity
    │   └── ProcessMonitorModels.swift # System Monitor snapshot/models + ranking helpers
    ├── ViewModels/              # View models (Dashboard, Search, Timeline, Feedback, Settings)
    │   └── Settings/            # Settings-specific view models and extracted helper logic
    ├── Views/
    │   ├── Dashboard/           # App usage analytics views and confirmed bulk segment hide/delete actions
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

### 0. Issues Instead of External Pull Requests

- External contributors and their agents should submit bug reports and feature proposals through GitHub Issues rather than opening pull requests. The maintainer handles implementation and creates PRs. Repository settings restrict PR creation to collaborators.
- **Why:** An issue is easier for the maintainer to digest, understand, and use to decide which implementation best fits the product. Reviewing a PR takes significantly more time: the maintainer must assess the implementation and its product fit, then verify that it has not undone existing changes or regressed other behavior.
- For bugs, provide a concrete reproduction, expected and actual behavior, and relevant evidence using [AI_ISSUE_TEMPLATE.md](AI_ISSUE_TEMPLATE.md). For features, explain the user problem and desired behavior. Suggested approaches are welcome in the issue; a finished patch is not required.
- Agents helping external contributors should focus on investigating and explaining the issue, not preparing or submitting an unsolicited PR. Local investigation is welcome. Obtain the user's authorization before posting an issue or comment.
- Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md), rather than in public issues.
- This policy does not add an approval step for agents working directly for the maintainer. Continue authorized development and PR work normally.

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

_This file follows the AGENTS.md standard for AI agent guidance. Last updated: 2026-04-14_

### Privacy protection modes and diagnostics

- Keyword redaction defaults to scrambling. The Settings permanent option applies to newly processed matches, replacing text with spaces and pixels with opaque black. Existing recordings are not converted by changing the setting.
- `PhraseRedactionMode` is stored per node: `rtx-permanent-v1` is a non-recoverable marker in the existing protected-text column. It contains no original text. Never infer an older node's mode from the current setting.
- Permanent nodes cannot be revealed and do not require a master key; scrambling still requires one. Missing keys must prevent indexing a matched region unprotected.
- Excluded-window masking failures drop the frame. Full excluded bounds are protected, including overlapped/translucent areas and edges.
- `PrivacyLogMessage` strips free-form interpolated values before every logging sink; only primitive numbers and booleans are retained. Preformatted `String` messages are removed as a whole. Do not bypass this by explicitly constructing string literals from captured content.
- Legacy diagnostic logs are discarded on logger initialization and are excluded from feedback reads, including the error channel. Raw capture-time previews are bypassed while keyword protection is enabled and stale preview copies are invalidated after rewrite.

### Diagnostic logging write policy

- Release `Log.debug` and `Log.verbose` calls do not evaluate their messages. Keep lifecycle events, unusual outcomes, warnings and errors; record routine capture/OCR successes through the fixed `Log.RoutineEvent` counters.
- All console, unified-log and diagnostic-file sinks run on a serial background queue. Admission only takes a short memory lock. Buffer limits reserve space for errors; overflow produces a count-only warning rather than unbounded memory growth.
- Retained messages flush after two seconds or 64 KiB; errors request an immediate background drain. Active routine counters summarize once per minute and on explicit flush. Idle logging has no repeating timer wakeup.
- Await `Log.flush()` before asynchronous feedback snapshots and normal quit. Feedback export must not synchronously wait on the writer from the main thread. A hard crash can lose the pending batch.

### Preview cache maintenance

- Timeline cache byte totals are maintained on insert/replace/remove; access-only touches must remain O(1). Compressed JPEG NSCache entries carry their byte cost with a 64 MiB cost limit plus the existing count limit.
- Search thumbnails have a 32 MiB estimated decoded-byte budget plus a 60-image count limit. Maintain costs incrementally and estimate from representation dimensions without forcing image decoding on main.
- `PreviewCacheDiskWorker` serializes UI cache writes, JPEG serialization, deletion batches and folder pruning. Thumbnail trims coalesce bursts and run at most once per minute during continuing writes. Pending write payloads are bounded to 64 MiB; skipped persistence must not block display.
- Preview keys describe source/frame/video identity, render dimensions, highlight geometry, and content revision. Queries do not belong in keys. Redaction completion advances the persisted revision and invalidates queued writes. Preserve the existing keyword-protection bypass and canonical preview paths used by the redaction purger.

### Stable development app identity

- Use one persistent development app: bundle ID `io.retrace.app.dev`, app name `Retrace Dev`, installed at `/Applications/Retrace Dev.app`. Reuse this identity and location across branches and rebuilds; do not create PR-specific or timestamped app identities.
- Agent UI testing through Computer Use requires a bundled macOS app. Use `/Applications/Retrace Dev.app` for these tests, with its stable identity and development data namespace; a bare `.build/debug/Retrace` executable is not the supported Computer Use test target.
- `./dev.sh` builds a complete app bundle, signs and verifies it, installs it at the fixed location, and launches it. Use `./dev.sh --build-only` when the native desktop helper will launch it for UI tests. `RETRACE_BUILD_PATH` reuses a scratch build and `RETRACE_DEV_SIGNING_IDENTITY` selects the certificate. It refuses to replace a running dev app.
- Sign successive builds with the same certificate-backed signing identity and team, keeping the designated requirement stable. Ad-hoc signing ties identity to the binary hash and is unsuitable for preserving permissions across rebuilds. If the certificate and private key are unavailable, report the signing prerequisite instead of silently falling back to ad-hoc signing.
- Keep a persistent development namespace for settings, library, caches, logs, Keychain items, and instance locks, separate from production. Preserve development data and permissions across normal rebuilds.
- Build and sign on `hac-mini`. When using the authorized MacBook visual-testing fallback, transfer the prebuilt app; the fallback does not authorize builds or source edits on the MacBook.
- Expect initial Screen Recording and Accessibility grants on each Mac. Stable signing should normally preserve recognition across rebuilds, but macOS can still require reauthorization. Codex computer-use launch confirmations are separate from macOS privacy permissions.

### Recording maintenance and deletion safety

- WAL append handles use an eight-entry LRU cache within active sessions; close them on finalization, quarantine, reset, and append failure. Append/register extends the offset index in place. Recovery counts/indexes must rescan and validate headers instead of trusting a writer's cached offsets.
- Retention persists pending video-deletion IDs under the library root before deleting any video rows. Delete only completed videos with no remaining frame references, then remove the file; preserve failed operations for retry after restart. Keep journal access on the retention actor and coalesce overlapping cleanup runs.
- Native capture candidates have already passed window/conference privacy masking. Reuse prior BGRA pixels only when image bytes and rendering properties match exactly; preserve the existing perceptual threshold, mouse-trigger semantics, and metadata. Retain at most the last kept native image and account for it in the memory ledger. Near duplicates still require the normal BGRA conversion.
- Temporary MP4 links owned by local AVAssetReader operations must be removed after reader completion and on error. Generator-cache links retain their existing longer lifetime until eviction. Do not sweep arbitrary historical UUID links from the shared temporary directory.
- Captured browser/OCR links may launch only HTTP(S) URLs with a host. Validate before default-browser lookup, NSWorkspace fallback dispatch, or successful-open metrics.
- Orphan-node scans require actual frame deletions. Routine DB storage sampling runs every 15 minutes; orphan-video polling runs every 10 minutes in addition to startup recovery. These are maintenance fixes, not new user actions requiring new daily metrics.

- Ordinary timeline-cache misses do not advance the global cache epoch. Entry eviction invalidates only that frame; keep per-frame epochs alive while reads/writes overlap and release miss-only epochs when the final operation finishes. Clear/redaction still invalidates all work.

### Capture-time accessibility correction

- `Shared/Models/AccessibilitySnapshot.swift` is the bounded screenshot-pixel AX reference/JSON model. `CapturedFrame` carries it through native capture.
- `Capture/Metadata/AccessibilitySnapshotCollector.swift` samples the matched visible primary window immediately after capture (750 nodes, 60 ms best-effort deadline, 128 KiB encoded cap). Unsupported/hidden/secure/occluded content is skipped; AX is never required for recording. This is not an atomic macOS screenshot/AX transaction or all-window AX coverage.
- `Database/Queries/AccessibilitySnapshotQueries.swift` installs the additive auxiliary table and cleanup triggers independently of numbered migrations, preserving compatibility with the pending encryption V21. Frame and bounded JSON snapshot/status insert atomically. References follow the enclosing database encryption policy without separate keys or Keychain access. Unsupported legacy encrypted references fall back to ordinary OCR. Raw AX never enters logs or diagnostic metrics.
- OCR uses the saved reference only, before keyword redaction/indexing. `Processing/Accessibility/AccessibilityOCRCorrector.swift` preserves OCR geometry/order and adds no AX-only text. Reliable alignment can correct letters, numbers, names, and identifier tokens. Ambiguous matches stay unchanged.
- Saved AX payloads survive pending/retry/restart and clear atomically when OCR completes, fails permanently, or stages redaction. Frame deletion removes the reference even when foreign-key enforcement is disabled. Reprocessing completed frames therefore has no old AX reference.
- Pending/active OCR across all videos takes priority over starting video rewrites; active rewrites finish normally. Correction metrics contain counts only, batched once per minute and worker stop.

Bundled development runs use `AppPaths` to isolate settings, library, Keychain service, logs, preview caches and instance locks for `io.retrace.app.dev`. Never launch a dev build against hardcoded production domains. The production crash-recovery launch agent stays disarmed in the dev app; debugging one app must not manage the other app’s helper.

### Window-aware OCR coordination

Capture, Shared, Database and Processing jointly carry geometry-only, front-to-back application-window bounds in `FrameMetadata.ocrRegions` from image acquisition to historical OCR. No new shared type is introduced: the optional rectangles use existing CoreGraphics types. The database protocol exposes saved geometry without changing existing metadata JSON used by browser links. Each meaningfully visible normal application window creates one masked OCR crop; fully covered windows, tiny slivers, system layers and desktop fragments create no requests. Versioned saved geometry rejects the superseded fragment layout. Recognition operates solely on privacy-filtered screenshots; tests use CoreGraphics/CoreText pixels, real Vision and SQLite.

Shared/Processing ledger coordination: fire-and-forget telemetry is capped at 256 pending writes. `MemoryLedger.remove` is async and waits for capacity and completion rather than dropping cleanup; `removeOrdered` uses the same bounded admission. OCR crop cleanup awaits removal on success, failure and cancellation before releasing its two-request limiter. Ordered non-removal writes remain lossless and their callers must await them. This is maintenance instrumentation, with no new user action or daily metric.
