import Compression
import CryptoKit
import Foundation
import Shared

public enum WALQuarantineDisposition: Sendable {
    case discardable
    case retained

    var logLabel: String {
        switch self {
        case .discardable:
            return "Quarantined"
        case .retained:
            return "Retained quarantined"
        }
    }
}

/// Write-Ahead Log Manager for crash-safe frame persistence
///
/// Persists losslessly compressed BGRA frames before video encoding. Each record is
/// independently readable for OCR and crash recovery; legacy raw records remain readable.
///
/// Directory structure:
/// {AppPaths.storageRoot}/wal/
///   └── active_segment_{videoID}/
///       ├── frames.bin      # Independent versioned records (header, metadata, LZFSE pixels)
///       └── metadata.json   # Segment metadata (videoID, startTime, frameCount)
public actor WALManager {
    private let walRootURL: URL
    private var frameOffsetIndexCache: [Int64: WALFrameOffsetIndex] = [:]
    private var frameIDOffsetIndexCache: [Int64: WALFrameIDOffsetIndex] = [:]
    private var debugRawReadOffsetsByVideoID: [Int64: [UInt64]] = [:]
    private static let eagerReadSafetyLimitBytes: Int64 = 512 * 1024 * 1024
    private static let maximumFrameBytes = 256 * 1024 * 1024
    private static let recordMagic = Data("RTRCWAL2".utf8)
    private static let recordExtensionSize = 48  // magic + codec + decoded size + SHA-256
    private var compressionTotals: [Int64: WALCompressionTotals] = [:]
    private static let discardableQuarantinePrefix = "quarantined_segment_"
    private static let retainedQuarantinePrefix = "retained_segment_"

    public init(walRoot: URL) {
        self.walRootURL = walRoot
    }

    public func initialize() async throws {
        var isDirectory: ObjCBool = false
        let walRootExists = FileManager.default.fileExists(
            atPath: walRootURL.path,
            isDirectory: &isDirectory
        )

        if walRootExists && !isDirectory.boolValue {
            let relocatedURL = try relocateInvalidWALRoot()
            Log.warning(
                "[WAL] Moved invalid WAL root aside to \(relocatedURL.lastPathComponent)",
                category: .storage
            )
        }

        if !FileManager.default.fileExists(atPath: walRootURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: walRootURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw StorageError.walUnavailable(
                    reason: "Failed to create WAL directory at \(walRootURL.path): \(error.localizedDescription)"
                )
            }
        }

        try verifyWriteAccess()

    }

    // MARK: - Write Operations

    /// Create a new WAL session for a video segment
    public func createSession(videoID: VideoSegmentID) async throws -> WALSession {
        try await initialize()

        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")

        // Create session directory
        do {
            try FileManager.default.createDirectory(
                at: sessionDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw makeStorageWriteError(
                path: sessionDir.path,
                error: error,
                fallback: "Failed to create WAL session directory"
            )
        }

        // Create empty frames.bin file
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        try createEmptyFile(at: framesURL)
        let frameMapURL = sessionDir.appendingPathComponent("frame_id_map.bin")
        try createEmptyFile(at: frameMapURL)

        // Create metadata file
        let metadata = WALMetadata(
            videoID: videoID,
            startTime: Date(),
            frameCount: 0,
            width: 0,
            height: 0,
            durableReadableFrameCount: 0,
            durableVideoFileSizeBytes: 0
        )
        do {
            try saveMetadata(metadata, to: sessionDir)
        } catch {
            Log.warning(
                "[WAL] Failed to persist initial metadata sidecar for session \(videoID.value): \(error.localizedDescription)",
                category: .storage
            )
        }

        return WALSession(
            videoID: videoID,
            sessionDir: sessionDir,
            framesURL: framesURL,
            metadata: metadata
        )
    }

    /// Append a frame to the WAL
    public func appendFrame(_ frame: CapturedFrame, to session: inout WALSession) async throws {
        let strings = [
            frame.metadata.appBundleID, frame.metadata.appName,
            frame.metadata.windowName, frame.metadata.browserURL
        ].map { Data(($0 ?? "").utf8) }
        guard frame.width > 0, frame.height > 0,
            frame.timestamp.timeIntervalSince1970.isFinite,
            frame.width <= Int(UInt32.max), frame.height <= Int(UInt32.max),
            frame.bytesPerRow >= frame.width * 4,
            frame.bytesPerRow <= Self.maximumFrameBytes / frame.height,
            frame.imageData.count == frame.bytesPerRow * frame.height,
            strings.allSatisfy({ $0.count <= Int(UInt16.max) })
        else {
            throw StorageError.fileWriteFailed(path: session.framesURL.path, underlying: "Invalid WAL frame dimensions or metadata")
        }

        // This actor serializes codec work. The streaming encoder has a fixed output
        // scratch buffer and retains at most one frame's worth of compressed output.
        let compressionStart = CFAbsoluteTimeGetCurrent()
        let compressed = try compressPixels(frame.imageData)
        let codec: WALPayloadCodec = compressed == nil ? .raw : .lzfse
        let payload = compressed ?? frame.imageData
        let compressionMs = (CFAbsoluteTimeGetCurrent() - compressionStart) * 1000
        let header = WALFrameHeader(
            timestamp: frame.timestamp.timeIntervalSince1970,
            width: UInt32(frame.width), height: UInt32(frame.height),
            bytesPerRow: UInt32(frame.bytesPerRow), dataSize: UInt32(payload.count),
            displayID: frame.metadata.displayID,
            appBundleIDLength: UInt16(strings[0].count), appNameLength: UInt16(strings[1].count),
            windowNameLength: UInt16(strings[2].count), browserURLLength: UInt16(strings[3].count)
        )
        var headerData = Self.recordMagic
        appendLittleEndian(codec.rawValue, to: &headerData)
        appendLittleEndian(UInt32(frame.imageData.count), to: &headerData)
        headerData.append(contentsOf: SHA256.hash(data: frame.imageData))
        appendLittleEndian(header.timestamp.bitPattern, to: &headerData)
        for value in [header.width, header.height, header.bytesPerRow, header.dataSize, header.displayID] {
            appendLittleEndian(value, to: &headerData)
        }
        for string in strings { appendLittleEndian(UInt16(string.count), to: &headerData) }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forWritingTo: session.framesURL)
        } catch {
            throw makeStorageWriteError(path: session.framesURL.path, error: error, fallback: "Cannot open WAL for appending")
        }
        defer { try? fileHandle.close() }
        let recordOffset = try fileHandle.seekToEnd()
        do {
            try fileHandle.write(contentsOf: headerData)
            for string in strings { try fileHandle.write(contentsOf: string) }
            try fileHandle.write(contentsOf: payload)
        } catch {
            // A failed append must not strand a partial record before the next append.
            // A process crash still leaves a recoverable prefix, as with legacy WALs.
            try? fileHandle.truncate(atOffset: recordOffset)
            frameOffsetIndexCache.removeValue(forKey: session.videoID.value)
            throw makeStorageWriteError(path: session.framesURL.path, error: error, fallback: "Failed to append frame to WAL")
        }
        var totals = compressionTotals[session.videoID.value, default: WALCompressionTotals()]
        totals.frameCount += 1
        totals.compressedFrameCount += codec == .lzfse ? 1 : 0
        totals.rawBytes += Int64(frame.imageData.count)
        totals.storedBytes += Int64(headerData.count + strings.reduce(0) { $0 + $1.count } + payload.count)
        totals.compressionMilliseconds += compressionMs
        compressionTotals[session.videoID.value] = totals

        // Update session metadata
        session.metadata.frameCount += 1
        if session.metadata.width == 0 {
            session.metadata.width = frame.width
            session.metadata.height = frame.height
        }

        do {
            try saveMetadata(session.metadata, to: session.sessionDir)
        } catch {
            Log.warning(
                "[WAL] Failed to update metadata sidecar for session \(session.videoID.value): \(error.localizedDescription)",
                category: .storage
            )
        }

        // Invalidate frame offset index cache so the next random-access read
        // can rebuild with the newly appended frame.
        frameOffsetIndexCache.removeValue(forKey: session.videoID.value)
    }

    /// Persist the readable frontier of the fragmented MP4 so recovery can
    /// trust the flushed prefix even if generic timestamp validation fails later.
    public func updateDurableVideoState(
        videoID: VideoSegmentID,
        readableFrameCount: Int,
        durableVideoFileSizeBytes: Int64
    ) async throws {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            throw StorageError.fileNotFound(path: sessionDir.path)
        }

        var metadata = try loadMetadata(from: sessionDir)
        let nextReadableFrameCount = max(metadata.durableReadableFrameCount, readableFrameCount)
        let nextDurableVideoFileSizeBytes = max(metadata.durableVideoFileSizeBytes, durableVideoFileSizeBytes)

        guard nextReadableFrameCount != metadata.durableReadableFrameCount
            || nextDurableVideoFileSizeBytes != metadata.durableVideoFileSizeBytes else {
            return
        }

        metadata.durableReadableFrameCount = nextReadableFrameCount
        metadata.durableVideoFileSizeBytes = nextDurableVideoFileSizeBytes
        try saveMetadata(metadata, to: sessionDir)
    }

    /// Persist a stable mapping from database frameID -> WAL frame offset.
    /// This lets OCR load the exact raw payload by frameID, avoiding index drift.
    public func registerFrameID(videoID: VideoSegmentID, frameID: Int64, frameIndex: Int) async throws {
        guard frameIndex >= 0 else {
            throw StorageError.fileWriteFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Cannot register negative frame index \(frameIndex)"
            )
        }

        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let mapURL = sessionDir.appendingPathComponent("frame_id_map.bin")

        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }
        if !FileManager.default.fileExists(atPath: mapURL.path) {
            do {
                try createEmptyFile(at: mapURL)
            } catch {
                Log.warning(
                    "[WAL] Failed to create frameID map sidecar for session \(videoID.value): \(error.localizedDescription)",
                    category: .storage
                )
                return
            }
        }

        let currentFramesSize = (try? FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        guard currentFramesSize > 0 else {
            throw StorageError.fileWriteFailed(path: framesURL.path, underlying: "WAL frames file is empty")
        }

        let offsets = try frameOffsets(
            for: videoID.value,
            framesURL: framesURL,
            currentFileSize: currentFramesSize
        )
        guard frameIndex < offsets.count else {
            throw StorageError.fileWriteFailed(
                path: framesURL.path,
                underlying: "Cannot register frameID \(frameID): frameIndex \(frameIndex) out of range (0..<\(offsets.count))"
            )
        }

        let record = WALFrameIDMapRecord(frameID: frameID, frameOffset: offsets[frameIndex])
        do {
            try appendFrameIDMapRecord(record, to: mapURL)
            cacheFrameIDMapRecord(videoIDValue: videoID.value, record: record)
        } catch {
            Log.warning(
                "[WAL] Failed to append frameID map entry for session \(videoID.value); recreating sidecar: \(error.localizedDescription)",
                category: .storage
            )

            do {
                try rebuildFrameIDMap(videoIDValue: videoID.value, mapURL: mapURL, appending: record)
                Log.warning(
                    "[WAL] Recreated frameID map sidecar for session \(videoID.value) after write failure",
                    category: .storage
                )
            } catch {
                Log.warning(
                    "[WAL] Failed to recreate frameID map sidecar for session \(videoID.value): \(error.localizedDescription)",
                    category: .storage
                )
            }
        }
    }

    /// Finalize a WAL session (after successful video encoding)
    public func finalizeSession(_ session: WALSession) async throws {
        // Delete the WAL directory - video is now safely encoded
        // Use try? to handle case where directory was already deleted (e.g., double-finalize)
        if FileManager.default.fileExists(atPath: session.sessionDir.path) {
            try FileManager.default.removeItem(at: session.sessionDir)
        }
        clearSessionCaches(videoIDValue: session.videoID.value)
    }

    /// Finalize an active-segment WAL directory by videoID.
    /// Safety: refuses to remove directories that still contain recoverable WAL frames.
    @discardableResult
    public func finalizeSessionDirectoryIfPresent(videoID: VideoSegmentID) async throws -> Bool {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            return false
        }

        if let recoverableFrameCount = try await recoverableFrameCountIfPresent(videoID: videoID),
           recoverableFrameCount > 0 {
            throw StorageError.fileWriteFailed(
                path: sessionDir.path,
                underlying: "Refusing to finalize WAL directory with \(recoverableFrameCount) recoverable frames"
            )
        }

        try FileManager.default.removeItem(at: sessionDir)
        clearSessionCaches(videoIDValue: videoID.value)
        return true
    }

    /// Clear ALL WAL sessions (used when changing database location)
    /// WARNING: This deletes unrecovered frame data! Only call when intentionally switching databases.
    public func clearAllSessions() async throws {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: walRootURL,
            includingPropertiesForKeys: nil
        )

        var clearedCount = 0
        for dir in contents where dir.hasDirectoryPath {
            if dir.lastPathComponent.hasPrefix("active_segment_")
                || isQuarantineDirectory(dir)
            {
                try FileManager.default.removeItem(at: dir)
                clearedCount += 1
            }
        }

        if clearedCount > 0 {
            Log.warning("[WAL] Cleared \(clearedCount) WAL sessions (database location changed)", category: .storage)
        }

        frameOffsetIndexCache.removeAll()
        frameIDOffsetIndexCache.removeAll()
        compressionTotals.removeAll()
    }

    /// Delete discardable quarantined WAL sessions older than the provided cutoff date.
    @discardableResult
    public func cleanupQuarantinedSessions(olderThan cutoffDate: Date) async -> Int {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return 0
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: walRootURL,
                includingPropertiesForKeys: nil
            )
        } catch {
            Log.warning(
                "[WAL] Failed to enumerate quarantined WAL sessions during cleanup: \(error.localizedDescription)",
                category: .storage
            )
            return 0
        }

        var removedCount = 0
        for dir in contents where dir.hasDirectoryPath {
            guard isDiscardableQuarantineDirectory(dir) else {
                continue
            }

            guard let quarantinedAt = quarantineDate(for: dir), quarantinedAt <= cutoffDate else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: dir)
                removedCount += 1

                if let videoIDValue = quarantinedVideoID(for: dir) {
                    frameOffsetIndexCache.removeValue(forKey: videoIDValue)
                    frameIDOffsetIndexCache.removeValue(forKey: videoIDValue)
                }
            } catch {
                Log.warning(
                    "[WAL] Failed to remove quarantined WAL session \(dir.lastPathComponent): \(error.localizedDescription)",
                    category: .storage
                )
            }
        }

        if removedCount > 0 {
            Log.info("[WAL] Removed \(removedCount) expired quarantined WAL sessions", category: .storage)
        }

        return removedCount
    }

    // MARK: - Recovery Operations

    /// List all active WAL sessions (for crash recovery)
    public func listActiveSessions() async throws -> [WALSession] {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: walRootURL,
            includingPropertiesForKeys: nil
        )

        var sessions: [WALSession] = []
        for dir in contents where dir.hasDirectoryPath {
            // Parse videoID from directory name: "active_segment_{videoID}"
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("active_segment_"),
                  let videoIDStr = dirName.split(separator: "_").last,
                  let videoIDValue = Int64(videoIDStr) else {
                continue
            }

            let framesURL = dir.appendingPathComponent("frames.bin")
            guard FileManager.default.fileExists(atPath: framesURL.path) else {
                continue
            }

            let videoID = VideoSegmentID(value: videoIDValue)
            let metadata: WALMetadata
            do {
                let loadedMetadata = try loadMetadata(from: dir)
                metadata = try repairMetadataIfNeeded(
                    loadedMetadata,
                    videoID: videoID,
                    sessionDir: dir,
                    framesURL: framesURL
                )
            } catch {
                Log.warning(
                    "[WAL] Failed to load metadata for session \(videoID.value); attempting rebuild from frames.bin: \(error.localizedDescription)",
                    category: .storage
                )

                let rebuiltMetadata: WALMetadata?
                let quarantineReason: String
                do {
                    rebuiltMetadata = try rebuildMetadata(videoID: videoID, framesURL: framesURL)
                    quarantineReason = "Corrupted metadata and no recoverable WAL frames"
                } catch {
                    // A complete but unsupported/corrupt record is not a truncated
                    // tail. Retain this directory without blocking healthy sessions
                    // or allowing its parse failure to prevent recording startup.
                    rebuiltMetadata = nil
                    quarantineReason = "Cannot rebuild WAL metadata: \(error.localizedDescription)"
                    Log.warning("[WAL] Retaining session \(videoID.value): \(quarantineReason)", category: .storage)
                }

                if let rebuiltMetadata {
                    do {
                        try saveMetadata(rebuiltMetadata, to: dir)
                    } catch {
                        Log.warning(
                            "[WAL] Rebuilt metadata for session \(videoID.value) but failed to persist repaired sidecar: \(error.localizedDescription)",
                            category: .storage
                        )
                    }

                    Log.warning(
                        "[WAL] Rebuilt metadata for session \(videoID.value) from recoverable WAL frames",
                        category: .storage
                    )
                    metadata = rebuiltMetadata
                } else {
                    let placeholderSession = WALSession(
                        videoID: videoID,
                        sessionDir: dir,
                        framesURL: framesURL,
                        metadata: placeholderMetadata(for: videoID)
                    )
                    do {
                        _ = try await quarantineSession(
                            placeholderSession,
                            reason: quarantineReason,
                            disposition: .retained
                        )
                    } catch {
                        Log.error(
                            "[WAL] Failed to quarantine session \(videoID.value) after metadata rebuild failure",
                            category: .storage,
                            error: error
                        )
                    }
                    continue
                }
            }

            sessions.append(WALSession(
                videoID: videoID,
                sessionDir: dir,
                framesURL: framesURL,
                metadata: metadata
            ))
        }

        return sessions
    }

    /// Returns the current size of a WAL session's stored frame records.
    public func framesFileSize(for session: WALSession) async throws -> Int64 {
        guard FileManager.default.fileExists(atPath: session.framesURL.path) else {
            throw StorageError.fileNotFound(path: session.framesURL.path)
        }

        return (try FileManager.default.attributesOfItem(atPath: session.framesURL.path)[.size] as? Int64) ?? 0
    }

    /// Count recoverable frames without materializing the whole WAL into memory.
    /// Truncated tail frames are ignored so recovery can salvage the valid prefix.
    public func recoverableFrameCount(for session: WALSession) async throws -> Int {
        let fileSize = try await framesFileSize(for: session)
        guard fileSize > 0 else { return 0 }

        return try frameOffsets(
            for: session.videoID.value,
            framesURL: session.framesURL,
            currentFileSize: fileSize
        ).count
    }

    /// Returns recoverable frame count for an active WAL directory if present.
    /// - Returns: `nil` when no active WAL directory exists for `videoID`.
    public func recoverableFrameCountIfPresent(videoID: VideoSegmentID) async throws -> Int? {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            return nil
        }

        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            return 0
        }

        let probeSession = WALSession(
            videoID: videoID,
            sessionDir: sessionDir,
            framesURL: framesURL,
            metadata: placeholderMetadata(for: videoID)
        )
        return try await recoverableFrameCount(for: probeSession)
    }

    func recoveryIndex(for session: WALSession) async throws -> WALRecoveryIndex {
        let fileSize = try await framesFileSize(for: session)
        guard fileSize > 0 else {
            return WALRecoveryIndex(recoverableOffsets: [], mappedFrames: [])
        }

        let recoverableOffsets = try frameOffsets(
            for: session.videoID.value,
            framesURL: session.framesURL,
            currentFileSize: fileSize
        )
        let offsetToFrameIndex = Dictionary(uniqueKeysWithValues: recoverableOffsets.enumerated().map { ($0.element, $0.offset) })

        let mapURL = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        guard FileManager.default.fileExists(atPath: mapURL.path) else {
            return WALRecoveryIndex(recoverableOffsets: recoverableOffsets, mappedFrames: [])
        }

        let mapFileSize = (try? FileManager.default.attributesOfItem(atPath: mapURL.path)[.size] as? Int64) ?? 0
        guard mapFileSize > 0 else {
            return WALRecoveryIndex(recoverableOffsets: recoverableOffsets, mappedFrames: [])
        }

        let records = try buildFrameIDMapRecords(
            mapURL: mapURL,
            tolerateTruncatedTail: true
        )
        var mappedFrames: [WALRecoveryMappedFrame] = []
        mappedFrames.reserveCapacity(records.count)

        var seenOffsets: Set<UInt64> = []
        var seenFrameIDs: Set<Int64> = []

        for record in records {
            guard let frameIndex = offsetToFrameIndex[record.frameOffset] else {
                Log.warning(
                    "[WAL] Ignoring frameID map entry for frame \(record.frameID) with unrecoverable offset \(record.frameOffset)",
                    category: .storage
                )
                continue
            }
            guard seenOffsets.insert(record.frameOffset).inserted else {
                Log.warning(
                    "[WAL] Ignoring duplicate frameID map offset \(record.frameOffset) while building recovery index",
                    category: .storage
                )
                continue
            }
            guard seenFrameIDs.insert(record.frameID).inserted else {
                Log.warning(
                    "[WAL] Ignoring duplicate frameID map entry for frame \(record.frameID) while building recovery index",
                    category: .storage
                )
                continue
            }

            mappedFrames.append(
                WALRecoveryMappedFrame(
                    frameID: record.frameID,
                    frameOffset: record.frameOffset,
                    frameIndex: frameIndex
                )
            )
        }

        mappedFrames.sort { $0.frameIndex < $1.frameIndex }
        return WALRecoveryIndex(recoverableOffsets: recoverableOffsets, mappedFrames: mappedFrames)
    }

    func debugRawReadOffsets(for videoID: VideoSegmentID) -> [UInt64] {
        debugRawReadOffsetsByVideoID[videoID.value] ?? []
    }

    func resetDebugRawReadOffsets(for videoID: VideoSegmentID? = nil) {
        if let videoID {
            debugRawReadOffsetsByVideoID.removeValue(forKey: videoID.value)
        } else {
            debugRawReadOffsetsByVideoID.removeAll()
        }
    }

    /// Rename an active WAL session out of the recovery path so launch can continue.
    /// Retained quarantines are preserved for manual inspection instead of timed cleanup.
    @discardableResult
    public func quarantineSession(
        _ session: WALSession,
        reason: String,
        disposition: WALQuarantineDisposition = .discardable
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: session.sessionDir.path) else {
            return session.sessionDir
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var destinationURL = walRootURL.appendingPathComponent(
            "\(quarantinePrefix(for: disposition))\(session.videoID.value)_\(timestamp)",
            isDirectory: true
        )
        var suffix = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = walRootURL.appendingPathComponent(
                "\(quarantinePrefix(for: disposition))\(session.videoID.value)_\(timestamp)_\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }

        try FileManager.default.moveItem(at: session.sessionDir, to: destinationURL)
        clearSessionCaches(videoIDValue: session.videoID.value)

        Log.warning(
            "[WAL] \(disposition.logLabel) session \(session.videoID.value) to \(destinationURL.lastPathComponent): \(reason)",
            category: .storage
        )

        return destinationURL
    }

    /// Read all frames only when their decoded pixels fit the requested budget.
    /// The maximum eager-read budget is 512 MiB; single-frame reads do not load the backlog.
    public func readFrames(
        from session: WALSession,
        maximumDecodedBytes: Int64 = 512 * 1024 * 1024
    ) async throws -> [CapturedFrame] {
        let fileSize = try await framesFileSize(for: session)
        if fileSize > Self.eagerReadSafetyLimitBytes {
            throw StorageError.fileReadFailed(
                path: session.framesURL.path,
                underlying: "WAL session too large for eager read (\(fileSize) bytes)"
            )
        }

        let offsets = try frameOffsets(
            for: session.videoID.value,
            framesURL: session.framesURL,
            currentFileSize: fileSize
        )
        // A small compressed file can expand to gigabytes. Inspect headers before
        // materializing any pixels, and allow callers to choose a smaller budget.
        let budget = min(maximumDecodedBytes, Self.eagerReadSafetyLimitBytes)
        let handle = try FileHandle(forReadingFrom: session.framesURL)
        defer { try? handle.close() }
        var decodedBytes: Int64 = 0
        for offset in offsets {
            try handle.seek(toOffset: offset)
            guard let record = try readRecordHeader(fileHandle: handle, path: session.framesURL.path),
                Int64(record.decodedSize) <= budget - decodedBytes
            else {
                throw StorageError.fileReadFailed(
                    path: session.framesURL.path,
                    underlying: "WAL session too large for eager read (decoded byte budget \(budget))"
                )
            }
            decodedBytes += Int64(record.decodedSize)
        }
        var frames: [CapturedFrame] = []
        frames.reserveCapacity(offsets.count)
        for offset in offsets {
            frames.append(try readFrame(videoID: session.videoID, atOffset: offset))
        }
        return frames
    }

    /// Read a single frame from an active WAL session by database frame ID.
    /// Active-session reads require a persisted frameID map entry so OCR never
    /// silently falls back to a drifted capture index.
    public func readFrame(videoID: VideoSegmentID, frameID: Int64, fallbackFrameIndex: Int) async throws -> CapturedFrame {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let mapURL = sessionDir.appendingPathComponent("frame_id_map.bin")

        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }

        if FileManager.default.fileExists(atPath: mapURL.path) {
            let mapFileSize = (try? FileManager.default.attributesOfItem(atPath: mapURL.path)[.size] as? Int64) ?? 0
            if mapFileSize > 0 {
                let offsetByFrameID = try frameIDOffsets(
                    for: videoID.value,
                    mapURL: mapURL,
                    currentFileSize: mapFileSize
                )
                if let mappedOffset = offsetByFrameID[frameID] {
                    return try readFrame(videoID: videoID, atOffset: mappedOffset)
                }
            }
        }

        throw StorageError.fileReadFailed(
            path: mapURL.path,
            underlying: "Incomplete WAL frameID map for frameID \(frameID); refusing fallback to frame index \(fallbackFrameIndex)"
        )
    }

    /// Read a single frame from an active WAL session by capture index.
    /// This avoids loading the entire WAL into memory when OCR needs one frame.
    public func readFrame(videoID: VideoSegmentID, frameIndex: Int) async throws -> CapturedFrame {
        guard frameIndex >= 0 else {
            throw StorageError.fileReadFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Frame index \(frameIndex) is negative"
            )
        }

        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }

        let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        if currentFileSize <= 0 {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "WAL file is empty")
        }

        let offsets = try frameOffsets(
            for: videoID.value,
            framesURL: framesURL,
            currentFileSize: currentFileSize
        )
        guard frameIndex < offsets.count else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Frame index \(frameIndex) out of range (0..<\(offsets.count))"
            )
        }

        return try readFrame(videoID: videoID, atOffset: offsets[frameIndex])
    }

    // MARK: - Private Helpers

    private static let headerSize = 36
    private static let frameIDMapRecordSize = MemoryLayout<Int64>.size + MemoryLayout<UInt64>.size

    /// Aggregate once per segment, rather than adding per-frame database/log writes.
    public func compressionStatistics(videoID: VideoSegmentID) -> (
        frameCount: Int, compressedFrameCount: Int, rawBytes: Int64,
        storedBytes: Int64, compressionMilliseconds: Double
    )? {
        guard let totals = compressionTotals[videoID.value] else { return nil }
        return (
            totals.frameCount, totals.compressedFrameCount, totals.rawBytes,
            totals.storedBytes, totals.compressionMilliseconds
        )
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    /// Returns nil when storing the original is smaller. Never retain output larger
    /// than the source, and never write an uncompressed intermediate to disk.
    private func compressPixels(_ pixels: Data) throws -> Data? {
        let chunkSize = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var stream = compression_stream(dst_ptr: output, dst_size: 0, src_ptr: output, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else {
            throw StorageError.fileWriteFailed(path: "WAL compression", underlying: "Cannot initialize LZFSE encoder")
        }
        defer { compression_stream_destroy(&stream) }
        return try pixels.withUnsafeBytes { input in
            stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = pixels.count
            var compressed = Data()
            while true {
                stream.dst_ptr = output
                stream.dst_size = chunkSize
                let previousInputSize = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw StorageError.fileWriteFailed(path: "WAL compression", underlying: "LZFSE encoding failed")
                }
                if produced >= pixels.count - compressed.count { return nil }
                compressed.append(output, count: produced)
                if status == COMPRESSION_STATUS_END { return compressed }
                guard produced > 0 || stream.src_size < previousInputSize else {
                    throw StorageError.fileWriteFailed(path: "WAL compression", underlying: "LZFSE encoder made no progress")
                }
            }
        }
    }

    /// V2 is self-describing in frames.bin, so loss of metadata.json cannot erase
    /// the codec/version. Per-record framing also allows legacy and V2 records together.
    private func readRecordHeader(fileHandle: FileHandle, path: String) throws -> WALRecordHeader? {
        guard let prefix = try fileHandle.read(upToCount: 8), !prefix.isEmpty else { return nil }
        guard prefix.count == 8 else {
            throw StorageError.fileReadFailed(path: path, underlying: "Incomplete WAL record prefix")
        }
        let record: WALRecordHeader
        if prefix == Self.recordMagic {
            let ext = try readExact(fileHandle: fileHandle, count: Self.recordExtensionSize - 8, path: path, label: "V2 record extension")
            let codecValue = ext.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard let codec = WALPayloadCodec(rawValue: codecValue) else {
                throw StorageError.fileReadFailed(path: path, underlying: "Unsupported WAL payload codec \(codecValue)")
            }
            let decodedSize = ext.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            let header = try parseFrameHeader(
                from: readExact(
                    fileHandle: fileHandle, count: Self.headerSize, path: path, label: "V2 frame header"
                ))
            record = WALRecordHeader(
                frame: header, codec: codec, decodedSize: decodedSize,
                checksum: Data(ext[8..<40]), headerByteCount: Self.headerSize + Self.recordExtensionSize
            )
        } else {
            var data = prefix
            data.append(try readExact(fileHandle: fileHandle, count: Self.headerSize - 8, path: path, label: "legacy frame header"))
            let header = try parseFrameHeader(from: data)
            record = WALRecordHeader(
                frame: header, codec: .raw, decodedSize: header.dataSize, checksum: nil, headerByteCount: Self.headerSize)
        }
        let header = record.frame
        let expectedSize = UInt64(header.bytesPerRow) * UInt64(header.height)
        let payloadSizeIsValid =
            record.codec == .raw
            ? header.dataSize == record.decodedSize : header.dataSize < record.decodedSize
        guard header.timestamp.isFinite, header.width > 0, header.height > 0,
            UInt64(header.bytesPerRow) >= UInt64(header.width) * 4,
            expectedSize > 0, expectedSize <= UInt64(Self.maximumFrameBytes),
            expectedSize == UInt64(record.decodedSize),
            header.dataSize > 0, header.dataSize <= Self.maximumFrameBytes,
            payloadSizeIsValid
        else {
            throw StorageError.fileReadFailed(path: path, underlying: "Invalid WAL frame size or dimensions")
        }
        return record
    }

    private func metadataNeedsRepair(_ metadata: WALMetadata) -> Bool {
        guard metadata.width > 0, metadata.height > 0, metadata.frameCount > 0 else {
            return true
        }

        return approximateFrameByteCount(width: metadata.width, height: metadata.height) == nil
    }

    private func approximateFrameByteCount(width: Int, height: Int) -> Int64? {
        guard width > 0, height > 0 else {
            return nil
        }

        let width64 = Int64(width)
        let height64 = Int64(height)
        let (pixelCount, pixelOverflow) = width64.multipliedReportingOverflow(by: height64)
        guard !pixelOverflow else {
            return nil
        }

        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, byteCount > 0 else {
            return nil
        }

        return byteCount
    }

    private func frameOffsets(for videoIDValue: Int64, framesURL: URL, currentFileSize: Int64) throws -> [UInt64] {
        if let cached = frameOffsetIndexCache[videoIDValue], cached.fileSize == currentFileSize {
            return cached.offsets
        }

        let offsets = try buildFrameOffsetIndex(framesURL: framesURL, currentFileSize: currentFileSize)
        frameOffsetIndexCache[videoIDValue] = WALFrameOffsetIndex(fileSize: currentFileSize, offsets: offsets)
        return offsets
    }

    private func frameIDOffsets(for videoIDValue: Int64, mapURL: URL, currentFileSize: Int64) throws -> [Int64: UInt64] {
        if let cached = frameIDOffsetIndexCache[videoIDValue], cached.fileSize == currentFileSize {
            return cached.offsetByFrameID
        }

        let index = try buildFrameIDOffsetIndex(mapURL: mapURL)
        frameIDOffsetIndexCache[videoIDValue] = WALFrameIDOffsetIndex(
            fileSize: currentFileSize,
            offsetByFrameID: index
        )
        return index
    }

    private func buildFrameIDOffsetIndex(mapURL: URL) throws -> [Int64: UInt64] {
        var offsetByFrameID: [Int64: UInt64] = [:]

        for record in try buildFrameIDMapRecords(mapURL: mapURL, tolerateTruncatedTail: false) {
            offsetByFrameID[record.frameID] = record.frameOffset
        }

        return offsetByFrameID
    }

    private func buildFrameIDMapRecords(
        mapURL: URL,
        tolerateTruncatedTail: Bool
    ) throws -> [WALFrameIDMapRecord] {
        guard let fileHandle = FileHandle(forReadingAtPath: mapURL.path) else {
            throw StorageError.fileReadFailed(
                path: mapURL.path,
                underlying: "Cannot open WAL frame map for indexing"
            )
        }
        defer { try? fileHandle.close() }

        var records: [WALFrameIDMapRecord] = []

        while true {
            guard let recordData = try? fileHandle.read(upToCount: Self.frameIDMapRecordSize), !recordData.isEmpty else {
                break
            }
            guard recordData.count == Self.frameIDMapRecordSize else {
                if tolerateTruncatedTail {
                    Log.warning(
                        "[WAL] Ignoring truncated frameID map tail in \(mapURL.lastPathComponent) (got \(recordData.count) bytes)",
                        category: .storage
                    )
                    break
                }

                throw StorageError.fileReadFailed(
                    path: mapURL.path,
                    underlying: "Incomplete frame map record (got \(recordData.count) bytes)"
                )
            }

            records.append(try parseFrameIDMapRecord(recordData, path: mapURL.path))
        }

        return records
    }

    private func appendFrameIDMapRecord(_ record: WALFrameIDMapRecord, to mapURL: URL) throws {
        guard let fileHandle = FileHandle(forWritingAtPath: mapURL.path) else {
            throw StorageError.fileWriteFailed(
                path: mapURL.path,
                underlying: "Cannot open frame map for appending"
            )
        }
        defer { try? fileHandle.close() }

        if #available(macOS 10.15.4, *) {
            try fileHandle.seekToEnd()
        } else {
            fileHandle.seekToEndOfFile()
        }

        var data = Data()
        var frameID = record.frameID
        var frameOffset = record.frameOffset
        withUnsafeBytes(of: &frameID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &frameOffset) { data.append(contentsOf: $0) }

        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: data)
        } else {
            fileHandle.write(data)
        }
    }

    private func cacheFrameIDMapRecord(videoIDValue: Int64, record: WALFrameIDMapRecord) {
        var cached = frameIDOffsetIndexCache[videoIDValue] ?? WALFrameIDOffsetIndex(
            fileSize: 0,
            offsetByFrameID: [:]
        )

        cached.offsetByFrameID[record.frameID] = record.frameOffset
        cached.fileSize = max(
            cached.fileSize + Int64(Self.frameIDMapRecordSize),
            Int64(cached.offsetByFrameID.count * Self.frameIDMapRecordSize)
        )
        frameIDOffsetIndexCache[videoIDValue] = cached
    }

    private func rebuildFrameIDMap(
        videoIDValue: Int64,
        mapURL: URL,
        appending newRecord: WALFrameIDMapRecord
    ) throws {
        var mergedRecords = existingFrameIDMapRecords(videoIDValue: videoIDValue, mapURL: mapURL)
        if let existingIndex = mergedRecords.firstIndex(where: { $0.frameID == newRecord.frameID }) {
            mergedRecords[existingIndex] = newRecord
        } else {
            mergedRecords.append(newRecord)
        }

        try replaceFrameIDMapFile(at: mapURL, with: mergedRecords)
        frameIDOffsetIndexCache[videoIDValue] = WALFrameIDOffsetIndex(
            fileSize: Int64(mergedRecords.count * Self.frameIDMapRecordSize),
            offsetByFrameID: Dictionary(uniqueKeysWithValues: mergedRecords.map { ($0.frameID, $0.frameOffset) })
        )
    }

    private func existingFrameIDMapRecords(videoIDValue: Int64, mapURL: URL) -> [WALFrameIDMapRecord] {
        if let cached = frameIDOffsetIndexCache[videoIDValue] {
            return cached.offsetByFrameID
                .map { WALFrameIDMapRecord(frameID: $0.key, frameOffset: $0.value) }
                .sorted { $0.frameOffset < $1.frameOffset }
        }

        return (try? buildFrameIDMapRecords(mapURL: mapURL, tolerateTruncatedTail: true)) ?? []
    }

    private func replaceFrameIDMapFile(at mapURL: URL, with records: [WALFrameIDMapRecord]) throws {
        if FileManager.default.fileExists(atPath: mapURL.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: mapURL.path)
            if let fileType = attributes?[.type] as? FileAttributeType, fileType != .typeRegular {
                try? FileManager.default.removeItem(at: mapURL)
            }
        }

        var data = Data()
        data.reserveCapacity(records.count * Self.frameIDMapRecordSize)
        for record in records {
            var frameID = record.frameID
            var frameOffset = record.frameOffset
            withUnsafeBytes(of: &frameID) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &frameOffset) { data.append(contentsOf: $0) }
        }

        do {
            try data.write(to: mapURL, options: .atomic)
        } catch {
            throw makeStorageWriteError(
                path: mapURL.path,
                error: error,
                fallback: "Failed to recreate WAL frame map"
            )
        }
    }

    private func createEmptyFile(at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StorageError.fileWriteFailed(
                path: url.path,
                underlying: "Cannot create file"
            )
        }
    }

    private func verifyWriteAccess() throws {
        let probeDirectoryURL = walRootURL.appendingPathComponent(
            ".wal_probe_\(UUID().uuidString)",
            isDirectory: true
        )
        let probeFileURL = probeDirectoryURL.appendingPathComponent("probe")

        do {
            try FileManager.default.createDirectory(
                at: probeDirectoryURL,
                withIntermediateDirectories: false
            )
            try createEmptyFile(at: probeFileURL)
            try FileManager.default.removeItem(at: probeDirectoryURL)
        } catch {
            if FileManager.default.fileExists(atPath: probeFileURL.path) {
                try? FileManager.default.removeItem(at: probeFileURL)
            }
            if FileManager.default.fileExists(atPath: probeDirectoryURL.path) {
                try? FileManager.default.removeItem(at: probeDirectoryURL)
            }

            let reason: String
            if isOutOfSpaceError(error) {
                reason = "Insufficient disk space while verifying WAL write access at \(walRootURL.path)"
            } else {
                reason = "Failed to verify WAL write access at \(walRootURL.path): \(error.localizedDescription)"
            }

            throw StorageError.walUnavailable(reason: reason)
        }
    }

    private func makeStorageWriteError(path: String, error: Error, fallback: String) -> StorageError {
        if isOutOfSpaceError(error) {
            return .insufficientDiskSpace
        }

        return .fileWriteFailed(path: path, underlying: "\(fallback): \(error.localizedDescription)")
    }

    private func isOutOfSpaceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOSPC {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlyingError.domain == NSCocoaErrorDomain, underlyingError.code == NSFileWriteOutOfSpaceError {
                return true
            }
            if underlyingError.domain == NSPOSIXErrorDomain, underlyingError.code == ENOSPC {
                return true
            }
        }

        return false
    }

    private func buildFrameOffsetIndex(framesURL: URL, currentFileSize: Int64) throws -> [UInt64] {
        guard let fileHandle = FileHandle(forReadingAtPath: framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Cannot open WAL for indexing"
            )
        }
        defer { try? fileHandle.close() }

        var offsets: [UInt64] = []
        let fileSize = UInt64(max(0, currentFileSize))

        while currentOffset(fileHandle: fileHandle) < fileSize {
            let frameOffset = currentOffset(fileHandle: fileHandle)
            let record: WALRecordHeader
            do {
                guard let parsed = try readRecordHeader(fileHandle: fileHandle, path: framesURL.path) else { break }
                record = parsed
            } catch StorageError.fileReadFailed(_, let reason) where reason.hasPrefix("Incomplete ") {
                // Only incomplete writes are a recoverable tail. Unknown codecs or
                // malformed complete headers must propagate so recovery retains
                // the session instead of deleting data it doesn't understand.
                Log.warning("[WAL] Ignoring truncated frame header at offset \(frameOffset): \(reason)", category: .storage)
                break
            }
            let nextOffset = frameOffset + UInt64(record.headerByteCount + record.metadataByteCount) + UInt64(record.frame.dataSize)
            guard nextOffset <= fileSize else {
                Log.warning("[WAL] Ignoring truncated frame payload at offset \(frameOffset)", category: .storage)
                break
            }
            offsets.append(frameOffset)
            try seek(fileHandle: fileHandle, toOffset: nextOffset)
        }

        return offsets
    }

    private func quarantinePrefix(for disposition: WALQuarantineDisposition) -> String {
        switch disposition {
        case .discardable:
            Self.discardableQuarantinePrefix
        case .retained:
            Self.retainedQuarantinePrefix
        }
    }

    private func isDiscardableQuarantineDirectory(_ directoryURL: URL) -> Bool {
        directoryURL.lastPathComponent.hasPrefix(Self.discardableQuarantinePrefix)
    }

    private func isQuarantineDirectory(_ directoryURL: URL) -> Bool {
        isDiscardableQuarantineDirectory(directoryURL)
            || directoryURL.lastPathComponent.hasPrefix(Self.retainedQuarantinePrefix)
    }

    private func quarantinedVideoID(for directoryURL: URL) -> Int64? {
        let components = directoryURL.lastPathComponent.split(separator: "_")
        guard components.count >= 4 else { return nil }
        return Int64(components[2])
    }

    private func quarantineDate(for directoryURL: URL) -> Date? {
        let components = directoryURL.lastPathComponent.split(separator: "_")
        guard components.count >= 4, let timestampMillis = Int64(components[3]) else {
            return nil
        }

        return Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
    }

    private func relocateInvalidWALRoot() throws -> URL {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var destinationURL = walRootURL.deletingLastPathComponent().appendingPathComponent(
            "wal.invalid.\(timestamp)",
            isDirectory: false
        )
        var suffix = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = walRootURL.deletingLastPathComponent().appendingPathComponent(
                "wal.invalid.\(timestamp).\(suffix)",
                isDirectory: false
            )
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: walRootURL, to: destinationURL)
        } catch {
            throw StorageError.walUnavailable(
                reason: "WAL path \(walRootURL.path) is not a directory and could not be repaired: \(error.localizedDescription)"
            )
        }

        return destinationURL
    }

    func readFrame(videoID: VideoSegmentID, atOffset frameOffset: UInt64) throws -> CapturedFrame {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard let fileHandle = FileHandle(forReadingAtPath: framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Cannot open WAL for reading"
            )
        }
        defer { try? fileHandle.close() }

        debugRawReadOffsetsByVideoID[videoID.value, default: []].append(frameOffset)

        try seek(fileHandle: fileHandle, toOffset: frameOffset)

        guard let record = try readRecordHeader(fileHandle: fileHandle, path: framesURL.path) else {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "Missing WAL frame header")
        }
        let header = record.frame

        let appBundleID = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.appBundleIDLength),
            path: framesURL.path,
            label: "appBundleID"
        )
        let appName = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.appNameLength),
            path: framesURL.path,
            label: "appName"
        )
        let windowName = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.windowNameLength),
            path: framesURL.path,
            label: "windowName"
        )
        let browserURL = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.browserURLLength),
            path: framesURL.path,
            label: "browserURL"
        )

        let payload = try readExact(
            fileHandle: fileHandle, count: Int(header.dataSize),
            path: framesURL.path, label: "pixel data at offset \(frameOffset)"
        )
        let pixelData: Data
        switch record.codec {
        case .raw:
            pixelData = payload
        case .lzfse:
            // The extra byte detects streams that expand beyond the declared size.
            // Validate dimensions/decoded length before allocating the destination.
            var decoded = Data(count: Int(record.decodedSize) + 1)
            let decodedCount = decoded.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                        nil, COMPRESSION_LZFSE
                    )
                }
            }
            guard decodedCount == Int(record.decodedSize) else {
                throw StorageError.fileReadFailed(path: framesURL.path, underlying: "Corrupt LZFSE frame or decoded size mismatch")
            }
            decoded.removeLast()
            pixelData = decoded
        }
        if let checksum = record.checksum, Data(SHA256.hash(data: pixelData)) != checksum {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "WAL frame checksum mismatch")
        }

        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: header.timestamp),
            imageData: pixelData,
            width: Int(header.width),
            height: Int(header.height),
            bytesPerRow: Int(header.bytesPerRow),
            metadata: FrameMetadata(
                appBundleID: appBundleID,
                appName: appName,
                windowName: windowName,
                browserURL: browserURL,
                displayID: header.displayID
            )
        )
    }

    private func currentOffset(fileHandle: FileHandle) -> UInt64 {
        if #available(macOS 10.15.4, *) {
            return (try? fileHandle.offset()) ?? 0
        } else {
            return fileHandle.offsetInFile
        }
    }

    private func seek(fileHandle: FileHandle, toOffset: UInt64) throws {
        if #available(macOS 10.15.4, *) {
            try fileHandle.seek(toOffset: toOffset)
        } else {
            fileHandle.seek(toFileOffset: toOffset)
        }
    }

    private func readExact(fileHandle: FileHandle, count: Int, path: String, label: String) throws -> Data {
        guard count >= 0 else {
            throw StorageError.fileReadFailed(path: path, underlying: "Invalid read size \(count) for \(label)")
        }
        if count == 0 {
            return Data()
        }

        guard let data = try? fileHandle.read(upToCount: count), data.count == count else {
            throw StorageError.fileReadFailed(
                path: path,
                underlying: "Incomplete \(label): expected \(count) bytes"
            )
        }
        return data
    }

    private func clearSessionCaches(videoIDValue: Int64) {
        compressionTotals.removeValue(forKey: videoIDValue)
        frameOffsetIndexCache.removeValue(forKey: videoIDValue)
        frameIDOffsetIndexCache.removeValue(forKey: videoIDValue)
    }

    private func readOptionalString(
        fileHandle: FileHandle,
        length: Int,
        path: String,
        label: String
    ) throws -> String? {
        if length == 0 {
            return nil
        }

        let data = try readExact(fileHandle: fileHandle, count: length, path: path, label: label)
        return String(data: data, encoding: .utf8)
    }

    private func saveMetadata(_ metadata: WALMetadata, to dir: URL) throws {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func loadMetadata(from dir: URL) throws -> WALMetadata {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func rebuildMetadata(videoID: VideoSegmentID, framesURL: URL) throws -> WALMetadata? {
        let currentFileSize = (try FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        guard currentFileSize > 0 else {
            return nil
        }

        let offsets = try frameOffsets(
            for: videoID.value,
            framesURL: framesURL,
            currentFileSize: currentFileSize
        )
        guard let firstOffset = offsets.first else {
            return nil
        }

        guard let fileHandle = FileHandle(forReadingAtPath: framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Cannot open WAL for metadata rebuild"
            )
        }
        defer { try? fileHandle.close() }

        try seek(fileHandle: fileHandle, toOffset: firstOffset)
        guard let record = try readRecordHeader(fileHandle: fileHandle, path: framesURL.path) else { return nil }
        let header = record.frame

        return WALMetadata(
            videoID: videoID,
            startTime: Date(timeIntervalSince1970: header.timestamp),
            frameCount: offsets.count,
            width: Int(header.width),
            height: Int(header.height),
            durableReadableFrameCount: 0,
            durableVideoFileSizeBytes: 0
        )
    }

    private func placeholderMetadata(for videoID: VideoSegmentID) -> WALMetadata {
        WALMetadata(
            videoID: videoID,
            startTime: Date(timeIntervalSince1970: 0),
            frameCount: 0,
            width: 0,
            height: 0,
            durableReadableFrameCount: 0,
            durableVideoFileSizeBytes: 0
        )
    }

    private func repairMetadataIfNeeded(
        _ metadata: WALMetadata,
        videoID: VideoSegmentID,
        sessionDir: URL,
        framesURL: URL
    ) throws -> WALMetadata {
        let framesFileSize = (try FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        guard framesFileSize > 0 else {
            return metadata
        }

        let needsRepair = metadataNeedsRepair(metadata)
        guard needsRepair, let rebuiltMetadata = try rebuildMetadata(videoID: videoID, framesURL: framesURL) else {
            return metadata
        }

        var repairedMetadata = rebuiltMetadata
        repairedMetadata.durableReadableFrameCount = metadata.durableReadableFrameCount
        repairedMetadata.durableVideoFileSizeBytes = metadata.durableVideoFileSizeBytes

        do {
            try saveMetadata(repairedMetadata, to: sessionDir)
        } catch {
            Log.warning(
                "[WAL] Repaired stale metadata for session \(videoID.value) but failed to persist rebuilt sidecar: \(error.localizedDescription)",
                category: .storage
            )
        }

        Log.warning(
            "[WAL] Repaired stale metadata for session \(videoID.value) from recoverable WAL frames",
            category: .storage
        )
        return repairedMetadata
    }

    private func parseFrameHeader(from data: Data) throws -> WALFrameHeader {
        // Header size: 8+4+4+4+4+4+2+2+2+2 = 36 bytes
        let expectedHeaderSize = 36
        guard data.count >= expectedHeaderSize else {
            throw StorageError.fileReadFailed(
                path: "WAL header",
                underlying: "Incomplete header: expected \(expectedHeaderSize) bytes, got \(data.count)"
            )
        }

        var offset = 0

        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            // Bounds check to prevent crash on corrupted data
            guard offset + size <= data.count else {
                throw StorageError.fileReadFailed(
                    path: "WAL header",
                    underlying: "Out of bounds read at offset \(offset) for \(size) bytes (data size: \(data.count))"
                )
            }
            let value = data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: type)) }
            offset += size
            return value
        }

        return WALFrameHeader(
            timestamp: Double(bitPattern: try read(UInt64.self)),
            width: try read(UInt32.self),
            height: try read(UInt32.self),
            bytesPerRow: try read(UInt32.self),
            dataSize: try read(UInt32.self),
            displayID: try read(UInt32.self),
            appBundleIDLength: try read(UInt16.self),
            appNameLength: try read(UInt16.self),
            windowNameLength: try read(UInt16.self),
            browserURLLength: try read(UInt16.self)
        )
    }

    private func parseFrameIDMapRecord(_ data: Data, path: String) throws -> WALFrameIDMapRecord {
        guard data.count == Self.frameIDMapRecordSize else {
            throw StorageError.fileReadFailed(
                path: path,
                underlying: "Invalid frame map record size \(data.count)"
            )
        }

        let frameID = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int64.self) }
        let frameOffset = data.withUnsafeBytes { $0.load(fromByteOffset: MemoryLayout<Int64>.size, as: UInt64.self) }
        return WALFrameIDMapRecord(frameID: frameID, frameOffset: frameOffset)
    }
}

