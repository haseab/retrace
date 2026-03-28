import Foundation
import Security
import SQLCipher
import Shared

final class SharedSQLiteConnection: DatabaseConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    init(db: OpaquePointer? = nil) {
        self.db = db
    }

    func setConnection(_ db: OpaquePointer?) {
        lock.lock()
        self.db = db
        lock.unlock()
    }

    func getConnection() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return db
    }

    func prepare(sql: String) throws -> OpaquePointer? {
        guard let db = getConnection() else {
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
    func execute(sql: String) throws -> Int {
        guard let db = getConnection() else {
            throw DatabaseConnectionError.notConnected
        }

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: error)
        }

        return Int(sqlite3_changes(db))
    }

    func beginTransaction() throws {
        try execute(sql: "BEGIN TRANSACTION")
    }

    func commit() throws {
        try execute(sql: "COMMIT")
    }

    func rollback() throws {
        try execute(sql: "ROLLBACK")
    }

    func finalize(_ statement: OpaquePointer?) {
        if let statement = statement {
            sqlite3_finalize(statement)
        }
    }
}

public enum SQLiteReadOnlyConnectionFactory {
    public enum ConnectionKind {
        case sqlite
        case sqlcipher
    }

    public static func makeConnection(
        databasePath: String,
        connectionKind: ConnectionKind = .sqlite,
        configure: (_ db: OpaquePointer, _ isInMemory: Bool) throws -> Void
    ) throws -> DatabaseConnection {
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        let path = databasePath.hasPrefix("file:")
            ? databasePath
            : NSString(string: databasePath).expandingTildeInPath

        var db: OpaquePointer?
        var flags = SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        flags |= isInMemory ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY

        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close_v2(db)
            throw DatabaseConnectionError.connectionOpenFailed(path: path, error: error)
        }

        guard let db else {
            throw DatabaseConnectionError.connectionOpenFailed(path: path, error: "Connection pointer was nil")
        }

        do {
            try configure(db, isInMemory)
            return wrapConnection(db, kind: connectionKind)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    public static func makeRetraceConnection(databasePath: String) throws -> DatabaseConnection {
        try makeConnection(databasePath: databasePath) { db, isInMemory in
            if !isInMemory, let keyData = try loadRetraceDatabaseKeyIfEnabled() {
                let keyHex = keyData.map { String(format: "%02hhx", $0) }.joined()
                try execSQL("PRAGMA key = \"x'\(keyHex)'\";", db: db)
            }
            try configureReadOnlyConnection(db)
        }
    }

    public static func makeRewindConnection(
        databasePath: String,
        password: String,
        cipherCompatibility: Int
    ) throws -> DatabaseConnection {
        try makeConnection(databasePath: databasePath, connectionKind: .sqlcipher) { db, _ in
            try execSQL("PRAGMA key = '\(password)'", db: db)
            try execSQL("PRAGMA cipher_compatibility = \(cipherCompatibility)", db: db)
            try configureReadOnlyConnection(db)
        }
    }

    private static func wrapConnection(
        _ db: OpaquePointer,
        kind: ConnectionKind
    ) -> DatabaseConnection {
        switch kind {
        case .sqlite:
            return SQLiteConnection(db: db)
        case .sqlcipher:
            return SQLCipherConnection(db: db)
        }
    }

    private static func configureReadOnlyConnection(_ db: OpaquePointer) throws {
        sqlite3_busy_timeout(db, 5_000)
        try execSQL("PRAGMA query_only = ON;", db: db)
        try verifyReadableConnection(db)
    }

    private static func loadRetraceDatabaseKeyIfEnabled() throws -> Data? {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let encryptionEnabled = defaults.object(forKey: "encryptionEnabled") as? Bool ?? false
        guard encryptionEnabled else {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppPaths.keychainService,
            kSecAttrAccount as String: AppPaths.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw DatabaseConnectionError.connectionConfigurationFailed(
                error: "Failed to load Retrace database encryption key from Keychain (status: \(status))"
            )
        }
        return data
    }

    private static func verifyReadableConnection(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            throw DatabaseConnectionError.connectionConfigurationFailed(error: message)
        }
        sqlite3_finalize(statement)
    }

    private static func execSQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: message)
        }
    }
}

