import AppKit
import App
import Shared
import XCTest
@testable import Retrace

final class CommentComposerTargetContextTests: XCTestCase {
    @MainActor
    func testLoadCommentsForSelectedTimelineBlockCoalescesDuplicateInFlightRequest() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let frame = makeCommentTargetTimelineFrame()
        let segmentID = SegmentID(value: frame.frame.segmentID.value)
        let gate = AsyncTestGate()
        let comment = makeSegmentComment(
            id: 1,
            body: "Existing comment",
            frameID: frame.frame.id,
            createdAt: Date(timeIntervalSince1970: 1_710_000_010)
        )
        var fetchCount = 0

        viewModel.frames = [frame]
        viewModel.timelineContextMenuSegmentIndex = 0
        viewModel.test_blockCommentsHooks.getCommentsForSegments = { requestedSegmentIDs in
            XCTAssertEqual(requestedSegmentIDs, [segmentID])
            fetchCount += 1
            await gate.enterAndWait()
            return [self.makeLinkedSegmentComment(comment, preferredSegmentID: segmentID)]
        }

        let initialLoad = Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
        await gate.waitUntilEntered()

        let duplicateLoad = Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
        try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertTrue(viewModel.isLoadingBlockComments)

        await gate.release()
        await initialLoad.value
        await duplicateLoad.value

