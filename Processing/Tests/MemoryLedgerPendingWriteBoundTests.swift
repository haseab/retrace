import XCTest
import Shared

/// `MemoryLedger` chains every pending write onto its predecessor, so each one keeps a
/// live `Task` alive that retains the one before it. Before the fire-and-forget entry
/// points were capped, a writer that outran the drain grew that chain without bound --
/// an unthrottled loop in `OCRStageMemoryLedgerCostTests` killed the test process with
/// signal 10, and `flushPendingUpdates()` had to await the whole backlog to return.
final class MemoryLedgerPendingWriteBoundTests: XCTestCase {

    private let tagPrefix = "test.memoryLedger.pendingWriteBound"

    override func tearDown() async throws {
        await MemoryLedger.flushPendingUpdates()
        try await super.tearDown()
    }

    func testFireAndForgetFloodStaysWithinBacklogLimit() async {
        let limit = MemoryLedger.pendingWriteDiagnostics.limit
        let droppedBefore = MemoryLedger.pendingWriteDiagnostics.dropped

        // Far more writes than the drain can retire while the loop runs. Unbounded,
        // this is the shape that used to kill the process.
        var maxObservedDepth = 0
        for index in 0..<20_000 {
            MemoryLedger.set(
                tag: "\(tagPrefix).flood",
                bytes: Int64(index),
                function: "test.memoryLedger",
                kind: "telemetry"
            )
            maxObservedDepth = max(maxObservedDepth, MemoryLedger.pendingWriteDiagnostics.depth)
        }

        XCTAssertLessThanOrEqual(
            maxObservedDepth,
            limit,
            "Pending-write backlog grew past its cap; the chain is unbounded again."
        )
        XCTAssertGreaterThan(
            MemoryLedger.pendingWriteDiagnostics.dropped,
            droppedBefore,
            "20,000 fire-and-forget writes outran the drain but nothing was dropped, "
                + "so this test is no longer exercising the cap."
        )

        // The whole point of the cap: flushing cannot be left awaiting an unbounded
        // chain. Generous bound -- this is a liveness check, not a timing assertion.
        let start = Date()
        await MemoryLedger.flushPendingUpdates()
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
        XCTAssertEqual(MemoryLedger.pendingWriteDiagnostics.depth, 0)

        await MemoryLedger.removeOrdered(tag: "\(tagPrefix).flood")
    }

    func testAcceptedWritesStillLandAndOrderedWritesAreNeverDropped() async {
        let tag = "\(tagPrefix).ordered"

        // Saturate the backlog first, so the ordered write below is issued precisely
        // when the fire-and-forget path is refusing work.
        for index in 0..<20_000 {
            MemoryLedger.set(
                tag: "\(tagPrefix).noise",
                bytes: Int64(index),
                function: "test.memoryLedger",
                kind: "telemetry"
            )
        }

        let droppedBeforeOrdered = MemoryLedger.pendingWriteDiagnostics.dropped
        await MemoryLedger.setOrdered(
            tag: tag,
            bytes: 4_096,
            function: "test.memoryLedger",
            kind: "telemetry"
        )
        XCTAssertEqual(
            MemoryLedger.pendingWriteDiagnostics.dropped,
            droppedBeforeOrdered,
            "An ordered write was dropped; only fire-and-forget writes may be refused."
        )

        let snapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let ordered = snapshot.components.first { $0.tag == tag }
        XCTAssertEqual(ordered?.bytes, 4_096, "The ordered write never reached the store.")

        // A dropped `set` must not stop later writes to the same tag from landing.
        let noise = snapshot.components.first { $0.tag == "\(tagPrefix).noise" }
        XCTAssertNotNil(noise, "Every fire-and-forget write was dropped, not just the excess.")

        await MemoryLedger.removeOrdered(tag: tag)
        await MemoryLedger.removeOrdered(tag: "\(tagPrefix).noise")
    }
}
