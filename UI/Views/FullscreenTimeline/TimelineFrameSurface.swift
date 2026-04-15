import Foundation
import SwiftUI
import Shared

struct TimelineFrameSurfaceState {
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let capturedMouseCursorPoint: CGPoint?
    let redactedNodes: [OCRNodeWithText]
    let hyperlinkContextMenuEntries: [HyperlinkContextMenuEntry]
    let redactionContextMenuEntries: [RedactedNodeContextMenuEntry]
    let showsHyperlinkVisualOverlays: Bool
    let showFinalZoomState: Bool
    let showZoomTransition: Bool
    let showZoomExitTransition: Bool
    let showNormalMode: Bool
    let highlightControlsVisibilityRow: Bool
}

struct TimelineFrameSurfaceBaseLayer<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let surfaceState: TimelineFrameSurfaceState
    let content: () -> Content

    var body: some View {
        ZStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(viewModel.frameZoomScale)
                .offset(viewModel.frameZoomOffset)

            if (surfaceState.showFinalZoomState || surfaceState.showZoomTransition || surfaceState.showZoomExitTransition),
               let region = viewModel.zoomRegion {
                ZoomUnifiedOverlay(
                    viewModel: viewModel,
                    zoomRegion: region,
                    containerSize: surfaceState.containerSize,
                    actualFrameRect: surfaceState.actualFrameRect,
                    isTransitioning: surfaceState.showZoomTransition,
                    isExitTransitioning: surfaceState.showZoomExitTransition
                ) {
                    content()
                }
            }
        }
    }
}

struct TimelineFrameSurfaceNormalOverlayLayer: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let surfaceState: TimelineFrameSurfaceState
    let onHyperlinkOpen: (OCRHyperlinkMatch) -> Void

    var body: some View {
        if surfaceState.showNormalMode {
            Group {
                if !viewModel.isInLiveMode,
                   let cursorPoint = surfaceState.capturedMouseCursorPoint {
                    CapturedMouseCursorOverlay(point: cursorPoint)
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                        .allowsHitTesting(false)
                }

                if viewModel.isDraggingZoomRegion,
                   let start = viewModel.zoomRegionDragStart,
                   let end = viewModel.zoomRegionDragEnd {
                    ZoomRegionDragPreview(
                        start: start,
                        end: end,
                        containerSize: surfaceState.containerSize,
                        actualFrameRect: surfaceState.actualFrameRect
                    )
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)
                }

                if !viewModel.ocrNodes.isEmpty {
                    RedactedNodeRevealOverlay(
                        viewModel: viewModel,
                        nodes: surfaceState.redactedNodes,
                        actualFrameRect: surfaceState.actualFrameRect
                    )
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)
                    .allowsHitTesting(false)
                }

                TextSelectionOverlay(
                    viewModel: viewModel,
                    containerSize: surfaceState.containerSize,
                    actualFrameRect: surfaceState.actualFrameRect,
                    hyperlinkMatches: viewModel.hyperlinkMatches,
                    onHyperlinkOpen: onHyperlinkOpen,
                    isInteractionDisabled: viewModel.isInLiveMode && viewModel.ocrNodes.isEmpty,
                    onDragStart: { point, isCommandDrag in
                        viewModel.startDragSelection(
                            at: point,
                            mode: isCommandDrag ? .box : .character
                        )
                    },
                    onDragUpdate: { point, isCommandDrag in
                        viewModel.updateDragSelection(
                            to: point,
                            mode: isCommandDrag ? .box : .character
                        )
                        viewModel.showTextSelectionHintBannerOnce()
                    },
                    onDragEnd: {
                        viewModel.endDragSelection()
                        viewModel.resetTextSelectionHintState()
                    },
                    onClearSelection: {
                        viewModel.clearTextSelection()
                    },
                    onZoomRegionStart: { point in
                        viewModel.startZoomRegion(at: point)
                    },
                    onZoomRegionUpdate: { point in
                        viewModel.updateZoomRegion(to: point)
                    },
                    onZoomRegionEnd: {
                        viewModel.endZoomRegion()
                    },
                    onDoubleClick: { point in
                        viewModel.selectWordAt(point: point)
                    },
                    onTripleClick: { point in
                        viewModel.selectNodeAt(point: point)
                    }
                )
                .scaleEffect(viewModel.frameZoomScale)
                .offset(viewModel.frameZoomOffset)

                if surfaceState.showsHyperlinkVisualOverlays, let box = viewModel.urlBoundingBox {
                    URLBoundingBoxOverlay(
                        boundingBox: box,
                        containerSize: surfaceState.containerSize,
                        actualFrameRect: surfaceState.actualFrameRect,
                        isHovering: viewModel.isHoveringURL,
                        onHoverChanged: { hovering in
                            viewModel.isHoveringURL = hovering
                        },
                        onClick: {
                            viewModel.openURLInBrowser()
                            TimelineWindowController.shared.hide(restorePreviousFocus: false)
                        }
                    )
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)
                }

                if surfaceState.showsHyperlinkVisualOverlays, !viewModel.hyperlinkMatches.isEmpty {
                    OCRHyperlinkOverlay(
                        matches: viewModel.hyperlinkMatches,
                        actualFrameRect: surfaceState.actualFrameRect,
                        onHoverChanged: { match in
                            viewModel.updateInPageURLHoverState(match)
                        },
                        onOpen: onHyperlinkOpen
                    )
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)
                }
            }
        }
    }
}

