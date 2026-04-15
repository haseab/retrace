import Foundation
import SwiftUI
import Shared
import App

struct TimelineSurfaceOverlayLayer: View {
    let coordinator: AppCoordinator
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isCommentSubmenuMounted: Bool
    let commentSubmenuVisibility: Double

    var body: some View {
        Group {
            if viewModel.isLoading {
                TimelineLoadingOverlay()
            }

            if let error = viewModel.error {
                TimelineErrorOverlay(message: error)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.error)
            }

            if viewModel.showDeleteConfirmation {
                DeleteConfirmationDialog(
                    segmentFrameCount: viewModel.selectedSegmentFrameCount,
                    onDeleteFrame: {
                        viewModel.confirmDeleteSelectedFrame()
                    },
                    onDeleteSegment: {
                        viewModel.confirmDeleteSegment()
                    },
                    onCancel: {
                        viewModel.cancelDelete()
                    }
                )
            }

            if viewModel.isSearchOverlayVisible {
                SpotlightSearchOverlay(
                    coordinator: coordinator,
                    viewModel: viewModel.searchViewModel,
                    onResultSelected: { result, query in
                        Task {
                            await viewModel.navigateToSearchResult(
                                frameID: result.id,
                                timestamp: result.timestamp,
                                highlightQuery: query
                            )
                        }
                    },
                    onDismiss: {
                        viewModel.closeSearchOverlay()
                    }
                )
            }

            if viewModel.showOCRDebugOverlay {
                OCRDebugOverlay(
                    viewModel: viewModel,
                    containerSize: containerSize,
                    actualFrameRect: actualFrameRect
                )
                .scaleEffect(viewModel.frameZoomScale)
                .offset(viewModel.frameZoomOffset)
            }

            if viewModel.isFilterPanelVisible {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if viewModel.activeFilterDropdown != .none {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissFilterDropdown()
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissFilterPanel()
                            }
                        }
                    }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        FilterPanel(viewModel: viewModel)
                            .fixedSize()
                    }
                }
                .padding(.trailing, containerSize.width / 2 + TimelineScaleFactor.controlSpacing + 60)
                .padding(.bottom, TimelineScaleFactor.tapeBottomPadding + TimelineScaleFactor.tapeHeight + 75)
                .transition(.opacity.combined(with: .offset(y: 10)))

                FilterDropdownOverlay(viewModel: viewModel)
            }

            if viewModel.showTimelineContextMenu {
                let timelineContextMenuBinding = Binding(
                    get: { viewModel.showTimelineContextMenu },
                    set: { viewModel.setTimelineContextMenuVisible($0) }
                )
                TimelineSegmentContextMenu(
                    viewModel: viewModel,
                    isPresented: timelineContextMenuBinding,
                    location: viewModel.timelineContextMenuLocation,
                    containerSize: containerSize
                )
            }

            TimelineCommentSubmenuOverlay(
                viewModel: viewModel,
                isMounted: isCommentSubmenuMounted,
                visibility: commentSubmenuVisibility,
                availableWidth: containerSize.width
            )
        }
    }
}

struct TimelineFeedbackOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let topSafeAreaInset: CGFloat

    var body: some View {
        Group {
            if let message = viewModel.toastMessage {
                TimelineToastOverlay(
                    message: message,
                    icon: viewModel.toastIcon,
                    isError: viewModel.toastTone == .error,
                    isVisible: viewModel.toastVisible
                )
            }

            if let undoMessage = viewModel.pendingDeleteUndoMessage {
                TimelinePendingDeleteUndoBanner(
                    message: undoMessage,
                    topSafeAreaInset: topSafeAreaInset,
                    onUndo: { viewModel.undoPendingDelete() },
                    onDismiss: { viewModel.dismissPendingDeleteUndo() }
                )
            }
        }
    }
}

