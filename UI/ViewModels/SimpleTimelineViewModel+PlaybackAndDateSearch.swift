import App
import AppKit
import Foundation
import Shared
import SwiftyChrono
import SwiftUI

extension SimpleTimelineViewModel {
    // MARK: - Video Playback State

    /// Whether video controls are enabled (read from UserDefaults)
    public var showVideoControls: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showVideoControls")
    }

    /// Start auto-advancing frames at the current playback speed
    public func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        schedulePlaybackTimer()
    }

    /// Stop auto-advancing frames
    public func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Toggle between play and pause
    public func togglePlayback() {
        let wasPlaying = isPlaying
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
        DashboardViewModel.recordPlaybackToggled(
            coordinator: coordinator,
            source: "timeline",
            wasPlaying: wasPlaying,
            isPlaying: isPlaying,
            speed: playbackSpeed
        )
    }

    /// Update the playback speed and reschedule the timer if playing
    public func setPlaybackSpeed(_ speed: Double) {
        let previousSpeed = playbackSpeed
        guard previousSpeed != speed else { return }

        playbackSpeed = speed
        if isPlaying {
            // Reschedule timer with new interval
            playbackTimer?.invalidate()
            schedulePlaybackTimer()
        }

        DashboardViewModel.recordPlaybackSpeedChanged(
            coordinator: coordinator,
            source: "timeline",
            previousSpeed: previousSpeed,
            newSpeed: speed,
            isPlaying: isPlaying
        )
    }

    /// Schedule the playback timer at the current speed
    private func schedulePlaybackTimer() {
        let interval = 1.0 / playbackSpeed
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let nextIndex = self.currentIndex + 1
                if nextIndex < self.frames.count {
                    self.navigateToFrame(nextIndex)
                } else {
                    // Reached the end - stop playback
                    self.stopPlayback()
                }
            }
        }
    }

    /// Copy the current frame ID to clipboard
    public func copyCurrentFrameID() {
        guard let frame = currentFrame else { return }
        let frameIDString = String(frame.id.value)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(frameIDString, forType: .string)
    }

    public func toggleFrameIDBadgeVisibilityFromDevMenu() {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let isEnabled = !defaults.bool(forKey: "showFrameIDs")
        defaults.set(isEnabled, forKey: "showFrameIDs")
        DashboardViewModel.recordDeveloperSettingToggle(
            coordinator: coordinator,
            source: "timeline_dev_menu",
            settingKey: "showFrameIDs",
            isEnabled: isEnabled
        )
    }

    /// Reprocess OCR for the current frame (developer tool)
    /// Clears existing OCR data and re-enqueues the frame for processing
    public func reprocessCurrentFrameOCR() async throws {
        guard let frame = currentFrame else { return }
        // Only allow reprocessing for Retrace frames (not imported Rewind videos)
        guard frame.source == .native else {
            Log.warning("[OCR] Cannot reprocess OCR for Rewind frames", category: .ui)
            return
        }
        try await coordinator.reprocessOCR(frameID: frame.id)
    }

    // MARK: - Tape Scroll

    /// Handle scroll delta to navigate frames
    /// - Parameters:
    ///   - delta: The scroll delta value
    ///   - isTrackpad: Whether the scroll came from a trackpad (precise scrolling) vs mouse wheel
    public func handleScroll(delta: CGFloat, isTrackpad: Bool = true) async {
        // Stop playback on manual scroll
        if isPlaying {
            stopPlayback()
        }

        markVisibleSessionScrubStarted(source: isTrackpad ? "trackpad-scroll" : "mouse-wheel")

        // Exit live mode on first scroll
        if isInLiveMode {
            exitLiveMode()
            return // First scroll exits live mode, don't navigate yet
        }

        guard !frames.isEmpty else { return }

        // Read user sensitivity setting (0.1–1.0, default 0.50)
        let store = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let userSensitivity = store.object(forKey: "scrollSensitivity") != nil ? store.double(forKey: "scrollSensitivity") : 0.50
        let sensitivityMultiplier = CGFloat(userSensitivity / 0.50) // Normalize so 0.50 = current behavior

        // Mark as actively scrolling
        if !isActivelyScrolling {
            isActivelyScrolling = true
            dismissContextMenu()
            dismissTimelineContextMenu(reason: .scroll)
        }

        // Cancel previous debounce task
        scrollDebounceTask?.cancel()

        if isTrackpad {
            // Continuous scrolling: convert delta to pixel displacement
            // Scale so trackpad movement maps ~1:1 to tape pixel movement
            let pixelDelta = delta * sensitivityMultiplier
            subFrameOffset += pixelDelta

            // Check if we've crossed frame boundaries
            let ppf = pixelsPerFrame
            if abs(subFrameOffset) >= ppf / 2 {
                let framesToCross = Int(round(subFrameOffset / ppf))
                if framesToCross != 0 {
                    let prevIndex = currentIndex
                    let targetIndex = currentIndex + framesToCross
                    let clampedTarget = max(0, min(frames.count - 1, targetIndex))
                    let actualFramesMoved = clampedTarget - prevIndex

                    if actualFramesMoved != 0 {
                        // Only subtract the frames we actually moved
                        subFrameOffset -= CGFloat(actualFramesMoved) * ppf
                        navigateToFrame(clampedTarget, fromScroll: true)
                    }

                    // At boundary: clamp offset so it doesn't accumulate past the edge
                    if clampedTarget != targetIndex {
                        subFrameOffset = 0
                    }
                }
            }

            // Safety clamp: prevent any residual offset past boundaries
            if currentIndex == 0 && subFrameOffset < 0 {
                subFrameOffset = 0
            } else if currentIndex >= frames.count - 1 && subFrameOffset > 0 {
                subFrameOffset = 0
            }
        } else {
            // Mouse wheel: discrete frame steps (no sub-frame movement)
            let baseSensitivity: CGFloat = 0.5 * sensitivityMultiplier
            let referencePixelsPerFrame: CGFloat = TimelineConfig.basePixelsPerFrame * TimelineConfig.defaultZoomLevel + TimelineConfig.minPixelsPerFrame * (1 - TimelineConfig.defaultZoomLevel)
            let zoomAdjustedSensitivity = baseSensitivity * (referencePixelsPerFrame / pixelsPerFrame)

            // Accumulate in subFrameOffset temporarily for mouse wheel
            let mouseAccum = delta * zoomAdjustedSensitivity
            var frameStep = Int(mouseAccum)
            if frameStep == 0 && abs(delta) > 0.001 {
                frameStep = delta > 0 ? 1 : -1
            }
            if frameStep != 0 {
                subFrameOffset = 0
                navigateToFrame(currentIndex + frameStep, fromScroll: true)
            }
        }

        // Clear transient search-result highlight when user manually scrolls.
        if isShowingSearchHighlight && !hasActiveInFrameSearchQuery {
            clearSearchHighlight()
        }

        // Debounce: settle tape to frame center and load OCR/URL after 200ms of no scroll
        scrollDebounceTask = Task {
            try? await Task.sleep(for: .nanoseconds(Int64(200_000_000)), clock: .continuous)
            if !Task.isCancelled {
                await MainActor.run {
                    self.isActivelyScrolling = false
                    self.schedulePresentationOverlayRefresh()
                }
            }
        }
    }

    /// Cancel any in-progress tape drag momentum (e.g., user clicked again to stop)
    public func cancelTapeDragMomentum() {
        tapeDragMomentumTask?.cancel()
        tapeDragMomentumTask = nil
    }

    /// End a tape click-drag scrub session, optionally with momentum
    /// - Parameter velocity: Release velocity in pixels/second (in scroll convention, negated from screen delta)
    public func endTapeDrag(withVelocity velocity: CGFloat = 0) {
        // Cancel any existing momentum
        tapeDragMomentumTask?.cancel()

        let minVelocity: CGFloat = 50 // px/s threshold to trigger momentum
        if abs(velocity) > minVelocity {
            // Start momentum animation
            tapeDragMomentumTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                let friction: CGFloat = 0.95 // Per-tick decay factor
                let tickInterval: UInt64 = 16_000_000 // ~60fps (16ms)
                var currentVelocity = velocity
                let stopThreshold: CGFloat = 20 // px/s to stop

                while abs(currentVelocity) > stopThreshold && !Task.isCancelled {
                    // Convert velocity (px/s) to per-tick delta (px)
                    let dt: CGFloat = 0.016 // 16ms
                    let delta = currentVelocity * dt

                    await self.handleScroll(delta: delta, isTrackpad: true)

                    // Apply friction
                    currentVelocity *= friction

                    try? await Task.sleep(for: .nanoseconds(Int64(tickInterval)), clock: .continuous)
                }

                if !Task.isCancelled {
                    self.isActivelyScrolling = false
                    self.schedulePresentationOverlayRefresh()
                }
            }
        } else {
            // No meaningful velocity — just re-enable deferred operations
            isActivelyScrolling = false
            schedulePresentationOverlayRefresh()
        }
    }

    // MARK: - Computed Properties

    /// Get the playhead position as a percentage (0.0 to 1.0)
    public var playheadPosition: CGFloat {
        guard frames.count > 1 else { return 0.5 }
        return CGFloat(currentIndex) / CGFloat(frames.count - 1)
    }

    /// Get formatted time string for current frame - derived from currentTimestamp
    public var currentTimeString: String {
        guard let timestamp = currentTimestamp else { return "--:--:--" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Get formatted date string for current frame - derived from currentTimestamp
    public var currentDateString: String {
        guard let timestamp = currentTimestamp else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Total number of frames (for tape view)
    public var frameCount: Int {
        frames.count
    }

    /// Whether the timeline is currently showing the most recent frame
    /// Returns true only when at the last frame and no newer frames exist
    public var isAtMostRecentFrame: Bool {
        return isNearMostRecentFrame(within: 1)
    }

    /// Whether the playhead is centered on a hard timeline edge with no more frames beyond it.
    /// This is narrower than `isAtMostRecentFrame`: it only becomes true once scrolling has
    /// fully settled on the absolute start/end, with no residual sub-frame offset.
    var isSettledAtAbsoluteTimelineBoundary: Bool {
        guard !frames.isEmpty else { return false }
        guard abs(subFrameOffset) < 0.001 else { return false }

        let atAbsoluteStart = currentIndex <= 0 && !frameWindowStore.hasMoreOlder
        let atAbsoluteEnd = currentIndex >= frames.count - 1 && !frameWindowStore.hasMoreNewer
        return atAbsoluteStart || atAbsoluteEnd
    }

    /// Whether the timeline is within N frames of the most recent
    /// - Parameter within: Number of frames from the end to consider "near" (1 = last frame only, 2 = last 2 frames, etc.)
    public func isNearMostRecentFrame(within count: Int) -> Bool {
        guard !frames.isEmpty else { return true }
        return currentIndex >= frames.count - count && !frameWindowStore.hasMoreNewer
    }

    nonisolated static func isNewestLoadedTimestampRecent(
        _ newestLoadedTimestamp: Date?,
        now: Date,
        threshold: TimeInterval = 5 * 60
    ) -> Bool {
        guard let newestLoadedTimestamp else { return true }
        return abs(now.timeIntervalSince(newestLoadedTimestamp)) <= threshold
    }

    func isNewestLoadedFrameRecent(now: Date = Date()) -> Bool {
        Self.isNewestLoadedTimestampRecent(frames.last?.frame.timestamp, now: now)
    }

    /// Whether the timeline is within N frames of the latest loaded frame.
    /// Unlike `isNearMostRecentFrame`, this intentionally ignores `hasMoreNewer`.
    /// Useful for UI decisions where stale boundary flags should not block "near-now" behavior.
    public func isNearLatestLoadedFrame(within count: Int) -> Bool {
        guard !frames.isEmpty else { return true }
        return currentIndex >= frames.count - count
    }

    /// Whether to show the "Go to Now" button
    /// Shows when not viewing the most recent available frame
    public var shouldShowGoToNow: Bool {
        guard !frames.isEmpty else { return false }
        // Show if not at the end of loaded frames, or if there are newer frames to load
        return currentIndex < frames.count - 1 || frameWindowStore.hasMoreNewer
    }

    /// Navigate to the most recent frame — jumps to end of tape if already loaded, otherwise reloads from DB
    public func goToNow() {
        // Cmd+J should snap to an exact frame center, not preserve partial scrub offset.
        cancelTapeDragMomentum()
        scrollDebounceTask?.cancel()
        scrollDebounceTask = nil
        isActivelyScrolling = false
        subFrameOffset = 0
        frameWindowStore.cancelBoundaryLoadTasks(reason: "goToNow")

        // Clear filters without triggering reload (we'll handle that ourselves)
        if activeFilterCount > 0 {
            clearFilterState()
        }

        // Always reload from DB to get the true most recent frame (unfiltered)
        Task {
            await loadMostRecentFrame()
            await refreshProcessingStatuses()
        }
    }

}
