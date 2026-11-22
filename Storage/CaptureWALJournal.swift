import Foundation
import Shared

/// Serial capture ingress. Owns only the current journal writer per display;
/// queued receipts retain older writers until their frames have been consumed.
public actor CaptureWALJournal {
    private let storage: any StorageProtocol
    private let segmentFrameLimit: Int
    private var generation: UInt64 = 0
    private var current: [UInt32: (writer: any SegmentWriter, width: Int, height: Int, count: Int)] = [:]

    public init(storage: any StorageProtocol, segmentFrameLimit: Int = 150) {
        self.storage = storage
        self.segmentFrameLimit = segmentFrameLimit
    }

    public func rotate() {
        generation &+= 1
        current.removeAll()
    }

    public func persist(_ frame: CapturedFrame) async throws -> CapturedFrame {
        let generation = self.generation
        let displayID = frame.metadata.displayID
        var entry = current[displayID]
        if entry == nil || entry!.width != frame.width || entry!.height != frame.height || entry!.count >= segmentFrameLimit {
            entry = (try await storage.createSegmentWriter(), frame.width, frame.height, 0)
        }
        var active = entry!
        let index = try await active.writer.persistFrameToWAL(frame)
        active.count = index + 1
        if self.generation == generation { current[displayID] = active }
        let receipt = CapturedFrameJournalReceipt(writer: active.writer,
            segmentID: await active.writer.segmentID, frameIndex: index)
        return CapturedFrame(timestamp: frame.timestamp, imageData: frame.imageData,
            width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
            metadata: frame.metadata, accessibilitySnapshot: frame.accessibilitySnapshot,
            journalReceipt: receipt)
    }
}
