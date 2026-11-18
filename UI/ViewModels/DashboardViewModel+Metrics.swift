import CoreGraphics
import CrashRecoverySupport
import Foundation
import App
import Database

extension DashboardViewModel {
    // MARK: - Metric Event Recording

    /// Record a timeline open event
    public static func recordTimelineOpen(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .timelineOpens)
    }

    /// Record a search event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - query: The search query text to store in metadata
    public static func recordSearch(coordinator: AppCoordinator, query: String) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .searches, metadata: query)
    }

    /// Record a text copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - text: The copied text to store in metadata
    public static func recordTextCopy(coordinator: AppCoordinator, text: String) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .textCopies, metadata: text)
    }

    /// Record an image copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - frameID: Optional frame ID that was copied
    public static func recordImageCopy(coordinator: AppCoordinator, frameID: Int64? = nil) {
        UIMetricsRecorder.recordString(
            coordinator: coordinator,
            type: .imageCopies,
            value: frameID
        )
    }

    /// Record an image save event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - frameID: Optional frame ID that was saved
    public static func recordImageSave(coordinator: AppCoordinator, frameID: Int64? = nil) {
        UIMetricsRecorder.recordString(
            coordinator: coordinator,
            type: .imageSaves,
            value: frameID
        )
    }

    /// Record a deeplink copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - url: The deeplink URL that was copied
    public static func recordDeeplinkCopy(coordinator: AppCoordinator, url: String) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .deeplinkCopies, metadata: url)
    }

    /// Record timeline session duration (only if > 3 seconds)
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - duration: Duration in milliseconds
    public static func recordTimelineSession(coordinator: AppCoordinator, durationMs: Int64) {
        guard durationMs > 3000 else { return }
        UIMetricsRecorder.recordString(
            coordinator: coordinator,
            type: .timelineSessionDuration,
            value: durationMs
        )
    }

    /// Record a filtered search query
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - metadata: Sanitized filtered-search metric payload
    public static func recordFilteredSearch(
        coordinator: AppCoordinator,
        metadata: FilteredSearchMetricMetadata
    ) {
        UIMetricsRecorder.recordEncodable(
            coordinator: coordinator,
            type: .filteredSearchQuery,
            payload: metadata
        )
    }

    /// Record a timeline filter query
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - metadata: Sanitized timeline-filter metric payload
    public static func recordTimelineFilter(
        coordinator: AppCoordinator,
        metadata: TimelineFilterMetricMetadata
    ) {
        UIMetricsRecorder.recordEncodable(
            coordinator: coordinator,
            type: .timelineFilterQuery,
            payload: metadata
        )
    }

    /// Record scrub distance for the session
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - distancePixels: Total scrub distance in pixels
    public static func recordScrubDistance(coordinator: AppCoordinator, distancePixels: Double) {
        UIMetricsRecorder.recordString(
            coordinator: coordinator,
            type: .scrubDistance,
            value: Int(distancePixels)
        )
    }

    /// Record a search dialog open event
    public static func recordSearchDialogOpen(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .searchDialogOpens)
    }

    /// Record an OCR reprocess request
    public static func recordOCRReprocess(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .ocrReprocessRequests)
    }

    /// Record an arrow key navigation event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - direction: "left" or "right"
    public static func recordArrowKeyNavigation(coordinator: AppCoordinator, direction: String) {
        UIMetricsRecorder.record(
            coordinator: coordinator,
            type: .arrowKeyNavigation,
            metadata: direction
        )
    }

    /// Record a shift+drag zoom region event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - region: The bounding box of the zoom region
    ///   - screenSize: The size of the screen
    public static func recordShiftDragZoom(
        coordinator: AppCoordinator,
        region: CGRect,
        screenSize: CGSize
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .shiftDragZoomRegion,
            payload: [
                "region": [
                    "x": Double(region.origin.x),
                    "y": Double(region.origin.y),
                    "width": Double(region.width),
                    "height": Double(region.height)
                ],
                "screenSize": [
                    "width": Double(screenSize.width),
                    "height": Double(screenSize.height)
                ]
            ]
        )
    }

    /// Record a shift+drag text copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - copiedText: The text that was copied
    public static func recordShiftDragTextCopy(coordinator: AppCoordinator, copiedText: String) {
        UIMetricsRecorder.record(
            coordinator: coordinator,
            type: .shiftDragTextCopy,
            metadata: copiedText
        )
    }

    /// Record transient OCR triggered by drag-start on a still-only frame (p=4).
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - gesture: Gesture that triggered OCR ("shift-drag" or "cmd-drag")
    ///   - frameID: Frame identifier for diagnostic correlation
    public static func recordStillFrameDragOCR(
        coordinator: AppCoordinator,
        gesture: String,
        frameID: Int64
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .stillFrameDragOCR,
            payload: [
                "gesture": gesture,
                "frameID": frameID
            ]
        )
    }

    /// Record an app launch event
    public static func recordAppLaunch(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .appLaunches)
    }

    public static func recordCrashAutoRestart(
        coordinator: AppCoordinator,
        source: CrashRecoverySupport.RelaunchSource
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .crashAutoRestart,
            payload: ["source": source.rawValue]
        )
    }

    /// Record a keyboard shortcut usage
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - shortcut: The shortcut identifier (e.g. "cmd+shift+t", "cmd+f")
    public static func recordKeyboardShortcut(coordinator: AppCoordinator, shortcut: String) {
        UIMetricsRecorder.record(
            coordinator: coordinator,
            type: .keyboardShortcut,
            metadata: shortcut
        )
    }

    /// Record a debug-only watchdog hang trigger from the dashboard.
    public static func recordDebugWatchdogHangTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugWatchdogHangTriggered)
    }

    /// Record a debug-only capture interruption trigger from the dashboard.
    public static func recordDebugCaptureInterruptionTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugCaptureInterruptionTriggered)
    }

    /// Record a debug-only encoding interruption trigger from the dashboard.
    public static func recordDebugEncodingInterruptionTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugEncodingInterruptionTriggered)
    }

    /// Record a debug-only forced termination trigger from the dashboard.
    public static func recordDebugForcedTerminationTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugForcedTerminationTriggered)
    }

    /// Record a debug-only onboarding relaunch from the dashboard.
    public static func recordDebugOnboardingRelaunchTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugOnboardingRelaunchTriggered)
    }

    public static func recordDeveloperSettingToggle(
        coordinator: AppCoordinator,
        source: String,
        settingKey: String,
        isEnabled: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .developerSettingToggle,
            payload: [
                "source": source,
                "settingKey": settingKey,
                "isEnabled": isEnabled
            ]
        )
    }

    /// Record a debug-only crash trigger from the dashboard.
    public static func recordDebugCrashTriggered(coordinator: AppCoordinator) {
        UIMetricsRecorder.record(coordinator: coordinator, type: .debugCrashTriggered)
    }

    public static func recordDateSearchSubmitted(
        coordinator: AppCoordinator,
        source: String,
        query: String,
        queryLength: Int,
        frameIDSearchEnabled: Bool,
        lookedLikeFrameID: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .dateSearchSubmitted,
            payload: [
                "source": source,
                "query": query,
                "queryLength": queryLength,
                "frameIDSearchEnabled": frameIDSearchEnabled,
                "lookedLikeFrameID": lookedLikeFrameID
            ]
        )
    }

    public static func recordDateSearchOutcome(
        coordinator: AppCoordinator,
        source: String,
        query: String,
        outcome: String,
        queryLength: Int,
        frameIDLookupAttempted: Bool,
        frameCount: Int? = nil
    ) {
        var payload: [String: Any] = [
            "source": source,
            "query": query,
            "outcome": outcome,
            "queryLength": queryLength,
            "frameIDLookupAttempted": frameIDLookupAttempted
        ]
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .dateSearchOutcome,
            payload: payload
        )
    }

    public static func recordBrowserLinkOpened(
        coordinator: AppCoordinator,
        source: String,
        url: String,
        usedYouTubeTimestamp: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .browserLinkOpened,
            payload: [
                "source": source,
                "url": url,
                "usedYouTubeTimestamp": usedYouTubeTimestamp
            ]
        )
    }

    public static func recordSegmentHide(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int,
        hiddenFilter: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .segmentHide,
            payload: [
                "source": source,
                "segmentCount": segmentCount,
                "frameCount": frameCount,
                "hiddenFilter": hiddenFilter
            ]
        )
    }

    public static func recordSegmentUnhide(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int,
        hiddenFilter: String,
        removedFromCurrentView: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .segmentUnhide,
            payload: [
                "source": source,
                "segmentCount": segmentCount,
                "frameCount": frameCount,
                "hiddenFilter": hiddenFilter,
                "removedFromCurrentView": removedFromCurrentView
            ]
        )
    }

    public static func recordTagSubmenuOpen(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int?,
        frameCount: Int?,
        selectedTagCount: Int?
    ) {
        var payload: [String: Any] = ["source": source]
        if let segmentCount {
            payload["segmentCount"] = segmentCount
        }
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        if let selectedTagCount {
            payload["selectedTagCount"] = selectedTagCount
        }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .tagSubmenuOpen,
            payload: payload
        )
    }

    public static func recordTagToggleOnBlock(
        coordinator: AppCoordinator,
        source: String,
        tagID: Int64,
        tagName: String,
        action: String,
        segmentCount: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .tagToggleOnBlock,
            payload: [
                "source": source,
                "tagID": tagID,
                "tagName": tagName,
                "action": action,
                "segmentCount": segmentCount
            ]
        )
    }

    public static func recordTagCreateAndAddOnBlock(
        coordinator: AppCoordinator,
        source: String,
        tagID: Int64,
        tagName: String,
        segmentCount: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .tagCreateAndAddOnBlock,
            payload: [
                "source": source,
                "tagID": tagID,
                "tagName": tagName,
                "segmentCount": segmentCount
            ]
        )
    }

    public static func recordCommentSubmenuOpen(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int?,
        frameCount: Int?,
        existingCommentCount: Int?
    ) {
        var payload: [String: Any] = ["source": source]
        if let segmentCount {
            payload["segmentCount"] = segmentCount
        }
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        if let existingCommentCount {
            payload["existingCommentCount"] = existingCommentCount
        }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .commentSubmenuOpen,
            payload: payload
        )
    }

    public static func recordQuickCommentOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .quickCommentOpened,
            payload: ["source": source]
        )
    }

    public static func recordQuickCommentClosed(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .quickCommentClosed,
            payload: ["source": source]
        )
    }

    public static func recordQuickCommentContextPreviewToggle(
        coordinator: AppCoordinator,
        source: String,
        isCollapsed: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .quickCommentContextPreviewToggle,
            payload: [
                "source": source,
                "isCollapsed": isCollapsed
            ]
        )
    }

    public static func recordTimelineAutoDismissed(
        coordinator: AppCoordinator,
        activatedBundleID: String? = nil
    ) {
        var payload: [String: Any] = ["trigger": "app_activation"]
        if let activatedBundleID {
            payload["activatedBundleID"] = activatedBundleID
        }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .timelineAutoDismissed,
            payload: payload
        )
    }

    public static func recordCommentAdded(
        coordinator: AppCoordinator,
        source: String,
        requestedSegmentCount: Int,
        linkedSegmentCount: Int,
        bodyLength: Int,
        attachmentCount: Int,
        hasFrameAnchor: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .commentAdded,
            payload: [
                "source": source,
                "requestedSegmentCount": requestedSegmentCount,
                "linkedSegmentCount": linkedSegmentCount,
                "bodyLength": bodyLength,
                "attachmentCount": attachmentCount,
                "hasFrameAnchor": hasFrameAnchor
            ]
        )
    }

    public static func recordCommentDeletedFromBlock(
        coordinator: AppCoordinator,
        source: String,
        linkedSegmentCount: Int,
        hadFrameAnchor: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .commentDeletedFromBlock,
            payload: [
                "source": source,
                "linkedSegmentCount": linkedSegmentCount,
                "hadFrameAnchor": hadFrameAnchor
            ]
        )
    }

    public static func recordCommentAttachmentPickerOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .commentAttachmentPickerOpened,
            payload: ["source": source]
        )
    }

    public static func recordCommentAttachmentOpened(
        coordinator: AppCoordinator,
        source: String,
        fileExtension: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .commentAttachmentOpened,
            payload: [
                "source": source,
                "fileExtension": fileExtension
            ]
        )
    }

    public static func recordAllCommentsOpened(
        coordinator: AppCoordinator,
        source: String,
        anchorCommentID: Int64?
    ) {
        var payload: [String: Any] = ["source": source]
        if let anchorCommentID {
            payload["anchorCommentID"] = anchorCommentID
        }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .allCommentsOpened,
            payload: payload
        )
    }

    public static func recordPlaybackToggled(
        coordinator: AppCoordinator,
        source: String,
        wasPlaying: Bool,
        isPlaying: Bool,
        speed: Double
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .playbackToggled,
            payload: [
                "source": source,
                "wasPlaying": wasPlaying,
                "isPlaying": isPlaying,
                "speed": speed
            ]
        )
    }

    public static func recordPlaybackSpeedChanged(
        coordinator: AppCoordinator,
        source: String,
        previousSpeed: Double,
        newSpeed: Double,
        isPlaying: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .playbackSpeedChanged,
            payload: [
                "source": source,
                "previousSpeed": previousSpeed,
                "newSpeed": newSpeed,
                "isPlaying": isPlaying
            ]
        )
    }

    public static func recordRecordingStartedFromMenu(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .recordingStartedFromMenu,
            payload: ["source": source]
        )
    }

    public static func recordRecordingPauseSelected(
        coordinator: AppCoordinator,
        source: String,
        durationSeconds: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .recordingPauseSelected,
            payload: [
                "source": source,
                "durationSeconds": durationSeconds
            ]
        )
    }

    public static func recordRecordingTurnedOff(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .recordingTurnedOff,
            payload: ["source": source]
        )
    }

    public static func recordRecordingAutoResumed(
        coordinator: AppCoordinator,
        source: String,
        pausedDurationSeconds: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .recordingAutoResumed,
            payload: [
                "source": source,
                "pausedDurationSeconds": pausedDurationSeconds
            ]
        )
    }

    public static func recordSystemMonitorOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .systemMonitorOpened,
            payload: ["source": source]
        )
    }

    public static func recordHelpOpened(coordinator: AppCoordinator, source: String) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .helpOpened,
            payload: ["source": source]
        )
    }

    public static func recordSettingsSearchOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .settingsSearchOpened,
            payload: ["source": source]
        )
    }

    public static func recordRedactionRulesUpdated(
        coordinator: AppCoordinator,
        windowPatternCount: Int,
        urlPatternCount: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .redactionRulesUpdated,
            payload: [
                "windowPatternCount": windowPatternCount,
                "urlPatternCount": urlPatternCount
            ]
        )
    }

    public static func recordPrivateWindowRedactionToggle(
        coordinator: AppCoordinator,
        enabled: Bool,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .privateWindowRedactionToggle,
            payload: [
                "enabled": enabled,
                "source": source
            ]
        )
    }

    public static func recordSystemMonitorSettingsOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .systemMonitorSettingsOpened,
            payload: ["source": source]
        )
    }

    public static func recordSystemMonitorOpenPowerOCRCard(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .systemMonitorOpenPowerOCRCard,
            payload: ["source": source]
        )
    }

    public static func recordSystemMonitorOpenPowerOCRPriority(
        coordinator: AppCoordinator,
        source: String
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .systemMonitorOpenPowerOCRPriority,
            payload: ["source": source]
        )
    }

    public static func recordSystemMonitorMemoryLogToggle(
        coordinator: AppCoordinator,
        source: String,
        expanded: Bool
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .systemMonitorMemoryLogToggle,
            payload: [
                "source": source,
                "expanded": expanded
            ]
        )
    }

    public static func recordFrameDeleted(
        coordinator: AppCoordinator,
        source: String,
        frameID: Int64
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .frameDeleted,
            payload: [
                "source": source,
                "frameID": frameID
            ]
        )
    }

    public static func recordSegmentDeleted(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int
    ) {
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .segmentDeleted,
            payload: [
                "source": source,
                "segmentCount": segmentCount,
                "frameCount": frameCount
            ]
        )
    }
}
