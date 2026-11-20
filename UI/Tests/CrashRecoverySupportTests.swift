import Dispatch
import ServiceManagement
import Shared
import XCTest
@testable import CrashRecoverySupport
@testable import Retrace

private final class TestCrashRecoveryHelperProxy: NSObject, CrashRecoveryHelperXPCProtocol, @unchecked Sendable {
    var shouldReply = false
    var armCallCount = 0
    var expectedExitCallCount = 0
    var relaunchCallCount = 0
    var hangSampleCallCount = 0
    var capturedRelaunchTargetAppPath: String?
    var capturedHangSampleTrigger: String?
    var hangSampleReplyPath: String?
    var blockHangSampleReply = false

    private let hangSampleReplyGate = DispatchSemaphore(value: 0)

    func arm(reply: @escaping () -> Void) {
        armCallCount += 1
        if shouldReply {
            reply()
        }
    }

    func prepareForExpectedExit(reply: @escaping () -> Void) {
        expectedExitCallCount += 1
        if shouldReply {
            reply()
        }
    }

    func prepareForRelaunch(targetAppPath: String?, reply: @escaping () -> Void) {
        relaunchCallCount += 1
        capturedRelaunchTargetAppPath = targetAppPath
        if shouldReply {
            reply()
        }
    }

    func captureWatchdogHangSample(trigger: String, reply: @escaping (String?) -> Void) {
        hangSampleCallCount += 1
        capturedHangSampleTrigger = trigger
        if shouldReply {
            if blockHangSampleReply {
                let replyPath = hangSampleReplyPath
                DispatchQueue.global(qos: .userInitiated).async {
                    self.hangSampleReplyGate.wait()
                    reply(replyPath)
                }
            } else {
                reply(hangSampleReplyPath)
            }
        }
    }

    func releaseBlockedHangSampleReply() {
        hangSampleReplyGate.signal()
    }
}

final class CrashRecoverySupportTests: XCTestCase {
    @MainActor
    private func blockMainActorForTesting(
        started: XCTestExpectation,
        releaseMainActor: DispatchSemaphore
    ) {
        started.fulfill()
        releaseMainActor.wait()
    }

    private func makeTestDefaults(suffix: String = UUID().uuidString) -> UserDefaults {
        let suiteName = "io.retrace.tests.crash-recovery.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testAppBundleURLFromExecutableReturnsEnclosingApp() {
        let executableURL = URL(fileURLWithPath: "/Applications/Retrace.app/Contents/MacOS/Retrace")

        let bundleURL = CrashRecoverySupport.appBundleURL(fromExecutableURL: executableURL)

        XCTAssertEqual(bundleURL?.path, "/Applications/Retrace.app")
    }

    func testAppBundleURLFromExecutableReturnsNilOutsideAppBundle() {
        let executableURL = URL(fileURLWithPath: "/tmp/Retrace")

        XCTAssertNil(CrashRecoverySupport.appBundleURL(fromExecutableURL: executableURL))
    }

    func testCurrentLaunchTargetUsesCurrentProcessExecutableWhenArgumentsAreRelative() {
        let target = CrashRecoverySupport.currentLaunchTarget(
            arguments: ["Contents/MacOS/Retrace"]
        )

        XCTAssertNotNil(target)
        XCTAssertEqual(target, CrashRecoverySupport.currentLaunchTarget())
    }

    func testCurrentLaunchTargetReturnsExecutableOutsideAppBundle() {
        let target = CrashRecoverySupport.currentLaunchTarget(arguments: ["/tmp/.build/debug/Retrace"])

        XCTAssertEqual(target, .executable(URL(fileURLWithPath: "/tmp/.build/debug/Retrace")))
    }

    func testLaunchArgumentsDetectCrashRecoveryRelaunch() {
        XCTAssertTrue(
            CrashRecoverySupport.launchedFromCrashRecovery(
                arguments: ["Retrace", CrashRecoverySupport.crashRecoveryLaunchArgument]
            )
        )
        XCTAssertFalse(CrashRecoverySupport.launchedFromCrashRecovery(arguments: ["Retrace"]))
    }