struct TimelineFrameSurface<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @AppStorage("captureMousePosition", store: fullscreenTimelineSettingsStore) private var captureMousePosition = true
    let onURLClicked: () -> Void
    let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let surfaceState = makeSurfaceState(for: geometry)
            let openHyperlink: (OCRHyperlinkMatch) -> Void = { match in
                let didOpen = viewModel.openHyperlinkMatch(match)
                if didOpen {
                    TimelineWindowController.shared.hide(restorePreviousFocus: false)
                }
            }

            TimelineFrameSurfaceBaseLayer(
                viewModel: viewModel,
                surfaceState: surfaceState,
                content: content
            )
            .overlay {
                TimelineFrameSurfaceNormalOverlayLayer(
                    viewModel: viewModel,
                    surfaceState: surfaceState,
                    onHyperlinkOpen: openHyperlink
                )
            }
            .overlay {
                if !surfaceState.redactionContextMenuEntries.isEmpty {
                    RedactionTooltipOverlay(
                        viewModel: viewModel,
                        entries: surfaceState.redactionContextMenuEntries,
                        containerSize: surfaceState.containerSize,
                        onToggleReveal: { node in
                            viewModel.togglePhraseLevelRedactionReveal(for: node)
                        }
                    )
                }
            }
            .onRightClick(
                hyperlinkEntries: surfaceState.hyperlinkContextMenuEntries,
                onHyperlinkRightClick: { match in
                    viewModel.dismissRedactionTooltip()
                    viewModel.recordInPageURLRightClick(for: match)
                },
                onHyperlinkCopy: { match in
                    _ = viewModel.copyHyperlinkMatch(match)
                }
            ) { location in
                guard !viewModel.isFilterPanelVisible else { return }
                viewModel.dismissRedactionTooltip()
                withAnimation(.easeOut(duration: 0.16)) {
                    viewModel.presentContextMenu(at: location)
                }
            }
            .overlay {
                if viewModel.showContextMenu {
                    let frameContextMenuBinding = Binding(
                        get: { viewModel.showContextMenu },
                        set: { viewModel.setContextMenuVisible($0) }
                    )
                    FloatingContextMenu(
                        viewModel: viewModel,
                        isPresented: frameContextMenuBinding,
                        location: viewModel.contextMenuLocation,
                        containerSize: surfaceState.containerSize,
                        highlightControlsVisibilityRow: surfaceState.highlightControlsVisibilityRow
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                if viewModel.isFrameZoomed {
                    FrameZoomIndicator(zoomScale: viewModel.frameZoomScale)
                        .padding(.spacingL)
                        .padding(.top, 40)
                }
            }
        }
    }

    private func makeSurfaceState(for geometry: GeometryProxy) -> TimelineFrameSurfaceState {
        let actualFrameRect = calculateActualDisplayedFrameRect(containerSize: geometry.size)
        let capturedMouseCursorPoint = capturedMouseOverlayPoint(
            mousePosition: viewModel.frameMousePosition,
            framePixelSize: currentFramePixelSize(),
            actualFrameRect: actualFrameRect
        )
        let showFinalZoomState = viewModel.isZoomRegionActive && viewModel.zoomRegion != nil
        let showZoomTransition = viewModel.isZoomTransitioning && viewModel.zoomRegion != nil
        let showZoomExitTransition = viewModel.isZoomExitTransitioning && viewModel.zoomRegion != nil
        let showNormalMode = !viewModel.isZoomRegionActive && !viewModel.isZoomTransitioning && !viewModel.isZoomExitTransitioning
        let showsHyperlinkVisualOverlays = !viewModel.isInLiveMode
        let redactedNodes = viewModel.ocrNodes.filter(\.isRedacted)

        return TimelineFrameSurfaceState(
            containerSize: geometry.size,
            actualFrameRect: actualFrameRect,
            capturedMouseCursorPoint: captureMousePosition ? capturedMouseCursorPoint : nil,
            redactedNodes: redactedNodes,
            hyperlinkContextMenuEntries: makeHyperlinkContextMenuEntries(
                actualFrameRect: actualFrameRect,
                containerSize: geometry.size,
                showsHyperlinkVisualOverlays: showsHyperlinkVisualOverlays
            ),
            redactionContextMenuEntries: makeRedactionContextMenuEntries(
                redactedNodes: redactedNodes,
                actualFrameRect: actualFrameRect,
                containerSize: geometry.size,
                showFinalZoomState: showFinalZoomState,
                showNormalMode: showNormalMode
            ),
            showsHyperlinkVisualOverlays: showsHyperlinkVisualOverlays,
            showFinalZoomState: showFinalZoomState,
            showZoomTransition: showZoomTransition,
            showZoomExitTransition: showZoomExitTransition,
            showNormalMode: showNormalMode,
            highlightControlsVisibilityRow: viewModel.highlightShowControlsContextMenuRow || shouldGuideHideControlsRow(
                containerSize: geometry.size,
                actualFrameRect: actualFrameRect
            )
        )
    }

    private func makeHyperlinkContextMenuEntries(
        actualFrameRect: CGRect,
        containerSize: CGSize,
        showsHyperlinkVisualOverlays: Bool
    ) -> [HyperlinkContextMenuEntry] {
        guard showsHyperlinkVisualOverlays else { return [] }
        return viewModel.hyperlinkMatches.compactMap { match in
            let rect = transformedHyperlinkContextMenuRect(
                for: match,
                actualFrameRect: actualFrameRect,
                containerSize: containerSize,
                scale: viewModel.frameZoomScale,
                offset: viewModel.frameZoomOffset
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return HyperlinkContextMenuEntry(match: match, rect: rect)
        }
    }

    private func makeRedactionContextMenuEntries(
        redactedNodes: [OCRNodeWithText],
        actualFrameRect: CGRect,
        containerSize: CGSize,
        showFinalZoomState: Bool,
        showNormalMode: Bool
    ) -> [RedactedNodeContextMenuEntry] {
        if showFinalZoomState, let zoomRegion = viewModel.zoomRegion {
            let zoomedRect = zoomedFrameRectForContextMenu(
                zoomRegion: zoomRegion,
                containerSize: containerSize,
                actualFrameRect: actualFrameRect
            )
            guard zoomedRect.width > 1, zoomedRect.height > 1 else { return [] }
            return redactedNodes.compactMap { node in
                guard let rect = zoomedRedactionContextMenuRect(
                    for: node,
                    zoomRegion: zoomRegion,
                    zoomedRect: zoomedRect
                ),
                rect.width > 1,
                rect.height > 1 else {
                    return nil
                }
                return RedactedNodeContextMenuEntry(
                    node: node,
                    rect: rect,
                    tooltipState: SimpleTimelineViewModel.phraseLevelRedactionTooltipState(
                        for: viewModel.currentTimelineFrame?.processingStatus ?? -1,
                        isRevealed: viewModel.revealedRedactedNodePatches[node.id] != nil
                    )
                )
            }
        }

        guard showNormalMode else { return [] }
        return redactedNodes.compactMap { node in
            let rect = transformedRedactionContextMenuRect(
                for: node,
                actualFrameRect: actualFrameRect,
                containerSize: containerSize,
                scale: viewModel.frameZoomScale,
                offset: viewModel.frameZoomOffset
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return RedactedNodeContextMenuEntry(
                node: node,
                rect: rect,
                tooltipState: SimpleTimelineViewModel.phraseLevelRedactionTooltipState(
                    for: viewModel.currentTimelineFrame?.processingStatus ?? -1,
                    isRevealed: viewModel.revealedRedactedNodePatches[node.id] != nil
                )
            )
        }
    }

    private func calculateActualDisplayedFrameRect(containerSize: CGSize) -> CGRect {
        let frameSize = currentFramePixelSize()
        let containerAspect = containerSize.width / containerSize.height
        let frameAspect = frameSize.width / frameSize.height

        let displayedSize: CGSize
        let offset: CGPoint

        if frameAspect > containerAspect {
            displayedSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / frameAspect
            )
            offset = CGPoint(
                x: 0,
                y: (containerSize.height - displayedSize.height) / 2
            )
        } else {
            displayedSize = CGSize(
                width: containerSize.height * frameAspect,
                height: containerSize.height
            )
            offset = CGPoint(
                x: (containerSize.width - displayedSize.width) / 2,
                y: 0
            )
        }

        return CGRect(origin: offset, size: displayedSize)
    }

    private func currentFramePixelSize() -> CGSize {
        let frameSize: CGSize
        if viewModel.isInLiveMode, let liveImage = viewModel.liveScreenshot {
            frameSize = CGSize(
                width: liveImage.representations.first?.pixelsWide ?? Int(liveImage.size.width),
                height: liveImage.representations.first?.pixelsHigh ?? Int(liveImage.size.height)
            )
        } else if let videoInfo = viewModel.currentVideoInfo,
                  let width = videoInfo.width,
                  let height = videoInfo.height {
            frameSize = CGSize(width: width, height: height)
        } else if let image = viewModel.displayableCurrentImage {
            frameSize = CGSize(
                width: image.representations.first?.pixelsWide ?? Int(image.size.width),
                height: image.representations.first?.pixelsHigh ?? Int(image.size.height)
            )
        } else if let fallbackImage = viewModel.waitingVideoFallbackImage {
            frameSize = CGSize(
                width: fallbackImage.representations.first?.pixelsWide ?? Int(fallbackImage.size.width),
                height: fallbackImage.representations.first?.pixelsHigh ?? Int(fallbackImage.size.height)
            )
        } else {
            frameSize = CGSize(width: 1920, height: 1080)
        }

        return frameSize
    }

    private func capturedMouseOverlayPoint(
        mousePosition: CGPoint?,
        framePixelSize: CGSize,
        actualFrameRect: CGRect
    ) -> CGPoint? {
        guard let mousePosition else { return nil }
        guard framePixelSize.width > 1, framePixelSize.height > 1 else { return nil }

        let normalizedX = min(max(mousePosition.x / framePixelSize.width, 0), 1)
        let normalizedY = min(max(mousePosition.y / framePixelSize.height, 0), 1)

        return CGPoint(
            x: actualFrameRect.origin.x + (normalizedX * actualFrameRect.width),
            y: actualFrameRect.origin.y + (normalizedY * actualFrameRect.height)
        )
    }

    private func shouldGuideHideControlsRow(containerSize: CGSize, actualFrameRect: CGRect) -> Bool {
        guard viewModel.isShowingSearchHighlight else { return false }
        guard !viewModel.areControlsHidden else { return false }
        guard !viewModel.isInFrameSearchVisible else { return false }

        let highlightCutoffY = containerSize.height * 0.75
        var seenNodeIDs = Set<Int>()

        for match in viewModel.searchHighlightNodes {
            guard seenNodeIDs.insert(match.node.id).inserted else { continue }

            let rect = CGRect(
                x: actualFrameRect.origin.x + (match.node.x * actualFrameRect.width),
                y: actualFrameRect.origin.y + (match.node.y * actualFrameRect.height),
                width: match.node.width * actualFrameRect.width,
                height: match.node.height * actualFrameRect.height
            )

            guard !rect.isEmpty else { continue }
            if rect.maxY >= highlightCutoffY {
                return true
            }
        }

        return false
    }
}

