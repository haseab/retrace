import SwiftUI
import Shared

extension SimpleTimelineViewModel {
    // MARK: - Segment Comments + Tags

    public func loadCommentsForSelectedTimelineBlock(forceRefresh: Bool = false) async {
        await commentsStore.loadSelectedBlockComments(
            segmentIDs: selectedTimelineBlockOrderedSegmentIDs() ?? [],
            forceRefresh: forceRefresh,
            fetchLinkedComments: fetchLinkedCommentsForSelectedTimelineBlock,
            invalidate: { [weak self] in self?.notifyCommentStateWillChange() }
        )
    }

    public func preferredSegmentIDForSelectedBlockComment(_ commentID: SegmentCommentID) -> SegmentID? {
        commentsStore.preferredSegmentID(for: commentID)
    }

    func selectedTimelineBlockOrderedSegmentIDs() -> [SegmentID]? {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            return nil
        }
        return getOrderedSegmentIds(inBlock: block)
    }

    func fetchLinkedCommentsForSelectedTimelineBlock(
        _ segmentIDs: [SegmentID]
    ) async throws -> [TimelineLinkedSegmentComment] {
#if DEBUG
        if let override = test_blockCommentsHooks.getCommentsForSegments {
            return try await override(segmentIDs)
        }
#endif
        return try await coordinator.getCommentsForSegments(segmentIds: segmentIDs).map {
            (comment: $0.comment, preferredSegmentID: $0.preferredSegmentID)
        }
    }

    public func loadTags() async {
        await commentsStore.loadTags(
            context: currentTagLoadContext(),
            fetchAllTags: { [weak self] in
                guard let self else { return [] }
                return try await self.coordinator.getAllTags()
            },
            fetchTagsForSegment: { [weak self] segmentID in
                guard let self else { return [] }
                return try await self.coordinator.getTagsForSegment(segmentId: segmentID)
            },
            callbacks: makeCommentTagIndicatorCallbacks()
        )
    }

    func ensureTapeTagIndicatorDataLoadedIfNeeded() {
        commentsStore.ensureTagIndicatorDataLoadedIfNeeded(
            hasFrames: !frames.isEmpty,
            fetchAllTags: { [weak self] in
                guard let self else { return [] }
                return try await self.coordinator.getAllTags()
            },
            fetchSegmentTagsMap: { [weak self] in
                guard let self else { return [:] }
                return try await self.coordinator.getSegmentTagsMap()
            },
            fetchSegmentCommentCountsMap: { [weak self] in
                guard let self else { return [:] }
                return try await self.coordinator.getSegmentCommentCountsMap()
            },
            callbacks: makeCommentTagIndicatorCallbacks()
        )
    }

    func refreshTapeIndicatorsAfterExternalMutation(reason: String) {
        commentsStore.refreshTagIndicatorDataFromDatabase(
            hasFrames: !frames.isEmpty,
            reason: reason,
            fetch: { [weak self] in
                guard let self else { return (tags: [], segmentTagsMap: [:], segmentCommentCountsMap: [:]) }
#if DEBUG
                if let override = self.test_tapeIndicatorRefreshHooks.fetchIndicatorData {
                    return try await override()
                }
#endif
                async let tagsTask = self.coordinator.getAllTags()
                async let segmentTagsTask = self.coordinator.getSegmentTagsMap()
                async let commentCountsTask = self.coordinator.getSegmentCommentCountsMap()
                return try await (tagsTask, segmentTagsTask, commentCountsTask)
            },
            callbacks: makeCommentTagIndicatorCallbacks()
        )
    }

    var hiddenTagIDValue: Int64? {
        blockSnapshotController.hiddenTagIDValue
    }

    public func getSegmentId(forFrameAt index: Int) -> SegmentID? {
        guard index >= 0 && index < frames.count else { return nil }
        return SegmentID(value: frames[index].frame.segmentID.value)
    }

    func getAppSegmentId(forFrameAt index: Int) -> AppSegmentID? {
        guard index >= 0 && index < frames.count else { return nil }
        return frames[index].frame.segmentID
    }

    func isFrameFromRewind(at index: Int) -> Bool {
        guard index >= 0 && index < frames.count else { return false }
        return frames[index].frame.source == .rewind
    }

    public func hideSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if hidingSegmentBlockRange != nil {
            Log.debug("[Tags] Hide ignored - hide animation already in progress", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot hide Rewind data")
            dismissTimelineContextMenu()
            return
        }

        performHideSegment(segmentIds: getSegmentIds(inBlock: block), block: block)
    }

    func performHideSegment(segmentIds: Set<SegmentID>, block: AppBlock) {
        DashboardViewModel.recordSegmentHide(
            coordinator: coordinator,
            source: "timeline_context",
            segmentCount: segmentIds.count,
            frameCount: block.frameCount,
            hiddenFilter: filterCriteria.hiddenFilter.rawValue
        )

        for segmentId in segmentIds {
            filterStore.insertHiddenSegmentID(segmentId, invalidate: notifyFilterStateWillChange)
        }

        dismissTimelineContextMenu()

        withAnimation(.easeInOut(duration: 0.16)) {
            hidingSegmentBlockRange = block.startIndex...block.endIndex
        }

        Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(160_000_000)), clock: .continuous)

            let beforeCount = frames.count
            let mutation = frameWindowStore.removeFrames(
                matching: segmentIds,
                from: frames,
                currentIndex: currentIndex,
                preserveCurrentFrameID: currentTimelineFrame?.frame.id
            )
            mutateFramesOptimistically(reason: .hideSegmentRemoveFrames) {
                frames = mutation.frames
            }
            let removedCount = beforeCount - frames.count

            currentIndex = mutation.resultingCurrentIndex
            hidingSegmentBlockRange = nil

            refreshCurrentFramePresentation()
            checkAndLoadMoreFrames(reason: "performHideSegment.postRemoval")

            Log.debug("[Tags] Hidden \(segmentIds.count) segments in block, removed \(removedCount) frames from UI", category: .ui)
        }

        Task {
            do {
                try await coordinator.hideSegments(segmentIds: Array(segmentIds))
                Log.debug("[Tags] \(segmentIds.count) segments hidden in database", category: .ui)
            } catch {
                Log.error("[Tags] Failed to hide segments in database: \(error)", category: .ui)
            }
        }
    }

    public func unhideSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if hidingSegmentBlockRange != nil {
            Log.debug("[Tags] Unhide ignored - hide/unhide animation already in progress", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot modify Rewind data")
            dismissTimelineContextMenu()
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        let segmentIdsToUnhide = Set(segmentIds.filter { hiddenSegmentIds.contains($0) })
        guard !segmentIdsToUnhide.isEmpty else {
            Log.debug("[Tags] Unhide ignored - no hidden segments found in selected block", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        performUnhideSegment(segmentIdsToUnhide: segmentIdsToUnhide, block: block)
    }

    func performUnhideSegment(segmentIdsToUnhide: Set<SegmentID>, block: AppBlock) {
        let shouldRemoveFromCurrentView = filterCriteria.hiddenFilter == .onlyHidden
        DashboardViewModel.recordSegmentUnhide(
            coordinator: coordinator,
            source: "timeline_context",
            segmentCount: segmentIdsToUnhide.count,
            frameCount: block.frameCount,
            hiddenFilter: filterCriteria.hiddenFilter.rawValue,
            removedFromCurrentView: shouldRemoveFromCurrentView
        )

        for segmentId in segmentIdsToUnhide {
            filterStore.removeHiddenSegmentID(segmentId, invalidate: notifyFilterStateWillChange)
        }

        dismissTimelineContextMenu()

        if shouldRemoveFromCurrentView {
            withAnimation(.easeInOut(duration: 0.16)) {
                hidingSegmentBlockRange = block.startIndex...block.endIndex
            }

            Task { @MainActor in
                try? await Task.sleep(for: .nanoseconds(Int64(160_000_000)), clock: .continuous)

                let beforeCount = frames.count
                let mutation = frameWindowStore.removeFrames(
                    matching: segmentIdsToUnhide,
                    from: frames,
                    currentIndex: currentIndex,
                    preserveCurrentFrameID: currentTimelineFrame?.frame.id
                )
                mutateFramesOptimistically(reason: .unhideSegmentRemoveFrames) {
                    frames = mutation.frames
                }
                let removedCount = beforeCount - frames.count

                currentIndex = mutation.resultingCurrentIndex
                hidingSegmentBlockRange = nil

                refreshCurrentFramePresentation()
                checkAndLoadMoreFrames(reason: "performUnhideSegment.postRemoval")

                Log.debug("[Tags] Unhidden \(segmentIdsToUnhide.count) segments in block, removed \(removedCount) frames from Only Hidden view", category: .ui)
            }
        } else {
            Log.debug("[Tags] Unhidden \(segmentIdsToUnhide.count) segments in block (kept visible in current filter mode)", category: .ui)
        }

        Task {
            do {
                guard let hiddenTag = try await coordinator.getTag(name: Tag.hiddenTagName) else {
                    Log.debug("[Tags] Hidden tag missing during unhide; nothing to remove in database", category: .ui)
                    return
                }
                try await coordinator.removeTagFromSegments(segmentIds: Array(segmentIdsToUnhide), tagId: hiddenTag.id)
                Log.debug("[Tags] \(segmentIdsToUnhide.count) segments unhidden in database", category: .ui)
            } catch {
                Log.error("[Tags] Failed to unhide segments in database: \(error)", category: .ui)
            }
        }
    }

    public func addTagToSelectedSegment(tag: Tag) {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            dismissTimelineContextMenu()
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)

        commentsStore.addTagToSegments(
            tagID: tag.id,
            segmentIDs: segmentIds,
            callbacks: makeCommentOptimisticSnapshotCallbacks()
        )

        dismissTimelineContextMenu()

        Task {
            do {
                try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                Log.debug("[Tags] Added tag '\(tag.name)' to \(segmentIds.count) segments in block", category: .ui)
            } catch {
                Log.error("[Tags] Failed to add tag to segments: \(error)", category: .ui)
            }
        }
    }

    public func toggleTagOnSelectedSegment(
        tag: Tag,
        source: String = "timeline_tag_submenu"
    ) {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        let isCurrentlySelected = selectedSegmentTags.contains(tag.id)
        let action = isCurrentlySelected ? "remove" : "add"

        DashboardViewModel.recordTagToggleOnBlock(
            coordinator: coordinator,
            source: source,
            tagID: tag.id.value,
            tagName: tag.name,
            action: action,
            segmentCount: segmentIds.count
        )

        if isCurrentlySelected {
            commentsStore.deselectSelectedSegmentTag(tag.id, invalidate: notifyCommentStateWillChange)
            commentsStore.removeTagFromSegments(
                tagID: tag.id,
                segmentIDs: segmentIds,
                callbacks: makeCommentOptimisticSnapshotCallbacks()
            )
        } else {
            commentsStore.selectSelectedSegmentTag(tag.id, invalidate: notifyCommentStateWillChange)
            commentsStore.addTagToSegments(
                tagID: tag.id,
                segmentIDs: segmentIds,
                callbacks: makeCommentOptimisticSnapshotCallbacks()
            )
        }

        Task {
            do {
                if isCurrentlySelected {
                    try await coordinator.removeTagFromSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                    Log.debug("[Tags] Removed tag '\(tag.name)' from \(segmentIds.count) segments in block", category: .ui)
                } else {
                    try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                    Log.debug("[Tags] Added tag '\(tag.name)' to \(segmentIds.count) segments in block", category: .ui)
                }
            } catch {
                Log.error("[Tags] Failed to toggle tag on segments: \(error)", category: .ui)
                await MainActor.run {
                    if isCurrentlySelected {
                        commentsStore.selectSelectedSegmentTag(tag.id, invalidate: notifyCommentStateWillChange)
                        commentsStore.addTagToSegments(
                            tagID: tag.id,
                            segmentIDs: segmentIds,
                            callbacks: makeCommentOptimisticSnapshotCallbacks()
                        )
                    } else {
                        commentsStore.deselectSelectedSegmentTag(tag.id, invalidate: notifyCommentStateWillChange)
                        commentsStore.removeTagFromSegments(
                            tagID: tag.id,
                            segmentIDs: segmentIds,
                            callbacks: makeCommentOptimisticSnapshotCallbacks()
                        )
                    }
                }
            }
        }
    }

    public func createAndAddTag(named tagName: String) {
        setNewTagDraftName(tagName)
        createAndAddTag()
    }

    public func createAndAddTag() {
        let tagName = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else { return }

        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        setNewTagDraftName("")

        Task {
            do {
                let newTag = try await coordinator.createTag(name: tagName)
                try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: newTag.id)

                await MainActor.run {
                    commentsStore.appendAvailableTagIfNeeded(newTag, callbacks: makeCommentTagIndicatorCallbacks())
                    commentsStore.selectSelectedSegmentTag(newTag.id, invalidate: notifyCommentStateWillChange)
                    commentsStore.addTagToSegments(
                        tagID: newTag.id,
                        segmentIDs: segmentIds,
                        callbacks: makeCommentOptimisticSnapshotCallbacks()
                    )
                }

                DashboardViewModel.recordTagCreateAndAddOnBlock(
                    coordinator: coordinator,
                    source: "timeline_tag_submenu",
                    tagID: newTag.id.value,
                    tagName: newTag.name,
                    segmentCount: segmentIds.count
                )
                Log.debug("[Tags] Created tag '\(tagName)' and added to \(segmentIds.count) segments in block", category: .ui)
            } catch {
                Log.error("[Tags] Failed to create tag: \(error)", category: .ui)
            }
        }
    }
}
