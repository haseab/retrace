import XCTest
@testable import Retrace

final class CrashReportSupportTests: XCTestCase {
    func testLoadRecentCrashReportReturnsNewestDiagnosticReportAcrossSources() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        _ = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: emergencyDirectoryURL
        )
        _ = try createCrashReport(
            named: "retrace-emergency-hang_detected-2026-03-09_080000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_079_200),
            in: emergencyDirectoryURL
        )
        let latestReport = try createCrashReport(
            named: "Retrace-2026-03-09-121500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_095_700),
            in: diagnosticDirectoryURL
        )
        _ = try createCrashReport(
            named: "OtherApp-2026-03-09-130000.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_098_000),
            in: diagnosticDirectoryURL
        )

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_100_000)
        )

        XCTAssertEqual(result?.source, .macOSDiagnosticReport)
        XCTAssertEqual(result?.fileName, latestReport.lastPathComponent)
    }

    func testLoadRecentCrashReportSkipsAcknowledgedLatestDiagnosticReport() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        let fallbackReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: emergencyDirectoryURL
        )
        let acknowledgedReport = try createCrashReport(
            named: "Retrace-2026-03-09-121500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: diagnosticDirectoryURL
        )

        let acknowledgedIdentifier = DashboardCrashReportSummary(
            source: .macOSDiagnosticReport,
            fileName: acknowledgedReport.lastPathComponent,
            fileURL: acknowledgedReport,
            capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
        ).acknowledgmentIdentifier

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedReportIdentifiers: [acknowledgedIdentifier]
        )

        XCTAssertEqual(result?.source, .watchdogAutoQuit)
        XCTAssertEqual(result?.fileName, fallbackReport.lastPathComponent)
    }

    func testLoadRecentCrashReportAcknowledgedNewestHidesOlderReports() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        _ = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_100000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_086_400),
            in: emergencyDirectoryURL
        )
        let newestReport = try createCrashReport(
            named: "Retrace-2026-03-09-121500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: diagnosticDirectoryURL
        )

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedBeforeDate: Date(timeIntervalSince1970: 1_773_090_000)
        )

        XCTAssertNil(result, newestReport.lastPathComponent)
    }

    func testLoadRecentCrashReportAcknowledgingSecondNewestAlsoHidesOlderReports() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        let newestReport = try createCrashReport(
            named: "Retrace-2026-03-09-131500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_093_600),
            in: diagnosticDirectoryURL
        )
        let secondNewestReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: emergencyDirectoryURL
        )
        _ = try createCrashReport(
            named: "Retrace-2026-03-09-111500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_086_400),
            in: diagnosticDirectoryURL
        )

        let newestAcknowledgedIdentifier = DashboardCrashReportSummary(
            source: .macOSDiagnosticReport,
            fileName: newestReport.lastPathComponent,
            fileURL: newestReport,
            capturedAt: Date(timeIntervalSince1970: 1_773_093_600)
        ).acknowledgmentIdentifier

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_097_200),
            acknowledgedReportIdentifiers: [newestAcknowledgedIdentifier],
            acknowledgedBeforeDate: Date(timeIntervalSince1970: 1_773_090_000)
        )

        XCTAssertNil(result, secondNewestReport.lastPathComponent)
    }

    func testLoadRecentCrashReportIgnoresUnsupportedDiagnosticReportExtensions() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        let emergencyReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_100000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_086_400),
            in: emergencyDirectoryURL
        )
        _ = try createCrashReport(
            named: "Retrace_2026-03-09-121500_hasbook-bro.diag",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: diagnosticDirectoryURL
        )

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(result?.source, .watchdogAutoQuit)
        XCTAssertEqual(result?.fileName, emergencyReport.lastPathComponent)
    }

    func testLoadRecentCrashReportSkipsEveryAcknowledgedRecentReport() throws {
        let fileManager = FileManager.default
        let (emergencyDirectoryURL, diagnosticDirectoryURL, cleanupURL) = try makeReportDirectories()
        defer { try? fileManager.removeItem(at: cleanupURL) }

        let emergencyReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_100000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_086_400),
            in: emergencyDirectoryURL
        )
        let diagnosticReport = try createCrashReport(
            named: "Retrace-2026-03-09-121500.ips",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: diagnosticDirectoryURL
        )

        let acknowledgedIdentifiers: Set<String> = [
            DashboardCrashReportSummary(
                source: .watchdogAutoQuit,
                fileName: emergencyReport.lastPathComponent,
                fileURL: emergencyReport,
                capturedAt: Date(timeIntervalSince1970: 1_773_086_400)
            ).acknowledgmentIdentifier,
            DashboardCrashReportSummary(
                source: .macOSDiagnosticReport,
                fileName: diagnosticReport.lastPathComponent,
                fileURL: diagnosticReport,
                capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
            ).acknowledgmentIdentifier
        ]

        let result = DashboardViewModel.loadRecentCrashReport(
            fileManager: fileManager,
            crashReportDirectory: emergencyDirectoryURL.path,
            diagnosticReportDirectories: [diagnosticDirectoryURL.path],
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedReportIdentifiers: acknowledgedIdentifiers
        )

        XCTAssertNil(result)
    }

    func testCrashLaunchContextPrefillsBugReportAndEmailFocusForWatchdogAutoQuit() {
        let report = DashboardCrashReportSummary(
            source: .watchdogAutoQuit,
            fileName: "retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt",
            fileURL: URL(fileURLWithPath: "/tmp/retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt"),
            capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
        )

        let context = DashboardViewModel.makeCrashFeedbackLaunchContext(
            for: report,
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(context.source, .crashBanner)
        XCTAssertEqual(context.feedbackType, .bug)
        XCTAssertEqual(context.preferredFocusField, .email)
        XCTAssertTrue(context.prefilledDescription?.contains("Retrace Auto Quit Crash Logging") == true)
        XCTAssertTrue(context.prefilledDescription?.contains("Enter any other relevant context here:") == true)
    }

    func testCrashLaunchContextPrefillsDiagnosticCrashDescription() {
        let report = DashboardCrashReportSummary(
            source: .macOSDiagnosticReport,
            fileName: "Retrace-2026-03-09-121500.ips",
            fileURL: URL(fileURLWithPath: "/tmp/Retrace-2026-03-09-121500.ips"),
            capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
        )

        let context = DashboardViewModel.makeCrashFeedbackLaunchContext(for: report)

        XCTAssertEqual(context.source, .crashBanner)
        XCTAssertTrue(context.prefilledDescription?.contains("Retrace macOS Crash Report") == true)
    }

    func testLoadRecentWALFailureCrashReturnsNewestReport() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        _ = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: directoryURL
        )
        let latestReport = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWALFailureCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(result?.fileName, latestReport.lastPathComponent)
    }

    func testLoadRecentWALFailureCrashSkipsAcknowledgedReport() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let olderReport = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: directoryURL
        )
        let newestReport = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWALFailureCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedFileNames: [newestReport.lastPathComponent]
        )

        XCTAssertEqual(result?.fileName, olderReport.lastPathComponent)
    }

    func testLoadRecentWALFailureCrashAcknowledgedNewestAlsoHidesOlderReports() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        _ = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: directoryURL
        )
        _ = try createCrashReport(
            named: "retrace-emergency-wal_unavailable-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWALFailureCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedBeforeDate: Date(timeIntervalSince1970: 1_773_090_000)
        )

        XCTAssertNil(result)
    }

    func testWALFailureLaunchContextPrefillsBugReportAndEmailFocus() {
        let report = WALFailureCrashReportSummary(
            fileName: "retrace-emergency-wal_unavailable-2026-03-09_110000.txt",
            fileURL: URL(fileURLWithPath: "/tmp/retrace-emergency-wal_unavailable-2026-03-09_110000.txt"),
            capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
        )

        let context = DashboardViewModel.makeWALFailureFeedbackLaunchContext(
            for: report,
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(context.source, .walFailureCrashBanner)
        XCTAssertEqual(context.feedbackType, .bug)
        XCTAssertEqual(context.preferredFocusField, .email)
        XCTAssertTrue(context.prefilledDescription?.contains("Retrace Recovery Failure") == true)
        XCTAssertTrue(context.prefilledDescription?.contains("couldn't complete recovery during startup") == true)
    }

    func testStorageHealthBannerMessageWarnsBeforeStop() {
        let state = StorageHealthBannerState(
            severity: .warning,
            availableGB: 1.25,
            shouldStop: false
        )

        XCTAssertTrue(state.messageText.contains("1.25 GB free"))
        XCTAssertTrue(state.messageText.contains("running low"))
    }

    func testStorageHealthBannerMessageExplainsForcedStop() {
        let state = StorageHealthBannerState(
            severity: .critical,
            availableGB: 0.42,
            shouldStop: true
        )

        XCTAssertTrue(state.messageText.contains("Recording stopped"))
        XCTAssertTrue(state.messageText.contains("0.42 GB free"))
    }

    private func makeReportDirectories() throws -> (URL, URL, URL) {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let emergencyDirectoryURL = baseURL.appendingPathComponent("emergency", isDirectory: true)
        let diagnosticDirectoryURL = baseURL.appendingPathComponent("diagnostic", isDirectory: true)
        try fileManager.createDirectory(at: emergencyDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticDirectoryURL, withIntermediateDirectories: true)
        return (emergencyDirectoryURL, diagnosticDirectoryURL, baseURL)
    }

    private func createCrashReport(
        named fileName: String,
        modifiedAt date: Date,
        in directoryURL: URL
    ) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(fileName)
        try "report".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        return fileURL
    }
}
