import SwiftUI
import AppKit
import App
import Shared

@MainActor
final class QuickCommentComposerViewModel: ObservableObject {
    typealias RecentFramesLoader = @Sendable () async throws -> [FrameWithVideoInfo]
    typealias PreviewImageLoader = @Sendable (FrameWithVideoInfo) async -> NSImage?

    @Published private(set) var target: CommentComposerTargetDisplayInfo?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var availableTags: [Tag] = []
    @Published private(set) var sessionAddedTagIDs: Set<TagID> = []
    @Published var newCommentText: String = ""
    @Published var isLoadingTarget = false
    @Published var isLoadingTags = false
    @Published var isSubmittingComment = false
    @Published var isCreatingTag = false
    @Published var messageText: String?
    @Published var messageIsError = false

    let metricsSource: String

    private let coordinator: AppCoordinator
    private let recentFramesLoader: RecentFramesLoader
    private let previewImageLoader: PreviewImageLoader
    private var isTargetPinnedForEditing = false

    init(
        coordinator: AppCoordinator,
        source: String,
        recentFramesLoader: RecentFramesLoader? = nil,
        previewImageLoader: PreviewImageLoader? = nil
    ) {
        self.coordinator = coordinator
        self.metricsSource = source
        self.recentFramesLoader = recentFramesLoader ?? {
            try await coordinator.getMostRecentFramesWithVideoInfo(limit: 40)
        }
        self.previewImageLoader = previewImageLoader ?? { frame in
            await Self.loadPreviewImage(for: frame, coordinator: coordinator)
        }
    }

    var canSubmitComment: Bool {
        !trimmedComment.isEmpty && !isSubmittingComment && !isReadOnlyTarget
    }

    var isReadOnlyTarget: Bool {
        target?.source == .rewind
    }

