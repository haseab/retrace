import XCTest
import Shared
@testable import Capture

final class CaptureTriggerSchedulingTests: XCTestCase {
    func testStartCaptureRejectsConfigurationWithoutAutomaticTriggers() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 13, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )

        do {
            try await manager.startCapture(
                config: testConfig(
                    captureIntervalSeconds: 0,
                    captureOnWindowChange: false,
                    captureOnMouseClick: false
                )
            )
            XCTFail("Expected invalid configuration error")
        } catch let error as CaptureError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("Unexpected capture error: \(error)")
            }
            XCTAssertEqual(reason, "At least one automatic capture trigger must be enabled.")
        }

        let isCapturing = await manager.isCapturing
        XCTAssertFalse(isCapturing)
    }

    func testUpdateConfigRejectsDisablingAllAutomaticTriggers() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 14, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 14, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )

        try await manager.startCapture(config: testConfig())
        defer {
            Task { try? await manager.stopCapture() }
        }

        do {
            try await manager.updateConfig(
                testConfig(
                    captureIntervalSeconds: 0,
                    captureOnWindowChange: false,
                    captureOnMouseClick: false
                )
            )
            XCTFail("Expected invalid configuration error")
        } catch let error as CaptureError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("Unexpected capture error: \(error)")
            }
            XCTAssertEqual(reason, "At least one automatic capture trigger must be enabled.")
        }

        let config = await manager.getConfig()
        XCTAssertEqual(config.captureIntervalSeconds, 1.0, accuracy: 0.0001)
        XCTAssertTrue(config.captureOnWindowChange)
        XCTAssertTrue(config.captureOnMouseClick)
    }

    func testMouseClickSchedulesExactlyOneCaptureAfterMouseUpSettleDelay() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 7, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 7, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseDown()
        try await sleep(milliseconds: 70)
        let captureCountBeforeMouseUp = await backend.captureCount()
        XCTAssertEqual(captureCountBeforeMouseUp, 0)

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 8)
        let earlyCaptureCount = await backend.captureCount()
        XCTAssertEqual(earlyCaptureCount, 0)

        try await sleep(milliseconds: 45)
        let captureDisplayIDs = await backend.captureDisplayIDs()
        let collectedFrameCount = await collector.count()
        XCTAssertEqual(captureDisplayIDs, [7])
        XCTAssertEqual(collectedFrameCount, 1)
    }

    func testMouseClickSuppressesPendingWindowChangeCapture() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 1, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 1, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            appInfoProvider: FakeAppInfoProvider(
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Window A",
                    displayID: 1
                )
            )
        )

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await displaySwitchMonitor.emitWindowChange()
        try await sleep(milliseconds: 10)
        await mouseClickMonitor.emitMouseUp()

        try await sleep(milliseconds: 90)
        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(collectedFrameCount, 1)
    }

    func testMouseClickSuppressesPendingIntervalAndResetsNextInterval() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(displayID: 3, pixelValue: 10),
                makeFrame(displayID: 3, pixelValue: 80)
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 3, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.02,
                mouseClickSettleDelay: 0.01,
                windowChangeSettleDelay: 0.03,
                startWithImmediateIntervalCapture: false
            )
        )

        try await manager.startCapture(
            config: testConfig(captureIntervalSeconds: 0.05)
        )
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        try await sleep(milliseconds: 40)
        await mouseClickMonitor.emitMouseUp()

        try await sleep(milliseconds: 25)
        let firstCaptureCount = await backend.captureCount()
        let firstCollectedFrameCount = await collector.count()
        XCTAssertEqual(firstCaptureCount, 1)
        XCTAssertEqual(firstCollectedFrameCount, 1)

        try await sleep(milliseconds: 70)
        let finalCaptureCount = await backend.captureCount()
        let finalCollectedFrameCount = await collector.count()
        XCTAssertEqual(finalCaptureCount, 2)
        XCTAssertEqual(finalCollectedFrameCount, 2)
    }

    func testMouseClickWithinRefractoryIsDroppedInsteadOfBuffered() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(displayID: 5, pixelValue: 10),
                makeFrame(displayID: 5, pixelValue: 80)
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 5, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let triggerRecorder = MouseClickOutcomeRecorder()
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.05,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.03,
                startWithImmediateIntervalCapture: false
            )
        )
        await manager.setTriggerRecorder(triggerRecorder)

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 15)
        await mouseClickMonitor.emitMouseUp()

        try await sleep(milliseconds: 20)
        let earlyCaptureCount = await backend.captureCount()
        XCTAssertEqual(earlyCaptureCount, 1)

        try await sleep(milliseconds: 50)
        let finalCaptureCount = await backend.captureCount()
        let hasDebouncedOutcome = await triggerRecorder.contains(outcome: .debounced)
        XCTAssertEqual(finalCaptureCount, 1)
        XCTAssertTrue(hasDebouncedOutcome)
    }

    func testMouseMonitorUnavailableDoesNotBlockWindowCapture() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 2, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 2, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: false)
        let triggerRecorder = MouseClickOutcomeRecorder()
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )
        await manager.setTriggerRecorder(triggerRecorder)

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await displaySwitchMonitor.emitWindowChange()
        try await sleep(milliseconds: 80)

        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        let hasMonitorUnavailableOutcome = await triggerRecorder.contains(outcome: .monitorUnavailable)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(collectedFrameCount, 1)
        XCTAssertTrue(hasMonitorUnavailableOutcome)
    }

    func testMouseClickMonitoringRetriesAfterPermissionGrantWithoutRestart() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 6, pixelValue: 10)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 6, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: false)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 80)
        let captureCountBeforeRetry = await backend.captureCount()
        XCTAssertEqual(captureCountBeforeRetry, 0)

        await mouseClickMonitor.setStartResult(true)
        await manager.retryMouseClickMonitoringIfNeeded()
        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 80)

        let captureCountAfterRetry = await backend.captureCount()
        let collectedFrameCountAfterRetry = await collector.count()
        XCTAssertEqual(captureCountAfterRetry, 1)
        XCTAssertEqual(collectedFrameCountAfterRetry, 1)
    }

    func testClickTriggeredDuplicateFrameReportsDedupedOutcome() async throws {
        let duplicate = makeFrame(displayID: 4, pixelValue: 10)
        let backend = FakeScreenCaptureBackend(frames: [duplicate, duplicate])
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 4, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let triggerRecorder = MouseClickOutcomeRecorder()
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.01,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.03,
                startWithImmediateIntervalCapture: false
            )
        )
        await manager.setTriggerRecorder(triggerRecorder)

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 20)
        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 30)

        let collectedFrameCount = await collector.count()
        let hasCapturedOutcome = await triggerRecorder.contains(outcome: .captured)
        let hasDedupedOutcome = await triggerRecorder.contains(outcome: .deduped)
        XCTAssertEqual(collectedFrameCount, 1)
        XCTAssertTrue(hasCapturedOutcome)
        XCTAssertTrue(hasDedupedOutcome)
    }

    func testMouseClickFallsBackToCurrentCaptureDisplayWithoutPermission() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [makeFrame(displayID: 11, pixelValue: 30)]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 22, hasPermission: false)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor
        )

        try await manager.startCapture(config: testConfig())
        defer {
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 80)

        let captureDisplayIDs = await backend.captureDisplayIDs()
        XCTAssertEqual(captureDisplayIDs, [22])
    }

    func testWindowChangeShortlyAfterMouseClickIsSuppressed() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(displayID: 9, pixelValue: 10),
                makeFrame(displayID: 9, pixelValue: 80)
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 9, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.06,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.01,
                startWithImmediateIntervalCapture: false
            )
        )

        try await manager.startCapture(config: testConfig())
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 20)
        await displaySwitchMonitor.emitWindowChange()
        try await sleep(milliseconds: 80)

        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(collectedFrameCount, 1)
    }

    func testOffCaptureIntervalDisablesPeriodicSchedulingButStillAllowsEventDrivenCapture() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(displayID: 12, pixelValue: 10),
                makeFrame(displayID: 12, pixelValue: 80)
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 12, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.02,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.01,
                startWithImmediateIntervalCapture: false
            )
        )

        try await manager.startCapture(config: testConfig(captureIntervalSeconds: 0))
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        try await sleep(milliseconds: 80)
        let captureCountBeforeEvents = await backend.captureCount()
        XCTAssertEqual(captureCountBeforeEvents, 0)

        await displaySwitchMonitor.emitWindowChange()
        try await sleep(milliseconds: 30)
        let captureCountAfterWindowChange = await backend.captureCount()
        XCTAssertEqual(captureCountAfterWindowChange, 1)

        try await sleep(milliseconds: 80)
        let captureCountWithoutPeriodicReschedule = await backend.captureCount()
        XCTAssertEqual(captureCountWithoutPeriodicReschedule, 1)

        await mouseClickMonitor.emitMouseUp()
        try await sleep(milliseconds: 20)
        let finalCaptureCount = await backend.captureCount()
        let finalCollectedFrameCount = await collector.count()
        XCTAssertEqual(finalCaptureCount, 2)
        XCTAssertEqual(finalCollectedFrameCount, 2)
    }

    private func makeManager(
        backend: FakeScreenCaptureBackend,
        displayMonitor: FakeDisplayMonitor,
        displaySwitchMonitor: FakeDisplaySwitchMonitor,
        mouseClickMonitor: FakeMouseClickMonitor,
        appInfoProvider: FakeAppInfoProvider = FakeAppInfoProvider(
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Window A",
                displayID: 1
            )
        ),
        schedulingConfiguration: CaptureSchedulingConfiguration = CaptureSchedulingConfiguration(
            minimumInterCaptureInterval: 0.02,
            mouseClickSettleDelay: 0.03,
            windowChangeSettleDelay: 0.06,
            startWithImmediateIntervalCapture: false
        )
    ) -> CaptureManager {
        CaptureManager(
            config: testConfig(),
            cgWindowListCapture: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            appInfoProvider: appInfoProvider,
            schedulingConfiguration: schedulingConfiguration
        )
    }

    private func testConfig(
        captureIntervalSeconds: Double = 1.0,
        captureOnWindowChange: Bool = true,
        captureOnMouseClick: Bool = true
    ) -> CaptureConfig {
        CaptureConfig(
            captureIntervalSeconds: captureIntervalSeconds,
            adaptiveCaptureEnabled: true,
            deduplicationThreshold: CaptureConfig.defaultDeduplicationThreshold,
            keepFramesOnMouseMovement: false,
            maxResolution: .hd1080,
            excludedAppBundleIDs: [],
            excludePrivateWindows: false,
            showCursor: true,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )
    }

    private func makeFrame(
        displayID: UInt32,
        pixelValue: UInt8,
        timestamp: Date = Date()
    ) -> CapturedFrame {
        let width = 4
        let height = 4
        let bytesPerRow = width * 4
        let imageData = Data(repeating: pixelValue, count: bytesPerRow * height)
        return CapturedFrame(
            timestamp: timestamp,
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(displayID: displayID)
        )
    }

    private func collectFrames(
        from stream: AsyncStream<CapturedFrame>,
        into collector: FrameCollector
    ) -> Task<Void, Never> {
        Task {
            for await frame in stream {
                await collector.append(frame)
            }
        }
    }

    private func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds), clock: .continuous)
    }
}

