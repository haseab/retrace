import Foundation
import Shared

/// Single-producer/single-consumer handoff. The capture scheduler owns the sole
/// producer: never launch a Task per send. At most one captured frame waits here
/// outside the queue, and the consumer pulls directly without a second buffer.
actor BoundedFrameChannel {
    private let frameLimit: Int
    private let byteLimit: Int
    private var frames: [CapturedFrame] = []
    private(set) var bufferedBytes = 0
    private var finished = false
    private var receiver: CheckedContinuation<CapturedFrame?, Never>?
    private var sender: (id: UUID, frame: CapturedFrame, continuation: CheckedContinuation<Bool, Never>)?

    init(frameLimit: Int, byteLimit: Int) {
        precondition(frameLimit > 0 && byteLimit > 0)
        self.frameLimit = frameLimit
        self.byteLimit = byteLimit
    }

    var bufferedFrameCount: Int { frames.count }
    var isWaitingToSend: Bool { sender != nil }

    nonisolated var stream: AsyncStream<CapturedFrame> {
        AsyncStream(unfolding: { await self.next() }, onCancel: {
            Task { await self.abort() }
        })
    }

    func send(_ frame: CapturedFrame) async -> Bool {
        guard !finished, !Task.isCancelled else { return false }
        guard sender == nil else {
            // A violated producer contract must not turn into an unbounded list
            // of suspended tasks retaining screenshots.
            Log.error("Concurrent capture frame producers are unsupported", category: .capture)
            return false
        }
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
            return true
        }
        if canBuffer(frame) {
            append(frame)
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                sender = (id, frame, continuation)
            }
        } onCancel: {
            Task { await self.cancelSend(id) }
        }
    }

    private func next() async -> CapturedFrame? {
        guard !Task.isCancelled else {
            abort()
            return nil
        }
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            bufferedBytes -= frame.imageData.count
            if let sender, canBuffer(sender.frame) {
                self.sender = nil
                append(sender.frame)
                sender.continuation.resume(returning: true)
            }
            return frame
        }
        if let sender {
            // Screenshots larger than the byte budget bypass the queue through
            // direct handoff; they never require increasing that budget.
            self.sender = nil
            sender.continuation.resume(returning: true)
            return sender.frame
        }
        guard !finished, receiver == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                receiver = continuation
                if Task.isCancelled { abort() }
            }
        } onCancel: {
            Task { await self.abort() }
        }
    }

    private func canBuffer(_ frame: CapturedFrame) -> Bool {
        frames.count < frameLimit && frame.imageData.count <= byteLimit - bufferedBytes
    }

    private func append(_ frame: CapturedFrame) {
        frames.append(frame)
        bufferedBytes += frame.imageData.count
    }

    private func cancelSend(_ id: UUID) {
        guard let sender, sender.id == id else { return }
        self.sender = nil
        sender.continuation.resume(returning: false)
    }

    /// Normal producer completion keeps accepted work available to the consumer.
    func finish() {
        finished = true
        if frames.isEmpty && sender == nil {
            let receiver = self.receiver
            self.receiver = nil
            receiver?.resume(returning: nil)
        }
    }

    /// Emergency/consumer cancellation wakes both sides without draining. Pixels
    /// admitted through production ingress already have recovery WAL records.
    func abort() {
        finished = true
        frames.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        let sender = self.sender
        let receiver = self.receiver
        self.sender = nil
        self.receiver = nil
        sender?.continuation.resume(returning: false)
        receiver?.resume(returning: nil)
    }
}
