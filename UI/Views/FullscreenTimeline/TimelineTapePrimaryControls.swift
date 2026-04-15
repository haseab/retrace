import SwiftUI
import AppKit
import Shared
import App

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
                    if abs(frameIndex - viewModel.currentIndex) < 40 {
                        FrameRightClickHandler(viewModel: viewModel, frameIndex: frameIndex)
                    }
                }
            )
    }
}

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
        .instantTooltip("Go to Date & Time (⌘G)", isVisible: $isHovering)
    }
}

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
        Button(action: {
            viewModel.dismissContextMenu()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.togglePlayback()
            }
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
}

fileprivate struct TimelineTapePlayheadLayoutState {
    let centerX: CGFloat
    let controlsY: CGFloat
    let middleSideControlsWidth: CGFloat
    let searchButtonX: CGFloat
    let rightControlsCenterX: CGFloat
    let rightControlsWidth: CGFloat
    let playheadLineY: CGFloat
    let searchPanelY: CGFloat
    let calendarPickerY: CGFloat

    init(containerWidth: CGFloat, showVideoControls: Bool, tapeHeight: CGFloat) {
        let videoControlsWidth = showVideoControls
            ? TimelineScaleFactor.controlButtonSize + TimelineScaleFactor.controlSpacing
            : 0
        let controlClusterWidth = TimelineScaleFactor.controlButtonSize * 2 + 6 + 8 + videoControlsWidth
        let rightClusterWidth = (TimelineScaleFactor.controlButtonSize * 4)
            + (TimelineScaleFactor.controlSpacing * 3)
            + 8
        centerX = containerWidth / 2
        controlsY = TimelineScaleFactor.controlsYOffset
        middleSideControlsWidth = controlClusterWidth
        searchButtonX = TimelineScaleFactor.leftControlsX
        rightControlsWidth = rightClusterWidth
        rightControlsCenterX = containerWidth
            - TimelineScaleFactor.rightControlsXOffset
            - (TimelineScaleFactor.controlButtonSize + TimelineScaleFactor.controlSpacing) / 2
        playheadLineY = tapeHeight / 2
        searchPanelY = TimelineScaleFactor.searchPanelYOffset
        calendarPickerY = TimelineScaleFactor.calendarPickerYOffset
    }
}

extension TimelineTapeView {
    var playhead: some View {
        let tapeHeight = TimelineScaleFactor.tapeHeight
        return GeometryReader { geometry in
            TimelineTapePlayheadOverlay(
                viewModel: viewModel,
                tapeHeight: tapeHeight,
                layout: TimelineTapePlayheadLayoutState(
                    containerWidth: geometry.size.width,
                    showVideoControls: viewModel.showVideoControls,
                    tapeHeight: tapeHeight
                )
            )
        }
    }
}

private struct TimelineTapePlayheadOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let tapeHeight: CGFloat
    let layout: TimelineTapePlayheadLayoutState

    var body: some View {
        ZStack {
            TimelineTapeCenterControls(
                viewModel: viewModel,
                middleSideControlsWidth: layout.middleSideControlsWidth
            )
            .position(x: layout.centerX, y: layout.controlsY)

            SearchButton(viewModel: viewModel)
                .opacity(viewModel.isSearchOverlayVisible ? 0 : 1)
                .scaleEffect(viewModel.isSearchOverlayVisible ? 0.8 : 1.0)
                .animation(.easeOut(duration: 0.15), value: viewModel.isSearchOverlayVisible)
                .position(x: layout.searchButtonX, y: layout.controlsY)

            HStack(spacing: TimelineScaleFactor.controlSpacing) {
                CurrentAppBadge(viewModel: viewModel)
                MoreOptionsMenu(viewModel: viewModel)
            }
            .padding(4)
            .frame(width: layout.rightControlsWidth, alignment: .trailing)
            .position(x: layout.rightControlsCenterX, y: layout.controlsY)

            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                .fill(Color.white)
                .frame(width: TimelineScaleFactor.playheadWidth, height: tapeHeight * 2.5)
                .position(x: layout.centerX, y: layout.playheadLineY)

            TimelineTapeDateJumpOverlayHost(
                viewModel: viewModel,
                centerX: layout.centerX,
                searchPanelY: layout.searchPanelY,
                calendarPickerY: layout.calendarPickerY
            )
        }
    }
}

private struct TimelineTapeCenterControls: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let middleSideControlsWidth: CGFloat

    var body: some View {
        HStack(spacing: TimelineScaleFactor.controlSpacing) {
            FilterAndPeekGroup(viewModel: viewModel)
                .frame(width: middleSideControlsWidth, alignment: .trailing)

            DatetimeButton(viewModel: viewModel)

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
    }
}

