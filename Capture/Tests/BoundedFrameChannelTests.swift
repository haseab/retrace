import XCTest
import ImageIO
import Shared
@testable import Capture

final class BoundedFrameChannelTests: XCTestCase {
    private func screenshot(_ sequence: Int) throws -> CapturedFrame {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(CaptureFrameCandidate(image: image, timestamp: Date(timeIntervalSince1970: Double(sequence)), metadata: FrameMetadata(displayID: 1)).materialize())
    }

    private func waitForBlockedSend(_ channel: BoundedFrameChannel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await channel.isWaitingToSend), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let waiting = await channel.isWaitingToSend
        XCTAssertTrue(waiting)
    }

    func testFullQueueSuspendsProducerAndStreamConsumesInOrderWithoutPrefetch() async throws {
        let frames = try (0..<4).map(screenshot)
        let channel = BoundedFrameChannel(frameLimit: 2, byteLimit: frames[0].imageData.count * 4)
        let firstSent = await channel.send(frames[0])
        let secondSent = await channel.send(frames[1])
        XCTAssertTrue(firstSent && secondSent)
        let producer = Task { await channel.send(frames[2]) }
        await waitForBlockedSend(channel)
        let depth = await channel.bufferedFrameCount
        XCTAssertEqual(depth, 2)
        var iterator = channel.stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.timestamp, frames[0].timestamp)
        let admitted = await producer.value
        XCTAssertTrue(admitted)
        let depthAfterRead = await channel.bufferedFrameCount
        XCTAssertEqual(depthAfterRead, 2) // no hidden AsyncStream prefetch buffer
        for expected in frames[1...2] {
            let actual = await iterator.next()
            XCTAssertEqual(actual?.timestamp, expected.timestamp)
            XCTAssertEqual(actual?.imageData, expected.imageData)
        }
        await channel.finish()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testGracefulFinishDrainsQueuedAndWaitingFrames() async throws {
        let frames = try (0..<2).map(screenshot)
        let channel = BoundedFrameChannel(frameLimit: 1, byteLimit: frames[0].imageData.count)
        _ = await channel.send(frames[0])
        let producer = Task { await channel.send(frames[1]) }
        await waitForBlockedSend(channel)
        await channel.finish()
        var iterator = channel.stream.makeAsyncIterator()
        for expected in frames {
            let actual = await iterator.next()
            XCTAssertEqual(actual?.timestamp, expected.timestamp)
        }
        let admitted = await producer.value
        XCTAssertTrue(admitted)
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testByteBudgetAppliesBeforeFrameCountLimit() async throws {
        let frame = try screenshot(1)
        let channel = BoundedFrameChannel(frameLimit: 8, byteLimit: frame.imageData.count)
        _ = await channel.send(frame)
        let producer = Task { await channel.send(frame) }
        await waitForBlockedSend(channel)
        let bytes = await channel.bufferedBytes
        let count = await channel.bufferedFrameCount
        XCTAssertEqual(bytes, frame.imageData.count)
        XCTAssertEqual(count, 1)
        await channel.abort()
        let admitted = await producer.value
        XCTAssertFalse(admitted)
    }

    func testOversizedFrameUsesDirectHandoffWithoutExceedingQueueBudget() async throws {
        let frame = try screenshot(1)
        let channel = BoundedFrameChannel(frameLimit: 8, byteLimit: 1)
        let producer = Task { await channel.send(frame) }
        await waitForBlockedSend(channel)
        let bytes = await channel.bufferedBytes
        XCTAssertEqual(bytes, 0)
        var iterator = channel.stream.makeAsyncIterator()
        let actual = await iterator.next()
        let admitted = await producer.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(actual?.imageData, frame.imageData)
        await channel.finish()
    }

    func testCancelledBlockedProducerReleasesItsFrameAndAllowsAnotherSend() async throws {
        let first = try screenshot(1)
        let second = try screenshot(2)
        let channel = BoundedFrameChannel(frameLimit: 1, byteLimit: first.imageData.count)
        _ = await channel.send(first)
        let cancelledProducer = Task { await channel.send(second) }
        await waitForBlockedSend(channel)
        cancelledProducer.cancel()
        let admitted = await cancelledProducer.value
        XCTAssertFalse(admitted)
        let waiting = await channel.isWaitingToSend
        XCTAssertFalse(waiting)
        var iterator = channel.stream.makeAsyncIterator()
        let actual = await iterator.next()
        XCTAssertEqual(actual?.timestamp, first.timestamp)
        let next = await channel.send(second)
        XCTAssertTrue(next)
        await channel.finish()
    }

    func testCancelledConsumerClosesChannelAndFutureSendsDoNotHang() async throws {
        let channel = BoundedFrameChannel(frameLimit: 1, byteLimit: 1024)
        let consumer = Task {
            var iterator = channel.stream.makeAsyncIterator()
            return await iterator.next()
        }
        consumer.cancel()
        let result = await consumer.value
        XCTAssertNil(result)
        let admitted = await channel.send(try screenshot(1))
        XCTAssertFalse(admitted)
    }

    func testLifecycleEventUsesSameBoundedFIFOAndWakesIdleConsumer() async throws {
        let frame = try screenshot(1)
        let channel = BoundedFrameChannel(frameLimit: 1, byteLimit: frame.imageData.count)
        _ = await channel.send(frame)
        let producer = Task { await channel.send(.retainDisplays([7])) }
        await waitForBlockedSend(channel)
        var iterator = channel.eventStream.makeAsyncIterator()
        guard case .frame(let received) = await iterator.next() else { return XCTFail("Expected queued screenshot") }
        XCTAssertEqual(received.imageData, frame.imageData)
        let sent = await producer.value
        XCTAssertTrue(sent)
        guard case .retainDisplays(let displays) = await iterator.next() else { return XCTFail("Expected lifecycle event") }
        XCTAssertEqual(displays, [7])
        let consumer = Task { await iterator.next() }
        _ = await channel.send(.retainDisplays([]))
        guard case .retainDisplays(let empty) = await consumer.value else { return XCTFail("Idle consumer must wake") }
        XCTAssertTrue(empty.isEmpty)
        await channel.finish()
    }
}
