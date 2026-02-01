#!/usr/bin/env swift

import Foundation
import SQLite3

// MARK: - Test Script for Rewind Database Connection
// This script tests if we can properly decrypt and query the Rewind database
// Note: Path should match AppPaths.defaultRewindStorageRoot in Shared/AppPaths.swift

let password = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
// Default Rewind storage root - matches AppPaths.defaultRewindStorageRoot
let defaultRewindStorageRoot = "~/Library/Application Support/com.memoryvault.MemoryVault"
let rewindStorageRoot = NSString(string: defaultRewindStorageRoot).expandingTildeInPath
let dbPath = "\(rewindStorageRoot)/db-enc.sqlite3"

print("=" * 60)
print("REWIND DATABASE CONNECTION TEST")
print("=" * 60)
print()

// Check if database exists
print("[1] Checking database file...")
if FileManager.default.fileExists(atPath: dbPath) {
    print("    ✓ Database found at: \(dbPath)")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
       let size = attrs[.size] as? Int64 {
        print("    ✓ File size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
    }
} else {
    print("    ✗ Database NOT found at: \(dbPath)")
    exit(1)
}
print()

// Open database
print("[2] Opening database connection...")
var db: OpaquePointer?
let openResult = sqlite3_open(dbPath, &db)
if openResult == SQLITE_OK {
    print("    ✓ Database opened successfully")
} else {
    let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
    print("    ✗ Failed to open database: \(errorMsg)")
    exit(1)
}
print()

// Set encryption key
print("[3] Setting encryption key...")
let keySQL = "PRAGMA key = '\(password)'"
if sqlite3_exec(db, keySQL, nil, nil, nil) == SQLITE_OK {
    print("    ✓ Encryption key set")
} else {
    print("    ✗ Failed to set encryption key")
    exit(1)
}
print()

// Set cipher compatibility
print("[4] Setting cipher compatibility (SQLCipher 4)...")
if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, nil) == SQLITE_OK {
    print("    ✓ Cipher compatibility set to 4")
} else {
    print("    ✗ Failed to set cipher compatibility")
    exit(1)
}
print()

// Verify encryption key works
print("[5] Verifying encryption key...")
var testStmt: OpaquePointer?
let testSQL = "SELECT count(*) FROM sqlite_master"
if sqlite3_prepare_v2(db, testSQL, -1, &testStmt, nil) == SQLITE_OK {
    if sqlite3_step(testStmt) == SQLITE_ROW {
        let count = sqlite3_column_int(testStmt, 0)
        print("    ✓ Encryption key verified! Found \(count) tables/indexes in sqlite_master")
    } else {
        print("    ✗ Failed to step through test query")
        exit(1)
    }
    sqlite3_finalize(testStmt)
} else {
    let errorMsg = String(cString: sqlite3_errmsg(db!))
    print("    ✗ Failed to prepare test query: \(errorMsg)")
    print("    This usually means the encryption key is wrong!")
    exit(1)
}
print()

// List all tables
print("[6] Listing all tables...")
var listStmt: OpaquePointer?
let listSQL = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
if sqlite3_prepare_v2(db, listSQL, -1, &listStmt, nil) == SQLITE_OK {
    var tables: [String] = []
    while sqlite3_step(listStmt) == SQLITE_ROW {
        if let name = sqlite3_column_text(listStmt, 0) {
            tables.append(String(cString: name))
        }
    }
    sqlite3_finalize(listStmt)
    print("    Found \(tables.count) tables:")
    for table in tables {
        print("      - \(table)")
    }
} else {
    print("    ✗ Failed to list tables")
}
print()

// Count frames
print("[7] Counting frames in 'frame' table...")
var countStmt: OpaquePointer?
let countSQL = "SELECT count(*) FROM frame"
if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
    if sqlite3_step(countStmt) == SQLITE_ROW {
        let count = sqlite3_column_int64(countStmt, 0)
        print("    ✓ Total frames: \(count)")
    }
    sqlite3_finalize(countStmt)
} else {
    let errorMsg = String(cString: sqlite3_errmsg(db!))
    print("    ✗ Failed to count frames: \(errorMsg)")
}
print()

