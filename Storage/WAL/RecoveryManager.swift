import Foundation
import Shared

/// Manages crash recovery by processing write-ahead logs on app startup
///
/// Recovery process:
/// 1. Scan for active WAL sessions (incomplete video segments)
/// 2. Read raw frames from WAL
/// 3. Re-encode frames to video + enqueue for async OCR processing
/// 4. Clean up WAL after successful recovery
public actor RecoveryManager {
    private let walManager: WALManager
    private let storage: StorageProtocol
    private let database: DatabaseProtocol
    private let processing: ProcessingProtocol
    private let search: SearchProtocol
    private var frameEnqueueCallback: (@Sendable ([Int64]) async throws -> Void)?

    public init(
        walManager: WALManager,
        storage: StorageProtocol,
        database: DatabaseProtocol,
        processing: ProcessingProtocol,
        search: SearchProtocol
    ) {
        self.walManager = walManager
        self.storage = storage
        self.database = database
        self.processing = processing
        self.search = search
    }

    /// Set callback for enqueueing frames (called by AppCoordinator)
    public func setFrameEnqueueCallback(_ callback: @escaping @Sendable ([Int64]) async throws -> Void) {
        self.frameEnqueueCallback = callback
    }

    /// Recover from any active WAL sessions (call this on app startup)
    /// Groups sessions by resolution and merges them into single videos per resolution
    public func recoverAll() async throws -> RecoveryResult {
        let sessions = try await walManager.listActiveSessions()

        guard !sessions.isEmpty else {
            Log.info("[Recovery] No WAL sessions found - clean startup", category: .storage)
            return RecoveryResult(sessionsRecovered: 0, framesRecovered: 0, videoSegmentsCreated: 0)
        }

        Log.warning("[Recovery] Found \(sessions.count) incomplete WAL sessions - starting recovery", category: .storage)

        // Read all frames from all sessions and group by resolution
        var framesByResolution: [String: [(session: WALSession, frames: [CapturedFrame])]] = [:]

        for session in sessions {
            do {
                let frames = try await walManager.readFrames(from: session)
                guard !frames.isEmpty, let firstFrame = frames.first else {
                    // Empty session - just clean up
                    try await walManager.finalizeSession(session)
                    continue
                }

                let resolutionKey = "\(firstFrame.width)x\(firstFrame.height)"
                if framesByResolution[resolutionKey] == nil {
                    framesByResolution[resolutionKey] = []
                }
                framesByResolution[resolutionKey]?.append((session: session, frames: frames))
            } catch {
                Log.error("[Recovery] ✗ Failed to read WAL session \(session.videoID.value): \(error)", category: .storage)
            }
        }

        var totalFrames = 0
        var totalSegments = 0

        // Process each resolution group - merge all sessions into one video
        for (resolutionKey, sessionData) in framesByResolution {
            do {
                // Combine all frames from all sessions of this resolution, sorted by timestamp
                let allFrames = sessionData.flatMap { $0.frames }.sorted { $0.timestamp < $1.timestamp }

                guard !allFrames.isEmpty else { continue }

                Log.info("[Recovery] Processing \(allFrames.count) frames for resolution \(resolutionKey) from \(sessionData.count) sessions", category: .storage)

                let result = try await recoverFrames(allFrames, resolutionKey: resolutionKey)
                totalFrames += result.framesRecovered
                totalSegments += result.videoSegmentsCreated

                // Clean up all WAL sessions for this resolution
                for data in sessionData {
                    try await walManager.finalizeSession(data.session)
                }

                Log.info("[Recovery] ✓ Recovered \(resolutionKey): \(result.framesRecovered) frames into \(result.videoSegmentsCreated) video(s)", category: .storage)
            } catch {
                Log.error("[Recovery] ✗ Failed to recover resolution \(resolutionKey): \(error)", category: .storage)
            }
        }

        Log.info("[Recovery] Complete: \(sessions.count) sessions, \(totalFrames) frames, \(totalSegments) video segments", category: .storage)

        return RecoveryResult(
            sessionsRecovered: sessions.count,
            framesRecovered: totalFrames,
            videoSegmentsCreated: totalSegments
        )
    }

    /// Recover frames for a specific resolution, respecting max frames per segment (150)
    /// Creates multiple video segments if needed
    private func recoverFrames(_ frames: [CapturedFrame], resolutionKey: String) async throws -> RecoveryResult {
        let maxFramesPerSegment = 150
        var totalFramesRecovered = 0
        var totalVideosCreated = 0
        var recoveredFrameIDs: [Int64] = []
        var skippedDuplicates = 0

        // Split frames into chunks of maxFramesPerSegment
        let frameChunks = stride(from: 0, to: frames.count, by: maxFramesPerSegment).map {
            Array(frames[$0..<min($0 + maxFramesPerSegment, frames.count)])
        }

        for chunk in frameChunks {
            guard !chunk.isEmpty else { continue }

            // Re-encode this chunk to video
            let videoSegment = try await reencodeFrames(chunk)

            // Insert video segment into database
            let dbVideoID = try await database.insertVideoSegment(videoSegment)
            totalVideosCreated += 1

            Log.debug("[Recovery] Video segment created with DB ID: \(dbVideoID), \(chunk.count) frames", category: .storage)

            // Process each frame: insert to database
            var currentAppSegmentID: Int64?

            for (frameIndex, frame) in chunk.enumerated() {
                // Skip if a frame with the same timestamp already exists (to the second)
                if try await database.frameExistsAtTimestamp(frame.timestamp) {
                    skippedDuplicates += 1
                    continue
                }

                // Create app segment if needed (track app changes within chunk)
                let needsNewSegment = currentAppSegmentID == nil

                if needsNewSegment {
                    currentAppSegmentID = try await database.insertSegment(
                        bundleID: frame.metadata.appBundleID ?? "com.unknown.recovered",
                        startDate: frame.timestamp,
                        endDate: frame.timestamp,
                        windowName: frame.metadata.windowName ?? "Recovered Session",
                        browserUrl: frame.metadata.browserURL,
                        type: 0
                    )
                }

                // Insert frame into database with pending status
                let frameRef = FrameReference(
                    id: FrameID(value: 0),
                    timestamp: frame.timestamp,
                    segmentID: AppSegmentID(value: currentAppSegmentID!),
                    videoID: VideoSegmentID(value: dbVideoID),
                    frameIndexInSegment: frameIndex,
                    metadata: frame.metadata,
                    source: .native
                )
                let frameID = try await database.insertFrame(frameRef)
                recoveredFrameIDs.append(frameID)
                totalFramesRecovered += 1
            }

            // Update app segment end date
            if let segmentID = currentAppSegmentID, let lastFrame = chunk.last {
                try await database.updateSegmentEndDate(id: segmentID, endDate: lastFrame.timestamp)
            }
        }

        if skippedDuplicates > 0 {
            Log.info("[Recovery] Skipped \(skippedDuplicates) duplicate frames (already in database)", category: .storage)
        }

        // Enqueue all recovered frames for async processing
        if let enqueueCallback = frameEnqueueCallback, !recoveredFrameIDs.isEmpty {
            try await enqueueCallback(recoveredFrameIDs)
            Log.info("[Recovery] Enqueued \(recoveredFrameIDs.count) frames for async processing", category: .storage)
        }

        return RecoveryResult(
            sessionsRecovered: 1,
            framesRecovered: totalFramesRecovered,
            videoSegmentsCreated: totalVideosCreated
        )
    }

    /// Re-encode frames from WAL to a video file
    /// If encoding fails mid-way (e.g., encoder timeout), finalizes with whatever frames were encoded
    private func reencodeFrames(_ frames: [CapturedFrame]) async throws -> VideoSegment {
        guard !frames.isEmpty else {
            throw StorageError.fileWriteFailed(path: "WAL recovery", underlying: "No frames to encode")
        }

        // Create a new segment writer
        let writer = try await storage.createSegmentWriter()
        var framesEncoded = 0

        // Append all frames, handling encoder failures gracefully
        for frame in frames {
            do {
                try await writer.appendFrame(frame)
                framesEncoded += 1
            } catch {
                // Encoder failed (e.g., timeout) - it auto-finalizes, so just log and break
                Log.warning("[Recovery] Encoder failed after \(framesEncoded)/\(frames.count) frames: \(error). Continuing with partial recovery.", category: .storage)
                break
            }
        }

        // Finalize and return (safe even if encoder already finalized due to timeout)
        return try await writer.finalize()
    }
}

// MARK: - Models

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