private struct CapturedMouseCursorOverlay: View {
    let point: CGPoint
    private static let targetCursorSize = CGSize(width: 29, height: 40)
    private static let macCursorVisualScale: CGFloat = 1.12
    private static let fallbackHotspot = CGPoint(x: 3.26, y: 3.26)
    private static let fallbackOuterCursorFontSize: CGFloat = 32.6
    private static let fallbackInnerCursorFontSize: CGFloat = 29.4
    private static let cursorOpacity: Double = 0.5

    private static let macStyledCursor: (image: NSImage, hotSpot: CGPoint)? = {
        let cursor = NSCursor.arrow
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0,
              let recolored = recoloredMacCursorImage(image) else {
            return nil
        }
        return (image: recolored, hotSpot: cursor.hotSpot)
    }()

    private static func resolvedRenderedCursorSize() -> CGSize {
        guard let cursor = Self.macStyledCursor else { return Self.targetCursorSize }

        let widthScale = Self.targetCursorSize.width / cursor.image.size.width
        let heightScale = Self.targetCursorSize.height / cursor.image.size.height
        let scale = min(widthScale, heightScale) * Self.macCursorVisualScale
        return CGSize(
            width: cursor.image.size.width * scale,
            height: cursor.image.size.height * scale
        )
    }

