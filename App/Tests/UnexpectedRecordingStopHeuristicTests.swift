import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Shared
import Storage
@testable import App

final class UnexpectedRecordingStopHeuristicTests: XCTestCase {
    func testRunningPipelineRecoversAfterWALPermissionFailure() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false)
    }

    func testRunningPipelineRecoversAfterWriterCancellation() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: true)
    }

    func testRunningPipelineRecoversAfterMissingWALFile() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false, removeJournal: true)
    }

    func testRunningPipelineRetriesPersistentStorageFailureUntilRestored() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false, persistent: true)
    }

    func testUserStopCancelsPersistentStorageRetries() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false, persistent: true, userStop: true)
    }

    func testRetryDropsCaptureWhenTimelineWasOpenedDuringOutage() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false, persistent: true, privacyPause: true)
    }

    func testJournaledPipelineRecoversAfterWriterCancellation() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: true, useJournal: true)
    }

    func testCaptureIngressRetriesStorageOutageWithoutStoppingRecorder() async throws {
        try await exerciseRunningPipelineFailure(cancelWriter: false, persistent: true, useJournal: true, journalIngress: true)
    }

    private func exerciseRunningPipelineFailure(cancelWriter: Bool, removeJournal: Bool = false, persistent: Bool = false, userStop: Bool = false, privacyPause: Bool = false, useJournal: Bool = false, journalIngress: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetracePipelineProbe_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("wal").path)
            try? FileManager.default.removeItem(at: root)
        }
        let suite = "example.retrace.pipeline-probe.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = ServiceContainer(
            databasePath: root.appendingPathComponent("retrace.db").path,
            storageConfig: StorageConfig(storageRootPath: root.path, retentionDays: nil, maxStorageGB: nil),
            storageCrashReportDirectory: root.appendingPathComponent("diagnostics").path
        )
        try await services.database.initialize()
        try await services.ftsEngine.initialize()
        try await services.storage.initialize(config: StorageConfig(storageRootPath: root.path, retentionDays: nil, maxStorageGB: nil))
        await services.prepareProcessingQueueForTesting()
        let coordinator = AppCoordinator(
            services: services,
            recordingDefaults: defaults,
            timelineStillDirectory: root.appendingPathComponent("stills")
        )
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        defer { continuation.finish() }
        let frame = try pipelineProbeFrame()
        let journalStorage = await services.storage
        let journal = CaptureWALJournal(storage: journalStorage)
        var ingressTask: Task<Void, Never>?
        defer { ingressTask?.cancel() }
        do {
            await coordinator.startPipelineForTesting(frameStream: stream, journal: useJournal ? journal : nil)
            let started = await coordinator.getStatus()
            XCTAssertTrue(started.isRunning)
            XCTAssertTrue(defaults.bool(forKey: "shouldAutoStartRecording"))
            continuation.yield(useJournal ? try await journal.persist(frame) : frame)
            try await waitForPipelineProbe { await coordinator.getStatus().framesProcessed >= 1 }

            let beforeFailure = try await services.database.getFrameCount()
            XCTAssertEqual(beforeFailure, 1)
            let stopNotification = expectation(forNotification: RecordingUnexpectedStopNotification.didStop, object: nil)
            stopNotification.isInverted = true
            let queuedReceipt = journalIngress ? try await journal.persist(pipelineProbeFrame()) : nil
            let backlogCount = journalIngress ? 1 : 0
            if cancelWriter {
                await coordinator.debugInterruptEncodingPipeline()
            } else {
                let journal = try XCTUnwrap(
                    FileManager.default.enumerator(at: root.appendingPathComponent("wal"), includingPropertiesForKeys: nil)?
                        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "frames.bin" }
                )
                // The current WAL caches append handles. Evict the active one
                // before changing its path/permissions so the next append uses
                // the actual filesystem rather than an already-open descriptor.
                let wal = await services.storage.getWALManager()
                var evictions: [WALSession] = []
                for offset in 0..<8 {
                    var session = try await wal.createSession(videoID: VideoSegmentID(value: Int64(9_000_000 + offset)))
                    try await wal.appendFrame(frame, to: &session)
                    evictions.append(session)
                }
                for session in evictions { try await wal.finalizeSession(session) }
                if removeJournal {
                    try FileManager.default.removeItem(at: journal)
                } else {
                    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: journal.path)
                }
            }
            if persistent {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("wal").path)
            }
            let pendingFrame = try pipelineProbeFrame()
            if journalIngress {
                ingressTask = Task {
                    if let persisted = await coordinator.persistCapturedFrameWithRecovery(pendingFrame, journal: journal) {
                        continuation.yield(persisted)
                    }
                }
            } else {
                continuation.yield(useJournal ? try await journal.persist(pendingFrame) : pendingFrame)
            }
            try await waitForPipelineProbe { coordinator.statusHolder.status.isInterrupted }
            if let queuedReceipt {
                continuation.yield(queuedReceipt)
                try await waitForPipelineProbe { await coordinator.getStatus().framesProcessed >= 2 }
                XCTAssertTrue(coordinator.statusHolder.status.isInterrupted, "Draining an older receipt must not hide an ingress outage")
            }
            XCTAssertTrue(coordinator.statusHolder.status.isRunning)
            XCTAssertTrue(defaults.bool(forKey: "shouldAutoStartRecording"))
            if persistent {
                try await waitForPipelineProbe { coordinator.statusHolder.status.errors >= 2 }
                XCTAssertTrue(coordinator.statusHolder.status.isInterrupted)
                let duringFailure = try await services.database.getFrameCount()
                XCTAssertEqual(duringFailure, beforeFailure + backlogCount)
                if privacyPause {
                    await coordinator.setTimelineVisible(true)
                    await coordinator.setTimelineVisible(false)
                }
                if userStop {
                    continuation.finish()
                    try await coordinator.stopPipeline()
                    XCTAssertFalse(coordinator.statusHolder.status.isRunning)
                    XCTAssertFalse(coordinator.statusHolder.status.isInterrupted)
                    XCTAssertFalse(defaults.bool(forKey: "shouldAutoStartRecording"))
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("wal").path)
            }
            if privacyPause {
                continuation.yield(try pipelineProbeFrame())
                try await waitForPipelineProbe { await coordinator.getStatus().framesProcessed >= 2 + backlogCount }
                try await Task.sleep(for: .milliseconds(100))
                let afterPrivacyChange = try await services.database.getFrameCount()
                XCTAssertEqual(afterPrivacyChange, 2, "The pre-timeline pending capture must not be retried")
            }
            if !userStop {
                try await waitForPipelineProbe { await coordinator.getStatus().framesProcessed >= 2 + backlogCount }
                XCTAssertTrue(coordinator.statusHolder.status.isRunning)
                XCTAssertFalse(coordinator.statusHolder.status.isInterrupted)
                XCTAssertTrue(defaults.bool(forKey: "shouldAutoStartRecording"))
                continuation.yield(try pipelineProbeFrame())
                try await waitForPipelineProbe { await coordinator.getStatus().framesProcessed >= 3 + backlogCount }
                let afterRecovery = try await services.database.getFrameCount()
                XCTAssertEqual(afterRecovery, 3 + backlogCount, "Retry must neither lose nor duplicate the failed frame")
                let unexpectedStop = await coordinator.getUnexpectedRecordingStopState()
                XCTAssertNil(unexpectedStop)
                let sessions = try await services.storage.getWALManager().listActiveSessions()
                XCTAssertFalse(sessions.isEmpty, "Recovery journals must survive writer replacement")
                let events = try await services.database.getRecentMetricEvents(limit: 20)
                let transitions = events.filter { $0.metricType.rawValue == "recording_recovery_action" }
                XCTAssertEqual(transitions.count, 2, "Record transitions, not each retry")
                XCTAssertTrue(transitions.contains { $0.metadata?.contains("interrupted") == true })
                XCTAssertTrue(transitions.contains { $0.metadata?.contains("resumed") == true })

            } else {
                continuation.yield(frame)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(coordinator.statusHolder.status.isRunning)
            }
            await fulfillment(of: [stopNotification], timeout: 0.15)
            let failure = cancelWriter ? "cancelled_writer" : (removeJournal ? "missing_wal" : "readonly_wal")
            print("[PipelineProbe] \(failure): persistent=\(persistent) user_stop=\(userStop) automatic_recovery=\(!userStop)")
            if !userStop {
                continuation.finish()
                try await coordinator.stopPipeline()
            }
            if useJournal {
                try await coordinator.runCrashRecoveryForTesting()
                let recoveredCount = try await services.database.getFrameCount()
                XCTAssertEqual(recoveredCount, 3 + backlogCount, "Replaying a failed receipt must not duplicate frames during recovery")
            }

        } catch {
            ingressTask?.cancel()
            continuation.finish()
            try? await coordinator.stopPipeline(persistState: false)
            await coordinator.waitForPipelineForTesting()
            try? await coordinator.shutdown()
            try? await services.ftsEngine.close()
            try? await services.database.close()
            throw error
        }
        ingressTask?.cancel()
        await ingressTask?.value
        continuation.finish()
        await coordinator.waitForPipelineForTesting()
        try await coordinator.shutdown()
        try await services.ftsEngine.close()
        try await services.database.close()
    }

    private func waitForPipelineProbe(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for recording pipeline")
                throw NSError(domain: "PipelineProbe", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pipelineProbeFrame() throws -> CapturedFrame {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = 128, height = 128, stride = 128 * 4
        var pixels = Data(count: stride * height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CapturedFrame(imageData: pixels, width: width, height: height, bytesPerRow: stride, metadata: FrameMetadata(appBundleID: "com.example.capture", appName: "Example", windowName: "Probe"))
    }

    func testTimelineCaptureRejectsDelayedFramesAfterTimelineCloses() {
        let closedAt = Date(timeIntervalSince1970: 1_000)
        // Capture delivery can finish after close (title stability alone waits 650ms).
        XCTAssertTrue(AppCoordinator.shouldSuppressTimelineCapture(
            capturedAt: closedAt.addingTimeInterval(-0.5),
            isTimelineVisible: false,
            lastTimelineHiddenAt: closedAt
        ))
        XCTAssertTrue(AppCoordinator.shouldSuppressTimelineCapture(
            capturedAt: closedAt,
            isTimelineVisible: false,
            lastTimelineHiddenAt: closedAt
        ))
        XCTAssertFalse(AppCoordinator.shouldSuppressTimelineCapture(
            capturedAt: closedAt.addingTimeInterval(0.5),
            isTimelineVisible: false,
            lastTimelineHiddenAt: closedAt
        ))
    }

    func testTimelineCapturePausesWhileVisibleAndAllowsFramesBeforeFirstOpen() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(AppCoordinator.shouldSuppressTimelineCapture(
            capturedAt: capturedAt,
            isTimelineVisible: true,
            lastTimelineHiddenAt: nil
        ))
        XCTAssertFalse(AppCoordinator.shouldSuppressTimelineCapture(
            capturedAt: capturedAt,
            isTimelineVisible: false,
            lastTimelineHiddenAt: nil
        ))
    }

    func testUnexpectedCaptureTerminationRequiresRecordingToStillBeMarkedRunning() {
        XCTAssertTrue(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: false,
                isCaptureActive: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: false,
                taskWasCancelled: false,
                isCaptureActive: false
            )
        )
    }

    func testUnexpectedCaptureTerminationIgnoresIntentionalCancellationAndActiveCapture() {
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: true,
                isCaptureActive: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: false,
                isCaptureActive: true
            )
        )
    }

    func testStalledUnreadableWriterReturnsWriterWhenAnotherWriterContinues() {
        let now = Date(timeIntervalSince1970: 1_775_100_000)
        let writers = [
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "3024x1964",
                videoDBID: 1000059,
                frameCount: 3,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 3,
                oldestPendingUnreadableAt: now.addingTimeInterval(-90)
            ),
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "1920x1200",
                videoDBID: 1000060,
                frameCount: 5,
                persistedReadableFrameCount: 3,
                pendingUnreadableFrameCount: 0,
                oldestPendingUnreadableAt: nil
            )
        ]

        let stalledWriter = AppCoordinator.stalledUnreadableWriter(
            in: writers,
            now: now,
            threshold: 45,
            minimumPendingFrames: 2
        )

        XCTAssertEqual(stalledWriter?.videoDBID, 1000059)
    }

    func testStalledUnreadableWriterIgnoresSingleWriterWithoutCompetingProgress() {
        let now = Date(timeIntervalSince1970: 1_775_100_000)
        let writers = [
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "3024x1964",
                videoDBID: 1000059,
                frameCount: 2,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 2,
                oldestPendingUnreadableAt: now.addingTimeInterval(-120)
            )
        ]

        let stalledWriter = AppCoordinator.stalledUnreadableWriter(
            in: writers,
            now: now,
            threshold: 45,
            minimumPendingFrames: 2
        )

        XCTAssertNil(stalledWriter)
    }

    func testStalledUnreadableWriterIgnoresWhenOtherWriterHasNoReadableFramesYet() {
        let now = Date(timeIntervalSince1970: 1_775_100_000)
        let writers = [
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "3024x1964",
                videoDBID: 1000059,
                frameCount: 3,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 3,
                oldestPendingUnreadableAt: now.addingTimeInterval(-90)
            ),
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "1920x1200",
                videoDBID: 1000060,
                frameCount: 6,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 2,
                oldestPendingUnreadableAt: now.addingTimeInterval(-30)
            )
        ]

        let stalledWriter = AppCoordinator.stalledUnreadableWriter(
            in: writers,
            now: now,
            threshold: 45,
            minimumPendingFrames: 2
        )

        XCTAssertNil(stalledWriter)
    }

    func testTimelineVisibilityGenerationRejectsOlderUpdates() {
        XCTAssertTrue(
            AppCoordinator.shouldApplyTimelineVisibilityUpdate(
                incomingGeneration: 5,
                currentGeneration: 4
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldApplyTimelineVisibilityUpdate(
                incomingGeneration: 4,
                currentGeneration: 4
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldApplyTimelineVisibilityUpdate(
                incomingGeneration: 3,
                currentGeneration: 4
            )
        )
    }

    func testUnversionedTimelineVisibilityUpdatesKeepExistingCompatibility() {
        XCTAssertTrue(
            AppCoordinator.shouldApplyTimelineVisibilityUpdate(
                incomingGeneration: nil,
                currentGeneration: 4
            )
        )
    }
}
