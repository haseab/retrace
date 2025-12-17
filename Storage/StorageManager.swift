import AppKit
import AVFoundation
import Foundation
import Shared

/// Main StorageProtocol implementation.
public actor StorageManager: StorageProtocol {
    private var config: StorageConfig?
    private var storageRootURL: URL
    private let directoryManager: DirectoryManager
    private let encoderConfig: VideoEncoderConfig

    public init(
        storageRoot: URL = URL(fileURLWithPath: StorageConfig.default.expandedStorageRootPath, isDirectory: true),
        encoderConfig: VideoEncoderConfig = .default
    ) {
        self.storageRootURL = storageRoot
        self.directoryManager = DirectoryManager(storageRoot: storageRoot)
        self.encoderConfig = encoderConfig
    }

    public func initialize(config: StorageConfig) async throws {
        self.config = config
        let rootPath = config.expandedStorageRootPath
        storageRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        await directoryManager.updateRoot(storageRootURL)
        try await directoryManager.ensureBaseDirectories()
    }

    public func createSegmentWriter() async throws -> SegmentWriter {
        guard config != nil else {
            throw StorageError.directoryCreationFailed(path: "Storage not initialized")
        }

        let segmentID = SegmentID()
        let now = Date()
        let fileURL = try await directoryManager.segmentURL(for: segmentID, date: now)
        let relative = await directoryManager.relativePath(from: fileURL)

        return try SegmentWriterImpl(
            segmentID: segmentID,
            fileURL: fileURL,
            relativePath: relative,
            encoderConfig: encoderConfig
        )
    }

    public func readFrame(segmentID: SegmentID, timestamp: Date) async throws -> Data {
        // Get segment path - files are MP4 without extension (no decryption needed)
        let segmentURL = try await getSegmentPath(id: segmentID)
        let asset = AVAsset(url: segmentURL)

        // Verify video track exists
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "No video track")
        }

        // Get segment start time from metadata (embedded during encoding)
        let metadata = try await asset.load(.metadata)
        var segmentStart: Date?

        for item in metadata {
            if item.identifier == .quickTimeMetadataCreationDate,
               let value = try await item.load(.value) as? String {
                // Parse ISO 8601 date string
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                segmentStart = formatter.date(from: value)
                break
            }
        }

        // Fallback: try common metadata if custom metadata not found
        if segmentStart == nil {
            if let creationDateItem = try await asset.load(.creationDate),
               let date = try await creationDateItem.load(.dateValue) {
                segmentStart = date
            }
        }

        guard let segmentStart else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "No creation date metadata found")
        }

        // Calculate time relative to segment start
        let relativeSeconds = timestamp.timeIntervalSince(segmentStart)

        // Ensure we're not seeking before the start or after the end
        guard relativeSeconds >= 0 else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Requested timestamp before segment start")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: relativeSeconds, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw StorageError.fileReadFailed(path: segmentURL.path, underlying: "Failed to convert frame")
        }

        return jpegData
    }

    public func getSegmentPath(id: SegmentID) async throws -> URL {
        let files = try await directoryManager.listAllSegmentFiles()
        if let match = files.first(where: { $0.lastPathComponent.contains(id.stringValue) }) {
            return match
        }
        throw StorageError.fileNotFound(path: id.stringValue)
    }

    public func deleteSegment(id: SegmentID) async throws {
        let url = try await getSegmentPath(id: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StorageError.fileWriteFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    public func segmentExists(id: SegmentID) async throws -> Bool {
        (try? await getSegmentPath(id: id)) != nil
    }


    public func getTotalStorageUsed() async throws -> Int64 {
        let files = try await directoryManager.listAllSegmentFiles()
        var total: Int64 = 0
        for url in files {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    public func getAvailableDiskSpace() async throws -> Int64 {
        try DiskSpaceMonitor.availableBytes(at: storageRootURL)
    }

    public func cleanupOldSegments(olderThan date: Date) async throws -> [SegmentID] {
        let files = try await directoryManager.listAllSegmentFiles()
        var deleted: [SegmentID] = []

        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modDate = values?.contentModificationDate ?? Date.distantFuture
            guard modDate < date else { continue }

            if let id = parseSegmentID(from: url) {
                deleted.append(id)
            }
            try? FileManager.default.removeItem(at: url)
        }

        return deleted
    }

    public func getStorageDirectory() -> URL {
        storageRootURL
    }

    // MARK: - Private helpers

    private func parseSegmentID(from url: URL) -> SegmentID? {
        // No extension to delete - files are stored without extensions
        let name = url.lastPathComponent
        guard name.hasPrefix("segment_") else { return nil }
        let uuidString = name.replacingOccurrences(of: "segment_", with: "")
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        return SegmentID(value: uuid)
    }
}
