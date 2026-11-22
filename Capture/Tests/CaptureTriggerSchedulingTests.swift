import XCTest
import ImageIO
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

    func testWindowChangeKeepsLatestAppActivationWhileEarlierEvaluationIsInFlight() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(
                    displayID: 15,
                    pixelValue: 20,
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Docs"
                )
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 15, hasPermission: true)
        let displaySwitchMonitor = FakeDisplaySwitchMonitor()
        let mouseClickMonitor = FakeMouseClickMonitor(startResult: true)
        let collector = FrameCollector()
        let firstLookupGate = AsyncGate()
        let manager = makeManager(
            backend: backend,
            displayMonitor: displayMonitor,
            displaySwitchMonitor: displaySwitchMonitor,
            mouseClickMonitor: mouseClickMonitor,
            appInfoProvider: BlockingSequencedFakeAppInfoProvider(
                responses: [
                    FrameMetadata(
                        appBundleID: "com.apple.Safari",
                        appName: "Safari",
                        windowName: "Inbox",
                        displayID: 15
                    ),
                    FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Google Chrome",
                        windowName: "Docs",
                        displayID: 15
                    )
                ],
                firstLookupGate: firstLookupGate
            ),
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.02,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.005,
                startWithImmediateIntervalCapture: false
            )
        )

        try await manager.startCapture(
            config: testConfig(
                captureIntervalSeconds: 0,
                captureOnMouseClick: false
            )
        )
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        let firstEventTask = Task {
            await displaySwitchMonitor.emitActivationWindowChange(
                bundleID: "com.apple.Safari",
                appName: "Safari"
            )
        }
        try await sleep(milliseconds: 10)
        await displaySwitchMonitor.emitActivationWindowChange(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome"
        )
        await firstLookupGate.open()
        await firstEventTask.value

        try await sleep(milliseconds: 40)
        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        let lastCollectedFrame = await collector.lastFrame()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(collectedFrameCount, 1)
        XCTAssertEqual(lastCollectedFrame?.metadata.appBundleID, "com.google.Chrome")
        XCTAssertEqual(lastCollectedFrame?.metadata.windowName, "Docs")
    }

    func testActivationWindowChangeDropsFrameWhenCapturedMetadataDisagrees() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(
                    displayID: 16,
                    pixelValue: 30,
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Docs"
                )
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 16, hasPermission: true)
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
                    windowName: "Inbox",
                    displayID: 16
                )
            )
        )

        try await manager.startCapture(
            config: testConfig(
                captureIntervalSeconds: 0,
                captureOnMouseClick: false
            )
        )
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await displaySwitchMonitor.emitActivationWindowChange(
            bundleID: "com.apple.Safari",
            appName: "Safari"
        )

        try await sleep(milliseconds: 30)
        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(collectedFrameCount, 0)
    }

    func testActivationWindowChangeRetryAfterDroppedCaptureStillSchedulesLaterRetry() async throws {
        let backend = FakeScreenCaptureBackend(
            frames: [
                makeFrame(
                    displayID: 17,
                    pixelValue: 30,
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Docs"
                ),
                makeFrame(
                    displayID: 17,
                    pixelValue: 60,
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Inbox"
                )
            ]
        )
        let displayMonitor = FakeDisplayMonitor(activeDisplayID: 17, hasPermission: true)
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
                    windowName: "Inbox",
                    displayID: 17
                )
            ),
            schedulingConfiguration: CaptureSchedulingConfiguration(
                minimumInterCaptureInterval: 0.02,
                mouseClickSettleDelay: 0.005,
                windowChangeSettleDelay: 0.005,
                startWithImmediateIntervalCapture: false
            )
        )

        try await manager.startCapture(
            config: testConfig(
                captureIntervalSeconds: 0,
                captureOnMouseClick: false
            )
        )
        let stream = await manager.frameStream
        let streamTask = collectFrames(from: stream, into: collector)
        defer {
            streamTask.cancel()
            Task { try? await manager.stopCapture() }
        }

        await displaySwitchMonitor.emitActivationWindowChange(
            bundleID: "com.apple.Safari",
            appName: "Safari"
        )
        try await sleep(milliseconds: 35)
        await displaySwitchMonitor.emitActivationWindowChange(
            bundleID: "com.apple.Safari",
            appName: "Safari"
        )

        try await sleep(milliseconds: 45)
        let captureCount = await backend.captureCount()
        let collectedFrameCount = await collector.count()
        XCTAssertEqual(captureCount, 2)
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

    func testNativeScreenshotCandidatesPreserveDuplicateAndDimensionChangeDecisions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width / 2, height: image.height)))
        let backend = FakeScreenCaptureBackend(candidates: [image, image, crop].enumerated().map {
            CaptureFrameCandidate(image: $0.element, timestamp: Date().addingTimeInterval(Double($0.offset)), metadata: FrameMetadata(displayID: 1))
        })
        let clicks = FakeMouseClickMonitor(startResult: true)
        let manager = makeManager(backend: backend, displayMonitor: FakeDisplayMonitor(activeDisplayID: 1, hasPermission: true), displaySwitchMonitor: FakeDisplaySwitchMonitor(), mouseClickMonitor: clicks)
        try await manager.startCapture(config: testConfig(captureIntervalSeconds: 0, captureOnWindowChange: false))
        for expected in 1...3 {
            await clicks.emitMouseUp()
            for _ in 0..<100 {
                if await manager.getStatistics().totalFramesCaptured >= expected { break }
                try await sleep(milliseconds: 20)
            }
        }
        let stats = await manager.getStatistics()
        XCTAssertEqual(stats.totalFramesCaptured, 3)
        XCTAssertEqual(stats.framesDeduped, 1)
        try await manager.stopCapture()
    }

    func testFullQueuePausesCaptureUntilConsumerPullsAndStopReleasesProducer() async throws {
        let backend = FakeScreenCaptureBackend(frames: (0..<24).map {
            makeFrame(displayID: 13, pixelValue: UInt8($0), timestamp: Date(timeIntervalSince1970: Double($0)))
        })
        let manager = makeManager(backend: backend,
            displayMonitor: FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true),
            displaySwitchMonitor: FakeDisplaySwitchMonitor(),
            mouseClickMonitor: FakeMouseClickMonitor(startResult: true))
        let config = testConfig(captureIntervalSeconds: 0.04, captureOnWindowChange: false, captureOnMouseClick: false,
                                adaptiveCaptureEnabled: false)
        try await manager.startCapture(config: config)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10), clock: .continuous) }
            catch { return }
            try? await manager.stopCapture()
        }
        defer { watchdog.cancel() }
        let stream = await manager.frameStream
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await backend.captureCount() < 9, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        let blockedCount = await backend.captureCount()
        guard blockedCount == 9 else {
            try await manager.stopCapture()
            return XCTFail("Expected eight queued frames and one suspended capture; got \(blockedCount) captures")
        }
        var iterator = stream.makeAsyncIterator()
        for sequence in 0..<12 {
            let frame = await iterator.next()
            XCTAssertEqual(frame?.timestamp, Date(timeIntervalSince1970: Double(sequence)))
        }
        // Fill the queue again and stop with no consumer pulling. This must wake
        // the producer instead of holding shutdown hostage to storage progress.
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await backend.captureCount() < 21, ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        let secondBlockedCount = await backend.captureCount()
        XCTAssertEqual(secondBlockedCount, 21)
        try await manager.stopCapture()
        let finished = await iterator.next()
        XCTAssertNil(finished)
        // An old suspended producer must not contaminate a restarted stream.
        try await manager.startCapture(config: config)
        var restartedIterator = await manager.frameStream.makeAsyncIterator()
        let restarted = await restartedIterator.next()
        XCTAssertEqual(restarted?.timestamp, Date(timeIntervalSince1970: 21))
        try await manager.stopCapture()
    }

    func testEmptyDisplayDiscoveryKeepsPeriodicRetriesAlive() async throws {
        let backend = FakeScreenCaptureBackend(frames: [])
        let monitor = FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true, emptyDisplayList: true)
        let manager = makeManager(backend: backend, displayMonitor: monitor,
            displaySwitchMonitor: FakeDisplaySwitchMonitor(), mouseClickMonitor: FakeMouseClickMonitor(startResult: true))
        let config = testConfig(captureIntervalSeconds: 0.04, captureOnWindowChange: false, captureOnMouseClick: false)
            .updating(recordAllDisplays: true)
        try await manager.startCapture(config: config)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await monitor.discoveryCount() < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        let attempts = await monitor.discoveryCount()
        try await manager.stopCapture()
        XCTAssertGreaterThanOrEqual(attempts, 3)
    }

    func testGracefulStopWaitsForPersistenceAndDrainsTheInFlightScreenshot() async throws {
        let backend = FakeScreenCaptureBackend(frames: [makeFrame(displayID: 13, pixelValue: 10)])
        let manager = makeManager(backend: backend,
            displayMonitor: FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true),
            displaySwitchMonitor: FakeDisplaySwitchMonitor(), mouseClickMonitor: FakeMouseClickMonitor(startResult: true))
        let gate = AsyncGate()
        let persistenceStarted = FrameCollector()
        await manager.setFramePersistenceHandler { frame in
            await persistenceStarted.append(frame)
            await gate.wait()
            return frame
        }
        try await manager.startCapture(config: testConfig(captureIntervalSeconds: 0.04,
            captureOnWindowChange: false, captureOnMouseClick: false))
        let stream = await manager.frameStream
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await persistenceStarted.count() == 0, ContinuousClock.now < deadline { await Task.yield() }
        let count = await persistenceStarted.count()
        XCTAssertEqual(count, 1)
        let stop = Task { try await manager.stopCapture(drain: true) }
        while await manager.isCapturing { await Task.yield() }
        await gate.open()
        try await stop.value
        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()
        XCTAssertNotNil(frame)
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testPersistenceFailureDoesNotAdmitAnUnjournaledScreenshot() async throws {
        let backend = FakeScreenCaptureBackend(frames: [makeFrame(displayID: 13, pixelValue: 10)])
        let manager = makeManager(backend: backend,
            displayMonitor: FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true),
            displaySwitchMonitor: FakeDisplaySwitchMonitor(), mouseClickMonitor: FakeMouseClickMonitor(startResult: true))
        await manager.setFramePersistenceHandler { _ in throw StorageError.insufficientDiskSpace }
        try await manager.startCapture(config: testConfig(captureIntervalSeconds: 0.04,
            captureOnWindowChange: false, captureOnMouseClick: false))
        var iterator = await manager.frameStream.makeAsyncIterator()
        let frame = await iterator.next()
        XCTAssertNil(frame)
        let running = await manager.isCapturing
        XCTAssertFalse(running)
    }

    func testEmergencyAbortReleasesAFullQueueDuringNormalDrain() async throws {
        let backend = FakeScreenCaptureBackend(frames: (0..<12).map {
            makeFrame(displayID: 13, pixelValue: UInt8($0))
        })
        let manager = makeManager(backend: backend,
            displayMonitor: FakeDisplayMonitor(activeDisplayID: 13, hasPermission: true),
            displaySwitchMonitor: FakeDisplaySwitchMonitor(), mouseClickMonitor: FakeMouseClickMonitor(startResult: true))
        try await manager.startCapture(config: testConfig(captureIntervalSeconds: 0.04,
            captureOnWindowChange: false, captureOnMouseClick: false, adaptiveCaptureEnabled: false))
        let stream = await manager.frameStream
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await backend.captureCount() < 9, ContinuousClock.now < deadline { await Task.yield() }
        let count = await backend.captureCount()
        XCTAssertEqual(count, 9)
        let drain = Task { try await manager.stopCapture(drain: true) }
        while await manager.isCapturing { await Task.yield() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(3), clock: .continuous) }
            catch { return }
            XCTFail("Emergency abort did not release the draining producer")
            var fallback = stream.makeAsyncIterator()
            _ = await fallback.next()
        }
        defer { watchdog.cancel() }
        try await manager.stopCapture() // explicit emergency/abort path
        try await drain.value
        var iterator = stream.makeAsyncIterator()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    private func makeManager(
        backend: FakeScreenCaptureBackend,
        displayMonitor: FakeDisplayMonitor,
        displaySwitchMonitor: FakeDisplaySwitchMonitor,
        mouseClickMonitor: FakeMouseClickMonitor,
        appInfoProvider: any CaptureAppInfoProviding = FakeAppInfoProvider(
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
            schedulingConfiguration: schedulingConfiguration,
            permissionCheck: { true }
        )
    }

    private func testConfig(
        captureIntervalSeconds: Double = 1.0,
        captureOnWindowChange: Bool = true,
        captureOnMouseClick: Bool = true,
        adaptiveCaptureEnabled: Bool = true
    ) -> CaptureConfig {
        CaptureConfig(
            captureIntervalSeconds: captureIntervalSeconds,
            adaptiveCaptureEnabled: adaptiveCaptureEnabled,
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
        appBundleID: String? = nil,
        appName: String? = nil,
        windowName: String? = nil,
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
            metadata: FrameMetadata(
                appBundleID: appBundleID,
                appName: appName,
                windowName: windowName,
                displayID: displayID
            )
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
    private var candidates: [CaptureFrameCandidate] = []
    private var frames: [CapturedFrame]
    private var displayIDs: [UInt32] = []

    init(frames: [CapturedFrame]) {
        self.frames = frames
    }

    init(candidates: [CaptureFrameCandidate]) {
        frames = []
        self.candidates = candidates
    }

    func captureCandidate(displayID: CGDirectDisplayID) async -> CaptureFrameCandidate? {
        if !candidates.isEmpty {
            displayIDs.append(displayID)
            return candidates.removeFirst()
        }
        return await captureFrame(displayID: displayID).map { CaptureFrameCandidate(frame: $0) }
    }

    func startCapture(config: CaptureConfig, displayID: CGDirectDisplayID?) async throws {}
    func stopCapture() async throws {}
    func updateConfig(_ config: CaptureConfig) async throws {}
    func disableFaceBlurForConferenceCall(callID: String) async -> Bool { true }
    func setOnConferenceFramePrivacyEvent(
        _ callback: (@Sendable (ConferenceFramePrivacyEvent) async -> Void)?
    ) async {}

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
    private let emptyDisplayList: Bool
    private var discoveries = 0
    func discoveryCount() -> Int { discoveries }

    init(activeDisplayID: UInt32, hasPermission: Bool, emptyDisplayList: Bool = false) {
        self.activeDisplayID = activeDisplayID
        self.hasPermission = hasPermission
        self.emptyDisplayList = emptyDisplayList
    }

    func getAvailableDisplays() async throws -> [DisplayInfo] {
        discoveries += 1
        if emptyDisplayList { return [] }
        return [
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
    private var onWindowChange: (@Sendable (WindowChangeEvent) async -> Void)?
    private var nextEventID: UInt64 = 0

    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?) {
        onDisplaySwitch = callback
    }

    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?) {
        onAccessibilityPermissionDenied = callback
    }

    func setOnWindowChange(_ callback: (@Sendable (WindowChangeEvent) async -> Void)?) {
        onWindowChange = callback
    }

    func startMonitoring(initialDisplayID: UInt32) {}
    func stopMonitoring() async {}

    func emitWindowChange() async {
        nextEventID += 1
        await onWindowChange?(
            WindowChangeEvent(
                id: nextEventID,
                source: .axActivation,
                observedAt: Date(),
                activatedApp: nil,
                workspaceFrontmostApp: nil
            )
        )
    }

    func emitActivationWindowChange(bundleID: String, appName: String) async {
        nextEventID += 1
        let activatedApp = CaptureAppSnapshot(
            name: appName,
            bundleID: bundleID,
            pid: 42
        )
        await onWindowChange?(
            WindowChangeEvent(
                id: nextEventID,
                source: .appActivation,
                observedAt: Date(),
                activatedApp: activatedApp,
                workspaceFrontmostApp: activatedApp
            )
        )
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

private actor BlockingSequencedFakeAppInfoProvider: CaptureAppInfoProviding {
    private var responses: [FrameMetadata]
    let firstLookupGate: AsyncGate

    init(responses: [FrameMetadata], firstLookupGate: AsyncGate) {
        self.responses = responses
        self.firstLookupGate = firstLookupGate
    }

    private var lookupCount = 0

    func getFrontmostAppInfo(
        includeBrowserURL: Bool,
        preferredDisplayID: CGDirectDisplayID?
    ) async -> FrameMetadata {
        lookupCount += 1
        let lookupNumber = lookupCount
        if lookupNumber == 1 {
            await firstLookupGate.wait()
        }
        guard let firstResponse = responses.first else {
            return FrameMetadata(displayID: preferredDisplayID ?? 0)
        }
        if responses.count > 1 {
            responses.removeFirst()
        }
        return firstResponse
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

    func lastFrame() -> CapturedFrame? {
        frames.last
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
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
