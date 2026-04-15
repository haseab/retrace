import Foundation
import SwiftUI
import Shared

extension Notification.Name {
    static let showFrameContextMenu = Notification.Name("showFrameContextMenu")
}

struct RightClickOverlay: ViewModifier {
    final class HyperlinkMenuTarget: NSObject {
        var match: OCRHyperlinkMatch?
        var onCopyHyperlink: (OCRHyperlinkMatch) -> Void = { _ in }

        @objc func copyLinkAction(_ sender: Any?) {
            guard let match else { return }
            onCopyHyperlink(match)
        }
    }

    final class RedactionMenuTarget: NSObject {
        var node: OCRNodeWithText?
        var onToggleReveal: (OCRNodeWithText) -> Void = { _ in }

        @objc func toggleRevealAction(_ sender: Any?) {
            guard let node else { return }
            onToggleReveal(node)
        }
    }

    final class MonitorState: ObservableObject {
        var hyperlinkEntries: [HyperlinkContextMenuEntry] = []
        var redactionEntries: [RedactedNodeContextMenuEntry] = []
        var onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void = { _ in }
        var onCopyHyperlink: (OCRHyperlinkMatch) -> Void = { _ in }
        var onRedactionRevealToggle: (OCRNodeWithText) -> Void = { _ in }
        var onRightClick: (CGPoint) -> Void = { _ in }
        var viewBounds: CGRect = .zero
        let hyperlinkMenuTarget = HyperlinkMenuTarget()
        let redactionMenuTarget = RedactionMenuTarget()
    }

    struct MonitorStateSyncView: NSViewRepresentable {
        let monitorState: MonitorState
        let hyperlinkEntries: [HyperlinkContextMenuEntry]
        let redactionEntries: [RedactedNodeContextMenuEntry]
        let onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void
        let onHyperlinkCopy: (OCRHyperlinkMatch) -> Void
        let onRedactionRevealToggle: (OCRNodeWithText) -> Void
        let onRightClick: (CGPoint) -> Void
        let viewBounds: CGRect

        func makeNSView(context: Context) -> NSView {
            NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            monitorState.hyperlinkEntries = hyperlinkEntries
            monitorState.redactionEntries = redactionEntries
            monitorState.onHyperlinkRightClick = onHyperlinkRightClick
            monitorState.onCopyHyperlink = onHyperlinkCopy
            monitorState.onRedactionRevealToggle = onRedactionRevealToggle
            monitorState.onRightClick = onRightClick
            monitorState.viewBounds = viewBounds
        }
    }

    let hyperlinkEntries: [HyperlinkContextMenuEntry]
    let redactionEntries: [RedactedNodeContextMenuEntry]
    let onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void
    let onHyperlinkCopy: (OCRHyperlinkMatch) -> Void
    let onRedactionRevealToggle: (OCRNodeWithText) -> Void
    let onRightClick: (CGPoint) -> Void
    @State private var eventMonitor: Any?
    @State private var viewBounds: CGRect = .zero
    @StateObject private var monitorState = MonitorState()

    private var timelineExclusionHeight: CGFloat {
        TimelineScaleFactor.tapeHeight + TimelineScaleFactor.tapeBottomPadding + 20
    }

