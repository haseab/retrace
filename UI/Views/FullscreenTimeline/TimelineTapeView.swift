import SwiftUI
import Shared
import App
import UniformTypeIdentifiers
import AVFoundation

/// Timeline tape view that scrolls horizontally with a fixed center playhead
/// Groups consecutive frames by app and displays app icons
public struct TimelineTapeView: View {

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
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app")

    /// Scrubbing animation duration from settings (0 = no animation, max 0.20)
    /// Using @AppStorage so the view automatically updates when the setting changes
    @AppStorage("scrubbingAnimationDuration", store: UserDefaults(suiteName: "io.retrace.app"))
    private var scrubbingAnimationDuration: Double = 0.10
    @StateObject private var tapeLayoutCache = TapeLayoutCache()

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background (tap to clear selection)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.clearSelection()
                }

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

    // MARK: - Tape Content

    private var tapeContent: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let blocks = viewModel.appBlocks
            let layout = tapeLayoutCache.layout(
                snapshotRevision: viewModel.appBlockSnapshotRevision,
                blocks: blocks,
                frameCount: viewModel.frames.count,
                pixelsPerFrame: pixelsPerFrame,
                blockSpacing: blockSpacing,
                gapIndicatorWidth: gapIndicatorWidth,
                hidingRange: viewModel.hidingSegmentBlockRange
            )

            // Calculate offset to center current frame
            let currentFrameOffset = layout.offsetForFrame(viewModel.currentIndex)
            let unclampedTapeOffset = centerX - currentFrameOffset - viewModel.subFrameOffset

            // Calculate total tape width
            let totalTapeWidth = layout.totalTapeWidth

            // Clamp tape offset to prevent scrolling past content
            // - At the start: tape's left edge shouldn't go past centerX
            // - At the end: tape's right edge shouldn't go past centerX
            let maxOffset = centerX // Start of tape at center (for first frame)
            let minOffset = centerX - totalTapeWidth // End of tape at center (for last frame)

            let tapeOffset = max(minOffset, min(maxOffset, unclampedTapeOffset))

            // Calculate visible frame range for culling (only render visible frames)
            let visibleLeftX = -tapeOffset
            let visibleRightX = geometry.size.width - tapeOffset
            // Add buffer for smooth scrolling
            let buffer = geometry.size.width
            let cullingLeftX = visibleLeftX - buffer
            let cullingRightX = visibleRightX + buffer

            ZStack(alignment: .leading) {
                // Main tape blocks with gap indicators
                // Precompute all block positions in O(n), then filter to visible
                let visibleBlocks = layout.blocks.filter { item in
                    item.rightX >= cullingLeftX && item.leftX <= cullingRightX
                }

                ForEach(visibleBlocks, id: \.block.id) { item in
                    // Gap indicator before block
                    if item.hasGap, let gapX = item.gapX {
                        gapIndicatorView(block: item.block)
                            .offset(x: gapX)
                    }
                    // The block itself
                    appBlockView(item: item, cullingLeftX: cullingLeftX, cullingRightX: cullingRightX)
                        .offset(x: item.leftX)
                }
                .frame(width: totalTapeWidth, alignment: .leading)

                // Video boundary markers overlay (only when enabled)
                if viewModel.showVideoBoundaries {
                    videoBoundaryMarkers(layout: layout)
                }
            }
            .offset(x: tapeOffset)
            .animation(scrubbingAnimationDuration > 0 && !viewModel.isActivelyScrolling ? .easeOut(duration: scrubbingAnimationDuration) : nil, value: viewModel.currentIndex)
            .animation(.easeOut(duration: 0.2), value: viewModel.zoomLevel)
        }
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

    private func appBlockView(item: TapeBlockLayout, cullingLeftX: CGFloat, cullingRightX: CGFloat) -> some View {
        let block = item.block
        let isCurrentBlock = viewModel.currentIndex >= block.startIndex && viewModel.currentIndex <= block.endIndex
        let isSelectedBlock = viewModel.selectedFrameIndex.map { $0 >= block.startIndex && $0 <= block.endIndex } ?? false
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
            guard frameIndex >= 0 && frameIndex < frameCenterOffsets.count else { return 0 }
            return frameCenterOffsets[frameIndex]
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

    // MARK: - Fixed Playhead

    private var playhead: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let middleSideControlsWidth = TimelineScaleFactor.controlButtonSize * 2 + 6 + 8 +
                (viewModel.showVideoControls ? TimelineScaleFactor.controlButtonSize + TimelineScaleFactor.controlSpacing : 0)

            ZStack {
                // Center controls: Filter + Datetime + GoToNow/Refresh
                // Datetime stays centered, filter on left, go-to-now on right
                HStack(spacing: TimelineScaleFactor.controlSpacing) {
                    // Filter button (left of datetime)
                    FilterAndPeekGroup(viewModel: viewModel)
                        .frame(width: middleSideControlsWidth, alignment: .trailing)

                    // Datetime button (center)
                    DatetimeButton(viewModel: viewModel)

                    // Go to Now / Refresh button + Video Controls (right of datetime)
                    HStack(spacing: TimelineScaleFactor.controlSpacing) {
                        Group {
                            if viewModel.shouldShowGoToNow {
                                GoToNowButton(viewModel: viewModel)
                                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            } else {
                                RefreshButton(viewModel: viewModel)
                                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: viewModel.shouldShowGoToNow)

                        if viewModel.showVideoControls {
                            VideoControlsButton(viewModel: viewModel)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .frame(width: middleSideControlsWidth, alignment: .leading)
                }
                .position(x: centerX, y: TimelineScaleFactor.controlsYOffset)

                // Left side controls (search)
                SearchButton(viewModel: viewModel)
                    .opacity(viewModel.isSearchOverlayVisible ? 0 : 1)
                    .scaleEffect(viewModel.isSearchOverlayVisible ? 0.8 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: viewModel.isSearchOverlayVisible)
                    .position(x: TimelineScaleFactor.leftControlsX, y: TimelineScaleFactor.controlsYOffset)

                // Right side controls (app badge + more options)
                HStack(spacing: TimelineScaleFactor.controlSpacing) {
                    CurrentAppBadge(viewModel: viewModel)
                    // ZoomControl(viewModel: viewModel)
                    MoreOptionsMenu(viewModel: viewModel)
                }
                .padding(4)
                .frame(width: (TimelineScaleFactor.controlButtonSize * 4) + (TimelineScaleFactor.controlSpacing * 3) + 8, alignment: .trailing)
                .position(x: geometry.size.width - TimelineScaleFactor.rightControlsXOffset - (TimelineScaleFactor.controlButtonSize + TimelineScaleFactor.controlSpacing) / 2, y: TimelineScaleFactor.controlsYOffset)

                // Playhead vertical line (fixed at center)
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                    .fill(Color.white)
                    .frame(width: TimelineScaleFactor.playheadWidth, height: tapeHeight * 2.5)
                    .position(x: centerX, y: tapeHeight / 2)

                // Floating search input (appears above the datetime button when active)
                if viewModel.isDateSearchActive && !viewModel.isCalendarPickerVisible {
                    FloatingDateSearchPanel(
                        text: $viewModel.dateSearchText,
                        onSubmit: {
                            Task {
                                await viewModel.searchForDate(viewModel.dateSearchText)
                            }
                        },
                        onCancel: {
                            viewModel.closeDateSearch()
                        },
                        enableFrameIDSearch: viewModel.enableFrameIDSearch,
                        viewModel: viewModel
                    )
                    .position(x: centerX, y: TimelineScaleFactor.searchPanelYOffset)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                }

                // Calendar picker (appears when calendar button is clicked)
                if viewModel.isCalendarPickerVisible {
                    CalendarPickerView(viewModel: viewModel)
                        .position(x: centerX, y: TimelineScaleFactor.calendarPickerYOffset)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
        }
    }

}

// MARK: - Frame Segment View

/// Individual frame segment in the timeline tape with hover effect
struct FrameSegmentView: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let frameIndex: Int
    let isHidden: Bool
    let pixelsPerFrame: CGFloat
    let tapeHeight: CGFloat

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.white.opacity(0.2) : Color.clear)
            .frame(width: pixelsPerFrame, height: tapeHeight)
            .contentShape(Rectangle())
            .overlay(
                // Diagonal stripe pattern for hidden segments
                Group {
                    if isHidden {
                        HiddenSegmentOverlay()
                    }
                }
            )
            .onTapGesture {
                viewModel.selectFrame(at: frameIndex)
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .overlay(
                Group {
                    // Only create NSView for frames near current index to avoid 500 NSView instances
                    if abs(frameIndex - viewModel.currentIndex) < 40 {
                        FrameRightClickHandler(viewModel: viewModel, frameIndex: frameIndex)
                    }
                }
            )
    }
}

// MARK: - Datetime Button

/// Button showing current date/time that opens the date search panel
struct DatetimeButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            viewModel.toggleDateSearch()
        }) {
            HStack(spacing: TimelineScaleFactor.iconSpacing) {
                Text(viewModel.currentDateString)
                    .font(.system(size: TimelineScaleFactor.fontCaption, weight: .medium))
                    .foregroundColor(isHovering ? .white : .white.opacity(0.7))

                Text(viewModel.currentTimeString)
                    .font(.system(size: TimelineScaleFactor.fontMono, weight: .regular, design: .monospaced))
                    .foregroundColor(.white)

                Image(systemName: "chevron.down")
                    .font(.system(size: TimelineScaleFactor.fontTiny, weight: .bold))
                    .foregroundColor(isHovering ? .white.opacity(0.7) : .white.opacity(0.4))
            }
            .padding(.horizontal, TimelineScaleFactor.paddingH)
            .padding(.vertical, TimelineScaleFactor.paddingV)
            .themeAwareCapsuleStyle(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Go To Now Button

/// Button to quickly jump to the most recent frame
/// Fades in when not viewing the most recent frame
struct GoToNowButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            viewModel.goToNow()
        }) {
            Image(systemName: "forward.end.fill")
                .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                .foregroundColor(isHovering ? .white : .white.opacity(0.7))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .instantTooltip("Go to Now (⌘J)", isVisible: $isHovering)
    }
}