        XCTAssertEqual(viewModel.selectedBlockComments, [comment])
        XCTAssertEqual(viewModel.preferredSegmentIDForSelectedBlockComment(comment.id), segmentID)
        XCTAssertFalse(viewModel.isLoadingBlockComments)
    }

    @MainActor
    func testLoadCommentsForSelectedTimelineBlockForceRefreshPublishesLatestResult() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let frame = makeCommentTargetTimelineFrame()
        let segmentID = SegmentID(value: frame.frame.segmentID.value)
        let gate = AsyncTestGate()
        let initialComment = makeSegmentComment(
            id: 1,
            body: "Initial comment",
            frameID: frame.frame.id,
            createdAt: Date(timeIntervalSince1970: 1_710_000_010)
        )
        let refreshedComment = makeSegmentComment(
            id: 2,
            body: "Refreshed comment",
            frameID: frame.frame.id,
            createdAt: Date(timeIntervalSince1970: 1_710_000_020)
        )
        var fetchCount = 0

        viewModel.frames = [frame]
        viewModel.timelineContextMenuSegmentIndex = 0
        viewModel.test_blockCommentsHooks.getCommentsForSegments = { requestedSegmentIDs in
            XCTAssertEqual(requestedSegmentIDs, [segmentID])
            fetchCount += 1

            if fetchCount == 1 {
                await gate.enterAndWait()
                return [self.makeLinkedSegmentComment(initialComment, preferredSegmentID: segmentID)]
            }

            return [self.makeLinkedSegmentComment(refreshedComment, preferredSegmentID: segmentID)]
        }

        let initialLoad = Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
        await gate.waitUntilEntered()

        let forcedReload = Task { await viewModel.loadCommentsForSelectedTimelineBlock(forceRefresh: true) }
        try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        XCTAssertEqual(fetchCount, 2)

        await forcedReload.value
        XCTAssertEqual(viewModel.selectedBlockComments, [refreshedComment])
        XCTAssertEqual(viewModel.preferredSegmentIDForSelectedBlockComment(refreshedComment.id), segmentID)

        await gate.release()
        await initialLoad.value

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(viewModel.selectedBlockComments, [refreshedComment])
        XCTAssertFalse(viewModel.isLoadingBlockComments)
    }

    @MainActor
    func testAddCommentToSelectedSegmentCancelsInFlightThreadReloadAndPublishesLatestComments() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let frame = makeCommentTargetTimelineFrame()
        let segmentID = SegmentID(value: frame.frame.segmentID.value)
        let gate = AsyncTestGate()
        let refreshedLoadRan = expectation(description: "refreshed load ran")
        let existingComment = makeSegmentComment(
            id: 10,
            body: "Existing comment",
            frameID: frame.frame.id,
            createdAt: Date(timeIntervalSince1970: 1_710_000_010)
        )
        let insertedComment = makeSegmentComment(
            id: 11,
            body: "New comment",
            frameID: frame.frame.id,
            createdAt: Date(timeIntervalSince1970: 1_710_000_020)
        )
        var fetchCount = 0
        var createCount = 0

        viewModel.frames = [frame]
        viewModel.timelineContextMenuSegmentIndex = 0
        viewModel.newCommentText = insertedComment.body
        viewModel.test_blockCommentsHooks.getCommentsForSegments = { requestedSegmentIDs in
            XCTAssertEqual(requestedSegmentIDs, [segmentID])
            fetchCount += 1

            if fetchCount == 1 {
                await gate.enterAndWait()
                return [self.makeLinkedSegmentComment(existingComment, preferredSegmentID: segmentID)]
            }

            refreshedLoadRan.fulfill()
            return [
                self.makeLinkedSegmentComment(existingComment, preferredSegmentID: segmentID),
                self.makeLinkedSegmentComment(insertedComment, preferredSegmentID: segmentID)
            ]
        }
        viewModel.test_blockCommentsHooks.createCommentForSegments = { body, requestedSegmentIDs, attachments, frameID, author in
            createCount += 1
            XCTAssertEqual(body, insertedComment.body)
            XCTAssertEqual(requestedSegmentIDs, [segmentID])
            XCTAssertTrue(attachments.isEmpty)
            XCTAssertEqual(frameID, frame.frame.id)
            XCTAssertNil(author)
            return AppCoordinator.SegmentCommentCreateResult(
                comment: insertedComment,
                linkedSegmentIDs: [segmentID],
                skippedSegmentIDs: [],
                failedSegmentIDs: []
            )
        }

        let initialLoad = Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
        await gate.waitUntilEntered()

        viewModel.addCommentToSelectedSegment()
        await fulfillment(of: [refreshedLoadRan], timeout: 1.0)

        await gate.release()
        await initialLoad.value

        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(viewModel.selectedBlockComments, [existingComment, insertedComment])
        XCTAssertEqual(viewModel.preferredSegmentIDForSelectedBlockComment(insertedComment.id), segmentID)
        XCTAssertEqual(viewModel.newCommentText, "")
        XCTAssertFalse(viewModel.isLoadingBlockComments)
        XCTAssertFalse(viewModel.isAddingComment)
    }

    @MainActor
    func testResolveTagSubmenuAnchorIndexPrefersRequestedIndexInsideBlock() {
        let block = AppBlock(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            startIndex: 30,
            endIndex: 36,
            frameCount: 7,
            tagIDs: [],
            hasComments: false,
            gapBeforeSeconds: nil
        )

        let resolvedIndex = SimpleTimelineViewModel.resolveTagSubmenuAnchorIndex(
            requestedIndex: 34,
            in: block
        )

        XCTAssertEqual(resolvedIndex, 34)
    }

    @MainActor
    func testResolveTagSubmenuAnchorIndexFallsBackToBlockStart() {
        let block = AppBlock(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            startIndex: 30,
            endIndex: 36,
            frameCount: 7,
            tagIDs: [],
            hasComments: false,
            gapBeforeSeconds: nil
        )

        let resolvedIndex = SimpleTimelineViewModel.resolveTagSubmenuAnchorIndex(
            requestedIndex: 41,
            in: block
        )

        XCTAssertEqual(resolvedIndex, 30)
    }

    @MainActor
    func testOpenTagSubmenuForSelectedCommentTargetKeepsCommentModalOpen() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [makeCommentTargetTimelineFrame()]
        viewModel.timelineContextMenuSegmentIndex = 0
        viewModel.selectedFrameIndex = 0
        viewModel.showCommentSubmenu = true
        viewModel.showTimelineContextMenu = false
        viewModel.showTagSubmenu = false

        viewModel.openTagSubmenuForSelectedCommentTarget()

        XCTAssertEqual(viewModel.timelineContextMenuSegmentIndex, 0)
        XCTAssertEqual(viewModel.selectedFrameIndex, 0)
        XCTAssertTrue(viewModel.showCommentSubmenu)
        XCTAssertTrue(viewModel.showTagSubmenu)
        XCTAssertFalse(viewModel.showTimelineContextMenu)
    }

    @MainActor
    func testOpenTagSubmenuForSelectedCommentTargetTogglesClosedWhenAlreadyVisible() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [makeCommentTargetTimelineFrame()]
        viewModel.timelineContextMenuSegmentIndex = 0
        viewModel.selectedFrameIndex = 0
        viewModel.showCommentSubmenu = true
        viewModel.showTimelineContextMenu = false
        viewModel.showTagSubmenu = true

        viewModel.openTagSubmenuForSelectedCommentTarget()

        XCTAssertTrue(viewModel.showCommentSubmenu)
        XCTAssertFalse(viewModel.showTagSubmenu)
        XCTAssertFalse(viewModel.showTimelineContextMenu)
    }

    @MainActor
    func testResolvePreferredCommentTargetIndexPrefersCurrentIndexInsideBlock() {
        let block = AppBlock(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            startIndex: 10,
            endIndex: 16,
            frameCount: 7,
            tagIDs: [],
            hasComments: false,
            gapBeforeSeconds: nil
        )

        let resolvedIndex = SimpleTimelineViewModel.resolvePreferredCommentTargetIndex(
            in: block,
            currentIndex: 14,
            selectedFrameIndex: 10,
            timelineContextMenuSegmentIndex: 10
        )

        XCTAssertEqual(resolvedIndex, 14)
    }

    @MainActor
    func testResolvePreferredCommentTargetIndexFallsBackToSelectedFrameIndex() {
        let block = AppBlock(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            startIndex: 20,
            endIndex: 25,
            frameCount: 6,
            tagIDs: [],
            hasComments: false,
            gapBeforeSeconds: nil
        )

        let resolvedIndex = SimpleTimelineViewModel.resolvePreferredCommentTargetIndex(
            in: block,
            currentIndex: 9,
            selectedFrameIndex: 23,
            timelineContextMenuSegmentIndex: 20
        )

        XCTAssertEqual(resolvedIndex, 23)
    }

    @MainActor
    func testMakeCommentComposerTargetContextPrefersWindowNameAndSortsTagNames() {
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 42),
                timestamp: Date(timeIntervalSince1970: 1_710_000_000),
                segmentID: AppSegmentID(value: 11),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "Pricing Deck - Acme",
                    browserURL: "https://acme.test/deck"
                )
            ),
            videoInfo: nil,
            processingStatus: 2
        )

        let block = AppBlock(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            startIndex: 0,
            endIndex: 4,
            frameCount: 5,
            tagIDs: [7, 3],
            hasComments: false,
            gapBeforeSeconds: nil
        )

        let context = SimpleTimelineViewModel.makeCommentComposerTargetDisplayInfo(
            timelineFrame: timelineFrame,
            block: block,
            availableTagsByID: [
                3: Tag(id: TagID(value: 3), name: "Follow Up"),
                7: Tag(id: TagID(value: 7), name: "Action Item")
            ]
        )

        XCTAssertEqual(context.title, "Pricing Deck - Acme")
        XCTAssertEqual(context.subtitle, "Google Chrome")
        XCTAssertEqual(context.browserURL, "https://acme.test/deck")
        XCTAssertEqual(context.tagNames, ["Action Item", "Follow Up"])
    }

    @MainActor
    func testMakeCommentComposerTargetContextFallsBackToSelectedSegmentTags() {
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 88),
                timestamp: Date(timeIntervalSince1970: 1_710_100_000),
                segmentID: AppSegmentID(value: 19),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: nil,
                    windowName: nil,
                    browserURL: nil
                )
            ),
            videoInfo: nil,
            processingStatus: 2
        )

        let context = SimpleTimelineViewModel.makeCommentComposerTargetDisplayInfo(
            timelineFrame: timelineFrame,
            block: nil,
            availableTagsByID: [
                5: Tag(id: TagID(value: 5), name: "Later")
            ],
            selectedSegmentTagIDs: [5]
        )

        XCTAssertEqual(context.title, "com.apple.Safari")
        XCTAssertNil(context.subtitle)
        XCTAssertEqual(context.tagNames, ["Later"])
    }

    @MainActor
    func testQuickCommentRefreshTargetUsesInjectedPreviewLoader() async {
        let persistedPreview = NSImage(size: NSSize(width: 4, height: 4))
        let frame = FrameWithVideoInfo(
            frame: FrameReference(
                id: FrameID(value: 501),
                timestamp: Date(timeIntervalSince1970: 1_710_200_000),
                segmentID: AppSegmentID(value: 41),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Inbox",
                    browserURL: "https://example.com"
                )
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-preview.mp4",
                frameIndex: 0,
                frameRate: 1
            ),
            processingStatus: 2
        )

        let viewModel = QuickCommentComposerViewModel(
            coordinator: AppCoordinator(),
            source: "test",
            recentFramesLoader: { [frame] in [frame] },
            previewImageLoader: { _ in persistedPreview }
        )

        let didRefresh = await viewModel.refreshTarget(initialLoad: true)

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(viewModel.target?.frameID, frame.frame.id)
        XCTAssertEqual(viewModel.target?.title, "Inbox")
        XCTAssertEqual(viewModel.target?.subtitle, "Safari")
        XCTAssertTrue(viewModel.previewImage === persistedPreview)
    }

    @MainActor
    func testQuickCommentPrepareInitialTargetDoesNotLoadTagsUntilRequested() async {
        let persistedPreview = NSImage(size: NSSize(width: 4, height: 4))
        let frame = FrameWithVideoInfo(
            frame: FrameReference(
                id: FrameID(value: 601),
                timestamp: Date(timeIntervalSince1970: 1_710_200_100),
                segmentID: AppSegmentID(value: 42),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Inbox",
                    browserURL: "https://example.com"
                )
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-preview.mp4",
                frameIndex: 0,
                frameRate: 1
            ),
            processingStatus: 2
        )

        let viewModel = QuickCommentComposerViewModel(
            coordinator: AppCoordinator(),
            source: "test",
            recentFramesLoader: { [frame] in [frame] },
            previewImageLoader: { _ in persistedPreview }
        )

        let didPrepare = await viewModel.prepareInitialTarget()

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(viewModel.target?.frameID, frame.frame.id)
        XCTAssertTrue(viewModel.availableTags.isEmpty)
        XCTAssertNil(viewModel.messageText)
        XCTAssertFalse(viewModel.messageIsError)
    }

    @MainActor
    func testQuickCommentRefreshTargetPrefersTimelineDiskBufferPreview() async throws {
        let frame = FrameWithVideoInfo(
            frame: FrameReference(
                id: FrameID(value: 999_501),
                timestamp: Date(timeIntervalSince1970: 1_710_200_000),
                segmentID: AppSegmentID(value: 41),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Inbox",
                    browserURL: "https://example.com"
                )
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/nonexistent-preview.mp4",
                frameIndex: 0,
                frameRate: 1
            ),
            processingStatus: 2
        )
        let cachedPreview = makeSolidImage(size: NSSize(width: 7, height: 5), color: .systemRed)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frame.frame.id)

        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeJPEGData(cachedPreview).write(to: cacheFileURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: cacheFileURL)
        }

        let viewModel = QuickCommentComposerViewModel(
            coordinator: AppCoordinator(),
            source: "test",
            recentFramesLoader: { [frame] in [frame] }
        )

        let didRefresh = await viewModel.refreshTarget(initialLoad: true)

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(viewModel.target?.frameID, frame.frame.id)
        XCTAssertEqual(viewModel.previewImage?.size.width, cachedPreview.size.width)
        XCTAssertEqual(viewModel.previewImage?.size.height, cachedPreview.size.height)
    }

    @MainActor
    func testQuickCommentPinningDoesNotResumeLiveRefreshAfterClearingText() {
        let viewModel = QuickCommentComposerViewModel(
            coordinator: AppCoordinator(),
            source: "test"
        )

        XCTAssertFalse(viewModel.shouldFreezeLiveRefresh)

        viewModel.pinTargetForEditing()
        viewModel.newCommentText = "Draft"
        viewModel.newCommentText = ""

        XCTAssertTrue(viewModel.shouldFreezeLiveRefresh)
    }

    @MainActor
    func testRefreshTapeIndicatorsPublishesLatestResultWhenNewRefreshCancelsOldOne() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let frame = makeCommentTargetTimelineFrame()
        let segmentID = frame.frame.segmentID.value
        let gate = AsyncTestGate()
        let secondRefreshRan = expectation(description: "second refresh ran")
        var fetchCount = 0

        viewModel.frames = [frame]
        viewModel.test_tapeIndicatorRefreshHooks.fetchIndicatorData = {
            fetchCount += 1

            if fetchCount == 1 {
                await gate.enterAndWait()
                return (
                    tags: [Tag(id: TagID(value: 1), name: "First")],
                    segmentTagsMap: [segmentID: Set([1])],
                    segmentCommentCountsMap: [segmentID: 1]
                )
            }

            secondRefreshRan.fulfill()
            return (
                tags: [Tag(id: TagID(value: 2), name: "Second")],
                segmentTagsMap: [segmentID: Set([2])],
                segmentCommentCountsMap: [segmentID: 2]
            )
        }

        viewModel.refreshTapeIndicatorsAfterExternalMutation(reason: "tag-add")
        await gate.waitUntilEntered()

        viewModel.refreshTapeIndicatorsAfterExternalMutation(reason: "comment-add")
        await fulfillment(of: [secondRefreshRan], timeout: 1.0)

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(viewModel.availableTags.map(\.name), ["Second"])
        XCTAssertEqual(viewModel.segmentTagsMap[segmentID], Set([2]))
        XCTAssertEqual(viewModel.segmentCommentCountsMap[segmentID], 2)

        await gate.release()
        try? await Task.sleep(for: .milliseconds(10), clock: .continuous)

        XCTAssertEqual(viewModel.availableTags.map(\.name), ["Second"])
        XCTAssertEqual(viewModel.segmentTagsMap[segmentID], Set([2]))
        XCTAssertEqual(viewModel.segmentCommentCountsMap[segmentID], 2)
    }

    private func makeCommentTargetTimelineFrame() -> TimelineFrame {
        TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 1),
                timestamp: Date(timeIntervalSince1970: 1_710_000_000),
                segmentID: AppSegmentID(value: 11),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowName: "Inbox Zero",
                    browserURL: "https://example.com"
                )
            ),
            videoInfo: nil,
            processingStatus: 2
        )
    }

    private func makeSegmentComment(
        id: Int64,
        body: String,
        frameID: FrameID? = nil,
        createdAt: Date
    ) -> SegmentComment {
        SegmentComment(
            id: SegmentCommentID(value: id),
            body: body,
            author: "Test Author",
            attachments: [],
            frameID: frameID,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeLinkedSegmentComment(
        _ comment: SegmentComment,
        preferredSegmentID: SegmentID
    ) -> AppCoordinator.LinkedSegmentComment {
        AppCoordinator.LinkedSegmentComment(
            comment: comment,
            preferredSegmentID: preferredSegmentID
        )
    }

    private func timelineDiskBufferFileURL(frameID: FrameID) -> URL {
        SimpleTimelineViewModel.timelineDiskFrameBufferFileURL(for: frameID)
    }

    private func makeSolidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func makeJPEGData(_ image: NSImage) throws -> Data {
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(
            bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        )
    }
}

private actor AsyncTestGate {
    private var didEnter = false
    private var enterContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        enterContinuation?.resume()
        enterContinuation = nil

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }

        await withCheckedContinuation { continuation in
            enterContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
