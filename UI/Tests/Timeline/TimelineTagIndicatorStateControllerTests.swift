import XCTest
import Shared
@testable import Retrace

@MainActor
final class TimelineTagIndicatorStateControllerTests: XCTestCase {
    private let invalidate = {}
    private let noopCallbacks = TimelineCommentsStore.TagIndicatorUpdateCallbacks(
        invalidate: {},
        didUpdateAvailableTags: {},
        didUpdateSegmentTagsMap: {},
        didUpdateSegmentCommentCountsMap: {}
    )

    func testSettersMarkLoadedStateAndPublishStoredData() {
        let store = TimelineCommentsStore()
        let tags = [
            Tag(id: TagID(value: 2), name: "Beta"),
            Tag(id: TagID(value: 1), name: "Alpha")
        ]
        let selectedTags = Set([TagID(value: 1)])
        let segmentTagsMap: [Int64: Set<Int64>] = [42: Set([1, 2])]
        let commentCounts: [Int64: Int] = [42: 3]

        store.setAvailableTags(tags, invalidate: invalidate)
        store.setSelectedSegmentTags(selectedTags, invalidate: invalidate)
        store.setSegmentTagsMap(segmentTagsMap, invalidate: invalidate)
        store.setSegmentCommentCountsMap(commentCounts, invalidate: invalidate)

        XCTAssertEqual(store.tagIndicatorState.availableTags, tags)
        XCTAssertEqual(store.tagIndicatorState.selectedSegmentTags, selectedTags)
        XCTAssertEqual(store.tagIndicatorState.segmentTagsMap, segmentTagsMap)
        XCTAssertEqual(store.tagIndicatorState.segmentCommentCountsMap, commentCounts)
        XCTAssertTrue(store.tagIndicatorState.hasLoadedAvailableTags)
        XCTAssertTrue(store.tagIndicatorState.hasLoadedSegmentTagsMap)
        XCTAssertTrue(store.tagIndicatorState.hasLoadedSegmentCommentCountsMap)
    }

    func testOptimisticMutationsUpdateSelectionMapsAndSortedAvailableTags() {
        let store = TimelineCommentsStore()
        let alpha = Tag(id: TagID(value: 1), name: "Alpha")
        let beta = Tag(id: TagID(value: 2), name: "Beta")
        let segmentIDs = Set([SegmentID(value: 101), SegmentID(value: 202)])
        let callbacks = TimelineCommentsStore.OptimisticSnapshotCallbacks(
            invalidate: invalidate,
            refreshSnapshotImmediately: { _ in }
        )

        store.appendAvailableTagIfNeeded(beta, invalidate: invalidate)
        store.appendAvailableTagIfNeeded(alpha, invalidate: invalidate)
        store.appendAvailableTagIfNeeded(alpha, invalidate: invalidate)
        store.selectSelectedSegmentTag(alpha.id, invalidate: invalidate)
        store.addTagToSegments(tagID: alpha.id, segmentIDs: segmentIDs, callbacks: callbacks)
        store.incrementCommentCounts(for: segmentIDs, callbacks: callbacks)
        store.incrementCommentCounts(for: Set([SegmentID(value: 101)]), callbacks: callbacks)
        store.deselectSelectedSegmentTag(alpha.id, invalidate: invalidate)
        store.removeTagFromSegments(tagID: alpha.id, segmentIDs: Set([SegmentID(value: 202)]), callbacks: callbacks)
        store.decrementCommentCounts(for: Set([SegmentID(value: 202)]), callbacks: callbacks)

        XCTAssertEqual(store.tagIndicatorState.availableTags.map(\.name), ["Alpha", "Beta"])
        XCTAssertTrue(store.tagIndicatorState.selectedSegmentTags.isEmpty)
        XCTAssertEqual(store.tagIndicatorState.segmentTagsMap[101], Set([1]))
        XCTAssertNil(store.tagIndicatorState.segmentTagsMap[202])
        XCTAssertEqual(store.tagIndicatorState.segmentCommentCountsMap[101], 2)
        XCTAssertNil(store.tagIndicatorState.segmentCommentCountsMap[202])
    }