    func body(content: Content) -> some View {
        content
            .background(
                MonitorStateSyncView(
                    monitorState: monitorState,
                    hyperlinkEntries: hyperlinkEntries,
                    redactionEntries: redactionEntries,
                    onHyperlinkRightClick: onHyperlinkRightClick,
                    onHyperlinkCopy: onHyperlinkCopy,
                    onRedactionRevealToggle: onRedactionRevealToggle,
                    onRightClick: onRightClick,
                    viewBounds: viewBounds
                )
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            updateViewBoundsIfNeeded(geo.frame(in: .global))
                        }
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            updateViewBoundsIfNeeded(newFrame)
                        }
                }
            )
            .onAppear {
                syncMonitorState()
                setupEventMonitor()
            }
            .onDisappear {
                removeEventMonitor()
            }
    }

    private func updateViewBoundsIfNeeded(_ newFrame: CGRect) {
        let epsilon: CGFloat = 0.5
        let hasMeaningfulDelta =
            abs(viewBounds.minX - newFrame.minX) > epsilon ||
            abs(viewBounds.minY - newFrame.minY) > epsilon ||
            abs(viewBounds.width - newFrame.width) > epsilon ||
            abs(viewBounds.height - newFrame.height) > epsilon

        if hasMeaningfulDelta || viewBounds == .zero {
            viewBounds = newFrame
            monitorState.viewBounds = newFrame
        }
    }

    private func syncMonitorState() {
        monitorState.hyperlinkEntries = hyperlinkEntries
        monitorState.redactionEntries = redactionEntries
        monitorState.onHyperlinkRightClick = onHyperlinkRightClick
        monitorState.onCopyHyperlink = onHyperlinkCopy
        monitorState.onRedactionRevealToggle = onRedactionRevealToggle
        monitorState.onRightClick = onRightClick
        monitorState.viewBounds = viewBounds
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window else { return event }

            if FocusableTextInputSupport.shouldDeferRightClickToTextInput(window: window, event: event) {
                return event
            }

            let windowLocation = event.locationInWindow
            let swiftUILocation = CGPoint(x: windowLocation.x, y: window.frame.height - windowLocation.y)
            let currentViewBounds = monitorState.viewBounds

            if currentViewBounds.contains(swiftUILocation) {
                let localPoint = CGPoint(
                    x: swiftUILocation.x - currentViewBounds.minX,
                    y: swiftUILocation.y - currentViewBounds.minY
                )
                let matchedHyperlink = monitorState.hyperlinkEntries.first(where: { $0.rect.contains(localPoint) })
                let matchedRedaction = monitorState.redactionEntries.first(where: { $0.rect.contains(localPoint) })
                let distanceFromBottom = currentViewBounds.height - localPoint.y

                if let matchedHyperlink, let contentView = window.contentView {
                    let target = monitorState.hyperlinkMenuTarget
                    target.match = matchedHyperlink.match
                    monitorState.onHyperlinkRightClick(matchedHyperlink.match)
                    target.onCopyHyperlink = monitorState.onCopyHyperlink

                    let menu = NSMenu()
                    let copyItem = NSMenuItem(title: "Copy Link", action: #selector(HyperlinkMenuTarget.copyLinkAction(_:)), keyEquivalent: "")
                    copyItem.target = target
                    menu.addItem(copyItem)
                    NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                    return nil
                }

                if let matchedRedaction,
                   let tooltipState = matchedRedaction.tooltipState,
                   let contentView = window.contentView {
                    let target = monitorState.redactionMenuTarget
                    target.node = matchedRedaction.node
                    target.onToggleReveal = monitorState.onRedactionRevealToggle

                    let menu = NSMenu()
                    let toggleItem = NSMenuItem(
                        title: tooltipState.title,
                        action: #selector(RedactionMenuTarget.toggleRevealAction(_:)),
                        keyEquivalent: ""
                    )
                    toggleItem.target = target
                    toggleItem.isEnabled = tooltipState.isInteractive
                    menu.addItem(toggleItem)
                    NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                    return nil
                }

                if distanceFromBottom < timelineExclusionHeight {
                    return event
                }

                DispatchQueue.main.async {
                    monitorState.onRightClick(localPoint)
                }
                return nil
            }

            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

extension View {
    func onRightClick(
        hyperlinkEntries: [HyperlinkContextMenuEntry] = [],
        redactionEntries: [RedactedNodeContextMenuEntry] = [],
        onHyperlinkRightClick: @escaping (OCRHyperlinkMatch) -> Void = { _ in },
        onHyperlinkCopy: @escaping (OCRHyperlinkMatch) -> Void = { _ in },
        onRedactionRevealToggle: @escaping (OCRNodeWithText) -> Void = { _ in },
        perform action: @escaping (CGPoint) -> Void
    ) -> some View {
        modifier(
            RightClickOverlay(
                hyperlinkEntries: hyperlinkEntries,
                redactionEntries: redactionEntries,
                onHyperlinkRightClick: onHyperlinkRightClick,
                onHyperlinkCopy: onHyperlinkCopy,
                onRedactionRevealToggle: onRedactionRevealToggle,
                onRightClick: action
            )
        )
    }
}

struct FloatingContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize
    let highlightControlsVisibilityRow: Bool

    private let menuWidth: CGFloat = 272
    private let menuHeight: CGFloat = 252
    private let edgePadding: CGFloat = 16

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPresented = false
                    }
                }

            ContextMenuContent(
                viewModel: viewModel,
                showMenu: $isPresented,
                highlightControlsVisibilityRow: highlightControlsVisibilityRow
            )
            .retraceMenuContainer()
            .fixedSize()
            .position(adjustedPosition)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: isPresented)
    }

    private var shouldShowAbove: Bool {
        location.y + menuHeight > containerSize.height - edgePadding
    }

    private var adjustedPosition: CGPoint {
        var x = location.x + menuWidth / 2
        var y = shouldShowAbove ? (location.y - menuHeight / 2) : (location.y + menuHeight / 2)

        if x + menuWidth / 2 > containerSize.width - edgePadding {
            x = containerSize.width - menuWidth / 2 - edgePadding
        }
        if x - menuWidth / 2 < edgePadding {
            x = menuWidth / 2 + edgePadding
        }
        if y - menuHeight / 2 < edgePadding {
            y = menuHeight / 2 + edgePadding
        }
        if y + menuHeight / 2 > containerSize.height - edgePadding {
            y = containerSize.height - menuHeight / 2 - edgePadding
        }

        return CGPoint(x: x, y: y)
    }
}

struct TagSubmenuRow: View {
    let tag: Tag
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(TagColorStore.color(for: tag))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )

                Text(tag.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((isHovering || isKeyboardHighlighted) ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            onHoverChanged?(hovering)
        }
    }
}
