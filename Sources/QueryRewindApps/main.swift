import Foundation
import SQLCipher
import Shared

// Rewind database path and password
let dbPath = NSString(string: AppPaths.rewindDBPath).expandingTildeInPath
let password = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"

// Output file path
let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
let outputPath = "\(homeDir)/Desktop/rewind_segments.txt"

print("Opening Rewind database at: \(dbPath)")

// Check if file exists
guard FileManager.default.fileExists(atPath: dbPath) else {
    print("ERROR: Database file not found at: \(dbPath)")
    exit(1)
}

// Open database
var db: OpaquePointer?
let openResult = sqlite3_open(dbPath, &db)
guard openResult == SQLITE_OK else {
    let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
    print("Failed to open database: \(errorMsg) (code: \(openResult))")
    exit(1)
}
print("✓ Database file opened")

// Set encryption key using sqlite3_exec with error pointer
var keyError: UnsafeMutablePointer<Int8>?
let keySQL = "PRAGMA key = '\(password)'"
let keyResult = sqlite3_exec(db, keySQL, nil, nil, &keyError)
if keyResult != SQLITE_OK {
    let error = keyError.map { String(cString: $0) } ?? "Unknown error"
    sqlite3_free(keyError)
    print("Failed to set encryption key: \(error)")
    sqlite3_close(db)
    exit(1)
}
print("✓ Encryption key set")

// Set cipher compatibility (Rewind uses SQLCipher 4)
var compatError: UnsafeMutablePointer<Int8>?
let compatResult = sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError)
if compatResult != SQLITE_OK {
    let error = compatError.map { String(cString: $0) } ?? "Unknown error"
    sqlite3_free(compatError)
    print("Failed to set cipher compatibility: \(error)")
    sqlite3_close(db)
    exit(1)
}
print("✓ Cipher compatibility set to 4")

// Verify connection by testing a simple query
var testStmt: OpaquePointer?
guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK else {
    let errMsg = String(cString: sqlite3_errmsg(db!))
    print("Failed to verify encryption key: \(errMsg)")
    sqlite3_close(db)
    exit(1)
}

guard sqlite3_step(testStmt) == SQLITE_ROW else {
    sqlite3_finalize(testStmt)
    print("Failed to read from encrypted database")
    sqlite3_close(db)
    exit(1)
}

let tableCount = sqlite3_column_int(testStmt, 0)
sqlite3_finalize(testStmt)
print("✓ Encryption verified (\(tableCount) objects in schema)")

print("\nQuerying segments...")

// Query distinct bundle IDs with counts
let query = """
    SELECT bundleId, COUNT(*) as segment_count
    FROM segment
    WHERE bundleId IS NOT NULL AND bundleId != ''
    GROUP BY bundleId
    ORDER BY segment_count DESC
    """

var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
    let errMsg = String(cString: sqlite3_errmsg(db!))
    print("Failed to prepare query: \(errMsg)")
    sqlite3_close(db)
    exit(1)
}

var results: [String] = []
results.append("Rewind Segments")
results.append(String(repeating: "=", count: 80))
results.append("Bundle ID".padding(toLength: 60, withPad: " ", startingAt: 0) + "Segments")
results.append(String(repeating: "-", count: 80))

var totalSegments = 0
var appCount = 0

while sqlite3_step(stmt) == SQLITE_ROW {
    if let bundleIdPtr = sqlite3_column_text(stmt, 0) {
        let bundleId = String(cString: bundleIdPtr)
        let count = sqlite3_column_int(stmt, 1)
        let line = bundleId.padding(toLength: 60, withPad: " ", startingAt: 0) + "\(count)"
        results.append(line)
        totalSegments += Int(count)
        appCount += 1
    }
}

sqlite3_finalize(stmt)
sqlite3_close(db)

results.append(String(repeating: "-", count: 80))
results.append("Total: \(appCount) apps, \(totalSegments) segments")

// Write to file
let output = results.joined(separator: "\n")
do {
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("\n✓ Results written to: \(outputPath)")
    print("\n\(output)")
} catch {
    print("Failed to write output: \(error)")
    exit(1)
}