    func testConsumeCrashRecoveryLaunchSourceReturnsStoredSourceForCrashRelaunch() {
        let defaults = makeTestDefaults()
        XCTAssertTrue(
            CrashRecoverySupport.storePendingCrashRecoveryLaunchSource(
                .watchdogAutoQuit,
                defaults: defaults
            )
        )

        let source = CrashRecoverySupport.consumeCrashRecoveryLaunchSource(
            arguments: ["Retrace", CrashRecoverySupport.crashRecoveryLaunchArgument],
            defaults: defaults
        )

        XCTAssertEqual(source, .watchdogAutoQuit)
        XCTAssertEqual(
            CrashRecoverySupport.consumeCrashRecoveryLaunchSource(
                arguments: ["Retrace", CrashRecoverySupport.crashRecoveryLaunchArgument],
                defaults: defaults
            ),
            .unknown
        )
    }

    func testConsumeCrashRecoveryLaunchSourcePrefersExplicitArgumentSource() {
        let defaults = makeTestDefaults()
        XCTAssertTrue(
            CrashRecoverySupport.storePendingCrashRecoveryLaunchSource(
                .watchdogAutoQuit,
                defaults: defaults
            )
        )

        let source = CrashRecoverySupport.consumeCrashRecoveryLaunchSource(
            arguments: [
                "Retrace",
                CrashRecoverySupport.crashRecoveryLaunchArgument,
                CrashRecoverySupport.crashRecoverySourceArgument,
                CrashRecoverySupport.RelaunchSource.crashRecoveryHelper.rawValue,
            ],
            defaults: defaults
        )

        XCTAssertEqual(source, .crashRecoveryHelper)
        XCTAssertEqual(
            CrashRecoverySupport.consumeCrashRecoveryLaunchSource(
                arguments: ["Retrace", CrashRecoverySupport.crashRecoveryLaunchArgument],
                defaults: defaults
            ),
            .unknown
        )
    }

    func testConsumeCrashRecoveryLaunchSourceIgnoresStoredValueForNormalLaunches() {
        let defaults = makeTestDefaults()
        XCTAssertTrue(
            CrashRecoverySupport.storePendingCrashRecoveryLaunchSource(
                .crashRecoveryHelper,
                defaults: defaults
            )
        )

        XCTAssertNil(
            CrashRecoverySupport.consumeCrashRecoveryLaunchSource(
                arguments: ["Retrace"],
                defaults: defaults
            )
        )
    }

    func testShouldRefreshRegistrationWhenBuildChanges() {
        XCTAssertTrue(
            CrashRecoverySupport.shouldRefreshRegistration(
                storedBuild: "9",
                currentBuild: "10",
                storedLaunchTargetPath: "/Applications/Retrace.app",
                currentLaunchTargetPath: "/Applications/Retrace.app",
                status: .enabled
            )
        )
    }

    func testShouldRefreshRegistrationWhenLaunchTargetChanges() {
        XCTAssertTrue(
            CrashRecoverySupport.shouldRefreshRegistration(
                storedBuild: "10",
                currentBuild: "10",
                storedLaunchTargetPath: "/Applications/Retrace-old.app",
                currentLaunchTargetPath: "/Applications/Retrace.app",
                status: .enabled
            )
        )
    }

    func testShouldRefreshRegistrationWhenServiceMissing() {
        XCTAssertTrue(
            CrashRecoverySupport.shouldRefreshRegistration(
                storedBuild: "10",
                currentBuild: "10",
                storedLaunchTargetPath: "/Applications/Retrace.app",
                currentLaunchTargetPath: "/Applications/Retrace.app",
                status: .notRegistered
            )
        )
    }

    func testShouldNotRefreshRegistrationWhenBuildAndTargetMatchEnabledService() {
        XCTAssertFalse(
            CrashRecoverySupport.shouldRefreshRegistration(
                storedBuild: "10",
                currentBuild: "10",
                storedLaunchTargetPath: "/Applications/Retrace.app",
                currentLaunchTargetPath: "/Applications/Retrace.app",
                status: .enabled
            )
        )
    }

