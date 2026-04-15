import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TimelineWindowController {
    // MARK: - Key Code Mapping

    func keyCodeForString(_ key: String) -> UInt16 {
        switch key.lowercased() {
        case "space": return 49
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "left", "leftarrow", "←": return 123
        case "right", "rightarrow", "→": return 124
        case "down", "downarrow", "↓": return 125
        case "up", "uparrow", "↑": return 126

        // Letters
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6

        // Numbers
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25

        default: return 0
        }
    }

    nonisolated static func shouldHandleTimelineKeyboardShortcuts(
        isTimelineVisible: Bool,
        frontmostProcessID: pid_t?,
        currentProcessID: pid_t
    ) -> Bool {
        guard isTimelineVisible, let frontmostProcessID else { return false }
        return frontmostProcessID == currentProcessID
    }

    nonisolated static func shouldToggleSearchOverlayFromShortcut(
        isActivelyScrolling: Bool,
        isSettledAtAbsoluteTimelineBoundary: Bool = false
    ) -> Bool {
        !isActivelyScrolling || isSettledAtAbsoluteTimelineBoundary
    }

    nonisolated static func searchOverlayShortcutAction(
        isSearchOverlayVisible: Bool,
        shouldRefocusSearchFieldBeforeClose: Bool
    ) -> SearchOverlayShortcutAction {
        guard isSearchOverlayVisible else { return .open }
        return shouldRefocusSearchFieldBeforeClose ? .focusField : .close
    }

    // MARK: - Scrub Distance Tracking

    /// Accumulate scrub distance for the current session
    public func accumulateScrubDistance(_ distance: Double) {
        sessionScrubDistance += distance
    }

    // MARK: - Image & Link Actions (Keyboard Shortcuts)

    func copyCurrentFrameImage() {
        guard let viewModel = timelineViewModel else { return }
        viewModel.copyCurrentFrameImageToClipboard()
    }

    func saveCurrentFrameImage() {
        guard let viewModel = timelineViewModel else { return }
        getCurrentFrameImage(viewModel: viewModel) { [weak self] image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = formatter.string(from: viewModel.currentTimestamp ?? Date())
            savePanel.nameFieldStringValue = "retrace-\(timestamp).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                        if let coordinator = self?.coordinator {
                            DashboardViewModel.recordImageSave(coordinator: coordinator, frameID: viewModel.currentFrame?.id.value)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    func copyMomentLink() -> Bool {
        guard let viewModel = timelineViewModel,
              !viewModel.isInLiveMode,
              let timestamp = viewModel.currentTimestamp,
              let url = DeeplinkHandler.generateTimelineLink(timestamp: timestamp) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        viewModel.showToast("Moment Link copied")
        if let coordinator = coordinator {
            DashboardViewModel.recordDeeplinkCopy(coordinator: coordinator, url: url.absoluteString)
        }
        return true
    }

    func getCurrentFrameImage(viewModel: SimpleTimelineViewModel, completion: @escaping (NSImage?) -> Void) {
        if viewModel.isInLiveMode {
            completion(viewModel.liveScreenshot)
            return
        }

        if let image = viewModel.currentImage {
            completion(image)
            return
        }

        guard let videoInfo = viewModel.currentVideoInfo else {
            completion(nil)
            return
        }

        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                completion(nil)
                return
            }
        }

        guard let url = MP4SymlinkResolver.resolveURL(for: actualVideoPath) else {
            completion(nil)
            return
        }

        let asset = AVURLAsset(url: url)
        let directDecodeBytes = UIDirectFrameDecodeMemoryLedger.begin(
            tag: UIDirectFrameDecodeMemoryLedger.timelineWindowGeneratorTag,
            function: "ui.timeline.window_actions",
            reason: "ui.timeline.window_frame_decode",
            videoInfo: videoInfo
        )
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let time = videoInfo.frameTimeCMTime

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                UIDirectFrameDecodeMemoryLedger.end(
                    tag: UIDirectFrameDecodeMemoryLedger.timelineWindowGeneratorTag,
                    reason: "ui.timeline.window_frame_decode",
                    bytes: directDecodeBytes
                )
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    completion(nil)
                }
            }
        }
    }

    func recordShortcut(_ shortcut: String) {
        if let coordinator = coordinator {
            DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: shortcut)
        }
    }

    nonisolated static func shouldDismissTimelineWithCommandW(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers == [.command] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 13 || key == "w"
    }

    nonisolated static func shouldDeferCommandAToTextInput(
        isTextFieldActive: Bool,
        isSearchOverlayVisible: Bool,
        isFilterPanelVisible: Bool,
        isDateSearchActive: Bool,
        isCommentSubmenuVisible: Bool
    ) -> Bool {
        isTextFieldActive ||
            isSearchOverlayVisible ||
            isFilterPanelVisible ||
            isDateSearchActive ||
            isCommentSubmenuVisible
    }

    nonisolated static func shouldNavigateTimelineBackward(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers.isEmpty || normalizedModifiers == [.option] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 123 || key == "j" || key == "l"
    }

    nonisolated static func shouldNavigateTimelineForward(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers.isEmpty || normalizedModifiers == [.option] else {
            return false
        }

        let key = charactersIgnoringModifiers?.lowercased()
        return keyCode == 124 || key == "k" || key == ";"
    }

    nonisolated static func searchResultNavigationDirection(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isSearchResultHighlightVisible: Bool
    ) -> SearchResultNavigationDirection? {
        guard isSearchResultHighlightVisible else { return nil }

        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        guard normalizedModifiers == [.command, .shift] else {
            return nil
        }

        switch keyCode {
        case 123:
            return .previous
        case 124:
            return .next
        default:
            return nil
        }
    }

    func shouldHandleTimelineKeyboardShortcuts() -> Bool {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return Self.shouldHandleTimelineKeyboardShortcuts(
            isTimelineVisible: isVisible,
            frontmostProcessID: frontmostProcessID,
            currentProcessID: currentProcessID
        )
    }

    func formattedPoint(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    /// Resolve quick app filter trigger key from an NSEvent.
    /// Supports Option+F.
    func quickAppFilterTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == [.option] && (key == "f" || event.keyCode == 3) {
            return "Option+F"
        }
        return nil
    }

    /// Resolve add-tag shortcut key from an NSEvent.
    /// Supports Cmd+T.
    func addTagShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        guard event.keyCode == 17 else { // T key
            return nil
        }
        if modifiers == [.command] {
            return "Cmd+T"
        }
        return nil
    }

    /// Resolve add-comment shortcut key from an NSEvent.
    /// Supports Option+C.
    func addCommentShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        guard event.keyCode == 8 else { // C key
            return nil
        }
        if modifiers == [.option] {
            return "Option+C"
        }
        return nil
    }

    /// Resolve open-link shortcut key from an NSEvent.
    /// Supports Cmd+Shift+L with both keycode and character fallback.
    func openLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command, .shift] ? "Cmd+Shift+L" : nil
    }

    /// Resolve copy-link shortcut key from an NSEvent.
    /// Supports Cmd+L with both keycode and character fallback.
    func copyLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command] ? "Cmd+L" : nil
    }

    /// Resolve copy-YouTube-markdown shortcut key from an NSEvent.
    /// Supports Option+Cmd+L with both keycode and character fallback.
    func copyYouTubeMarkdownLinkShortcutTrigger(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.command, .option] ? "Option+Cmd+L" : nil
    }

    /// Resolve copy-moment-link shortcut key from an NSEvent.
    /// Supports Option+Shift+L with both keycode and character fallback.
    func copyMomentLinkShortcutTrigger(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let matchesLKey = event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l"
        guard matchesLKey else { return nil }
        return modifiers == [.option, .shift] ? "Option+Shift+L" : nil
    }

    /// Toggle quick app filter for the app at the current playhead.
    /// First press applies a single-app include filter, second press clears it.
    func togglePlayheadAppFilter(trigger: String) {
        guard let viewModel = timelineViewModel else {
            return
        }

        let shortcutMetric = trigger == "Option+F" ? "opt+f" : "cmd+f"
        recordShortcut(shortcutMetric)

        guard let currentFrame = viewModel.currentTimelineFrame else {
            return
        }

        guard let bundleID = currentFrame.frame.metadata.appBundleID, !bundleID.isEmpty else {
            return
        }

        if isSingleAppOnlyIncludeFilter(viewModel.filterCriteria, matching: bundleID) {
            viewModel.beginCmdFQuickFilterLatencyTrace(
                bundleID: bundleID,
                action: "clear_app_filter",
                trigger: trigger,
                source: currentFrame.frame.source
            )
            viewModel.clearAllFilters()
            return
        }

        viewModel.beginCmdFQuickFilterLatencyTrace(
            bundleID: bundleID,
            action: "apply_app_filter",
            trigger: trigger,
            source: currentFrame.frame.source
        )

        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include

        // Use the same pending+apply path as the filter panel's Apply button.
        viewModel.replacePendingFilterCriteria(criteria)
        viewModel.applyFilters()
    }

    /// Hide or unhide the visible segment block at the current playhead index.
    func hidePlayheadSegment(trigger _: String) {
        guard let viewModel = timelineViewModel else { return }
        guard !viewModel.frames.isEmpty else { return }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        viewModel.setTimelineContextMenuAnchorIndex(clampedIndex)

        let isShowingHiddenSegments = viewModel.filterCriteria.hiddenFilter != .hide
        let isPlayheadSegmentHidden = viewModel.isFrameHidden(at: clampedIndex)

        if isShowingHiddenSegments && isPlayheadSegmentHidden {
            viewModel.unhideSelectedTimelineSegment()
        } else {
            viewModel.hideSelectedTimelineSegment()
        }
    }

    /// Open the timeline segment "Add Tag" submenu for the current playhead index.
    func openAddTagSubmenuAtPlayhead(trigger _: String) {
        guard let viewModel = timelineViewModel else {
            return
        }
        guard !viewModel.frames.isEmpty else {
            return
        }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        let menuLocation = defaultTimelineContextMenuLocation()

        viewModel.dismissOtherDialogs()

        // Reset menu state before re-opening to avoid stale/half-mounted submenu state.
        viewModel.prepareTimelineContextMenuSelection(index: clampedIndex, location: menuLocation)
        viewModel.setTimelineContextMenuVisible(false)
        viewModel.dismissTagEditing()

        // Open context menu on next runloop, then load tags, then open submenu.
        DispatchQueue.main.async { [weak self] in
            guard let self, let viewModel = self.timelineViewModel else {
                return
            }
            let liveIndex = max(0, min(viewModel.currentIndex, max(0, viewModel.frames.count - 1)))
            viewModel.prepareTimelineContextMenuSelection(index: liveIndex, location: menuLocation)
            viewModel.setTimelineContextMenuVisible(true)
            viewModel.setHoveringAddTagButton(true)

            Task { @MainActor in
                await viewModel.loadTags()

                DispatchQueue.main.async { [weak self] in
                    guard let self, let viewModel = self.timelineViewModel else {
                        return
                    }
                    // Re-assert menu visibility before opening submenu.
                    viewModel.setTimelineContextMenuVisible(true)
                    viewModel.setHoveringAddTagButton(true)
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.presentTagSubmenuInExistingContextMenu(source: "keyboard_cmd_t")
                    }
                }
            }
        }
    }

    /// Open the timeline segment "Add Comment" composer for the current playhead index.
    func openAddCommentComposerAtPlayhead(source: String) {
        guard let viewModel = timelineViewModel else {
            return
        }
        guard !viewModel.frames.isEmpty else {
            return
        }

        let clampedIndex = max(0, min(viewModel.currentIndex, viewModel.frames.count - 1))
        guard let block = viewModel.getBlock(forFrameAt: clampedIndex) else {
            return
        }

        viewModel.dismissOtherDialogs()
        withAnimation(.easeOut(duration: 0.15)) {
            viewModel.openCommentSubmenuForTimelineBlock(block, source: source)
        }
    }

    func defaultTimelineContextMenuLocation() -> CGPoint {
        guard let contentView = window?.contentView else {
            return .zero
        }
        let size = contentView.bounds.size
        return CGPoint(x: size.width * 0.5, y: max(48, size.height - 140))
    }

    func isSingleAppOnlyIncludeFilter(_ criteria: FilterCriteria, matching bundleID: String? = nil) -> Bool {
        guard criteria.appFilterMode == .include,
              let selectedApps = criteria.selectedApps,
              selectedApps.count == 1 else {
            return false
        }
        if let bundleID {
            guard selectedApps.contains(bundleID) else { return false }
        }

        let hasNoSources = criteria.selectedSources == nil || criteria.selectedSources?.isEmpty == true
        let hasNoTags = criteria.selectedTags == nil || criteria.selectedTags?.isEmpty == true
        let hasNoWindowFilter = criteria.windowNameFilter?.isEmpty ?? true
        let hasNoBrowserFilter = criteria.browserUrlFilter?.isEmpty ?? true

        return hasNoSources &&
            criteria.hiddenFilter == .hide &&
            criteria.commentFilter == .allFrames &&
            hasNoTags &&
            criteria.tagFilterMode == .include &&
            hasNoWindowFilter &&
            hasNoBrowserFilter &&
            criteria.effectiveDateRanges.isEmpty
    }

    // MARK: - Session Metrics

    /// Force-record active session metrics without blocking the main actor.
    /// Returns true when metrics were flushed before timeout, false otherwise.
    public func forceRecordSessionMetrics(timeoutMs: UInt64 = 350) async -> Bool {
        guard let startTime = sessionStartTime, let coordinator = coordinator else { return true }

        let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
        let scrubDistance = sessionScrubDistance > 0 ? Int(sessionScrubDistance) : nil

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await coordinator.recordMetricEvent(metricType: .timelineSessionDuration, metadata: "\(durationMs)")
                    if let scrubDistance {
                        try await coordinator.recordMetricEvent(metricType: .scrubDistance, metadata: "\(scrubDistance)")
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .nanoseconds(Int64(timeoutMs * 1_000_000)), clock: .continuous)
                    throw SessionMetricFlushTimeout()
                }

                _ = try await group.next()
                group.cancelAll()
            }

            Log.info("[TIMELINE] Session metrics flush completed during termination", category: .ui)
            return true
        } catch is SessionMetricFlushTimeout {
            Log.warning("[TIMELINE] Session metrics flush timed out after \(timeoutMs)ms during termination", category: .ui)
            return false
        } catch {
            Log.warning("[TIMELINE] Session metrics flush failed during termination: \(error)", category: .ui)
            return false
        }
    }
}

struct SessionMetricFlushTimeout: Error {}
