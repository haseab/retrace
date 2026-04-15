import AppKit
import Foundation
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    static func frameIDsMatch(_ lhs: [TimelineFrame], _ rhs: [TimelineFrame]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where lhs[index].frame.id != rhs[index].frame.id {
            return false
        }
        return true
    }

    static func isPureAppend(oldFrames: [TimelineFrame], newFrames: [TimelineFrame]) -> Bool {
        guard !oldFrames.isEmpty, newFrames.count > oldFrames.count else { return false }
        let leadingWindow = Array(newFrames.prefix(oldFrames.count))
        return frameIDsMatch(oldFrames, leadingWindow)
    }

    static func isPurePrepend(oldFrames: [TimelineFrame], newFrames: [TimelineFrame]) -> Bool {
        guard !oldFrames.isEmpty, newFrames.count > oldFrames.count else { return false }
        let trailingWindow = Array(newFrames.suffix(oldFrames.count))
        return frameIDsMatch(oldFrames, trailingWindow)
    }

    // MARK: - Zoom Computed Properties

    /// Current pixels per frame based on zoom level
    public var pixelsPerFrame: CGFloat {
        let clampedZoomLevel = zoomLevel.clamped(to: 0...TimelineConfig.maxZoomLevel)
        let legacyRange = TimelineConfig.basePixelsPerFrame - TimelineConfig.minPixelsPerFrame

        if clampedZoomLevel <= 1.0 {
            return TimelineConfig.minPixelsPerFrame + (legacyRange * clampedZoomLevel)
        }

        let extendedRange = TimelineConfig.maxPixelsPerFrame - TimelineConfig.basePixelsPerFrame
        let extendedProgress = (clampedZoomLevel - 1.0) / (TimelineConfig.maxZoomLevel - 1.0)
        return TimelineConfig.basePixelsPerFrame + (extendedRange * extendedProgress)
    }

    /// Frame skip factor - how many frames to skip when displaying
    /// At 50%+ zoom, show all frames (skip = 1)
    /// Below 50%, progressively skip more frames
    public var frameSkipFactor: Int {
        if zoomLevel >= 0.5 {
            return 1
        }

        let skipRange = zoomLevel / 0.5
        let maxSkip = 5
        let skip = Int(round(CGFloat(maxSkip) - (skipRange * CGFloat(maxSkip - 1))))
        return max(1, skip)
    }

    /// Visible frames accounting for skip factor
    public var visibleFrameIndices: [Int] {
        let skip = frameSkipFactor
        if skip == 1 {
            return Array(0..<frames.count)
        }
        return stride(from: 0, to: frames.count, by: skip).map { $0 }
    }

    // MARK: - Derived Properties

    public var currentTimelineFrame: TimelineFrame? {
        guard currentIndex >= 0 && currentIndex < frames.count else { return nil }
        return frames[currentIndex]
    }

    public var currentFrame: FrameReference? {
        currentTimelineFrame?.frame
    }

    public var selectedCommentTargetTimelineFrame: TimelineFrame? {
        guard let index = selectedCommentTargetIndex else {
            return nil
        }
        return frames[index]
    }

    public var selectedCommentComposerTarget: CommentComposerTargetDisplayInfo? {
        guard let index = selectedCommentTargetIndex,
              index >= 0,
              index < frames.count else { return nil }

        let timelineFrame = frames[index]
        let block = getBlock(forFrameAt: index)

        return Self.makeCommentComposerTargetDisplayInfo(
            timelineFrame: timelineFrame,
            block: block,
            availableTagsByID: availableTagsByID,
            selectedSegmentTagIDs: Set(selectedSegmentTags.map { $0.value })
        )
    }

    public var showFrameIDs: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showFrameIDs")
    }

    public var showOCRDebugOverlay: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showOCRDebugOverlay")
    }

    var displayableCurrentImage: NSImage? {
        switch currentFrameStillDisplayMode {
        case .currentImage:
            return currentImage
        case .waitingFallback, .none:
            return nil
        }
    }

    var waitingVideoFallbackImage: NSImage? {
        guard currentFrameStillDisplayMode == .waitingFallback else { return nil }
        return waitingFallbackImage
    }

    var currentFrameMediaDisplayMode: CurrentFrameMediaDisplayMode {
        Self.resolveCurrentFrameMediaDisplayMode(
            currentFrameID: currentTimelineFrame?.frame.id,
            currentImageFrameID: currentImageFrameID,
            hasCurrentImage: currentImage != nil,
            hasVideo: currentTimelineFrame?.videoInfo != nil
        )
    }

    static func resolveCurrentFrameMediaDisplayMode(
        currentFrameID: FrameID?,
        currentImageFrameID: FrameID?,
        hasCurrentImage: Bool,
        hasVideo: Bool
    ) -> CurrentFrameMediaDisplayMode {
        guard let currentFrameID else { return .noContent }

        if hasCurrentImage && currentImageFrameID == currentFrameID {
            return .still
        }

        return hasVideo ? .decodedVideo : .noContent
    }

    var currentFrameStillDisplayMode: CurrentFrameStillDisplayMode {
        Self.resolveCurrentFrameStillDisplayMode(
            currentFrameID: currentTimelineFrame?.frame.id,
            currentImageFrameID: currentImageFrameID,
            hasCurrentImage: currentImage != nil,
            hasVideo: currentTimelineFrame?.videoInfo != nil,
            hasWaitingFallbackImage: waitingFallbackImage != nil,
            pendingVideoPresentationFrameID: pendingVideoPresentationFrameID,
            isPendingVideoPresentationReady: isPendingVideoPresentationReady
        )
    }

    var currentFrameStillUsesFreshCaptureSource: Bool {
        switch currentFrameStillDisplayMode {
        case .currentImage:
            guard let currentFrameID = currentTimelineFrame?.frame.id,
                  currentImage != nil,
                  currentImageFrameID == currentFrameID else {
                return false
            }
            return hasExternalCaptureStillInDiskFrameBuffer(frameID: currentFrameID)
        case .waitingFallback:
            guard let fallbackFrameID = waitingFallbackImageFrameID,
                  waitingFallbackImage != nil else {
                return false
            }
            return hasExternalCaptureStillInDiskFrameBuffer(frameID: fallbackFrameID)
        case .none:
            return false
        }
    }

    static func resolveCurrentFrameStillDisplayMode(
        currentFrameID: FrameID?,
        currentImageFrameID: FrameID?,
        hasCurrentImage: Bool,
        hasVideo: Bool,
        hasWaitingFallbackImage: Bool,
        pendingVideoPresentationFrameID: FrameID?,
        isPendingVideoPresentationReady: Bool
    ) -> CurrentFrameStillDisplayMode {
        guard let currentFrameID else { return .none }

        if hasCurrentImage && currentImageFrameID == currentFrameID {
            return .currentImage
        }

        if hasVideo,
           hasWaitingFallbackImage,
           pendingVideoPresentationFrameID == currentFrameID,
           !isPendingVideoPresentationReady {
            return .waitingFallback
        }

        return .none
    }

    public var currentVideoInfo: FrameVideoInfo? {
        guard let timelineFrame = currentTimelineFrame,
              let info = timelineFrame.videoInfo,
              info.frameIndex >= 0 else {
            return nil
        }
        return info
    }

    public var currentTimestamp: Date? {
        currentTimelineFrame?.frame.timestamp
    }
}