final class MouseClickMonitorTests: XCTestCase {
    func testStartMonitoringDoesNotRequireAccessibilityTrust() async throws {
        let launcher = MouseClickMonitorLaunchRecorder()
        let monitor = MouseClickMonitor(
            dependencies: .init(
                hasListenEventAccess: { true },
                makeSession: { _ in
                    TestMouseClickTapSession(
                        mode: .immediate(true),
                        launchRecorder: launcher
                    )
                }
            )
        )

        let started = await monitor.startMonitoring()
        let launchCount = await launcher.launchCount()
        XCTAssertTrue(started)
        XCTAssertEqual(launchCount, 1)

        await monitor.stopMonitoring()
    }

    func testConcurrentStartsShareSingleSetupAttempt() async throws {
        let launcher = MouseClickMonitorLaunchRecorder()
        let monitor = MouseClickMonitor(
            dependencies: .init(
                hasListenEventAccess: { true },
                makeSession: { _ in
                    TestMouseClickTapSession(
                        mode: .delayed(milliseconds: 20, result: true),
                        launchRecorder: launcher
                    )
                }
            )
        )

        async let first = monitor.startMonitoring()
        async let second = monitor.startMonitoring()

        let firstStarted = await first
        let secondStarted = await second
        let launchCount = await launcher.launchCount()
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(launchCount, 1)

        await monitor.stopMonitoring()
    }