    var trimmedComment: String {
        newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sessionAddedTags: [Tag] {
        availableTags
            .filter { sessionAddedTagIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var shouldFreezeLiveRefresh: Bool {
        isTargetPinnedForEditing || isSubmittingComment || isCreatingTag
    }

    func recordContextPreviewToggle(isCollapsed: Bool) {
        DashboardViewModel.recordQuickCommentContextPreviewToggle(
            coordinator: coordinator,
            source: metricsSource,
            isCollapsed: isCollapsed
        )
    }

    func recordTagSubmenuOpen(source: String) {
        DashboardViewModel.recordTagSubmenuOpen(
            coordinator: coordinator,
            source: source,
            segmentCount: target == nil ? nil : 1,
            frameCount: target == nil ? nil : 1,
            selectedTagCount: sessionAddedTagIDs.count
        )
    }

    func pinTargetForEditing() {
        guard !isTargetPinnedForEditing else { return }
        isTargetPinnedForEditing = true
        Log.debug("[QuickComment] Pinned live target for active editor session", category: .ui)
    }

    func prepareInitialTarget() async -> Bool {
        let didRefresh = await refreshTarget(initialLoad: true)
        guard didRefresh else { return false }
        return target != nil
    }

    @discardableResult
    func refreshTarget(initialLoad: Bool = false) async -> Bool {
        if initialLoad {
            isLoadingTarget = true
        }
        defer {
            if initialLoad {
                isLoadingTarget = false
            }
        }

        do {
            let recentFrames = try await recentFramesLoader()
            guard let selectedFrame = Self.preferredTargetFrame(from: recentFrames) else {
                messageText = "No recent captured frame was available."
                messageIsError = true
                target = nil
                previewImage = nil
                sessionAddedTagIDs = []
                return false
            }

            let previousSegmentID = target?.segmentID
            let resolvedTarget = Self.makeTarget(from: selectedFrame)
            target = resolvedTarget
            messageText = nil
            messageIsError = false
            if previousSegmentID != nil && previousSegmentID != resolvedTarget.segmentID {
                sessionAddedTagIDs = []
            }
            previewImage = await previewImageLoader(selectedFrame)

            return true
        } catch {
            Log.error("[QuickComment] Failed to refresh target: \(error)", category: .ui)
            messageText = "Could not refresh the latest captured frame."
            messageIsError = true
            return false
        }
    }

    func loadAvailableTagsForPicker() async {
        isLoadingTags = true
        defer { isLoadingTags = false }

        await loadAvailableTagsIfNeeded()
    }

    func addTag(_ tag: Tag) async {
        guard let segmentID = target?.segmentID else { return }
        guard !isReadOnlyTarget else {
            messageText = "Cannot tag Rewind data."
            messageIsError = true
            return
        }
        guard !sessionAddedTagIDs.contains(tag.id) else { return }

        pinTargetForEditing()

        DashboardViewModel.recordTagToggleOnBlock(
            coordinator: coordinator,
            source: metricsSource,
            tagID: tag.id.value,
            tagName: tag.name,
            action: "add",
            segmentCount: 1
        )

        do {
            try await coordinator.addTagToSegment(segmentId: segmentID, tagId: tag.id)
            sessionAddedTagIDs.insert(tag.id)
            messageText = nil
            messageIsError = false
            TimelineWindowController.shared.refreshTapeIndicatorsAfterExternalMutation(
                reason: "quick_comment_tag_added"
            )
        } catch {
            Log.error("[QuickComment] Failed to add tag \(tag.id.value) on segment \(segmentID.value): \(error)", category: .ui)
            messageText = "Could not add the tag."
            messageIsError = true
        }
    }

    func createAndAddTag(named rawTagName: String) async {
        let tagName = rawTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else { return }
        guard let segmentID = target?.segmentID else { return }
        guard !isReadOnlyTarget else {
            messageText = "Cannot tag Rewind data."
            messageIsError = true
            return
        }
        guard !isCreatingTag else { return }

        pinTargetForEditing()
        isCreatingTag = true
        defer { isCreatingTag = false }

        do {
            let createdTag = try await coordinator.createTag(name: tagName)
            try await coordinator.addTagToSegment(segmentId: segmentID, tagId: createdTag.id)

            if !availableTags.contains(where: { $0.id == createdTag.id }) {
                availableTags.append(createdTag)
                availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            sessionAddedTagIDs.insert(createdTag.id)
            messageText = nil
            messageIsError = false

            DashboardViewModel.recordTagCreateAndAddOnBlock(
                coordinator: coordinator,
                source: metricsSource,
                tagID: createdTag.id.value,
                tagName: createdTag.name,
                segmentCount: 1
            )
            TimelineWindowController.shared.refreshTapeIndicatorsAfterExternalMutation(
                reason: "quick_comment_tag_created"
            )
        } catch {
            Log.error("[QuickComment] Failed to create tag '\(tagName)': \(error)", category: .ui)
            messageText = "Could not create the tag."
            messageIsError = true
        }
    }

    @discardableResult
    func submitComment() async -> Bool {
        let commentBody = trimmedComment
        guard !commentBody.isEmpty else {
            messageText = "Comment cannot be empty."
            messageIsError = true
            return false
        }
        guard let target else { return false }
        guard !isReadOnlyTarget else {
            messageText = "Cannot comment on Rewind data."
            messageIsError = true
            return false
        }
        guard !isSubmittingComment else { return false }

        isSubmittingComment = true
        do {
            let createResult = try await coordinator.createCommentForSegments(
                body: commentBody,
                segmentIds: [target.segmentID],
                attachments: [],
                frameID: target.frameID,
                author: nil
            )

            newCommentText = ""
            messageText = nil
            messageIsError = false
            isSubmittingComment = false

            DashboardViewModel.recordCommentAdded(
                coordinator: coordinator,
                source: metricsSource,
                requestedSegmentCount: 1,
                linkedSegmentCount: createResult.linkedSegmentIDs.count,
                bodyLength: commentBody.count,
                attachmentCount: 0,
                hasFrameAnchor: true
            )
            TimelineWindowController.shared.refreshTapeIndicatorsAfterExternalMutation(
                reason: "quick_comment_added"
            )
            return true
        } catch {
            isSubmittingComment = false
            Log.error("[QuickComment] Failed to submit comment: \(error)", category: .ui)
            messageText = "Could not add the comment."
            messageIsError = true
            return false
        }
    }

    private func loadAvailableTagsIfNeeded() async {
        guard availableTags.isEmpty else { return }

        do {
            availableTags = try await coordinator.getAllTags()
                .filter { !$0.isHidden }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            Log.error("[QuickComment] Failed to load available tags: \(error)", category: .ui)
            messageText = "Could not load tags."
            messageIsError = true
        }
    }

    private static func loadPersistedPreviewImage(
        for frame: FrameWithVideoInfo,
        coordinator: AppCoordinator
    ) async -> NSImage? {
        do {
            let data: Data
            if let videoInfo = frame.videoInfo {
                data = try await coordinator.getFrameImageFromPath(
                    videoPath: videoInfo.videoPath,
                    frameIndex: videoInfo.frameIndex
                )
            } else {
                data = try await coordinator.getFrameImage(
                    segmentID: frame.frame.videoID,
                    timestamp: frame.frame.timestamp
                )
            }
            return NSImage(data: data)
        } catch {
            Log.error("[QuickComment] Failed to load preview for frame \(frame.frame.id.value): \(error)", category: .ui)
            return nil
        }
    }

    private static func loadPreviewImage(
        for frame: FrameWithVideoInfo,
        coordinator: AppCoordinator
    ) async -> NSImage? {
        if let diskBufferedPreview = await SimpleTimelineViewModel.loadTimelineDiskFrameBufferPreviewImage(
            for: frame.frame.id,
            logPrefix: "[QuickComment]"
        ) {
            return diskBufferedPreview
        }

        return await loadPersistedPreviewImage(for: frame, coordinator: coordinator)
    }

    private static func preferredTargetFrame(from frames: [FrameWithVideoInfo]) -> FrameWithVideoInfo? {
        guard !frames.isEmpty else { return nil }

        for frame in frames {
            let metadata = frame.frame.metadata
            if !StandaloneCommentComposerWindowController.isSelfCaptureCandidate(
                appBundleID: metadata.appBundleID,
                windowName: metadata.windowName
            ) {
                return frame
            }
        }

        return frames.first
    }

    private static func makeTarget(from frame: FrameWithVideoInfo) -> CommentComposerTargetDisplayInfo {
        let metadata = frame.frame.metadata
        return CommentComposerTargetDisplayInfo(
            frameID: frame.frame.id,
            segmentID: SegmentID(value: frame.frame.segmentID.value),
            source: frame.frame.source,
            timestamp: frame.frame.timestamp,
            appBundleID: metadata.appBundleID,
            appName: metadata.appName,
            windowName: metadata.windowName,
            browserURL: metadata.browserURL
        )
    }
}
