import SwiftUI
import AppKit
import Shared
import App
import UniformTypeIdentifiers
import AVFoundation

struct TimelineBlockIndicatorPresentation: Equatable {
    let showsTagIndicator: Bool
    let showsCommentIndicator: Bool
    let showsActionMenuAffordance: Bool

    var shouldRender: Bool {
        showsTagIndicator || showsCommentIndicator || showsActionMenuAffordance
    }

    static func make(for block: AppBlock, revealsAffordances: Bool) -> Self {
        let showsTagIndicator = !block.tagIDs.isEmpty
        let showsCommentIndicator = block.hasComments
        return Self(
            showsTagIndicator: showsTagIndicator,
            showsCommentIndicator: showsCommentIndicator,
            showsActionMenuAffordance: revealsAffordances
        )
    }
}

/// Timeline tape view that scrolls horizontally with a fixed center playhead
/// Groups consecutive frames by app and displays app icons
public struct TimelineTapeView: View {
    private struct TapeViewportState {
        let layout: TapeLayoutSnapshot
        let tapeOffset: CGFloat
        let totalTapeWidth: CGFloat
        let cullingLeftX: CGFloat
        let cullingRightX: CGFloat
        let visibleBlocks: [TapeBlockLayout]
        let tagsByID: [Int64: Tag]
    }

    // MARK: - Properties

    @ObservedObject var viewModel: SimpleTimelineViewModel
    let width: CGFloat
    let coordinator: AppCoordinator

    // Tape dimensions (resolution-adaptive)
    private var tapeHeight: CGFloat { TimelineScaleFactor.tapeHeight }
    private var blockSpacing: CGFloat { TimelineScaleFactor.blockSpacing }
    private var appIconSize: CGFloat { TimelineScaleFactor.appIconSize }
    private var iconDisplayThreshold: CGFloat { TimelineScaleFactor.iconDisplayThreshold }
    private var pixelsPerFrame: CGFloat { viewModel.pixelsPerFrame }

    /// Fixed offset for the app badge - positioned to the left of the datetime button
    private var currentAppBadgeOffset: CGFloat {
        -(TimelineScaleFactor.controlButtonSize * 3 + TimelineScaleFactor.controlSpacing)
    }

    /// Shared UserDefaults store for accessing settings
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Scrubbing animation duration from settings (0 = no animation, max 0.20)
    /// Using @AppStorage so the view automatically updates when the setting changes
    @AppStorage("scrubbingAnimationDuration", store: TimelineTapeView.settingsStore)
    private var scrubbingAnimationDuration: Double = 0.10
    @StateObject private var tapeLayoutCache = TapeLayoutCache()
    @State private var hoveredBlockID: String?

    // MARK: - Body

    public var body: some View {
        tapeShell
    }

