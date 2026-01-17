import Foundation
import SQLCipher
import Shared

/// Initial database schema - Rewind-compatible structure
/// Creates all tables from scratch for a fresh Retrace installation
struct V1_InitialSchema: Migration {
    let version = 1

    func migrate(db: OpaquePointer) async throws {
        Log.info("📦 Creating initial Rewind-compatible schema...", category: .database)

        // Configure database before creating tables
        try configurePragmas(db: db)

        // Create all tables
        try createSegmentTable(db: db)
        try createFrameTable(db: db)
        try createNodeTable(db: db)
        try createVideoTable(db: db)
        try createAudioTable(db: db)
        try createTranscriptWordTable(db: db)
        try createSearchRankingTables(db: db)
        try createEventTable(db: db)
        try createSummaryTable(db: db)
        try createUtilityTables(db: db)

        // Create all indexes
        try createIndexes(db: db)

        Log.info("✅ Initial schema created successfully", category: .database)
    }

    // MARK: - PRAGMA Configuration

    private func configurePragmas(db: OpaquePointer) throws {
        // NOTE: All PRAGMAs are set by DatabaseManager.initialize() BEFORE migrations run.
        // We cannot set PRAGMAs here because:
        // 1. MigrationRunner wraps migrations in a transaction
        // 2. PRAGMA auto_vacuum, journal_mode, and synchronous cannot be changed inside transactions
        // 3. DatabaseManager already configures these before calling runMigrations()

        Log.debug("✓ PRAGMAs already configured by DatabaseManager")
    }

    // MARK: - Core Tables

    private func createSegmentTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS segment (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                bundleID    TEXT NOT NULL,
                startDate   INTEGER NOT NULL,
                endDate     INTEGER NOT NULL,
                windowName  TEXT,
                browserUrl  TEXT,
                type        INTEGER NOT NULL
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created segment table")
    }

    private func createFrameTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS frame (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                createdAt       INTEGER NOT NULL,
                imageFileName   TEXT NOT NULL,
                segmentId       INTEGER,
                videoId         INTEGER,
                videoFrameIndex INTEGER,
                isStarred       INTEGER NOT NULL DEFAULT 0,
                encodingStatus  TEXT,
                FOREIGN KEY (segmentId) REFERENCES segment(id) ON DELETE CASCADE,
                FOREIGN KEY (videoId) REFERENCES video(id) ON DELETE SET NULL
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created frame table")
    }

    private func createNodeTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS node (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                frameId     INTEGER NOT NULL,
                nodeOrder   INTEGER NOT NULL,
                textOffset  INTEGER NOT NULL,
                textLength  INTEGER NOT NULL,
                leftX       REAL NOT NULL,
                topY        REAL NOT NULL,
                width       REAL NOT NULL,
                height      REAL NOT NULL,
                windowIndex INTEGER,
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created node table")
    }

    private func createVideoTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS video (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                height          INTEGER NOT NULL,
                width           INTEGER NOT NULL,
                path            TEXT NOT NULL,
                fileSize        INTEGER,
                frameRate       REAL NOT NULL,
                uploadedAt      INTEGER,
                xid             TEXT,
                processingState INTEGER NOT NULL
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created video table")
    }

    // MARK: - Audio Tables

