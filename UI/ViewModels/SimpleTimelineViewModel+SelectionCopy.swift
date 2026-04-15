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
    public var selectedText: String {
        guard hasSelection else { return "" }

        var result = ""
        let nodesToCheck = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes

        let sortedNodes = nodesToCheck.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        for node in sortedNodes {
            if let range = getSelectionRange(for: node.id) {
                let text = node.text
                let startIdx = text.index(text.startIndex, offsetBy: min(range.start, text.count))
                let endIdx = text.index(text.startIndex, offsetBy: min(range.end, text.count))
                if startIdx < endIdx {
                    result += String(text[startIdx..<endIdx])
                    result += " "
                }
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    public func copySelectedText() {
        let text = selectedText
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Text copied", icon: "doc.on.doc.fill")

        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: text)

        if hasSelection {
            DashboardViewModel.recordShiftDragTextCopy(coordinator: coordinator, copiedText: text)
        }
    }

    public func copyZoomedRegionText() {
        guard let _ = zoomRegion, isZoomRegionActive else {
            showToast("Text unavailable", icon: "exclamationmark.circle.fill")
            return
        }

        let text = visibleZoomRegionText()
        guard !text.isEmpty else {
            showToast("Text unavailable", icon: "exclamationmark.circle.fill")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Text copied", icon: "doc.on.doc.fill")
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: text)
    }

    public func copyCurrentFrameImageToClipboard() {
        getCurrentFrameImage { image in
            guard let image = image else {
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let didWrite = pasteboard.writeObjects([image])

            guard didWrite else {
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            self.showToast("Image copied")
            DashboardViewModel.recordImageCopy(coordinator: self.coordinator, frameID: self.currentFrame?.id.value)
        }
    }

    public func copyZoomedRegionImage() {
        guard let region = zoomRegion, isZoomRegionActive else {
            Log.warning("[ZoomCopy] Ignored copy: no active zoom region", category: .ui)
            return
        }

        getCurrentFrameImage { image in
            guard let image = image else {
                Log.warning("[ZoomCopy] Failed: current frame image unavailable", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                Log.warning("[ZoomCopy] Failed: could not get CGImage from frame image", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            let pixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            let rawCropRect = CGRect(
                x: region.origin.x * CGFloat(cgImage.width),
                y: region.origin.y * CGFloat(cgImage.height),
                width: region.width * CGFloat(cgImage.width),
                height: region.height * CGFloat(cgImage.height)
            )
            let cropRect = rawCropRect.intersection(pixelBounds).integral

            guard !cropRect.isEmpty, let croppedCGImage = cgImage.cropping(to: cropRect) else {
                Log.warning("[ZoomCopy] Failed: crop rect invalid raw=\(rawCropRect), clipped=\(cropRect), image=\(cgImage.width)x\(cgImage.height)", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            let croppedImage = NSImage(
                cgImage: croppedCGImage,
                size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height)
            )

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let didWrite = pasteboard.writeObjects([croppedImage])

            guard didWrite else {
                Log.warning("[ZoomCopy] Failed: pasteboard.writeObjects returned false", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            self.showToast("Image copied")
            DashboardViewModel.recordImageCopy(coordinator: self.coordinator, frameID: self.currentFrame?.id.value)
        }
    }

    private func visibleZoomRegionText() -> String {
        let sortedNodes = ocrNodesInZoomRegion.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        return sortedNodes.compactMap { visibleTextInZoomRegion(for: $0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleTextInZoomRegion(for node: OCRNodeWithText) -> String? {
        let rawText: String
        if let range = getVisibleCharacterRange(for: node) {
            let clampedStart = max(0, min(range.start, node.text.count))
            let clampedEnd = max(clampedStart, min(range.end, node.text.count))
            guard clampedStart < clampedEnd else {
                return nil
            }

            let startIndex = node.text.index(node.text.startIndex, offsetBy: clampedStart)
            let endIndex = node.text.index(node.text.startIndex, offsetBy: clampedEnd)
            rawText = String(node.text[startIndex..<endIndex])
        } else {
            rawText = node.text
        }

        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
        if isInLiveMode {
            if let liveScreenshot {
                completion(liveScreenshot)
            } else {
                Log.warning("[ZoomCopy] Live mode active but liveScreenshot is nil", category: .ui)
                completion(nil)
            }
            return
        }

        guard let videoInfo = currentVideoInfo else {
            Log.warning("[ZoomCopy] No currentVideoInfo for historical frame image extraction", category: .ui)
            completion(nil)
            return
        }

        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                Log.warning("[ZoomCopy] Video file missing at both paths: \(actualVideoPath) and \(pathWithExtension)", category: .ui)
                completion(nil)
                return
            }
        }

        guard let url = MP4SymlinkResolver.resolveURL(for: actualVideoPath) else {
            Log.warning("[ZoomCopy] Failed to resolve mp4-compatible URL for video path: \(actualVideoPath)", category: .ui)
            completion(nil)
            return
        }
        zoomCopyRequestID &+= 1
        let requestID = zoomCopyRequestID
        cancelZoomCopyDecode(reason: "ui.timeline.zoom_copy_decode")
        let asset = AVURLAsset(url: url)
        let directDecodeBytes = UIDirectFrameDecodeMemoryLedger.begin(
            tag: UIDirectFrameDecodeMemoryLedger.zoomCopyGeneratorTag,
            function: "ui.timeline.direct_decode",
            reason: "ui.timeline.zoom_copy_decode",
            videoInfo: videoInfo
        )
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        let generatorID = ObjectIdentifier(imageGenerator)
        zoomCopyGenerator = imageGenerator
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let time = videoInfo.frameTimeCMTime
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                UIDirectFrameDecodeMemoryLedger.end(
                    tag: UIDirectFrameDecodeMemoryLedger.zoomCopyGeneratorTag,
                    reason: "ui.timeline.zoom_copy_decode",
                    bytes: directDecodeBytes
                )
                self.clearZoomCopyGeneratorIfMatching(generatorID)
                guard requestID == self.zoomCopyRequestID else {
                    return
                }
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    Log.warning("[ZoomCopy] AVAssetImageGenerator returned nil image for url=\(url.path), frameIndex=\(videoInfo.frameIndex)", category: .ui)
                    completion(nil)
                }
            }
        }
    }

    func cancelPendingDirectDecodeGenerators(reason: String) {
        cancelShiftDragDisplayDecode(reason: reason)
        cancelZoomCopyDecode(reason: reason)
    }

    func cancelShiftDragDisplayDecode(reason: String) {
        guard let shiftDragDisplayGenerator else { return }
        shiftDragDisplayGenerator.cancelAllCGImageGeneration()
        self.shiftDragDisplayGenerator = nil
        Log.debug("[Timeline-Decode] Cancelled shift-drag generator (\(reason))", category: .ui)
    }

    private func cancelZoomCopyDecode(reason: String) {
        guard let zoomCopyGenerator else { return }
        zoomCopyGenerator.cancelAllCGImageGeneration()
        self.zoomCopyGenerator = nil
        Log.debug("[Timeline-Decode] Cancelled zoom-copy generator (\(reason))", category: .ui)
    }

    func clearShiftDragDisplayGeneratorIfMatching(_ generatorID: ObjectIdentifier) {
        guard let shiftDragDisplayGenerator else { return }
        guard ObjectIdentifier(shiftDragDisplayGenerator) == generatorID else { return }
        self.shiftDragDisplayGenerator = nil
    }

    private func clearZoomCopyGeneratorIfMatching(_ generatorID: ObjectIdentifier) {
        guard let zoomCopyGenerator else { return }
        guard ObjectIdentifier(zoomCopyGenerator) == generatorID else { return }
        self.zoomCopyGenerator = nil
    }
}