// MARK: - Refresh Button

/// Button to refresh and load the newest data when already at the most recent frame
struct RefreshButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            Task {
                await viewModel.loadMostRecentFrame()
                await viewModel.refreshProcessingStatuses()
            }
        }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                .foregroundColor(isHovering ? .white : .white.opacity(0.7))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .instantTooltip("Refresh (⌘J)", isVisible: $isHovering)
    }
}

// MARK: - Video Controls Button

/// Play/pause button with speed control popover for auto-advancing frames
/// Only visible when "Show video controls" is enabled in Settings > Advanced
struct VideoControlsButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isButtonHovering = false
    @State private var isPickerHovering = false
    @State private var showSpeedPicker = false

    private let availableSpeeds: [Double] = [1, 2, 4, 8]

    private var isHoveringControl: Bool {
        isButtonHovering || isPickerHovering
    }

    var body: some View {
        // Button sized to match other controls; speed picker floats above via overlay
        Button(action: {
            viewModel.dismissContextMenu()
            let wasPlaying = viewModel.isPlaying
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.togglePlayback()
            }
            Log.info(
                "[PLAY-CLICK] button click handled wasPlaying=\(wasPlaying) nowPlaying=\(viewModel.isPlaying) " +
                "speed=\(formattedSpeed(viewModel.playbackSpeed)) mouse=\(formattedMouseLocation())",
                category: .ui
            )
        }) {
            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                .foregroundColor(isHoveringControl || viewModel.isPlaying ? .white : .white.opacity(0.7))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isActive: viewModel.isPlaying, isHovering: isHoveringControl)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isButtonHovering = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showSpeedPicker = true
                }
            } else {
                NSCursor.pop()
                dismissSpeedPickerIfNeeded(after: 0.2)
            }
        }
        .instantTooltip(
            viewModel.isPlaying ? "Pause" : "Play (\(formattedSpeed(viewModel.playbackSpeed)))",
            isVisible: .constant(isButtonHovering && !showSpeedPicker)
        )
        // Speed picker floats above the play button.
        .overlay(alignment: .bottom) {
            if showSpeedPicker {
                VStack(spacing: 2) {
                    ForEach(availableSpeeds.reversed(), id: \.self) { speed in
                        SpeedOptionRow(
                            speed: speed,
                            isSelected: speed == viewModel.playbackSpeed,
                            label: formattedSpeed(speed)
                        ) {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                viewModel.setPlaybackSpeed(speed)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(RetraceMenuStyle.backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                // Position picker so its bottom sits above the button top with a fixed gap.
                .offset(y: -(TimelineScaleFactor.controlButtonSize + 6))
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)).combined(with: .offset(y: 4)))
                .onHover { hovering in
                    if hovering {
                        isPickerHovering = true
                    } else {
                        isPickerHovering = false
                        dismissSpeedPickerIfNeeded(after: 0.15)
                    }
                }
            }
        }
    }

    private func formattedSpeed(_ speed: Double) -> String {
        if speed == 1 { return "1x" }
        return "\(Int(speed))x"
    }

    private func dismissSpeedPickerIfNeeded(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if !isButtonHovering && !isPickerHovering {
                withAnimation(.easeOut(duration: 0.15)) {
                    showSpeedPicker = false
                }
            }
        }
    }

    private func formattedMouseLocation() -> String {
        let mouse = NSEvent.mouseLocation
        return "(\(Int(mouse.x)),\(Int(mouse.y)))"
    }
}