    func testResetLoadedStateClearsFlagsButPreservesCachedData() {
        let store = TimelineCommentsStore()
        store.setAvailableTags([Tag(id: TagID(value: 1), name: "Alpha")], invalidate: invalidate)
        store.setSegmentTagsMap([42: Set([1])], invalidate: invalidate)
        store.setSegmentCommentCountsMap([42: 1], invalidate: invalidate)

        store.resetLoadedTagIndicatorState(invalidate: invalidate)

        XCTAssertEqual(store.tagIndicatorState.availableTags.map(\.name), ["Alpha"])
        XCTAssertEqual(store.tagIndicatorState.segmentTagsMap[42], Set([1]))
        XCTAssertEqual(store.tagIndicatorState.segmentCommentCountsMap[42], 1)
        XCTAssertFalse(store.tagIndicatorState.hasLoadedAvailableTags)
        XCTAssertFalse(store.tagIndicatorState.hasLoadedSegmentTagsMap)
        XCTAssertFalse(store.tagIndicatorState.hasLoadedSegmentCommentCountsMap)
    }

    @MainActor
    func testCommentsStoreLoadTagsPublishesAvailableAndSelectedSegmentTags() async {
        let store = TimelineCommentsStore()
        let availableTags = [
            Tag(id: TagID(value: 1), name: "Alpha"),
            Tag(id: TagID(value: 2), name: "Beta")
        ]
        let selectedSegmentTags = [
            Tag(id: TagID(value: 2), name: "Beta")
        ]
        var requestedSegmentIDs: [SegmentID] = []

        await store.loadTags(
            context: .init(
                timelineContextMenuSegmentIndex: 7,
                selectedSegmentID: SegmentID(value: 42)
            ),
            fetchAllTags: {
                availableTags
            },
            fetchTagsForSegment: { segmentID in
                requestedSegmentIDs.append(segmentID)
                return selectedSegmentTags
            },
            callbacks: noopCallbacks
        )

        XCTAssertEqual(requestedSegmentIDs, [SegmentID(value: 42)])
        XCTAssertEqual(store.tagIndicatorState.availableTags.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(store.tagIndicatorState.selectedSegmentTags, Set([TagID(value: 2)]))
    }

    @MainActor
    func testCommentsStoreEnsureTagIndicatorDataLoadedIfNeededCoalescesAndPublishesData() async {
        let store = TimelineCommentsStore()
        let gate = SharedAsyncTestGate()
        var fetchTagsCallCount = 0

        store.ensureTagIndicatorDataLoadedIfNeeded(
            hasFrames: true,
            fetchAllTags: {
                fetchTagsCallCount += 1
                await gate.enterAndWait()
                return [Tag(id: TagID(value: 1), name: "Alpha")]
            },
            fetchSegmentTagsMap: {
                [42: Set([1])]
            },
            fetchSegmentCommentCountsMap: {
                [42: 3]
            },
            callbacks: noopCallbacks
        )
        store.ensureTagIndicatorDataLoadedIfNeeded(
            hasFrames: true,
            fetchAllTags: {
                fetchTagsCallCount += 1
                return []
            },
            fetchSegmentTagsMap: {
                [:]
            },
            fetchSegmentCommentCountsMap: {
                [:]
            },
            callbacks: noopCallbacks
        )

        await gate.waitUntilEntered()
        XCTAssertEqual(fetchTagsCallCount, 1)

        await gate.release()
        await waitUntil {
            store.tagIndicatorState.hasLoadedAvailableTags &&
            store.tagIndicatorState.hasLoadedSegmentTagsMap &&
            store.tagIndicatorState.hasLoadedSegmentCommentCountsMap
        }

        XCTAssertEqual(store.tagIndicatorState.availableTags.map(\.name), ["Alpha"])
        XCTAssertEqual(store.tagIndicatorState.segmentTagsMap[42], Set([1]))
        XCTAssertEqual(store.tagIndicatorState.segmentCommentCountsMap[42], 3)
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
