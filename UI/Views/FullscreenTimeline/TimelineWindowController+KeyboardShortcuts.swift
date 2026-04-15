import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TimelineWindowController {
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard shouldHandleTimelineKeyboardShortcuts() else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let addTagTrigger = addTagShortcutTrigger(for: event, modifiers: modifiers)
        let addCommentTrigger = addCommentShortcutTrigger(for: event, modifiers: modifiers)
        let isAddTagShortcut = addTagTrigger != nil

        // Don't handle escape if a modal panel (save panel, etc.) is open
        if NSApp.modalWindow != nil {
            return false
        }

        // Don't handle escape if our window is not the key window (e.g., save panel is open)
        if let keyWindow = NSApp.keyWindow, keyWindow != window {
            // Option+C must remain timeline-local; don't steal focus for it.
            if isAddTagShortcut {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            } else {
                return false
            }
        }

        if event.keyCode == 53 {
            return handleEscapeKey()
        }

        if Self.shouldDismissTimelineWithCommandW(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            recordShortcut("cmd+w")
            hide()
            return true
        }

        // Check if it's the toggle shortcut (uses saved shortcut config)
        let shortcutConfig = loadTimelineShortcut()
        let expectedKeyCode = keyCodeForString(shortcutConfig.key)
        if event.keyCode == expectedKeyCode && modifiers == shortcutConfig.modifiers.nsModifiers {
            hide()
            return true
        }

        // Cmd+F to toggle in-frame search
        if event.keyCode == 3 && modifiers == [.command] { // F key with Command
            recordShortcut("cmd+f")
            if let viewModel = timelineViewModel {
                viewModel.toggleInFrameSearch()
            }
            return true
        }

        // Cmd+G to toggle date search panel ("Go to" date)
        if event.keyCode == 5 && modifiers == [.command] { // G key with Command
            recordShortcut("cmd+g")
            if let viewModel = timelineViewModel {
                viewModel.toggleDateSearch()
            }
            return true
        }

        // Cmd+K to toggle search overlay
        if event.keyCode == 40 && modifiers == [.command] { // K key with Command
            recordShortcut("cmd+k")
            if let viewModel = timelineViewModel {
                guard Self.shouldToggleSearchOverlayFromShortcut(
                    isActivelyScrolling: viewModel.isActivelyScrolling,
                    isSettledAtAbsoluteTimelineBoundary: viewModel.isSettledAtAbsoluteTimelineBoundary
                ) else {
                    Log.info("[TimelineShortcut] Cmd+K ignored while scroll is active", category: .ui)
                    return true
                }
                let wasVisible = viewModel.isSearchOverlayVisible
                let action = Self.searchOverlayShortcutAction(
                    isSearchOverlayVisible: wasVisible,
                    shouldRefocusSearchFieldBeforeClose: viewModel.searchViewModel.shouldRefocusSearchFieldOnEscape
                )
                Log.info(
                    "[TimelineShortcut] Cmd+K action=\(String(describing: action)) wasVisible=\(wasVisible) fieldFocused=\(viewModel.searchViewModel.isSearchFieldFocused) queryEmpty=\(viewModel.searchViewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                    category: .ui
                )
                switch action {
                case .focusField:
                    viewModel.searchViewModel.requestSearchFieldFocus(selectAll: true)
                case .close:
                    viewModel.closeSearchOverlay()
                case .open:
                    _ = Self.presentSearchOverlay(
                        on: viewModel,
                        coordinator: coordinator,
                        recentEntriesRevealDelay: 0.3
                    )
                }
            }
            return true
        }

        // Option+H to hide segment block at playhead
        if event.keyCode == 4 && modifiers == [.option] { // H key with Option
            recordShortcut("opt+h")
            hidePlayheadSegment(trigger: "Option+H")
            return true
        }

        // Add Tag submenu for segment block at playhead (Cmd+T)
        if let trigger = addTagTrigger {
            recordShortcut("cmd+t")
            openAddTagSubmenuAtPlayhead(trigger: trigger)
            return true
        }

        // Add Comment composer for segment block at playhead (Option+C)
        if addCommentTrigger != nil {
            recordShortcut("opt+c")
            openAddCommentComposerAtPlayhead(source: "keyboard_opt_c")
            return true
        }

        // Option+F to toggle app filter for the current playhead frame
        if let trigger = quickAppFilterTrigger(for: event, modifiers: modifiers) {
            togglePlayheadAppFilter(trigger: trigger)
            return true
        }

        // Cmd+Shift+F to toggle filter panel
        if event.keyCode == 3 && modifiers == [.command, .shift] { // F key with Command+Shift
            recordShortcut("cmd+shift+f")
            if let viewModel = timelineViewModel {
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.openFilterPanel()
                    }
                }
            }
            return true
        }

        // Delete or Backspace key to delete selected frame
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty { // Backspace (51) or Delete (117)
            if let viewModel = timelineViewModel, viewModel.selectedFrameIndex != nil {
                viewModel.requestDeleteSelectedFrame()
                return true
            }
        }

        // Handle delete confirmation dialog keyboard shortcuts
        if let viewModel = timelineViewModel, viewModel.showDeleteConfirmation {
            // Enter/Return confirms deletion
            if event.keyCode == 36 || event.keyCode == 76 { // Return (36) or Enter (76)
                viewModel.confirmDeleteSelectedFrame()
                return true
            }
            // Escape cancels (handled above, but also catch it here for the dialog)
            if event.keyCode == 53 { // Escape
                viewModel.cancelDelete()
                return true
            }
        }

        // Cmd+A to select all text on the frame
        // Skip when text editing owns the shortcut.
        if event.keyCode == 0 && modifiers == [.command] { // A key with Command
            let isTextFieldActive = isTimelineTextFieldActive()

            if Self.shouldDeferCommandAToTextInput(
                isTextFieldActive: isTextFieldActive,
                isSearchOverlayVisible: timelineViewModel?.isSearchOverlayVisible ?? false,
                isFilterPanelVisible: timelineViewModel?.isFilterPanelVisible ?? false,
                isDateSearchActive: timelineViewModel?.isDateSearchActive ?? false,
                isCommentSubmenuVisible: timelineViewModel?.showCommentSubmenu ?? false
            ) {
                return false // Let the text field handle Cmd+A
            }

            if let viewModel = timelineViewModel {
                recordShortcut("cmd+a")
                viewModel.selectAllText()
                return true
            }
        }

        // Cmd+C to copy selected text, otherwise copy the active image context.
        if event.charactersIgnoringModifiers == "c" && modifiers == [.command] {
            recordShortcut("cmd+c")
            if let viewModel = timelineViewModel {
                if viewModel.hasSelection {
                    viewModel.copySelectedText()
                } else if viewModel.isZoomRegionActive {
                    viewModel.copyZoomedRegionImage()
                } else {
                    copyCurrentFrameImage()
                }
                return true
            }
        }

        // Cmd+S to save image
        if event.charactersIgnoringModifiers == "s" && modifiers == [.command] {
            recordShortcut("cmd+s")
            saveCurrentFrameImage()
            return true
        }

        // Cmd+Shift+L to open current browser link
        if openLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("cmd+shift+l")
            if timelineViewModel?.openCurrentBrowserURL() == true {
                hide(restorePreviousFocus: false)
                return true
            }
            return false
        }

        // Cmd+L to copy current browser URL
        if copyLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("cmd+l")
            if let viewModel = timelineViewModel, viewModel.copyCurrentBrowserURL() {
                return true
            }
            return true
        }

        // Option+Cmd+L to copy YouTube markdown link
        if copyYouTubeMarkdownLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("opt+cmd+l")
            if let viewModel = timelineViewModel, viewModel.copyCurrentYouTubeMarkdownLink() {
                return true
            }
            return true
        }

        // Option+Shift+L to copy moment link
        if copyMomentLinkShortcutTrigger(for: event, modifiers: modifiers) != nil {
            recordShortcut("opt+shift+l")
            _ = copyMomentLink()
            return true
        }

        // Cmd+; to toggle more options menu
        if event.charactersIgnoringModifiers == ";" && modifiers == [.command] {
            recordShortcut("cmd+;")
            if let viewModel = timelineViewModel {
                viewModel.toggleMoreOptionsMenu()
                return true
            }
            return false
        }

        // Cmd+H to toggle timeline controls visibility
        if event.keyCode == 4 && modifiers == [.command] { // H key with Command
            recordShortcut("cmd+h")
            if let viewModel = timelineViewModel {
                viewModel.toggleControlsVisibility(showRestoreHint: true)
                return true
            }
        }

        // Cmd+P to toggle peek mode (view full context while filtered)
        if event.keyCode == 35 && modifiers == [.command] { // P key with Command
            recordShortcut("cmd+p")
            if let viewModel = timelineViewModel {
                // Only allow peek if we have active filters or are already peeking
                if viewModel.filterCriteria.hasActiveFilters || viewModel.isPeeking {
                    viewModel.togglePeek()
                    return true
                }
            }
        }

        // Cmd+J to go to now (most recent frame)
        if event.keyCode == 38 && modifiers == [.command] { // J key with Command
            recordShortcut("cmd+j")
            if let viewModel = timelineViewModel {
                viewModel.goToNow()
                return true
            }
        }

        // Cmd+Z to undo (go back to last stopped playhead position)
        if event.keyCode == 6 && modifiers == [.command] { // Z key with Command
            if let viewModel = timelineViewModel {
                if viewModel.undoToLastStoppedPosition() {
                    recordShortcut("cmd+z")
                    return true
                }
            }
            // Don't consume the event if there's nothing to undo
            return false
        }

        // Cmd+Shift+Z to redo (go forward to last undone playhead position)
        if event.keyCode == 6 && modifiers == [.command, .shift] { // Z key with Command+Shift
            if let viewModel = timelineViewModel {
                if viewModel.redoLastUndonePosition() {
                    recordShortcut("cmd+shift+z")
                    return true
                }
            }
            // Don't consume the event if there's nothing to redo
            return false
        }

        // Space bar to toggle play/pause (only when video controls are enabled)
        if event.keyCode == 49 && modifiers.isEmpty { // Space
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                viewModel.togglePlayback()
                return true
            }
        }

        // Shift+> to increase playback speed (only when video controls are enabled)
        if event.characters == ">" {
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                let speeds: [Double] = [1, 2, 4, 8]
                if let currentIdx = speeds.firstIndex(of: viewModel.playbackSpeed), currentIdx < speeds.count - 1 {
                    let newSpeed = speeds[currentIdx + 1]
                    viewModel.setPlaybackSpeed(newSpeed)
                    viewModel.showToast("Speed: \(Int(newSpeed))x")
                }
                return true
            }
        }

        // Shift+< to decrease playback speed (only when video controls are enabled)
        if event.characters == "<" {
            if let viewModel = timelineViewModel, viewModel.showVideoControls {
                let speeds: [Double] = [1, 2, 4, 8]
                if let currentIdx = speeds.firstIndex(of: viewModel.playbackSpeed), currentIdx > 0 {
                    let newSpeed = speeds[currentIdx - 1]
                    viewModel.setPlaybackSpeed(newSpeed)
                    viewModel.showToast("Speed: \(Int(newSpeed))x")
                }
                return true
            }
        }

        // Calendar picker keyboard navigation should consume arrow/enter keys
        // while the picker is visible so timeline scrubbing does not trigger.
        if let viewModel = timelineViewModel,
           viewModel.isCalendarPickerVisible,
           modifiers.isEmpty {
            if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 {
                return viewModel.handleCalendarPickerArrowKey(event.keyCode)
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return or Enter
                return viewModel.handleCalendarPickerEnterKey()
            }
        }

        // While the filter panel is open, let the panel own arrow-key navigation.
        // This prevents left/right from scrubbing the timeline behind the panel.
        if let viewModel = timelineViewModel,
           viewModel.isFilterPanelVisible,
           modifiers.isEmpty,
           (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }

        // Left arrow, J, or L - navigate to previous frame (Option = 3x speed)
        // Skip when search UI is open so overlay controls can own arrow keys.
        if let viewModel = timelineViewModel,
           viewModel.isSearchOverlayVisible,
           !viewModel.searchViewModel.searchQuery.isEmpty,
           (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }
        // Skip when a search filter dropdown is open (e.g., DateFilterPopover uses arrow keys for calendar navigation)
        if let viewModel = timelineViewModel, viewModel.searchViewModel.isDropdownOpen, (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126) {
            return false
        }
        if let viewModel = timelineViewModel,
           let direction = Self.searchResultNavigationDirection(
               keyCode: event.keyCode,
               modifiers: modifiers,
               isSearchResultHighlightVisible: viewModel.searchResultHighlightNavigationState != nil
           ) {
            let shortcut: String
            switch direction {
            case .previous:
                shortcut = "cmd+shift+left"
            case .next:
                shortcut = "cmd+shift+right"
            }
            recordShortcut(shortcut)
            Task { @MainActor in
                await viewModel.navigateToAdjacentSearchResult(
                    offset: direction == .previous ? -1 : 1,
                    trigger: .keyboard
                )
            }
            return true
        }
        // Cmd+Left: jump to the start of the previous consecutive timeline block
        if event.keyCode == 123 && modifiers == [.command] {
            if let viewModel = timelineViewModel, viewModel.navigateToPreviousBlockStart() {
                recordShortcut("cmd+left")
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "left")
                }
            }
            return true // Consume even at boundary to avoid system "bonk" sound
        }

        if Self.shouldNavigateTimelineBackward(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex - step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "left")
                }
            }
            return true // Always consume to prevent system "bonk" sound
        }

        // Right arrow, K, or ; - navigate to next frame (Option = 3x speed)
        // Cmd+Right: jump to the start of the next consecutive timeline block
        if event.keyCode == 124 && modifiers == [.command] {
            if let viewModel = timelineViewModel, viewModel.navigateToNextBlockStartOrNewestFrame() {
                recordShortcut("cmd+right")
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "right")
                }
            }
            return true // Consume even at boundary to avoid system "bonk" sound
        }

        if Self.shouldNavigateTimelineForward(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex + step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "right")
                }
            }
            return true // Always consume to prevent system "bonk" sound
        }

        // Ctrl+0 to reset frame zoom to 100%
        if event.keyCode == 29 && modifiers == [.control] { // 0 key with Control
            recordShortcut("ctrl+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd+0 to reset frame zoom to 100% (alternative shortcut)
        if event.keyCode == 29 && modifiers == [.command] { // 0 key with Command
            recordShortcut("cmd+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd++ (Cmd+=) to zoom in frame
        // Key code 24 is '=' which is '+' with shift, but Cmd+= works as zoom in
        if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
            recordShortcut("cmd++")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(1.25, animated: true) // Zoom in by 25%
                return true
            }
        }

        // Cmd+- to zoom out frame
        if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] { // - key (main or numpad)
            recordShortcut("cmd+-")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(0.8, animated: true) // Zoom out by 20%
                return true
            }
        }

        // Any other key (not a modifier) clears text selection
        if let viewModel = timelineViewModel,
           viewModel.hasSelection,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.keyCode != 53 { // Don't clear on Escape (handled above)
            // Only clear for non-navigation keys
            let navigationKeys: Set<UInt16> = [123, 124, 125, 126, 37, 38, 40, 41, 49] // Arrow keys + J, K, L, ; + Space
            if !navigationKeys.contains(event.keyCode) {
                viewModel.clearTextSelection()
            }
        }

        return false
    }

    func handleEscapeKey() -> Bool {
        if let viewModel = timelineViewModel {
            if viewModel.showTagSubmenu {
                withAnimation(.easeOut(duration: 0.12)) {
                    viewModel.dismissTagEditing()
                }
                return true
            }
            if viewModel.showCommentSubmenu && viewModel.isCommentLinkPopoverPresented {
                viewModel.requestCloseCommentLinkPopover()
                return true
            }
            if viewModel.showCommentSubmenu && viewModel.isAllCommentsBrowserActive {
                viewModel.requestReturnToThreadComments()
                return true
            }
            if viewModel.showCommentSubmenu {
                viewModel.dismissCommentSubmenu()
                return true
            }
            if viewModel.showTimelineContextMenu || viewModel.showContextMenu || viewModel.showCommentSubmenu {
                withAnimation(.easeOut(duration: 0.12)) {
                    viewModel.dismissContextMenu()
                    viewModel.dismissTimelineContextMenu()
                }
                return true
            }
            if viewModel.isDraggingZoomRegion {
                viewModel.cancelZoomRegionDrag()
                return true
            }
            if viewModel.isCalendarPickerVisible {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    viewModel.closeCalendarPicker()
                }
                return true
            }
            if viewModel.isZoomSliderExpanded {
                withAnimation(.easeOut(duration: 0.12)) {
                    viewModel.setZoomSliderExpanded(false)
                }
                return true
            }
            if viewModel.isDateSearchActive {
                viewModel.closeDateSearch()
                return true
            }
            if viewModel.isSearchOverlayVisible && viewModel.searchViewModel.isRecentEntriesPopoverVisible {
                viewModel.searchViewModel.requestDismissRecentEntriesPopoverByUser()
                return true
            }
            if viewModel.isSearchOverlayVisible && viewModel.searchViewModel.isDropdownOpen {
                if viewModel.searchViewModel.isDatePopoverHandlingKeys {
                    return false
                }
                viewModel.searchViewModel.closeDropdownsSignal += 1
                return true
            }
            if viewModel.isSearchOverlayVisible {
                let searchViewModel = viewModel.searchViewModel
                if searchViewModel.isSearchOverlayExpanded &&
                    !searchViewModel.shouldDismissExpandedOverlayOnEscape {
                    searchViewModel.clearAllFilters()
                    searchViewModel.resetSearchOrderToDefault()
                    searchViewModel.requestOverlayCollapse()
                    return true
                }
                if searchViewModel.shouldRefocusSearchFieldOnEscape {
                    searchViewModel.requestSearchFieldFocus(selectAll: true)
                    return true
                }

                searchViewModel.requestOverlayDismiss(clearSearchState: true)
                return true
            }
            if viewModel.isInFrameSearchVisible ||
                !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.closeInFrameSearch(clearQuery: true)
                return true
            }
            if viewModel.isShowingSearchHighlight {
                viewModel.clearSearchHighlight()
                if viewModel.searchViewModel.results != nil && !viewModel.searchViewModel.searchQuery.isEmpty {
                    viewModel.openSearchOverlay()
                }
                return true
            }
            if viewModel.showDeleteConfirmation {
                viewModel.cancelDelete()
                return true
            }
            if viewModel.isZoomRegionActive {
                viewModel.exitZoomRegion()
                return true
            }
            if viewModel.hasSelection {
                viewModel.clearTextSelection()
                return true
            }
            if viewModel.isPeeking {
                viewModel.exitPeek()
                return true
            }
            if viewModel.isFilterPanelVisible && viewModel.isFilterDropdownOpen {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.dismissFilterDropdown()
                }
                return true
            }
            if viewModel.isFilterPanelVisible {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.dismissFilterPanel()
                }
                return true
            }
            if viewModel.filterCriteria.hasActiveFilters {
                viewModel.clearAllFilters()
                return true
            }
        }

        hide()
        return true
    }

}