    private static func resolvedRenderedHotspot(for renderedCursorSize: CGSize) -> CGPoint {
        guard let cursor = Self.macStyledCursor else { return Self.fallbackHotspot }
        guard cursor.image.size.width > 0, cursor.image.size.height > 0 else { return Self.fallbackHotspot }

        let scale = renderedCursorSize.width / cursor.image.size.width
        return CGPoint(
            x: cursor.hotSpot.x * scale,
            y: cursor.hotSpot.y * scale
        )
    }

    private var renderedCursorSize: CGSize {
        Self.resolvedRenderedCursorSize()
    }

    private var renderedHotspot: CGPoint {
        Self.resolvedRenderedHotspot(for: renderedCursorSize)
    }

    var body: some View {
        Group {
            if let cursor = Self.macStyledCursor {
                Image(nsImage: cursor.image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack(alignment: .topLeading) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: Self.fallbackOuterCursorFontSize, weight: .black))
                        .foregroundStyle(.white.opacity(0.96))
                        .offset(x: 1.2, y: 1.2)

                    Image(systemName: "cursorarrow")
                        .font(.system(size: Self.fallbackInnerCursorFontSize, weight: .black))
                        .foregroundStyle(Color.retraceBrandBlue)
                        .offset(x: 0.56, y: 0.56)
                }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 1.6, x: 0, y: 0)
        .opacity(Self.cursorOpacity)
        .frame(width: renderedCursorSize.width, height: renderedCursorSize.height, alignment: .topLeading)
        .position(
            x: point.x + (renderedCursorSize.width / 2) - renderedHotspot.x,
            y: point.y + (renderedCursorSize.height / 2) - renderedHotspot.y
        )
    }

    private static func recoloredMacCursorImage(_ image: NSImage) -> NSImage? {
        let pointSize = image.size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelWidth = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width.rounded())
        let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height.rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: pointSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()

        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerRow = bitmap.bytesPerRow

        let brandRed = 11.0
        let brandGreen = 51.0
        let brandBlue = 108.0

        for row in 0 ..< pixelHeight {
            for col in 0 ..< pixelWidth {
                let offset = (row * bytesPerRow) + (col * 4)
                let r = Double(data[offset + 0])
                let g = Double(data[offset + 1])
                let b = Double(data[offset + 2])
                let a = Double(data[offset + 3])

                guard a > 0 else { continue }

                let luminance = ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255.0
                let shouldTintCore = (a >= 150.0 && luminance <= 0.76) || (a >= 100.0 && luminance <= 0.50)
                guard shouldTintCore else { continue }

                let edgeBlend = min(max((luminance - 0.10) / 0.60, 0.0), 1.0)
                let tone = 0.84 + (0.16 * edgeBlend)

                data[offset + 0] = UInt8(max(0, min(255, Int((brandRed * tone).rounded()))))
                data[offset + 1] = UInt8(max(0, min(255, Int((brandGreen * tone).rounded()))))
                data[offset + 2] = UInt8(max(0, min(255, Int((brandBlue * tone).rounded()))))
            }
        }

        let output = NSImage(size: pointSize)
        output.addRepresentation(bitmap)
        return output
    }
}

