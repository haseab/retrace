import Foundation
import Shared

/// Manages crash recovery by processing write-ahead logs on app startup
///
/// Recovery process:
/// 1. Scan for active WAL sessions (incomplete video segments)
/// 2. Read raw frames from WAL
/// 3. Re-encode frames to video + enqueue recovered frame IDs via callback
/// 4. Clean up WAL after successful recovery
public actor RecoveryManager {
    private let walManager: WALManager
    private let storage: StorageProtocol
    private let database: DatabaseProtocol
    private var frameEnqueueCallback: (@Sendable ([Int64]) async throws -> Void)?
    private static let maxFramesPerRecoveryBatch = 150
    private static let maxRecoveryBatchBytes: Int64 = 256 * 1024 * 1024

    public init(
        walManager: WALManager,
        storage: StorageProtocol,
        database: DatabaseProtocol
    ) {
        self.walManager = walManager
        self.storage = storage
        self.database = database
    }

    /// Set callback for enqueueing frames (called by AppCoordinator)
    public func setFrameEnqueueCallback(_ callback: @escaping @Sendable ([Int64]) async throws -> Void) {
        self.frameEnqueueCallback = callback
    }

    /// Recover from any active WAL sessions (call this on app startup)
    /// Optimized: checks existing fragmented MP4 files first and only re-encodes missing frames
    public func recoverAll() async throws -> RecoveryResult {
        let sessions = try await walManager.listActiveSessions()

        guard !sessions.isEmpty else {
            Log.info("[Recovery] No WAL sessions found - clean startup", category: .storage)
            return RecoveryResult(sessionsRecovered: 0, framesRecovered: 0, videoSegmentsCreated: 0)
        }

        Log.warning("[Recovery] Found \(sessions.count) incomplete WAL sessions - starting recovery", category: .storage)

        var recoveredSessions = 0
        var totalFrames = 0
        var totalSegments = 0
        var totalSkippedFrames = 0
        var totalRawFramesLoaded = 0
        var totalFramesReencoded = 0

        for session in sessions {
            let frontier: RecoverySessionFrontier
            do {
                frontier = try await buildSessionFrontier(for: session)
            } catch {
                await handleRecoveryFailure(for: session, error: error, rollbacks: [])
                continue
            }

            guard frontier.recoverableFrameCount > 0 else {
                do {
                    let preservedExistingVideo = try await handleSessionWithoutRecoverableFrames(frontier)
                    if preservedExistingVideo {
                        recoveredSessions += 1
                        totalSkippedFrames += frontier.actualExistingFrameCount
                    }
                } catch {
                    await handleRecoveryFailure(for: session, error: error, rollbacks: [])
                }
                continue
            }

            if frontier.recoverableFrameCount != session.metadata.frameCount {
                Log.warning(
                    "[Recovery] WAL session \(session.videoID.value) metadata frameCount=\(session.metadata.frameCount) but recoverable frameCount=\(frontier.recoverableFrameCount); reconciling only the recoverable WAL prefix",
                    category: .storage
                )
            }

            if frontier.actualExistingFrameCount > frontier.recoverableFrameCount && frontier.hasValidVideo {
                Log.warning(
                    "[Recovery] Video \(session.videoID.value) has \(frontier.actualExistingFrameCount) readable frames but WAL has only \(frontier.recoverableFrameCount) recoverable frames; preserving the verified video row and repairing only WAL-backed metadata",
                    category: .storage
                )
            }

            Log.info(
                "[Recovery] Session \(session.videoID.value) frontier summary: wal=\(frontier.recoverableFrameCount), mapped=\(frontier.mappedFrameCount), unmappedTail=\(frontier.unmappedTailCount), readablePrefix=\(frontier.walBackedReadablePrefixCount), durablePrefix=\(frontier.persistedDurableReadablePrefixCount), dbCompleteMappedSkipped=\(frontier.dbCompleteMappedFramesSkipped), hasValidVideo=\(frontier.hasValidVideo)",
                category: .storage
            )

            var sessionFramesRecovered = 0
            var sessionSegmentsCreated = 0
            var sessionRawFramesLoaded = 0
            var sessionFramesReencoded = 0
            var sessionMappedFramesRepaired = 0
            var sessionFrameIDsToEnqueue: [Int64] = []
            var sessionRollbacks: [RecoveryCommitRollback] = []
            var appSegmentState = RecoveryAppSegmentState()
            var readableVideoFinalization: (databaseVideoID: Int64, frameCount: Int)?

            do {
                if frontier.walBackedReadablePrefixCount > 0 {
                    let preservedVideoFrameCount = frontier.hasValidVideo
                        ? frontier.actualExistingFrameCount
                        : frontier.walBackedReadablePrefixCount

                    if !frontier.hasValidVideo {
                        Log.warning(
                            "[Recovery] Video \(session.videoID.value) failed timestamp validation, but WAL metadata confirms \(frontier.walBackedReadablePrefixCount) flushed frames are durable; preserving that readable prefix and replaying only the unreadable tail",
                            category: .storage
                        )
                    }

                    let videoTarget = try await ensureDatabaseVideoIDForReadableVideoIfNeeded(
                        session: session,
                        existingDatabaseVideoID: frontier.existingDatabaseVideoID,
                        frameCount: preservedVideoFrameCount,
                        descriptors: frontier.descriptors
                    )

                    let readablePrefixResult = try await reconcileReadableVideoPrefix(
                        frontier: frontier,
                        videoTarget: videoTarget,
                        appSegmentState: &appSegmentState
                    )
                    sessionFramesRecovered += readablePrefixResult.framesRecovered
                    sessionRawFramesLoaded += readablePrefixResult.rawFramesLoaded
                    sessionMappedFramesRepaired += readablePrefixResult.mappedFramesRepaired
                    sessionFrameIDsToEnqueue.append(contentsOf: readablePrefixResult.frameIDsToEnqueue)
                    sessionRollbacks.append(readablePrefixResult.rollback)
                    totalSkippedFrames += frontier.walBackedReadablePrefixCount
                    readableVideoFinalization = (videoTarget.databaseVideoID, preservedVideoFrameCount)

                    let suffixDescriptors = Array(frontier.descriptors.dropFirst(frontier.walBackedReadablePrefixCount))
                    if !suffixDescriptors.isEmpty {
                        Log.info(
                            "[Recovery] Video \(session.videoID.value) has \(frontier.walBackedReadablePrefixCount)/\(frontier.recoverableFrameCount) WAL-backed frames already durable in fMP4; re-encoding only \(suffixDescriptors.count) tail frames",
                            category: .storage
                        )
                        let recoveryResult = try await recoverFrames(
                            from: session,
                            descriptors: suffixDescriptors,
                            batchSize: frontier.batchSize,
                            appSegmentState: &appSegmentState
                        )
                        sessionFramesRecovered += recoveryResult.framesRecovered
                        sessionSegmentsCreated += recoveryResult.videoSegmentsCreated
                        sessionRawFramesLoaded += recoveryResult.rawFramesLoaded
                        sessionFramesReencoded += recoveryResult.framesReencoded
                        sessionFrameIDsToEnqueue.append(contentsOf: recoveryResult.frameIDsToEnqueue)
                        sessionRollbacks.append(contentsOf: recoveryResult.rollbacks)
                    }

                    if let readableVideoFinalization {
                        try await finalizeExistingVideoRow(
                            pathVideoID: session.videoID,
                            databaseVideoID: readableVideoFinalization.databaseVideoID,
                            frameCount: readableVideoFinalization.frameCount
                        )
                    }
                } else {
                    let shouldDeleteInvalidExistingSegmentAfterRecovery = frontier.actualExistingFrameCount > 0
                    if frontier.actualExistingFrameCount > 0 {
                        Log.warning(
                            "[Recovery] Video \(session.videoID.value) has invalid timestamps; ignoring video frontier and rebuilding from WAL/map",
                            category: .storage
                        )
                    } else {
                        Log.info(
                            "[Recovery] Video \(session.videoID.value) has no readable prefix; recovering from WAL/map only",
                            category: .storage
                        )
                    }

                    let recoveryResult = try await recoverFrames(
                        from: session,
                        descriptors: frontier.descriptors,
                        batchSize: frontier.batchSize,
                        appSegmentState: &appSegmentState
                    )
                    sessionFramesRecovered += recoveryResult.framesRecovered
                    sessionSegmentsCreated += recoveryResult.videoSegmentsCreated
                    sessionRawFramesLoaded += recoveryResult.rawFramesLoaded
                    sessionFramesReencoded += recoveryResult.framesReencoded
                    sessionFrameIDsToEnqueue.append(contentsOf: recoveryResult.frameIDsToEnqueue)
                    sessionRollbacks.append(contentsOf: recoveryResult.rollbacks)

                    let discardReason = frontier.actualExistingFrameCount > 0
                        ? "Replaced invalid-timestamp video with WAL-recovered segments"
                        : "Replaced unreadable placeholder video with WAL-recovered segments"
                    _ = try await discardUnfinalisedDatabaseVideoIfPresent(
                        for: session,
                        reason: discardReason
                    )
                    if shouldDeleteInvalidExistingSegmentAfterRecovery {
                        do {
                            try await storage.deleteSegment(id: session.videoID)
                            Log.info(
                                "[Recovery] Removed invalid-timestamp segment file \(session.videoID.value) after successful WAL recovery",
                                category: .storage
                            )
                        } catch {
                            Log.warning(
                                "[Recovery] Failed to remove invalid-timestamp segment file \(session.videoID.value) after successful WAL recovery: \(error.localizedDescription)",
                                category: .storage
                            )
                        }
                    }
                }
            } catch {
                await handleRecoveryFailure(for: session, error: error, rollbacks: sessionRollbacks)
                continue
            }

            await enqueueRecoveredFramesPostCommit(sessionFrameIDsToEnqueue, session: session)
            await finalizeRecoveredSessionWAL(session)
            recoveredSessions += 1

            totalFrames += sessionFramesRecovered
            totalSegments += sessionSegmentsCreated
            totalRawFramesLoaded += sessionRawFramesLoaded
            totalFramesReencoded += sessionFramesReencoded

            Log.info(
                "[Recovery] Session \(session.videoID.value) completed: inserted=\(sessionFramesRecovered), mappedRepaired=\(sessionMappedFramesRepaired), rawWALFramesLoaded=\(sessionRawFramesLoaded), framesReencoded=\(sessionFramesReencoded), newVideoSegments=\(sessionSegmentsCreated)",
                category: .storage
            )
        }

        if totalSkippedFrames > 0 {
            Log.info("[Recovery] Skipped re-encoding \(totalSkippedFrames) frames (already in video files)", category: .storage)
        }
        Log.info(
            "[Recovery] Complete: \(recoveredSessions)/\(sessions.count) sessions recovered, \(totalFrames) frames processed, \(totalSegments) new video segments, \(totalRawFramesLoaded) WAL frames loaded, \(totalFramesReencoded) frames re-encoded",
            category: .storage
        )

        return RecoveryResult(
            sessionsRecovered: recoveredSessions,
            framesRecovered: totalFrames,
            videoSegmentsCreated: totalSegments
        )
    }

    private func handleSessionWithoutRecoverableFrames(_ frontier: RecoverySessionFrontier) async throws -> Bool {
        let preservedVideoFrameCount = frontier.hasValidVideo
            ? frontier.actualExistingFrameCount
            : frontier.walBackedReadablePrefixCount

        if frontier.actualExistingFrameCount > 0, preservedVideoFrameCount > 0 {
            let videoTarget = try await ensureDatabaseVideoIDForReadableVideoIfNeeded(
                session: frontier.session,
                existingDatabaseVideoID: frontier.existingDatabaseVideoID,
                frameCount: preservedVideoFrameCount,
                descriptors: frontier.descriptors
            )
            try await finalizeExistingVideoRow(
                pathVideoID: frontier.session.videoID,
                databaseVideoID: videoTarget.databaseVideoID,
                frameCount: preservedVideoFrameCount
            )
            Log.warning(
                "[Recovery] WAL session \(frontier.session.videoID.value) has no recoverable WAL frames, but existing video contains \(preservedVideoFrameCount) reusable readable frames; preserved the durable video data and quarantined WAL residue",
                category: .storage
            )
        } else if frontier.session.metadata.frameCount > 0 {
            _ = try await discardUnfinalisedDatabaseVideoIfPresent(
                for: frontier.session,
                reason: "No recoverable WAL frames found in WAL session"
            )
        }

        if frontier.session.metadata.frameCount > 0 {
            _ = try await walManager.quarantineSession(
                frontier.session,
                reason: "No recoverable frames found in WAL session",
                disposition: .discardable
            )
        } else {
            try await walManager.finalizeSession(frontier.session)
        }

        return frontier.actualExistingFrameCount > 0 && preservedVideoFrameCount > 0
    }

    private func handleRecoveryFailure(
        for session: WALSession,
        error: Error,
        rollbacks: [RecoveryCommitRollback]
    ) async {
        await rollbackRecoveryCommits(rollbacks)
        Log.error("[Recovery] ✗ Failed to process WAL session \(session.videoID.value): \(error)", category: .storage)

        do {
            _ = try await discardUnfinalisedDatabaseVideoIfPresent(
                for: session,
                reason: "WAL session quarantined after recovery failure"
            )
            _ = try await walManager.quarantineSession(
                session,
                reason: error.localizedDescription,
                disposition: .retained
            )
        } catch {
            Log.error("[Recovery] Failed to quarantine WAL session \(session.videoID.value)", category: .storage, error: error)
        }
    }

    private func enqueueRecoveredFramesPostCommit(_ frameIDs: [Int64], session: WALSession) async {
        guard !frameIDs.isEmpty else {
            return
        }

        do {
            try await enqueueFramesIfNeeded(frameIDs, context: "[Recovery]")
        } catch {
            Log.warning(
                "[Recovery] Post-commit OCR enqueue failed for session \(session.videoID.value); keeping recovered DB state intact: \(error.localizedDescription)",
                category: .storage
            )
        }
    }

    private func finalizeRecoveredSessionWAL(_ session: WALSession) async {
        do {
            try await walManager.finalizeSession(session)
        } catch {
            Log.error(
                "[Recovery] Failed to remove WAL session \(session.videoID.value) after successful recovery",
                category: .storage,
                error: error
            )
            do {
                _ = try await walManager.quarantineSession(
                    session,
                    reason: "WAL cleanup failed after successful recovery",
                    disposition: .retained
                )
            } catch {
                Log.error(
                    "[Recovery] Failed to quarantine WAL session \(session.videoID.value) after cleanup failure",
                    category: .storage,
                    error: error
                )
            }
        }
    }

    private func buildSessionFrontier(for session: WALSession) async throws -> RecoverySessionFrontier {
        let recoveryIndex = try await walManager.recoveryIndex(for: session)
        let recoverableFrameCount = recoveryIndex.recoverableOffsets.count
        let persistedDurableReadablePrefixCount = min(session.metadata.durableReadableFrameCount, recoverableFrameCount)
        let existingVideoState = try await resolveExistingVideoState(
            for: session,
            recoverableFrameCount: recoverableFrameCount
        )
        let actualExistingFrameCount = existingVideoState.frameCount
        let hasValidVideo = existingVideoState.hasValidVideo
        let readableVideoPrefixCount = actualExistingFrameCount
        let trustedReadablePrefixCount = hasValidVideo
            ? actualExistingFrameCount
            : persistedDurableReadablePrefixCount
        let walBackedReadablePrefixCount = min(
            actualExistingFrameCount,
            recoverableFrameCount,
            trustedReadablePrefixCount
        )
        let existingDatabaseVideoID = (actualExistingFrameCount > 0 || recoverableFrameCount > 0)
            ? try await resolveDatabaseVideoIDIfPresent(for: session)
            : nil

        let mappedFrameIDs = recoveryIndex.mappedFrames.map(\.frameID)
        let statuses = mappedFrameIDs.isEmpty
            ? [:]
            : try await database.getFrameProcessingStatuses(frameIDs: mappedFrameIDs)

        var existingFramesByID: [Int64: FrameReference] = [:]
        existingFramesByID.reserveCapacity(mappedFrameIDs.count)
        for frameID in mappedFrameIDs {
            if let frame = try await database.getFrame(id: FrameID(value: frameID)) {
                existingFramesByID[frameID] = frame
            }
        }

        let mappedFramesByIndex = Dictionary(
            uniqueKeysWithValues: recoveryIndex.mappedFrames.map { ($0.frameIndex, $0) }
        )

        var descriptors: [RecoveryFrameDescriptor] = []
        descriptors.reserveCapacity(recoverableFrameCount)
        for (frameIndex, walOffset) in recoveryIndex.recoverableOffsets.enumerated() {
            let mappedFrame = mappedFramesByIndex[frameIndex]
            let mappedFrameID = mappedFrame?.frameID
            descriptors.append(
                RecoveryFrameDescriptor(
                    frameIndex: frameIndex,
                    walOffset: walOffset,
                    mappedFrameID: mappedFrameID,
                    existingFrame: mappedFrameID.flatMap { existingFramesByID[$0] },
                    processingStatus: mappedFrameID.flatMap { statuses[$0] }
                )
            )
        }

        let unmappedTailCount = descriptors.reversed().prefix { !$0.isMapped }.count
        let dbCompleteMappedFramesSkipped = descriptors
            .prefix(walBackedReadablePrefixCount)
            .filter(\.isMappedComplete)
            .count

        return RecoverySessionFrontier(
            session: session,
            descriptors: descriptors,
            recoverableFrameCount: recoverableFrameCount,
            mappedFrameCount: recoveryIndex.mappedFrames.count,
            unmappedTailCount: unmappedTailCount,
            actualExistingFrameCount: actualExistingFrameCount,
            readableVideoPrefixCount: readableVideoPrefixCount,
            persistedDurableReadablePrefixCount: persistedDurableReadablePrefixCount,
            walBackedReadablePrefixCount: walBackedReadablePrefixCount,
            hasValidVideo: hasValidVideo,
            existingDatabaseVideoID: existingDatabaseVideoID,
            dbCompleteMappedFramesSkipped: dbCompleteMappedFramesSkipped,
            batchSize: recoveryBatchSize(for: session)
        )
    }

    private func resolveExistingVideoState(
        for session: WALSession,
        recoverableFrameCount: Int
    ) async throws -> RecoveryExistingVideoState {
        let persistedDurableReadablePrefixCount = min(session.metadata.durableReadableFrameCount, recoverableFrameCount)

        var actualExistingFrameCount = try await storage.countFramesInSegment(id: session.videoID)
        if actualExistingFrameCount < persistedDurableReadablePrefixCount,
           persistedDurableReadablePrefixCount > 0,
           session.metadata.durableVideoFileSizeBytes > 0 {
            let repairedFrameCount = await trimUnreadableVideoTailToLastDurableBoundaryIfNeeded(
                session: session,
                durableVideoFileSizeBytes: session.metadata.durableVideoFileSizeBytes
            )
            actualExistingFrameCount = max(actualExistingFrameCount, repairedFrameCount)
        }

        let hasValidVideo = actualExistingFrameCount > 0
            ? (try? await storage.isVideoValid(id: session.videoID)) ?? false
            : false

        return RecoveryExistingVideoState(
            frameCount: actualExistingFrameCount,
            hasValidVideo: hasValidVideo
        )
    }

    private func trimUnreadableVideoTailToLastDurableBoundaryIfNeeded(
        session: WALSession,
        durableVideoFileSizeBytes: Int64
    ) async -> Int {
        guard durableVideoFileSizeBytes > 0,
              let segmentURL = try? await storage.getSegmentPath(id: session.videoID),
              let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64),
              currentFileSize > durableVideoFileSizeBytes,
              let fileHandle = FileHandle(forUpdatingAtPath: segmentURL.path) else {
            return 0
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.truncate(atOffset: UInt64(durableVideoFileSizeBytes))
            let recoveredFrameCount = (try? await storage.countFramesInSegment(id: session.videoID)) ?? 0
            if recoveredFrameCount > 0 {
                Log.warning(
                    "[Recovery] Trimmed unreadable video \(session.videoID.value) from \(currentFileSize) to last durable boundary \(durableVideoFileSizeBytes) bytes and recovered \(recoveredFrameCount) readable frames",
                    category: .storage
                )
            }
            return recoveredFrameCount
        } catch {
            Log.warning(
                "[Recovery] Failed to trim unreadable video \(session.videoID.value) to last durable boundary: \(error.localizedDescription)",
                category: .storage
            )
            return 0
        }
    }

    private func ensureDatabaseVideoIDForReadableVideoIfNeeded(
        session: WALSession,
        existingDatabaseVideoID: Int64?,
        frameCount: Int,
        descriptors: [RecoveryFrameDescriptor]
    ) async throws -> RecoveryResolvedVideoTarget {
        if let existingDatabaseVideoID {
            return RecoveryResolvedVideoTarget(
                databaseVideoID: existingDatabaseVideoID,
                createdDatabaseVideoID: nil
            )
        }

        let segmentURL = try await storage.getSegmentPath(id: session.videoID)
        let storageRoot = await storage.getStorageDirectory()
        let fileSize = (try FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0

        let knownTimestamps = descriptors.prefix(frameCount).compactMap { $0.existingFrame?.timestamp }
        let startTime = knownTimestamps.min() ?? session.metadata.startTime
        let endTime: Date
        if let maxTimestamp = knownTimestamps.max() {
            endTime = maxTimestamp
        } else if frameCount > 1 {
            endTime = startTime.addingTimeInterval(Double(frameCount - 1))
        } else {
            endTime = startTime
        }

        let video = VideoSegment(
            id: session.videoID,
            startTime: startTime,
            endTime: endTime,
            frameCount: frameCount,
            fileSizeBytes: fileSize,
            relativePath: relativePath(from: segmentURL, storageRoot: storageRoot),
            width: session.metadata.width,
            height: session.metadata.height
        )
        let databaseVideoID = try await database.insertVideoSegment(video)
        Log.warning(
            "[Recovery] Created DB video row \(databaseVideoID) for readable video \(session.videoID.value) instead of re-encoding the durable prefix",
            category: .storage
        )
        return RecoveryResolvedVideoTarget(
            databaseVideoID: databaseVideoID,
            createdDatabaseVideoID: VideoSegmentID(value: databaseVideoID)
        )
    }

    private func reconcileReadableVideoPrefix(
        frontier: RecoverySessionFrontier,
        videoTarget: RecoveryResolvedVideoTarget,
        appSegmentState: inout RecoveryAppSegmentState
    ) async throws -> RecoveryReadablePrefixResult {
        guard frontier.walBackedReadablePrefixCount > 0 else {
            return RecoveryReadablePrefixResult(
                framesRecovered: 0,
                rawFramesLoaded: 0,
                mappedFramesRepaired: 0,
                frameIDsToEnqueue: [],
                rollback: RecoveryCommitRollback(
                    createdDatabaseVideoID: videoTarget.createdDatabaseVideoID
                )
            )
        }

        var plannedFrames: [RecoveryBufferedFrame] = []
        plannedFrames.reserveCapacity(frontier.walBackedReadablePrefixCount)
        var rawFramesLoaded = 0
        var mappedFramesRepaired = 0

        for descriptor in frontier.descriptors.prefix(frontier.walBackedReadablePrefixCount) {
            if let existingFrame = descriptor.existingFrame {
                plannedFrames.append(
                    RecoveryBufferedFrame(
                        frameIndex: descriptor.frameIndex,
                        mappedFrameID: descriptor.mappedFrameID,
                        timestamp: existingFrame.timestamp,
                        metadata: existingFrame.metadata
                    )
                )

                let status = descriptor.processingStatus ?? 0
                if descriptor.isMapped, status != 2, status != 7 {
                    mappedFramesRepaired += 1
                }
                continue
            }

            let frame = try await walManager.readFrame(videoID: frontier.session.videoID, atOffset: descriptor.walOffset)
            rawFramesLoaded += 1
            plannedFrames.append(
                RecoveryBufferedFrame(
                    frameIndex: descriptor.frameIndex,
                    mappedFrameID: descriptor.mappedFrameID,
                    timestamp: frame.timestamp,
                    metadata: frame.metadata
                )
            )
            if descriptor.isMapped {
                mappedFramesRepaired += 1
            }
        }

        let commitPlan = try await planRecoveredSegmentCommit(
            for: plannedFrames,
            initialState: appSegmentState
        )
        let applyResult = try await applyRecoveryCommitPlan(
            commitPlan,
            databaseVideoID: videoTarget.databaseVideoID
        )
        var rollback = applyResult.rollback
        if rollback.createdDatabaseVideoID == nil {
            rollback.createdDatabaseVideoID = videoTarget.createdDatabaseVideoID
        }
        appSegmentState = applyResult.finalAppSegmentState

        return RecoveryReadablePrefixResult(
            framesRecovered: applyResult.framesRecovered,
            rawFramesLoaded: rawFramesLoaded,
            mappedFramesRepaired: mappedFramesRepaired,
            frameIDsToEnqueue: applyResult.frameIDs,
            rollback: rollback
        )
    }

    private func resolveExistingFrameForRecovery(
        _ loadedFrame: RecoveryBufferedFrame,
        matchedExistingFrameIDs: inout Set<Int64>
    ) async throws -> FrameReference? {
        let timestampMillis = Int64(loadedFrame.timestamp.timeIntervalSince1970 * 1000)

        if let mappedFrameID = loadedFrame.mappedFrameID {
            guard matchedExistingFrameIDs.insert(mappedFrameID).inserted else {
                Log.warning(
                    "[Recovery] Duplicate mapped frameID \(mappedFrameID) encountered for WAL frame \(loadedFrame.frameIndex); inserting a recovered frame instead",
                    category: .storage
                )
                return nil
            }

            guard let existingFrame = try await database.getFrame(id: FrameID(value: mappedFrameID)) else {
                Log.warning(
                    "[Recovery] Mapped frameID \(mappedFrameID) for WAL frame \(loadedFrame.frameIndex) is missing from the database; inserting a recovered frame instead",
                    category: .storage
                )
                return nil
            }

            guard segmentMetadataMatches(existingFrame: existingFrame, metadata: loadedFrame.metadata) else {
                Log.warning(
                    "[Recovery] Mapped frameID \(mappedFrameID) for WAL frame \(loadedFrame.frameIndex) metadata differed from the WAL frame; inserting a recovered frame instead",
                    category: .storage
                )
                return nil
            }

            return existingFrame
        }

        guard let existingFrameID = try await database.getFrameIDAtTimestamp(loadedFrame.timestamp) else {
            return nil
        }

        guard matchedExistingFrameIDs.insert(existingFrameID).inserted else {
            Log.warning(
                "[Recovery] Duplicate existing frame match avoided (frameID=\(existingFrameID), timestamp=\(timestampMillis), frameIndex=\(loadedFrame.frameIndex)); inserting new frame",
                category: .storage
            )
            return nil
        }

        guard let existingFrame = try await database.getFrame(id: FrameID(value: existingFrameID)) else {
            Log.warning(
                "[Recovery] Existing frame lookup returned missing row (frameID=\(existingFrameID), timestamp=\(timestampMillis)); inserting new frame",
                category: .storage
            )
            return nil
        }

        guard segmentMetadataMatches(existingFrame: existingFrame, metadata: loadedFrame.metadata) else {
            Log.warning(
                "[Recovery] Existing frame \(existingFrameID) timestamp matched but segment metadata differed; inserting a new recovered frame instead",
                category: .storage
            )
            return nil
        }

        return existingFrame
    }

    private func recoverFrames(
        from session: WALSession,
        descriptors: [RecoveryFrameDescriptor],
        batchSize: Int,
        appSegmentState: inout RecoveryAppSegmentState
    ) async throws -> RecoveryFrameRecoveryResult {
        guard !descriptors.isEmpty else {
            return RecoveryFrameRecoveryResult(
                framesRecovered: 0,
                videoSegmentsCreated: 0,
                rawFramesLoaded: 0,
                framesReencoded: 0,
                frameIDsToEnqueue: [],
                rollbacks: []
            )
        }

        let maxFramesPerSegment = 150
        var totalFramesRecovered = 0
        var totalVideosCreated = 0
        var recoveredFrameIDs: [Int64] = []
        var recoveredFrameIDSet: Set<Int64> = []
        var rawFramesLoaded = 0
        var framesReencoded = 0
        var writerState: RecoveryWriterState?
        var committedRollbacks: [RecoveryCommitRollback] = []

        func finalizeActiveWriter() async throws {
            guard let currentState = writerState else { return }
            guard !currentState.bufferedFrames.isEmpty else {
                try? await currentState.writer.cancel()
                writerState = nil
                return
            }

            let videoSegment = try await currentState.writer.finalize()
            let encodedCount = min(currentState.bufferedFrames.count, videoSegment.frameCount)
            guard encodedCount > 0 else {
                throw StorageError.fileWriteFailed(
                    path: "WAL recovery",
                    underlying: "Recovered writer finalized without encoded frames"
                )
            }

            let commitResult = try await commitRecoveredSegment(
                videoSegment: videoSegment,
                frames: Array(currentState.bufferedFrames.prefix(encodedCount)),
                appSegmentState: &appSegmentState
            )
            committedRollbacks.append(commitResult.rollback)
            totalFramesRecovered += commitResult.framesRecovered
            totalVideosCreated += 1
            for frameID in commitResult.frameIDs where recoveredFrameIDSet.insert(frameID).inserted {
                recoveredFrameIDs.append(frameID)
            }
            writerState = nil
        }

        do {
            for batchStart in stride(from: 0, to: descriptors.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, descriptors.count)
                let batchDescriptors = Array(descriptors[batchStart..<batchEnd])
                for descriptor in batchDescriptors {
                    let frame = try await walManager.readFrame(videoID: session.videoID, atOffset: descriptor.walOffset)
                    let bufferedFrame = RecoveryBufferedFrame(
                        frameIndex: descriptor.frameIndex,
                        mappedFrameID: descriptor.mappedFrameID,
                        timestamp: frame.timestamp,
                        metadata: frame.metadata
                    )
                    rawFramesLoaded += 1

                    if writerState == nil {
                        writerState = RecoveryWriterState(
                            writer: try await storage.createSegmentWriter(),
                            bufferedFrames: []
                        )
                    }

                    do {
                        var currentState = writerState!
                        try await currentState.writer.appendFrame(frame)
                        currentState.bufferedFrames.append(bufferedFrame)
                        writerState = currentState
                        framesReencoded += 1

                        if currentState.bufferedFrames.count >= maxFramesPerSegment {
                            try await finalizeActiveWriter()
                        }
                    } catch {
                        let bufferedCount = writerState?.bufferedFrames.count ?? 0
                        Log.warning(
                            "[Recovery] Encoder failed at WAL frame \(descriptor.frameIndex) after \(bufferedCount) buffered frames: \(error). Finalizing encoded prefix and retrying remaining frames.",
                            category: .storage
                        )

                        if bufferedCount > 0 {
                            try await finalizeActiveWriter()
                        } else if let currentState = writerState {
                            try? await currentState.writer.cancel()
                            writerState = nil
                        }

                        let retryWriter = try await storage.createSegmentWriter()
                        do {
                            try await retryWriter.appendFrame(frame)
                            writerState = RecoveryWriterState(writer: retryWriter, bufferedFrames: [bufferedFrame])
                            framesReencoded += 1
                        } catch {
                            try? await retryWriter.cancel()
                            throw StorageError.fileWriteFailed(
                                path: "WAL recovery",
                                underlying: "Failed to encode frame \(descriptor.frameIndex) after writer rollover: \(error)"
                            )
                        }
                    }
                }
            }

            if writerState != nil {
                try await finalizeActiveWriter()
            }

            return RecoveryFrameRecoveryResult(
                framesRecovered: totalFramesRecovered,
                videoSegmentsCreated: totalVideosCreated,
                rawFramesLoaded: rawFramesLoaded,
                framesReencoded: framesReencoded,
                frameIDsToEnqueue: recoveredFrameIDs,
                rollbacks: committedRollbacks
            )
        } catch {
            if let currentState = writerState {
                try? await currentState.writer.cancel()
            }
            await rollbackRecoveryCommits(committedRollbacks)
            throw error
        }
    }

    private func repairExistingFrameVideoLinkIfNeeded(
        _ existingFrame: FrameReference,
        databaseVideoID: Int64,
        frameIndex: Int
    ) async throws {
        guard existingFrame.videoID.value != databaseVideoID
            || existingFrame.frameIndexInSegment != frameIndex else {
            return
        }

        try await database.updateFrameVideoLink(
            frameID: existingFrame.id,
            videoID: VideoSegmentID(value: databaseVideoID),
            frameIndex: frameIndex
        )
    }

    private func relativePath(from url: URL, storageRoot: URL) -> String {
        let rootPath = storageRoot.path
        let fullPath = url.path
        if fullPath.hasPrefix(rootPath) {
            let index = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
            return String(fullPath[index...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fullPath
    }

    private func applyRecoveryCommitPlan(
        _ commitPlan: RecoveryRecoveredSegmentCommitPlan,
        databaseVideoID: Int64
    ) async throws -> RecoveryCommitApplyResult {
        var insertedSegmentIDsByPlanID: [Int: Int64] = [:]
        var rollback = RecoveryCommitRollback()

        do {
            for plannedSegmentID in commitPlan.plannedSegments.keys.sorted() {
                guard let plannedSegment = commitPlan.plannedSegments[plannedSegmentID] else {
                    continue
                }

                let segmentID = try await database.insertSegment(
                    bundleID: plannedSegment.bundleID,
                    startDate: plannedSegment.startDate,
                    endDate: plannedSegment.endDate,
                    windowName: plannedSegment.windowName,
                    browserUrl: plannedSegment.browserURL,
                    type: 0
                )
                insertedSegmentIDsByPlanID[plannedSegmentID] = segmentID
                rollback.insertedSegmentIDs.append(segmentID)
            }

            for segmentID in commitPlan.existingSegmentEndDateChanges.keys.sorted() {
                guard let endDateChange = commitPlan.existingSegmentEndDateChanges[segmentID] else {
                    continue
                }
                try await database.updateSegmentEndDate(id: segmentID, endDate: endDateChange.updatedEndDate)
            }
            rollback.existingSegmentEndDateChanges = commitPlan.existingSegmentEndDateChanges

            var frameIDs: [Int64] = []
            var framesRecovered = 0

            for action in commitPlan.frameActions {
                switch action {
                case .updateExisting(let rollbackInfo, let newFrameIndex):
                    try await database.updateFrameVideoLink(
                        frameID: FrameID(value: rollbackInfo.frameID),
                        videoID: VideoSegmentID(value: databaseVideoID),
                        frameIndex: newFrameIndex
                    )
                    rollback.updatedExistingFrames.append(rollbackInfo)
                    frameIDs.append(rollbackInfo.frameID)

                case .insertNew(let frame, let segmentRef, let newFrameIndex):
                    let segmentID = try resolveSegmentID(
                        for: segmentRef,
                        insertedSegmentIDsByPlanID: insertedSegmentIDsByPlanID
                    )
                    let frameRef = FrameReference(
                        id: FrameID(value: 0),
                        timestamp: frame.timestamp,
                        segmentID: AppSegmentID(value: segmentID),
                        videoID: VideoSegmentID(value: databaseVideoID),
                        frameIndexInSegment: newFrameIndex,
                        metadata: frame.metadata,
                        source: .native
                    )
                    let frameID = try await database.insertFrame(frameRef)
                    rollback.insertedFrameIDs.append(frameID)
                    frameIDs.append(frameID)
                    framesRecovered += 1
                }
            }

            let finalAppSegmentState = try resolveCommittedAppSegmentState(
                from: commitPlan.finalState,
                insertedSegmentIDsByPlanID: insertedSegmentIDsByPlanID
            )

            return RecoveryCommitApplyResult(
                framesRecovered: framesRecovered,
                frameIDs: frameIDs,
                rollback: rollback,
                finalAppSegmentState: finalAppSegmentState
            )
        } catch {
            await rollbackRecoveryCommit(rollback)
            throw error
        }
    }

    private func commitRecoveredSegment(
        videoSegment: VideoSegment,
        frames: [RecoveryBufferedFrame],
        appSegmentState: inout RecoveryAppSegmentState
    ) async throws -> RecoveredSegmentCommitResult {
        guard !frames.isEmpty else {
            throw StorageError.fileWriteFailed(
                path: "WAL recovery",
                underlying: "Attempted to commit an empty recovered segment"
            )
        }

        let commitPlan = try await planRecoveredSegmentCommit(
            for: frames,
            initialState: appSegmentState
        )
        let dbVideoID = try await database.insertVideoSegment(videoSegment)
        var commitRollback = RecoveryCommitRollback(
            createdDatabaseVideoID: VideoSegmentID(value: dbVideoID),
            createdPathVideoID: videoSegment.id
        )

        do {
            let applyResult = try await applyRecoveryCommitPlan(
                commitPlan,
                databaseVideoID: dbVideoID
            )
            commitRollback.insertedFrameIDs = applyResult.rollback.insertedFrameIDs
            commitRollback.updatedExistingFrames = applyResult.rollback.updatedExistingFrames
            commitRollback.insertedSegmentIDs = applyResult.rollback.insertedSegmentIDs
            commitRollback.existingSegmentEndDateChanges = applyResult.rollback.existingSegmentEndDateChanges

            try await database.markVideoFinalized(
                id: dbVideoID,
                frameCount: videoSegment.frameCount,
                fileSize: videoSegment.fileSizeBytes
            )

            appSegmentState = applyResult.finalAppSegmentState

            if !commitRollback.updatedExistingFrames.isEmpty {
                Log.info("[Recovery] Updated \(commitRollback.updatedExistingFrames.count) existing frames to point to recovered video", category: .storage)
            }

            return RecoveredSegmentCommitResult(
                framesRecovered: applyResult.framesRecovered,
                frameIDs: applyResult.frameIDs,
                rollback: commitRollback
            )
        } catch {
            await rollbackRecoveryCommit(commitRollback)
            throw error
        }
    }

    private func enqueueFramesIfNeeded(_ frameIDs: [Int64], context: String) async throws {
        guard let enqueueCallback = frameEnqueueCallback, !frameIDs.isEmpty else {
            return
        }

        var seen: Set<Int64> = []
        let uniqueFrameIDs = frameIDs.filter { seen.insert($0).inserted }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: uniqueFrameIDs)

        var framesToMarkReadable: [Int64] = []
        var framesToResetToPending: [Int64] = []
        var framesAwaitingRewriteRecovery: [Int64] = []
        var framesToProcess: [Int64] = []

        for frameID in uniqueFrameIDs {
            let status = statuses[frameID] ?? 0
            switch status {
            case 2, 7:
                continue
            case 4:
                framesToMarkReadable.append(frameID)
                framesToProcess.append(frameID)
            case 1, 3:
                framesToResetToPending.append(frameID)
                framesToProcess.append(frameID)
            case 5, 6, 8:
                // Rewrite-lane frames were already OCR-complete before recovery.
                // Preserve their status so startup rewrite recovery can resume the
                // segment rewrite without re-entering OCR and duplicating FTS state.
                framesAwaitingRewriteRecovery.append(frameID)
            case 0:
                framesToProcess.append(frameID)
            default:
                Log.warning("\(context) Unknown processingStatus \(status) for frame \(frameID)", category: .storage)
            }
        }

        for frameID in framesToMarkReadable {
            try await database.markFrameReadable(frameID: frameID)
        }
        if !framesToMarkReadable.isEmpty {
            Log.info("\(context) Marked \(framesToMarkReadable.count) frames as readable", category: .storage)
        }

        for frameID in framesToResetToPending {
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 0)
        }
        if !framesToResetToPending.isEmpty {
            Log.info("\(context) Reset \(framesToResetToPending.count) frames to pending status", category: .storage)
        }
        if !framesAwaitingRewriteRecovery.isEmpty {
            Log.info(
                "\(context) Preserved \(framesAwaitingRewriteRecovery.count) rewrite-state frames for rewrite recovery",
                category: .storage
            )
        }

        if !framesToProcess.isEmpty {
            try await enqueueCallback(framesToProcess)
            Log.info("\(context) Enqueued \(framesToProcess.count) frames for OCR (skipped \(uniqueFrameIDs.count - framesToProcess.count) already processed)", category: .storage)
        } else {
            Log.info("\(context) All \(uniqueFrameIDs.count) frames already have OCR data", category: .storage)
        }
    }

    private func resolveDatabaseVideoIDIfPresent(for session: WALSession) async throws -> Int64? {
        let sessionFilename = session.videoID.stringValue
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()

        if let matchedVideo = unfinalisedVideos.first(where: {
            videoPathStem(for: $0.relativePath) == sessionFilename
        }) {
            return matchedVideo.id
        }

        if let video = try await database.findVideoSegment(relativePathStem: sessionFilename),
           videoPathStem(for: video.relativePath) == sessionFilename {
            return video.id.value
        }
        return nil
    }

    private func videoPathStem(for relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
    }

    private func discardUnfinalisedDatabaseVideoIfPresent(for session: WALSession, reason: String) async throws -> Bool {
        let sessionFilename = session.videoID.stringValue
        let unfinalisedVideos = try await database.getAllUnfinalisedVideos()
        guard let matchedVideo = unfinalisedVideos.first(where: {
            videoPathStem(for: $0.relativePath) == sessionFilename
        }) else {
            return false
        }

        try await database.deleteVideoSegment(id: VideoSegmentID(value: matchedVideo.id))
        Log.warning(
            "[Recovery] Deleted unfinalised DB video row \(matchedVideo.id) for WAL session \(session.videoID.value): \(reason)",
            category: .storage
        )
        return true
    }

    private func finalizeExistingVideoRow(
        pathVideoID: VideoSegmentID,
        databaseVideoID: Int64,
        frameCount: Int
    ) async throws {
        let segmentURL = try await storage.getSegmentPath(id: pathVideoID)
        let fileSize = (try FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size] as? Int64) ?? 0
        try await database.markVideoFinalized(
            id: databaseVideoID,
            frameCount: frameCount,
            fileSize: fileSize
        )
    }

    private func flushAppSegmentEndDateIfNeeded(
        state: inout RecoveryAppSegmentState
    ) async throws {
        guard state.currentSegmentHasInsertedFrames,
              let currentSegmentID = state.currentSegmentID,
              let lastFrameTimestamp = state.lastFrameTimestamp else {
            return
        }

        try await database.updateSegmentEndDate(id: currentSegmentID, endDate: lastFrameTimestamp)
        state.currentSegmentHasInsertedFrames = false
    }

    private func normalizedBundleID(_ bundleID: String?) -> String {
        bundleID ?? "com.unknown.recovered"
    }

    private func normalizedWindowName(_ windowName: String?) -> String {
        windowName ?? "Recovered Session"
    }

    private func normalizedBrowserURL(_ browserURL: String?) -> String? {
        guard let browserURL = browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browserURL.isEmpty else {
            return nil
        }
        return browserURL
    }

    private func recoveryBatchSize(for session: WALSession) -> Int {
        let approximateFrameBytes = approximateFrameByteCount(width: session.metadata.width, height: session.metadata.height) ?? 1
        let byBytes = max(1, Int(Self.maxRecoveryBatchBytes / approximateFrameBytes))
        return min(Self.maxFramesPerRecoveryBatch, byBytes)
    }

    private func approximateFrameByteCount(width: Int, height: Int) -> Int64? {
        guard width > 0, height > 0 else {
            return nil
        }

        let width64 = Int64(width)
        let height64 = Int64(height)
        let (pixelCount, pixelOverflow) = width64.multipliedReportingOverflow(by: height64)
        guard !pixelOverflow else {
            Log.warning(
                "[Recovery] Ignoring overflowing WAL metadata dimensions \(width)x\(height) while sizing recovery batches",
                category: .storage
            )
            return nil
        }

        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, byteCount > 0 else {
            Log.warning(
                "[Recovery] Ignoring overflowing WAL metadata byte count for dimensions \(width)x\(height) while sizing recovery batches",
                category: .storage
            )
            return nil
        }

        return byteCount
    }

    private func segmentMetadataMatches(existingFrame: FrameReference, metadata: FrameMetadata) -> Bool {
        normalizedBundleID(existingFrame.metadata.appBundleID) == normalizedBundleID(metadata.appBundleID)
            && normalizedWindowName(existingFrame.metadata.windowName) == normalizedWindowName(metadata.windowName)
    }

    private func planRecoveredSegmentCommit(
        for frames: [RecoveryBufferedFrame],
        initialState: RecoveryAppSegmentState
    ) async throws -> RecoveryRecoveredSegmentCommitPlan {
        var matchedExistingFrameIDs: Set<Int64> = []
        var frameActions: [RecoveryRecoveredFrameCommitAction] = []
        var plannedSegments: [Int: RecoveryPlannedSegment] = [:]
        var existingSegmentEndDateChanges: [Int64: RecoverySegmentEndDateChange] = [:]
        var state = RecoverySegmentPlanningState(
            currentSegmentRef: initialState.currentSegmentID.map(RecoverySegmentReference.existing),
            currentBundleID: initialState.currentBundleID,
            currentWindowName: initialState.currentWindowName,
            lastFrameTimestamp: initialState.lastFrameTimestamp
        )
        var nextPlannedSegmentID = 0

        func updatePlannedSegmentEndDate(_ plannedSegmentID: Int, to timestamp: Date) {
            guard var plannedSegment = plannedSegments[plannedSegmentID] else {
                return
            }
            if timestamp > plannedSegment.endDate {
                plannedSegment.endDate = timestamp
                plannedSegments[plannedSegmentID] = plannedSegment
            }
        }

        func recordExistingSegmentEndDateChange(segmentID: Int64, newEndDate: Date) async throws {
            guard let existingSegment = try await database.getSegment(id: segmentID) else {
                return
            }

            let updatedEndDate = max(existingSegment.endDate, newEndDate)
            guard updatedEndDate > existingSegment.endDate else {
                return
            }

            if let currentChange = existingSegmentEndDateChanges[segmentID] {
                if updatedEndDate > currentChange.updatedEndDate {
                    existingSegmentEndDateChanges[segmentID] = RecoverySegmentEndDateChange(
                        originalEndDate: currentChange.originalEndDate,
                        updatedEndDate: updatedEndDate
                    )
                }
            } else {
                existingSegmentEndDateChanges[segmentID] = RecoverySegmentEndDateChange(
                    originalEndDate: existingSegment.endDate,
                    updatedEndDate: updatedEndDate
                )
            }
        }

        func flushCurrentSegmentEndDateIfNeeded() async throws {
            guard state.currentSegmentHasInsertedFrames,
                  let currentSegmentRef = state.currentSegmentRef,
                  let lastFrameTimestamp = state.lastFrameTimestamp else {
                return
            }

            switch currentSegmentRef {
            case .existing(let segmentID):
                try await recordExistingSegmentEndDateChange(segmentID: segmentID, newEndDate: lastFrameTimestamp)
            case .planned(let plannedSegmentID):
                updatePlannedSegmentEndDate(plannedSegmentID, to: lastFrameTimestamp)
            }

            state.currentSegmentHasInsertedFrames = false
        }

        func setCurrentState(
            segmentRef: RecoverySegmentReference,
            bundleID: String,
            windowName: String,
            timestamp: Date,
            hasInsertedFrames: Bool
        ) {
            state.currentSegmentRef = segmentRef
            state.currentBundleID = bundleID
            state.currentWindowName = windowName
            state.lastFrameTimestamp = timestamp
            state.currentSegmentHasInsertedFrames = hasInsertedFrames
        }

        func planSegmentReference(for frame: RecoveryBufferedFrame) async throws -> RecoverySegmentReference {
            let bundleID = normalizedBundleID(frame.metadata.appBundleID)
            let windowName = normalizedWindowName(frame.metadata.windowName)
            let browserURL = normalizedBrowserURL(frame.metadata.browserURL)

            if let currentSegmentRef = state.currentSegmentRef,
               state.currentBundleID == bundleID,
               state.currentWindowName == windowName {
                state.lastFrameTimestamp = frame.timestamp
                state.currentSegmentHasInsertedFrames = true
                if case .planned(let plannedSegmentID) = currentSegmentRef {
                    updatePlannedSegmentEndDate(plannedSegmentID, to: frame.timestamp)
                }
                return currentSegmentRef
            }

            try await flushCurrentSegmentEndDateIfNeeded()

            let plannedSegmentID = nextPlannedSegmentID
            nextPlannedSegmentID += 1
            plannedSegments[plannedSegmentID] = RecoveryPlannedSegment(
                bundleID: bundleID,
                startDate: frame.timestamp,
                endDate: frame.timestamp,
                windowName: windowName,
                browserURL: browserURL
            )
            setCurrentState(
                segmentRef: .planned(plannedSegmentID),
                bundleID: bundleID,
                windowName: windowName,
                timestamp: frame.timestamp,
                hasInsertedFrames: true
            )
            return .planned(plannedSegmentID)
        }

        for (newFrameIndex, loadedFrame) in frames.enumerated() {
            if let existingFrame = try await resolveExistingFrameForRecovery(
                loadedFrame,
                matchedExistingFrameIDs: &matchedExistingFrameIDs
            ) {
                try await flushCurrentSegmentEndDateIfNeeded()
                setCurrentState(
                    segmentRef: .existing(existingFrame.segmentID.value),
                    bundleID: normalizedBundleID(existingFrame.metadata.appBundleID),
                    windowName: normalizedWindowName(existingFrame.metadata.windowName),
                    timestamp: loadedFrame.timestamp,
                    hasInsertedFrames: false
                )
                frameActions.append(
                    .updateExisting(
                        rollbackInfo: RecoveryExistingFrameVideoLink(
                            frameID: existingFrame.id.value,
                            originalVideoID: existingFrame.videoID,
                            originalFrameIndex: existingFrame.frameIndexInSegment
                        ),
                        newFrameIndex: newFrameIndex
                    )
                )
                continue
            }

            let segmentRef = try await planSegmentReference(for: loadedFrame)
            frameActions.append(.insertNew(frame: loadedFrame, segmentRef: segmentRef, newFrameIndex: newFrameIndex))
        }

        try await flushCurrentSegmentEndDateIfNeeded()

        return RecoveryRecoveredSegmentCommitPlan(
            frameActions: frameActions,
            plannedSegments: plannedSegments,
            existingSegmentEndDateChanges: existingSegmentEndDateChanges,
            finalState: state
        )
    }

    private func resolveSegmentID(
        for segmentRef: RecoverySegmentReference,
        insertedSegmentIDsByPlanID: [Int: Int64]
    ) throws -> Int64 {
        switch segmentRef {
        case .existing(let segmentID):
            return segmentID
        case .planned(let plannedSegmentID):
            guard let segmentID = insertedSegmentIDsByPlanID[plannedSegmentID] else {
                throw StorageError.fileWriteFailed(
                    path: "WAL recovery",
                    underlying: "Missing planned segment mapping for recovered segment \(plannedSegmentID)"
                )
            }
            return segmentID
        }
    }

    private func resolveCommittedAppSegmentState(
        from planningState: RecoverySegmentPlanningState,
        insertedSegmentIDsByPlanID: [Int: Int64]
    ) throws -> RecoveryAppSegmentState {
        let currentSegmentID: Int64?
        if let currentSegmentRef = planningState.currentSegmentRef {
            currentSegmentID = try resolveSegmentID(
                for: currentSegmentRef,
                insertedSegmentIDsByPlanID: insertedSegmentIDsByPlanID
            )
        } else {
            currentSegmentID = nil
        }

        return RecoveryAppSegmentState(
            currentSegmentID: currentSegmentID,
            currentBundleID: planningState.currentBundleID,
            currentWindowName: planningState.currentWindowName,
            lastFrameTimestamp: planningState.lastFrameTimestamp
        )
    }

    private func rollbackRecoveryCommit(_ rollback: RecoveryCommitRollback) async {
        for rollbackInfo in rollback.updatedExistingFrames.reversed() {
            do {
                try await database.updateFrameVideoLink(
                    frameID: FrameID(value: rollbackInfo.frameID),
                    videoID: rollbackInfo.originalVideoID,
                    frameIndex: rollbackInfo.originalFrameIndex
                )
            } catch {
                Log.error(
                    "[Recovery] Failed to restore original video link for frame \(rollbackInfo.frameID) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }

        for frameID in rollback.insertedFrameIDs.reversed() {
            do {
                try await database.deleteFrame(id: FrameID(value: frameID))
            } catch {
                Log.error(
                    "[Recovery] Failed to delete inserted frame \(frameID) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }

        for (segmentID, endDateChange) in rollback.existingSegmentEndDateChanges.sorted(by: { $0.key > $1.key }) {
            do {
                try await database.updateSegmentEndDate(id: segmentID, endDate: endDateChange.originalEndDate)
            } catch {
                Log.error(
                    "[Recovery] Failed to restore original endDate for segment \(segmentID) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }

        for segmentID in rollback.insertedSegmentIDs.reversed() {
            do {
                try await database.deleteSegment(id: segmentID)
            } catch {
                Log.error(
                    "[Recovery] Failed to delete inserted recovery segment \(segmentID) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }

        if let recoveredPathVideoID = rollback.createdPathVideoID {
            do {
                try await storage.deleteSegment(id: recoveredPathVideoID)
            } catch {
                Log.error(
                    "[Recovery] Failed to delete transient recovered segment file \(recoveredPathVideoID.value) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }

        if let recoveredVideoID = rollback.createdDatabaseVideoID {
            do {
                try await database.deleteVideoSegment(id: recoveredVideoID)
            } catch {
                Log.error(
                    "[Recovery] Failed to delete transient recovered video row \(recoveredVideoID.value) during rollback",
                    category: .storage,
                    error: error
                )
            }
        }
    }

    private func rollbackRecoveryCommits(_ rollbacks: [RecoveryCommitRollback]) async {
        for rollback in rollbacks.reversed() {
            await rollbackRecoveryCommit(rollback)
        }
    }
}

// MARK: - Models

private struct RecoveryWriterState {
    let writer: SegmentWriter
    var bufferedFrames: [RecoveryBufferedFrame]
}

private struct RecoveryFrameDescriptor {
    let frameIndex: Int
    let walOffset: UInt64
    let mappedFrameID: Int64?
    let existingFrame: FrameReference?
    let processingStatus: Int?

    var isMapped: Bool {
        mappedFrameID != nil
    }

    var isMappedComplete: Bool {
        isMapped && existingFrame != nil && (processingStatus == 2 || processingStatus == 7)
    }
}

private struct RecoveryBufferedFrame {
    let frameIndex: Int
    let mappedFrameID: Int64?
    let timestamp: Date
    let metadata: FrameMetadata
}

private struct RecoverySessionFrontier {
    let session: WALSession
    let descriptors: [RecoveryFrameDescriptor]
    let recoverableFrameCount: Int
    let mappedFrameCount: Int
    let unmappedTailCount: Int
    let actualExistingFrameCount: Int
    let readableVideoPrefixCount: Int
    let persistedDurableReadablePrefixCount: Int
    let walBackedReadablePrefixCount: Int
    let hasValidVideo: Bool
    let existingDatabaseVideoID: Int64?
    let dbCompleteMappedFramesSkipped: Int
    let batchSize: Int
}

private struct RecoveryExistingVideoState {
    let frameCount: Int
    let hasValidVideo: Bool
}

private enum RecoverySegmentReference: Hashable {
    case existing(Int64)
    case planned(Int)
}

private struct RecoveryAppSegmentState {
    var currentSegmentID: Int64?
    var currentBundleID: String?
    var currentWindowName: String?
    var lastFrameTimestamp: Date?
    var currentSegmentHasInsertedFrames = false
}

private struct RecoverySegmentPlanningState {
    var currentSegmentRef: RecoverySegmentReference?
    var currentBundleID: String?
    var currentWindowName: String?
    var lastFrameTimestamp: Date?
    var currentSegmentHasInsertedFrames = false
}

private struct RecoveryPlannedSegment {
    let bundleID: String
    let startDate: Date
    var endDate: Date
    let windowName: String
    let browserURL: String?
}

private struct RecoverySegmentEndDateChange {
    let originalEndDate: Date
    let updatedEndDate: Date
}

private struct RecoveryExistingFrameVideoLink {
    let frameID: Int64
    let originalVideoID: VideoSegmentID
    let originalFrameIndex: Int
}

private struct RecoveryCommitRollback {
    var insertedFrameIDs: [Int64] = []
    var updatedExistingFrames: [RecoveryExistingFrameVideoLink] = []
    var insertedSegmentIDs: [Int64] = []
    var existingSegmentEndDateChanges: [Int64: RecoverySegmentEndDateChange] = [:]
    var createdDatabaseVideoID: VideoSegmentID?
    var createdPathVideoID: VideoSegmentID?
}

private struct RecoveryResolvedVideoTarget {
    let databaseVideoID: Int64
    let createdDatabaseVideoID: VideoSegmentID?
}

private enum RecoveryRecoveredFrameCommitAction {
    case updateExisting(rollbackInfo: RecoveryExistingFrameVideoLink, newFrameIndex: Int)
    case insertNew(frame: RecoveryBufferedFrame, segmentRef: RecoverySegmentReference, newFrameIndex: Int)
}

private struct RecoveryRecoveredSegmentCommitPlan {
    let frameActions: [RecoveryRecoveredFrameCommitAction]
    let plannedSegments: [Int: RecoveryPlannedSegment]
    let existingSegmentEndDateChanges: [Int64: RecoverySegmentEndDateChange]
    let finalState: RecoverySegmentPlanningState
}

private struct RecoveryCommitApplyResult {
    let framesRecovered: Int
    let frameIDs: [Int64]
    let rollback: RecoveryCommitRollback
    let finalAppSegmentState: RecoveryAppSegmentState
}

private struct RecoveredSegmentCommitResult {
    let framesRecovered: Int
    let frameIDs: [Int64]
    let rollback: RecoveryCommitRollback
}

private struct RecoveryReadablePrefixResult {
    let framesRecovered: Int
    let rawFramesLoaded: Int
    let mappedFramesRepaired: Int
    let frameIDsToEnqueue: [Int64]
    let rollback: RecoveryCommitRollback
}

private struct RecoveryFrameRecoveryResult {
    let framesRecovered: Int
    let videoSegmentsCreated: Int
    let rawFramesLoaded: Int
    let framesReencoded: Int
    let frameIDsToEnqueue: [Int64]
    let rollbacks: [RecoveryCommitRollback]
}

public struct RecoveryResult: Sendable {
    public let sessionsRecovered: Int
    public let framesRecovered: Int
    public let videoSegmentsCreated: Int

    public init(sessionsRecovered: Int, framesRecovered: Int, videoSegmentsCreated: Int) {
        self.sessionsRecovered = sessionsRecovered
        self.framesRecovered = framesRecovered
        self.videoSegmentsCreated = videoSegmentsCreated
    }
}
