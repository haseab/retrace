import SwiftUI
import AppKit
import Shared
import App

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

            if viewModel.activeFilterCount > 0 {
                Button(action: {
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
        .instantTooltip(viewModel.activeFilterCount > 0 && isBadgeHovering ? "Clear filters" : "Filter (⌘⇧F)", isVisible: .constant(isHovering || isBadgeHovering))
    }
}

struct FilterAndPeekGroup: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    private var showPeekButton: Bool {
        viewModel.activeFilterCount > 0 || viewModel.isPeeking
    }

    private let spacing: CGFloat = 6

    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Color.white.opacity(showPeekButton ? 0.08 : 0))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(showPeekButton ? 0.15 : 0), lineWidth: 0.5)
                )
                .frame(
                    width: showPeekButton
                        ? (TimelineScaleFactor.controlButtonSize * 2 + spacing + 8)
                        : TimelineScaleFactor.controlButtonSize,
                    height: TimelineScaleFactor.controlButtonSize + (showPeekButton ? 8 : 0)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPeekButton)

            FilterButton(viewModel: viewModel)
                .padding(showPeekButton ? 4 : 0)

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
            width: TimelineScaleFactor.controlButtonSize * 2 + spacing + 8,
            alignment: .trailing
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPeekButton)
    }
}

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

struct SearchButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    @State private var isHovering = false

    private var displayText: String {
        let query = viewModel.searchViewModel.searchQuery
        return query.isEmpty ? "Search" : query
    }

    private var hasSearchQuery: Bool {
        !viewModel.searchViewModel.searchQuery.isEmpty
    }

    var body: some View {
        Button(action: {
            viewModel.dismissContextMenu()
            Log.info("[TimelineShortcut] Search button clicked", category: .ui)
            viewModel.openSearchOverlay(recentEntriesRevealDelay: 0.3)
            DashboardViewModel.recordSearchDialogOpen(coordinator: coordinatorWrapper.coordinator)
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
                viewModel.setMoreOptionsMenuVisible(true)
            } else {
                NSCursor.pop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !isMenuHovering && !isButtonHovering {
                        viewModel.setMoreOptionsMenuVisible(false)
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
                        set: { viewModel.setMoreOptionsMenuVisible($0) }
                    )
                )
                .retraceMenuContainer()
                .frame(width: 272)
                .clipped()
                .contentShape(Rectangle())
                .onHover { hovering in
                    isMenuHovering = hovering
                    if !hovering {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if !isMenuHovering && !isButtonHovering {
                                viewModel.setMoreOptionsMenuVisible(false)
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

enum TimelineHoverTooltipStyle {
    static let fontSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    static let backgroundColor = Color(white: 0.11)

    static var font: Font {
        .system(size: fontSize, weight: .medium)
    }

    static var height: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading + (verticalPadding * 2))
    }

    static func width(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width + (horizontalPadding * 2))
    }
}

enum InstantTooltipPlacement {
    case top
    case bottom
}

struct InstantTooltip: ViewModifier {
    let text: String
    @Binding var isVisible: Bool
    let placement: InstantTooltipPlacement

    private var alignment: Alignment {
        switch placement {
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }

    private var verticalOffset: CGFloat {
        switch placement {
        case .top:
            return -44
        case .bottom:
            return 44
        }
    }

    private var transitionYOffset: CGFloat {
        switch placement {
        case .top:
            return 4
        case .bottom:
            return -4
        }
    }

    func body(content: Content) -> some View {
        content
            .zIndex(isVisible ? 1 : 0)
            .overlay(alignment: alignment) {
                if isVisible {
                    Text(text)
                        .font(TimelineHoverTooltipStyle.font)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, TimelineHoverTooltipStyle.horizontalPadding)
                        .padding(.vertical, TimelineHoverTooltipStyle.verticalPadding)
                        .background(
                            Capsule()
                                .fill(TimelineHoverTooltipStyle.backgroundColor)
                        )
                        .offset(y: verticalOffset)
                        .transition(.opacity.combined(with: .offset(y: transitionYOffset)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isVisible)
    }
}

extension View {
    func instantTooltip(
        _ text: String,
        isVisible: Binding<Bool>,
        placement: InstantTooltipPlacement = .top
    ) -> some View {
        modifier(InstantTooltip(text: text, isVisible: isVisible, placement: placement))
    }
}

struct ZoomSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(geometry.size.width, 1)
            let clampedValue = min(max(value, range.lowerBound), range.upperBound)
            let progress = (clampedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = progress * trackWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.retraceAccent.opacity(0.8))
                    .frame(width: thumbX, height: 4)

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
                        let clampedProgress = max(0, min(1, gesture.location.x / trackWidth))
                        value = range.lowerBound + (clampedProgress * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }
}

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

class FrameRightClickNSView: NSView {
    weak var viewModel: SimpleTimelineViewModel?
    var frameIndex: Int = 0

    override func rightMouseDown(with event: NSEvent) {
        handleRightClick(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            handleRightClick(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else {
            return nil
        }

        if event.type == .rightMouseDown {
            return super.hitTest(point)
        }

        if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
            return super.hitTest(point)
        }

        return nil
    }

    private func handleRightClick(with event: NSEvent) {
        guard let viewModel = viewModel else { return }
        guard let window = self.window,
              let contentView = window.contentView else { return }

        let windowPoint = event.locationInWindow
        let contentHeight = contentView.bounds.height
        let menuLocation = CGPoint(
            x: windowPoint.x,
            y: contentHeight - windowPoint.y
        )

        DispatchQueue.main.async {
            viewModel.openTimelineContextMenu(at: self.frameIndex, menuLocation: menuLocation)
        }
    }
}

struct HiddenSegmentOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let stripeWidth: CGFloat = 3
                let spacing: CGFloat = 6
                let color = Color.white.opacity(0.3)

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

struct GapHatchPattern: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let stripeWidth: CGFloat = 1
                let spacing: CGFloat = 5
                let color = Color.white.opacity(0.1)

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

private let timelineSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

struct ThemeAwareCircleButtonStyle: ViewModifier {
    let isActive: Bool
    let isHovering: Bool

    @State private var theme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()

    private var showColoredBorders: Bool {
        timelineSettingsStore.bool(forKey: "timelineColoredBorders")
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

struct ThemeAwareCapsuleButtonStyle: ViewModifier {
    let isActive: Bool
    let isHovering: Bool

    @State private var theme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()

    private var showColoredBorders: Bool {
        timelineSettingsStore.bool(forKey: "timelineColoredBorders")
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
    func themeAwareCircleStyle(isActive: Bool = false, isHovering: Bool = false, useCapsule: Bool = false) -> some View {
        if useCapsule {
            return AnyView(modifier(ThemeAwareCapsuleButtonStyle(isActive: isActive, isHovering: isHovering)))
        } else {
            return AnyView(modifier(ThemeAwareCircleButtonStyle(isActive: isActive, isHovering: isHovering)))
        }
    }

    func themeAwareCapsuleStyle(isActive: Bool = false, isHovering: Bool = false) -> some View {
        modifier(ThemeAwareCapsuleButtonStyle(isActive: isActive, isHovering: isHovering))
    }
}

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