/// Individual speed option row with hover highlight and pointer cursor
private struct SpeedOptionRow: View {
    let speed: Double
    let isSelected: Bool
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected || isHovering ? .white : .white.opacity(0.6))
                .frame(width: 40, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.white.opacity(0.15) : (isHovering ? Color.white.opacity(0.1) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Current App Badge

/// Circular badge showing the current app's icon
/// Positioned to the left of the datetime button
/// Shows "Open" button when hovering on a browser URL frame
struct CurrentAppBadge: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var expandTask: Task<Void, Never>?

    private let buttonSize = TimelineScaleFactor.controlButtonSize * 1.125
    private let iconSize = TimelineScaleFactor.controlButtonSize * 0.95

    /// Get the bundle ID of the current frame's app
    private var currentBundleID: String? {
        viewModel.currentFrame?.metadata.appBundleID
    }

    /// Get the browser URL if available
    private var currentBrowserURL: String? {
        viewModel.currentFrame?.metadata.browserURL
    }

    /// Check if we have a valid URL to open
    var hasOpenableURL: Bool {
        guard let urlString = currentBrowserURL, !urlString.isEmpty else { return false }
        return URL(string: urlString) != nil
    }

    /// Whether to show the expanded "Open" state
    private var shouldShowExpanded: Bool {
        (isExpanded || isHovering) && hasOpenableURL && !viewModel.isActivelyScrolling
    }

    private var expandedWidth: CGFloat {
        TimelineScaleFactor.controlButtonSize * 3.0
    }

    var body: some View {
        Group {
            // Only show the badge for browsers with an openable URL
            if let bundleID = currentBundleID, hasOpenableURL {
                Button(action: {
                    if hasOpenableURL, viewModel.openCurrentBrowserURL() {
                        TimelineWindowController.shared.hide()
                    }
                }) {
                    // Fixed-size container with trailing alignment - pill expands leftward
                    ZStack(alignment: .trailing) {
                        // Invisible spacer to maintain hit area
                        Color.clear
                            .frame(width: expandedWidth, height: buttonSize)

                        // Animated button content pinned to right edge (expands left)
                        HStack(spacing: 8) {
                            if shouldShowExpanded {
                                Text("Open")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                            appIconView(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                        }
                        .frame(height: buttonSize)
                        .padding(.leading, shouldShowExpanded ? 12 : 0)
                        .padding(.trailing, shouldShowExpanded ? 10 : 0)
                        .background(
                            Group {
                                if shouldShowExpanded {
                                    Capsule()
                                        .fill(Color(white: 0.15))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.white.opacity(0.15), lineWidth: 1.0)
                                        )
                                }
                            }
                        )
                        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: shouldShowExpanded)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                    if hasOpenableURL {
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .instantTooltip("Open Link (⌘L)", isVisible: .constant(isHovering))
                .id(bundleID)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shouldShowExpanded)
        .animation(.easeInOut(duration: 0.2), value: currentBundleID)
        .onChange(of: viewModel.isActivelyScrolling) { isScrolling in
            if isScrolling {
                // Collapse immediately when scrolling starts
                expandTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded = false
                }
            } else if hasOpenableURL {
                // Expand after a short delay when scrolling stops on a browser frame
                expandTask?.cancel()
                expandTask = Task {
                    try? await Task.sleep(nanoseconds: 650_000_000) // 650ms delay
                    if !Task.isCancelled && !viewModel.isActivelyScrolling && hasOpenableURL {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: hasOpenableURL) { hasURL in
            if !hasURL {
                // Collapse when navigating away from a browser frame
                expandTask?.cancel()
                isExpanded = false
            } else if !viewModel.isActivelyScrolling {
                // Schedule expand when landing on a browser frame
                expandTask?.cancel()
                expandTask = Task {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    if !Task.isCancelled && !viewModel.isActivelyScrolling && hasOpenableURL {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // If we appear on a browser frame (not scrolling), expand after delay
            if hasOpenableURL && !viewModel.isActivelyScrolling {
                expandTask = Task {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appIconView(for bundleID: String) -> some View {
        AppIconView(bundleID: bundleID, size: iconSize)
    }
}

// MARK: - Zoom Control

/// Zoom control that expands from a magnifier button to a slider (expands leftward)
struct ZoomControl: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    /// Show tooltip only when hovering and slider is not expanded
    private var showTooltip: Bool {
        isHovering && !viewModel.isZoomSliderExpanded
    }

    var body: some View {
        // Use overlay so the button position stays fixed and slider appears to its left
        Button(action: {
            viewModel.dismissContextMenu()
            let animation: Animation = viewModel.isZoomSliderExpanded ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8)
            withAnimation(animation) {
                viewModel.isZoomSliderExpanded.toggle()
            }
        }) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: TimelineScaleFactor.fontCallout, weight: .medium))
                .foregroundColor(isHovering || viewModel.isZoomSliderExpanded ? .white : .white.opacity(0.6))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isActive: viewModel.isZoomSliderExpanded, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .overlay(alignment: .trailing) {
            // Expanded slider panel - positioned to the left of the button
            if viewModel.isZoomSliderExpanded {
                HStack(spacing: TimelineScaleFactor.iconSpacing) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    ZoomSlider(value: $viewModel.zoomLevel)
                        .frame(width: TimelineScaleFactor.zoomSliderWidth)

                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, TimelineScaleFactor.buttonPaddingH)
                .padding(.vertical, TimelineScaleFactor.buttonPaddingV)
                .background(
                    Capsule()
                        .fill(Color(white: 0.15))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .offset(x: -TimelineScaleFactor.controlButtonSize - 8) // Position to the left of the button
                .transition(.opacity.combined(with: .offset(x: 20)))
            }
        }
        .overlay(alignment: .top) {
            if showTooltip {
                Text("Zoom")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black)
                    )
                    .offset(y: -44)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Filter Button

/// Filter button that shows active filter count badge
struct FilterButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var isBadgeHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                viewModel.dismissContextMenu()
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.openFilterPanel()
                    }
                }
            }) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: TimelineScaleFactor.fontCallout, weight: .medium))
                    .foregroundColor(isHovering || viewModel.isFilterPanelVisible || viewModel.activeFilterCount > 0
                        ? .white
                        : .white.opacity(0.6))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isFilterPanelVisible)
                    .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                    .themeAwareCircleStyle(isActive: viewModel.isFilterPanelVisible || viewModel.activeFilterCount > 0, isHovering: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            // Badge showing active filter count (or X on hover to clear)
            if viewModel.activeFilterCount > 0 {
                Button(action: {
                    // Clear all filters when clicking the badge
                    viewModel.clearAllFilters()
                }) {
                    Group {
                        if isBadgeHovering {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(viewModel.activeFilterCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .background(Color.red)
                    .clipShape(Circle())
                    .scaleEffect(isBadgeHovering ? 1.15 : 1.0)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.1)) {
                        isBadgeHovering = hovering
                    }
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
        }
        .instantTooltip(viewModel.activeFilterCount > 0 && isBadgeHovering ? "Clear filters" : "Filter (⌥F)", isVisible: .constant(isHovering || isBadgeHovering))
    }
}

/// Groups the peek button (left) with the filter button (right) when filters are active
/// Filter stays anchored; peek slides in/out on the left without shifting filter.
struct FilterAndPeekGroup: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    private var showPeekButton: Bool {
        viewModel.activeFilterCount > 0 || viewModel.isPeeking
    }

    private let spacing: CGFloat = 6

    var body: some View {
        ZStack(alignment: .trailing) {
            // Background capsule sized as if both buttons exist, so nothing jumps
            Capsule()
                .fill(Color.white.opacity(showPeekButton ? 0.08 : 0))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(showPeekButton ? 0.15 : 0), lineWidth: 0.5)
                )
                .frame(
                    width: showPeekButton
                        ? (TimelineScaleFactor.controlButtonSize * 2 + spacing + 8) // 2 buttons + spacing + padding
                        : TimelineScaleFactor.controlButtonSize,                   // just filter button
                    height: TimelineScaleFactor.controlButtonSize + (showPeekButton ? 8 : 0)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPeekButton)

            // Anchored filter button (never moves)
            FilterButton(viewModel: viewModel)
                .padding(showPeekButton ? 4 : 0)

            // Peek button slides in to the LEFT of filter, without affecting layout
            if showPeekButton {
                PeekButton(viewModel: viewModel)
                    .padding(4)
                    .offset(x: -(TimelineScaleFactor.controlButtonSize + spacing))
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .zIndex(1)
            }
        }
        .frame(
            width: TimelineScaleFactor.controlButtonSize * 2 + spacing + 8, // Always reserve space for both buttons
            alignment: .trailing
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPeekButton)
    }
}

/// Button to toggle peek mode (view full timeline context while filtered)
struct PeekButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.togglePeek()
        }) {
            Image(systemName: "eye")
                .font(.system(size: TimelineScaleFactor.fontCallout, weight: .medium))
                .foregroundColor(isHovering || viewModel.isPeeking ? .white : .white.opacity(0.6))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isActive: viewModel.isPeeking, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .instantTooltip(viewModel.isPeeking ? "Hide Context (⌘P)" : "See Context (⌘P)", isVisible: .constant(isHovering))
    }
}