// Get date range of frames
print("[8] Getting frame date range...")
var rangeStmt: OpaquePointer?
let rangeSQL = "SELECT MIN(createdAt), MAX(createdAt) FROM frame"
if sqlite3_prepare_v2(db, rangeSQL, -1, &rangeStmt, nil) == SQLITE_OK {
    if sqlite3_step(rangeStmt) == SQLITE_ROW {
        let minMs = sqlite3_column_int64(rangeStmt, 0)
        let maxMs = sqlite3_column_int64(rangeStmt, 1)
        let minDate = Date(timeIntervalSince1970: Double(minMs) / 1000.0)
        let maxDate = Date(timeIntervalSince1970: Double(maxMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("    ✓ Earliest frame: \(formatter.string(from: minDate))")
        print("    ✓ Latest frame:   \(formatter.string(from: maxDate))")
    }
    sqlite3_finalize(rangeStmt)
} else {
    let errorMsg = String(cString: sqlite3_errmsg(db!))
    print("    ✗ Failed to get date range: \(errorMsg)")
}
print()

// Sample some frames
print("[9] Sampling 5 recent frames...")
var sampleStmt: OpaquePointer?
let sampleSQL = """
    SELECT
        f.id,
        f.createdAt,
        f.segmentId,
        f.videoId,
        f.videoFrameIndex,
        s.bundleID,
        s.windowName
    FROM frame f
    LEFT JOIN segment s ON f.segmentId = s.id
    ORDER BY f.createdAt DESC
    LIMIT 5
    """
if sqlite3_prepare_v2(db, sampleSQL, -1, &sampleStmt, nil) == SQLITE_OK {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    var count = 0
    while sqlite3_step(sampleStmt) == SQLITE_ROW {
        count += 1
        let frameId = sqlite3_column_int64(sampleStmt, 0)
        let createdAtMs = sqlite3_column_int64(sampleStmt, 1)
        let segmentId = sqlite3_column_int64(sampleStmt, 2)
        let videoId = sqlite3_column_type(sampleStmt, 3) != SQLITE_NULL ? sqlite3_column_int64(sampleStmt, 3) : -1
        let frameIndex = sqlite3_column_int(sampleStmt, 4)
        let bundleID = sqlite3_column_text(sampleStmt, 5).map { String(cString: $0) } ?? "NULL"
        let windowName = sqlite3_column_text(sampleStmt, 6).map { String(cString: $0) } ?? "NULL"

        let date = Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
        print("    Frame #\(count):")
        print("      ID: \(frameId)")
        print("      Timestamp: \(formatter.string(from: date))")
        print("      Segment: \(segmentId), Video: \(videoId), Index: \(frameIndex)")
        print("      App: \(bundleID)")
        print("      Window: \(windowName.prefix(50))...")
        print()
    }
    sqlite3_finalize(sampleStmt)
    if count == 0 {
        print("    ⚠ No frames found!")
    }
} else {
    let errorMsg = String(cString: sqlite3_errmsg(db!))
    print("    ✗ Failed to sample frames: \(errorMsg)")
}

// Count segments
print("[10] Counting segments...")
var segCountStmt: OpaquePointer?
let segCountSQL = "SELECT count(*) FROM segment"
if sqlite3_prepare_v2(db, segCountSQL, -1, &segCountStmt, nil) == SQLITE_OK {
    if sqlite3_step(segCountStmt) == SQLITE_ROW {
        let count = sqlite3_column_int64(segCountStmt, 0)
        print("    ✓ Total segments: \(count)")
    }
    sqlite3_finalize(segCountStmt)
}
print()

// Count videos
print("[11] Counting videos...")
var vidCountStmt: OpaquePointer?
let vidCountSQL = "SELECT count(*) FROM video"
if sqlite3_prepare_v2(db, vidCountSQL, -1, &vidCountStmt, nil) == SQLITE_OK {
    if sqlite3_step(vidCountStmt) == SQLITE_ROW {
        let count = sqlite3_column_int64(vidCountStmt, 0)
        print("    ✓ Total videos: \(count)")
    }
    sqlite3_finalize(vidCountStmt)
}
print()

// Close database
sqlite3_close(db)
print("=" * 60)
print("TEST COMPLETE - Database connection successful!")
print("=" * 60)

// Helper for string multiplication
extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}