private func transformedHyperlinkContextMenuRect(
    for match: OCRHyperlinkMatch,
    actualFrameRect: CGRect,
    containerSize: CGSize,
    scale: CGFloat,
    offset: CGSize
) -> CGRect {
    let rect = CGRect(
        x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
        y: actualFrameRect.origin.y + (match.y * actualFrameRect.height),
        width: match.highlightWidth * actualFrameRect.width,
        height: match.height * actualFrameRect.height
    )

    guard scale != 1 else {
        return rect.offsetBy(dx: offset.width, dy: offset.height)
    }

    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    let scaledOrigin = CGPoint(
        x: center.x + ((rect.origin.x - center.x) * scale) + offset.width,
        y: center.y + ((rect.origin.y - center.y) * scale) + offset.height
    )

    return CGRect(
        origin: scaledOrigin,
        size: CGSize(width: rect.width * scale, height: rect.height * scale)
    )
}

private func transformedRedactionContextMenuRect(
    for node: OCRNodeWithText,
    actualFrameRect: CGRect,
    containerSize: CGSize,
    scale: CGFloat,
    offset: CGSize
) -> CGRect {
    let rect = CGRect(
        x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
        y: actualFrameRect.origin.y + (node.y * actualFrameRect.height),
        width: node.width * actualFrameRect.width,
        height: node.height * actualFrameRect.height
    )

    guard scale != 1 else {
        return rect.offsetBy(dx: offset.width, dy: offset.height)
    }

    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    let scaledOrigin = CGPoint(
        x: center.x + ((rect.origin.x - center.x) * scale) + offset.width,
        y: center.y + ((rect.origin.y - center.y) * scale) + offset.height
    )

    return CGRect(
        origin: scaledOrigin,
        size: CGSize(width: rect.width * scale, height: rect.height * scale)
    )
}