    func testStopMonitoringCancelsInFlightSetup() async throws {
        let launcher = MouseClickMonitorLaunchRecorder()
        let monitor = MouseClickMonitor(
            dependencies: .init(
                hasListenEventAccess: { true },
                makeSession: { _ in
                    TestMouseClickTapSession(
                        mode: .manual,
                        launchRecorder: launcher
                    )
                }
            )
        )

        let startTask = Task {
            await monitor.startMonitoring()
        }

        try await Task.sleep(for: .milliseconds(20), clock: .continuous)
        await monitor.stopMonitoring()

        let started = await startTask.value
        let launchCount = await launcher.launchCount()
        XCTAssertFalse(started)
        XCTAssertEqual(launchCount, 1)
    }
}

private actor FakeScreenCaptureBackend: ScreenCaptureBackend {
    private var frames: [CapturedFrame]
    private var displayIDs: [UInt32] = []

    init(frames: [CapturedFrame]) {
        self.frames = frames
    }

    func startCapture(config: CaptureConfig, displayID: CGDirectDisplayID?) async throws {}
    func stopCapture() async throws {}
    func updateConfig(_ config: CaptureConfig) async throws {}

    func captureFrame(displayID: CGDirectDisplayID) async -> CapturedFrame? {
        displayIDs.append(displayID)
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func captureCount() -> Int {
        displayIDs.count
    }

    func captureDisplayIDs() -> [UInt32] {
        displayIDs
    }
}

private actor FakeDisplayMonitor: CaptureDisplayMonitoring {
    private let activeDisplayID: UInt32
    private let hasPermission: Bool

    init(activeDisplayID: UInt32, hasPermission: Bool) {
        self.activeDisplayID = activeDisplayID
        self.hasPermission = hasPermission
    }

    func getAvailableDisplays() async throws -> [DisplayInfo] {
        [
            DisplayInfo(
                id: activeDisplayID,
                width: 100,
                height: 100,
                scaleFactor: 1,
                isMain: true,
                name: "Test"
            )
        ]
    }

    func getFocusedDisplay() async throws -> DisplayInfo? {
        (try await getAvailableDisplays()).first
    }

    func getActiveDisplayID() -> UInt32 {
        activeDisplayID
    }

    func getActiveDisplayIDWithPermissionStatus() -> (UInt32, Bool) {
        (activeDisplayID, hasPermission)
    }
}

private actor FakeDisplaySwitchMonitor: CaptureDisplaySwitchMonitoring {
    private var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?
    private var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?
    private var onWindowChange: (@Sendable () async -> Void)?

    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?) {
        onDisplaySwitch = callback
    }

    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?) {
        onAccessibilityPermissionDenied = callback
    }

    func setOnWindowChange(_ callback: (@Sendable () async -> Void)?) {
        onWindowChange = callback
    }

    func startMonitoring(initialDisplayID: UInt32) {}
    func stopMonitoring() async {}

    func emitWindowChange() async {
        await onWindowChange?()
    }
}

