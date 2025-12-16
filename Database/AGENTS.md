# DATABASE Agent Instructions

You are responsible for the **Database** module of Retrace. Your job is to implement SQLite database operations including schema, migrations, CRUD operations, and full-text search indexing.

## Your Directory

```
Database/
├── DatabaseManager.swift      # Main DatabaseProtocol implementation
├── FTSManager.swift           # FTSProtocol implementation
├── Schema.swift               # Table definitions
├── Migrations/
│   ├── MigrationRunner.swift  # Run migrations in order
│   └── V1_InitialSchema.swift # Initial schema migration
├── Queries/
│   ├── FrameQueries.swift     # Frame CRUD operations
│   ├── SegmentQueries.swift   # Segment CRUD operations
│   └── DocumentQueries.swift  # Document/FTS operations
└── Tests/
    ├── DatabaseManagerTests.swift
    └── FTSManagerTests.swift
```

## Protocols You Must Implement

### 1. `DatabaseProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
- Frame CRUD operations
- Segment CRUD operations
- Document CRUD operations
- Statistics

### 2. `FTSProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
- Full-text search queries
- Match counting
- Index maintenance

## Schema Design

### Tables

```sql
-- Video segments (container files)
CREATE TABLE segments (
    id TEXT PRIMARY KEY,           -- SegmentID UUID
    start_time INTEGER NOT NULL,   -- Unix timestamp ms
    end_time INTEGER NOT NULL,     -- Unix timestamp ms
    frame_count INTEGER NOT NULL,
    file_size_bytes INTEGER NOT NULL,
    relative_path TEXT NOT NULL,
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);

-- Individual frames
CREATE TABLE frames (
    id TEXT PRIMARY KEY,           -- FrameID UUID
    segment_id TEXT NOT NULL,      -- FK to segments
    timestamp INTEGER NOT NULL,    -- Unix timestamp ms
    frame_index INTEGER NOT NULL,  -- Index within segment
    duration_ms INTEGER DEFAULT 2000,
    app_bundle_id TEXT,
    app_name TEXT,
    window_title TEXT,
    browser_url TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    FOREIGN KEY (segment_id) REFERENCES segments(id) ON DELETE CASCADE
);

-- Indexed documents for FTS
CREATE TABLE documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id TEXT NOT NULL UNIQUE, -- FK to frames
    content TEXT NOT NULL,         -- Full extracted text
    app_name TEXT,
    window_title TEXT,
    browser_url TEXT,
    timestamp INTEGER NOT NULL,
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);

-- FTS5 virtual table
CREATE VIRTUAL TABLE documents_fts USING fts5(
    content,
    app_name,
    window_title,
    content='documents',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
    INSERT INTO documents_fts(rowid, content, app_name, window_title)
    VALUES (new.id, new.content, new.app_name, new.window_title);
END;

CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, content, app_name, window_title)
    VALUES ('delete', old.id, old.content, old.app_name, old.window_title);
END;

CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, content, app_name, window_title)
    VALUES ('delete', old.id, old.content, old.app_name, old.window_title);
    INSERT INTO documents_fts(rowid, content, app_name, window_title)
    VALUES (new.id, new.content, new.app_name, new.window_title);
END;

-- Indexes
CREATE INDEX idx_frames_timestamp ON frames(timestamp);
CREATE INDEX idx_frames_segment ON frames(segment_id);
CREATE INDEX idx_frames_app ON frames(app_bundle_id);
CREATE INDEX idx_segments_time ON segments(start_time, end_time);
CREATE INDEX idx_documents_timestamp ON documents(timestamp);
```

## Key Implementation Details

### 1. Use SQLite Directly
- Use the C SQLite API via Swift's bridging (or a lightweight wrapper like GRDB)
- Enable WAL mode for concurrent reads during writes
- Enable FTS5 extension

```swift
sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
```