// MARK: - Controls Toggle Button

/// Button to toggle timeline controls visibility
struct ControlsToggleButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            viewModel.toggleControlsVisibility()
        }) {
            Image(systemName: viewModel.areControlsHidden ? "menubar.arrow.up.rectangle" : "menubar.arrow.down.rectangle")
                .font(.system(size: TimelineScaleFactor.fontMono, weight: .medium))
                .foregroundColor(isHovering ? .white : .white.opacity(0.6))
                .padding(.horizontal, TimelineScaleFactor.paddingV)
                .padding(.vertical, TimelineScaleFactor.paddingV)
                .themeAwareCapsuleStyle(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .instantTooltip(viewModel.areControlsHidden ? "Show (⌘H)" : "Hide (⌘H)", isVisible: $isHovering)
    }
}

// MARK: - Search Button

/// Search button styled as an input field that opens the spotlight search overlay
struct SearchButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    @State private var isHovering = false

    /// Display text: shows the search query if present, otherwise "Search"
    private var displayText: String {
        let query = viewModel.searchViewModel.searchQuery
        return query.isEmpty ? "Search" : query
    }

    /// Whether there's an active search query
    private var hasSearchQuery: Bool {
        !viewModel.searchViewModel.searchQuery.isEmpty
    }

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            // Set overlay visible immediately, clear highlight asynchronously to avoid blocking
            viewModel.isSearchOverlayVisible = true
            // Record search dialog open metric
            DashboardViewModel.recordSearchDialogOpen(coordinator: coordinatorWrapper.coordinator)
            Task { @MainActor in
                viewModel.clearSearchHighlight()
            }
        }) {
            HStack(spacing: TimelineScaleFactor.iconSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: TimelineScaleFactor.fontCaption, weight: .medium))
                    .foregroundColor(hasSearchQuery ? .white.opacity(0.9) : (isHovering ? .white.opacity(0.9) : .white.opacity(0.5)))

                Text(displayText)
                    .font(.system(size: TimelineScaleFactor.fontCaption, weight: .regular))
                    .foregroundColor(hasSearchQuery ? .white.opacity(0.9) : (isHovering ? .white.opacity(0.8) : .white.opacity(0.4)))
                    .lineLimit(1)

                Spacer()

                // Keyboard shortcut hint
                Text("⌘K")
                    .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                    .foregroundColor(isHovering ? .white.opacity(0.7) : .white.opacity(0.3))
                    .padding(.horizontal, 6 * TimelineScaleFactor.current)
                    .padding(.vertical, 2 * TimelineScaleFactor.current)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * TimelineScaleFactor.current)
                            .fill(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.1))
                    )
            }
            .padding(.horizontal, TimelineScaleFactor.paddingH)
            .padding(.vertical, TimelineScaleFactor.paddingV)
            .frame(width: TimelineScaleFactor.searchButtonWidth)
            .themeAwareCapsuleStyle(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .help("Search (Cmd+K)")
    }
}