private actor FakeMouseClickMonitor: CaptureMouseClickMonitoring {
    private var startResult: Bool
    private var mouseUpCallback: (@Sendable () async -> Void)?
    private var isMonitoring = false

    init(startResult: Bool) {
        self.startResult = startResult
    }

    func setOnLeftMouseUp(_ callback: (@Sendable () async -> Void)?) {
        mouseUpCallback = callback
    }

    func startMonitoring() async -> Bool {
        isMonitoring = startResult
        return startResult
    }

    func stopMonitoring() async {
        isMonitoring = false
    }

    func setStartResult(_ startResult: Bool) {
        self.startResult = startResult
    }

    func emitMouseDown() async {}

    func emitMouseUp() async {
        guard isMonitoring else { return }
        await mouseUpCallback?()
    }
}

private struct FakeAppInfoProvider: CaptureAppInfoProviding {
    let metadata: FrameMetadata

    func getFrontmostAppInfo(
        includeBrowserURL: Bool,
        preferredDisplayID: CGDirectDisplayID?
    ) async -> FrameMetadata {
        metadata
    }
}

private actor FrameCollector {
    private var frames: [CapturedFrame] = []

    func append(_ frame: CapturedFrame) {
        frames.append(frame)
    }

    func count() -> Int {
        frames.count
    }
}