private struct TimelineLoadingOverlay: View {
    var body: some View {
        VStack(spacing: .spacingM) {
            SpinnerView(size: 32, lineWidth: 3, color: .white)
            Text("Loading...")
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

private struct TimelineErrorOverlay: View {
    let message: String

    var body: some View {
        let accentColor = Color.orange

        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(accentColor)
            Text(message)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accentColor.opacity(0.35), lineWidth: 1)
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
    }
}

private struct TimelineToastOverlay: View {
    let message: String
    let icon: String?
    let isError: Bool
    let isVisible: Bool

    private var accentColor: Color {
        isError ? .red : .green
    }

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                Text(message)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.5))
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accentColor.opacity(0.35), lineWidth: 1)
                }
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .scaleEffect(isVisible ? 1.0 : 0.85)
            .opacity(isVisible ? 1.0 : 0.0)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

private struct TimelinePendingDeleteUndoBanner: View {
    let message: String
    let topSafeAreaInset: CGFloat
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.95))

                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                Button("Undo") {
                    onUndo()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.26), lineWidth: 1)
                )

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.68))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .padding(.top, max(topSafeAreaInset + 18, 56))
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: message)
    }
}

struct ControlsHiddenRestoreHintBanner: View {
    let onDismiss: () -> Void
    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        TimelineHintBanner(style: .capsule, scale: scale, onDismiss: onDismiss) {
            Image(systemName: "menubar.arrow.down.rectangle")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            Text("Controls hidden")
                .font(.system(size: 15 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.92))

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: 16 * scale)

            KeyboardBadge(symbol: "Right-click")

            Text("on screen to bring them back")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.76))
        }
    }
}

struct PositionRecoveryHintBanner: View {
    let onDismiss: () -> Void
    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        TimelineHintBanner(style: .capsule, scale: scale, onDismiss: onDismiss) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            Text("Lost your place?")
                .font(.system(size: 15 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.92))

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: 16 * scale)

            Text("Press")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.76))

            KeyboardBadge(symbol: "⌘ Z")

            Text("to return to your previous position")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.76))
        }
    }
}

struct TextSelectionHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        TimelineHintBanner(style: .card, onDismiss: onDismiss) {
            Image(systemName: "info.circle.fill")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            Text("Selecting text?")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            HStack(spacing: 4) {
                Text("Try Area Selection")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.75))
                KeyboardBadge(symbol: "⇧ Shift")
                Text("+")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                KeyboardBadge(symbol: "⊹ Drag")
                Text("OR")
                    .font(.retraceCaption2Bold)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 2)
                Text("Box Selection")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.75))
                KeyboardBadge(symbol: "⌘ Cmd")
                Text("+")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                KeyboardBadge(symbol: "⊹ Drag")
            }
        }
    }
}

struct SearchResultNavigationToast: View {
    let state: SearchViewModel.ResultNavigationState
    let onNavigatePrevious: () -> Void
    let onNavigateNext: () -> Void
    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        VStack(alignment: .center, spacing: 10 * scale) {
            HStack(spacing: 10 * scale) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 16 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                Text("\(state.currentPosition) of \(state.loadedCount)\(state.canLoadMore || state.isLoadingMore ? "+" : "")")
                    .font(.system(size: 15 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .monospacedDigit()
            }

            HStack(spacing: 10 * scale) {
                SearchResultNavigationButton(
                    systemImage: "chevron.left",
                    isDisabled: !state.canNavigatePrevious,
                    tooltipText: "⌘ ⇧ ←",
                    scale: scale,
                    action: onNavigatePrevious
                )

                SearchResultNavigationButton(
                    systemImage: "chevron.right",
                    isDisabled: !state.canNavigateNext && !state.canLoadMore,
                    tooltipText: "⌘ ⇧ →",
                    scale: scale,
                    action: onNavigateNext
                )
            }

            if state.isLoadingMore {
                HStack(spacing: 6 * scale) {
                    SpinnerView(size: 12 * scale, lineWidth: 1.8, color: .white.opacity(0.85))
                    Text("Loading more")
                        .font(.system(size: 14 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.76))
                }
            }
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 12 * scale)
        .background(
            RoundedRectangle(cornerRadius: 18 * scale)
                .fill(Color.black.opacity(0.72))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18 * scale)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct SearchResultNavigationButton: View {
    let systemImage: String
    let isDisabled: Bool
    let tooltipText: String
    var scale: CGFloat = 1
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isDisabled ? 0.38 : 0.88))
                .frame(width: 34 * scale, height: 34 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 10 * scale)
                        .fill(buttonBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10 * scale)
                        .stroke(Color.white.opacity(isDisabled ? 0.08 : 0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .instantTooltip(tooltipText, isVisible: $isHovering)
        .onHover { hovering in
            isHovering = !isDisabled && hovering
        }
        .onChange(of: isDisabled) { disabled in
            if disabled {
                isHovering = false
            }
        }
        .onDisappear {
            isHovering = false
        }
    }

    private var buttonBackgroundColor: Color {
        isDisabled ? Color.white.opacity(0.04) : Color.white.opacity(isHovering ? 0.18 : 0.1)
    }
}

struct SearchHighlightControlsHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        TimelineHintBanner(style: .card, onDismiss: onDismiss) {
            Image(systemName: "lightbulb.fill")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            Text("Highlighted text is under timeline controls.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text("Press")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

            KeyboardBadge(symbol: "⌘ H")

            Text("to hide/show controls, or right-click.")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

struct TimelineTapeRightClickHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        TimelineHintBanner(style: .card, onDismiss: onDismiss) {
            Image(systemName: "lightbulb.fill")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            Text("Hint: You can also right-click the timeline tape to open the same tape menu!")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text("")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))
                .hidden()
        }
    }
}

