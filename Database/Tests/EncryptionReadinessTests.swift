import Foundation
import XCTest
import Security
import SQLCipher
import Shared
@testable import Database

final class EncryptionReadinessTests: XCTestCase {
    func testConnectionKeyErrorsRedactSecretsAcrossDiagnosticFormats() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let handle = try XCTUnwrap(db)
        // Force a real key/rekey failure without depending on a wrong password
        // causing PRAGMA key itself to fail (it usually does not).
        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            action == SQLITE_PRAGMA ? SQLITE_DENY : SQLITE_OK
        }, nil)
        let connections: [any DatabaseConnection] = [SQLiteConnection(db: handle), SQLCipherConnection(db: handle)]
        for sql in [
            "PRAGMA key = 'password-canary-32';",
            "pRaGmA\n main.rekey = \"x'abcdef0123456789'\";",
            "PRAGMA /* configuration */ key = 'password-canary-32';"
        ] {
            for connection in connections {
                for prepare in [false, true] {
                    do {
                        if prepare {
                            let statement = try connection.prepare(sql: sql)
                            connection.finalize(statement)
                        } else {
                            try connection.execute(sql: sql)
                        }
                        XCTFail("Expected authorizer rejection")
                    } catch {
                        for diagnostic in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                            XCTAssertFalse(diagnostic.contains("password-canary-32"))
                            XCTAssertFalse(diagnostic.contains("abcdef0123456789"))
                            XCTAssertTrue(diagnostic.contains("redacted"))
                        }
                    }
                }
            }
        }
    }

    func testRawConnectionErrorsRedactParserEchoAndPreserveOrdinaryDiagnostics() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let handle = try XCTUnwrap(db)
        let sql = "PRAGMA key = parser_secret_canary invalid;"
        XCTAssertNotEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        let message = String(cString: sqlite3_errmsg(handle))
        // The newer read-connection factory on main constructs this shared error
        // directly. Protect it even when the caller supplies unsanitized SQL.
        let error = DatabaseConnectionError.executionFailed(sql: sql, error: message)
        for diagnostic in [String(describing: error), String(reflecting: error), error.localizedDescription] {
            XCTAssertFalse(diagnostic.contains("parser_secret_canary"))
            XCTAssertTrue(diagnostic.contains("redacted"))
        }
        XCTAssertThrowsError(try SQLiteConnection(db: handle).execute(sql: "SELECT * FROM absent_table")) { error in
            XCTAssertTrue(String(describing: error).contains("absent_table"))
        }
    }

    func testDefaultDatabaseKeyUsesTheCanonicalMasterAccountAndOpensEncryptedData() throws {
        let master = Data((0..<32).map { UInt8($0) })
        let expected = MasterKeyManager.derivedKeyData(from: master, purpose: .databaseEncryption)
        var requestedAccount: String?
        let key = try DatabaseManager.loadDatabaseKey(
            account: AppPaths.keychainAccount,
            source: .masterKeyDerived,
            loadLegacy: { _ in throw NSError(domain: "missing", code: 1) },
            loadMasterDerived: { account in
                requestedAccount = account
                guard account == MasterKeyManager.keychainAccount else { throw NSError(domain: "wrong-account", code: 1) }
                return expected
            }
        )
        XCTAssertEqual(requestedAccount, MasterKeyManager.keychainAccount)
        try verifyEncryptedRoundTrip(key: key)
    }

    func testCustomMasterAccountRemainsScopedToThatLibrary() throws {
        let account = "master-key.test-library"
        let expected = Data(repeating: 23, count: 32)
        let key = try DatabaseManager.loadDatabaseKey(
            account: account, source: .masterKeyDerived,
            loadLegacy: { _ in throw NSError(domain: "missing", code: 1) },
            loadMasterDerived: { actual in XCTAssertEqual(actual, account); return expected }
        )
        try verifyEncryptedRoundTrip(key: key)
    }

    func testBoundAttachExportsAnEncryptedDatabaseThatCanBeReopened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let connection = try XCTUnwrap(db)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('portable-canary');", nil, nil, nil), SQLITE_OK)
        let key = Data(repeating: 83, count: 32)
        let target = root.appendingPathComponent("export.db")
        try DatabaseManager.attachMigrationDatabase(at: target.path, keyData: key, to: connection)
        XCTAssertEqual(sqlite3_exec(connection, "SELECT sqlcipher_export('migrated'); DETACH DATABASE migrated;", nil, nil, nil), SQLITE_OK)
        try assertStoredCanary(at: target, key: key)
    }

    func testFailedAttachErrorAndSavedJobDoNotContainTheKey() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let connection = try XCTUnwrap(db)
        let key = Data(repeating: 73, count: 32)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        // A nonexistent parent makes the real SQLite ATTACH fail.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("child/export.db")
        do {
            try DatabaseManager.attachMigrationDatabase(at: missing.path, keyData: key, to: connection)
            XCTFail("Expected attach failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(hex))
            var job = DatabaseMigrationJob(kind: .encrypt, databasePath: "/test/source.db", storageRootPath: "/test")
            job.lastError = error.localizedDescription
            job.lastMessage = "Failed: \(error.localizedDescription)"
            let saved = try JSONEncoder().encode(job)
            XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(hex))
        }
    }

    func testFailedLegacyKeyUpdatePreservesTheExistingKey() throws {
        let oldKey = Data(repeating: 3, count: 32)
        let stored = oldKey
        var updateCalled = false
        XCTAssertThrowsError(try DatabaseManager.saveKeyToKeychainStatic(
            Data(repeating: 9, count: 32),
            service: "io.retrace.tests.\(UUID().uuidString)", account: "test-key",
            addItem: { _, _ in errSecDuplicateItem },
            updateItem: { query, changes in
                updateCalled = true
                XCTAssertEqual((query as NSDictionary)[kSecAttrSynchronizable as String] as? Bool, true)
                XCTAssertNotNil((changes as NSDictionary)[kSecValueData as String])
                return errSecInteractionNotAllowed
            }
        ))
        XCTAssertTrue(updateCalled)
        XCTAssertEqual(stored, oldKey)
        // The preserved key still decrypts the existing database.
        try verifyEncryptedRoundTrip(key: stored)
    }

    func testLegacyKeyCreationFailureDoesNotAttemptAReplacement() {
        var updateCalled = false
        XCTAssertThrowsError(try DatabaseManager.saveKeyToKeychainStatic(
            Data(repeating: 9, count: 32),
            service: "io.retrace.tests.\(UUID().uuidString)", account: "test-key",
            addItem: { _, _ in errSecMissingEntitlement },
            updateItem: { _, _ in updateCalled = true; return errSecSuccess }
        ))
        XCTAssertFalse(updateCalled)
    }

    func testKeyPragmaFailureDoesNotIncludeKeyMaterial() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let connection = try XCTUnwrap(db)
        // Deny the actual PRAGMA so its sensitive error path executes.
        sqlite3_set_authorizer(connection, { _, action, _, _, _, _ in
            action == SQLITE_PRAGMA ? SQLITE_DENY : SQLITE_OK
        }, nil)
        let key = Data(repeating: 41, count: 32)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try DatabaseManager.applyRetraceSQLCipherSettings(key, to: connection)) { error in
            XCTAssertFalse(error.localizedDescription.contains(hex))
            XCTAssertFalse(error.localizedDescription.contains("PRAGMA key"))
        }
    }

    func testDefaultLookupFallsBackToTheCanonicalMasterWhenNoLegacyKeyExists() throws {
        let expected = Data(repeating: 37, count: 32)
        let key = try DatabaseManager.loadDatabaseKey(
            account: AppPaths.keychainAccount, source: nil,
            loadLegacy: { _ in throw NSError(domain: "missing", code: 1) },
            loadMasterDerived: { account in
                XCTAssertEqual(account, MasterKeyManager.keychainAccount)
                return expected
            }
        )
        try verifyEncryptedRoundTrip(key: key)
    }

    func testSuccessfulLegacyKeyUpdateUsesOnlyAtomicUpdate() throws {
        var stored = Data(repeating: 3, count: 32)
        let replacement = Data(repeating: 9, count: 32)
        var calls: [String] = []
        try DatabaseManager.saveKeyToKeychainStatic(
            replacement, service: "io.retrace.tests.\(UUID().uuidString)", account: "test-key",
            addItem: { _, _ in calls.append("add"); return errSecDuplicateItem },
            updateItem: { _, changes in
                calls.append("update")
                stored = try! XCTUnwrap((changes as NSDictionary)[kSecValueData as String] as? Data)
                return errSecSuccess
            }
        )
        XCTAssertEqual(calls, ["add", "update"])
        try verifyEncryptedRoundTrip(key: stored)
        XCTAssertEqual(stored, replacement)
    }

    func testOldMigrationJobsStillResolveTheirLegacyDatabaseKey() throws {
        let legacy = Data(repeating: 71, count: 32)
        var masterWasQueried = false
        let key = try DatabaseManager.loadDatabaseKey(
            account: AppPaths.keychainAccount, source: nil,
            loadLegacy: { account in XCTAssertEqual(account, AppPaths.keychainAccount); return legacy },
            loadMasterDerived: { _ in masterWasQueried = true; return Data(repeating: 99, count: 32) }
        )
        XCTAssertFalse(masterWasQueried)
        try verifyEncryptedRoundTrip(key: key)
    }

    private func verifyEncryptedRoundTrip(key: Data) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        do {
            try DatabaseManager.applyRetraceSQLCipherSettings(key, to: connection)
            XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('portable-canary');", nil, nil, nil), SQLITE_OK)
            sqlite3_close(connection)
        } catch { sqlite3_close(connection); throw error }
        try assertStoredCanary(at: url, key: key)
    }

    private func assertStoredCanary(at url: URL, key: Data) throws {
        XCTAssertFalse(try Data(contentsOf: url).starts(with: Data("SQLite format 3".utf8)))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("portable-canary"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let connection = try XCTUnwrap(db)
        try DatabaseManager.applyRetraceSQLCipherSettings(key, to: connection)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT value FROM sample", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(statement, 0).map { String(cString: $0) }, "portable-canary")
    }
}