    func testRelaunchProcessUsesOpenForAppBundleCrashRecovery() {
        XCTAssertEqual(
            CrashRecoverySupport.relaunchProcess(
                for: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                markAsCrashRecovery: true
            ),
            CrashRecoverySupport.RelaunchProcess(
                executablePath: "/usr/bin/open",
                arguments: ["/Applications/Retrace.app", "--args", CrashRecoverySupport.crashRecoveryLaunchArgument]
            )
        )
    }

    func testRelaunchProcessUsesOpenForAppBundleIntentionalRelaunch() {
        XCTAssertEqual(
            CrashRecoverySupport.relaunchProcess(
                for: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                markAsCrashRecovery: false
            ),
            CrashRecoverySupport.RelaunchProcess(
                executablePath: "/usr/bin/open",
                arguments: ["/Applications/Retrace.app"]
            )
        )
    }

    func testRelaunchProcessIncludesExplicitCrashRecoverySourceForAppBundle() {
        XCTAssertEqual(
            CrashRecoverySupport.relaunchProcess(
                for: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                markAsCrashRecovery: true,
                source: .crashRecoveryHelper
            ),
            CrashRecoverySupport.RelaunchProcess(
                executablePath: "/usr/bin/open",
                arguments: [
                    "/Applications/Retrace.app",
                    "--args",
                    CrashRecoverySupport.crashRecoveryLaunchArgument,
                    CrashRecoverySupport.crashRecoverySourceArgument,
                    CrashRecoverySupport.RelaunchSource.crashRecoveryHelper.rawValue,
                ]
            )
        )
    }

    func testRelaunchProcessUsesExecutableForStandaloneBinary() {
        XCTAssertEqual(
            CrashRecoverySupport.relaunchProcess(
                for: .executable(URL(fileURLWithPath: "/tmp/.build/debug/Retrace")),
                markAsCrashRecovery: true
            ),
            CrashRecoverySupport.RelaunchProcess(
                executablePath: "/tmp/.build/debug/Retrace",
                arguments: [CrashRecoverySupport.crashRecoveryLaunchArgument]
            )
        )
    }

    func testShouldPromptForApprovalOnlyForBundledLaunchAgent() {
        XCTAssertTrue(
            CrashRecoverySupport.shouldPromptForApproval(
                status: .requiresApproval,
                launchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app"))
            )
        )
        XCTAssertFalse(
            CrashRecoverySupport.shouldPromptForApproval(
                status: .enabled,
                launchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app"))
            )
        )
        XCTAssertFalse(
            CrashRecoverySupport.shouldPromptForApproval(
                status: .requiresApproval,
                launchTarget: .executable(URL(fileURLWithPath: "/tmp/.build/debug/Retrace"))
            )
        )
    }

    func testUserFacingStatusRequiresApprovalForBundledLaunchAgent() {
        XCTAssertEqual(
            CrashRecoverySupport.makeUserFacingStatus(
                launchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                serviceStatus: .requiresApproval,
                unavailableReason: .registrationFailed
            ),
            .requiresApproval
        )
    }

    func testUserFacingStatusSurfacesRegistrationFailure() {
        XCTAssertEqual(
            CrashRecoverySupport.makeUserFacingStatus(
                launchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                serviceStatus: .notFound,
                unavailableReason: .registrationFailed
            ),
            .unavailable(.registrationFailed)
        )
    }

    func testUserFacingStatusReturnsAvailableForNonAppLaunches() {
        XCTAssertEqual(
            CrashRecoverySupport.makeUserFacingStatus(
                launchTarget: .executable(URL(fileURLWithPath: "/tmp/.build/debug/Retrace")),
                serviceStatus: .requiresApproval,
                unavailableReason: .registrationFailed
            ),
            .available
        )
    }

    func testRegistrationRecoveryRetryRunsWhenHelperArmFailsWithoutApprovalRequirement() {
        XCTAssertTrue(
            CrashRecoverySupport.shouldAttemptRegistrationRecoveryAfterArmFailure(serviceStatus: .enabled)
        )
        XCTAssertTrue(
            CrashRecoverySupport.shouldAttemptRegistrationRecoveryAfterArmFailure(serviceStatus: .notFound)
        )
    }

