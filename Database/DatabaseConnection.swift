import Foundation
import SQLCipher

/// Protocol abstracting SQLite/SQLCipher database operations
/// Allows UnifiedDatabaseAdapter to work with both encrypted and unencrypted databases
public protocol DatabaseConnection: Sendable {
    /// Get the underlying database pointer
    func getConnection() -> OpaquePointer?

    /// Prepare a SQL statement
    func prepare(sql: String) throws -> OpaquePointer?

    /// Execute a SQL statement without results (returns number of changes)
    @discardableResult
    func execute(sql: String) throws -> Int

    /// Begin a transaction
    func beginTransaction() throws

    /// Commit the current transaction
    func commit() throws

    /// Rollback the current transaction
    func rollback() throws

    /// Finalize a statement
    func finalize(_ statement: OpaquePointer?)
}

// MARK: - Database Errors

public enum DatabaseConnectionError: Error, CustomStringConvertible {
    case statementPreparationFailed(sql: String, error: String)
    case executionFailed(sql: String, error: String)
    case transactionFailed(error: String)
    case notConnected
    case connectionOpenFailed(path: String, error: String)
    case connectionConfigurationFailed(error: String)
    case readPoolClosed

    public var description: String {
        switch self {
        case .statementPreparationFailed(let sql, let error):
            return "Failed to prepare statement '\(sql)': \(error)"
        case .executionFailed(let sql, let error):
            return "Failed to execute '\(sql)': \(error)"
        case .transactionFailed(let error):
            return "Transaction failed: \(error)"
        case .notConnected:
            return "Database not connected"
        case .connectionOpenFailed(let path, let error):
            return "Failed to open database at '\(path)': \(error)"
        case .connectionConfigurationFailed(let error):
            return "Failed to configure database connection: \(error)"
        case .readPoolClosed:
            return "Read connection pool is closed"
        }
    }
}

// MARK: - SQLite Connection (Unencrypted)

/// Wrapper for standard SQLite connection (used by RetraceDataSource)
public final class SQLiteConnection: DatabaseConnection, @unchecked Sendable {
    private let db: OpaquePointer?

    public init(db: OpaquePointer?) {
        self.db = db
    }

    public func getConnection() -> OpaquePointer? {
        return db
    }

    public func prepare(sql: String) throws -> OpaquePointer? {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.statementPreparationFailed(sql: sql, error: error)
        }

        return statement
    }

    @discardableResult
    public func execute(sql: String) throws -> Int {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: error)
        }

        return Int(sqlite3_changes(db))
    }

    public func beginTransaction() throws {
        try execute(sql: "BEGIN TRANSACTION")
    }

    public func commit() throws {
        try execute(sql: "COMMIT")
    }

    public func rollback() throws {
        try execute(sql: "ROLLBACK")
    }

    public func finalize(_ statement: OpaquePointer?) {
        if let statement = statement {
            sqlite3_finalize(statement)
        }
    }
}

// MARK: - SQLCipher Connection (Encrypted)

/// Wrapper for SQLCipher connection (used by RewindDataSource)
public final class SQLCipherConnection: DatabaseConnection, @unchecked Sendable {
    private let db: OpaquePointer?

    public init(db: OpaquePointer?) {
        self.db = db
    }

    public func getConnection() -> OpaquePointer? {
        return db
    }

    public func prepare(sql: String) throws -> OpaquePointer? {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.statementPreparationFailed(sql: sql, error: error)
        }

        return statement
    }

    @discardableResult
    public func execute(sql: String) throws -> Int {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: error)
        }

        return Int(sqlite3_changes(db))
    }

    public func beginTransaction() throws {
        try execute(sql: "BEGIN TRANSACTION")
    }

    public func commit() throws {
        try execute(sql: "COMMIT")
    }

    public func rollback() throws {
        try execute(sql: "ROLLBACK")
    }

    public func finalize(_ statement: OpaquePointer?) {
        if let statement = statement {
            sqlite3_finalize(statement)
        }
    }
}

/// Checked SELECT iteration. Keep lock retries bounded and never restart a read
/// after returning rows, which could duplicate results or mix snapshots.
public enum SQLiteReadStep: Sendable {
    public static func next(_ statement: OpaquePointer?) throws -> Int32 {
        guard let statement, let db = sqlite3_db_handle(statement) else {
            throw DatabaseConnectionError.notConnected
        }
        let canRetry = sqlite3_stmt_readonly(statement) != 0 && sqlite3_stmt_busy(statement) == 0
        var result = sqlite3_step(statement)
        let primaryCode = result & 0xff
        if canRetry && (primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED) {
            // Existing connection busy_timeout handles waiting. One fresh attempt only;
            // reset preserves bound parameters and discards the failed execution.
            sqlite3_reset(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            let sql = sqlite3_sql(statement).map(String.init(cString:)) ?? "SELECT"
            throw DatabaseConnectionError.executionFailed(sql: sql, error: String(cString: sqlite3_errmsg(db)))
        }
        return result
    }
}
