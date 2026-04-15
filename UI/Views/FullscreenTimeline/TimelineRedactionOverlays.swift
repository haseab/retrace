import Foundation
import SwiftUI
import Shared

struct FrameZoomIndicator: View {
    let zoomScale: CGFloat

    var body: some View {
        HStack(spacing: .spacingS) {
            Image(systemName: zoomScale > 1.0 ? "plus.magnifyingglass" : "minus.magnifyingglass")
                .font(.retraceCaption)
            Text(TimelineZoomSettings.percentLabel(forScale: zoomScale))
                .font(.retraceCaption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
        .transition(.opacity.combined(with: .scale))
    }
}

private struct DemystifiedRevealPatchView: View {
    let patch: NSImage
    let size: CGSize
    let isVisible: Bool

    @State private var revealProgress: CGFloat = 0

    private static let revealAnimation = Animation.spring(response: 0.46, dampingFraction: 0.84)

    var body: some View {
        ZStack {
            Image(nsImage: patch)
                .resizable()
                .interpolation(.none)
                .frame(width: size.width, height: size.height)
                .blur(radius: (1.0 - revealProgress) * 12.0)
                .saturation(0.65 + (0.35 * revealProgress))
                .brightness((1.0 - revealProgress) * 0.08)
                .scaleEffect(1.03 - (0.03 * revealProgress))

            LinearGradient(
                colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.55),
                    Color.white.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: max(size.width * 0.28, 18), height: size.height * 1.5)
            .rotationEffect(.degrees(16))
            .offset(x: (size.width * 1.35 * revealProgress) - (size.width * 0.7))
            .opacity(1.0 - min(revealProgress * 1.1, 1.0))
            .blendMode(.screen)
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            revealProgress = isVisible ? 0 : 1
            withAnimation(Self.revealAnimation) {
                revealProgress = isVisible ? 1 : 0
            }
        }
        .onChange(of: isVisible) { visible in
            withAnimation(Self.revealAnimation) {
                revealProgress = visible ? 1 : 0
            }
        }
    }
}

struct RedactedNodeRevealOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let nodes: [OCRNodeWithText]
    let actualFrameRect: CGRect

    private var processingStatus: Int {
        viewModel.currentTimelineFrame?.processingStatus ?? -1
    }