// MARK: - More Options Menu

/// Three-dot menu button with dropdown options
struct MoreOptionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    @State private var isButtonHovering = false
    @State private var isMenuHovering = false

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
        }) {
            Image(systemName: "ellipsis")
                .font(.system(size: TimelineScaleFactor.fontCallout, weight: .medium))
                .foregroundColor(isButtonHovering || viewModel.isMoreOptionsMenuVisible ? .white : .white.opacity(0.6))
                .frame(width: TimelineScaleFactor.controlButtonSize, height: TimelineScaleFactor.controlButtonSize)
                .themeAwareCircleStyle(isActive: viewModel.isMoreOptionsMenuVisible, isHovering: isButtonHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isButtonHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
                viewModel.isMoreOptionsMenuVisible = true
            } else {
                NSCursor.pop()
                // Delay hiding to allow moving to menu
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !isMenuHovering && !isButtonHovering {
                        viewModel.isMoreOptionsMenuVisible = false
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isMoreOptionsMenuVisible {
                ContextMenuContent(
                    viewModel: viewModel,
                    showMenu: Binding(
                        get: { viewModel.isMoreOptionsMenuVisible },
                        set: { viewModel.isMoreOptionsMenuVisible = $0 }
                    )
                )
                    .retraceMenuContainer()
                    .frame(width: 205)
                    .clipped()
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isMenuHovering = hovering
                        if !hovering {
                            // Delay hiding to allow moving back to button
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if !isMenuHovering && !isButtonHovering {
                                    viewModel.isMoreOptionsMenuVisible = false
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                    .offset(y: -TimelineScaleFactor.controlButtonSize - 8)
            }
        }
        .animation(.easeOut(duration: 0.12), value: viewModel.isMoreOptionsMenuVisible)
    }
}

// MARK: - Instant Tooltip

/// Custom instant tooltip that appears above the view on hover
struct InstantTooltip: ViewModifier {
    let text: String
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(white: 0.11))
                        )
                        .offset(y: -44)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isVisible)
    }
}

extension View {
    func instantTooltip(_ text: String, isVisible: Binding<Bool>) -> some View {
        modifier(InstantTooltip(text: text, isVisible: isVisible))
    }
}

// MARK: - Zoom Slider

