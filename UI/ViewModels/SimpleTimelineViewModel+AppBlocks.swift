import Shared

enum AppBlockSnapshotUpdateKind {
    case syncTagCatalog
    case invalidate
    case refreshImmediately
}

enum OptimisticFrameMutationReason {
    case confirmDeleteSelectedFrame
    case restoreDeletedOperation(String)
    case confirmDeleteSegment
    case hideSegmentRemoveFrames
    case unhideSegmentRemoveFrames

    var logLabel: String {
        switch self {
        case .confirmDeleteSelectedFrame:
            "confirmDeleteSelectedFrame"
        case .restoreDeletedOperation(let reason):
            "restoreDeletedOperation.\(reason)"
        case .confirmDeleteSegment:
            "confirmDeleteSegment"
        case .hideSegmentRemoveFrames:
            "performHideSegment.removeFrames"
        case .unhideSegmentRemoveFrames:
            "performUnhideSegment.removeFrames"
        }
    }
}

enum AppBlockSnapshotUpdateReason {
    case availableTagsUpdated
    case segmentTagsMapUpdated
    case segmentCommentCountsMapUpdated
    case framesDidSet
    case framesDidSetWindowReplaced
    case framesDidSetPrepended
    case framesDidSetAppended
    case invalidateCachesAndReload
    case optimisticCommentMutation(TimelineCommentsStore.OptimisticSnapshotReason)
    case optimisticFrameMutation(OptimisticFrameMutationReason)

    var logLabel: String {
        switch self {
        case .availableTagsUpdated:
            "availableTags.updated"
        case .segmentTagsMapUpdated:
            "segmentTagsMap.updated"
        case .segmentCommentCountsMapUpdated:
            "segmentCommentCountsMap.updated"
        case .framesDidSet:
            "frames.didSet"
        case .framesDidSetWindowReplaced:
            "frames.didSet.windowReplaced"
        case .framesDidSetPrepended:
            "frames.didSet.prepended"
        case .framesDidSetAppended:
            "frames.didSet.appended"
        case .invalidateCachesAndReload:
            "invalidateCachesAndReload"
        case .optimisticCommentMutation(let reason):
            reason.logLabel
        case .optimisticFrameMutation(let reason):
            reason.logLabel
        }
    }
}

extension SimpleTimelineViewModel {
    /// Read-only lookup map used by TimelineTapeView hot paths.
    public var availableTagsByID: [Int64: Tag] {
        blockSnapshotController.availableTagsByID
    }

    public var tagCatalogRevision: UInt64 {
        blockSnapshotController.tagCatalogRevision
    }

    public var appBlockSnapshotRevision: Int {
        blockSnapshotController.appBlockSnapshotRevision
    }

    var latestCachedAppBlockSnapshot: TimelineAppBlockSnapshot? {
        blockSnapshotController.latestCachedSnapshot
    }

    var appBlockSnapshot: TimelineAppBlockSnapshot {
        blockSnapshotController.snapshot(
            frameInputs: makeSnapshotFrameInputs(from: frames),
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap
        )
    }

    public var appBlocks: [AppBlock] {
        appBlockSnapshot.blocks
    }

    func makeSnapshotFrameInputs(from frameList: [TimelineFrame]) -> [SnapshotFrameInput] {
        frameList.map { timelineFrame in
            SnapshotFrameInput(
                bundleID: timelineFrame.frame.metadata.appBundleID,
                appName: timelineFrame.frame.metadata.appName,
                segmentIDValue: timelineFrame.frame.segmentID.value,
                timestamp: timelineFrame.frame.timestamp,
                videoPath: timelineFrame.videoInfo?.videoPath
            )
        }
    }

    func applyAppBlockSnapshotUpdate(
        _ updateKind: AppBlockSnapshotUpdateKind,
        reason: AppBlockSnapshotUpdateReason
    ) {
        let frameInputs = makeSnapshotFrameInputs(from: frames)
        let reasonLabel = reason.logLabel

        switch updateKind {
        case .syncTagCatalog:
            blockSnapshotController.refreshTagCachesAndInvalidateSnapshotIfNeeded(
                availableTags: availableTags,
                reason: reasonLabel,
                frameInputs: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                isVerboseLoggingEnabled: Self.isVerboseTimelineLoggingEnabled
            )

        case .invalidate:
            blockSnapshotController.invalidateSnapshot(
                reason: reasonLabel,
                frameInputs: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                isVerboseLoggingEnabled: Self.isVerboseTimelineLoggingEnabled
            )

        case .refreshImmediately:
            blockSnapshotController.refreshSnapshotImmediately(
                reason: reasonLabel,
                frameInputs: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                isVerboseLoggingEnabled: Self.isVerboseTimelineLoggingEnabled
            )
        }
    }

    func makeCommentTagIndicatorCallbacks() -> TimelineCommentsStore.TagIndicatorUpdateCallbacks {
        TimelineCommentsStore.TagIndicatorUpdateCallbacks(
            invalidate: { [weak self] in self?.notifyCommentStateWillChange() },
            didUpdateAvailableTags: { [weak self] in
                self?.applyAppBlockSnapshotUpdate(.syncTagCatalog, reason: .availableTagsUpdated)
            },
            didUpdateSegmentTagsMap: { [weak self] in
                self?.applyAppBlockSnapshotUpdate(.invalidate, reason: .segmentTagsMapUpdated)
            },
            didUpdateSegmentCommentCountsMap: { [weak self] in
                self?.applyAppBlockSnapshotUpdate(.invalidate, reason: .segmentCommentCountsMapUpdated)
            }
        )
    }

    func currentTagLoadContext() -> TimelineCommentsStore.TagLoadContext {
        let selectedSegmentID = timelineContextMenuSegmentIndex.flatMap { getSegmentId(forFrameAt: $0) }
        return TimelineCommentsStore.TagLoadContext(
            timelineContextMenuSegmentIndex: timelineContextMenuSegmentIndex,
            selectedSegmentID: selectedSegmentID
        )
    }

    func makeCommentOptimisticSnapshotCallbacks() -> TimelineCommentsStore.OptimisticSnapshotCallbacks {
        TimelineCommentsStore.OptimisticSnapshotCallbacks(
            invalidate: { [weak self] in self?.notifyCommentStateWillChange() },
            refreshSnapshotImmediately: { [weak self] reason in
                self?.applyAppBlockSnapshotUpdate(.refreshImmediately, reason: .optimisticCommentMutation(reason))
            }
        )
    }

    func normalizeCommentTimelineMetadata(_ rawValue: String?) -> String? {
        normalizedMetadataString(rawValue)
    }

    func mutateFramesOptimistically(
        reason: OptimisticFrameMutationReason,
        mutation: () -> Void
    ) {
        mutation()
        applyAppBlockSnapshotUpdate(.refreshImmediately, reason: .optimisticFrameMutation(reason))
    }
}