### 2. Actor-Based Thread Safety
```swift
public actor DatabaseManager: DatabaseProtocol {
    private var db: OpaquePointer?

    public func initialize() async throws {
        // Open database
        // Run migrations
        // Enable WAL mode
    }
}
```

### 3. Migration System
```swift
protocol Migration {
    static var version: Int { get }
    static func migrate(db: OpaquePointer) throws
}

// Track applied migrations
CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

### 4. FTS Search with Snippets
```swift
func search(query: String, limit: Int, offset: Int) async throws -> [FTSMatch] {
    let sql = """
        SELECT
            d.id, d.frame_id, d.timestamp, d.app_name, d.window_title,
            snippet(documents_fts, 0, '<mark>', '</mark>', '...', 32) as snippet,
            bm25(documents_fts) as rank
        FROM documents_fts
        JOIN documents d ON documents_fts.rowid = d.id
        WHERE documents_fts MATCH ?
        ORDER BY rank
        LIMIT ? OFFSET ?
    """
    // Execute and map results
}
```

### 5. Date Handling
- Store all dates as Unix timestamps in milliseconds (INTEGER)
- Convert to/from Swift `Date` using:
```swift
let timestampMs = Int64(date.timeIntervalSince1970 * 1000)
let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw DatabaseError.queryFailed(query: sql, underlying: errorMessage)
throw DatabaseError.connectionFailed(underlying: errorMessage)
```

## Testing Strategy (TDD Philosophy)

### Core Principles

**Test-Driven Development (TDD)** is mandatory for this module. The goal is to have such comprehensive tests that you can confidently deploy based solely on tests passing—no manual inspection needed.

**The TDD Cycle:**
```
1. Write failing test (RED)
2. Write minimum code to pass (GREEN)
3. Refactor (REFACTOR)
4. Repeat
```

### Test Categories

We maintain 6 categories of tests, each serving a specific purpose:

#### 1. Schema Validation Tests (`SchemaValidationTests.swift`)
**Purpose:** Verify all SQL statements in `Schema.swift` compile correctly.
**What they catch:** Typos, syntax errors, missing commas, invalid SQL.

```swift
func testCreateFramesTable_IsValidSQL() {
    assertValidSQL(Schema.createSegmentsTable)
    assertValidSQL(Schema.createAppSessionsTable)
    assertValidSQL(Schema.createFramesTable)  // Depends on above
}
```

#### 2. Migration Tests (`MigrationTests.swift`)
**Purpose:** Verify migrations run correctly and create expected schema.
**What they catch:** Migration ordering issues, missing tables/indexes/triggers.

```swift
func testV1Migration_CreatesAllCoreTables() async throws {
    let runner = MigrationRunner(db: db!)
    try runner.runMigrations()
    XCTAssertTrue(tableExists("frames"))
}
```

#### 3. Query Builder Tests (`QueryBuilderTests.swift`)
**Purpose:** Unit test individual query builder methods in isolation.
**What they catch:** SQL bugs, parameter binding errors, parsing issues.

#### 4. Edge Case Tests (`EdgeCaseTests.swift`)
**Purpose:** Test boundary conditions, null handling, special characters.
**What they catch:** Bugs that only appear with unusual inputs.

- Empty database queries (should return nil/empty, not crash)
- Null/optional fields stored and retrieved correctly
- Unicode, emoji, special characters
- SQL injection attempts (should be stored literally, not executed)
- Very long content
- Boundary timestamps (exact start/end, 1ms outside)
- Zero limits, huge offsets
- Duplicate ID handling

#### 5. Integration Tests (`IntegrationTests.swift`)
**Purpose:** Test complete workflows end-to-end.
**What they catch:** Module interaction bugs, cascade issues.

```swift
func testFullCaptureToSearchFlow() async throws {
    // 1. Create segment (simulate capture)
    // 2. Create frame with metadata
    // 3. Index document (simulate OCR)
    // 4. Search and find content
}
```

#### 6. FTS Manager Tests (`FTSManagerTests.swift`)
**Purpose:** Test full-text search functionality.
**What they catch:** Search bugs, ranking issues, filter problems.

### Writing New Tests

When adding any new feature, ALWAYS write the test first:

```swift
// 1. Write test (will fail - method doesn't exist)
func testNewFeature() async throws {
    let result = try await database.newMethod()
    XCTAssertEqual(result, expectedValue)
}