/// Custom slider for zoom control with Rewind-style appearance
struct ZoomSlider: View {
    @Binding var value: CGFloat

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbX = value * trackWidth

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 4)

                // Filled portion
                Capsule()
                    .fill(Color.retraceAccent.opacity(0.8))
                    .frame(width: thumbX, height: 4)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: thumbX - (isDragging ? 7 : 5))
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let newValue = gesture.location.x / trackWidth
                        value = max(0, min(1, newValue))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Floating Date Search Panel

/// Elegant floating panel for natural language date/time search
struct FloatingDateSearchPanel: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var enableFrameIDSearch: Bool = false
    @ObservedObject var viewModel: SimpleTimelineViewModel

    @State private var isHovering = false
    @State private var isCalendarButtonHovering = false
    @State private var isSubmitButtonHovering = false
    /// Accumulated position from completed drags
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private var placeholderText: String {
        "e.g. 8 min ago, next Friday, or yesterday 2pm"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and close button - this is the drag handle
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.retraceTinyBold)
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 4)

                Text("Jump to")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.retraceTinyBold)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() }
                else { NSCursor.pop() }
            }

            // Search input field
            HStack(spacing: 14) {
                DateSearchField(
                    text: $text,
                    onSubmit: onSubmit,
                    onCancel: onCancel,
                    placeholder: placeholderText
                )
                .frame(height: 28)

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.retraceHeadline)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                // Submit button
                Button(action: onSubmit) {
                    ZStack {
                        Circle()
                            .fill(text.isEmpty ? Color.white.opacity(0.2) : Color.retraceSubmitAccent.opacity(isSubmitButtonHovering ? 1.0 : 0.8))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
                .onHover { hovering in
                    isSubmitButtonHovering = hovering
                    if hovering && !text.isEmpty { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
            .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                    .fill(RetraceMenuStyle.searchFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            // OR divider
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)

                Text("OR")
                    .font(.retraceTinyBold)
                    .foregroundColor(.white.opacity(0.4))

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Calendar button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.isCalendarPickerVisible = true
                }
                Task {
                    await viewModel.loadDatesWithFrames()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.retraceCalloutMedium)
                    Text("Browse Calendar")
                        .font(.retraceCaptionMedium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isCalendarButtonHovering ? RetraceMenuStyle.actionBlue : RetraceMenuStyle.actionBlue.opacity(0.8))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isCalendarButtonHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.bottom, 16)
        .frame(width: TimelineScaleFactor.searchPanelWidth)
        .retraceMenuContainer(addPadding: false)
        .background(
            ZStack {
                // Remove custom background - now using unified system
                RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .shadow(color: .retraceAccent.opacity(0.1), radius: 60, y: 30)
        .offset(
            x: panelPosition.width + dragOffset.width,
            y: panelPosition.height + dragOffset.height
        )
    }
}

// MARK: - Suggestion Chip

/// Small clickable chip for quick date suggestions
struct SuggestionChip: View {
    let text: String
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.retraceTinyMedium)
                Text(text)
                    .font(.retraceCaption2Medium)
            }
            .foregroundColor(isHovering ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isHovering ? 0.2 : 0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Calendar Picker View

/// Calendar picker with month view and time list - similar to Rewind's design
struct CalendarPickerView: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    @State private var displayedMonth: Date = Date()
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left side: Calendar
            calendarView
                .frame(width: TimelineScaleFactor.calendarPickerWidth)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 20)

            // Right side: Time grid (3 columns)
            timeListView
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.08))

                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .shadow(color: .retraceAccent.opacity(0.1), radius: 60, y: 30)
        .offset(
            x: panelPosition.width + dragOffset.width,
            y: panelPosition.height + dragOffset.height
        )
    }

    // MARK: - Calendar View

    private var calendarView: some View {
        VStack(spacing: 0) {
            // Title header - "Jump to Date & Time"
            HStack {
                Spacer()
                Text("Jump to Date & Time")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() }
                else { NSCursor.pop() }
            }

            // Month navigation row
            HStack {
                // Previous month button
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

                Spacer()

                Text(monthYearString)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                // Next month button
                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.retraceTinyMedium)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Calendar grid
            let days = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    dayCell(for: day)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Time List View

    private var timeListView: some View {
        VStack(spacing: 0) {
            // Spacer to align with calendar title area
            Color.clear.frame(height: 40)

            // Time grid - show all 24 hours in a 3-column grid with proper spacing
            LazyVGrid(
                columns: [
                    GridItem(.fixed(58), spacing: 6),
                    GridItem(.fixed(58), spacing: 6),
                    GridItem(.fixed(58), spacing: 6)
                ],
                spacing: 6
            ) {
                ForEach(0..<24, id: \.self) { hour in
                    let hasFrames = hourHasFrames(hour)
                    TimeSlotButton(
                        hourValue: hour,
                        hasFrames: hasFrames,
                        selectedDate: viewModel.selectedCalendarDate
                    ) {
                        // Use actual timestamp from hoursWithFrames (contains first frame time)
                        if let actualTimestamp = getFirstFrameTimestamp(forHour: hour) {
                            Task {
                                await viewModel.navigateToHour(actualTimestamp)
                            }
                        }
                    }
                    .frame(width: 58)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 210)
        .clipped()
    }

    /// Check if a specific hour has frames for the selected date
    private func hourHasFrames(_ hour: Int) -> Bool {
        guard viewModel.selectedCalendarDate != nil else { return false }
        let cal = Calendar.current
        return viewModel.hoursWithFrames.contains { date in
            cal.component(.hour, from: date) == hour
        }
    }

    /// Get the actual first frame timestamp for a given hour
    private func getFirstFrameTimestamp(forHour hour: Int) -> Date? {
        let cal = Calendar.current
        return viewModel.hoursWithFrames.first { date in
            cal.component(.hour, from: date) == hour
        }
    }

    // MARK: - Day Cell

    private func dayCell(for day: Date?) -> some View {
        Group {
            if let day = day {
                let isToday = calendar.isDateInToday(day)
                let isSelected = viewModel.selectedCalendarDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                let hasFrames = dateHasFrames(day)
                let isCurrentMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)

                Button(action: {
                    if hasFrames {
                        Task {
                            await viewModel.loadHoursForDate(day)
                        }
                    }
                }) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(isToday ? .retraceCaptionBold : .retraceCaption)
                        .foregroundColor(
                            hasFrames
                                ? (isSelected ? .white : .white.opacity(isCurrentMonth ? 0.9 : 0.4))
                                : .white.opacity(isCurrentMonth ? 0.25 : 0.1)
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            ZStack {
                                if isSelected {
                                    Circle()
                                        .fill(RetraceMenuStyle.actionBlue)
                                } else if isToday {
                                    Circle()
                                        .stroke(RetraceMenuStyle.actionBlue, lineWidth: 1.5)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasFrames)
                .onHover { h in
                    if hasFrames {
                        if h { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
            } else {
                Color.clear
                    .frame(width: 32, height: 32)
            }
        }
    }

    // MARK: - Helpers

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedMonth = newMonth
            }
        }
    }

    private func daysInMonth() -> [Date?] {
        var days: [Date?] = []

        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return days
        }

        // Start from the first day of the week containing the first day of the month
        var currentDate = monthFirstWeek.start

        // Generate 6 weeks (42 days) to fill the grid
        for _ in 0..<42 {
            if calendar.isDate(currentDate, equalTo: displayedMonth, toGranularity: .month) {
                days.append(currentDate)
            } else if currentDate < monthInterval.start {
                // Previous month days
                days.append(currentDate)
            } else if days.count < 35 || days.suffix(7).contains(where: { $0 != nil && calendar.isDate($0!, equalTo: displayedMonth, toGranularity: .month) }) {
                // Next month days (only if needed)
                days.append(currentDate)
            } else {
                days.append(nil)
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        return days
    }

    private func dateHasFrames(_ date: Date) -> Bool {
        let startOfDay = calendar.startOfDay(for: date)
        return viewModel.datesWithFrames.contains(startOfDay)
    }
}

// MARK: - Time Slot Button

struct TimeSlotButton: View {
    let hourValue: Int
    let hasFrames: Bool
    let selectedDate: Date?
    let action: () -> Void

    @State private var isHovering = false

    private var timeString: String {
        String(format: "%02d:00", hourValue)
    }

    var body: some View {
        Button(action: action) {
            Text(timeString)
                .font(.retraceMono)
                .foregroundColor(
                    hasFrames
                        ? (isHovering ? .white : .white.opacity(0.9))
                        : .white.opacity(0.25)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            hasFrames
                                ? (isHovering ? RetraceMenuStyle.actionBlue : Color.white.opacity(0.1))
                                : Color.clear
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasFrames)
        .onHover { hovering in
            if hasFrames {
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }
}

// MARK: - Date Search Field

/// Custom text field for date searching with auto-focus
struct DateSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var placeholder: String = "Enter a date or time..."

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 16, weight: .regular)
            ]
        )
        textField.font = .systemFont(ofSize: 16, weight: .regular)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true

        // Wire up Cmd+G to close the panel
        textField.onCancelCallback = onCancel

        // Focus the text field immediately when created
        // Use multiple dispatch levels to ensure focus happens after SwiftUI layout
        focusTextField(textField)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        textField.stringValue = text
        // No focus logic needed here - makeNSView handles initial focus
    }

    /// Robustly focus the text field using multiple attempts with retry logic
    /// for external monitors where NSApp activation is async
    private func focusTextField(_ textField: FocusableTextField, attempt: Int = 1) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(textField, attempt: attempt + 1)
                    }
                }
                return
            }
            self.performFocus(textField, in: window, attempt: attempt)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    /// Actually perform the focus operation with retry for external monitors
    private func performFocus(_ textField: FocusableTextField, in window: NSWindow, attempt: Int) {
        let maxAttempts = 5

        // Activate the app first — required for makeKey to work on external monitors
        // where NSApp.isActive may be false when the panel opens
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        let success = window.makeFirstResponder(textField)

        // Ensure field editor exists for caret to appear
        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        // If the window isn't key yet (activation is async on external monitors),
        // retry so keystrokes actually reach the text field
        if !isKeyAfterMakeKey && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onCancel: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Focusable TextField

/// Custom NSTextField that properly accepts first responder in borderless windows
/// Also intercepts Cmd+G to close the panel
class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    /// Callback to cancel/close the panel
    var onCancelCallback: (() -> Void)?

    /// Callback when the text field is clicked
    var onClickCallback: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClickCallback?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Check for Cmd+G to close the panel
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 5 && modifiers == [.command] { // G key with Command
            onCancelCallback?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}


// MARK: - Timeline Tape Right Click Handler

/// Per-frame right-click handler - knows its exact frame index
struct FrameRightClickHandler: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let frameIndex: Int

    func makeNSView(context: Context) -> FrameRightClickNSView {
        let view = FrameRightClickNSView()
        view.viewModel = viewModel
        view.frameIndex = frameIndex
        return view
    }

    func updateNSView(_ nsView: FrameRightClickNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.frameIndex = frameIndex
    }
}

