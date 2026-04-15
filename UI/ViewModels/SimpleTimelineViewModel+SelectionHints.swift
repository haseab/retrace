import App
import AppKit
import AVFoundation
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    enum PhraseLevelRedactionTooltipState: Equatable {
        case queued
        case reveal
        case hide

        var title: String {
            switch self {
            case .queued:
                return "Queued..."
            case .reveal:
                return "Reveal"
            case .hide:
                return "Hide"
            }
        }

        var tooltipText: String {
            title
        }

        var isInteractive: Bool {
            switch self {
            case .queued:
                return false
            case .reveal, .hide:
                return true
            }
        }
    }

    enum PhraseLevelRedactionOutlineState: Equatable {
        case hidden
        case queued
        case active
    }

    public enum DragSelectionMode: Sendable {
        case character
        case box
    }
}

extension SimpleTimelineViewModel {
    /// Select all text (Cmd+A) - respects zoom region if active
    public func selectAllText() {
        // Use nodes in zoom region if active, otherwise all nodes
        let nodesToSelect = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        guard !nodesToSelect.isEmpty else { return }

        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = true
        // Set selection to span all nodes - use same sorting as getSelectionRange (reading order)
        let sortedNodes = nodesToSelect.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }
        if let first = sortedNodes.first, let last = sortedNodes.last {
            setTextSelection(
                start: (nodeID: first.id, charIndex: 0),
                end: (nodeID: last.id, charIndex: last.text.count)
            )
        }
    }

    /// Clear text selection
    public func clearTextSelection() {
        setTextSelection(start: nil, end: nil)
        isAllTextSelected = false
        boxSelectedNodeIDs.removeAll()
        activeDragSelectionMode = .character
        dragStartPoint = nil
        dragEndPoint = nil
    }

    /// Start drag selection at a point (normalized coordinates)
    public func startDragSelection(at point: CGPoint, mode: DragSelectionMode = .character) {
        if mode == .box {
            triggerDragStartStillFrameOCRIfNeeded(gesture: "cmd-drag")
        }

        dragStartPoint = point
        dragEndPoint = point
        isAllTextSelected = false
        activeDragSelectionMode = mode

        switch mode {
        case .character:
            boxSelectedNodeIDs.removeAll()
            // Find the character position at this point.
            if let position = findCharacterPosition(at: point) {
                setTextSelection(start: position, end: position)
            } else {
                setTextSelection(start: nil, end: nil)
            }
        case .box:
            setTextSelection(start: nil, end: nil)
            updateBoxSelectionFromDragRect()
        }
    }

    /// Update drag selection to a point (normalized coordinates)
    public func updateDragSelection(to point: CGPoint, mode: DragSelectionMode? = nil) {
        if let mode {
            activeDragSelectionMode = mode
        }
        dragEndPoint = point

        switch activeDragSelectionMode {
        case .character:
            // Find the character position at the current point.
            if let position = findCharacterPosition(at: point) {
                setTextSelection(start: selectionStart, end: position)
            }
        case .box:
            updateBoxSelectionFromDragRect()
        }
    }

    /// End drag selection
    public func endDragSelection() {
        // Keep selection but clear drag points
        // Keep drag points - they're used for rectangle-based column filtering
        // They will be cleared when clearTextSelection() is called
    }

    /// Select the word at the given point (for double-click)
    public func selectWordAt(point: CGPoint) {
        guard let (nodeID, charIndex) = findCharacterPosition(at: point) else { return }
        guard let node = ocrNodes.first(where: { $0.id == nodeID }) else { return }

        let text = node.text
        guard !text.isEmpty else { return }

        // Clamp charIndex to valid range
        let clampedIndex = max(0, min(charIndex, text.count - 1))

        // Find word boundaries
        let (wordStart, wordEnd) = findWordBoundaries(in: text, around: clampedIndex)

        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = false
        setTextSelection(
            start: (nodeID: nodeID, charIndex: wordStart),
            end: (nodeID: nodeID, charIndex: wordEnd)
        )
    }

    /// Select all text in the node at the given point (for triple-click)
    public func selectNodeAt(point: CGPoint) {
        guard let (nodeID, _) = findCharacterPosition(at: point) else { return }
        guard let node = ocrNodes.first(where: { $0.id == nodeID }) else { return }

        // Select the entire node's text
        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = false
        setTextSelection(
            start: (nodeID: nodeID, charIndex: 0),
            end: (nodeID: nodeID, charIndex: node.text.count)
        )
    }

    /// Update Cmd+drag selection to include every node intersecting the current drag box.
    private func updateBoxSelectionFromDragRect() {
        guard let start = dragStartPoint, let end = dragEndPoint else {
            boxSelectedNodeIDs.removeAll()
            return
        }

        let rectMinX = min(start.x, end.x)
        let rectMaxX = max(start.x, end.x)
        let rectMinY = min(start.y, end.y)
        let rectMaxY = max(start.y, end.y)
        let dragRect = CGRect(
            x: rectMinX,
            y: rectMinY,
            width: rectMaxX - rectMinX,
            height: rectMaxY - rectMinY
        )

        let nodesToCheck = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        boxSelectedNodeIDs = Set(
            nodesToCheck.compactMap { node in
                let nodeRect = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
                // Inclusive overlap check so edge-touching nodes are selected.
                let intersects =
                    nodeRect.maxX >= dragRect.minX &&
                    nodeRect.minX <= dragRect.maxX &&
                    nodeRect.maxY >= dragRect.minY &&
                    nodeRect.minY <= dragRect.maxY
                return intersects ? node.id : nil
            }
        )
    }

    /// Find word boundaries around a character index
    private func findWordBoundaries(in text: String, around index: Int) -> (start: Int, end: Int) {
        guard !text.isEmpty else { return (0, 0) }

        let chars = Array(text)
        let clampedIndex = max(0, min(index, chars.count - 1))

        // Define word characters (alphanumeric and some punctuation that's part of words)
        func isWordChar(_ char: Character) -> Bool {
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }

        // Find start of word (scan backwards)
        var wordStart = clampedIndex
        while wordStart > 0 && isWordChar(chars[wordStart - 1]) {
            wordStart -= 1
        }

        // Find end of word (scan forwards)
        var wordEnd = clampedIndex
        while wordEnd < chars.count && isWordChar(chars[wordEnd]) {
            wordEnd += 1
        }

        // If we didn't find a word (clicked on whitespace/punctuation), select just that character
        if wordStart == wordEnd {
            wordEnd = min(wordStart + 1, chars.count)
        }

        return (start: wordStart, end: wordEnd)
    }

    // MARK: - Text Selection Hint Banner Methods

    /// Show the text selection hint banner once per drag session
    /// Call this during drag updates - it will only show the banner the first time per drag
    public func showTextSelectionHintBannerOnce() {
        guard !hasShownHintThisDrag else { return }
        hasShownHintThisDrag = true
        showTextSelectionHintBanner()
    }

    /// Reset the hint banner state (call when drag ends)
    public func resetTextSelectionHintState() {
        hasShownHintThisDrag = false
    }

    /// Show the text selection hint banner with auto-dismiss after 5 seconds
    public func showTextSelectionHintBanner() {
        // Cancel any existing timer
        textSelectionHintTimer?.invalidate()

        // Show the banner
        showTextSelectionHint = true

        // Auto-dismiss after 5 seconds
        textSelectionHintTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissTextSelectionHint()
            }
        }
    }

    /// Dismiss the text selection hint banner
    public func dismissTextSelectionHint() {
        textSelectionHintTimer?.invalidate()
        textSelectionHintTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showTextSelectionHint = false
        }
    }

    // MARK: - Timeline Tape Right-Click Hint Methods

    func showTimelineTapeRightClickHint(autoDismissAfter: TimeInterval = 5) {
        timelineTapeRightClickHintDismissTask?.cancel()
        timelineTapeRightClickHintDismissTask = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            showTimelineTapeRightClickHintBanner = true
        }

        TimelineMetrics.recordTimelineTapeRightClickHintAction(
            coordinator: coordinator,
            action: "shown",
            trigger: "bubble_scroll_dismiss"
        )

        let dismissDelayNs = Int64(max(0, autoDismissAfter) * 1_000_000_000)
        timelineTapeRightClickHintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .nanoseconds(dismissDelayNs), clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.timelineTapeRightClickHintDismissTask = nil
            self.clearTimelineTapeRightClickHint(cancelDismissTask: false)
            TimelineMetrics.recordTimelineTapeRightClickHintAction(
                coordinator: self.coordinator,
                action: "auto_dismissed",
                trigger: "bubble_scroll_dismiss"
            )
        }
    }

    public func dismissTimelineTapeRightClickHint() {
        clearTimelineTapeRightClickHint()
        TimelineMetrics.recordTimelineTapeRightClickHintAction(
            coordinator: coordinator,
            action: "dismissed",
            trigger: "bubble_scroll_dismiss"
        )
    }

    func clearTimelineTapeRightClickHint(
        animated: Bool = true,
        cancelDismissTask: Bool = true
    ) {
        if cancelDismissTask {
            timelineTapeRightClickHintDismissTask?.cancel()
            timelineTapeRightClickHintDismissTask = nil
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                showTimelineTapeRightClickHintBanner = false
            }
        } else {
            showTimelineTapeRightClickHintBanner = false
        }
    }

    // MARK: - Scroll Orientation Hint Methods

    /// Show the scroll orientation hint banner with auto-dismiss after 8 seconds
    public func showScrollOrientationHint(current: String) {
        scrollOrientationHintCurrentOrientation = current
        scrollOrientationHintTimer?.invalidate()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showScrollOrientationHintBanner = true
        }

        scrollOrientationHintTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissScrollOrientationHint()
            }
        }
    }

    /// Dismiss the scroll orientation hint banner
    public func dismissScrollOrientationHint() {
        scrollOrientationHintTimer?.invalidate()
        scrollOrientationHintTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showScrollOrientationHintBanner = false
        }
    }

    /// Open settings and guide the user to timeline scroll orientation controls.
    public func openTimelineScrollOrientationSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        NotificationCenter.default.post(name: .openSettingsTimelineScrollOrientation, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openSettingsTimelineScrollOrientation, object: nil)
        }
        dismissScrollOrientationHint()
    }

    // MARK: - Controls Hidden Restore Guidance

    /// Clear any controls-hidden restore guidance and ensure controls start visible on the next open.
    public func resetControlsVisibilityForNextOpen() {
        areControlsHidden = false
        clearControlsHiddenRestoreGuidance(animated: false)
    }

    func showControlsIfHidden() {
        guard areControlsHidden else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            areControlsHidden = false
        }
        clearControlsHiddenRestoreGuidance()
    }

    func armControlsHiddenRestoreGuidance() {
        highlightShowControlsContextMenuRow = true

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            showControlsHiddenRestoreHintBanner = true
        }
    }

    public func dismissControlsHiddenRestoreHint() {
        withAnimation(.easeOut(duration: 0.2)) {
            showControlsHiddenRestoreHintBanner = false
        }
    }

    public func showPositionRecoveryHint(
        hiddenElapsedSeconds: TimeInterval,
        autoDismissAfter: TimeInterval = 10
    ) {
        guard !Self.positionRecoveryHintDismissedForSession else {
            return
        }

        positionRecoveryHintDismissTask?.cancel()
        positionRecoveryHintDismissTask = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            showPositionRecoveryHintBanner = true
        }

        TimelineMetrics.recordPositionRecoveryHintAction(
            coordinator: coordinator,
            action: "shown",
            source: "cache_bust_reopen",
            seconds: max(0, Int(hiddenElapsedSeconds.rounded(.down)))
        )

        let dismissDelayNs = Int64(max(0, autoDismissAfter) * 1_000_000_000)
        positionRecoveryHintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .nanoseconds(dismissDelayNs), clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.positionRecoveryHintDismissTask = nil
            self.clearPositionRecoveryHint(cancelDismissTask: false)
            TimelineMetrics.recordPositionRecoveryHintAction(
                coordinator: self.coordinator,
                action: "auto_dismissed",
                source: "cache_bust_reopen"
            )
        }
    }

    public func dismissPositionRecoveryHint() {
        Self.positionRecoveryHintDismissedForSession = true
        clearPositionRecoveryHint()
        TimelineMetrics.recordPositionRecoveryHintAction(
            coordinator: coordinator,
            action: "dismissed",
            source: "cache_bust_reopen"
        )
    }

    func clearControlsHiddenRestoreGuidance(animated: Bool = true) {
        highlightShowControlsContextMenuRow = false

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                showControlsHiddenRestoreHintBanner = false
            }
        } else {
            showControlsHiddenRestoreHintBanner = false
        }
    }

    func clearPositionRecoveryHintForSupersedingNavigation() {
        guard showPositionRecoveryHintBanner else { return }
        clearPositionRecoveryHint()
    }

    func clearPositionRecoveryHint(
        animated: Bool = true,
        cancelDismissTask: Bool = true
    ) {
        if cancelDismissTask {
            positionRecoveryHintDismissTask?.cancel()
            positionRecoveryHintDismissTask = nil
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                showPositionRecoveryHintBanner = false
            }
        } else {
            showPositionRecoveryHintBanner = false
        }
    }
}
