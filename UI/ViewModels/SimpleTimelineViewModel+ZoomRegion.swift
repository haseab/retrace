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
    public func resetFrameZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            frameZoomScale = 1.0
            frameZoomOffset = .zero
        }
    }

    public func applyMagnification(
        _ magnification: CGFloat,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
        frameSize: CGSize? = nil,
        animated: Bool = false
    ) {
        let newScale = (frameZoomScale * magnification).clamped(to: Self.minFrameZoomScale...Self.maxFrameZoomScale)

        let newOffset: CGSize
        if newScale != frameZoomScale, let size = frameSize {
            let anchorOffsetX = (anchor.x - 0.5) * size.width
            let anchorOffsetY = (anchor.y - 0.5) * size.height
            let scaleDelta = newScale / frameZoomScale
            newOffset = CGSize(
                width: frameZoomOffset.width * scaleDelta + anchorOffsetX * (1 - scaleDelta),
                height: frameZoomOffset.height * scaleDelta + anchorOffsetY * (1 - scaleDelta)
            )
        } else if newScale != frameZoomScale {
            let scaleDelta = newScale / frameZoomScale
            newOffset = CGSize(
                width: frameZoomOffset.width * scaleDelta,
                height: frameZoomOffset.height * scaleDelta
            )
        } else {
            newOffset = frameZoomOffset
        }

        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                frameZoomScale = newScale
                frameZoomOffset = newOffset
            }
        } else {
            frameZoomScale = newScale
            frameZoomOffset = newOffset
        }
    }

    public func updateFrameZoomOffset(by delta: CGSize) {
        frameZoomOffset = CGSize(
            width: frameZoomOffset.width + delta.width,
            height: frameZoomOffset.height + delta.height
        )
    }

    // MARK: - Zoom Region Methods (Shift+Drag)

    private func startZoomEntryTransition(for sessionID: Int) {
        guard sessionID == activeShiftDragSessionID else { return }

        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil

        isZoomTransitioning = true
        zoomTransitionProgress = 0
        zoomTransitionBlurOpacity = 0

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            zoomTransitionProgress = 1.0
            zoomTransitionBlurOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            guard sessionID == self.activeShiftDragSessionID else { return }
            self.isZoomRegionActive = true
            self.zoomTransitionStartRect = nil
            DispatchQueue.main.async {
                guard sessionID == self.activeShiftDragSessionID else { return }
                self.isZoomTransitioning = false
            }
        }
    }

    public func startZoomRegion(at point: CGPoint) {
        triggerDragStartStillFrameOCRIfNeeded(gesture: "shift-drag")
        zoomUpdateCount = 0
        isDraggingZoomRegion = true
        zoomRegionDragStart = point
        zoomRegionDragEnd = point
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil

        shiftDragSessionCounter += 1
        activeShiftDragSessionID = shiftDragSessionCounter
        shiftDragStartFrameID = currentFrame?.id.value
        shiftDragStartVideoInfo = currentVideoInfo
        clearTextSelection()
    }

    public func updateZoomRegion(to point: CGPoint) {
        zoomUpdateCount += 1
        zoomRegionDragEnd = point
    }

    public func endZoomRegion() {
        guard let start = zoomRegionDragStart, let end = zoomRegionDragEnd else {
            isDraggingZoomRegion = false
            return
        }

        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)

        let width = maxX - minX
        let height = maxY - minY

        let sessionID = activeShiftDragSessionID
        let startFrameIDValue = shiftDragStartFrameID
        let startVideoInfoValue = shiftDragStartVideoInfo
        let endFrameIDValue = currentFrame?.id.value
        let endVideoInfoValue = currentVideoInfo

        guard width > 0.01 && height > 0.01 else {
            isDraggingZoomRegion = false
            zoomRegionDragStart = nil
            zoomRegionDragEnd = nil
            shiftDragStartFrameID = nil
            shiftDragStartVideoInfo = nil
            return
        }

        let finalRect = CGRect(x: minX, y: minY, width: width, height: height)

        if let screenSize = NSScreen.main?.frame.size {
            let absoluteRect = CGRect(
                x: finalRect.origin.x * screenSize.width,
                y: finalRect.origin.y * screenSize.height,
                width: finalRect.width * screenSize.width,
                height: finalRect.height * screenSize.height
            )
            DashboardViewModel.recordShiftDragZoom(coordinator: coordinator, region: absoluteRect, screenSize: screenSize)
        }

        zoomTransitionStartRect = finalRect
        zoomRegion = finalRect

        let probeVideoInfo = endVideoInfoValue ?? startVideoInfoValue
        let probeFrameID = endFrameIDValue ?? startFrameIDValue
        loadShiftDragDisplaySnapshot(
            frameID: probeFrameID,
            videoInfo: probeVideoInfo
        ) { [weak self] in
            self?.startZoomEntryTransition(for: sessionID)
        }
        shiftDragStartFrameID = nil
        shiftDragStartVideoInfo = nil
    }

    private func loadShiftDragDisplaySnapshot(
        frameID: Int64?,
        videoInfo: FrameVideoInfo?,
        completion: (() -> Void)? = nil
    ) {
        shiftDragDisplayRequestID += 1
        let requestID = shiftDragDisplayRequestID
        cancelShiftDragDisplayDecode(reason: "ui.timeline.shift_drag_decode")

        if isInLiveMode {
            shiftDragDisplaySnapshot = liveScreenshot
            shiftDragDisplaySnapshotFrameID = frameID
            completion?()
            return
        }

        guard let videoInfo else {
            completion?()
            return
        }

        guard let url = resolveVideoURLForShiftDragProbe(videoInfo: videoInfo) else {
            completion?()
            return
        }

        let requestedTime = videoInfo.frameTimeCMTime
        let directDecodeBytes = UIDirectFrameDecodeMemoryLedger.begin(
            tag: UIDirectFrameDecodeMemoryLedger.shiftDragGeneratorTag,
            function: "ui.timeline.direct_decode",
            reason: "ui.timeline.shift_drag_decode",
            videoInfo: videoInfo
        )

        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        let generatorID = ObjectIdentifier(imageGenerator)
        shiftDragDisplayGenerator = imageGenerator
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                UIDirectFrameDecodeMemoryLedger.end(
                    tag: UIDirectFrameDecodeMemoryLedger.shiftDragGeneratorTag,
                    reason: "ui.timeline.shift_drag_decode",
                    bytes: directDecodeBytes
                )
                self.clearShiftDragDisplayGeneratorIfMatching(generatorID)
                guard requestID == self.shiftDragDisplayRequestID else {
                    return
                }

                if let cgImage = cgImage {
                    self.shiftDragDisplaySnapshot = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.shiftDragDisplaySnapshotFrameID = frameID
                } else {
                    self.shiftDragDisplaySnapshot = nil
                    self.shiftDragDisplaySnapshotFrameID = nil
                }
                completion?()
            }
        }
    }

    private func resolveVideoURLForShiftDragProbe(videoInfo: FrameVideoInfo) -> URL? {
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                return nil
            }
        }

        return MP4SymlinkResolver.resolveURL(for: actualVideoPath)
    }

    public func exitZoomRegion() {
        guard !isZoomExitTransitioning, zoomRegion != nil else {
            clearZoomRegionState()
            return
        }

        clearTextSelection()
        isZoomExitTransitioning = true
        isZoomRegionActive = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.clearZoomRegionState()
        }
    }

    private func clearZoomRegionState() {
        cancelShiftDragDisplayDecode(reason: "ui.timeline.shift_drag_cleanup")
        isZoomRegionActive = false
        isZoomExitTransitioning = false
        isZoomTransitioning = false
        zoomRegion = nil
        zoomTransitionStartRect = nil
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil
        clearTextSelection()
    }

    public func cancelZoomRegionDrag() {
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil
    }
}
