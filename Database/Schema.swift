import Foundation
import SQLCipher

// MARK: - SQLite Constants

/// SQLITE_TRANSIENT constant for Swift - tells SQLite to make its own copy of the string
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      REWIND-COMPATIBLE DATABASE SCHEMA                       ║
// ║                                  Version 1                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝
//
// ┌─────────────────────────────────────────────────────────────────────────────┐
// │                              SCHEMA OVERVIEW                                 │
// ├─────────────────────────────────────────────────────────────────────────────┤
// │  Based on Rewind AI's proven architecture (238 days, 212M nodes, 2.3M frames) │
// │                                                                             │
// │   ┌──────────────┐       ┌──────────────┐       ┌──────────────────┐       │
// │   │   segment    │──────<│    frame     │>──────│      video       │       │
// │   │ (sessions)   │ 1:N   │  (captures)  │  N:1  │   (metadata)     │       │
// │   └──────────────┘       └──────┬───────┘       └──────────────────┘       │
// │                                 │                                           │
// │                                 │ 1:N                                       │
// │                                 ▼                                           │
// │                          ┌──────────────┐                                   │
// │                          │     node     │                                   │
// │                          │ (OCR boxes)  │                                   │
// │                          └──────────────┘                                   │
// │                                                                             │
// │   ┌─────────────────────────────────────────┐                               │
// │   │  searchRanking (FTS5)                   │                               │
// │   │  searchRanking_content (text storage)   │                               │
// │   └─────────────────────────────────────────┘                               │
// │                                                                             │
// │   Supporting: audio, transcript_word, event, summary, doc_segment           │
// │                                                                             │
// └─────────────────────────────────────────────────────────────────────────────┘

/// SQL schema definitions for Rewind-compatible Retrace database
/// Owner: DATABASE agent
enum Schema {

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │                            SCHEMA VERSION                               │
    // └─────────────────────────────────────────────────────────────────────────┘

    static let currentVersion = 1

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │                             TABLE NAMES                                 │
    // └─────────────────────────────────────────────────────────────────────────┘

    enum Tables {
        // Core tables
        static let segment = "segment"
        static let frame = "frame"
        static let node = "node"
        static let video = "video"

        // Audio tables
        static let audio = "audio"
        static let transcriptWord = "transcript_word"

        // FTS tables
        static let searchRanking = "searchRanking"
        static let searchRankingContent = "searchRanking_content"

        // Event/Meeting tables
        static let event = "event"
        static let summary = "summary"

        // Utility tables
        static let docSegment = "doc_segment"
        static let videoFileState = "videoFileState"
        static let frameProcessing = "frame_processing"
        static let purge = "purge"

        // Meta
        static let schemaMigrations = "schema_migrations"
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                           PRAGMA SETTINGS                               ║
    // ║                  (Applied on every database connection)                 ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    /// WAL mode: Allows concurrent reads while writing
    static let enableWAL = "PRAGMA journal_mode=WAL;"

    /// NORMAL sync: Faster than FULL, still crash-safe with WAL (was FULL in Rewind)
    static let setSynchronousNormal = "PRAGMA synchronous=NORMAL;"

    /// Enable foreign key constraint enforcement (was OFF in Rewind)
    static let enableForeignKeys = "PRAGMA foreign_keys=ON;"

    /// Use memory for temp tables (faster)
    static let setTempStoreMemory = "PRAGMA temp_store=MEMORY;"

    /// 64MB cache (was 2MB in Rewind)
    static let setCacheSize = "PRAGMA cache_size=-64000;"

    /// Auto vacuum to prevent fragmentation (was OFF in Rewind)
    static let setAutoVacuum = "PRAGMA auto_vacuum=INCREMENTAL;"

    /// Checkpoint WAL every ~4MB (1000 pages × 4KB)
    static let setWALAutocheckpoint = "PRAGMA wal_autocheckpoint=1000;"

    /// All pragmas to run on database initialization
    static var initializationPragmas: [String] {
        [
            enableWAL,
            setSynchronousNormal,
            enableForeignKeys,
            setTempStoreMemory,
            setCacheSize,
            setWALAutocheckpoint
        ]
    }

    // Note: auto_vacuum must be set BEFORE creating tables, so it's handled in migration

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │                         SCHEMA MIGRATIONS                               │
    // │  Tracks which migrations have been applied to this database             │
    // └─────────────────────────────────────────────────────────────────────────┘