// MARK: - Models

/// WAL session representing an active segment being recorded
public struct WALSession: Sendable {
    public let videoID: VideoSegmentID
    public let sessionDir: URL
    public let framesURL: URL
    public var metadata: WALMetadata

    public init(videoID: VideoSegmentID, sessionDir: URL, framesURL: URL, metadata: WALMetadata) {
        self.videoID = videoID
        self.sessionDir = sessionDir
        self.framesURL = framesURL
        self.metadata = metadata
    }
}

/// Metadata for a WAL session
public struct WALMetadata: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case videoID
        case startTime
        case frameCount
        case width
        case height
        case durableReadableFrameCount
        case durableVideoFileSizeBytes
    }

    public let videoID: VideoSegmentID
    public let startTime: Date
    public var frameCount: Int
    public var width: Int
    public var height: Int
    public var durableReadableFrameCount: Int
    public var durableVideoFileSizeBytes: Int64

    public init(
        videoID: VideoSegmentID,
        startTime: Date,
        frameCount: Int,
        width: Int,
        height: Int,
        durableReadableFrameCount: Int,
        durableVideoFileSizeBytes: Int64
    ) {
        self.videoID = videoID
        self.startTime = startTime
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.durableReadableFrameCount = durableReadableFrameCount
        self.durableVideoFileSizeBytes = durableVideoFileSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.videoID = try container.decode(VideoSegmentID.self, forKey: .videoID)
        self.startTime = try container.decode(Date.self, forKey: .startTime)
        self.frameCount = try container.decode(Int.self, forKey: .frameCount)
        self.width = try container.decode(Int.self, forKey: .width)
        self.height = try container.decode(Int.self, forKey: .height)
        self.durableReadableFrameCount = try container.decodeIfPresent(Int.self, forKey: .durableReadableFrameCount) ?? 0
        self.durableVideoFileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .durableVideoFileSizeBytes) ?? 0
    }
}