    var body: some View {
        ZStack {
            ForEach(nodes, id: \.id) { node in
                let rect = nodeRect(for: node)
                if rect.width > 1, rect.height > 1 {
                    let isTooltipActive = viewModel.activeRedactionTooltipNodeID == node.id
                    let outlineState = SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                        for: processingStatus,
                        isTooltipActive: isTooltipActive
                    )
                    let patch = viewModel.revealedRedactedNodePatches[node.id]
                        ?? viewModel.hidingRedactedNodePatches[node.id]
                    ZStack {
                        if let patch {
                            DemystifiedRevealPatchView(
                                patch: patch,
                                size: CGSize(width: rect.width, height: rect.height),
                                isVisible: viewModel.revealedRedactedNodePatches[node.id] != nil
                            )
                            .frame(width: rect.width, height: rect.height)
                        }

                        if outlineState != .hidden {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    outlineColor(for: outlineState),
                                    style: StrokeStyle(
                                        lineWidth: 1.5,
                                        dash: outlineState == .queued ? [4, 3] : []
                                    )
                                )
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private func nodeRect(for node: OCRNodeWithText) -> CGRect {
        CGRect(
            x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + (node.y * actualFrameRect.height),
            width: node.width * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
    }

    private func outlineColor(
        for state: SimpleTimelineViewModel.PhraseLevelRedactionOutlineState
    ) -> Color {
        switch state {
        case .hidden:
            return .clear
        case .queued:
            return Color.white.opacity(0.22)
        case .active:
            return Color.white.opacity(0.82)
        }
    }
}

struct ZoomedRedactedNodeRevealOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let zoomedRect: CGRect

    private var processingStatus: Int {
        viewModel.currentTimelineFrame?.processingStatus ?? -1
    }

    var body: some View {
        ZStack {
            ForEach(viewModel.ocrNodes.filter(\.isRedacted), id: \.id) { node in
                if let rect = transformedRect(for: node), rect.width > 1, rect.height > 1 {
                    let isTooltipActive = viewModel.activeRedactionTooltipNodeID == node.id
                    let outlineState = SimpleTimelineViewModel.phraseLevelRedactionOutlineState(
                        for: processingStatus,
                        isTooltipActive: isTooltipActive
                    )
                    let patch = viewModel.revealedRedactedNodePatches[node.id]
                        ?? viewModel.hidingRedactedNodePatches[node.id]

                    ZStack {
                        if let patch {
                            DemystifiedRevealPatchView(
                                patch: patch,
                                size: CGSize(width: rect.width, height: rect.height),
                                isVisible: viewModel.revealedRedactedNodePatches[node.id] != nil
                            )
                            .frame(width: rect.width, height: rect.height)
                        }

                        if outlineState != .hidden {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    outlineColor(for: outlineState),
                                    style: StrokeStyle(
                                        lineWidth: 1.5,
                                        dash: outlineState == .queued ? [4, 3] : []
                                    )
                                )
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .mask(
            Rectangle()
                .frame(width: zoomedRect.width, height: zoomedRect.height)
                .position(x: zoomedRect.midX, y: zoomedRect.midY)
        )
    }

    private func transformedRect(for node: OCRNodeWithText) -> CGRect? {
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

    private func outlineColor(
        for state: SimpleTimelineViewModel.PhraseLevelRedactionOutlineState
    ) -> Color {
        switch state {
        case .hidden:
            return .clear
        case .queued:
            return Color.white.opacity(0.26)
        case .active:
            return Color.white.opacity(0.9)
        }
    }
}

struct RedactionTooltipOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let entries: [RedactedNodeContextMenuEntry]
    let containerSize: CGSize
    let onToggleReveal: (OCRNodeWithText) -> Void
    @State private var escapeMonitor: Any?
    @State private var hoveredNodeID: Int?

    private let tooltipHeight: CGFloat = TimelineHoverTooltipStyle.height
    private let edgePadding: CGFloat = 14
    private let tooltipGap: CGFloat = 10

    private var hoverEntries: [RedactionTooltipHoverEntry] {
        entries.compactMap { entry in
            guard let tooltipState = entry.tooltipState else { return nil }
            return RedactionTooltipHoverEntry(
                nodeID: entry.node.id,
                triggerFrame: Self.triggerFrame(for: entry.rect),
                tooltipState: tooltipState
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RedactionTooltipHoverTracker(
                entries: hoverEntries,
                onHoveredNodeChanged: handleHoveredNodeChanged,
                onPrimaryClick: handlePrimaryClick(at:)
            )
            .frame(width: containerSize.width, height: containerSize.height)

            ForEach(entries, id: \.node.id) { entry in
                if let tooltipState = entry.tooltipState {
                    let tooltipFrame = Self.tooltipFrame(
                        for: entry.rect,
                        state: tooltipState,
                        containerSize: containerSize,
                        edgePadding: edgePadding,
                        tooltipHeight: tooltipHeight,
                        tooltipGap: tooltipGap
                    )

                    if hoveredNodeID == entry.node.id {
                        tooltipLabel(for: tooltipState)
                            .frame(width: tooltipFrame.width, height: tooltipFrame.height)
                            .offset(x: tooltipFrame.minX, y: tooltipFrame.minY)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            .zIndex(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: hoveredNodeID)
        .onChange(of: entries.map(\.node.id)) { nodeIDs in
            if let hoveredNodeID, !nodeIDs.contains(hoveredNodeID) {
                clearHoveredNode()
            }
        }
        .onAppear {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                guard hoveredNodeID != nil else { return event }
                clearHoveredNode()
                return nil
            }
        }
        .onDisappear {
            clearHoveredNode()
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    private func handleHoveredNodeChanged(_ nodeID: Int?) {
        guard let nodeID,
              let hoveredEntry = hoverEntries.first(where: { $0.nodeID == nodeID }) else {
            clearHoveredNode()
            return
        }

        guard hoveredNodeID != nodeID else { return }

        hoveredNodeID = nodeID
        viewModel.showRedactionTooltip(for: nodeID)
        viewModel.showRedactionTooltip(for: nodeID, state: hoveredEntry.tooltipState)
    }

    private func handlePrimaryAction(
        for node: OCRNodeWithText,
        state: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState
    ) {
        switch state {
        case .queued:
            break
        case .reveal, .hide:
            onToggleReveal(node)
        }
    }

    private func handlePrimaryClick(at location: CGPoint) -> Bool {
        guard let matchedEntry = entries.first(where: { Self.triggerFrame(for: $0.rect).contains(location) }),
              let tooltipState = matchedEntry.tooltipState,
              tooltipState.isInteractive else {
            return false
        }

        handlePrimaryAction(for: matchedEntry.node, state: tooltipState)
        return true
    }

    private func clearHoveredNode() {
        hoveredNodeID = nil
        viewModel.dismissRedactionTooltip()
    }

    static func triggerFrame(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.width, 1),
            height: max(rect.height, 1)
        )
    }

    private func tooltipForegroundColor(
        for state: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState
    ) -> Color {
        state.isInteractive ? .white : .white.opacity(0.5)
    }

    private func tooltipBackgroundColor(
        for state: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState
    ) -> Color {
        state.isInteractive
            ? TimelineHoverTooltipStyle.backgroundColor
            : TimelineHoverTooltipStyle.backgroundColor.opacity(0.72)
    }

    @ViewBuilder
    private func tooltipLabel(
        for state: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState
    ) -> some View {
        Text(state.tooltipText)
            .font(TimelineHoverTooltipStyle.font)
            .foregroundColor(tooltipForegroundColor(for: state))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, TimelineHoverTooltipStyle.horizontalPadding)
            .padding(.vertical, TimelineHoverTooltipStyle.verticalPadding)
            .background(
                Capsule()
                    .fill(tooltipBackgroundColor(for: state))
            )
    }

    static func tooltipFrame(
        for rect: CGRect,
        state: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState,
        containerSize: CGSize,
        edgePadding: CGFloat = 14,
        tooltipHeight: CGFloat = 28,
        tooltipGap: CGFloat = 10
    ) -> CGRect {
        let tooltipWidth = TimelineHoverTooltipStyle.width(for: state.tooltipText)

        var originX = rect.midX - (tooltipWidth / 2)
        originX = min(
            max(originX, edgePadding),
            containerSize.width - tooltipWidth - edgePadding
        )

        let preferredTopY = rect.minY - tooltipHeight - tooltipGap
        let fallbackBottomY = rect.maxY + tooltipGap
        let originY: CGFloat
        if preferredTopY >= edgePadding {
            originY = preferredTopY
        } else {
            originY = min(
                max(fallbackBottomY, edgePadding),
                containerSize.height - tooltipHeight - edgePadding
            )
        }

        return CGRect(x: originX, y: originY, width: tooltipWidth, height: tooltipHeight)
    }
}

private struct RedactionTooltipHoverEntry: Equatable {
    let nodeID: Int
    let triggerFrame: CGRect
    let tooltipState: SimpleTimelineViewModel.PhraseLevelRedactionTooltipState
}

private struct RedactionTooltipHoverTracker: NSViewRepresentable {
    let entries: [RedactionTooltipHoverEntry]
    let onHoveredNodeChanged: (Int?) -> Void
    let onPrimaryClick: (CGPoint) -> Bool

    func makeNSView(context: Context) -> RedactionTooltipHoverTrackingView {
        let view = RedactionTooltipHoverTrackingView()
        view.onHoveredNodeChanged = onHoveredNodeChanged
        view.onPrimaryClick = onPrimaryClick
        return view
    }

    func updateNSView(_ nsView: RedactionTooltipHoverTrackingView, context: Context) {
        let didEntriesChange = nsView.entries != entries
        nsView.entries = entries
        nsView.onHoveredNodeChanged = onHoveredNodeChanged
        nsView.onPrimaryClick = onPrimaryClick
        if didEntriesChange || !nsView.hasPerformedInitialHoverSync {
            nsView.refreshHoverStateForCurrentMouseLocation()
            nsView.hasPerformedInitialHoverSync = true
        }
    }
}

private final class RedactionTooltipHoverTrackingView: NSView {
    var entries: [RedactionTooltipHoverEntry] = []
    var onHoveredNodeChanged: ((Int?) -> Void)?
    var onPrimaryClick: ((CGPoint) -> Bool)?
    var hasPerformedInitialHoverSync = false

    private var trackingArea: NSTrackingArea?
    private var localMouseDownMonitor: Any?

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasPerformedInitialHoverSync = false
        if window == nil {
            removeLocalMouseDownMonitor()
        } else {
            installLocalMouseDownMonitorIfNeeded()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeLocalMouseDownMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        removeLocalMouseDownMonitor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHoveredNodeChanged?(hoveredNodeID(at: location))
    }

    override func mouseEntered(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHoveredNodeChanged?(hoveredNodeID(at: location))
    }

    override func mouseExited(with event: NSEvent) {
        onHoveredNodeChanged?(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func refreshHoverStateForCurrentMouseLocation() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onHoveredNodeChanged?(hoveredNodeID(at: location))
    }

    private func installLocalMouseDownMonitorIfNeeded() {
        guard localMouseDownMonitor == nil else { return }

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let eventWindow = event.window, eventWindow == self.window else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.onPrimaryClick?(location) == true else { return event }
            return nil
        }
    }

    private func removeLocalMouseDownMonitor() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
    }

    private func hoveredNodeID(at location: CGPoint) -> Int? {
        entries.first(where: { $0.triggerFrame.contains(location) })?.nodeID
    }
}
