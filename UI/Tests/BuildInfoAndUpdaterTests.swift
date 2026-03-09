import XCTest
import Shared
import App
@testable import Retrace

final class BuildInfoFormattingTests: XCTestCase {
    func testDisplayVersionForReleaseBuild() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: false, gitCommit: "abc1234"),
            "v1.2.3"
        )
    }

    func testDisplayVersionForDevBuildIncludesCommitWhenKnown() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: true, gitCommit: "abc1234"),
            "v1.2.3-dev · abc1234"
        )
    }

    func testDisplayVersionForDevBuildOmitsUnknownCommit() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: true, gitCommit: "unknown"),
            "v1.2.3-dev"
        )
    }

    func testFullVersionForReleaseBuild() {
        XCTAssertEqual(
            BuildInfo.makeFullVersion(
                version: "1.2.3",
                buildNumber: "99",
                isDevBuild: false,
                gitCommit: "abc1234",
                gitBranch: "feature/xyz"
            ),
            "1.2.3 (99)"
        )
    }

    func testFullVersionForDevBuildIncludesCommitAndBranchWhenKnown() {
        XCTAssertEqual(
            BuildInfo.makeFullVersion(
                version: "1.2.3",
                buildNumber: "99",
                isDevBuild: true,
                gitCommit: "abc1234",
                gitBranch: "feature/xyz"
            ),
            "1.2.3-dev · abc1234 (feature/xyz)"
        )
    }

    func testDisplayBranchShownOnlyForDevWithKnownBranch() {
        XCTAssertEqual(
            BuildInfo.makeDisplayBranch(isDevBuild: true, gitBranch: "feature/xyz"),
            "feature/xyz"
        )
        XCTAssertNil(BuildInfo.makeDisplayBranch(isDevBuild: false, gitBranch: "feature/xyz"))
        XCTAssertNil(BuildInfo.makeDisplayBranch(isDevBuild: true, gitBranch: "unknown"))
    }

    func testCommitURLRequiresCommitAndFork() {
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "haseab/retrace")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "git@github.com:haseab/retrace")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "https://github.com/haseab/retrace.git")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertNil(BuildInfo.makeCommitURL(gitCommitFull: "unknown", forkName: "haseab/retrace"))
        XCTAssertNil(BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: ""))
    }
}

final class UpdaterManagerVersionResolutionTests: XCTestCase {
    func testResolveBundleVersionValueUsesConcreteBundleValue() {
        XCTAssertEqual(
            UpdaterManager.resolveBundleVersionValue("1.2.3", fallback: "0.0.0"),
            "1.2.3"
        )
    }

    func testResolveBundleVersionValueFallsBackForPlaceholder() {
        XCTAssertEqual(
            UpdaterManager.resolveBundleVersionValue("$(MARKETING_VERSION)", fallback: "0.0.0"),
            "0.0.0"
        )
    }

    func testResolveBundleVersionValueFallsBackForNilOrEmpty() {
        XCTAssertEqual(UpdaterManager.resolveBundleVersionValue(nil, fallback: "0.0.0"), "0.0.0")
        XCTAssertEqual(UpdaterManager.resolveBundleVersionValue("", fallback: "0.0.0"), "0.0.0")
    }
}
final class WatchdogCrashSupportTests: XCTestCase {
    func testLoadRecentWatchdogCrashReturnsNewestWatchdogReport() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let olderReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: directoryURL
        )
        _ = olderReport
        _ = try createCrashReport(
            named: "retrace-emergency-hang_detected-2026-03-09_080000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_079_200),
            in: directoryURL
        )
        let latestReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWatchdogCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(result?.fileName, latestReport.lastPathComponent)
    }

    func testLoadRecentWatchdogCrashSkipsAcknowledgedLatestReport() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fallbackReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-08_120000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_021_600),
            in: directoryURL
        )
        let acknowledgedReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWatchdogCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedFileNames: [acknowledgedReport.lastPathComponent]
        )

        XCTAssertEqual(result?.fileName, fallbackReport.lastPathComponent)
    }

    func testLoadRecentWatchdogCrashSkipsEveryAcknowledgedRecentReport() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let firstReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_100000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_086_400),
            in: directoryURL
        )
        let secondReport = try createCrashReport(
            named: "retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_773_090_000),
            in: directoryURL
        )

        let result = DashboardViewModel.loadRecentWatchdogCrash(
            fileManager: fileManager,
            crashReportDirectory: directoryURL.path,
            now: Date(timeIntervalSince1970: 1_773_093_600),
            acknowledgedFileNames: [
                firstReport.lastPathComponent,
                secondReport.lastPathComponent
            ]
        )

        XCTAssertNil(result)
    }

    func testWatchdogCrashLaunchContextPrefillsBugReportAndEmailFocus() {
        let report = WatchdogCrashReportSummary(
            fileName: "retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt",
            fileURL: URL(fileURLWithPath: "/tmp/retrace-emergency-watchdog_auto_quit-2026-03-09_110000.txt"),
            capturedAt: Date(timeIntervalSince1970: 1_773_090_000)
        )

        let context = DashboardViewModel.makeWatchdogCrashFeedbackLaunchContext(
            for: report,
            now: Date(timeIntervalSince1970: 1_773_093_600)
        )

        XCTAssertEqual(context.source, .watchdogCrashBanner)
        XCTAssertEqual(context.feedbackType, .bug)
        XCTAssertEqual(context.preferredFocusField, .email)
        XCTAssertTrue(context.prefilledDescription?.contains("Retrace Auto Quit Crash Logging") == true)
        XCTAssertTrue(context.prefilledDescription?.contains("Enter any other relevant context here:") == true)
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

final class HyperlinkMappingTests: XCTestCase {
    func testHyperlinkMatchesFromStoredRowsUsesPrimaryKeyNodeIDs() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 42
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary key match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Primary key match")
    }

    func testHyperlinkMatchesFromStoredRowsUsesResolvedNodeGeometry() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 42
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary key match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].x, 0.1)
        XCTAssertEqual(matches[0].y, 0.2)
        XCTAssertEqual(matches[0].width, 0.3)
        XCTAssertEqual(matches[0].height, 0.05)
    }

    func testHyperlinkMatchesFromStoredRowsFallsBackToLegacyNodeOrderRows() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 7
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Legacy nodeOrder match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Legacy nodeOrder match")
    }

    func testHyperlinkMatchesFromStoredRowsDropsRowWhenNodeIsMissing() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 999
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: [])

        XCTAssertTrue(matches.isEmpty)
    }

    func testHyperlinkMatchesFromStoredRowsIgnoresDuplicateOCRNodeIDs() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/watchdog",
                nodeID: 5_069_399_747
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 5_069_399_747,
                nodeOrder: 3,
                frameId: 42,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary link text"
            ),
            OCRNodeWithText(
                id: 5_069_399_747,
                nodeOrder: 3,
                frameId: 42,
                x: 0.1,
                y: 0.25,
                width: 0.3,
                height: 0.05,
                text: "Duplicate link text"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Primary link text")
        XCTAssertEqual(matches[0].url, "https://retrace.to/watchdog")
    }
}
