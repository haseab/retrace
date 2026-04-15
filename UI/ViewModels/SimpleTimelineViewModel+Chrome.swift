import AppKit
import Foundation
import SwiftUI

extension SimpleTimelineViewModel {
    // MARK: - Chrome Controls

    /// Toggle the top-right "more options" menu visibility
    public func toggleMoreOptionsMenu() {
        isMoreOptionsMenuVisible.toggle()
    }

    /// Set the top-right "more options" menu visibility directly.
    public func setMoreOptionsMenuVisible(_ isVisible: Bool) {
        isMoreOptionsMenuVisible = isVisible
    }

    /// Dismiss the top-right "more options" menu if visible
    public func dismissMoreOptionsMenu() {
        isMoreOptionsMenuVisible = false
    }

    public func setZoomSliderExpanded(_ isExpanded: Bool) {
        isZoomSliderExpanded = isExpanded
    }

    public func toggleZoomSliderExpanded() {
        isZoomSliderExpanded.toggle()
    }

    public func setTapeHidden(_ isHidden: Bool) {
        isTapeHidden = isHidden
    }

    public func setLivePresentationState(isActive: Bool, screenshot: NSImage?) {
        mediaPresentationState.isInLiveMode = isActive
        mediaPresentationState.liveScreenshot = screenshot
    }

    public func setFramePresentationState(isNotReady: Bool, hasLoadError: Bool) {
        mediaPresentationState.frameNotReady = isNotReady
        mediaPresentationState.frameLoadError = hasLoadError
    }

    public func toggleVideoBoundariesVisibility() {
        showVideoBoundaries.toggle()
    }

    public func toggleSegmentBoundariesVisibility() {
        showSegmentBoundaries.toggle()
    }

    public func setBrowserURLDebugWindowVisible(_ isVisible: Bool) {
        showBrowserURLDebugWindow = isVisible
    }

    public func toggleBrowserURLDebugWindowVisibility() {
        showBrowserURLDebugWindow.toggle()
    }

    /// Toggle visibility of timeline controls (tape, playhead, buttons)
    public func toggleControlsVisibility(showRestoreHint: Bool = false) {
        let willHideControls = !areControlsHidden
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            areControlsHidden = willHideControls
            // Dismiss filter panel when hiding controls
            if willHideControls && isFilterPanelVisible {
                dismissFilterPanel()
            }
        }

        if willHideControls {
            if showRestoreHint {
                armControlsHiddenRestoreGuidance()
            } else {
                clearControlsHiddenRestoreGuidance()
            }
        } else {
            clearControlsHiddenRestoreGuidance()
        }
    }

    // MARK: - Toast Feedback

    /// Show a brief toast notification overlay
    public func showToast(_ message: String, icon: String? = nil) {
        toastDismissTask?.cancel()
        let tone = classifyToastTone(message: message, icon: icon)
        let resolvedIcon = icon ?? (tone == .error ? "xmark.circle.fill" : "checkmark.circle.fill")

        // Set content first, then animate in
        toastMessage = message
        toastIcon = resolvedIcon
        toastTone = tone
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            toastVisible = true
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(1_500_000_000)), clock: .continuous) // 1.5s (longer for error messages)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.3)) {
                    self.toastVisible = false
                }
                // Clear content after fade-out completes
                try? await Task.sleep(for: .nanoseconds(Int64(350_000_000)), clock: .continuous)
                if !Task.isCancelled {
                    self.toastMessage = nil
                    self.toastIcon = nil
                    self.toastTone = .success
                }
            }
        }
    }

    private func classifyToastTone(message: String, icon: String?) -> TimelineToastTone {
        if let icon {
            if icon.contains("xmark") || icon.contains("exclamationmark") {
                return .error
            }
            if icon.contains("checkmark") {
                return .success
            }
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let errorKeywords = [
            "cannot",
            "can't",
            "failed",
            "error",
            "unable",
            "invalid",
            "denied",
            "missing",
            "not found"
        ]

        if errorKeywords.contains(where: { normalizedMessage.contains($0) }) {
            return .error
        }

        return .success
    }

    // MARK: - Presentation Errors + Loading

    func setMediaLoadingVisible(_ isVisible: Bool) {
        mediaPresentationState.isLoading = isVisible
    }

    func setPresentationError(_ message: String?) {
        mediaPresentationState.error = message
    }

    /// Clear error message and cancel any auto-dismiss task
    func clearError() {
        errorDismissTask?.cancel()
        setPresentationError(nil)
    }

    /// Show an error message that auto-dismisses after a delay
    /// - Parameters:
    ///   - message: The error message to display
    ///   - seconds: Time in seconds before auto-dismissing (default: 5)
    func showErrorWithAutoDismiss(_ message: String, seconds: UInt64 = 5) {
        setPresentationError(message)

        // Cancel any existing dismiss task
        errorDismissTask?.cancel()

        // Auto-dismiss after specified seconds
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(seconds)), clock: .continuous)
            if !Task.isCancelled {
                setPresentationError(nil)
            }
        }
    }

    func formatLocalDateForError(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy h:mm:ss a z"
        return formatter.string(from: date)
    }
}
