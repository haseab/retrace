import Foundation
import Shared
import XCTest
@testable import Capture

final class CapturePerformanceDiagnosticsTests: XCTestCase {
    func testProductionLogSinkRetainsNumericSummaryAndProcessFields() async throws {
        var diagnostics = CapturePerformanceDiagnostics(startedAt: 0)
        var sample = CapturePerformanceSample()
        sample.record(.total, milliseconds: 42)
        sample.increment(.completed)
        _ = diagnostics.record(sample, at: 1)
        let reports = diagnostics.flush(at: 60)
        diagnostics.emit(reports)
        await Log.flush()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: Log.logFilePath))
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > 65536 ? end - 65536 : 0)
        let text = String(decoding: try XCTUnwrap(handle.readToEnd()), as: UTF8.self)
        let summary = try XCTUnwrap(text.components(separatedBy: "\n").last { $0.contains("[CapturePerf] summary") })
        let process = try XCTUnwrap(text.components(separatedBy: "\n").last { $0.contains("[CapturePerf] process") })
        XCTAssertTrue(Log.isPrivacySafeLogEntry(summary))
        XCTAssertTrue(summary.contains("total_p50_ms=42"), summary)
        XCTAssertTrue(process.contains("cpu_one_core_pct="), process)
        XCTAssertTrue(process.contains("rss_mib="), process)
        XCTAssertFalse(process.contains("[private]"), process)
    }

    func testFastFramesAreSilentUntilSummaryAndSamplesStayBounded() {
        var diagnostics = CapturePerformanceDiagnostics(startedAt: 0)
        for index in 0..<1000 {
            var sample = CapturePerformanceSample()
            sample.record(.total, milliseconds: Double(index % 10))
            XCTAssertTrue(diagnostics.record(sample, at: Double(index) / 100).isEmpty)
        }
        let reports = diagnostics.flush(at: 60)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.frames, 1000)
        XCTAssertEqual(reports.first?.timings[.total]?.sampleCount, 256)
        XCTAssertEqual(reports.first?.timings[.total]?.p95Ms, 9)
        XCTAssertTrue(diagnostics.flush(at: 61).isEmpty, "Flushing must drain, not repeat old frames")
    }

    func testPersistentSlownessEmitsImmediatelyThenAtMostEveryThirtySeconds() {
        var diagnostics = CapturePerformanceDiagnostics(startedAt: 0)
        var sample = CapturePerformanceSample()
        sample.record(.total, milliseconds: 900)
        XCTAssertEqual(diagnostics.record(sample, at: 1).filter(\.isSlow).count, 1)
        for second in 2...30 {
            XCTAssertTrue(diagnostics.record(sample, at: Double(second)).isEmpty)
        }
        let repeated = diagnostics.record(sample, at: 31)
        XCTAssertEqual(repeated.filter(\.isSlow).count, 1)
        XCTAssertEqual(repeated.first?.suppressedSlowFrames, 29)
        let summary = diagnostics.record(sample, at: 60)
        XCTAssertEqual(summary.filter { !$0.isSlow }.count, 1)
    }

    func testMetadataSpikeIsReportedEvenWhenFrameTotalIsBelowThreshold() {
        var diagnostics = CapturePerformanceDiagnostics(startedAt: 0)
        var sample = CapturePerformanceSample()
        sample.record(.total, milliseconds: 300)
        sample.record(.browserURL, milliseconds: 200)
        sample.increment(.urlLookups)
        sample.increment(.urlUnavailable)
        let reports = diagnostics.record(sample, at: 2)
        XCTAssertEqual(reports.count, 1)
        let text = reports.flatMap(\.messages).map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("[CapturePerf] slow"))
        XCTAssertTrue(text.contains("url_ms=200"), text)
        XCTAssertTrue(text.contains("url_calls=1"), text)
        XCTAssertFalse(text.contains("[private]"), "Static labels and numeric fields must survive production privacy logging")
    }

    func testSummaryPreservesOutcomeCountsAndIgnoresInvalidDurations() {
        var diagnostics = CapturePerformanceDiagnostics(startedAt: 0)
        var sample = CapturePerformanceSample()
        sample.record(.faceDetection, milliseconds: .nan)
        sample.record(.faceDetection, milliseconds: -1)
        sample.increment(.consentBypassed, by: 2)
        sample.increment(.callUnknownIncomplete)
        sample.increment(.dropped)
        _ = diagnostics.record(sample, at: 1)
        let report = diagnostics.flush(at: 60).first
        XCTAssertNil(report?.timings[.faceDetection])
        let text = report?.messages.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertTrue(text.contains("bypassed=2"), text)
        XCTAssertTrue(text.contains("unknown_incomplete=1"), text)
        XCTAssertTrue(text.contains("dropped=1"), text)
        XCTAssertFalse(text.contains("[private]"))
    }
}
