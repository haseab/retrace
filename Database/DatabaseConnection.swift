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

public enum DatabaseConnectionError: Error, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
    case statementPreparationFailed(sql: String, error: String)
    case executionFailed(sql: String, error: String)
    case transactionFailed(error: String)
    case notConnected

    public var description: String {
        switch self {
        case .statementPreparationFailed(let sql, let error):
            let diagnostic = Self.safeSQLDiagnostic(sql: sql, error: error)
            return "Failed to prepare statement '\(diagnostic.sql)': \(diagnostic.error)"
        case .executionFailed(let sql, let error):
            let diagnostic = Self.safeSQLDiagnostic(sql: sql, error: error)
            return "Failed to execute '\(diagnostic.sql)': \(diagnostic.error)"
        case .transactionFailed(let error):
            return "Transaction failed: \(error)"
        case .notConnected:
            return "Database not connected"
        }
    }

    public var debugDescription: String { description }
    public var errorDescription: String? { description }

    /// Key setup SQL contains secrets. SQLite parser errors can echo them too.
    /// Match conservatively, including schema-qualified and commented pragmas;
    /// retaining SQL diagnostics for ordinary statements is still useful.
    static func safeSQLDiagnostic(sql: String, error: String) -> (sql: String, error: String) {
        let hasPragma = sql.range(of: #"\bpragma\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let hasKey = sql.range(of: #"\b(?:key|rekey)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard hasPragma && hasKey else { return (sql, error) }
        return ("PRAGMA key = <redacted>;", "SQLCipher key operation failed (details redacted)")
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
            let diagnostic = DatabaseConnectionError.safeSQLDiagnostic(sql: sql, error: error)
            throw DatabaseConnectionError.statementPreparationFailed(sql: diagnostic.sql, error: diagnostic.error)
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
            let diagnostic = DatabaseConnectionError.safeSQLDiagnostic(sql: sql, error: error)
            throw DatabaseConnectionError.executionFailed(sql: diagnostic.sql, error: diagnostic.error)
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
            let diagnostic = DatabaseConnectionError.safeSQLDiagnostic(sql: sql, error: error)
            throw DatabaseConnectionError.statementPreparationFailed(sql: diagnostic.sql, error: diagnostic.error)
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
            let diagnostic = DatabaseConnectionError.safeSQLDiagnostic(sql: sql, error: error)
            throw DatabaseConnectionError.executionFailed(sql: diagnostic.sql, error: diagnostic.error)
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
