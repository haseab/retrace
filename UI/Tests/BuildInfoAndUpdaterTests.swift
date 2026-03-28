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

final class AppRelaunchPathSelectionTests: XCTestCase {
    func testPreferredRelaunchPathUsesCurrentAppBundleWhenInstalledAppAlsoExists() {
        XCTAssertEqual(
            AppRelaunch.preferredRelaunchPath(
                currentBundlePath: "/Users/test/Downloads/Retrace.app",
                currentExecutablePath: "/Users/test/Downloads/Retrace.app/Contents/MacOS/Retrace",
                applicationsAppExists: true
            ),
            "/Users/test/Downloads/Retrace.app"
        )
    }

    func testPreferredRelaunchPathUsesCurrentExecutableForStandaloneDevBuild() {
        XCTAssertEqual(
            AppRelaunch.preferredRelaunchPath(
                currentBundlePath: "/Users/test/src/retrace/.build/arm64-apple-macosx/debug",
                currentExecutablePath: "/Users/test/src/retrace/.build/arm64-apple-macosx/debug/Retrace",
                applicationsAppExists: true
            ),
            "/Users/test/src/retrace/.build/arm64-apple-macosx/debug/Retrace"
        )
    }

    func testPreferredRelaunchPathFallsBackToInstalledAppWhenCurrentBundleAndExecutablePathsMissing() {
        XCTAssertEqual(
            AppRelaunch.preferredRelaunchPath(
                currentBundlePath: " ",
                currentExecutablePath: nil,
                applicationsAppExists: true
            ),
            "/Applications/Retrace.app"
        )
    }

    func testLaunchModeUsesOpenForAppBundles() {
        XCTAssertEqual(AppRelaunch.launchMode(forPath: "/Applications/Retrace.app"), .openItem)
    }

    func testLaunchModeUsesTerminalForStandaloneDevDebugBuild() {
        XCTAssertEqual(
            AppRelaunch.launchMode(
                forPath: "/Users/test/src/retrace/.build/arm64-apple-macosx/debug/Retrace",
                isDevBuild: true
            ),
            .openTerminal
        )
    }

    func testLaunchModeExecutesStandaloneBinaryForNonDevBuild() {
        XCTAssertEqual(
            AppRelaunch.launchMode(
                forPath: "/Users/test/src/retrace/.build/arm64-apple-macosx/debug/Retrace",
                isDevBuild: false
            ),
            .executeFile
        )
    }

    func testLaunchModeExecutesStandaloneDevNonDebugBuild() {
        XCTAssertEqual(
            AppRelaunch.launchMode(
                forPath: "/Users/test/src/retrace/bin/Retrace",
                isDevBuild: true
            ),
            .executeFile
        )
    }

    func testTerminalLauncherScriptRemovesWrapperAndExecutesBinary() {
        XCTAssertEqual(
            AppRelaunch.terminalLauncherScriptContents(
                forExecutablePath: "/Users/test/src/retrace/.build/debug/Retrace"
            ),
            """
            #!/bin/zsh
            rm -f -- "$0"
            exec '/Users/test/src/retrace/.build/debug/Retrace'
            """
        )
    }
}

final class SingleInstanceLockTests: XCTestCase {
    func testAcquireReportsAlreadyHeldWhenDescriptorAlreadyOwned() throws {
        let lockPath = makeTemporaryLockPath()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        var descriptor = try acquireLock(atPath: lockPath, processID: 1111)
        defer { SingleInstanceLock.release(descriptor: &descriptor) }

        guard case .alreadyHeld(let heldDescriptor) = SingleInstanceLock.acquire(
            atPath: lockPath,
            existingDescriptor: descriptor,
            processID: 2222
        ) else {
            return XCTFail("Expected .alreadyHeld for existing descriptor")
        }

        XCTAssertEqual(heldDescriptor, descriptor)
    }

    func testAcquireReportsAnotherProcessWhenLockIsHeldElsewhere() throws {
        let lockPath = makeTemporaryLockPath()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        var descriptor = try acquireLock(atPath: lockPath, processID: 1111)
        defer { SingleInstanceLock.release(descriptor: &descriptor) }

        guard case .heldByAnotherProcess = SingleInstanceLock.acquire(
            atPath: lockPath,
            existingDescriptor: -1,
            processID: 2222
        ) else {
            return XCTFail("Expected .heldByAnotherProcess while first descriptor owns the lock")
        }
    }

    func testAcquireSucceedsAfterPreviousDescriptorReleasesLock() throws {
        let lockPath = makeTemporaryLockPath()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        var originalDescriptor = try acquireLock(atPath: lockPath, processID: 1111)
        SingleInstanceLock.release(descriptor: &originalDescriptor)

        var reacquiredDescriptor = try acquireLock(atPath: lockPath, processID: 2222)
        defer { SingleInstanceLock.release(descriptor: &reacquiredDescriptor) }

        XCTAssertGreaterThanOrEqual(reacquiredDescriptor, 0)
    }

    private func makeTemporaryLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-single-instance-\(UUID().uuidString).lock")
            .path
    }

    private func acquireLock(atPath path: String, processID: pid_t) throws -> CInt {
        switch SingleInstanceLock.acquire(
            atPath: path,
            existingDescriptor: -1,
            processID: processID
        ) {
        case .acquired(let descriptor):
            return descriptor
        case .alreadyHeld:
            XCTFail("Expected fresh lock acquisition, but descriptor was already held")
        case .heldByAnotherProcess:
            XCTFail("Expected fresh lock acquisition, but another process owned the lock")
        case .error(let code):
            XCTFail("Expected fresh lock acquisition, but lock failed with errno \(code)")
        }

        throw NSError(domain: "SingleInstanceLockTests", code: 1)
    }
}

final class SingleInstanceLockRetrierTests: XCTestCase {
    func testAcquireRetriesUntilLockBecomesAvailable() async {
        var attempts = 0
        var sleepCalls = 0

        let result = await SingleInstanceLockRetrier.acquire(
            maxAttempts: 3,
            retryDelay: .milliseconds(1),
            acquire: { _ in
                attempts += 1

                if attempts < 3 {
                    return .heldByAnotherProcess
                }

                return .acquired(descriptor: 42)
            },
            sleep: { _ in
                sleepCalls += 1
            }
        )

        XCTAssertEqual(result, .acquired(descriptor: 42, attempts: 3))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleepCalls, 2)
    }

    func testAcquireFailsClosedAfterRetryBudgetExhaustedOnError() async {
        var attempts = 0
        var sleepCalls = 0

        let result = await SingleInstanceLockRetrier.acquire(
            maxAttempts: 4,
            retryDelay: .milliseconds(1),
            acquire: { _ in
                attempts += 1
                return .error(code: EIO)
            },
            sleep: { _ in
                sleepCalls += 1
            }
        )

        XCTAssertEqual(result, .failedError(code: EIO, attempts: 4))
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(sleepCalls, 3)
    }

    func testAcquireFailsClosedWhenAnotherProcessKeepsHoldingLock() async {
        var attempts = 0
        var sleepCalls = 0

        let result = await SingleInstanceLockRetrier.acquire(
            maxAttempts: 2,
            retryDelay: .milliseconds(1),
            acquire: { _ in
                attempts += 1
                return .heldByAnotherProcess
            },
            sleep: { _ in
                sleepCalls += 1
            }
        )

        XCTAssertEqual(result, .failedHeldByAnotherProcess(attempts: 2))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleepCalls, 1)
    }
}