/// Custom NSView that intercepts right-click events for a specific frame segment
class FrameRightClickNSView: NSView {
    weak var viewModel: SimpleTimelineViewModel?
    var frameIndex: Int = 0

    override func rightMouseDown(with event: NSEvent) {
        handleRightClick(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Check for control-click (which macOS treats as right-click)
        if event.modifierFlags.contains(.control) {
            handleRightClick(with: event)
        }
        // Don't call super - let the event pass through to SwiftUI views underneath
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only capture right-clicks and control-clicks
        guard let event = NSApp.currentEvent else {
            return nil
        }

        if event.type == .rightMouseDown {
            return super.hitTest(point)
        }

        if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
            return super.hitTest(point)
        }

        // Let all other events pass through to SwiftUI views underneath
        return nil
    }

    private func handleRightClick(with event: NSEvent) {
        guard let viewModel = viewModel else { return }

        // Get the parent window's content view size for positioning the menu
        guard let window = self.window,
              let contentView = window.contentView else { return }

        let windowPoint = event.locationInWindow

        // Convert to coordinates relative to the full content area
        let contentHeight = contentView.bounds.height
        let menuLocation = CGPoint(
            x: windowPoint.x,
            y: contentHeight - windowPoint.y // Flip Y coordinate for SwiftUI
        )

        // Use the frame index this handler was created with - no offset calculation needed!
        DispatchQueue.main.async {
            // Reset submenu state when opening a new context menu
            viewModel.showTagSubmenu = false
            viewModel.isHoveringAddTagButton = false
            viewModel.selectedSegmentTags = []

            // Update to new location/frame
            viewModel.timelineContextMenuSegmentIndex = self.frameIndex
            viewModel.timelineContextMenuLocation = menuLocation
            viewModel.selectedFrameIndex = self.frameIndex  // Highlight the right-clicked block
            viewModel.showTimelineContextMenu = true
            Task { await viewModel.loadTags() }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TimelineTapeView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let wrapper = AppCoordinatorWrapper(coordinator: coordinator)
        ZStack {
            Color.black
            TimelineTapeView(
                viewModel: SimpleTimelineViewModel(coordinator: coordinator),
                width: 800,
                coordinator: coordinator
            )
            .environmentObject(wrapper)
        }
        .frame(width: 800, height: 100)
    }
}
#endif

// MARK: - Hidden Segment Overlay

/// Visual indicator for hidden segments - diagonal stripe pattern
struct HiddenSegmentOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let stripeWidth: CGFloat = 3
                let spacing: CGFloat = 6
                let color = Color.white.opacity(0.3)

