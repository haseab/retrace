import Foundation
import SQLCipher
import Shared

public actor DatabaseMigrationEngine {
    private static let migrationDirectoryName = "Migration"
    private static let jobFileName = "database_migration_job.json"
    private static let sourceThroughputBytesPerSecond: Double = 80 * 1024 * 1024

    private let fileManager = FileManager.default
    private let defaultDatabasePath: String
    private let defaultStorageRootPath: String

    public init(
        databasePath: String = AppPaths.databasePath,
        storageRootPath: String = AppPaths.expandedStorageRoot
    ) {
        self.defaultDatabasePath = NSString(string: databasePath).expandingTildeInPath
        self.defaultStorageRootPath = NSString(string: storageRootPath).expandingTildeInPath
    }

    public nonisolated static func jobFileURL(storageRootPath: String) -> URL {
        let expanded = NSString(string: storageRootPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent(migrationDirectoryName, isDirectory: true)
            .appendingPathComponent(jobFileName, isDirectory: false)
    }

    public static func hasPendingJob(storageRootPath: String = AppPaths.expandedStorageRoot) -> Bool {
        let url = jobFileURL(storageRootPath: storageRootPath)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func loadPendingJob() throws -> DatabaseMigrationJob? {
        let url = Self.jobFileURL(storageRootPath: defaultStorageRootPath)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DatabaseMigrationJob.self, from: data)
    }

    public func persist(job: DatabaseMigrationJob) throws {
        try persistJob(job)
    }

    public func clearPendingJob() throws {
        let url = Self.jobFileURL(storageRootPath: defaultStorageRootPath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func scheduleJob(
        kind: DatabaseMigrationKind,
        keychainAccount: String? = nil,
        keyMaterialSource: DatabaseKeyMaterialSource? = nil,
        databasePath: String? = nil,
        storageRootPath: String? = nil
    ) throws -> DatabaseMigrationJob {
        let dbPath = NSString(string: databasePath ?? defaultDatabasePath).expandingTildeInPath
        let rootPath = NSString(string: storageRootPath ?? defaultStorageRootPath).expandingTildeInPath
        var job = DatabaseMigrationJob(
            kind: kind,
            databasePath: dbPath,
            storageRootPath: rootPath,
            scheduledSchemaVersion: MigrationRunner.latestVersion,
            keychainAccount: keychainAccount,
            keyMaterialSource: keyMaterialSource
        )

        let footprint = try sourceFootprintBytes(databasePath: dbPath)
        job.observedFootprintBytes = footprint
        job.requiredFreeSpaceBytes = requiredFreeSpace(forFootprintBytes: footprint, kind: kind)
        job.estimatedDurationSeconds = estimateDuration(forFootprintBytes: footprint, kind: kind)
        job.lastMessage = "Scheduled"

        try persistJob(job)
        return job
    }

    public func markInterrupted(reason: String) throws {
        guard var job = try loadPendingJob(), !job.isTerminal else { return }
        job.interruptionReason = reason
        job.updatedAt = Date()
        job.lastMessage = "Interrupted: \(reason)"
        try persistJob(job)
    }

    public func resumeIfNeeded(
        progress: (@Sendable (DatabaseMigrationStatus) -> Void)? = nil
    ) async throws -> DatabaseMigrationJob? {
        guard let job = try loadPendingJob(), !job.isTerminal else {
            return nil
        }
        return try await run(job: job, progress: progress)
    }

    public func run(
        job: DatabaseMigrationJob,
        progress: (@Sendable (DatabaseMigrationStatus) -> Void)? = nil
    ) async throws -> DatabaseMigrationJob {
        var job = job
        if job.startedAt == nil {
            job.startedAt = Date()
        }
        job.updatedAt = Date()
        job.interruptionReason = nil
        try normalizePendingTransformJobForCurrentBuild(&job)
        if job.scheduledSchemaVersion == nil {
            job.scheduledSchemaVersion = MigrationRunner.latestVersion
        }
        try persistJob(job)
        emit(job: job, progress: progress)

        do {
            while !job.isTerminal {
                switch job.phase {
                case .preflight:
                    try performPreflight(job: &job)
                    job.phase = .shadowA
                case .shadowA:
                    try performShadowACopy(job: &job)
                    job.phase = .shadowBTransform
                case .shadowBTransform:
                    try await performTransform(job: &job)
                    job.phase = .verify
                case .verify:
                    try performVerification(job: &job)
                    job.phase = .swap
                case .swap:
                    try performSwap(job: &job)
                    job.phase = .cleanup
                case .cleanup:
                    try performCleanup(job: &job)
                    job.phase = .completed
                    job.completedAt = Date()
                case .completed:
                    break
                case .failed:
                    break
                }

                job.updatedAt = Date()
                try persistJob(job)
                emit(job: job, progress: progress)
            }
        } catch {
            job.phase = .failed
            job.lastError = error.localizedDescription
            job.lastMessage = "Failed: \(error.localizedDescription)"
            job.updatedAt = Date()
            try? persistJob(job)
            emit(job: job, progress: progress)
            throw error
        }

        if job.phase == .completed {
            try? clearPendingJob()
            emitInactive(progress: progress)
        }

        return job
    }

    public func estimateDuration(forFootprintBytes footprintBytes: Int64, kind: DatabaseMigrationKind) -> TimeInterval {
        switch kind {
        case .encrypt, .decrypt:
            let copiedBytes = max(Double(footprintBytes) * 2.0, 1)
            return max(45, copiedBytes / Self.sourceThroughputBytesPerSecond)
        case .schema:
            return 30
        }
    }

    public func requiredFreeSpace(
        forFootprintBytes footprintBytes: Int64,
        kind: DatabaseMigrationKind = .encrypt
    ) -> Int64 {
        let safeFootprint = max(footprintBytes, 0)
        let headroom = max(Int64(512 * 1024 * 1024), Int64(Double(safeFootprint) * 0.10))
        switch kind {
        case .encrypt, .decrypt:
            // Peak usage keeps the live source DB plus shadow A, shadow B,
            // and the rollback backup created during swap.
            return safeFootprint * 3 + headroom
        case .schema:
            return headroom
        }
    }

    public func sourceFootprintBytes(databasePath: String? = nil) throws -> Int64 {
        let dbPath = NSString(string: databasePath ?? defaultDatabasePath).expandingTildeInPath
        let dbURL = URL(fileURLWithPath: dbPath)
        let walURL = URL(fileURLWithPath: dbPath + "-wal")
        let shmURL = URL(fileURLWithPath: dbPath + "-shm")

        return try allocatedFileSizeIfPresent(at: dbURL)
            + allocatedFileSizeIfPresent(at: walURL)
            + allocatedFileSizeIfPresent(at: shmURL)
    }

    public func detectPendingSchemaMigration(
        databasePath: String? = nil,
        keychainAccount: String? = nil
    ) throws -> Bool {
        let dbPath = NSString(string: databasePath ?? defaultDatabasePath).expandingTildeInPath
        guard fileManager.fileExists(atPath: dbPath) else {
            return false
        }

        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            return false
        }

        let encryptionState = DatabaseManager.databaseFileEncryptionState(at: dbPath)
        if encryptionState.isEncrypted {
            let resolution = try DatabaseManager.resolveDatabaseConnection(
                at: dbPath,
                preferredEncrypted: true,
                encryptedKeyAccounts: [keychainAccount ?? AppPaths.keychainAccount]
            )
            try DatabaseManager.applyDatabaseConnectionResolution(resolution, to: db)
        }

        let currentVersion = try currentSchemaVersion(db: db)
        return currentVersion < MigrationRunner.latestVersion
    }

    // MARK: - Internal Phases

    private func performPreflight(job: inout DatabaseMigrationJob) throws {
        job.lastMessage = "Running migration preflight"

        if job.kind != .schema {
            try ensureWALCheckpointed(
                path: job.databasePath,
                keychainAccount: job.keychainAccount,
                keyMaterialSource: job.keyMaterialSource
            )
        }

        let footprint = try sourceFootprintBytes(databasePath: job.databasePath)
        let required = requiredFreeSpace(forFootprintBytes: footprint, kind: job.kind)
        let available = try availableCapacityBytes(at: URL(fileURLWithPath: job.storageRootPath))

        job.observedFootprintBytes = footprint
        job.requiredFreeSpaceBytes = required
        job.estimatedDurationSeconds = estimateDuration(
            forFootprintBytes: footprint,
            kind: job.kind
        )

        guard available >= required else {
            let shortfall = required - available
            throw DatabaseError.connectionFailed(
                underlying: "Insufficient disk space for database migration kind=\(job.kind.rawValue) (required=\(required), available=\(available), shortfall=\(shortfall))"
            )
        }

        job.bytesProcessed = 0
    }

    private func performShadowACopy(job: inout DatabaseMigrationJob) throws {
        job.lastMessage = "Creating shadow database copy"
        guard job.kind != .schema else {
            return
        }

        let sourceURL = URL(fileURLWithPath: job.databasePath)
        let shadowAURL = shadowAURL(for: job)
        try copyReplacing(sourceURL, shadowAURL)

        job.bytesProcessed = try allocatedFileSizeIfPresent(at: shadowAURL)
    }

    private func performTransform(job: inout DatabaseMigrationJob) async throws {
        switch job.kind {
        case .schema:
            job.lastMessage = "Applying schema migrations"
            try await runSchemaMigration(job: job)
        case .encrypt:
            job.lastMessage = "Transforming database to encrypted format"
            try transformDatabase(job: job, toEncrypted: true)
        case .decrypt:
            job.lastMessage = "Transforming database to plaintext format"
            try transformDatabase(job: job, toEncrypted: false)
        }

        let targetPath: String = {
            switch job.kind {
            case .schema:
                return job.databasePath
            case .encrypt, .decrypt:
                return shadowBURL(for: job).path
            }
        }()

        job.bytesProcessed = try allocatedFileSizeIfPresent(at: URL(fileURLWithPath: targetPath))
    }

    private func performVerification(job: inout DatabaseMigrationJob) throws {
        job.lastMessage = "Verifying migrated database"

        switch job.kind {
        case .schema:
            let encryptionState = DatabaseManager.databaseFileEncryptionState(at: job.databasePath)
            let db = try openVerificationDatabase(
                at: job.databasePath,
                isEncrypted: encryptionState.isEncrypted,
                keychainAccount: encryptionState.isEncrypted ? (job.keychainAccount ?? AppPaths.keychainAccount) : nil,
                keyMaterialSource: job.keyMaterialSource
            )
            defer { sqlite3_close_v2(db) }

            try verifyIntegrity(of: db, label: "schema-migrated database")
            _ = try queryInt(db: db, sql: "SELECT COUNT(*) FROM sqlite_master;")

            let currentVersion = try currentSchemaVersion(db: db)
            guard currentVersion >= MigrationRunner.latestVersion else {
                throw DatabaseError.migrationFailed(
                    version: currentVersion,
                    underlying: "Schema migration verification failed (expected >= \(MigrationRunner.latestVersion))"
                )
            }

        case .encrypt:
            let sourceDB = try openVerificationDatabase(
                at: shadowAURL(for: job).path,
                isEncrypted: false,
                keychainAccount: nil,
                keyMaterialSource: nil
            )
            let targetDB = try openVerificationDatabase(
                at: shadowBURL(for: job).path,
                isEncrypted: true,
                keychainAccount: job.keychainAccount ?? AppPaths.keychainAccount,
                keyMaterialSource: job.keyMaterialSource
            )
            defer {
                sqlite3_close_v2(sourceDB)
                sqlite3_close_v2(targetDB)
            }

            try verifyIntegrity(of: sourceDB, label: "shadow source database")
            try verifyIntegrity(of: targetDB, label: "encrypted migrated database")
            try verifyLogicalTableParity(sourceDB: sourceDB, targetDB: targetDB, job: job)

        case .decrypt:
            let sourceDB = try openVerificationDatabase(
                at: shadowAURL(for: job).path,
                isEncrypted: true,
                keychainAccount: job.keychainAccount ?? AppPaths.keychainAccount,
                keyMaterialSource: job.keyMaterialSource
            )
            let targetDB = try openVerificationDatabase(
                at: shadowBURL(for: job).path,
                isEncrypted: false,
                keychainAccount: nil,
                keyMaterialSource: nil
            )
            defer {
                sqlite3_close_v2(sourceDB)
                sqlite3_close_v2(targetDB)
            }

            try verifyIntegrity(of: sourceDB, label: "shadow source database")
            try verifyIntegrity(of: targetDB, label: "plaintext migrated database")
            try verifyLogicalTableParity(sourceDB: sourceDB, targetDB: targetDB, job: job)
        }
    }

    private func performSwap(job: inout DatabaseMigrationJob) throws {
        job.lastMessage = "Swapping migrated database into place"
        guard job.kind != .schema else {
            return
        }

        let sourceURL = URL(fileURLWithPath: job.databasePath)
        let shadowB = shadowBURL(for: job)
        let backup = backupURL(for: job)
        if try swapAlreadyApplied(job: job, sourceURL: sourceURL, shadowB: shadowB) {
            job.lastMessage = "Detected prior swap completion; advancing to cleanup"
            try? removeIfPresent(URL(fileURLWithPath: sourceURL.path + "-wal"))
            try? removeIfPresent(URL(fileURLWithPath: sourceURL.path + "-shm"))
            return
        }

        let promotedKeyContext: (
            sourceAccount: String,
            keyMaterialSource: DatabaseKeyMaterialSource,
            deleteCanonicalOnRollback: Bool,
            previousCanonicalKeyData: Data?
        )? = try {
            guard job.kind == .encrypt else { return nil }

            let sourceAccount = job.keychainAccount ?? AppPaths.keychainAccount
            let keyMaterialSource = job.keyMaterialSource ?? .legacyDatabaseKey
            guard sourceAccount != AppPaths.keychainAccount else {
                return (sourceAccount, keyMaterialSource, false, nil)
            }

            guard keyMaterialSource == .legacyDatabaseKey else {
                return nil
            }

            let previousCanonicalKeyData = try? DatabaseManager.loadDatabaseKeyFromKeychain(
                account: AppPaths.keychainAccount,
                source: keyMaterialSource
            )
            let deleteCanonicalOnRollback = !DatabaseManager.hasDatabaseKeyInKeychain(
                account: AppPaths.keychainAccount,
                source: keyMaterialSource
            )
            let keyData = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: sourceAccount,
                source: keyMaterialSource
            )
            try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: AppPaths.keychainAccount)
            return (sourceAccount, keyMaterialSource, deleteCanonicalOnRollback, previousCanonicalKeyData)
        }()

        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }

        if fileManager.fileExists(atPath: sourceURL.path) {
            try copyReplacing(sourceURL, backup)
            try fileManager.removeItem(at: sourceURL)
        }

        do {
            try fileManager.moveItem(at: shadowB, to: sourceURL)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? copyReplacing(backup, sourceURL)
            }
            if let promotedKeyContext {
                if let previousCanonicalKeyData = promotedKeyContext.previousCanonicalKeyData {
                    try? DatabaseManager.saveDatabaseKeyToKeychain(
                        previousCanonicalKeyData,
                        account: AppPaths.keychainAccount
                    )
                } else if promotedKeyContext.deleteCanonicalOnRollback {
                    DatabaseManager.deleteDatabaseKeyFromKeychain(account: AppPaths.keychainAccount)
                }
            }
            throw error
        }

        // Remove stale sidecars from old DB generation.
        try? removeIfPresent(URL(fileURLWithPath: sourceURL.path + "-wal"))
        try? removeIfPresent(URL(fileURLWithPath: sourceURL.path + "-shm"))
    }

    private func performCleanup(job: inout DatabaseMigrationJob) throws {
        job.lastMessage = "Cleaning migration artifacts"

        try? removeIfPresent(shadowAURL(for: job))
        try? removeIfPresent(shadowBURL(for: job))
        try? removeIfPresent(backupURL(for: job))

        switch job.kind {
        case .encrypt:
            if let pendingAccount = job.keychainAccount,
               pendingAccount != AppPaths.keychainAccount {
                DatabaseManager.deleteDatabaseKeyFromKeychain(account: pendingAccount)
            }
        case .decrypt:
            break
        case .schema:
            break
        }
    }

    // MARK: - Helpers

    private func transformDatabase(job: DatabaseMigrationJob, toEncrypted: Bool) throws {
        let sourcePath = shadowAURL(for: job).path
        let targetPath = shadowBURL(for: job).path
        let targetURL = URL(fileURLWithPath: targetPath)

        try removeIfPresent(targetURL)
        try? removeIfPresent(URL(fileURLWithPath: targetPath + "-wal"))
        try? removeIfPresent(URL(fileURLWithPath: targetPath + "-shm"))
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: targetPath),
           !fileManager.createFile(atPath: targetPath, contents: Data()) {
            throw DatabaseError.connectionFailed(
                underlying: "Failed to create migration target database at \(targetPath)"
            )
        }

        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(sourcePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw DatabaseError.connectionFailed(underlying: "Failed to open shadow source database")
        }

        if !toEncrypted {
            let sourceAccount = job.keychainAccount ?? AppPaths.keychainAccount
            let sourceKey = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: sourceAccount,
                source: job.keyMaterialSource
            )
            try applySQLCipherKey(sourceKey, to: db)
        }

        let targetKeySQL: String
        if toEncrypted {
            let targetAccount = job.keychainAccount ?? AppPaths.keychainAccount
            let targetKey = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: targetAccount,
                source: job.keyMaterialSource
            )
            targetKeySQL = "\"x'\(targetKey.hexEncodedString())'\""
        } else {
            targetKeySQL = "''"
        }

        try executeSQL(
            db: db,
            sql: "ATTACH DATABASE '\(targetPath.sqlEscaped())' AS migrated KEY \(targetKeySQL);"
        )
        if toEncrypted {
            try executeSQL(
                db: db,
                sql: "PRAGMA migrated.cipher_compatibility = \(DatabaseManager.retraceSQLCipherCompatibility);"
            )
        }
        try executeSQL(db: db, sql: "SELECT sqlcipher_export('migrated');")
        try executeSQL(db: db, sql: "DETACH DATABASE migrated;")

        let targetKeychainAccount = toEncrypted ? (job.keychainAccount ?? AppPaths.keychainAccount) : nil
        _ = try DatabaseIdentityStore.rollGeneration(
            at: targetPath,
            keychainAccount: targetKeychainAccount,
            storageRootPath: job.storageRootPath
        )
    }

    private func runSchemaMigration(job: DatabaseMigrationJob) async throws {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(job.databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw DatabaseError.connectionFailed(underlying: "Failed to open database for schema migration")
        }

        let encryptionState = DatabaseManager.databaseFileEncryptionState(at: job.databasePath)
        if encryptionState.isEncrypted {
            let account = job.keychainAccount ?? AppPaths.keychainAccount
            let keyData = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: account,
                source: job.keyMaterialSource
            )
            try applySQLCipherKey(keyData, to: db)
        }

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()
    }

    private func ensureWALCheckpointed(
        path: String,
        keychainAccount: String?,
        keyMaterialSource: DatabaseKeyMaterialSource?
    ) throws {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard fileManager.fileExists(atPath: path) else {
            throw DatabaseError.connectionFailed(
                underlying: "Database file missing before migration preflight: \(path)"
            )
        }

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw DatabaseError.connectionFailed(
                underlying: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open database for WAL checkpoint"
            )
        }

        let encryptionState = DatabaseManager.databaseFileEncryptionState(at: path)
        if encryptionState.isEncrypted {
            let account = keychainAccount ?? AppPaths.keychainAccount
            let keyData = try DatabaseManager.loadDatabaseKeyFromKeychain(
                account: account,
                source: keyMaterialSource
            )
            try applySQLCipherKey(keyData, to: db)
        }

        let checkpoint = try runWALCheckpoint(db: db)
        let walURL = URL(fileURLWithPath: path + "-wal")
        let shmURL = URL(fileURLWithPath: path + "-shm")
        let walBytes = try fileSizeIfPresent(at: walURL)

        guard checkpoint.busyFrames == 0, walBytes == 0 else {
            throw DatabaseError.connectionFailed(
                underlying: """
                Unable to fully checkpoint WAL before migration \
                (busy=\(checkpoint.busyFrames), walFrames=\(checkpoint.walFrames), \
                checkpointed=\(checkpoint.checkpointedFrames), walBytes=\(walBytes))
                """
            )
        }

        try? removeIfPresent(walURL)
        try? removeIfPresent(shmURL)
    }

    private func swapAlreadyApplied(
        job: DatabaseMigrationJob,
        sourceURL: URL,
        shadowB: URL
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: shadowB.path) else {
            return false
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return false
        }

        switch job.kind {
        case .encrypt:
            guard DatabaseManager.databaseFileEncryptionState(at: sourceURL.path) == .encrypted else {
                return false
            }

            let candidateAccounts = Array(Set([AppPaths.keychainAccount, job.keychainAccount].compactMap { $0 }))
            let resolution = try? DatabaseManager.resolveDatabaseConnection(
                at: sourceURL.path,
                preferredEncrypted: true,
                encryptedKeyAccounts: candidateAccounts
            )
            return resolution?.mode == .encrypted

        case .decrypt:
            return DatabaseManager.databaseFileEncryptionState(at: sourceURL.path) == .plaintext
                && DatabaseManager.canOpenDatabase(at: sourceURL.path)

        case .schema:
            return false
        }
    }

    private func currentSchemaVersion(db: OpaquePointer) throws -> Int {
        let tableExists = try queryInt(
            db: db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations';"
        )

        guard tableExists > 0 else {
            return 0
        }

        return try queryInt(db: db, sql: "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
    }

    private func openVerificationDatabase(
        at path: String,
        isEncrypted: Bool,
        keychainAccount: String?,
        keyMaterialSource: DatabaseKeyMaterialSource?
    ) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw verificationFailure("Failed to open verification database at \(path)")
        }

        do {
            if isEncrypted {
                let account = keychainAccount ?? AppPaths.keychainAccount
                let keyData = try DatabaseManager.loadDatabaseKeyFromKeychain(
                    account: account,
                    source: keyMaterialSource
                )
                try applySQLCipherKey(keyData, to: db)
            }
            return db
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    private func verifyIntegrity(of db: OpaquePointer, label: String) throws {
        let rows = try queryStrings(db: db, sql: "PRAGMA integrity_check;")
        guard rows.count == 1, rows.first == "ok" else {
            let details = rows.isEmpty ? "no response" : rows.prefix(5).joined(separator: "; ")
            throw verificationFailure("Integrity check failed for \(label): \(details)")
        }
    }

    private func verifyLogicalTableParity(
        sourceDB: OpaquePointer,
        targetDB: OpaquePointer,
        job: DatabaseMigrationJob
    ) throws {
        let sourceTables = try logicalTableNames(db: sourceDB)
        let targetTables = try logicalTableNames(db: targetDB)
        guard sourceTables == targetTables else {
            throw verificationFailure(
                "Logical table set mismatch during \(job.kind.rawValue) verification (source=\(sourceTables), target=\(targetTables))"
            )
        }

        for tableName in sourceTables {
            let sourceCount = try queryInt(
                db: sourceDB,
                sql: "SELECT COUNT(*) FROM \"\(tableName.sqlIdentifierEscaped())\";"
            )
            let targetCount = try queryInt(
                db: targetDB,
                sql: "SELECT COUNT(*) FROM \"\(tableName.sqlIdentifierEscaped())\";"
            )

            guard sourceCount == targetCount else {
                throw verificationFailure(
                    "Row-count parity failed for table '\(tableName)' during \(job.kind.rawValue) verification (source=\(sourceCount), target=\(targetCount))"
                )
            }
        }
    }

    private func logicalTableNames(db: OpaquePointer) throws -> [String] {
        let virtualTables = Set(
            try queryStrings(
                db: db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type='table'
                  AND sql LIKE 'CREATE VIRTUAL TABLE%';
                """
            )
        )
        let allTables = try queryStrings(
            db: db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type='table'
              AND name NOT LIKE 'sqlite_%'
              AND name != 'database_identity'
            ORDER BY name;
            """
        )

        return allTables.filter { tableName in
            !virtualTables.contains(where: { tableName.hasPrefix($0 + "_") })
        }
    }

    private func emit(
        job: DatabaseMigrationJob,
        progress: (@Sendable (DatabaseMigrationStatus) -> Void)?
    ) {
        guard let progress else { return }
        let normalizedProgress = normalizedProgress(for: job.phase)
        let remaining: TimeInterval?
        if let estimate = job.estimatedDurationSeconds {
            remaining = max(0, estimate * (1 - normalizedProgress))
        } else {
            remaining = nil
        }

        progress(
            DatabaseMigrationStatus(
                isActive: !job.isTerminal,
                jobID: job.id,
                kind: job.kind,
                phase: job.phase,
                progress: normalizedProgress,
                message: job.lastMessage,
                estimatedSecondsRemaining: remaining,
                updatedAt: Date()
            )
        )
    }

    private func emitInactive(progress: (@Sendable (DatabaseMigrationStatus) -> Void)?) {
        progress?(DatabaseMigrationStatus.inactive)
    }

    private struct WALCheckpointStatus {
        let busyFrames: Int
        let walFrames: Int
        let checkpointedFrames: Int
    }

    private func normalizedProgress(for phase: DatabaseMigrationPhase) -> Double {
        switch phase {
        case .preflight:
            return 0.05
        case .shadowA:
            return 0.20
        case .shadowBTransform:
            return 0.55
        case .verify:
            return 0.75
        case .swap:
            return 0.90
        case .cleanup:
            return 0.98
        case .completed:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    private func shadowAURL(for job: DatabaseMigrationJob) -> URL {
        URL(fileURLWithPath: job.databasePath + ".migration.shadow_a")
    }

    private func shadowBURL(for job: DatabaseMigrationJob) -> URL {
        URL(fileURLWithPath: job.databasePath + ".migration.shadow_b")
    }

    private func backupURL(for job: DatabaseMigrationJob) -> URL {
        URL(fileURLWithPath: job.databasePath + ".migration.backup")
    }

    private func normalizePendingTransformJobForCurrentBuild(_ job: inout DatabaseMigrationJob) throws {
        guard job.kind != .schema, job.phase != .preflight else {
            return
        }
        guard let scheduledSchemaVersion = job.scheduledSchemaVersion,
              scheduledSchemaVersion < MigrationRunner.latestVersion else {
            return
        }

        let sourceURL = URL(fileURLWithPath: job.databasePath)
        let shadowB = shadowBURL(for: job)
        if try swapAlreadyApplied(job: job, sourceURL: sourceURL, shadowB: shadowB) {
            return
        }

        let sourceKeychainAccount: String? = {
            switch job.kind {
            case .encrypt:
                return nil
            case .decrypt:
                return job.keychainAccount ?? AppPaths.keychainAccount
            case .schema:
                return job.keychainAccount
            }
        }()

        guard try detectPendingSchemaMigration(
            databasePath: job.databasePath,
            keychainAccount: sourceKeychainAccount
        ) else {
            return
        }

        try removeTransformArtifacts(for: job)
        job.phase = .preflight
        job.bytesProcessed = 0
        job.lastMessage = "Discarded partial migrated database after build upgrade; restarting from live source"
        job.updatedAt = Date()

        Log.warning(
            "[DatabaseMigrationEngine] Discarded partial \(job.kind.rawValue) artifacts because a newer build requires a schema migration on the live source database",
            category: .database
        )
    }

    private func removeTransformArtifacts(for job: DatabaseMigrationJob) throws {
        try removeIfPresent(shadowAURL(for: job))
        try removeIfPresent(URL(fileURLWithPath: shadowAURL(for: job).path + "-wal"))
        try removeIfPresent(URL(fileURLWithPath: shadowAURL(for: job).path + "-shm"))
        try removeIfPresent(shadowBURL(for: job))
        try removeIfPresent(URL(fileURLWithPath: shadowBURL(for: job).path + "-wal"))
        try removeIfPresent(URL(fileURLWithPath: shadowBURL(for: job).path + "-shm"))
        try removeIfPresent(backupURL(for: job))
    }

    private func persistJob(_ job: DatabaseMigrationJob) throws {
        let url = Self.jobFileURL(storageRootPath: job.storageRootPath)
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(job)
        try data.write(to: url, options: .atomic)
    }

    private func executeSQL(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private func queryInt(db: OpaquePointer, sql: String) throws -> Int {
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
            throw DatabaseError.queryFailed(query: sql, underlying: "No rows")
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func queryStrings(db: OpaquePointer, sql: String) throws -> [String] {
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

        var rows: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                let value = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                rows.append(value)
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError.queryFailed(
                    query: sql,
                    underlying: String(cString: sqlite3_errmsg(db))
                )
            }
        }
    }

    private func runWALCheckpoint(db: OpaquePointer) throws -> WALCheckpointStatus {
        let sql = "PRAGMA wal_checkpoint(TRUNCATE);"
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
            throw DatabaseError.queryFailed(query: sql, underlying: "No rows")
        }

        return WALCheckpointStatus(
            busyFrames: Int(sqlite3_column_int(statement, 0)),
            walFrames: Int(sqlite3_column_int(statement, 1)),
            checkpointedFrames: Int(sqlite3_column_int(statement, 2))
        )
    }

    private func verificationFailure(_ underlying: String) -> DatabaseError {
        .migrationFailed(version: MigrationRunner.latestVersion, underlying: underlying)
    }

    private func applySQLCipherKey(_ keyData: Data, to db: OpaquePointer) throws {
        try DatabaseManager.applyRetraceSQLCipherSettings(keyData, to: db)
    }

    private func copyReplacing(_ source: URL, _ destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func availableCapacityBytes(at rootURL: URL) throws -> Int64 {
        do {
            let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }

            let fsValues = try fileManager.attributesOfFileSystem(forPath: rootURL.path)
            if let free = fsValues[.systemFreeSize] as? NSNumber {
                return free.int64Value
            }

            return 0
        } catch {
            throw StorageError.fileReadFailed(path: rootURL.path, underlying: error.localizedDescription)
        }
    }

    private func allocatedFileSizeIfPresent(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }

        let values = try url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ])

        if let totalAllocated = values.totalFileAllocatedSize {
            return Int64(totalAllocated)
        }
        if let allocated = values.fileAllocatedSize {
            return Int64(allocated)
        }
        if let size = values.fileSize {
            return Int64(size)
        }
        return 0
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? NSNumber
        return fileSize?.int64Value ?? 0
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}

private extension String {
    func sqlEscaped() -> String {
        replacingOccurrences(of: "'", with: "''")
    }

    func sqlIdentifierEscaped() -> String {
        replacingOccurrences(of: "\"", with: "\"\"")
    }
}