// 2. Run test → RED (fails)
// 3. Write minimum code to pass
// 4. Run test → GREEN (passes)
// 5. Refactor if needed
```

### Test File Structure

```
Database/Tests/
├── SchemaValidationTests.swift    # SQL syntax validation
├── MigrationTests.swift           # Migration execution
├── QueryBuilderTests.swift        # Query builder unit tests
├── EdgeCaseTests.swift            # Boundaries, nulls, errors
├── IntegrationTests.swift         # End-to-end workflows
├── DatabaseManagerTests.swift     # Manager-level tests
└── FTSManagerTests.swift          # Search tests
```

### Running Tests

```bash
swift test                                    # All tests
swift test --filter SchemaValidationTests    # Specific file
swift test --filter testFullCaptureToSearchFlow  # Specific test
```

### Test Checklist Before Deploying

- [ ] All schema SQL compiles
- [ ] Migration creates all tables/indexes/triggers
- [ ] Foreign keys enforced, cascades work
- [ ] Null fields handled correctly
- [ ] Unicode/special chars work
- [ ] SQL injection prevented
- [ ] Empty database queries don't crash
- [ ] Search finds correct content
- [ ] Search filters work
- [ ] Statistics accurate
- [ ] Concurrent access safe

## Dependencies

- **Input from**: PROCESSING module (ExtractedText to index)
- **Output to**: SEARCH module (FTSMatch results)
- **Uses types**: `FrameID`, `SegmentID`, `FrameReference`, `VideoSegment`, `IndexedDocument`, `FTSMatch`, `SearchFilters`

## DO NOT

- Modify any files outside `Database/`
- Import from other module directories (only `Shared/`)
- Create custom types that duplicate `Shared/Models/`
- Use Core Data or other ORMs—use SQLite directly
- Store binary data (images/video) in the database

## Performance Targets

- Insert: <5ms per frame
- Search: <100ms for typical queries
- Database size: <500MB per month of metadata
- Support 1M+ documents efficiently

## Getting Started

1. Create `Database/Schema.swift` with table definitions
2. Create `Database/Migrations/V1_InitialSchema.swift`
3. Implement `DatabaseManager` conforming to `DatabaseProtocol`
4. Implement `FTSManager` conforming to `FTSProtocol`
5. Write tests for all CRUD operations
6. Write tests for FTS search

Start with the schema and migrations, then build up the query layer.

## Schema Updates (V3)

### New Tables

#### 1. `app_sessions` - Application Focus Tracking

Tracks periods where a specific application had focus, similar to Rewind's "segment" concept.

```sql
CREATE TABLE app_sessions (
    id TEXT PRIMARY KEY,
    app_bundle_id TEXT NOT NULL,
    app_name TEXT,
    window_title TEXT,
    browser_url TEXT,
    display_id INTEGER,
    start_time INTEGER NOT NULL,
    end_time INTEGER,                    -- NULL = still active
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

**Why?**: UI needs to group frames by app session for timeline visualization. Without this, you'd have to scan all frames to determine session boundaries.

**Usage**: When app focus changes, close current session and create new one. Link frames to sessions for efficient queries like "show all Chrome usage today."

#### 2. `encoding_queue` - Async Encoding Jobs

Manages asynchronous frame encoding pipeline for both Intel (CPU) and Apple Silicon (hardware).

```sql
CREATE TABLE encoding_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id TEXT NOT NULL UNIQUE,
    priority INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    error_message TEXT,
    status TEXT DEFAULT 'pending',       -- pending, encoding, success, failed, cancelled
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    updated_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);
```

**Why?**: Encoding can be slow on Intel Macs. Async processing prevents blocking capture thread.

**Workflow**:
1. Frame captured → insert into `frames` with `encoding_status='pending'`
2. Add job to `encoding_queue` with priority
3. Background worker picks up job, encodes, updates status to 'success'
4. On failure, increment `retry_count` and requeue

#### 3. `deletion_queue` - Async Cleanup

Implements deferred deletion for responsive UI (inspired by Rewind's `purge` table).

```sql
CREATE TABLE deletion_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,            -- 'frame', 'segment', 'document', 'app_session'
    entity_id TEXT NOT NULL,
    file_path TEXT,                       -- Video file to delete (if applicable)
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

**Why?**: Deleting large video files blocks UI. Queue deletions for background processing.

**Workflow**:
1. User clicks delete → queue entity in `deletion_queue`
2. UI immediately hides entity (responds instantly)
3. Background job on next app launch:
   - Delete SQLite rows
   - Delete video files from disk
   - Remove from queue

### Updated Tables

#### `segments` - Added Dimensions

```sql
ALTER TABLE segments ADD COLUMN width INTEGER NOT NULL;
ALTER TABLE segments ADD COLUMN height INTEGER NOT NULL;
ALTER TABLE segments ADD COLUMN source TEXT DEFAULT 'native';
```

**Why?**: Multi-monitor setups have different resolutions. Need to know dimensions for proper video playback and timeline scrubbing.

#### `frames` - Added Encoding Status and Session Link

```sql
ALTER TABLE frames ADD COLUMN encoding_status TEXT DEFAULT 'pending';
ALTER TABLE frames ADD COLUMN session_id TEXT REFERENCES app_sessions(id) ON DELETE SET NULL;
ALTER TABLE frames ADD COLUMN source TEXT DEFAULT 'native';
```

- `encoding_status`: Track async encoding pipeline state
- `session_id`: Link frame to app session for efficient grouping
- `source`: Distinguish native captures from imported data (`'native'`, `'rewind'`, `'screen_memory'`, etc.)

**Note**: Removed `duration_ms` - it was always 2000ms (fixed capture rate). Can derive from timestamp gaps if needed.

### Migration Strategy

Existing databases (V1/V2) will automatically upgrade via migrations:
- V2: Add `source` column (for third-party import support)
- V3: Add dimensions, encoding_status, session_id, new tables

New installations get V3 schema immediately (no migrations needed).

### Indexes

Critical indexes for performance:

```sql
-- App sessions
CREATE INDEX idx_app_sessions_time ON app_sessions(start_time, end_time);
CREATE INDEX idx_app_sessions_app ON app_sessions(app_bundle_id);

-- Encoding queue
CREATE INDEX idx_encoding_queue_status ON encoding_queue(status, priority DESC);

-- Deletion queue
CREATE INDEX idx_deletion_queue_type ON deletion_queue(entity_type);

-- Frames (updated)
CREATE INDEX idx_frames_session ON frames(session_id);
CREATE INDEX idx_frames_encoding_status ON frames(encoding_status);
CREATE INDEX idx_frames_source ON frames(source);
```

### Junction Tables - Critical at 40GB+ Scale

#### `document_sessions` - Fast Search Filtering

**The Problem**:
```sql
-- Slow query (3 JOINs on millions of rows)
SELECT d.*, f.*, s.*
FROM documents_fts
JOIN documents d ON d.id = documents_fts.rowid
JOIN frames f ON f.id = d.frame_id
JOIN app_sessions s ON s.id = f.session_id
WHERE documents_fts MATCH 'error'
  AND s.app_bundle_id = 'com.google.Chrome';
```

At Rewind's 26 MB/hour text growth rate, you'd have **~18 million documents** after a year. Those JOINs are brutal.

**The Solution**:
```sql
CREATE TABLE document_sessions (
    document_id INTEGER NOT NULL,
    session_id TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    PRIMARY KEY (document_id, session_id),
    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES app_sessions(id) ON DELETE CASCADE
);
```

**Fast Query** (pre-joined, indexed lookup):
```sql
SELECT d.*, s.*
FROM documents_fts
JOIN documents d ON d.id = documents_fts.rowid
JOIN document_sessions ds ON ds.document_id = d.id
JOIN app_sessions s ON s.id = ds.session_id
WHERE documents_fts MATCH 'error'
  AND s.app_bundle_id = 'com.google.Chrome';
```

Avoids scanning `frames` table (largest table) entirely.

**Maintenance**: Populate when indexing documents:
```sql
INSERT INTO document_sessions (document_id, session_id, timestamp)
SELECT d.id, f.session_id, d.timestamp
FROM documents d
JOIN frames f ON f.id = d.frame_id;
```

#### `session_segments` - Efficient Video Retrieval

Links app sessions to video segments for fast playback.

**Why needed**:
- One session can span multiple 5-minute video segments
- One video segment can contain multiple app sessions (e.g., switching apps mid-segment)
- Many-to-many relationship requires junction table

**Usage**: "Play video of all Chrome usage between 2-3pm"
```sql
SELECT DISTINCT seg.*
FROM app_sessions s
JOIN session_segments ss ON ss.session_id = s.id
JOIN segments seg ON seg.id = ss.segment_id
WHERE s.app_bundle_id = 'com.google.Chrome'
  AND s.start_time BETWEEN ? AND ?;
```

Without this, you'd have to:
1. Find all frames in time range + app filter
2. Group by segment_id
3. Load each segment

With junction table: direct segment lookup.

#### `text_regions` - OCR Bounding Boxes

Stores spatial coordinates of detected text (inspired by Rewind's `node` table).

```sql
CREATE TABLE text_regions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id TEXT NOT NULL,
    text TEXT NOT NULL,
    x INTEGER NOT NULL,
    y INTEGER NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    confidence REAL,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);
```

**Critical for UI**: Click search result → jump to exact location on frame with highlighting.

**Storage cost**: ~150GB (200 bytes × 50 regions/frame × 15M frames). Worth it for professional UX.

#### `audio_captures` - Speech-to-Text (Future)

Scaffolding for audio transcription (Zoom/Meet/Teams).

```sql
CREATE TABLE audio_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    text TEXT NOT NULL,
    start_time INTEGER NOT NULL,
    end_time INTEGER NOT NULL,
    speaker TEXT,
    source TEXT,                    -- 'zoom', 'system', 'microphone'
    confidence REAL,
    FOREIGN KEY (session_id) REFERENCES app_sessions(id) ON DELETE SET NULL
);
```

**Not implemented yet** - schema ready for v2 feature.

### Key Design Decisions

1. **App Sessions separate from Frames**: Cleaner queries, mirrors Rewind's architecture
2. **Junction tables**: **Critical for 40GB+ databases** - avoids expensive JOINs at query time
3. **Text regions**: **150GB storage** but essential for click-to-zoom UI
4. **Audio captures**: Future-proof for speech-to-text (v2)
5. **Async encoding**: Supports both Intel (slow) and Apple Silicon (fast) without blocking
6. **Deferred deletion**: Responsive UI, safe cleanup on next launch
7. **Source column**: Import Rewind/ScreenMemory/TimeScroll data
8. **Dimensions in segments**: Multi-monitor support

### Performance at Scale

With junction tables and proper indexes:
- **Search with app filter**: <100ms (vs 5-10s without junction tables)
- **Video segment lookup**: <10ms (vs 1-2s scanning frames)
- **Database size**: ~500MB metadata/month + ~150GB text regions + ~50MB junctions

Trade-off: Slightly more complex writes (populate junction tables + text regions), but **massive** read speedups and professional UI.
