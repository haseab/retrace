import XCTest
@testable import App

final class CLILauncherManagerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var supportedAppBundlePath: String!
    private var launcherPath: String!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLILauncherManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        supportedAppBundlePath = temporaryDirectoryURL
            .appendingPathComponent("Applications/Retrace.app", isDirectory: true)
            .path
        launcherPath = temporaryDirectoryURL
            .appendingPathComponent("usr/local/bin/retrace", isDirectory: false)
            .path
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func testStatusReportsUnsupportedLocationWhenAppIsNotInApplications() {
        let manager = makeManager(currentAppBundlePath: temporaryDirectoryURL.appendingPathComponent("Debug/Retrace.app").path)

        let status = manager.status()

        XCTAssertEqual(status.state, .unsupportedAppLocation)
        XCTAssertEqual(status.launcherPath, launcherPath)
    }

    func testStatusReportsBundledCLIMissingWhenExecutableIsAbsent() {
        let manager = makeManager(currentAppBundlePath: supportedAppBundlePath)

        let status = manager.status()

        XCTAssertEqual(status.state, .bundledCLIMissing)
    }

    func testInstallWritesExpectedWrapperScript() throws {
        try createBundledCLIExecutable()
        let manager = makeManager(currentAppBundlePath: supportedAppBundlePath)

        XCTAssertEqual(manager.status().state, .notInstalled)

        let result = try manager.installLauncher()

        XCTAssertEqual(result.action, .install)
        XCTAssertFalse(result.usedPrivileges)
        XCTAssertEqual(try String(contentsOfFile: launcherPath, encoding: .utf8), manager.expectedWrapperScript)
        XCTAssertEqual(manager.status().state, .installed)
    }

    func testRepairOverwritesUnexpectedLauncherContents() throws {
        try createBundledCLIExecutable()
        let launcherURL = URL(fileURLWithPath: launcherPath)
        try FileManager.default.createDirectory(
            at: launcherURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try "#!/bin/sh\necho old\n".write(to: launcherURL, atomically: true, encoding: .utf8)

        let manager = makeManager(currentAppBundlePath: supportedAppBundlePath)
        XCTAssertEqual(manager.status().state, .needsRepair)

        let result = try manager.repairLauncher()

        XCTAssertEqual(result.action, .repair)
        XCTAssertFalse(result.usedPrivileges)
        XCTAssertEqual(try String(contentsOfFile: launcherPath, encoding: .utf8), manager.expectedWrapperScript)
        XCTAssertEqual(manager.status().state, .installed)
    }

    func testRemoveDeletesInstalledLauncher() throws {
        try createBundledCLIExecutable()
        let manager = makeManager(currentAppBundlePath: supportedAppBundlePath)
        _ = try manager.installLauncher()

        let result = try manager.removeLauncher()

        XCTAssertEqual(result.action, .remove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcherPath))
        XCTAssertEqual(manager.status().state, .notInstalled)
    }

    private func makeManager(currentAppBundlePath: String) -> CLILauncherManager {
        CLILauncherManager(
            fileManager: .default,
            supportedAppBundlePath: supportedAppBundlePath,
            launcherPath: launcherPath,
            currentAppBundlePathProvider: { currentAppBundlePath },
            privilegedCommandRunner: { command in
                XCTFail("Privileged runner should not be used in test: \(command)")
            }
        )
    }

    private func createBundledCLIExecutable() throws {
        let bundledCLIURL = URL(fileURLWithPath: supportedAppBundlePath)
            .appendingPathComponent("Contents/MacOS/RetraceCLI", isDirectory: false)
        try FileManager.default.createDirectory(
            at: bundledCLIURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try "#!/bin/sh\nexit 0\n".write(to: bundledCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLIURL.path)
    }
}
