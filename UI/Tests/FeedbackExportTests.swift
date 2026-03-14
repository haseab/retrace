import XCTest
@testable import Retrace

final class FeedbackExportTests: XCTestCase {
    @MainActor
    func testCanExportWithoutDescriptionOrValidEmail() {
        let viewModel = FeedbackViewModel()
        viewModel.email = "not-an-email"
        viewModel.description = ""

        XCTAssertTrue(viewModel.canExport)
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testExportTextIncludesReadableSectionsAndJSONPayload() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_773_489_600)
        let diagnostics = DiagnosticInfo(
            appVersion: "1.2.3",
            buildNumber: "45",
            macOSVersion: "14.4",
            deviceModel: "Mac14,15",
            totalDiskSpace: "1 TB",
            freeDiskSpace: "512 GB",
            databaseStats: DiagnosticInfo.DatabaseStats(
                sessionCount: 3,
                frameCount: 42,
                segmentCount: 7,
                databaseSizeMB: 128.5
            ),
            settingsSnapshot: [
                "captureIntervalSeconds": "2",
                "isRecordingEnabled": "true"
            ],
            recentErrors: ["[ERROR] Sample error"],
            recentLogs: [
                "2026-03-13T11:58:00Z [FeedbackMemoryProfile] Retrace current=512MB count=1",
                "2026-03-13T11:59:00Z [INFO] Sample log line"
            ],
            displayInfo: DiagnosticInfo.DisplayInfo(
                count: 1,
                displays: [
                    DiagnosticInfo.DisplayInfo.Display(
                        index: 0,
                        resolution: "3024x1964",
                        backingScaleFactor: "2.0",
                        colorSpace: "P3",
                        refreshRate: "120Hz",
                        isRetina: true,
                        frame: "(0,0,3024,1964)"
                    )
                ],
                mainDisplayIndex: 0
            ),
            processInfo: DiagnosticInfo.ProcessInfo(
                totalRunning: 12,
                eventMonitoringApps: 1,
                windowManagementApps: 0,
                securityApps: 1,
                hasJamf: false,
                hasKandji: false,
                axuiServerCPU: 2.3,
                windowServerCPU: 8.1
            ),
            accessibilityInfo: DiagnosticInfo.AccessibilityInfo(
                voiceOverEnabled: false,
                switchControlEnabled: false,
                reduceMotionEnabled: true,
                increaseContrastEnabled: false,
                reduceTransparencyEnabled: false,
                differentiateWithoutColorEnabled: false,
                displayHasInvertedColors: false
            ),
            performanceInfo: DiagnosticInfo.PerformanceInfo(
                cpuUsagePercent: 12.5,
                memoryUsedGB: 8.0,
                memoryTotalGB: 18.0,
                memoryPressure: "normal",
                swapUsedGB: 0.0,
                thermalState: "nominal",
                processorCount: 10,
                isLowPowerModeEnabled: false,
                powerSource: "AC",
                batteryLevel: 82
            ),
            emergencyCrashReports: ["Sample emergency report"],
            timestamp: Date(timeIntervalSince1970: 1_773_486_000)
        )

        let submission = FeedbackSubmission(
            type: .bug,
            email: "user@example.com",
            description: "Steps to reproduce\n1. Open Help\n2. Block network",
            diagnostics: diagnostics,
            includeScreenshot: true,
            screenshotData: Data([0x89, 0x50])
        )

        let text = submission.exportText(
            generatedAt: generatedAt,
            launchSource: .crashBanner,
            screenshotFileName: "report-screenshot.png"
        )

        XCTAssertTrue(text.contains("RETRACE FEEDBACK EXPORT (USER REPORT)"))
        XCTAssertTrue(text.contains("feedback_type: Bug Report"))
        XCTAssertTrue(text.contains("launch_source: crashBanner"))
        XCTAssertTrue(text.contains("screenshot_file: report-screenshot.png"))
        XCTAssertTrue(text.contains("=== FEEDBACK ==="))
        XCTAssertTrue(text.contains("Description:\nSteps to reproduce"))
        XCTAssertTrue(text.contains("=== DIAGNOSTICS ==="))
        XCTAssertTrue(text.contains("--- FULL LOGS (last hour) ---"))
        XCTAssertTrue(text.contains("=== BEGIN SUBMISSION JSON ==="))
        XCTAssertTrue(text.contains("=== END SUBMISSION JSON ==="))

        let payload = try exportPayload(from: text)
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["launchSource"] as? String, "crashBanner")
        XCTAssertEqual(metadata["screenshotFileName"] as? String, "report-screenshot.png")
        XCTAssertEqual(metadata["screenshotByteCount"] as? Int, 2)

        let report = try XCTUnwrap(payload["report"] as? [String: Any])
        XCTAssertEqual(report["type"] as? String, "Bug Report")
        XCTAssertEqual(report["email"] as? String, "user@example.com")
        XCTAssertEqual(report["includeScreenshot"] as? Bool, true)
    }

    func testSuggestedBaseNameSlugifiesFeedbackType() {
        let baseName = FeedbackSubmission.suggestedBaseName(
            forType: "Feature Request",
            timestamp: Date(timeIntervalSince1970: 1_773_489_600)
        )

        XCTAssertEqual(baseName, "retrace-feedback-feature-request-2026-03-14-120000")
    }

    private func exportPayload(from text: String) throws -> [String: Any] {
        let startMarker = "=== BEGIN SUBMISSION JSON ===\n"
        let endMarker = "\n=== END SUBMISSION JSON ==="

        guard let startRange = text.range(of: startMarker),
              let endRange = text.range(of: endMarker) else {
            XCTFail("Expected JSON markers in export text")
            return [:]
        }

        let jsonString = String(text[startRange.upperBound..<endRange.lowerBound])
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }
}