/// Frame header in WAL binary format (36 bytes fixed size + variable metadata strings)
private struct WALFrameHeader {
    let timestamp: Double           // 8 bytes - Unix timestamp
    let width: UInt32              // 4 bytes
    let height: UInt32             // 4 bytes
    let bytesPerRow: UInt32        // 4 bytes
    let dataSize: UInt32  // 4 bytes - stored payload size (compressed in V2)
    let displayID: UInt32          // 4 bytes
    let appBundleIDLength: UInt16  // 2 bytes
    let appNameLength: UInt16      // 2 bytes
    let windowNameLength: UInt16   // 2 bytes
    let browserURLLength: UInt16   // 2 bytes
    // Total: 36 bytes (8+20+8)
    // Followed by: appBundleID, appName, windowName, browserURL (UTF-8 strings)
    // Followed by: stored pixel payload (dataSize bytes)
}

private enum WALPayloadCodec: UInt32 {
    case raw = 0
    case lzfse = 1
}

private struct WALRecordHeader {
    let frame: WALFrameHeader
    let codec: WALPayloadCodec
    let decodedSize: UInt32
    let checksum: Data?
    let headerByteCount: Int

    var metadataByteCount: Int {
        Int(frame.appBundleIDLength) + Int(frame.appNameLength)
            + Int(frame.windowNameLength) + Int(frame.browserURLLength)
    }
}

private struct WALCompressionTotals {
    var frameCount = 0
    var compressedFrameCount = 0
    var rawBytes: Int64 = 0
    var storedBytes: Int64 = 0
    var compressionMilliseconds: Double = 0
}

private struct WALFrameOffsetIndex {
    let fileSize: Int64
    let offsets: [UInt64]
}

struct WALRecoveryIndex: Sendable {
    let recoverableOffsets: [UInt64]
    let mappedFrames: [WALRecoveryMappedFrame]
}

struct WALRecoveryMappedFrame: Sendable {
    let frameID: Int64
    let frameOffset: UInt64
    let frameIndex: Int
}

private struct WALFrameIDOffsetIndex {
    var fileSize: Int64
    var offsetByFrameID: [Int64: UInt64]
}

private struct WALFrameIDMapRecord {
    let frameID: Int64
    let frameOffset: UInt64
}