private func zoomedFrameRectForContextMenu(
    zoomRegion: CGRect,
    containerSize: CGSize,
    actualFrameRect: CGRect
) -> CGRect {
    let menuWidth: CGFloat = 180
    let menuGap: CGFloat = 30
    let maxWidth = containerSize.width * 0.70
    let maxHeight = containerSize.height * 0.75
    let regionWidth = zoomRegion.width * actualFrameRect.width
    let regionHeight = zoomRegion.height * actualFrameRect.height
    guard regionWidth > 0, regionHeight > 0 else { return .zero }

    let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
    let enlargedWidth = regionWidth * scaleToFit
    let enlargedHeight = regionHeight * scaleToFit
    let availableWidth = containerSize.width - menuWidth - menuGap

    return CGRect(
        x: (availableWidth - enlargedWidth) / 2,
        y: (containerSize.height - enlargedHeight) / 2,
        width: enlargedWidth,
        height: enlargedHeight
    )
}

private func zoomedRedactionContextMenuRect(
    for node: OCRNodeWithText,
    zoomRegion: CGRect,
    zoomedRect: CGRect
) -> CGRect? {
    let regionMaxX = zoomRegion.origin.x + zoomRegion.width
    let regionMaxY = zoomRegion.origin.y + zoomRegion.height
    let nodeMaxX = node.x + node.width
    let nodeMaxY = node.y + node.height

    guard nodeMaxX > zoomRegion.origin.x,
          node.x < regionMaxX,
          nodeMaxY > zoomRegion.origin.y,
          node.y < regionMaxY else {
        return nil
    }

    let relativeX = (node.x - zoomRegion.origin.x) / zoomRegion.width
    let relativeY = (node.y - zoomRegion.origin.y) / zoomRegion.height
    let relativeWidth = node.width / zoomRegion.width
    let relativeHeight = node.height / zoomRegion.height

    return CGRect(
        x: zoomedRect.origin.x + (relativeX * zoomedRect.width),
        y: zoomedRect.origin.y + (relativeY * zoomedRect.height),
        width: relativeWidth * zoomedRect.width,
        height: relativeHeight * zoomedRect.height
    )
}

struct HyperlinkContextMenuEntry {
    let match: OCRHyperlinkMatch
    let rect: CGRect
}

struct RedactedNodeContextMenuEntry {
    let node: OCRNodeWithText
    let rect: CGRect
    let tooltipState: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState?
}
