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
