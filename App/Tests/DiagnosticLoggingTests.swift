import Foundation
import XCTest
@testable import Shared

final class DiagnosticLoggingTests: XCTestCase {
    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-log-" + UUID().uuidString).appendingPathComponent("retrace.log")
    }

    func testEnqueueDoesNotWaitForWriterAndBufferIsBounded() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "blocked-test-log-writer")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let writer = LogFile(fileURL: url, queue: queue, maximumBufferedBytes: 4096, emitToSystemLog: false)
        for i in 0..<1000 {
            writer.append(LogEntry(level: .info, message: "routine \(i)", category: .app))
        }
        writer.append(LogEntry(level: .error, message: "important failure", category: .storage))
        let state = writer.bufferState
        XCTAssertLessThanOrEqual(state.bytes, 4096)
        XCTAssertGreaterThan(state.dropped, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        gate.signal()
        await writer.flush()
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("important failure"))
        XCTAssertTrue(content.contains("Dropped"))
    }

    func testAsyncFlushIncludesPendingMessagesAndRedactsContent() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LogFile(fileURL: url, flushInterval: 60, emitToSystemLog: false)
        let secret = "PRIVATE_LOG_CANARY"
        let message: PrivacyLogMessage = "event count=\(42) content=\(secret)"
        writer.append(LogEntry(level: .info, message: message.text, category: .capture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await writer.flush()
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("count=42"))
        XCTAssertFalse(content.contains(secret))
        XCTAssertTrue(content.split(separator: "\n").allSatisfy { Log.isPrivacySafeLogEntry(String($0)) })
    }

    func testConcurrentProducersRetainAllMessagesBelowBudget() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LogFile(fileURL: url, flushInterval: 60, emitToSystemLog: false)
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    for item in 0..<25 {
                        writer.append(LogEntry(level: .info, message: "producer=\(producer) item=\(item)", category: .app))
                    }
                }
            }
        }
        await writer.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertEqual(Set(lines.map { String($0.split(separator: "-").last!) }).count, 200)
    }

    func testRotationAndLegacyRemoval() async throws {
        let url = temporaryLog()
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy private content".utf8).write(to: url)
        try Data("legacy private content".utf8).write(to: old)
        let writer = LogFile(fileURL: url, maximumFileBytes: 512, flushInterval: 60, emitToSystemLog: false)
        for i in 0..<20 {
            writer.append(LogEntry(level: .info, message: "retained event \(i)", category: .app))
            await writer.flush()
        }
        for file in [url, old] {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 512)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("legacy private content"))
        }
    }

    func testRoutineEventsAreSummarizedAndFlushedForExport() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LogFile(fileURL: url, flushInterval: 60, emitToSystemLog: false)
        for _ in 0..<30 { writer.recordRoutine(.ocrProcessed, count: 1, durationMs: 200) }
        for _ in 0..<10 { writer.recordRoutine(.captureDeduplicated, count: 1, durationMs: nil) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let logs = await writer.readLastLines(count: 10)
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs.contains { $0.contains("OCR processed: events=30 units=30 averageMs=200.0") })
        XCTAssertTrue(logs.contains { $0.contains("Capture deduplicated: events=10") })
        await writer.flush()
        let repeatedRead = await writer.readLastLines(count: 10)
        XCTAssertEqual(repeatedRead.count, 2)
    }

    func testAutomaticTimerFlushesWithoutAnExport() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LogFile(fileURL: url, flushInterval: 0.02, routineInterval: 0.02, emitToSystemLog: false)
        writer.append(LogEntry(level: .info, message: "timer event", category: .app))
        writer.recordRoutine(.ocrProcessed, count: 1, durationMs: 100)
        // Observe real background writes, without calling flush/read (which would force a drain).
        var content = ""
        for _ in 0..<200 {
            content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if content.contains("timer event") && content.contains("OCR processed") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(content.contains("timer event"))
        XCTAssertTrue(content.contains("OCR processed"))
    }

    func testErrorTailIsNotHiddenByRoutineMessages() async throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LogFile(fileURL: url, flushInterval: 60, emitToSystemLog: false)
        writer.append(LogEntry(level: .warning, message: "earlier failure", category: .storage))
        for i in 0..<300 {
            writer.append(LogEntry(level: .info, message: "routine event \(i)", category: .app))
        }
        let errors = await writer.readLastLines(count: 10, errorsOnly: true)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("earlier failure"))
    }

    func testReleaseDebugDoesNotEvaluateMessage() async throws {
        #if !DEBUG
        var evaluations = 0
        func expensiveMessage() -> PrivacyLogMessage {
            evaluations += 1
            return "should not be evaluated"
        }
        Log.debug(expensiveMessage())
        Log.verbose(expensiveMessage())
        XCTAssertEqual(evaluations, 0)
        #endif
    }
}