    func testRegistrationRecoveryRetrySkipsApprovalRequiredState() {
        XCTAssertFalse(
            CrashRecoverySupport.shouldAttemptRegistrationRecoveryAfterArmFailure(serviceStatus: .requiresApproval)
        )
    }

    func testDisconnectLaunchParametersTreatArmedDisconnectWithoutSuppressionAsCrash() {
        let launchParameters = CrashRecoverySupport.SessionDisposition.armed.disconnectLaunchParameters(
            disconnectSuppressed: false
        )

        XCTAssertEqual(launchParameters?.markAsCrashRecovery, true)
        XCTAssertNil(launchParameters?.targetAppPath)
    }

    func testDisconnectLaunchParametersUseDisconnectSuppression() {
        XCTAssertNil(
            CrashRecoverySupport.SessionDisposition.armed.disconnectLaunchParameters(
                disconnectSuppressed: true
            )
        )
    }

    func testDisconnectLaunchParametersUseExpectedExitDisposition() {
        XCTAssertNil(
            CrashRecoverySupport.SessionDisposition.expectedExit.disconnectLaunchParameters(
                disconnectSuppressed: false
            )
        )
    }

    func testDisconnectLaunchParametersUseRelaunchDisposition() {
        let launchParameters = CrashRecoverySupport.SessionDisposition
            .relaunch("/Applications/Retrace.app")
            .disconnectLaunchParameters(disconnectSuppressed: false)

        XCTAssertEqual(launchParameters?.markAsCrashRecovery, false)
        XCTAssertEqual(launchParameters?.targetAppPath, "/Applications/Retrace.app")
    }

    func testDisconnectSuppressionRoundTripsAndIsConsumedOnce() {
        let defaults = makeTestDefaults()

        XCTAssertTrue(
            CrashRecoverySupport.storeDisconnectSuppression(
                now: Date(timeIntervalSince1970: 1_700_000_000),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            CrashRecoverySupport.consumeDisconnectSuppression(
                now: Date(timeIntervalSince1970: 1_700_000_005),
                defaults: defaults
            )
        )
        XCTAssertFalse(CrashRecoverySupport.consumeDisconnectSuppression(defaults: defaults))
    }

    func testDisconnectSuppressionExpiresWhenTooOld() {
        let defaults = makeTestDefaults()

        XCTAssertTrue(
            CrashRecoverySupport.storeDisconnectSuppression(
                now: Date(timeIntervalSince1970: 1_700_000_000),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            CrashRecoverySupport.consumeDisconnectSuppression(
                now: Date(timeIntervalSince1970: 1_700_000_100),
                defaults: defaults
            )
        )
    }

    func testSuccessfulArmClearsStaleDisconnectSuppression() {
        let defaults = makeTestDefaults()

        XCTAssertTrue(CrashRecoverySupport.storeDisconnectSuppression(defaults: defaults))
        XCTAssertTrue(
            CrashRecoverySupport.clearDisconnectSuppression(defaults: defaults)
        )
        XCTAssertFalse(CrashRecoverySupport.consumeDisconnectSuppression(defaults: defaults))
    }

    func testFailedArmDoesNotClearDisconnectSuppression() {
        let defaults = makeTestDefaults()

        XCTAssertTrue(CrashRecoverySupport.storeDisconnectSuppression(defaults: defaults))
        XCTAssertTrue(CrashRecoverySupport.loadDisconnectSuppression(defaults: defaults))
    }

    func testCrashAutoRestartGuardSuppressesThirdRestartWithinWindow() {
        let defaults = makeTestDefaults()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start,
            defaults: defaults
        )
        let second = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start.addingTimeInterval(60),
            defaults: defaults
        )
        let third = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start.addingTimeInterval(120),
            defaults: defaults
        )