struct ScrollOrientationHintBanner: View {
    let currentOrientation: String
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    private var isHorizontal: Bool { currentOrientation == "horizontal" }
    @State private var isSwitchHovered = false

    var body: some View {
        TimelineHintBanner(style: .card, onDismiss: onDismiss) {
            Image(systemName: isHorizontal ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            Text(isHorizontal ? "Vertical scrolling detected." : "Horizontal scrolling detected.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text(isHorizontal ? "Timeline is currently set to Left/Right." : "Timeline is currently set to Up/Down.")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

            Button(action: onSwitch) {
                Text(isHorizontal ? "Switch to Up/Down" : "Switch to Left/Right")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.retraceSubmitAccent.opacity(isSwitchHovered ? 0.42 : 0.32))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(isSwitchHovered ? 0.45 : 0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isSwitchHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

struct TimelineHintOverlayStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        VStack(spacing: 10 * scale) {
            content()
        }
        .padding(.top, 60)
        .padding(.horizontal, .spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private enum TimelineHintBannerStyle {
    case capsule
    case card
}

private struct TimelineHintBanner<Content: View>: View {
    let style: TimelineHintBannerStyle
    var scale: CGFloat = 1
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12 * scale) {
            content()

            if let onDismiss {
                TimelineHintDismissButton(scale: scale, onDismiss: onDismiss)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(backgroundShape)
        .overlay(borderShape)
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .capsule:
            18 * scale
        case .card:
            16
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .capsule:
            10 * scale
        case .card:
            10
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        switch style {
        case .capsule:
            Capsule()
                .fill(Color.black.opacity(0.72))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        case .card:
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.2).opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var borderShape: some View {
        switch style {
        case .capsule:
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        case .card:
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct TimelineHintDismissButton: View {
    var scale: CGFloat = 1
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundColor(.white.opacity(isHovering ? 0.88 : 0.66))
                .frame(width: 24 * scale, height: 24 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.16 : 0.1))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct RedactionReasonBanner: View {
    let reason: String
    let appBundleID: String?

    var body: some View {
        HStack(spacing: 10) {
            if let appBundleID, !appBundleID.isEmpty {
                AppIconView(bundleID: appBundleID, size: 18)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "eye.slash.fill")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(Color.orange.opacity(0.95))
            }

            Text("Redacted")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.95))

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1, height: 14)

            Text(reason)
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 680)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.13).opacity(0.94))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .allowsHitTesting(false)
        .help("Current frame is redacted")
    }
}

private struct KeyboardBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.retraceCaption2Medium)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
    }
}