private struct TimelineTapeDateJumpOverlayHost: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let centerX: CGFloat
    let searchPanelY: CGFloat
    let calendarPickerY: CGFloat

    var body: some View {
        Group {
            if viewModel.isDateSearchActive && !viewModel.isCalendarPickerVisible {
                FloatingDateSearchPanel(
                    text: Binding(
                        get: { viewModel.dateSearchText },
                        set: { viewModel.dateSearchText = $0 }
                    ),
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
                .position(x: centerX, y: searchPanelY)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }

            if viewModel.isCalendarPickerVisible {
                CalendarPickerView(viewModel: viewModel)
                    .position(x: centerX, y: calendarPickerY)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
    }
}

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

struct CurrentAppBadge: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var expandTask: Task<Void, Never>?

    private let buttonSize = TimelineScaleFactor.controlButtonSize * 1.125
    private let baseIconSize = TimelineScaleFactor.controlButtonSize * 0.95
    private let expandedIconSize = TimelineScaleFactor.controlButtonSize * 0.88

    private var currentBundleID: String? {
        viewModel.currentFrame?.metadata.appBundleID
    }

    private var currentBrowserURL: String? {
        viewModel.currentFrame?.metadata.browserURL
    }

    var hasOpenableURL: Bool {
        guard let urlString = currentBrowserURL, !urlString.isEmpty else { return false }
        return URL(string: urlString) != nil
    }

    private var currentRedactionReason: String? {
        guard let reason = viewModel.currentFrame?.metadata.redactionReason,
              !reason.isEmpty else {
            return nil
        }
        return reason
    }

    private var isCurrentFrameRedacted: Bool {
        currentRedactionReason != nil
    }

    private var shouldShowExpanded: Bool {
        (isExpanded || isHovering) && !viewModel.isActivelyScrolling && (hasOpenableURL || isCurrentFrameRedacted)
    }

    private var expandedLabel: String {
        isCurrentFrameRedacted ? "Redacted" : "Open"
    }

    private var expandedWidth: CGFloat {
        TimelineScaleFactor.controlButtonSize * 3.0
    }

    private var iconSize: CGFloat {
        shouldShowExpanded ? expandedIconSize : baseIconSize
    }

    var body: some View {
        Group {
            if let bundleID = currentBundleID, hasOpenableURL || isCurrentFrameRedacted {
                Button(action: {
                    if hasOpenableURL, viewModel.openCurrentBrowserURL() {
                        TimelineWindowController.shared.hide(restorePreviousFocus: false)
                    }
                }) {
                    ZStack(alignment: .trailing) {
                        Color.clear
                            .frame(width: expandedWidth, height: buttonSize)

                        HStack(spacing: 8) {
                            if shouldShowExpanded {
                                Text(expandedLabel)
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
                .help(currentRedactionReason.map { "Redacted: \($0)" } ?? "Open current URL")
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
                .instantTooltip("Open Link (⌘⇧L)", isVisible: .constant(isHovering))
                .id(bundleID)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shouldShowExpanded)
        .animation(.easeInOut(duration: 0.2), value: currentBundleID)
        .onChange(of: viewModel.isActivelyScrolling) { isScrolling in
            if isScrolling {
                expandTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded = false
                }
            } else if hasOpenableURL {
                expandTask?.cancel()
                expandTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(650_000_000)), clock: .continuous)
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
                expandTask?.cancel()
                isExpanded = false
            } else if !viewModel.isActivelyScrolling {
                expandTask?.cancel()
                expandTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(650_000_000)), clock: .continuous)
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
            if hasOpenableURL && !viewModel.isActivelyScrolling {
                expandTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(650_000_000)), clock: .continuous)
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

struct ZoomControl: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    private var showTooltip: Bool {
        isHovering && !viewModel.isZoomSliderExpanded
    }

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            let animation: Animation = viewModel.isZoomSliderExpanded ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8)
            withAnimation(animation) {
                viewModel.toggleZoomSliderExpanded()
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
            if viewModel.isZoomSliderExpanded {
                HStack(spacing: TimelineScaleFactor.iconSpacing) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: TimelineScaleFactor.fontCaption2, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    ZoomSlider(
                        value: Binding(
                            get: { viewModel.zoomLevel },
                            set: { viewModel.zoomLevel = $0 }
                        ),
                        range: 0...TimelineConfig.maxZoomLevel
                    )
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
                .offset(x: -TimelineScaleFactor.controlButtonSize - 8)
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