                // Draw diagonal stripes from bottom-left to top-right
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: .color(color), lineWidth: stripeWidth)
                    x += spacing + stripeWidth
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Gap Hatch Pattern

/// Hatched pattern for gap indicators - subtle diagonal stripes
struct GapHatchPattern: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let stripeWidth: CGFloat = 1
                let spacing: CGFloat = 5
                let color = Color.white.opacity(0.1)

                // Draw diagonal stripes
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: .color(color), lineWidth: stripeWidth)
                    x += spacing + stripeWidth
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Theme-aware Control Button Style

/// Shared UserDefaults store for accessing settings
private let timelineSettingsStore = UserDefaults(suiteName: "io.retrace.app")

/// View modifier that applies theme-based border styling to circular control buttons
struct ThemeAwareCircleButtonStyle: ViewModifier {
    let isActive: Bool
    let isHovering: Bool

    // Track theme changes to trigger view updates
    @State private var theme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()

    private var showColoredBorders: Bool {
        timelineSettingsStore?.bool(forKey: "timelineColoredBorders") ?? false
    }

    func body(content: Content) -> some View {
        content
            .background(
                Circle()
                    .fill(isActive ? Color.white.opacity(0.15) : Color(white: 0.15))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isActive)
            )
            .overlay(
                Circle()
                    .stroke(showColoredBorders ? theme.controlBorderColor : Color.white.opacity(0.15), lineWidth: 1.0)
            )
            .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { notification in
                if let newTheme = notification.object as? MilestoneCelebrationManager.ColorTheme {
                    theme = newTheme
                }
            }
    }
}

/// View modifier that applies theme-based border styling to capsule control buttons
struct ThemeAwareCapsuleButtonStyle: ViewModifier {
    let isActive: Bool
    let isHovering: Bool

    // Track theme changes to trigger view updates
    @State private var theme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()

    private var showColoredBorders: Bool {
        timelineSettingsStore?.bool(forKey: "timelineColoredBorders") ?? false
    }

    func body(content: Content) -> some View {
        content
            .background(
                Capsule()
                    .fill(isActive || isHovering ? Color(white: 0.2) : Color(white: 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(showColoredBorders ? theme.controlBorderColor : Color.white.opacity(0.15), lineWidth: 1.0)
            )
            .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { notification in
                if let newTheme = notification.object as? MilestoneCelebrationManager.ColorTheme {
                    theme = newTheme
                }
            }
    }
}

extension View {
    /// Apply theme-based styling to circular control buttons
    /// Set useCapsule to true to use capsule shape instead of circle (for expandable buttons)
    func themeAwareCircleStyle(isActive: Bool = false, isHovering: Bool = false, useCapsule: Bool = false) -> some View {
        if useCapsule {
            return AnyView(modifier(ThemeAwareCapsuleButtonStyle(isActive: isActive, isHovering: isHovering)))
        } else {
            return AnyView(modifier(ThemeAwareCircleButtonStyle(isActive: isActive, isHovering: isHovering)))
        }
    }

    /// Apply theme-based styling to capsule control buttons
    func themeAwareCapsuleStyle(isActive: Bool = false, isHovering: Bool = false) -> some View {
        modifier(ThemeAwareCapsuleButtonStyle(isActive: isActive, isHovering: isHovering))
    }
}
