import Foundation
import SQLCipher
import Shared

// MARK: - Migration Protocol

/// Protocol for database migrations
protocol Migration {
    /// Version number for this migration
    var version: Int { get }

    /// Apply this migration to the database
    func migrate(db: OpaquePointer) async throws
}

// MARK: - Migration Runner

/// Handles execution of database migrations in order
actor MigrationRunner {

    private let db: OpaquePointer

    init(db: OpaquePointer) {
        self.db = db
    }

    // MARK: - Public Methods

    /// Run all pending migrations
    func runMigrations() async throws {
        // Ensure schema_migrations table exists
        try createMigrationsTableIfNeeded()

        // Get current schema version
        let currentVersion = try getCurrentVersion()

        // Get all available migrations
        let migrations = getAllMigrations()

        // Run migrations that haven't been applied yet
        for migration in migrations where migration.version > currentVersion {
            try await runMigration(migration)
        }
    }

    /// Get the current schema version
    func getCurrentVersion() throws -> Int {
        let sql = "SELECT MAX(version) FROM schema_migrations;"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            // No migrations have been run yet
            return 0
        }

        let version = Int(sqlite3_column_int(statement, 0))
        return version
    }

    // MARK: - Private Methods

    private func createMigrationsTableIfNeeded() throws {
        let sql = Schema.createSchemaMigrationsTable

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private func getAllMigrations() -> [Migration] {
        // Return all migration instances in order
        // New migrations should be added to this array
        [
            V1_InitialSchema(),
            V2_UnfinalisedVideoTracking(),
            V3_TagSystem(),
            V4_DailyMetrics(),
            V5_FTSUnicode61()
        ]
    }

    private func runMigration(_ migration: Migration) async throws {
        let version = migration.version

        // Begin transaction
        try executeSQL("BEGIN TRANSACTION;")

        do {
            // Run the migration
            try await migration.migrate(db: db)

            // Record that this migration was applied
            try recordMigration(version: version)

            // Commit transaction
            try executeSQL("COMMIT;")
        } catch {
            // Rollback on error
            try? executeSQL("ROLLBACK;")
            throw DatabaseError.migrationFailed(version: version, underlying: error.localizedDescription)
        }
    }

    private func recordMigration(version: Int) throws {
        let timestamp = Schema.currentTimestamp()
        let sql = "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int(statement, 1, Int32(version))
        sqlite3_bind_int64(statement, 2, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    private func executeSQL(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }
}

// MARK: - Migration Utilities

extension MigrationRunner {

    /// Helper to execute multiple SQL statements
    static func executeStatements(db: OpaquePointer, statements: [String]) throws {
        for sql in statements {
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                sqlite3_free(errorMessage)
            }

            guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
                throw DatabaseError.queryFailed(query: sql, underlying: message)
            }
        }
    }
}
