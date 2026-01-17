import Foundation
import Shared
import Database
import Storage
import Search
import AppKit
import SQLCipher

// SQLITE_TRANSIENT constant for Swift
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Asynchronous frame processing queue with SQLite-backed durability
///
/// Features:
/// - Durable queue (survives app restarts)
/// - Concurrent worker pool for OCR processing
/// - Automatic retry on failure
/// - Backpressure monitoring
public actor FrameProcessingQueue {

    // MARK: - Properties

    private let databaseManager: DatabaseManager
    private let storage: StorageProtocol
    private let processing: ProcessingProtocol
    private let search: SearchProtocol

    private let config: ProcessingQueueConfig
    private var workers: [Task<Void, Never>] = []
    private var isRunning = false

    // Statistics
    private var totalProcessed: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageProtocol,
        processing: ProcessingProtocol,
        search: SearchProtocol,
        config: ProcessingQueueConfig = .default
    ) {
        self.databaseManager = database
        self.storage = storage
        self.processing = processing
        self.search = search
        self.config = config
    }

    // MARK: - Queue Operations

    /// Enqueue a frame for processing
    public func enqueue(frameID: Int64, priority: Int = 0) async throws {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        let sql = """
            INSERT INTO processing_queue (frameId, enqueuedAt, priority, retryCount)
            VALUES (?, ?, ?, 0);
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare enqueue statement")
        }

        sqlite3_bind_int64(stmt, 1, frameID)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(priority))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed("Failed to enqueue frame")
        }

        currentQueueDepth += 1

        Log.debug("[Queue] Enqueued frame \(frameID), depth: \(currentQueueDepth)", category: .processing)
    }

    /// Enqueue multiple frames (batch operation)
    public func enqueueBatch(frameIDs: [Int64], priority: Int = 0) async throws {
        for frameID in frameIDs {
            try await enqueue(frameID: frameID, priority: priority)
        }
    }

    /// Dequeue the next frame for processing
    private func dequeue() async throws -> QueuedFrame? {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        // Get highest priority item
        let sql = """
            SELECT id, frameId, retryCount
            FROM processing_queue
            ORDER BY priority DESC, enqueuedAt ASC
            LIMIT 1;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare dequeue statement")
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil // Queue empty
        }

        let queueID = sqlite3_column_int64(stmt, 0)
        let frameID = sqlite3_column_int64(stmt, 1)
        let retryCount = Int(sqlite3_column_int(stmt, 2))

        // Delete from queue
        let deleteSql = "DELETE FROM processing_queue WHERE id = ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }

        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare delete statement")
        }

        sqlite3_bind_int64(deleteStmt, 1, queueID)

        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed("Failed to delete from queue")
        }

        currentQueueDepth -= 1

        return QueuedFrame(queueID: queueID, frameID: frameID, retryCount: retryCount)
    }

    /// Get current queue depth
    public func getQueueDepth() async throws -> Int {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        let sql = "SELECT COUNT(*) FROM processing_queue;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryExecutionFailed("Failed to get queue depth")
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Worker Pool

    /// Start processing workers
    public func startWorkers() async {
        guard !isRunning else {
            Log.warning("[Queue] Workers already running", category: .processing)
            return
        }

        isRunning = true

        Log.info("[Queue] Starting \(config.workerCount) processing workers", category: .processing)

        for workerID in 0..<config.workerCount {
            let task = Task {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }
    }

    /// Stop processing workers
    public func stopWorkers() async {
        guard isRunning else { return }

        isRunning = false

        Log.info("[Queue] Stopping workers...", category: .processing)

        for worker in workers {
            worker.cancel()
        }

        workers.removeAll()

        Log.info("[Queue] Workers stopped", category: .processing)
    }

    /// Worker loop - processes frames from queue
    private func runWorker(id: Int) async {
        Log.debug("[Queue] Worker \(id) started", category: .processing)

        while isRunning {
            do {
                // Try to dequeue a frame
                guard let queuedFrame = try await dequeue() else {
                    // Queue empty - wait before polling again
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }

                // Process the frame
                let startTime = Date()
                do {
                    try await processFrame(queuedFrame)
                    totalProcessed += 1

                    let elapsed = Date().timeIntervalSince(startTime)
                    Log.debug("[Queue] Worker \(id) processed frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", category: .processing)

                } catch {
                    totalFailed += 1
                    Log.error("[Queue] Worker \(id) failed to process frame \(queuedFrame.frameID): \(error)", category: .processing)

                    // Retry if under limit
                    if queuedFrame.retryCount < config.maxRetryAttempts {
                        try await retryFrame(queuedFrame, error: error)
                    } else {
                        // Mark as failed permanently
                        try await markFrameAsFailed(queuedFrame.frameID, error: error)
                    }
                }

            } catch {
                Log.error("[Queue] Worker \(id) error: \(error)", category: .processing)
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s backoff
            }
        }

        Log.debug("[Queue] Worker \(id) stopped", category: .processing)
    }

    // MARK: - Frame Processing

    /// Process a single frame (OCR + FTS + Nodes)
    private func processFrame(_ queuedFrame: QueuedFrame) async throws {
        let frameID = queuedFrame.frameID

        // Mark as processing
        try await updateFrameProcessingStatus(frameID, status: .processing)

        // Get frame reference from database
        guard let frameRef = try await databaseManager.getFrame(id: FrameID(value: frameID)) else {
            throw DatabaseError.queryFailed(query: "getFrame", underlying: "Frame \(frameID) not found")
        }

        // Load frame image from video
        let frameData = try await storage.readFrame(
            segmentID: frameRef.videoID,
            frameIndex: frameRef.frameIndexInSegment
        )

        // Convert JPEG data to CapturedFrame for OCR
        guard let capturedFrame = try convertJPEGToCapturedFrame(frameData, frameRef: frameRef) else {
            throw ProcessingError.imageConversionFailed
        }

        // Run OCR
        let extractedText = try await processing.extractText(from: capturedFrame)

        // Index in FTS
        let docid = try await search.index(
            text: extractedText,
            segmentId: frameRef.segmentID.value,
            frameId: frameID
        )

        // Insert OCR nodes
        if docid > 0 && !extractedText.regions.isEmpty {
            var currentOffset = 0
            var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []

            for region in extractedText.regions {
                let textLength = region.text.count
                nodeData.append((
                    textOffset: currentOffset,
                    textLength: textLength,
                    bounds: region.bounds,
                    windowIndex: nil
                ))
                currentOffset += textLength + 1
            }

            // Get frame dimensions from video segment
            let videoSegments = try await databaseManager.getVideoSegments(
                from: frameRef.timestamp.addingTimeInterval(-1),
                to: frameRef.timestamp.addingTimeInterval(1)
            )

            if let videoSegment = videoSegments.first(where: { $0.id == frameRef.videoID }) {
                try await databaseManager.insertNodes(
                    frameID: FrameID(value: frameID),
                    nodes: nodeData,
                    frameWidth: videoSegment.width,
                    frameHeight: videoSegment.height
                )
            }
        }

        // Mark as completed
        try await updateFrameProcessingStatus(frameID, status: .completed)
    }

    /// Convert JPEG data back to CapturedFrame for OCR
    private func convertJPEGToCapturedFrame(_ jpegData: Data, frameRef: FrameReference) throws -> CapturedFrame? {
        guard let nsImage = NSImage(data: jpegData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        // Create BGRA bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        var pixelData = Data(count: bytesPerRow * height)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return CapturedFrame(
            timestamp: frameRef.timestamp,
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: frameRef.metadata
        )
    }

    // MARK: - Status Management

    /// Update frame processing status
    private func updateFrameProcessingStatus(_ frameID: Int64, status: FrameProcessingStatus) async throws {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        let sql = "UPDATE frame SET processingStatus = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare status update")
        }

        sqlite3_bind_int(stmt, 1, Int32(status.rawValue))
        sqlite3_bind_int64(stmt, 2, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed("Failed to update processing status")
        }
    }

    /// Retry a failed frame
    private func retryFrame(_ queuedFrame: QueuedFrame, error: Error) async throws {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        let sql = """
            INSERT INTO processing_queue (frameId, enqueuedAt, priority, retryCount, lastError)
            VALUES (?, ?, 0, ?, ?);
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare retry statement")
        }

        sqlite3_bind_int64(stmt, 1, queuedFrame.frameID)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(queuedFrame.retryCount + 1))
        sqlite3_bind_text(stmt, 4, error.localizedDescription, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed("Failed to retry frame")
        }

        Log.warning("[Queue] Retrying frame \(queuedFrame.frameID), attempt \(queuedFrame.retryCount + 1)", category: .processing)
    }

    /// Mark frame as permanently failed
    private func markFrameAsFailed(_ frameID: Int64, error: Error) async throws {
        try await updateFrameProcessingStatus(frameID, status: .failed)
        Log.error("[Queue] Frame \(frameID) marked as failed after max retries: \(error)", category: .processing)
    }

    /// Re-enqueue frames that were processing during a crash
    public func requeueCrashedFrames() async throws {
        guard let db = await databaseManager.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "No database connection")
        }

        // Find frames that were marked as "processing" - they crashed during OCR
        let sql = "SELECT id FROM frame WHERE processingStatus = 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Failed to prepare requeue query")
        }

        var frameIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(stmt, 0))
        }

        if !frameIDs.isEmpty {
            Log.warning("[Queue] Re-enqueueing \(frameIDs.count) frames that crashed during processing", category: .processing)
            try await enqueueBatch(frameIDs: frameIDs)
        }
    }

    // MARK: - Statistics

    public func getStatistics() -> QueueStatistics {
        return QueueStatistics(
            queueDepth: currentQueueDepth,
            totalProcessed: totalProcessed,
            totalFailed: totalFailed,
            workerCount: config.workerCount
        )
    }
}

// MARK: - Models

public struct ProcessingQueueConfig: Sendable {
    public let workerCount: Int
    public let maxRetryAttempts: Int
    public let maxQueueSize: Int

    public init(workerCount: Int = 2, maxRetryAttempts: Int = 3, maxQueueSize: Int = 1000) {
        self.workerCount = workerCount
        self.maxRetryAttempts = maxRetryAttempts
        self.maxQueueSize = maxQueueSize
    }

    public static let `default` = ProcessingQueueConfig()
}

private struct QueuedFrame {
    let queueID: Int64
    let frameID: Int64
    let retryCount: Int
}

public enum FrameProcessingStatus: Int, Sendable {
    case pending = 0
    case processing = 1
    case completed = 2
    case failed = 3
}

public struct QueueStatistics: Sendable {
    public let queueDepth: Int
    public let totalProcessed: Int
    public let totalFailed: Int
    public let workerCount: Int
}
