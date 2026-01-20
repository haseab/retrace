import XCTest
@testable import Database
import Shared
import SQLite3

/// Tests for AudioTranscriptionQueries (chunk-based architecture with word-level timestamps)
/// Tests the new chunk architecture vs old sentence-based architecture
/// Owner: DATABASE agent
final class AudioTranscriptionQueriesTests: XCTestCase {

    var db: OpaquePointer!
    var queries: AudioTranscriptionQueries!

    override func setUp() async throws {
        try await super.setUp()

        // Create in-memory database
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            XCTFail("Failed to open in-memory database")
            return
        }

        // Create schema
        try await V1_InitialSchema().migrate(db: db)

        // Create queries instance
        queries = AudioTranscriptionQueries(db: db)
    }

    override func tearDown() async throws {
        sqlite3_close(db)
        db = nil
        queries = nil
        try await super.tearDown()
    }

    // MARK: - Insert Tests

    func testInsertTranscription_WithoutWords() async throws {
        let now = Date()
        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_123",
            text: "Hello world, this is a test.",
            startTime: now,
            endTime: now.addingTimeInterval(3.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        XCTAssertGreaterThan(transcriptionID, 0, "Should return valid ID")

        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 1, "Should have 1 transcription")
    }

    func testInsertTranscription_WithWords() async throws {
        let now = Date()
        let words = [
            TranscriptionWord(word: "Hello", start: 0.0, end: 0.5, confidence: 0.98),
            TranscriptionWord(word: "world", start: 0.6, end: 1.2, confidence: 0.96),
            TranscriptionWord(word: "test", start: 2.0, end: 2.5, confidence: 0.94)
        ]

        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_123",
            text: "Hello world test",
            startTime: now,
            endTime: now.addingTimeInterval(3.0),
            source: .microphone,
            confidence: 0.95,
            words: words
        )

        XCTAssertGreaterThan(transcriptionID, 0)

        // Should have 1 transcription + 3 word entries = 4 total rows
        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 4, "Should have transcription + word rows")
    }

    func testInsertTranscription_NullSessionID() async throws {
        let now = Date()
        let transcriptionID = try await queries.insertTranscription(
            sessionID: nil,
            text: "Test without session",
            startTime: now,
            endTime: now.addingTimeInterval(2.0),
            source: .system,
            confidence: 0.90,
            words: []
        )

        XCTAssertGreaterThan(transcriptionID, 0)
    }

    func testInsertTranscription_NullConfidence() async throws {
        let now = Date()
        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_123",
            text: "Test without confidence",
            startTime: now,
            endTime: now.addingTimeInterval(2.0),
            source: .microphone,
            confidence: nil,
            words: []
        )

        XCTAssertGreaterThan(transcriptionID, 0)
    }

    func testInsertMultipleTranscriptions() async throws {
        let now = Date()

        let id1 = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "First transcription",
            startTime: now,
            endTime: now.addingTimeInterval(2.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        let id2 = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Second transcription",
            startTime: now.addingTimeInterval(2.0),
            endTime: now.addingTimeInterval(4.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        XCTAssertNotEqual(id1, id2, "Should have different IDs")

        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Query Tests

    func testGetTranscriptions_InTimeRange() async throws {
        let now = Date()

        // Insert 3 transcriptions at different times
        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "First",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Second",
            startTime: now.addingTimeInterval(10.0),
            endTime: now.addingTimeInterval(11.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Third",
            startTime: now.addingTimeInterval(20.0),
            endTime: now.addingTimeInterval(21.0),
            source: .microphone,
            confidence: 0.90,
            words: []
        )

        // Query middle range (should get only second transcription)
        let results = try await queries.getTranscriptions(
            from: now.addingTimeInterval(5.0),
            to: now.addingTimeInterval(15.0)
        )

        XCTAssertEqual(results.count, 1, "Should find 1 transcription in range")
        XCTAssertEqual(results.first?.text, "Second")
    }

    func testGetTranscriptions_FilterBySource() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Microphone audio",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "System audio",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .system,
            confidence: 0.92,
            words: []
        )

        // Query only microphone
        let micResults = try await queries.getTranscriptions(
            from: now.addingTimeInterval(-10.0),
            to: now.addingTimeInterval(10.0),
            source: .microphone
        )

        XCTAssertEqual(micResults.count, 1)
        XCTAssertEqual(micResults.first?.text, "Microphone audio")
        XCTAssertEqual(micResults.first?.source, .microphone)
    }

    func testGetTranscriptions_Limit() async throws {
        let now = Date()

        // Insert 5 transcriptions
        for i in 0..<5 {
            _ = try await queries.insertTranscription(
                sessionID: "session_1",
                text: "Transcription \(i)",
                startTime: now.addingTimeInterval(Double(i)),
                endTime: now.addingTimeInterval(Double(i) + 1.0),
                source: .microphone,
                confidence: 0.95,
                words: []
            )
        }

        // Query with limit of 3
        let results = try await queries.getTranscriptions(
            from: now.addingTimeInterval(-10.0),
            to: now.addingTimeInterval(100.0),
            limit: 3
        )

        XCTAssertEqual(results.count, 3, "Should respect limit")
    }

    func testGetTranscriptions_OrderedByStartTime() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Third",
            startTime: now.addingTimeInterval(20.0),
            endTime: now.addingTimeInterval(21.0),
            source: .microphone,
            confidence: 0.90,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "First",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Second",
            startTime: now.addingTimeInterval(10.0),
            endTime: now.addingTimeInterval(11.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        let results = try await queries.getTranscriptions(
            from: now.addingTimeInterval(-10.0),
            to: now.addingTimeInterval(100.0)
        )

        // Should be in descending order (newest first)
        XCTAssertEqual(results[0].text, "Third")
        XCTAssertEqual(results[1].text, "Second")
        XCTAssertEqual(results[2].text, "First")
    }

    func testGetTranscriptions_EmptyRange() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Test",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        // Query a time range that doesn't include the transcription
        let results = try await queries.getTranscriptions(
            from: now.addingTimeInterval(100.0),
            to: now.addingTimeInterval(200.0)
        )

        XCTAssertEqual(results.count, 0, "Should return empty array")
    }

    // MARK: - Search Tests

    func testSearchTranscriptions_BasicSearch() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "The quick brown fox jumps over the lazy dog",
            startTime: now,
            endTime: now.addingTimeInterval(5.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Another sentence without that animal",
            startTime: now.addingTimeInterval(10.0),
            endTime: now.addingTimeInterval(12.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        let results = try await queries.searchTranscriptions(query: "fox")

        XCTAssertEqual(results.count, 1, "Should find 1 match")
        XCTAssertTrue(results.first?.text.contains("fox") ?? false)
    }

    func testSearchTranscriptions_CaseInsensitive() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Hello World",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        // Search with different case
        let results = try await queries.searchTranscriptions(query: "world")

        XCTAssertEqual(results.count, 1, "Should be case-insensitive")
    }

    func testSearchTranscriptions_WithTimeRange() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Old keyword",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "New keyword",
            startTime: now.addingTimeInterval(100.0),
            endTime: now.addingTimeInterval(101.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        // Search for "keyword" but only in recent time
        let results = try await queries.searchTranscriptions(
            query: "keyword",
            from: now.addingTimeInterval(50.0)
        )

        XCTAssertEqual(results.count, 1, "Should find only recent match")
        XCTAssertTrue(results.first?.text.contains("New") ?? false)
    }

    // MARK: - Session Tests

    func testGetTranscriptions_ForSession() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_A",
            text: "Session A transcription 1",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_A",
            text: "Session A transcription 2",
            startTime: now.addingTimeInterval(2.0),
            endTime: now.addingTimeInterval(3.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_B",
            text: "Session B transcription",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.90,
            words: []
        )

        let sessionAResults = try await queries.getTranscriptions(forSession: "session_A")

        XCTAssertEqual(sessionAResults.count, 2, "Should find 2 transcriptions for session A")
        XCTAssertTrue(sessionAResults.allSatisfy { $0.sessionID == "session_A" })
    }

    func testGetTranscriptions_ForSession_OrderedByTime() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Second",
            startTime: now.addingTimeInterval(10.0),
            endTime: now.addingTimeInterval(11.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "First",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        let results = try await queries.getTranscriptions(forSession: "session_1")

        // Should be in ascending order (chronological)
        XCTAssertEqual(results[0].text, "First")
        XCTAssertEqual(results[1].text, "Second")
    }

    // MARK: - Delete Tests

    func testDeleteTranscriptions_OlderThan() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Old transcription",
            startTime: now.addingTimeInterval(-100.0),
            endTime: now.addingTimeInterval(-99.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Recent transcription",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.92,
            words: []
        )

        let deletedCount = try await queries.deleteTranscriptions(
            olderThan: now.addingTimeInterval(-50.0)
        )

        XCTAssertEqual(deletedCount, 1, "Should delete 1 old transcription")

        let remainingCount = try await queries.getTranscriptionCount()
        XCTAssertEqual(remainingCount, 1, "Should have 1 remaining transcription")
    }

    func testDeleteTranscriptions_NoMatches() async throws {
        let now = Date()

        _ = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "Recent transcription",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.95,
            words: []
        )

        let deletedCount = try await queries.deleteTranscriptions(
            olderThan: now.addingTimeInterval(-100.0)
        )

        XCTAssertEqual(deletedCount, 0, "Should delete nothing")
    }

    // MARK: - Count Tests

    func testGetTranscriptionCount_Empty() async throws {
        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 0, "Should be 0 for empty database")
    }

    func testGetTranscriptionCount_WithData() async throws {
        let now = Date()

        for i in 0..<5 {
            _ = try await queries.insertTranscription(
                sessionID: "session_1",
                text: "Transcription \(i)",
                startTime: now.addingTimeInterval(Double(i)),
                endTime: now.addingTimeInterval(Double(i) + 1.0),
                source: .microphone,
                confidence: 0.95,
                words: []
            )
        }

        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 5)
    }

    // MARK: - Model Tests

    func testAudioTranscription_ModelProperties() async throws {
        let now = Date()
        let created = Date()

        let transcription = AudioTranscription(
            id: 123,
            sessionID: "session_abc",
            text: "Test transcription",
            startTime: now,
            endTime: now.addingTimeInterval(5.0),
            source: .microphone,
            confidence: 0.92,
            createdAt: created
        )

        XCTAssertEqual(transcription.id, 123)
        XCTAssertEqual(transcription.sessionID, "session_abc")
        XCTAssertEqual(transcription.text, "Test transcription")
        XCTAssertEqual(transcription.startTime, now)
        XCTAssertEqual(transcription.endTime, now.addingTimeInterval(5.0))
        XCTAssertEqual(transcription.source, .microphone)
        XCTAssertEqual(transcription.confidence, 0.92)
        XCTAssertEqual(transcription.createdAt, created)
    }

    // MARK: - Edge Cases

    func testInsertTranscription_EmptyText() async throws {
        let now = Date()
        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_1",
            text: "",
            startTime: now,
            endTime: now.addingTimeInterval(1.0),
            source: .microphone,
            confidence: 0.0,
            words: []
        )

        XCTAssertGreaterThan(transcriptionID, 0, "Should handle empty text")
    }

    func testInsertTranscription_VeryLongText() async throws {
        let now = Date()
        let longText = String(repeating: "word ", count: 1000)

        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_1",
            text: longText,
            startTime: now,
            endTime: now.addingTimeInterval(60.0),
            source: .microphone,
            confidence: 0.85,
            words: []
        )

        XCTAssertGreaterThan(transcriptionID, 0, "Should handle long text")
    }

    func testInsertTranscription_ManyWords() async throws {
        let now = Date()
        var words: [TranscriptionWord] = []

        // Create 100 words
        for i in 0..<100 {
            words.append(TranscriptionWord(
                word: "word\(i)",
                start: Double(i) * 0.5,
                end: Double(i) * 0.5 + 0.4,
                confidence: 0.90
            ))
        }

        let transcriptionID = try await queries.insertTranscription(
            sessionID: "session_1",
            text: words.map { $0.word }.joined(separator: " "),
            startTime: now,
            endTime: now.addingTimeInterval(50.0),
            source: .microphone,
            confidence: 0.90,
            words: words
        )

        XCTAssertGreaterThan(transcriptionID, 0)

        // Should have 1 transcription + 100 words = 101 total
        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 101, "Should insert all word rows")
    }
}
