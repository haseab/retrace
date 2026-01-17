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
    public func recoverAll() async throws -> RecoveryResult {
        let sessions = try await walManager.listActiveSessions()

        guard !sessions.isEmpty else {
            Log.info("[Recovery] No WAL sessions found - clean startup", category: .storage)
            return RecoveryResult(sessionsRecovered: 0, framesRecovered: 0, videoSegmentsCreated: 0)
        }

        Log.warning("[Recovery] Found \(sessions.count) incomplete WAL sessions - starting recovery", category: .storage)

        var totalFrames = 0
        var totalSegments = 0

        for session in sessions {
            do {
                let result = try await recoverSession(session)
                totalFrames += result.framesRecovered
                totalSegments += result.videoSegmentsCreated
                Log.info("[Recovery] ✓ Recovered session \(session.videoID.value): \(result.framesRecovered) frames", category: .storage)
            } catch {
                Log.error("[Recovery] ✗ Failed to recover session \(session.videoID.value): \(error)", category: .storage)
                // Don't throw - continue recovering other sessions
            }
        }

        Log.info("[Recovery] Complete: \(sessions.count) sessions, \(totalFrames) frames, \(totalSegments) video segments", category: .storage)

        return RecoveryResult(
            sessionsRecovered: sessions.count,
            framesRecovered: totalFrames,
            videoSegmentsCreated: totalSegments
        )
    }

    /// Recover a single WAL session
    private func recoverSession(_ session: WALSession) async throws -> RecoveryResult {
        // Read all frames from WAL
        let frames = try await walManager.readFrames(from: session)

        guard !frames.isEmpty else {
            // Empty session - just clean up
            try await walManager.finalizeSession(session)
            return RecoveryResult(sessionsRecovered: 1, framesRecovered: 0, videoSegmentsCreated: 0)
        }

        Log.info("[Recovery] Processing \(frames.count) frames from WAL session \(session.videoID.value)", category: .storage)

        // Re-encode frames to video
        let videoSegment = try await reencodeFrames(frames, videoID: session.videoID)

        // Insert video segment into database
        let dbVideoID = try await database.insertVideoSegment(videoSegment)

        Log.debug("[Recovery] Video segment created with DB ID: \(dbVideoID)", category: .storage)

        // Process each frame: insert to database and enqueue for async OCR
        var currentAppSegmentID: Int64?
        var recoveredFrameIDs: [Int64] = []

        for (frameIndex, frame) in frames.enumerated() {
            // Create app segment if needed (all frames from same session)
            if currentAppSegmentID == nil {
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
        }

        // Enqueue all recovered frames for async processing
        if let enqueueCallback = frameEnqueueCallback {
            try await enqueueCallback(recoveredFrameIDs)
            Log.info("[Recovery] Enqueued \(recoveredFrameIDs.count) frames for async processing", category: .storage)
        } else {
            Log.warning("[Recovery] No processing queue callback set - frames will remain unprocessed", category: .storage)
        }

        // Update app segment end date
        if let segmentID = currentAppSegmentID, let lastFrame = frames.last {
            try await database.updateSegmentEndDate(id: segmentID, endDate: lastFrame.timestamp)
        }

        // Clean up WAL - recovery complete
        try await walManager.finalizeSession(session)

        return RecoveryResult(
            sessionsRecovered: 1,
            framesRecovered: frames.count,
            videoSegmentsCreated: 1
        )
    }

    /// Re-encode frames from WAL to a video file
    private func reencodeFrames(_ frames: [CapturedFrame], videoID: VideoSegmentID) async throws -> VideoSegment {
        guard !frames.isEmpty else {
            throw StorageError.fileWriteFailed(path: "WAL recovery", underlying: "No frames to encode")
        }

        // Create a new segment writer
        let writer = try await storage.createSegmentWriter()

        // Append all frames
        for frame in frames {
            try await writer.appendFrame(frame)
        }

        // Finalize and return
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