public actor SQLiteReadConnectionPool {
    private struct Lease: Sendable {
        let id: Int
        let connection: DatabaseConnection
        let ownsConnection: Bool
    }

    private enum CheckoutResult: Sendable {
        case lease(Lease)
        case closed
    }

    public static let defaultMaxConnections = min(
        4,
        max(2, ProcessInfo.processInfo.activeProcessorCount)
    )

    private let label: String
    private let maxConnections: Int
    private let connectionFactory: (@Sendable () throws -> DatabaseConnection)?
    private var idleConnections: [Lease]
    private var checkoutWaiters: [CheckedContinuation<CheckoutResult, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeLeaseCount = 0
    private var totalConnections = 0
    private var nextLeaseID = 0
    private var isClosed = false

    public init(
        label: String,
        maxConnections: Int = SQLiteReadConnectionPool.defaultMaxConnections,
        connectionFactory: @escaping @Sendable () throws -> DatabaseConnection
    ) {
        self.label = label
        self.maxConnections = max(1, maxConnections)
        self.connectionFactory = connectionFactory
        self.idleConnections = []
    }

    public init(label: String, sharedConnection: DatabaseConnection) {
        self.label = label
        self.maxConnections = 1
        self.connectionFactory = nil
        self.idleConnections = [
            Lease(id: 0, connection: sharedConnection, ownsConnection: false)
        ]
        self.totalConnections = 1
        self.nextLeaseID = 1
    }

    public func withConnection<T>(
        operation: String,
        traceID: String? = nil,
        _ body: @escaping @Sendable (DatabaseConnection) throws -> T
    ) async throws -> T {
        let lease = try await checkout(operation: operation, traceID: traceID)
        defer {
            checkin(lease)
        }

        try Task.checkCancellation()
        return try await Self.runInterruptibleBody(
            connection: lease.connection,
            body
        )
    }

    public func close() async {
        isClosed = true
        failQueuedCheckouts()
        closeIdleConnections()

        guard activeLeaseCount > 0 else {
            return
        }

        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    private func checkout(operation: String, traceID: String?) async throws -> Lease {
        guard !isClosed else {
            throw DatabaseConnectionError.readPoolClosed
        }

        let waitStartedAt = CFAbsoluteTimeGetCurrent()

        if let lease = idleConnections.popLast() {
            activeLeaseCount += 1
            logCheckoutWaitIfNeeded(
                operation: operation,
                traceID: traceID,
                waitStartedAt: waitStartedAt
            )
            return lease
        }

        if totalConnections < maxConnections {
            let lease = try makeConnection()
            activeLeaseCount += 1
            logCheckoutWaitIfNeeded(
                operation: operation,
                traceID: traceID,
                waitStartedAt: waitStartedAt
            )
            return lease
        }

        let result = await withCheckedContinuation { continuation in
            checkoutWaiters.append(continuation)
        }
        guard case .lease(let lease) = result else {
            throw DatabaseConnectionError.readPoolClosed
        }
        logCheckoutWaitIfNeeded(
            operation: operation,
            traceID: traceID,
            waitStartedAt: waitStartedAt
        )
        return lease
    }

    private func makeConnection() throws -> Lease {
        guard let connectionFactory else {
            throw DatabaseConnectionError.readPoolClosed
        }

        let connection = try connectionFactory()
        let lease = Lease(
            id: nextLeaseID,
            connection: connection,
            ownsConnection: true
        )
        nextLeaseID += 1
        totalConnections += 1

        Log.info(
            "[DB-READ-POOL][\(label)] opened connection \(lease.id) total=\(totalConnections)/\(maxConnections)",
            category: .database
        )
        return lease
    }

    private func checkin(_ lease: Lease) {
        if isClosed {
            activeLeaseCount -= 1
            closeConnectionIfOwned(lease)
            finishClosingIfNeeded()
            return
        }

        if let waiter = checkoutWaiters.first {
            checkoutWaiters.removeFirst()
            waiter.resume(returning: .lease(lease))
            return
        }

        activeLeaseCount -= 1
        idleConnections.append(lease)
    }

    private func failQueuedCheckouts() {
        let waiters = checkoutWaiters
        checkoutWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: .closed)
        }
    }

    private func closeIdleConnections() {
        let idle = idleConnections
        idleConnections.removeAll(keepingCapacity: false)
        for lease in idle {
            closeConnectionIfOwned(lease)
        }
        finishClosingIfNeeded()
    }

    private func finishClosingIfNeeded() {
        guard isClosed, activeLeaseCount == 0 else {
            return
        }

        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func closeConnectionIfOwned(_ lease: Lease) {
        guard lease.ownsConnection, let db = lease.connection.getConnection() else {
            return
        }

        let rc = sqlite3_close_v2(db)
        if rc != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            Log.warning(
                "[DB-READ-POOL][\(label)] failed to close connection \(lease.id) (\(rc)): \(message)",
                category: .database
            )
        }
    }

    private func logCheckoutWaitIfNeeded(
        operation: String,
        traceID: String?,
        waitStartedAt: CFAbsoluteTime
    ) {
        let waitMs = max(0, (CFAbsoluteTimeGetCurrent() - waitStartedAt) * 1000)
        Log.recordLatency(
            "database.read_pool.checkout_wait_ms",
            valueMs: waitMs,
            category: .database,
            summaryEvery: 10,
            warningThresholdMs: 100,
            criticalThresholdMs: 500
        )

        guard waitMs >= 100 else {
            return
        }

        Log.warning(
            "[DB-READ-POOL][\(label)] WAIT op='\(operation)' trace=\(traceID ?? "none") waited=\(String(format: "%.1f", waitMs))ms",
            category: .database
        )
    }

    private nonisolated static func runInterruptibleBody<T>(
        connection: DatabaseConnection,
        _ body: @escaping @Sendable (DatabaseConnection) throws -> T
    ) async throws -> T {
        let bodyTask = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try body(connection)
        }

        do {
            let value = try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: {
                bodyTask.cancel()
                if let db = connection.getConnection() {
                    sqlite3_interrupt(db)
                }
            }
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