    private func createAudioTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS audio (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                segmentId   INTEGER NOT NULL,
                path        TEXT NOT NULL,
                startTime   INTEGER NOT NULL,
                duration    INTEGER NOT NULL,
                FOREIGN KEY (segmentId) REFERENCES segment(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created audio table")
    }

    private func createTranscriptWordTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS transcript_word (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                segmentId       INTEGER NOT NULL,
                speechSource    TEXT NOT NULL,
                word            TEXT NOT NULL,
                timeOffset      INTEGER NOT NULL,
                fullTextOffset  INTEGER,
                duration        INTEGER NOT NULL,
                FOREIGN KEY (segmentId) REFERENCES segment(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created transcript_word table")
    }

    // MARK: - Full-Text Search Tables

    private func createSearchRankingTables(db: OpaquePointer) throws {
        // Create external content table (Rewind's structure)
        // This stores the actual text data that FTS5 indexes
        let contentTableSQL = """
            CREATE TABLE IF NOT EXISTS searchRanking_content (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                c0 TEXT,
                c1 TEXT,
                c2 TEXT
            );
            """
        try execute(db: db, sql: contentTableSQL)
        Log.debug("✓ Created searchRanking_content table")

        // Create FTS5 virtual table with external content
        // Matches Rewind's exact structure with c0, c1, c2 column names
        let ftsSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS searchRanking USING fts5(
                c0,
                c1,
                c2,
                content='searchRanking_content',
                content_rowid='id'
            );
            """
        try execute(db: db, sql: ftsSQL)
        Log.debug("✓ Created searchRanking FTS5 table with external content (c0=text, c1=otherText, c2=title)")
    }

    // MARK: - Event/Meeting Tables

    private func createEventTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS event (
                id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                type                TEXT NOT NULL,
                status              TEXT NOT NULL,
                title               TEXT,
                participants        TEXT,
                detailsJSON         TEXT,
                calendarID          TEXT,
                calendarEventID     TEXT,
                calendarSeriesID    TEXT,
                segmentID           INTEGER NOT NULL,
                FOREIGN KEY (segmentID) REFERENCES segment(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created event table")
    }

    private func createSummaryTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS summary (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                status  TEXT NOT NULL,
                text    TEXT,
                eventId INTEGER NOT NULL,
                FOREIGN KEY (eventId) REFERENCES event(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created summary table")
    }

    // MARK: - Utility Tables

    private func createUtilityTables(db: OpaquePointer) throws {
        // doc_segment: Links documents to segments
        let docSegmentSQL = """
            CREATE TABLE IF NOT EXISTS doc_segment (
                docid       INTEGER NOT NULL,
                segmentId   INTEGER NOT NULL,
                frameId     INTEGER
            );
            """
        try execute(db: db, sql: docSegmentSQL)
        Log.debug("✓ Created doc_segment table")

        // videoFileState: Tracks video download status
        let videoFileStateSQL = """
            CREATE TABLE IF NOT EXISTS videoFileState (
                id              TEXT PRIMARY KEY,
                downloadedAt    INTEGER
            );
            """
        try execute(db: db, sql: videoFileStateSQL)
        Log.debug("✓ Created videoFileState table")

        // frame_processing: Tracks frame processing status
        let frameProcessingSQL = """
            CREATE TABLE IF NOT EXISTS frame_processing (
                id              INTEGER NOT NULL,
                processingType  TEXT NOT NULL,
                createdAt       INTEGER NOT NULL
            );
            """
        try execute(db: db, sql: frameProcessingSQL)
        Log.debug("✓ Created frame_processing table")

        // purge: Tracks files to be deleted
        let purgeSQL = """
            CREATE TABLE IF NOT EXISTS purge (
                path        TEXT NOT NULL,
                fileType    TEXT NOT NULL
            );
            """
        try execute(db: db, sql: purgeSQL)
        Log.debug("✓ Created purge table")
    }

    // MARK: - Indexes

    private func createIndexes(db: OpaquePointer) throws {
        Log.debug("Creating indexes with Rewind naming convention...")

        // segment indexes (5) - Note: Rewind uses "appid" not "bundleID" in index name
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_appid ON segment(bundleID);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_endtime ON segment(endDate);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_starttime ON segment(startDate);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_windowname ON segment(windowName) WHERE windowName IS NOT NULL;")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_browserurl ON segment(browserUrl) WHERE browserUrl IS NOT NULL;")

        // frame indexes (5)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_frame_on_createdat ON frame(createdAt);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_frame_on_encodingstatus_createdat ON frame(encodingStatus, createdAt);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_frame_on_isstarred_createdat ON frame(isStarred, createdAt);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_frame_on_segmentid_createdat ON frame(segmentId, createdAt);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_frame_on_videoid ON frame(videoId);")

        // node indexes (2)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_node_on_frameid ON node(frameId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_node_on_windowindex ON node(windowIndex) WHERE windowIndex IS NOT NULL;")

        // transcript_word indexes (1)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_transcript_word_on_segmentid_fulltextoffset ON transcript_word(segmentId, fullTextOffset);")

        // event indexes (2)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_event_on_calendarseriesid ON event(calendarSeriesID);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_event_on_status ON event(status);")

        // summary indexes (2)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_summary_on_eventid ON summary(eventId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_summary_on_status ON summary(status);")

        // doc_segment indexes (2)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_doc_segment_on_frameid_docid ON doc_segment(frameId, docid);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_doc_segment_on_segmentid_docid ON doc_segment(segmentId, docid);")

        // video indexes (1)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_video_on_resolution ON video(width, height);")

        // audio indexes (1)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_audio_on_starttime ON audio(startTime);")

        Log.debug("✓ Created all 21 indexes (Rewind-compatible naming)")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 1, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
