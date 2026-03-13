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
            now: Date(timeIntervalSince1970: 1_773_093_600),
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

    private func makeReportDirectories() throws -> (URL, URL, URL) {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let emergencyDirectoryURL = baseURL.appendingPathComponent("emergency", isDirectory: true)
        let diagnosticDirectoryURL = baseURL.appendingPathComponent("diagnostic", isDirectory: true)
        try fileManager.createDirectory(at: emergencyDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticDirectoryURL, withIntermediateDirectories: true)
        return (emergencyDirectoryURL, diagnosticDirectoryURL, baseURL)
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
        XCTAssertTrue(context.prefilledDescription?.contains("Retrace WAL Startup Failure") == true)
        XCTAssertTrue(context.prefilledDescription?.contains("Crash recovery was skipped") == true)
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

final class AppNameResolverInstalledAppsTests: XCTestCase {
    func testInstalledAppsDeduplicatesDuplicateBundleIDsAcrossScanFolders() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryFolderURL = rootURL.appendingPathComponent("Applications", isDirectory: true)
        let secondaryFolderURL = rootURL.appendingPathComponent("Applications-2", isDirectory: true)

        try fileManager.createDirectory(at: primaryFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondaryFolderURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        try createAppBundle(
            named: "Safari Primary",
            bundleID: "com.apple.Safari",
            displayName: "Safari Primary",
            in: primaryFolderURL
        )
        try createAppBundle(
            named: "Safari Secondary",
            bundleID: "com.apple.Safari",
            displayName: "Safari Secondary",
            in: secondaryFolderURL
        )
        try createAppBundle(
            named: "Chrome",
            bundleID: "com.google.Chrome",
            displayName: "Chrome",
            in: secondaryFolderURL
        )

        let apps = AppNameResolver.installedApps(
            in: [primaryFolderURL, secondaryFolderURL],
            fileManager: fileManager
        )

        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertEqual(apps.map(\.name), ["Safari Primary", "Chrome"])
    }

    private func createAppBundle(
        named appName: String,
        bundleID: String,
        displayName: String,
        in folderURL: URL
    ) throws {
        let appURL = folderURL.appendingPathComponent("\(appName).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": displayName
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}

@MainActor
final class SearchViewModelAvailableAppsTests: XCTestCase {
    func testAvailableAppsDeduplicatesDuplicateBundleIDsAndPrefersInstalledEntries() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.installedApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome")
        ]
        viewModel.otherApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari (DB)"),
            AppInfo(bundleID: "com.microsoft.edgemac", name: "Edge")
        ]

        XCTAssertEqual(
            viewModel.availableApps.map(\.bundleID),
            ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac"]
        )
        XCTAssertEqual(
            viewModel.availableApps.first(where: { $0.bundleID == "com.apple.Safari" })?.name,
            "Safari"
        )
    }
}

final class SpotlightSearchOverlayRecentEntryAppMapTests: XCTestCase {
    func testRecentEntryAppNameMapDeduplicatesDuplicateBundleIDsWithoutTrapping() {
        let appNameMap = SpotlightSearchOverlay.recentEntryAppNameMap(from: [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "com.apple.Safari", name: "Safari Copy"),
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome")
        ])

        XCTAssertEqual(appNameMap.count, 2)
        XCTAssertEqual(appNameMap["com.apple.Safari"], "Safari")
        XCTAssertEqual(appNameMap["com.google.Chrome"], "Chrome")
    }
}