        XCTAssertTrue(first.shouldRelaunch)
        XCTAssertEqual(first.recentCount, 1)
        XCTAssertTrue(second.shouldRelaunch)
        XCTAssertEqual(second.recentCount, 2)
        XCTAssertFalse(third.shouldRelaunch)
        XCTAssertEqual(third.recentCount, 2)
    }

    func testCrashAutoRestartGuardAllowsRestartAfterWindowExpires() {
        let defaults = makeTestDefaults()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        _ = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start,
            defaults: defaults
        )
        _ = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start.addingTimeInterval(60),
            defaults: defaults
        )

        let decision = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart(
            now: start.addingTimeInterval(
                CrashRecoverySupport.crashAutoRestartWindowSeconds + 61
            ),
            defaults: defaults
        )

        XCTAssertTrue(decision.shouldRelaunch)
        XCTAssertEqual(decision.recentCount, 1)
    }

    func testIntentionalRelaunchPrefersHelperOnMainThreadForBundledApp() {
        XCTAssertTrue(
            AppRelaunch.shouldUseBundledHelperForIntentionalRelaunch(
                currentLaunchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                isMainThread: true
            )
        )
    }

    func testIntentionalRelaunchFallsBackToShellOffMainThreadOrOutsideAppBundle() {
        XCTAssertFalse(
            AppRelaunch.shouldUseBundledHelperForIntentionalRelaunch(
                currentLaunchTarget: .appBundle(URL(fileURLWithPath: "/Applications/Retrace.app")),
                isMainThread: false
            )
        )
        XCTAssertFalse(
            AppRelaunch.shouldUseBundledHelperForIntentionalRelaunch(
                currentLaunchTarget: .executable(URL(fileURLWithPath: "/tmp/.build/debug/Retrace")),
                isMainThread: true
            )
        )
    }

    func testFallbackLaunchCommandIncludesCrashRecoveryArgsForAppBundle() {
        XCTAssertEqual(
            AppRelaunch.fallbackLaunchCommand(
                atPath: "/Applications/Retrace.app",
                markAsCrashRecovery: true
            ),
            "open '/Applications/Retrace.app' --args \(CrashRecoverySupport.crashRecoveryLaunchArgument)"
        )
    }

    func testFallbackLaunchCommandIncludesCrashRecoverySourceForAppBundle() {
        XCTAssertEqual(
            AppRelaunch.fallbackLaunchCommand(
                atPath: "/Applications/Retrace.app",
                markAsCrashRecovery: true,
                crashRecoverySource: .watchdogAutoQuit
            ),
            "open '/Applications/Retrace.app' --args \(CrashRecoverySupport.crashRecoveryLaunchArgument) \(CrashRecoverySupport.crashRecoverySourceArgument) \(CrashRecoverySupport.RelaunchSource.watchdogAutoQuit.rawValue)"
        )
    }

    func testFallbackLaunchCommandOmitsCrashRecoveryArgsForIntentionalAppBundleRelaunch() {
        XCTAssertEqual(
            AppRelaunch.fallbackLaunchCommand(
                atPath: "/Applications/Retrace.app",
                markAsCrashRecovery: false
            ),
            "open '/Applications/Retrace.app'"
        )
    }

    func testFallbackLaunchCommandIncludesCrashRecoveryArgsForStandaloneExecutable() {
        XCTAssertEqual(
            AppRelaunch.fallbackLaunchCommand(
                atPath: "/tmp/.build/debug/Retrace",
                markAsCrashRecovery: true
            ),
            "'/tmp/.build/debug/Retrace' \(CrashRecoverySupport.crashRecoveryLaunchArgument)"
        )
    }

    func testShellFallbackStoresDisconnectSuppression() {
        let defaults = makeTestDefaults()

        XCTAssertTrue(AppRelaunch.prepareDisconnectSuppressionForShellFallback(defaults: defaults))
        XCTAssertTrue(CrashRecoverySupport.consumeDisconnectSuppression(defaults: defaults))
    }

    @MainActor
    func testBundledHelperRelaunchAcknowledgementRequiresReply() async {
        let proxy = TestCrashRecoveryHelperProxy()

        let acknowledged = await CrashRecoveryManager.helperAcknowledged(
            .relaunch("/Applications/Retrace.app"),
            via: proxy,
            timeoutMs: 10
        )

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(proxy.relaunchCallCount, 1)
        XCTAssertEqual(proxy.capturedRelaunchTargetAppPath, "/Applications/Retrace.app")
    }

    @MainActor
    func testBundledHelperRelaunchAcknowledgementSucceedsAfterReply() async {
        let proxy = TestCrashRecoveryHelperProxy()
        proxy.shouldReply = true

        let acknowledged = await CrashRecoveryManager.helperAcknowledged(
            .relaunch("/Applications/Retrace.app"),
            via: proxy,
            timeoutMs: 10
        )

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(proxy.relaunchCallCount, 1)
        XCTAssertEqual(proxy.capturedRelaunchTargetAppPath, "/Applications/Retrace.app")
    }

    @MainActor
    func testPrepareForExpectedExitInstallsDisconnectSuppressionWhenHelperDoesNotReply() async {
        let proxy = TestCrashRecoveryHelperProxy()
        let defaults = makeTestDefaults()
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy, defaults: defaults)

        await manager.prepareForExpectedExit()

        let disconnectCallCount = await manager.testDisconnectCallCount()
        XCTAssertEqual(proxy.expectedExitCallCount, 1)
        XCTAssertEqual(disconnectCallCount, 0)
        XCTAssertTrue(CrashRecoverySupport.loadDisconnectSuppression(defaults: defaults))
    }

    @MainActor
    func testBundledIntentionalRelaunchReturnsTrueWithoutDisconnectingWhenHelperReplies() async {
        let proxy = TestCrashRecoveryHelperProxy()
        proxy.shouldReply = true
        let defaults = makeTestDefaults()
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy, defaults: defaults)

        let acknowledged = await manager.requestIntentionalRelaunch(
            targetAppPath: "/Applications/Retrace.app"
        )

        let disconnectCallCount = await manager.testDisconnectCallCount()
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(proxy.relaunchCallCount, 1)
        XCTAssertEqual(disconnectCallCount, 0)
        XCTAssertFalse(CrashRecoverySupport.loadDisconnectSuppression(defaults: defaults))
    }

    @MainActor
    func testBundledIntentionalRelaunchReturnsFalseWithoutDisconnectingWhenHelperDoesNotReply() async {
        let proxy = TestCrashRecoveryHelperProxy()
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy)

        let acknowledged = await manager.requestIntentionalRelaunch(
            targetAppPath: "/Applications/Retrace.app"
        )

        let disconnectCallCount = await manager.testDisconnectCallCount()
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(proxy.relaunchCallCount, 1)
        XCTAssertEqual(disconnectCallCount, 0)
    }

    @MainActor
    func testBundledHelperWatchdogHangSampleReturnsPathAfterReply() async {
        let proxy = TestCrashRecoveryHelperProxy()
        proxy.shouldReply = true
        proxy.hangSampleReplyPath = "/tmp/retrace-watchdog-sample.txt"
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy)

        let samplePath = await manager.captureWatchdogHangSample(
            trigger: "watchdog_auto_quit",
            timeoutMs: 10
        )

        XCTAssertEqual(samplePath, "/tmp/retrace-watchdog-sample.txt")
        XCTAssertEqual(proxy.hangSampleCallCount, 1)
        XCTAssertEqual(proxy.capturedHangSampleTrigger, "watchdog_auto_quit")
    }

    @MainActor
    func testBundledHelperWatchdogHangSampleReturnsNilWhenHelperDoesNotReply() async {
        let proxy = TestCrashRecoveryHelperProxy()
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy)

        let samplePath = await manager.captureWatchdogHangSample(
            trigger: "watchdog_auto_quit",
            timeoutMs: 10
        )

        XCTAssertNil(samplePath)
        XCTAssertEqual(proxy.hangSampleCallCount, 1)
        XCTAssertEqual(proxy.capturedHangSampleTrigger, "watchdog_auto_quit")
    }

    func testHelperWatchdogHangSampleCompletesWhileMainActorIsBlocked() async {
        let proxy = TestCrashRecoveryHelperProxy()
        proxy.shouldReply = true
        proxy.hangSampleReplyPath = "/tmp/retrace-watchdog-sample.txt"
        let releaseMainActor = DispatchSemaphore(value: 0)
        let mainActorStarted = expectation(description: "main actor blocked")
        let completed = expectation(description: "hang sample completed off main actor")

        Task { @MainActor in
            self.blockMainActorForTesting(
                started: mainActorStarted,
                releaseMainActor: releaseMainActor
            )
        }
        await fulfillment(of: [mainActorStarted], timeout: 1)

        Task.detached {
            let samplePath = await CrashRecoveryManager.helperWatchdogHangSample(
                "watchdog_auto_quit",
                via: proxy,
                timeoutMs: 50
            )
            if samplePath == "/tmp/retrace-watchdog-sample.txt" {
                completed.fulfill()
            }
        }

        await fulfillment(of: [completed], timeout: 0.2)
        releaseMainActor.signal()

        XCTAssertEqual(proxy.hangSampleCallCount, 1)
        XCTAssertEqual(proxy.capturedHangSampleTrigger, "watchdog_auto_quit")
    }

    @MainActor
    func testWatchdogHangSampleDefersReconnectUntilInFlightRequestCompletes() async {
        let proxy = TestCrashRecoveryHelperProxy()
        proxy.shouldReply = true
        proxy.blockHangSampleReply = true
        proxy.hangSampleReplyPath = "/tmp/retrace-watchdog-sample.txt"
        let manager = CrashRecoveryManager.makeForTesting()
        await manager.configureBundledHelperForTesting(proxy: proxy)

        let captureTask = Task {
            await manager.captureWatchdogHangSample(
                trigger: "watchdog_auto_quit",
                timeoutMs: 500
            )
        }

        while proxy.hangSampleCallCount == 0 {
            await Task.yield()
        }

        await manager.simulateHelperConnectionLossForTesting(reason: "interrupted")
        XCTAssertEqual(proxy.armCallCount, 0)

        proxy.releaseBlockedHangSampleReply()
        let samplePath = await captureTask.value

        XCTAssertEqual(samplePath, "/tmp/retrace-watchdog-sample.txt")
        XCTAssertEqual(proxy.hangSampleCallCount, 1)
        XCTAssertEqual(proxy.armCallCount, 1)
        XCTAssertEqual(proxy.capturedHangSampleTrigger, "watchdog_auto_quit")
    }

    func testEmergencyDiagnosticsCaptureMergesHelperWatchdogSampleAndDeletesScratchFile() throws {
        let fileManager = FileManager.default
        let reportDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: reportDirectory) }

        let helperSampleURL = reportDirectory.appendingPathComponent("retrace-watchdog-sample-watchdog_auto_quit-2026-04-13_123000.txt")
        try """
        === RETRACE WATCHDOG HANG SAMPLE ===
        Trigger: watchdog_auto_quit
        Root Cause: main thread blocked in database write
        """.write(to: helperSampleURL, atomically: true, encoding: .utf8)

        let reportPath = try XCTUnwrap(
            EmergencyDiagnostics.capture(
                trigger: "watchdog_auto_quit",
                supplementalReportPaths: [helperSampleURL.path],
                cleanupSupplementalReports: true,
                directory: reportDirectory.path
            )
        )

        let reportContents = try String(contentsOfFile: reportPath, encoding: .utf8)
        XCTAssertTrue(reportContents.contains("=== RETRACE EMERGENCY DIAGNOSTIC ==="))
        XCTAssertTrue(reportContents.contains("--- HELPER WATCHDOG SAMPLE ---"))
        XCTAssertTrue(reportContents.contains("=== RETRACE WATCHDOG HANG SAMPLE ==="))
        XCTAssertTrue(reportContents.contains("Root Cause: main thread blocked in database write"))
        XCTAssertFalse(fileManager.fileExists(atPath: helperSampleURL.path))
    }

}
