import AppKit
import UniformTypeIdentifiers
import Shared
import App

extension SimpleTimelineViewModel {
    // MARK: - Comment Workflows

    public func insertCommentBoldMarkup() {
        commentsStore.appendDraftSnippet("**bold text**", invalidate: notifyCommentStateWillChange)
    }

    public func insertCommentItalicMarkup() {
        commentsStore.appendDraftSnippet("*italic text*", invalidate: notifyCommentStateWillChange)
    }

    public func insertCommentLinkMarkup() {
        commentsStore.appendDraftSnippet("[link text](https://example.com)", invalidate: notifyCommentStateWillChange)
    }

    public func insertCommentTimestampMarkup() {
        guard currentIndex >= 0, currentIndex < frames.count else { return }
        let timestamp = frames[currentIndex].frame.timestamp
        let formatted = Self.commentTimestampFormatter.string(from: timestamp)
        commentsStore.appendDraftSnippet("[\(formatted)] ", invalidate: notifyCommentStateWillChange)
    }

    public func selectCommentAttachmentFiles() {
        DashboardViewModel.recordCommentAttachmentPickerOpened(
            coordinator: coordinator,
            source: currentCommentMetricsSource
        )

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select files to attach to this comment"
        panel.prompt = "Attach"

        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            hostWindow.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: hostWindow) { [weak self] response in
                guard response == .OK else { return }
                Task { @MainActor [weak self] in
                    self?.addCommentAttachmentDrafts(from: panel.urls)
                }
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        addCommentAttachmentDrafts(from: panel.urls)
    }

    public func removeCommentAttachmentDraft(_ draft: CommentAttachmentDraft) {
        commentsStore.removeDraftAttachment(draft, invalidate: notifyCommentStateWillChange)
    }