private actor MouseClickOutcomeRecorder {
    private var outcomes: [MouseClickCaptureOutcome] = []

    func append(_ outcome: MouseClickCaptureOutcome) {
        outcomes.append(outcome)
    }

    func contains(outcome: MouseClickCaptureOutcome) -> Bool {
        outcomes.contains(outcome)
    }
}

private actor MouseClickMonitorLaunchRecorder {
    private var launchCountValue = 0

    func recordLaunch() {
        launchCountValue += 1
    }

    func launchCount() -> Int {
        launchCountValue
    }
}

private extension CaptureManager {
    func setTriggerRecorder(_ recorder: MouseClickOutcomeRecorder) {
        onMouseClickCaptureOutcome = { outcome, _ in
            await recorder.append(outcome)
        }
    }
}

private final class TestMouseClickTapSession: MouseClickTapSessionControlling, @unchecked Sendable {
    enum Mode {
        case immediate(Bool)
        case delayed(milliseconds: Int, result: Bool)
        case manual
    }

    private let mode: Mode
    private let launchRecorder: MouseClickMonitorLaunchRecorder
    private let stateLock = NSLock()
    private var startContinuation: CheckedContinuation<Bool, Never>?

    init(
        mode: Mode,
        launchRecorder: MouseClickMonitorLaunchRecorder
    ) {
        self.mode = mode
        self.launchRecorder = launchRecorder
    }

    func start() async -> Bool {
        await launchRecorder.recordLaunch()

        switch mode {
        case let .immediate(result):
            return result
        case let .delayed(milliseconds, result):
            return await withCheckedContinuation { continuation in
                storeContinuation(continuation)
                Task {
                    try? await Task.sleep(for: .milliseconds(milliseconds), clock: .continuous)
                    self.resumeStartIfNeeded(result)
                }
            }
        case .manual:
            return await withCheckedContinuation { continuation in
                storeContinuation(continuation)
            }
        }
    }

    func stop() async {
        resumeStartIfNeeded(false)
    }

    private func storeContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        stateLock.lock()
        startContinuation = continuation
        stateLock.unlock()
    }

    private func resumeStartIfNeeded(_ result: Bool) {
        stateLock.lock()
        let continuation = startContinuation
        startContinuation = nil
        stateLock.unlock()

        continuation?.resume(returning: result)
    }
}
