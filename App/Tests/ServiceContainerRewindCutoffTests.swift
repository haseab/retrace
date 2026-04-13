import XCTest
import Database
import SQLCipher
@testable import App

final class ServiceContainerRewindCutoffTests: XCTestCase {
    private let rewindTestPassword = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
    private let rewindCipherCompatibility = 4

    func testStoredRewindCutoffDateReturnsPersistedValue() {
        let suiteName = "io.retrace.app.tests.rewindCutoff.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedDate = Date(timeIntervalSince1970: 1_772_934_400.123)
        defaults.set(storedDate, forKey: "rewindCutoffDate")

        XCTAssertEqual(ServiceContainer.storedRewindCutoffDate(in: defaults), storedDate)
    }

    func testDefaultRewindCutoffDateUsesDecember20_2025AtLocalMidnightForCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let cutoffDate = ServiceContainer.defaultRewindCutoffDate(calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: cutoffDate)

        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 20)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testRewindCutoffDateFallsBackToDefaultWhenUnset() {
        let suiteName = "io.retrace.app.tests.rewindCutoff.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            ServiceContainer.rewindCutoffDate(in: defaults, calendar: calendar),
            ServiceContainer.defaultRewindCutoffDate(calendar: calendar)
        )
    }

    func testLatestRewindFrameDateReturnsMostRecentFrameTimestamp() throws {
        let latestDate = Date(timeIntervalSince1970: 1_773_960_245.456)
        let olderDate = latestDate.addingTimeInterval(-540)
        let databaseURL = try makeEncryptedRewindDatabase(
            createdAtValues: [
                DatabaseConfig.rewindDateFormatter.string(from: olderDate),
                DatabaseConfig.rewindDateFormatter.string(from: latestDate),
            ]
        )

        XCTAssertEqual(
            ServiceContainer.latestRewindFrameDate(databasePath: databaseURL.path),
            latestDate
        )
    }

    func testLatestRewindFrameDateReturnsNilWhenDatabaseIsMissing() {
        XCTAssertNil(
            ServiceContainer.latestRewindFrameDate(
                databasePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("db-enc.sqlite3")
                    .path
            )
        )
    }

    private func makeEncryptedRewindDatabase(createdAtValues: [String]) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("db-enc.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)

        guard let db else {
            XCTFail("Failed to create SQLCipher database")
            return databaseURL
        }

        defer {
            sqlite3_close_v2(db)
        }
        addTeardownBlock {
            try? fileManager.removeItem(at: directoryURL)
        }

        try execSQL("PRAGMA key = '\(rewindTestPassword)'", db: db)
        try execSQL("PRAGMA cipher_compatibility = \(rewindCipherCompatibility)", db: db)
        try execSQL("CREATE TABLE frame (createdAt TEXT NOT NULL)", db: db)

        for createdAt in createdAtValues {
            try execSQL("INSERT INTO frame (createdAt) VALUES ('\(createdAt)')", db: db)
        }

        return databaseURL
    }

    private func execSQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "ServiceContainerRewindCutoffTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