    static let createSchemaMigrationsTable = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     INTEGER PRIMARY KEY,
            applied_at  INTEGER DEFAULT (strftime('%s', 'now') * 1000)
        );
        """
}

// ╔═════════════════════════════════════════════════════════════════════════════╗
// ║                          DATE CONVERSION UTILITIES                          ║
// ╚═════════════════════════════════════════════════════════════════════════════╝

extension Schema {

    /// Convert Swift Date → SQLite timestamp (milliseconds since Unix epoch)
    static func dateToTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Convert SQLite timestamp (milliseconds) → Swift Date
    static func timestampToDate(_ timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000)
    }

    /// Get current timestamp in milliseconds
    static func currentTimestamp() -> Int64 {
        dateToTimestamp(Date())
    }
}

// ╔═════════════════════════════════════════════════════════════════════════════╗
// ║                     COORDINATE NORMALIZATION UTILITIES                      ║
// ╚═════════════════════════════════════════════════════════════════════════════╝

extension Schema {

    /// Normalize pixel coordinate to 0.0-1.0 range
    static func normalizeCoordinate(_ pixels: Int, frameSize: Int) -> Double {
        guard frameSize > 0 else { return 0.0 }
        return Double(pixels) / Double(frameSize)
    }

    /// Denormalize 0.0-1.0 coordinate to pixels
    static func denormalizeCoordinate(_ normalized: Double, frameSize: Int) -> Int {
        Int(normalized * Double(frameSize))
    }

    /// Normalize CGRect to normalized coordinates
    static func normalizeRect(_ rect: CGRect, frameWidth: Int, frameHeight: Int) -> (leftX: Double, topY: Double, width: Double, height: Double) {
        let leftX = normalizeCoordinate(Int(rect.origin.x), frameSize: frameWidth)
        let topY = normalizeCoordinate(Int(rect.origin.y), frameSize: frameHeight)
        let width = normalizeCoordinate(Int(rect.size.width), frameSize: frameWidth)
        let height = normalizeCoordinate(Int(rect.size.height), frameSize: frameHeight)
        return (leftX, topY, width, height)
    }

    /// Denormalize coordinates to CGRect
    static func denormalizeRect(leftX: Double, topY: Double, width: Double, height: Double, frameWidth: Int, frameHeight: Int) -> CGRect {
        let x = denormalizeCoordinate(leftX, frameSize: frameWidth)
        let y = denormalizeCoordinate(topY, frameSize: frameHeight)
        let w = denormalizeCoordinate(width, frameSize: frameWidth)
        let h = denormalizeCoordinate(height, frameSize: frameHeight)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// ╔═════════════════════════════════════════════════════════════════════════════╗
// ║                           REWIND SCHEMA REFERENCE                           ║
// ║              (For compatibility - actual schema is in V3 migration)         ║
// ╚═════════════════════════════════════════════════════════════════════════════╝

extension Schema {

    /// Rewind-compatible table structures (reference only - created by V3 migration)
    ///
    /// segment: Application/window sessions
    ///   - INTEGER id (PK, auto-increment)
    ///   - TEXT bundleID NOT NULL
    ///   - INTEGER startDate NOT NULL (ms)
    ///   - INTEGER endDate NOT NULL (ms)
    ///   - TEXT windowName
    ///   - TEXT browserUrl
    ///   - INTEGER type NOT NULL
    ///
    /// frame: Screen captures
    ///   - INTEGER id (PK, auto-increment)
    ///   - INTEGER createdAt NOT NULL (ms)
    ///   - TEXT imageFileName NOT NULL
    ///   - INTEGER segmentId (FK segment.id ON DELETE CASCADE)
    ///   - INTEGER videoId (FK video.id ON DELETE SET NULL)
    ///   - INTEGER videoFrameIndex
    ///   - INTEGER isStarred NOT NULL DEFAULT 0
    ///   - TEXT encodingStatus
    ///
    /// node: OCR text bounding boxes
    ///   - INTEGER id (PK, auto-increment)
    ///   - INTEGER frameId NOT NULL (FK frame.id ON DELETE CASCADE)
    ///   - INTEGER nodeOrder NOT NULL (reading order)
    ///   - INTEGER textOffset NOT NULL (char offset in searchRanking_content)
    ///   - INTEGER textLength NOT NULL (char length)
    ///   - REAL leftX NOT NULL (normalized 0.0-1.0)
    ///   - REAL topY NOT NULL (normalized 0.0-1.0)
    ///   - REAL width NOT NULL (normalized 0.0-1.0)
    ///   - REAL height NOT NULL (normalized 0.0-1.0)
    ///   - INTEGER windowIndex
    ///
    /// video: Video metadata
    ///   - INTEGER id (PK, auto-increment)
    ///   - INTEGER height NOT NULL
    ///   - INTEGER width NOT NULL
    ///   - TEXT path NOT NULL
    ///   - INTEGER fileSize
    ///   - REAL frameRate NOT NULL
    ///   - INTEGER uploadedAt (ms)
    ///   - TEXT xid
    ///   - INTEGER processingState NOT NULL
    ///
    /// audio: Audio recordings
    ///   - INTEGER id (PK, auto-increment)
    ///   - INTEGER segmentId NOT NULL (FK segment.id ON DELETE CASCADE)
    ///   - TEXT path NOT NULL
    ///   - INTEGER startTime NOT NULL (ms)
    ///   - INTEGER duration NOT NULL (ms)
    ///
    /// transcript_word: Word-level transcriptions
    ///   - INTEGER id (PK, auto-increment)
    ///   - INTEGER segmentId NOT NULL (FK segment.id ON DELETE CASCADE)
    ///   - TEXT speechSource NOT NULL ('me' | 'others')
    ///   - TEXT word NOT NULL
    ///   - INTEGER timeOffset NOT NULL (ms within audio)
    ///   - INTEGER fullTextOffset
    ///   - INTEGER duration NOT NULL (ms)
    ///
    /// searchRanking_content: FTS external content table
    ///   - INTEGER id (PK, auto-increment)
    ///   - TEXT c0 (main OCR text, 100-1000+ chars per frame)
    ///   - TEXT c1 (dual purpose: UI chrome text ~40-50 chars OR overflow OCR 500+ chars)
    ///   - TEXT c2 (window/app title, can be NULL)
    ///
    /// searchRanking: FTS5 virtual table (external content)
    ///   - text (maps to searchRanking_content.c0)
    ///   - otherText (maps to searchRanking_content.c1)
    ///   - title (maps to searchRanking_content.c2)
    ///   - content='searchRanking_content'
    ///   - content_rowid='id'
    ///
    /// IMPORTANT: No triggers! Insert into both tables manually:
    ///   1. INSERT INTO searchRanking_content (c0, c1, c2) VALUES (?, ?, ?)
    ///   2. INSERT INTO searchRanking (rowid, text, otherText, title)
    ///      VALUES (last_insert_rowid(), ?, ?, ?)
    ///
    /// event: Calendar events and meetings
    ///   - INTEGER id (PK, auto-increment)
    ///   - TEXT type NOT NULL
    ///   - TEXT status NOT NULL
    ///   - TEXT title
    ///   - TEXT participants
    ///   - TEXT detailsJSON
    ///   - TEXT calendarID
    ///   - TEXT calendarEventID
    ///   - TEXT calendarSeriesID
    ///   - INTEGER segmentID NOT NULL (FK segment.id ON DELETE CASCADE)
    ///
    /// summary: AI-generated summaries
    ///   - INTEGER id (PK, auto-increment)
    ///   - TEXT status NOT NULL
    ///   - TEXT text
    ///   - INTEGER eventId NOT NULL (FK event.id ON DELETE CASCADE)
    ///
    /// doc_segment: Document-to-segment links
    ///   - INTEGER docid NOT NULL
    ///   - INTEGER segmentId NOT NULL
    ///   - INTEGER frameId
    ///
    /// videoFileState: Video download tracking
    ///   - TEXT id (PK)
    ///   - INTEGER downloadedAt (ms)
    ///
    /// frame_processing: Frame processing status
    ///   - INTEGER id NOT NULL
    ///   - TEXT processingType NOT NULL
    ///   - INTEGER createdAt NOT NULL (ms)
    ///
    /// purge: Files marked for deletion
    ///   - TEXT path NOT NULL
    ///   - TEXT fileType NOT NULL
    ///
    /// INDEXES (21 total, Rewind-compatible naming):
    /// - segment: index_segment_on_appid, index_segment_on_endtime, index_segment_on_starttime,
    ///            index_segment_on_windowname (partial), index_segment_on_browserurl (partial)
    /// - frame: index_frame_on_createdat, index_frame_on_encodingstatus_createdat,
    ///          index_frame_on_isstarred_createdat, index_frame_on_segmentid_createdat, index_frame_on_videoid
    /// - node: index_node_on_frameid, index_node_on_windowindex (partial)
    /// - transcript_word: index_transcript_word_on_segmentid_fulltextoffset
    /// - event: index_event_on_calendarseriesid, index_event_on_status
    /// - summary: index_summary_on_eventid, index_summary_on_status
    /// - doc_segment: index_doc_segment_on_frameid_docid, index_doc_segment_on_segmentid_docid
    /// - video: index_video_on_resolution
    /// - audio: index_audio_on_starttime
}
