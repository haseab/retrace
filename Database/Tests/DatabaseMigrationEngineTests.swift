import XCTest
import Foundation
import SQLCipher
import Shared
@testable import Database

final class DatabaseMigrationEngineTests: XCTestCase {
    override func tearDown() {
        DatabaseManager.deleteDatabaseKeyFromKeychain(account: "sqlcipher-key.tests.pending")
        super.tearDown()
    }

    func testDatabaseFileEncryptionStateDetectsPlaintextHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_plaintext_header_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("SQLite format 3\0".utf8).write(to: url)

        XCTAssertEqual(
            DatabaseManager.databaseFileEncryptionState(at: url.path),
            .plaintext
        )
    }

    func testDatabaseFileEncryptionStateDetectsEncryptedHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_encrypted_header_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0x91, 0x4A, 0x13, 0x77, 0x2B, 0x08, 0xFF, 0x10]).write(to: url)

        XCTAssertEqual(
            DatabaseManager.databaseFileEncryptionState(at: url.path),
            .encrypted
        )
    }

    func testDatabaseFileEncryptionStateDetectsEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_empty_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        FileManager.default.createFile(atPath: url.path, contents: Data())

        XCTAssertEqual(
            DatabaseManager.databaseFileEncryptionState(at: url.path),
            .empty
        )
    }

    func testRequiredFreeSpaceUsesMinimumHeadroomForSmallFootprints() async {
        let engine = DatabaseMigrationEngine()
        let footprint = Int64(1_024 * 1_024 * 1_024)

        let required = await engine.requiredFreeSpace(forFootprintBytes: footprint)

        XCTAssertEqual(required, Int64(3_758_096_384))
    }

    func testRequiredFreeSpaceUsesTenPercentHeadroomForLargeFootprints() async {
        let engine = DatabaseMigrationEngine()
        let footprint = Int64(10 * 1_024 * 1_024 * 1_024)

        let required = await engine.requiredFreeSpace(forFootprintBytes: footprint)

        XCTAssertEqual(required, Int64(33_285_996_544))
    }

    func testRequiredFreeSpaceForSchemaUsesHeadroomOnly() async {
        let engine = DatabaseMigrationEngine()
        let footprint = Int64(10 * 1_024 * 1_024 * 1_024)

        let required = await engine.requiredFreeSpace(
            forFootprintBytes: footprint,
            kind: .schema
        )

        XCTAssertEqual(required, Int64(1_073_741_824))
    }

    func testEstimateDurationHasSafetyFloorForSmallMigrations() async {
        let engine = DatabaseMigrationEngine()
        let footprint = Int64(160 * 1_024 * 1_024)

        let duration = await engine.estimateDuration(forFootprintBytes: footprint, kind: .encrypt)

        XCTAssertEqual(duration, 45, accuracy: 0.001)
    }

    func testRecoveryPhraseExportRoundTripsThroughParser() throws {
        let phrase = DatabaseRecoveryPhrase.generate()

        let parsed = try DatabaseRecoveryPhrase.parse(phrase.exportText)

        XCTAssertEqual(parsed.words, phrase.words)
        XCTAssertEqual(parsed.derivedKeyData, phrase.derivedKeyData)
    }

    func testRecoveryPhraseRejectsChecksumMismatch() throws {
        let phrase = DatabaseRecoveryPhrase.generate()
        var tamperedWords = phrase.words
        tamperedWords[0] = tamperedWords[0] == "amberacre" ? "amberbeam" : "amberacre"

        XCTAssertThrowsError(try DatabaseRecoveryPhrase(words: tamperedWords)) { error in
            guard case DatabaseRecoveryPhraseError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testVerifyDatabaseAccessRejectsWrongKeyForEncryptedDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_verify_wrong_key_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let correctKey = DatabaseManager.generateDatabaseKey()
        let wrongKey = DatabaseManager.generateDatabaseKey()
        try createEncryptedDatabase(at: url.path, keyData: correctKey)

        XCTAssertThrowsError(
            try DatabaseManager.verifyDatabaseAccess(at: url.path, keyData: wrongKey)
        )
    }

    func testVerifyDatabaseAccessAcceptsCorrectKeyForEncryptedDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_verify_correct_key_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let key = DatabaseManager.generateDatabaseKey()
        try createEncryptedDatabase(at: url.path, keyData: key)

        XCTAssertNoThrow(
            try DatabaseManager.verifyDatabaseAccess(at: url.path, keyData: key)
        )
    }

    func testResolveDatabaseConnectionUsesProvidedPendingAccountForEncryptedDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_resolve_pending_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let pendingAccount = "sqlcipher-key.tests.pending"
        let key = DatabaseManager.generateDatabaseKey()
        try createEncryptedDatabase(at: url.path, keyData: key)
        try DatabaseManager.saveDatabaseKeyToKeychain(key, account: pendingAccount)

        let resolution = try DatabaseManager.resolveDatabaseConnection(
            at: url.path,
            preferredEncrypted: true,
            encryptedKeyAccounts: [pendingAccount]
        )

        XCTAssertEqual(resolution.mode, .encrypted)
        XCTAssertEqual(resolution.keychainAccount, pendingAccount)
    }

    func testResolveDatabaseConnectionSupportsMasterDerivedDatabaseKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_resolve_master_derived_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let masterAccount = "master-key.tests.pending"
        defer { try? MasterKeyManager.resetMasterKey(keychainAccount: masterAccount) }

        let masterKeyData = Data((0..<32).map { UInt8(255 - $0) })
        let recoveryPhrase = MasterKeyManager.recoveryPhrase(for: masterKeyData)
        _ = try MasterKeyManager.restoreMasterKey(
            fromRecoveryPhrase: recoveryPhrase,
            storagePolicy: .localOnly,
            keychainAccount: masterAccount
        )

        let key = try MasterKeyManager.derivedKeyData(for: .databaseEncryption, account: masterAccount)
        try createEncryptedDatabase(at: url.path, keyData: key)

        let resolution = try DatabaseManager.resolveDatabaseConnection(
            at: url.path,
            preferredEncrypted: true,
            encryptedKeyAccounts: [masterAccount]
        )

        XCTAssertEqual(resolution.mode, .encrypted)
        XCTAssertEqual(resolution.keychainAccount, masterAccount)
        XCTAssertEqual(resolution.keyMaterialSource, .masterKeyDerived)
    }

    func testEncryptMigrationResumesFromCompletedSwapWhenShadowBIsMissing() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_swap_resume_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let backupURL = URL(fileURLWithPath: dbURL.path + ".migration.backup")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        try createEncryptedDatabase(at: dbURL.path, keyData: keyData)
        try Data("backup".utf8).write(to: backupURL)
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = DatabaseMigrationJob(
            kind: .encrypt,
            phase: .swap,
            databasePath: dbURL.path,
            storageRootPath: testRoot.path,
            keychainAccount: pendingAccount
        )

        let finalJob = try await engine.run(job: job)

        XCTAssertEqual(finalJob.phase, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(DatabaseManager.hasDatabaseKeyInKeychain(account: pendingAccount))
        XCTAssertTrue(DatabaseManager.canOpenDatabase(at: dbURL.path, keyData: keyData))
    }

    func testEncryptMigrationCompletesWithIntegrityAndParityVerification() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_encrypt_verify_success_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let shadowAURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_a")
        let shadowBURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_b")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        try createPlaintextDatabase(at: dbURL.path, rowCount: 3)
        try createPlaintextDatabase(at: shadowAURL.path, rowCount: 3)
        try createEncryptedDatabase(at: shadowBURL.path, keyData: keyData, rowCount: 3)
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = DatabaseMigrationJob(
            kind: .encrypt,
            phase: .verify,
            databasePath: dbURL.path,
            storageRootPath: testRoot.path,
            keychainAccount: pendingAccount
        )

        let finalJob = try await engine.run(job: job)

        XCTAssertEqual(finalJob.phase, .completed)
        XCTAssertEqual(DatabaseManager.databaseFileEncryptionState(at: dbURL.path), .encrypted)
        XCTAssertTrue(DatabaseManager.canOpenDatabase(at: dbURL.path, keyData: keyData))
    }

    func testEncryptMigrationPreservesLibraryAndShardButRollsGeneration() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_encrypt_identity_roll_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        let fileDatabase = DatabaseManager(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let originalIdentity: DatabaseIdentity
        do {
            try await fileDatabase.initialize()
            originalIdentity = try await fileDatabase.currentDatabaseIdentity()
            try await fileDatabase.close()
        } catch {
            try? await fileDatabase.close()
            throw error
        }

        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = try await engine.scheduleJob(kind: .encrypt, keychainAccount: pendingAccount)

        let finalJob = try await engine.run(job: job)
        let migratedIdentity = try XCTUnwrap(
            DatabaseIdentityStore.readIdentity(at: dbURL.path, keyData: keyData)
        )

        XCTAssertEqual(finalJob.phase, .completed)
        XCTAssertEqual(migratedIdentity.libraryID, originalIdentity.libraryID)
        XCTAssertEqual(migratedIdentity.shardID, originalIdentity.shardID)
        XCTAssertNotEqual(migratedIdentity.generationID, originalIdentity.generationID)
    }

    func testEncryptVerificationRejectsLogicalRowCountDrift() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_encrypt_verify_drift_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let shadowAURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_a")
        let shadowBURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_b")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        try createPlaintextDatabase(at: shadowAURL.path, rowCount: 3)
        try createEncryptedDatabase(at: shadowBURL.path, keyData: keyData, rowCount: 2)
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = DatabaseMigrationJob(
            kind: .encrypt,
            phase: .verify,
            databasePath: dbURL.path,
            storageRootPath: testRoot.path,
            keychainAccount: pendingAccount
        )

        do {
            _ = try await engine.run(job: job)
            XCTFail("Expected verification to fail when migrated row counts drift")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Row-count parity failed"))
        }
    }

    func testEncryptMigrationResetsPreSwapArtifactsWhenLiveSchemaNeedsUpgrade() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_encrypt_reset_for_schema_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let shadowAURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_a")
        let shadowBURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_b")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        try createPlaintextDatabase(at: dbURL.path, rowCount: 3, schemaVersion: 13)
        try createPlaintextDatabase(at: shadowAURL.path, rowCount: 3)
        try createEncryptedDatabase(at: shadowBURL.path, keyData: keyData, rowCount: 1)
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = DatabaseMigrationJob(
            kind: .encrypt,
            phase: .verify,
            databasePath: dbURL.path,
            storageRootPath: testRoot.path,
            scheduledSchemaVersion: 13,
            keychainAccount: pendingAccount
        )

        let finalJob = try await engine.run(job: job)

        XCTAssertEqual(finalJob.phase, .completed)
        XCTAssertEqual(DatabaseManager.databaseFileEncryptionState(at: dbURL.path), .encrypted)
        XCTAssertTrue(DatabaseManager.canOpenDatabase(at: dbURL.path, keyData: keyData))
    }

    func testDecryptVerificationRejectsLogicalRowCountDrift() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_decrypt_verify_drift_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let shadowAURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_a")
        let shadowBURL = URL(fileURLWithPath: dbURL.path + ".migration.shadow_b")
        let pendingAccount = "sqlcipher-key.tests.pending"
        let keyData = DatabaseManager.generateDatabaseKey()

        try createEncryptedDatabase(at: shadowAURL.path, keyData: keyData, rowCount: 4)
        try createPlaintextDatabase(at: shadowBURL.path, rowCount: 1)
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: pendingAccount)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = DatabaseMigrationJob(
            kind: .decrypt,
            phase: .verify,
            databasePath: dbURL.path,
            storageRootPath: testRoot.path,
            keychainAccount: pendingAccount
        )

        do {
            _ = try await engine.run(job: job)
            XCTFail("Expected verification to fail when migrated row counts drift")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Row-count parity failed"))
        }
    }

    func testDecryptMigrationRetainsCanonicalKeyAfterCleanup() async throws {
        let previousKeyData = try? DatabaseManager.loadDatabaseKeyFromKeychain()
        defer {
            if let previousKeyData {
                try? DatabaseManager.saveDatabaseKeyToKeychain(previousKeyData)
            } else {
                DatabaseManager.deleteDatabaseKeyFromKeychain(account: AppPaths.keychainAccount)
            }
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_decrypt_retains_key_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let dbURL = testRoot.appendingPathComponent("retrace.db")
        let keyData = DatabaseManager.generateDatabaseKey()
        try DatabaseManager.saveDatabaseKeyToKeychain(keyData, account: AppPaths.keychainAccount)
        try createEncryptedDatabase(at: dbURL.path, keyData: keyData, rowCount: 2)

        let engine = DatabaseMigrationEngine(
            databasePath: dbURL.path,
            storageRootPath: testRoot.path
        )
        let job = try await engine.scheduleJob(kind: .decrypt)

        let finalJob = try await engine.run(job: job)

        XCTAssertEqual(finalJob.phase, .completed)
        XCTAssertEqual(DatabaseManager.databaseFileEncryptionState(at: dbURL.path), .plaintext)
        XCTAssertTrue(DatabaseManager.hasDatabaseKeyInKeychain(account: AppPaths.keychainAccount))
    }

    private func createPlaintextDatabase(
        at path: String,
        rowCount: Int = 1,
        schemaVersion: Int? = nil
    ) throws {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database at \(path)")
            return
        }

        try seedTestDatabase(db: db, rowCount: rowCount, schemaVersion: schemaVersion)
    }

    private func createEncryptedDatabase(
        at path: String,
        keyData: Data,
        rowCount: Int = 1,
        schemaVersion: Int? = nil
    ) throws {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close_v2(db)
            }
        }

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database at \(path)")
            return
        }

        try DatabaseManager.applyRetraceSQLCipherSettings(keyData, to: db)

        try seedTestDatabase(db: db, rowCount: rowCount, schemaVersion: schemaVersion)
    }

    private func seedTestDatabase(
        db: OpaquePointer,
        rowCount: Int,
        schemaVersion: Int? = nil
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT);", nil, nil, &errorMessage),
            SQLITE_OK
        )

        for index in 0..<rowCount {
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "INSERT INTO t (value) VALUES ('row_\(index)');",
                    nil,
                    nil,
                    &errorMessage
                ),
                SQLITE_OK
            )
        }

        if let schemaVersion {
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    """
                    CREATE TABLE schema_migrations (
                        version INTEGER PRIMARY KEY,
                        applied_at INTEGER
                    );
                    INSERT INTO schema_migrations (version, applied_at)
                    VALUES (\(schemaVersion), 0);
                    """,
                    nil,
                    nil,
                    &errorMessage
                ),
                SQLITE_OK
            )
        }
    }
}