    private var tapeShell: some View {
        ZStack {
            tapeInteractionBackground

            // Scrollable tape content (right-click handled per-frame)
            // Use id to force view recreation on peek toggle, enabling transition animation
            tapeContent
                .id("tape-\(viewModel.isPeeking)")
                .transition(.opacity.combined(with: .scale(scale: 0.98)))

            // Fixed center playhead (on top of everything)
            playhead
        }
        .frame(height: tapeHeight)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isPeeking)
    }

    private var tapeInteractionBackground: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.clearSelection()
            }
    }

    // MARK: - Tape Content

    private var tapeContent: some View {
        GeometryReader { geometry in
            let viewport = makeTapeViewportState(for: geometry)
            tapeViewport(viewport)
        }
    }

    private func makeTapeViewportState(for geometry: GeometryProxy) -> TapeViewportState {
        let centerX = geometry.size.width / 2
        let layout = tapeLayoutCache.layout(
            snapshotRevision: viewModel.appBlockSnapshotRevision,
            blocks: viewModel.appBlocks,
            frameCount: viewModel.frames.count,
            pixelsPerFrame: pixelsPerFrame,
            blockSpacing: blockSpacing,
            gapIndicatorWidth: gapIndicatorWidth,
            hidingRange: viewModel.hidingSegmentBlockRange
        )
        let currentFrameOffset = layout.offsetForFrame(viewModel.currentIndex)
        let unclampedTapeOffset = centerX - currentFrameOffset - viewModel.subFrameOffset
        let totalTapeWidth = layout.totalTapeWidth

        // Clamp tape offset to prevent scrolling past content.
        let maxOffset = centerX
        let minOffset = centerX - totalTapeWidth
        let tapeOffset = max(minOffset, min(maxOffset, unclampedTapeOffset))

        let visibleLeftX = -tapeOffset
        let visibleRightX = geometry.size.width - tapeOffset
        let buffer = geometry.size.width
        let cullingLeftX = visibleLeftX - buffer
        let cullingRightX = visibleRightX + buffer
        let visibleBlocks = layout.blocks.filter { item in
            item.rightX >= cullingLeftX && item.leftX <= cullingRightX
        }

        return TapeViewportState(
            layout: layout,
            tapeOffset: tapeOffset,
            totalTapeWidth: totalTapeWidth,
            cullingLeftX: cullingLeftX,
            cullingRightX: cullingRightX,
            visibleBlocks: visibleBlocks,
            tagsByID: viewModel.availableTagsByID
        )
    }

    @ViewBuilder
    private func tapeViewport(_ viewport: TapeViewportState) -> some View {
        ZStack(alignment: .leading) {
            tapeBlocks(viewport)

            if viewModel.showSegmentBoundaries {
                segmentBoundaryMarkers(layout: viewport.layout)
            }

            if viewModel.showVideoBoundaries {
                videoBoundaryMarkers(layout: viewport.layout)
            }
        }
        .offset(x: viewport.tapeOffset)
        .animation(
            scrubbingAnimationDuration > 0 && !viewModel.isActivelyScrolling
                ? .easeOut(duration: scrubbingAnimationDuration)
                : nil,
            value: viewModel.currentIndex
        )
        .animation(.easeOut(duration: 0.2), value: viewModel.zoomLevel)
    }

    private func tapeBlocks(_ viewport: TapeViewportState) -> some View {
        ForEach(viewport.visibleBlocks, id: \.block.id) { item in
            if item.hasGap, let gapX = item.gapX {
                gapIndicatorView(block: item.block)
                    .offset(x: gapX)
            }

            appBlockView(
                item: item,
                cullingLeftX: viewport.cullingLeftX,
                cullingRightX: viewport.cullingRightX,
                tagsByID: viewport.tagsByID
            )
            .offset(x: item.leftX)
        }
        .frame(width: viewport.totalTapeWidth, alignment: .leading)
    }

    // MARK: - Segment Boundary Markers

    /// Blue tick marks showing where segment boundaries are on the timeline
    @ViewBuilder
    private func segmentBoundaryMarkers(layout: TapeLayoutSnapshot) -> some View {
        let boundaries = viewModel.orderedSegmentBoundaryIndices

        ForEach(boundaries, id: \.self) { frameIndex in
            let xOffset = layout.offsetForFrame(frameIndex) - pixelsPerFrame / 2

            Rectangle()
                .fill(Color.blue)
                .frame(width: 2, height: tapeHeight + 16)
                .offset(x: xOffset, y: -8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Video Boundary Markers

    /// Red tick marks showing where video segment boundaries are on the timeline
    @ViewBuilder
    private func videoBoundaryMarkers(layout: TapeLayoutSnapshot) -> some View {
        let boundaries = viewModel.orderedVideoBoundaryIndices

        ForEach(boundaries, id: \.self) { frameIndex in
            let xOffset = layout.offsetForFrame(frameIndex) - pixelsPerFrame / 2

            // Thick red line that protrudes above and below the tape
            Rectangle()
                .fill(Color.red)
                .frame(width: 3, height: tapeHeight + 16)
                .offset(x: xOffset, y: -8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gap Indicator View

    /// Fixed-width indicator showing time gap between blocks
    private func gapIndicatorView(block: AppBlock) -> some View {
        let gapWidth: CGFloat = 100 * TimelineScaleFactor.current

        return ZStack {
            // Hatched background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.05))
                .frame(width: gapWidth, height: tapeHeight)
                .overlay(
                    GapHatchPattern()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

            // Gap duration text with background
            if let gapText = block.formattedGapBefore {
                Text(gapText)
                    .font(.system(size: 10 * TimelineScaleFactor.current, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 6 * TimelineScaleFactor.current)
                    .padding(.vertical, 2 * TimelineScaleFactor.current)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.2))
                    )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - App Block View

    private func appBlockView(
        item: TapeBlockLayout,
        cullingLeftX: CGFloat,
        cullingRightX: CGFloat,
        tagsByID: [Int64: Tag]
    ) -> some View {
        let hoverExtension: CGFloat = 36
        let block = item.block
        let isCurrentBlock = viewModel.currentIndex >= block.startIndex && viewModel.currentIndex <= block.endIndex
        let isSelectedBlock = viewModel.selectedFrameIndex.map { $0 >= block.startIndex && $0 <= block.endIndex } ?? false
        let revealsAffordances = hoveredBlockID == block.id
        let indicatorPresentation = TimelineBlockIndicatorPresentation.make(
            for: block,
            revealsAffordances: revealsAffordances
        )
        let color = blockColor(for: block)
        let collapseFactor = item.collapseFactor
        let isHidingBlock = collapseFactor < 0.999
        let framePixelWidth = max(item.effectivePixelsPerFrame, 0.001)
        let blockWidth = item.width

        // Calculate this block's position in tape-space for frame culling
        let blockLeftX = item.leftX
        let blockRightX = item.rightX

        // Calculate visible frame range within this block
        let relativeLeft = max(0, cullingLeftX - blockLeftX)
        let relativeRight = cullingRightX - blockLeftX

        let firstVisibleFrame = block.startIndex + max(0, Int(floor(relativeLeft / framePixelWidth)))
        let lastVisibleFrame = block.startIndex + min(block.frameCount - 1, Int(ceil(relativeRight / framePixelWidth)))

        // Clamp to block bounds
        let renderStart = max(block.startIndex, firstVisibleFrame)
        let renderEnd = min(block.endIndex, lastVisibleFrame)

        // Check if block is completely outside visible range
        let blockVisible = blockRightX >= cullingLeftX && blockLeftX <= cullingRightX

        return ZStack {
            // Background block
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: blockWidth, height: tapeHeight)
                .opacity(isCurrentBlock || isSelectedBlock ? 1.0 : 0.7)

            // Individual frame segments (clickable) - only render visible frames
            if blockVisible && renderStart <= renderEnd && !isHidingBlock {
                HStack(spacing: 0) {
                    // Spacer for frames before visible range
                    if renderStart > block.startIndex {
                        Spacer()
                            .frame(width: CGFloat(renderStart - block.startIndex) * framePixelWidth)
                    }

                    // Only render visible frames
                    ForEach(renderStart...renderEnd, id: \.self) { frameIndex in
                        frameSegment(at: frameIndex, in: block)
                    }

                    // Spacer for frames after visible range
                    if renderEnd < block.endIndex {
                        Spacer()
                            .frame(width: CGFloat(block.endIndex - renderEnd) * framePixelWidth)
                    }
                }
                .frame(width: blockWidth, height: tapeHeight)
            }

            // App icon (only show if block is wide enough)
            if !isHidingBlock, blockWidth > iconDisplayThreshold, let bundleID = block.bundleID {
                appIcon(for: bundleID)
                    .frame(width: appIconSize, height: appIconSize)
                    .allowsHitTesting(false) // Allow clicks to pass through to frame segments
            }

            // Top-edge indicators (tags/comments plus an action-menu hint when actions are otherwise hidden).
            if !isHidingBlock, blockWidth > 22, indicatorPresentation.shouldRender {
                BlockIndicatorsOverlay(
                    block: block,
                    blockWidth: blockWidth,
                    emphasized: isCurrentBlock || isSelectedBlock || revealsAffordances,
                    presentation: indicatorPresentation,
                    tagsByID: tagsByID,
                    tagCatalogRevision: viewModel.tagCatalogRevision,
                    onOpenTags: { source in
                        viewModel.openTagSubmenuForTimelineBlock(block, source: source)
                    },
                    onOpenComments: { source in
                        viewModel.openCommentSubmenuForTimelineBlock(block, source: source)
                    },
                    onOpenTimelineMenu: {
                        viewModel.openTimelineContextMenuForTimelineBlock(block)
                    }
                )
                .equatable()
            }

            // Selection/current border overlay (on top of frame segments so border is fully visible)
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelectedBlock ? Color.blue : (isCurrentBlock ? Color.white : Color.clear), lineWidth: isSelectedBlock ? 3 : 2)
                .frame(width: blockWidth, height: tapeHeight)
                .allowsHitTesting(false)
        }
        .scaleEffect(
            y: isHidingBlock ? 0.82 : 1.0,
            anchor: .center
        )
        .frame(width: blockWidth, height: tapeHeight + hoverExtension, alignment: .bottom)
        .offset(y: -hoverExtension / 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredBlockID = hovering ? block.id : (hoveredBlockID == block.id ? nil : hoveredBlockID)
            }
        }
        .opacity(isHidingBlock ? 0.12 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: collapseFactor)
    }

    // MARK: - Frame Segment View

    private func frameSegment(at frameIndex: Int, in block: AppBlock) -> some View {
        FrameSegmentView(
            viewModel: viewModel,
            frameIndex: frameIndex,
            isHidden: viewModel.isFrameHidden(at: frameIndex),
            pixelsPerFrame: pixelsPerFrame,
            tapeHeight: tapeHeight
        )
    }

    // MARK: - Helper Functions

    /// Fixed width of gap indicators (doubled from original)
    private var gapIndicatorWidth: CGFloat { 100 * TimelineScaleFactor.current }

    /// Cached block geometry for tape rendering.
    private struct TapeBlockLayout {
        let block: AppBlock
        let leftX: CGFloat
        let rightX: CGFloat
        let width: CGFloat
        let gapX: CGFloat?
        let hasGap: Bool
        let collapseFactor: CGFloat
        let effectivePixelsPerFrame: CGFloat
    }

    private struct TapeLayoutSnapshot {
        let blocks: [TapeBlockLayout]
        let totalTapeWidth: CGFloat
        let frameCenterOffsets: [CGFloat]

        static let empty = TapeLayoutSnapshot(blocks: [], totalTapeWidth: 0, frameCenterOffsets: [])

        func offsetForFrame(_ frameIndex: Int) -> CGFloat {
            guard !frameCenterOffsets.isEmpty else { return 0 }
            let clampedIndex = max(0, min(frameCenterOffsets.count - 1, frameIndex))
            return frameCenterOffsets[clampedIndex]
        }
    }

    private final class TapeLayoutCache: ObservableObject {
        private struct CacheKey: Equatable {
            let snapshotRevision: Int
            let frameCount: Int
            let pixelsPerFrameMilli: Int
            let blockSpacingMilli: Int
            let gapWidthMilli: Int
            let hidingLower: Int?
            let hidingUpper: Int?
        }

        private var key: CacheKey?
        private var cached: TapeLayoutSnapshot = .empty

        func layout(
            snapshotRevision: Int,
            blocks: [AppBlock],
            frameCount: Int,
            pixelsPerFrame: CGFloat,
            blockSpacing: CGFloat,
            gapIndicatorWidth: CGFloat,
            hidingRange: ClosedRange<Int>?
        ) -> TapeLayoutSnapshot {
            let key = CacheKey(
                snapshotRevision: snapshotRevision,
                frameCount: frameCount,
                pixelsPerFrameMilli: quantized(pixelsPerFrame),
                blockSpacingMilli: quantized(blockSpacing),
                gapWidthMilli: quantized(gapIndicatorWidth),
                hidingLower: hidingRange?.lowerBound,
                hidingUpper: hidingRange?.upperBound
            )
            if self.key == key {
                return cached
            }

            let layout = Self.buildLayout(
                blocks: blocks,
                frameCount: frameCount,
                pixelsPerFrame: pixelsPerFrame,
                blockSpacing: blockSpacing,
                gapIndicatorWidth: gapIndicatorWidth,
                hidingRange: hidingRange
            )
            self.key = key
            self.cached = layout
            return layout
        }

        private static func buildLayout(
            blocks: [AppBlock],
            frameCount: Int,
            pixelsPerFrame: CGFloat,
            blockSpacing: CGFloat,
            gapIndicatorWidth: CGFloat,
            hidingRange: ClosedRange<Int>?
        ) -> TapeLayoutSnapshot {
            guard !blocks.isEmpty else {
                return TapeLayoutSnapshot(
                    blocks: [],
                    totalTapeWidth: 0,
                    frameCenterOffsets: Array(repeating: 0, count: max(0, frameCount))
                )
            }

            var layoutBlocks: [TapeBlockLayout] = []
            layoutBlocks.reserveCapacity(blocks.count)
            var frameCenterOffsets = Array(repeating: CGFloat.zero, count: max(0, frameCount))
            var x: CGFloat = 0

            for block in blocks {
                let hasGap = block.gapBeforeSeconds != nil
                var gapX: CGFloat? = nil
                if hasGap {
                    gapX = x
                    x += gapIndicatorWidth + blockSpacing
                }

                let collapseFactor: CGFloat
                if let hidingRange,
                   hidingRange.lowerBound == block.startIndex,
                   hidingRange.upperBound == block.endIndex {
                    collapseFactor = 0.05
                } else {
                    collapseFactor = 1.0
                }

                let effectivePixelsPerFrame = pixelsPerFrame * collapseFactor
                let blockWidth = max(2, CGFloat(block.frameCount) * effectivePixelsPerFrame)
                let leftX = x
                let rightX = leftX + blockWidth

                layoutBlocks.append(TapeBlockLayout(
                    block: block,
                    leftX: leftX,
                    rightX: rightX,
                    width: blockWidth,
                    gapX: gapX,
                    hasGap: hasGap,
                    collapseFactor: collapseFactor,
                    effectivePixelsPerFrame: effectivePixelsPerFrame
                ))

                if !frameCenterOffsets.isEmpty {
                    let start = max(0, block.startIndex)
                    let end = min(block.endIndex, frameCenterOffsets.count - 1)
                    if start <= end {
                        for frameIndex in start...end {
                            let framePositionInBlock = frameIndex - block.startIndex
                            frameCenterOffsets[frameIndex] = leftX
                                + (CGFloat(framePositionInBlock) * effectivePixelsPerFrame)
                                + (effectivePixelsPerFrame / 2)
                        }
                    }
                }

                x = rightX + blockSpacing
            }

            let totalTapeWidth = max(0, x - blockSpacing)
            return TapeLayoutSnapshot(
                blocks: layoutBlocks,
                totalTapeWidth: totalTapeWidth,
                frameCenterOffsets: frameCenterOffsets
            )
        }

        private func quantized(_ value: CGFloat) -> Int {
            Int((value * 1_000).rounded())
        }
    }

    private func blockColor(for block: AppBlock) -> Color {
        if let bundleID = block.bundleID {
            return Color.segmentColor(for: bundleID)
        }
        return Color.gray.opacity(0.5)
    }

    private func appIcon(for bundleID: String) -> some View {
        AppIconView(bundleID: bundleID, size: appIconSize)
    }

    private struct BlockIndicatorsOverlay: View, Equatable {
        let block: AppBlock
        let blockWidth: CGFloat
        let emphasized: Bool
        let presentation: TimelineBlockIndicatorPresentation
        let tagsByID: [Int64: Tag]
        let tagCatalogRevision: UInt64
        let onOpenTags: (String) -> Void
        let onOpenComments: (String) -> Void
        let onOpenTimelineMenu: () -> Void

        @State private var isTagGroupHovering = false
        @State private var isCommentIconHovering = false

        static func == (lhs: BlockIndicatorsOverlay, rhs: BlockIndicatorsOverlay) -> Bool {
            lhs.block.id == rhs.block.id &&
                lhs.block.tagIDs == rhs.block.tagIDs &&
                lhs.block.hasComments == rhs.block.hasComments &&
                lhs.emphasized == rhs.emphasized &&
                lhs.presentation == rhs.presentation &&
                lhs.tagCatalogRevision == rhs.tagCatalogRevision &&
                abs(lhs.blockWidth - rhs.blockWidth) < 0.001
        }

        var body: some View {
            let indicatorRowHeight: CGFloat = 18
            let bubbleReferenceHeight: CGFloat = 16
            let tagButtonHeight: CGFloat = indicatorRowHeight + 4
            let commentButtonHeight: CGFloat = indicatorRowHeight
            let visibleControlHeight: CGFloat = max(
                presentation.showsTagIndicator ? tagButtonHeight : 0,
                presentation.showsCommentIndicator ? commentButtonHeight : 0,
                presentation.showsActionMenuAffordance ? bubbleReferenceHeight : 0
            )
            let topLift: CGFloat = 22 + max(0, (visibleControlHeight - bubbleReferenceHeight) / 2)

            return HStack(spacing: 6) {
                if presentation.showsTagIndicator {
                    Button(action: { onOpenTags("tape_indicator") }) {
                        tagIndicatorDots(rowHeight: indicatorRowHeight)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open tags")
                    .scaleEffect(isTagGroupHovering ? 1.12 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isTagGroupHovering)
                    .onHover { hovering in
                        isTagGroupHovering = hovering
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }

                if presentation.showsCommentIndicator {
                    Button(action: { onOpenComments("tape_indicator") }) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(emphasized ? 0.9 : 0.8))
                            .frame(width: indicatorRowHeight, height: indicatorRowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open comments")
                    .scaleEffect(isCommentIconHovering ? 1.18 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isCommentIconHovering)
                    .onHover { hovering in
                        isCommentIconHovering = hovering
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }

                if presentation.showsActionMenuAffordance {
                    actionMenuIndicatorButton {
                        onOpenTimelineMenu()
                    }
                }
            }
            .padding(.leading, 6)
            .offset(y: -topLift)
            .frame(width: blockWidth, height: TimelineScaleFactor.tapeHeight, alignment: .topLeading)
            .animation(.easeOut(duration: 0.12), value: presentation)
        }

        private func tagIndicatorDots(rowHeight: CGFloat) -> some View {
            let visibleTagIDs = Array(block.tagIDs.prefix(3))
            let hasOverflow = block.tagIDs.count > visibleTagIDs.count
            let dotOpacity = emphasized ? 0.96 : 0.82
            let dotStrokeOpacity = emphasized ? 0.58 : 0.42
            let dotGlowOpacity = emphasized ? 0.40 : 0.26
            let dotSize: CGFloat = 9
            let visibleCount = CGFloat(visibleTagIDs.count + (hasOverflow ? 1 : 0))
            let intrinsicRowWidth = visibleCount * dotSize + max(0, visibleCount - 1) * 3
            let rowWidth = max(10, intrinsicRowWidth)

            return HStack(spacing: 3) {
                ForEach(visibleTagIDs, id: \.self) { tagID in
                    let color = tagColor(forTagIDValue: tagID)
                    Circle()
                        .fill(color.opacity(dotOpacity))
                        .overlay(
                            Circle()
                                .stroke(color.opacity(dotStrokeOpacity), lineWidth: 0.8)
                        )
                        .shadow(color: color.opacity(dotGlowOpacity), radius: emphasized ? 3.2 : 2.4, x: 0, y: 0)
                        .frame(width: dotSize, height: dotSize)
                }

                if hasOverflow {
                    Circle()
                        .fill(Color.white.opacity(dotOpacity))
                        .frame(width: dotSize - 1, height: dotSize - 1)
                }
            }
            .frame(width: rowWidth, height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
        }

        private func tagColor(forTagIDValue tagIDValue: Int64) -> Color {
            if let tag = tagsByID[tagIDValue] {
                return TagColorStore.color(for: tag)
            }
            return TagColorStore.color(forTagID: TagID(value: tagIDValue))
        }

        private func actionMenuIndicatorButton(action: @escaping () -> Void) -> some View {
            ActionMenuIndicatorButton(emphasized: emphasized, action: action)
        }

        private struct ActionMenuIndicatorButton: View {
            let emphasized: Bool
            let action: () -> Void

            @State private var isHovering = false

            var body: some View {
                Button(action: action) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: emphasized ? 10 : 9, weight: .bold))
                        .foregroundColor(.white.opacity(emphasized || isHovering ? 0.84 : 0.7))
                        .frame(width: emphasized ? 16 : 14, height: emphasized ? 16 : 14)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(emphasized || isHovering ? 0.16 : 0.09))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(emphasized || isHovering ? 0.24 : 0.16), lineWidth: 0.8)
                        )
                        .scaleEffect(isHovering ? 1.12 : 1.0)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Open actions")
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isHovering)
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
        }
    }

}
