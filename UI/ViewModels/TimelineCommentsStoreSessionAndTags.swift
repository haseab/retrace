import Foundation
import Shared

extension TimelineCommentsStore {
    @MainActor
    func setTagSubmenuVisible(_ isVisible: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setShowTagSubmenu(isVisible) }
    }

    @MainActor
    func setCommentSubmenuVisible(_ isVisible: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setShowCommentSubmenu(isVisible) }
    }

    @MainActor
    func setCommentLinkPopoverPresented(_ isPresented: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setCommentLinkPopoverPresented(isPresented) }
    }

    @MainActor
    func setNewTagInputVisible(_ isVisible: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setShowNewTagInput(isVisible) }
    }

    @MainActor
    func setNewTagName(_ name: String, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setNewTagName(name) }
    }

    @MainActor
    func setAllCommentsBrowserActive(_ isActive: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setAllCommentsBrowserActive(isActive) }
    }

    @MainActor
    func setHoveringAddTagButton(_ isHovering: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setHoveringAddTagButton(isHovering) }
    }

    @MainActor
    func setHoveringAddCommentButton(_ isHovering: Bool, invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.setHoveringAddCommentButton(isHovering) }
    }

    @MainActor
    func requestCloseCommentLinkPopover(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.requestCloseCommentLinkPopover() }
    }

    @MainActor
    func requestReturnToThreadComments(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.requestReturnToThreadComments() }
    }

    @MainActor
    func closeTagSubmenuPreservingDraft(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.closeTagSubmenuPreservingDraft() }
    }

    @MainActor
    func dismissContextMenuSubmenus(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.dismissContextMenuSubmenus() }
    }

    @MainActor
    func prepareForTimelineContextMenuPresentation(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.prepareForTimelineContextMenuPresentation() }
    }

    @MainActor
    func prepareForCommentSubmenuPresentation(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.prepareForCommentSubmenuPresentation() }
    }

    @MainActor
    func prepareForTagSubmenuPresentation(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.prepareForTagSubmenuPresentation() }
    }

    @MainActor
    func presentTagSubmenuInsideComment(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.presentTagSubmenuInsideComment() }
    }

    @MainActor
    func showTagSubmenuFromContextMenu(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.showTagSubmenuFromContextMenu() }
    }

    @MainActor
    func toggleTagSubmenuFromContextMenu(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.toggleTagSubmenuFromContextMenu() }
    }

    @MainActor
    func presentCommentSubmenuFromContextMenu(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.presentCommentSubmenuFromContextMenu() }
    }

    @MainActor
    func dismissTagEditing(invalidate: () -> Void) {
        updateOverlayState(invalidate: invalidate) { $0.dismissTagEditing() }
    }

    @MainActor
    func resetLoadedTagIndicatorState(invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.resetLoadedState() }
    }

    @MainActor
    func setAvailableTags(_ tags: [Tag], invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.setAvailableTags(tags) }
    }

    @MainActor
    func appendAvailableTagIfNeeded(_ tag: Tag, invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.appendAvailableTagIfNeeded(tag) }
    }

    @MainActor
    func appendAvailableTagIfNeeded(_ tag: Tag, callbacks: TagIndicatorUpdateCallbacks) {
        guard !tagIndicatorState.availableTags.contains(where: { $0.id == tag.id }) else { return }
        updateTagIndicatorState(invalidate: callbacks.invalidate) { $0.appendAvailableTagIfNeeded(tag) }
        callbacks.didUpdateAvailableTags()
    }

    @MainActor
    func setSelectedSegmentTags(_ tagIDs: Set<TagID>, invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.setSelectedSegmentTags(tagIDs) }
    }

    @MainActor
    func clearSelectedSegmentTags(invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.clearSelectedSegmentTags() }
    }

    @MainActor
    func selectSelectedSegmentTag(_ tagID: TagID, invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.selectTag(tagID) }
    }

    @MainActor
    func deselectSelectedSegmentTag(_ tagID: TagID, invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.deselectTag(tagID) }
    }

    @MainActor
    func setSegmentTagsMap(_ map: [Int64: Set<Int64>], invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.setSegmentTagsMap(map) }
    }

    @MainActor
    func setSegmentCommentCountsMap(_ map: [Int64: Int], invalidate: () -> Void) {
        updateTagIndicatorState(invalidate: invalidate) { $0.setSegmentCommentCountsMap(map) }
    }

    @MainActor
    func addTagToSegments(
        tagID: TagID,
        segmentIDs: Set<SegmentID>,
        callbacks: OptimisticSnapshotCallbacks
    ) {
        updateTagIndicatorState(invalidate: callbacks.invalidate) {
            $0.addTagToSegments(tagID: tagID, segmentIDs: segmentIDs)
        }
        callbacks.refreshSnapshotImmediately(.addTagToSegmentTagsMap)
    }

    @MainActor
    func removeTagFromSegments(
        tagID: TagID,
        segmentIDs: Set<SegmentID>,
        callbacks: OptimisticSnapshotCallbacks
    ) {
        updateTagIndicatorState(invalidate: callbacks.invalidate) {
            $0.removeTagFromSegments(tagID: tagID, segmentIDs: segmentIDs)
        }
        callbacks.refreshSnapshotImmediately(.removeTagFromSegmentTagsMap)
    }

    @MainActor
    func incrementCommentCounts(
        for segmentIDs: Set<SegmentID>,
        callbacks: OptimisticSnapshotCallbacks
    ) {
        updateTagIndicatorState(invalidate: callbacks.invalidate) { $0.incrementCommentCounts(for: segmentIDs) }
        callbacks.refreshSnapshotImmediately(.incrementCommentCountsForSegments)
    }

    @MainActor
    func decrementCommentCounts(
        for segmentIDs: Set<SegmentID>,
        callbacks: OptimisticSnapshotCallbacks
    ) {
        updateTagIndicatorState(invalidate: callbacks.invalidate) { $0.decrementCommentCounts(for: segmentIDs) }
        callbacks.refreshSnapshotImmediately(.decrementCommentCountsForSegments)
    }

    @MainActor
    func loadSelectedBlockComments(
        segmentIDs: [SegmentID],
        forceRefresh: Bool,
        fetchLinkedComments: @escaping ([SegmentID]) async throws -> [TimelineLinkedSegmentComment],
        invalidate: @escaping () -> Void
    ) async {
        guard !segmentIDs.isEmpty else {
            updateThreadState(invalidate: invalidate) {
                $0.cancelCommentsLoad()
                $0.clearThreadComments()
            }
            return
        }

        let requestSegmentIDValues = segmentIDs.map(\.value)
        switch updateThreadState(invalidate: invalidate, mutation: {
            $0.beginCommentsLoad(
                requestSegmentIDValues: requestSegmentIDValues,
                forceRefresh: forceRefresh
            )
        }) {
        case let .awaitExisting(loadTask):
            await loadTask.value
            return

        case let .start(loadVersion):
            let loadStart = CFAbsoluteTimeGetCurrent()
            let loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    _ = self.updateThreadState(invalidate: invalidate) {
                        $0.finishCommentsLoad(version: loadVersion)
                    }
                }

                do {
                    let linkedComments = try await fetchLinkedComments(segmentIDs)
                    guard !Task.isCancelled else { return }

                    guard self.updateThreadState(invalidate: invalidate, mutation: {
                        $0.applyLoadedComments(linkedComments, version: loadVersion)
                    }) else { return }

                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                    Log.recordLatency(
                        "timeline.comments.thread_load_ms",
                        valueMs: elapsedMs,
                        category: .ui,
                        summaryEvery: 20,
                        warningThresholdMs: 120,
                        criticalThresholdMs: 300
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.updateThreadState(invalidate: invalidate, mutation: {
                        $0.applyLoadFailure(
                            version: loadVersion,
                            message: "Could not load comments."
                        )
                    }) else { return }
                    Log.error("[Comments] Failed to load block comments: \(error)", category: .ui)
                }
            }

            thread.setLoadTask(loadTask)
            await loadTask.value
        }
    }

    @MainActor
    func addCommentToSelectedBlock(
        body: String,
        segmentIDs: [SegmentID],
        attachmentDrafts: [CommentAttachmentDraft],
        selectedFrameID: FrameID?,
        createComment: @escaping (
            _ body: String,
            _ segmentIDs: [SegmentID],
            _ attachments: [SegmentCommentAttachment],
            _ frameID: FrameID?,
            _ author: String?
        ) async throws -> [SegmentID],
        fetchLinkedComments: @escaping ([SegmentID]) async throws -> [TimelineLinkedSegmentComment],
        didCreateComment: @escaping (_ linkedSegmentIDs: [SegmentID], _ persistedAttachments: [SegmentCommentAttachment]) -> Void,
        didFail: @escaping () -> Void,
        optimisticCallbacks: OptimisticSnapshotCallbacks? = nil,
        invalidate: @escaping () -> Void
    ) {
        updateThreadState(invalidate: invalidate) { $0.setIsAddingComment(true) }

        Task { @MainActor [weak self] in
            guard let self else { return }

            var persistedAttachments: [SegmentCommentAttachment] = []
            do {
                persistedAttachments = try await Task.detached(priority: .userInitiated) {
                    try Self.persistCommentAttachmentDrafts(attachmentDrafts)
                }.value

                let linkedSegmentIDs = try await createComment(
                    body,
                    segmentIDs,
                    persistedAttachments,
                    selectedFrameID,
                    nil
                )

                self.updateThreadState(invalidate: invalidate) {
                    $0.resetDraft()
                    $0.setIsAddingComment(false)
                }
                if let optimisticCallbacks, !linkedSegmentIDs.isEmpty {
                    self.incrementCommentCounts(for: Set(linkedSegmentIDs), callbacks: optimisticCallbacks)
                }
                didCreateComment(linkedSegmentIDs, persistedAttachments)
                await self.loadSelectedBlockComments(
                    segmentIDs: segmentIDs,
                    forceRefresh: true,
                    fetchLinkedComments: fetchLinkedComments,
                    invalidate: invalidate
                )
            } catch {
                Self.cleanupPersistedCommentAttachments(persistedAttachments)
                Log.error("[Comments] Failed to add comment: \(error)", category: .ui)
                self.updateThreadState(invalidate: invalidate) {
                    $0.setIsAddingComment(false)
                }
                didFail()
            }
        }
    }

    @MainActor
    func loadTags(
        context: TagLoadContext,
        fetchAllTags: @escaping () async throws -> [Tag],
        fetchTagsForSegment: @escaping (SegmentID) async throws -> [Tag],
        callbacks: TagIndicatorUpdateCallbacks
    ) async {
        do {
            let tags = try await fetchAllTags()
            setAvailableTags(tags, invalidate: callbacks.invalidate)
            callbacks.didUpdateAvailableTags()
            Log.debug("[Tags] Loaded \(tags.count) tags: \(tags.map(\.name))", category: .ui)

            Log.debug(
                "[Tags] timelineContextMenuSegmentIndex = \(String(describing: context.timelineContextMenuSegmentIndex))",
                category: .ui
            )

            if let segmentID = context.selectedSegmentID {
                Log.debug(
                    "[Tags] Loading tags for segment \(segmentID.value) at frame index \(String(describing: context.timelineContextMenuSegmentIndex))",
                    category: .ui
                )
                let segmentTags = try await fetchTagsForSegment(segmentID)
                setSelectedSegmentTags(Set(segmentTags.map(\.id)), invalidate: callbacks.invalidate)
                Log.debug(
                    "[Tags] Segment \(segmentID.value) has \(segmentTags.count) tags: \(segmentTags.map(\.name))",
                    category: .ui
                )
            } else {
                Log.debug(
                    "[Tags] Could not get segment ID - index: \(String(describing: context.timelineContextMenuSegmentIndex))",
                    category: .ui
                )
            }
        } catch {
            Log.error("[Tags] Failed to load tags: \(error)", category: .ui)
        }
    }

    @MainActor
    func ensureTagIndicatorDataLoadedIfNeeded(
        hasFrames: Bool,
        fetchAllTags: @escaping () async throws -> [Tag],
        fetchSegmentTagsMap: @escaping () async throws -> [Int64: Set<Int64>],
        fetchSegmentCommentCountsMap: @escaping () async throws -> [Int64: Int],
        callbacks: TagIndicatorUpdateCallbacks
    ) {
        guard hasFrames else { return }

        let needsTags = !tagIndicatorState.hasLoadedAvailableTags
        let needsSegmentTagsMap = !tagIndicatorState.hasLoadedSegmentTagsMap
        let needsSegmentCommentCountsMap = !tagIndicatorState.hasLoadedSegmentCommentCountsMap
        guard needsTags || needsSegmentTagsMap || needsSegmentCommentCountsMap else { return }
        guard lazyTagIndicatorLoadTask == nil else { return }

        lazyTagIndicatorLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.lazyTagIndicatorLoadTask = nil }

            do {
                var didLoadCommentCounts = false
                if needsTags && needsSegmentTagsMap && needsSegmentCommentCountsMap {
                    async let tagsTask = fetchAllTags()
                    async let segmentTagsTask = fetchSegmentTagsMap()
                    async let commentCountsTask = fetchSegmentCommentCountsMap()
                    let (tags, segmentTags, segmentCommentCounts) = try await (tagsTask, segmentTagsTask, commentCountsTask)
                    self.setAvailableTags(tags, invalidate: callbacks.invalidate)
                    callbacks.didUpdateAvailableTags()
                    self.setSegmentTagsMap(segmentTags, invalidate: callbacks.invalidate)
                    callbacks.didUpdateSegmentTagsMap()
                    self.setSegmentCommentCountsMap(segmentCommentCounts, invalidate: callbacks.invalidate)
                    callbacks.didUpdateSegmentCommentCountsMap()
                    didLoadCommentCounts = true
                } else if needsTags && needsSegmentTagsMap {
                    async let tagsTask = fetchAllTags()
                    async let segmentTagsTask = fetchSegmentTagsMap()
                    let (tags, segmentTags) = try await (tagsTask, segmentTagsTask)
                    self.setAvailableTags(tags, invalidate: callbacks.invalidate)
                    callbacks.didUpdateAvailableTags()
                    self.setSegmentTagsMap(segmentTags, invalidate: callbacks.invalidate)
                    callbacks.didUpdateSegmentTagsMap()
                } else if needsTags {
                    self.setAvailableTags(try await fetchAllTags(), invalidate: callbacks.invalidate)
                    callbacks.didUpdateAvailableTags()
                } else if needsSegmentTagsMap {
                    self.setSegmentTagsMap(try await fetchSegmentTagsMap(), invalidate: callbacks.invalidate)
                    callbacks.didUpdateSegmentTagsMap()
                }

                if needsSegmentCommentCountsMap && !didLoadCommentCounts {
                    self.setSegmentCommentCountsMap(try await fetchSegmentCommentCountsMap(), invalidate: callbacks.invalidate)
                    callbacks.didUpdateSegmentCommentCountsMap()
                }
            } catch {
                Log.error("[Tags] Failed to load tape tag indicator data: \(error)", category: .ui)
            }
        }
    }

    @MainActor
    func refreshTagIndicatorDataFromDatabase(
        hasFrames: Bool,
        reason: String,
        fetch: @escaping () async throws -> (
            tags: [Tag],
            segmentTagsMap: [Int64: Set<Int64>],
            segmentCommentCountsMap: [Int64: Int]
        ),
        callbacks: TagIndicatorUpdateCallbacks
    ) {
        guard hasFrames else { return }

        tagIndicatorRefreshTask?.cancel()
        tagIndicatorRefreshVersion &+= 1
        let refreshVersion = tagIndicatorRefreshVersion

        Log.debug("[TimelineIndicatorSync] Refresh requested reason=\(reason)", category: .ui)
        tagIndicatorRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.tagIndicatorRefreshVersion == refreshVersion {
                    self.tagIndicatorRefreshTask = nil
                }
            }

            do {
                let (tags, segmentTags, segmentCommentCounts) = try await fetch()
                guard !Task.isCancelled, self.tagIndicatorRefreshVersion == refreshVersion else { return }

                self.setAvailableTags(tags, invalidate: callbacks.invalidate)
                callbacks.didUpdateAvailableTags()
                self.setSegmentTagsMap(segmentTags, invalidate: callbacks.invalidate)
                callbacks.didUpdateSegmentTagsMap()
                self.setSegmentCommentCountsMap(segmentCommentCounts, invalidate: callbacks.invalidate)
                callbacks.didUpdateSegmentCommentCountsMap()
                Log.debug(
                    "[TimelineIndicatorSync] Refreshed indicator data reason=\(reason) tags=\(tags.count) taggedSegments=\(segmentTags.count) commentSegments=\(segmentCommentCounts.count)",
                    category: .ui
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.tagIndicatorRefreshVersion == refreshVersion else { return }
                Log.error("[TimelineIndicatorSync] Failed refreshing indicator data reason=\(reason): \(error)", category: .ui)
            }
        }
    }

    func cancelPendingWork() {
        cancelCommentSearch()
        thread.cancelCommentsLoad()
        lazyTagIndicatorLoadTask?.cancel()
        lazyTagIndicatorLoadTask = nil
        cancelPendingTagIndicatorRefresh()
    }

    static func persistCommentAttachmentDrafts(
        _ drafts: [CommentAttachmentDraft]
    ) throws -> [SegmentCommentAttachment] {
        guard !drafts.isEmpty else { return [] }

        let fileManager = FileManager.default
        let baseDirectoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)
        let attachmentsDirectoryName = "comment_attachments"
        let attachmentsDirectoryURL = baseDirectoryURL.appendingPathComponent(
            attachmentsDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: attachmentsDirectoryURL, withIntermediateDirectories: true)

        var persisted: [SegmentCommentAttachment] = []

        do {
            for draft in drafts {
                let safeName = sanitizedAttachmentFileName(draft.fileName)
                let persistedName = "\(UUID().uuidString)_\(safeName)"
                let destinationURL = attachmentsDirectoryURL.appendingPathComponent(
                    persistedName,
                    isDirectory: false
                )

                try fileManager.copyItem(at: draft.sourceURL, to: destinationURL)

                let sizeBytes = (
                    try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber
                )?.int64Value ?? draft.sizeBytes
                let relativePath = "\(attachmentsDirectoryName)/\(persistedName)"

                persisted.append(
                    SegmentCommentAttachment(
                        filePath: relativePath,
                        fileName: draft.fileName,
                        mimeType: draft.mimeType,
                        sizeBytes: sizeBytes
                    )
                )
            }
        } catch {
            for attachment in persisted {
                let removeURL = baseDirectoryURL.appendingPathComponent(
                    attachment.filePath,
                    isDirectory: false
                )
                try? fileManager.removeItem(at: removeURL)
            }
            throw error
        }

        return persisted
    }

    static func cleanupPersistedCommentAttachments(_ attachments: [SegmentCommentAttachment]) {
        guard !attachments.isEmpty else { return }

        let fileManager = FileManager.default
        let baseDirectoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)

        for attachment in attachments {
            let path: String
            if attachment.filePath.hasPrefix("/") || attachment.filePath.hasPrefix("~") {
                path = NSString(string: attachment.filePath).expandingTildeInPath
            } else {
                path = baseDirectoryURL.appendingPathComponent(
                    attachment.filePath,
                    isDirectory: false
                ).path
            }

            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    static func sanitizedAttachmentFileName(_ fileName: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\")
        let sanitizedScalars = fileName.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? "_" : Character(scalar)
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
    }

    func cancelPendingTagIndicatorRefresh() {
        tagIndicatorRefreshTask?.cancel()
        tagIndicatorRefreshTask = nil
        tagIndicatorRefreshVersion &+= 1
    }
}