    public func openCommentAttachment(_ attachment: SegmentCommentAttachment) {
        let resolvedPath: String
        if attachment.filePath.hasPrefix("/") || attachment.filePath.hasPrefix("~") {
            resolvedPath = NSString(string: attachment.filePath).expandingTildeInPath
        } else {
            resolvedPath = (AppPaths.expandedStorageRoot as NSString).appendingPathComponent(attachment.filePath)
        }

        let url = URL(fileURLWithPath: resolvedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("Attachment file is missing", icon: "exclamationmark.triangle.fill")
            return
        }

        NSWorkspace.shared.open(url)
        DashboardViewModel.recordCommentAttachmentOpened(
            coordinator: coordinator,
            source: currentCommentMetricsSource,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    @discardableResult
    public func removeCommentFromSelectedTimelineBlock(comment: SegmentComment) async -> Bool {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            showToast("Could not resolve selected segment block", icon: "exclamationmark.triangle.fill")
            return false
        }

        let segmentIDs = getSegmentIds(inBlock: block)
        guard !segmentIDs.isEmpty else {
            showToast("No segments selected", icon: "exclamationmark.circle.fill")
            return false
        }

        do {
            let linkedSegmentIDs = try await commentsStore.removeCommentFromSelectedBlock(
                comment: comment,
                segmentIDs: Array(segmentIDs),
                fetchCommentsForSegment: { [coordinator] segmentID in
                    try await coordinator.getCommentsForSegment(segmentId: segmentID)
                },
                removeCommentFromSegments: { [coordinator] segmentIDs, commentID in
                    try await coordinator.removeCommentFromSegments(
                        segmentIds: segmentIDs,
                        commentId: commentID
                    )
                },
                rowBuilder: { [self] comment, context in
                    commentTimelineRow(comment: comment, context: context)
                },
                optimisticCallbacks: makeCommentOptimisticSnapshotCallbacks(),
                invalidate: notifyCommentStateWillChange
            )

            if linkedSegmentIDs.isEmpty {
                return true
            }

            DashboardViewModel.recordCommentDeletedFromBlock(
                coordinator: coordinator,
                source: currentCommentMetricsSource,
                linkedSegmentCount: linkedSegmentIDs.count,
                hadFrameAnchor: comment.frameID != nil
            )
            showToast("Comment deleted", icon: "trash.fill")
            return true
        } catch {
            Log.error("[Comments] Failed to delete comment from block: \(error)", category: .ui)
            showToast("Failed to delete comment", icon: "xmark.circle.fill")
            return false
        }
    }

    public func addCommentToSelectedSegment() {
        let commentBody = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentBody.isEmpty else {
            showToast("Comment cannot be empty", icon: "exclamationmark.circle.fill")
            return
        }
        guard !isAddingComment else { return }

        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot comment on Rewind data")
            dismissTimelineContextMenu()
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        guard !segmentIds.isEmpty else {
            showToast("No segments selected", icon: "exclamationmark.circle.fill")
            return
        }
        let selectedFrameID = (index >= 0 && index < frames.count) ? frames[index].frame.id : nil

        commentsStore.addCommentToSelectedBlock(
            body: commentBody,
            segmentIDs: Array(segmentIds),
            attachmentDrafts: newCommentAttachmentDrafts,
            selectedFrameID: selectedFrameID,
            createComment: { [weak self] body, segmentIDs, attachments, frameID, author in
                guard let self else { return [] }
#if DEBUG
                if let override = self.test_blockCommentsHooks.createCommentForSegments {
                    return try await override(body, segmentIDs, attachments, frameID, author).linkedSegmentIDs
                }
#endif
                let createResult = try await self.coordinator.createCommentForSegments(
                    body: body,
                    segmentIds: segmentIDs,
                    attachments: attachments,
                    frameID: frameID,
                    author: author
                )
                return createResult.linkedSegmentIDs
            },
            fetchLinkedComments: fetchLinkedCommentsForSelectedTimelineBlock,
            didCreateComment: { [weak self] linkedSegmentIDs, persistedAttachments in
                guard let self else { return }
                DashboardViewModel.recordCommentAdded(
                    coordinator: self.coordinator,
                    source: self.currentCommentMetricsSource,
                    requestedSegmentCount: segmentIds.count,
                    linkedSegmentCount: linkedSegmentIDs.count,
                    bodyLength: commentBody.count,
                    attachmentCount: persistedAttachments.count,
                    hasFrameAnchor: selectedFrameID != nil
                )
            },
            didFail: { [weak self] in
                self?.showToast("Failed to add comment", icon: "xmark.circle.fill")
            },
            optimisticCallbacks: makeCommentOptimisticSnapshotCallbacks(),
            invalidate: { [weak self] in self?.notifyCommentStateWillChange() }
        )
    }

    public func loadCommentPreviewImage(for frameID: FrameID) async -> NSImage? {
        if currentImageFrameID == frameID, let currentImage {
            return currentImage
        }

        if let currentFrame, currentFrame.id == frameID {
            if isInLiveMode, let liveScreenshot {
                return liveScreenshot
            }

            if let waitingFallbackImage {
                return waitingFallbackImage
            }
        }

        if let diskBufferedPreview = await Self.loadTimelineDiskFrameBufferPreviewImage(
            for: frameID,
            logPrefix: "[Comments]"
        ) {
            return diskBufferedPreview
        }

        guard let timelineFrame = frames.first(where: { $0.frame.id == frameID }) else {
            return nil
        }

        do {
            return try await fetchForegroundPresentationLoadResult(timelineFrame).image
        } catch {
            Log.error("[Comments] Failed to load target preview for frame \(frameID.value): \(error)", category: .ui)
            return nil
        }
    }

    @discardableResult
    public func navigateToCommentFrame(frameID: FrameID) async -> Bool {
        setLoadingState(true, reason: "navigateToCommentFrame")
        clearError()

        let didNavigate = await searchForFrameID(frameID.value, includeHiddenSegments: true)
        if didNavigate {
            showToast("Opened linked frame", icon: "checkmark.circle.fill")
            return true
        }

        setLoadingState(false, reason: "navigateToCommentFrame.notFound")
        showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
        return false
    }

    @discardableResult
    public func navigateToComment(
        comment: SegmentComment,
        preferredSegmentID: SegmentID? = nil
    ) async -> Bool {
        if let frameID = comment.frameID {
            let didNavigate = await navigateToCommentFrame(frameID: frameID)
            if didNavigate {
                return true
            }
        }

        do {
            let fallbackSegmentID: SegmentID?
            if let preferredSegmentID {
                fallbackSegmentID = preferredSegmentID
            } else {
                fallbackSegmentID = try await coordinator.getFirstLinkedSegmentForComment(commentId: comment.id)
            }
            guard let fallbackSegmentID,
                  let fallbackFrameID = try await coordinator.getFirstFrameForSegment(segmentId: fallbackSegmentID) else {
                showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
                return false
            }

            let didNavigate = await navigateToCommentFrame(frameID: fallbackFrameID)
            if !didNavigate {
                showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
            }
            return didNavigate
        } catch {
            Log.error("[Comments] Failed to resolve fallback frame for comment \(comment.id.value): \(error)", category: .ui)
            showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
            return false
        }
    }

    public func updateCommentSearchQuery(_ rawQuery: String) {
        commentsStore.updateCommentSearchQuery(
            rawQuery,
            debounceNanoseconds: Self.commentSearchDebounceNanoseconds,
            pageSize: Self.commentSearchPageSize,
            searchEntries: searchCommentTimelineEntries,
            mapEntryToRow: mapCommentTimelineEntryToRow,
            invalidate: notifyCommentStateWillChange
        )
    }

    public func retryCommentSearch() {
        commentsStore.retryCommentSearch(
            pageSize: Self.commentSearchPageSize,
            searchEntries: searchCommentTimelineEntries,
            mapEntryToRow: mapCommentTimelineEntryToRow,
            invalidate: notifyCommentStateWillChange
        )
    }

    public func loadMoreCommentSearchResultsIfNeeded(currentCommentID: SegmentCommentID?) {
        commentsStore.loadMoreCommentSearchResultsIfNeeded(
            currentCommentID: currentCommentID,
            pageSize: Self.commentSearchPageSize,
            searchEntries: searchCommentTimelineEntries,
            mapEntryToRow: mapCommentTimelineEntryToRow,
            invalidate: notifyCommentStateWillChange
        )
    }

    public func resetCommentSearchState() {
        commentsStore.resetCommentSearchState(invalidate: notifyCommentStateWillChange)
    }

    public func loadCommentTimeline(anchoredAt anchorComment: SegmentComment?) async {
        DashboardViewModel.recordAllCommentsOpened(
            coordinator: coordinator,
            source: "timeline_comment_submenu",
            anchorCommentID: anchorComment?.id.value
        )

        await commentsStore.loadCommentTimeline(
            anchorComment: anchorComment,
            fetchAllTags: { [weak self] in
                guard let self else { return [] }
                return try await self.coordinator.getAllTags()
            },
            fetchSegmentTagsMap: { [weak self] in
                guard let self else { return [:] }
                return try await self.coordinator.getSegmentTagsMap()
            },
            fetchEntries: { [coordinator] in
                try await coordinator.getAllCommentTimelineEntries()
            },
            metadataNormalizer: normalizeCommentTimelineMetadata,
            rowBuilder: { [self] comment, context in
                commentTimelineRow(comment: comment, context: context)
            },
            callbacks: makeCommentTagIndicatorCallbacks()
        )
    }

    public func loadOlderCommentTimelinePage() async {
        await loadCommentTimelinePage(direction: .older)
    }

    public func loadNewerCommentTimelinePage() async {
        await loadCommentTimelinePage(direction: .newer)
    }

    func loadCommentTimelinePage(direction: TimelineCommentTimelineDirection) async {
        await commentsStore.loadCommentTimelinePage(
            direction: direction,
            baseFilters: filterCriteria,
            maxBatches: 4,
            fetchFramesBefore: { [coordinator] timestamp, limit, filters in
                try await coordinator.getFramesBefore(timestamp: timestamp, limit: limit, filters: filters)
            },
            fetchFramesAfter: { [coordinator] timestamp, limit, filters in
                try await coordinator.getFramesAfter(timestamp: timestamp, limit: limit, filters: filters)
            },
            metadataNormalizer: normalizeCommentTimelineMetadata,
            loadCommentsForSegment: { [coordinator] segmentID in
                try await coordinator.getCommentsForSegment(segmentId: segmentID)
            },
            rowBuilder: { [self] comment, context in
                commentTimelineRow(comment: comment, context: context)
            },
            invalidate: notifyCommentStateWillChange
        )
    }

    public func resetCommentTimelineState() {
        commentsStore.resetCommentTimelineBrowsing(invalidate: notifyCommentStateWillChange)
    }

    func commentTimelineRow(
        comment: SegmentComment,
        context: CommentTimelineSegmentContext?,
        hiddenTagID: Int64? = nil,
        tagsByID: [Int64: Tag]? = nil
    ) -> CommentTimelineRow {
        let effectiveHiddenTagID = hiddenTagID ?? hiddenTagIDValue
        let effectiveTagsByID = tagsByID ?? availableTagsByID
        let primaryTagName: String? = context.flatMap { context in
            let segmentTagIDs = segmentTagsMap[context.segmentID.value] ?? []
            let visibleTagNames = segmentTagIDs
                .filter { tagID in
                    guard let effectiveHiddenTagID else { return true }
                    return tagID != effectiveHiddenTagID
                }
                .compactMap { effectiveTagsByID[$0]?.name }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return visibleTagNames.first
        }

        return CommentTimelineRow(
            comment: comment,
            context: context,
            primaryTagName: primaryTagName
        )
    }

    func normalizedMetadataString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func searchCommentTimelineEntries(
        query: String,
        offset: Int,
        limit: Int
    ) async throws -> [TimelineCommentTimelineEntry] {
        try await coordinator.searchCommentTimelineEntries(
            query: query,
            limit: limit,
            offset: offset
        )
    }

    func mapCommentTimelineEntryToRow(_ entry: TimelineCommentTimelineEntry) -> CommentTimelineRow {
        commentTimelineRow(
            comment: entry.comment,
            context: CommentTimelineSegmentContext(
                segmentID: entry.segmentID,
                appBundleID: normalizedMetadataString(entry.appBundleID),
                appName: normalizedMetadataString(entry.appName),
                browserURL: normalizedMetadataString(entry.browserURL),
                referenceTimestamp: entry.referenceTimestamp
            )
        )
    }

    func addCommentAttachmentDrafts(from urls: [URL]) {
        guard !urls.isEmpty else { return }

        var updatedDrafts = newCommentAttachmentDrafts
        var existingPaths = Set(
            updatedDrafts.map { $0.sourceURL.resolvingSymlinksInPath().path }
        )
        var appended = 0
        let fileManager = FileManager.default

        for rawURL in urls {
            let resolvedURL = rawURL.resolvingSymlinksInPath()
            guard !existingPaths.contains(resolvedURL.path) else { continue }

            let fileName = resolvedURL.lastPathComponent
            guard !fileName.isEmpty else { continue }

            let mimeType = UTType(filenameExtension: resolvedURL.pathExtension)?.preferredMIMEType
            let sizeBytes = (try? fileManager.attributesOfItem(atPath: resolvedURL.path)[.size] as? NSNumber)?.int64Value

            updatedDrafts.append(
                CommentAttachmentDraft(
                    sourceURL: resolvedURL,
                    fileName: fileName,
                    mimeType: mimeType,
                    sizeBytes: sizeBytes
                )
            )
            existingPaths.insert(resolvedURL.path)
            appended += 1
        }

        if appended > 0 {
            commentsStore.setDraftAttachments(updatedDrafts, invalidate: notifyCommentStateWillChange)
            showToast("Attached \(appended) file\(appended == 1 ? "" : "s")", icon: "paperclip")
        }
    }
}
