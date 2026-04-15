import Foundation
import SwiftUI
import Shared

struct DeleteConfirmationDialog: View {
    let segmentFrameCount: Int
    let onDeleteFrame: () -> Void
    let onDeleteSegment: () -> Void
    let onCancel: () -> Void

    @State private var isHoveringDeleteFrame = false
    @State private var isHoveringDeleteSegment = false
    @State private var isHoveringCancel = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 20) {
                Image(systemName: "trash.fill")
                    .font(.retraceDisplay3)
                    .foregroundColor(.red.opacity(0.8))

                Text("Delete Frame?")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)

                VStack(spacing: 8) {
                    Text("Choose to delete this frame or the entire segment.")
                        .font(.retraceCallout)
                        .foregroundColor(.white.opacity(0.6))
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button(action: onDeleteFrame) {
                        HStack(spacing: 10) {
                            Image(systemName: "square")
                                .font(.retraceCallout)
                            Text("Delete Frame")
                                .font(.retraceCalloutMedium)
                        }
                        .foregroundColor(.white)
                        .frame(width: 240, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHoveringDeleteFrame ? Color.red.opacity(0.7) : Color.red.opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringDeleteFrame = hovering
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button(action: onDeleteSegment) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.retraceCallout)
                            Text("Delete Segment (\(segmentFrameCount) frames)")
                                .font(.retraceCalloutBold)
                        }
                        .foregroundColor(.white)
                        .frame(width: 240, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHoveringDeleteSegment ? Color.red.opacity(0.9) : Color.red.opacity(0.7))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringDeleteSegment = hovering
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 240, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isHoveringCancel ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringCancel = hovering
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: true)
    }
}

struct SearchHighlightOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect

    @State private var highlightScale: CGFloat = 0.3
    @State private var tooltipAnchorPoint: CGPoint?

    private let tooltipSize = CGSize(
        width: TimelineHoverTooltipStyle.width(for: "Copy All Highlighted Text"),
        height: TimelineHoverTooltipStyle.height
    )
    private let tooltipInset: CGFloat = 12
    private let tooltipGap: CGFloat = 10

    private var liveMatches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        viewModel.searchHighlightNodes
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            highlightLayer
                .allowsHitTesting(false)

            SearchHighlightHoverTracker(
                highlightedRects: highlightedRects,
                onHoverLocationChanged: handleHoverLocationChanged,
                onPrimaryClick: handlePrimaryClick(at:)
            )
            .frame(width: containerSize.width, height: containerSize.height)

            if let tooltipPosition = tooltipPosition {
                Text("Copy All Highlighted Text")
                    .font(TimelineHoverTooltipStyle.font)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, TimelineHoverTooltipStyle.horizontalPadding)
                    .padding(.vertical, TimelineHoverTooltipStyle.verticalPadding)
                    .background(Capsule().fill(TimelineHoverTooltipStyle.backgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
                    .offset(x: tooltipPosition.x, y: tooltipPosition.y)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            dismissTooltip()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0)) {
                highlightScale = 1.0
            }
        }
        .onDisappear(perform: dismissTooltip)
    }

    private var highlightLayer: some View {
        Group {
            if highlightedRects.isEmpty {
                if viewModel.isSearchResultNavigationModeActive,
                   viewModel.searchHighlightMode == .matchedNodes {
                    Color.black.opacity(0.25)
                } else {
                    Color.clear
                }
            } else {
                ZStack {
                    Color.black.opacity(0.25)

                    ForEach(Array(highlightedRects.enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white)
                            .frame(width: rect.width, height: rect.height)
                            .scaleEffect(highlightScale)
                            .position(x: rect.midX, y: rect.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                .overlay(
                    ZStack {
                        ForEach(Array(highlightedRects.enumerated()), id: \.offset) { _, rect in
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .scaleEffect(highlightScale)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                )
            }
        }
    }

    private var tooltipPosition: CGPoint? {
        guard let anchor = tooltipAnchorPoint else { return nil }

        let maxX = max(tooltipInset, containerSize.width - tooltipSize.width - tooltipInset)
        let preferredX = anchor.x - (tooltipSize.width / 2)
        let clampedX = min(max(preferredX, tooltipInset), maxX)

        let preferredAboveY = anchor.y - tooltipSize.height - tooltipGap
        let maxY = max(tooltipInset, containerSize.height - tooltipSize.height - tooltipInset)
        let y = preferredAboveY >= tooltipInset ? preferredAboveY : min(maxY, anchor.y + tooltipGap)
        return CGPoint(x: clampedX, y: y)
    }

    private var highlightedRects: [CGRect] {
        liveMatches.flatMap { match in
            let rects = match.ranges.compactMap { range -> CGRect? in
                let rect = screenRect(for: match.node, range: range)
                return rect.isEmpty ? nil : rect
            }

            if rects.isEmpty {
                let fallbackRect = screenRect(for: match.node)
                return fallbackRect.isEmpty ? [] : [fallbackRect]
            }

            return rects
        }
    }

    private func handleHoverLocationChanged(_ location: CGPoint?) {
        guard let location,
              let hoveredRect = highlightedRects.first(where: { $0.contains(location) }) else {
            dismissTooltip()
            return
        }

        tooltipAnchorPoint = CGPoint(x: hoveredRect.midX, y: hoveredRect.minY)
    }

    private func handlePrimaryClick(at location: CGPoint) -> Bool {
        guard highlightedRects.contains(where: { $0.contains(location) }) else {
            return false
        }

        viewModel.copySearchHighlightedTextByLine(from: liveMatches)
        dismissTooltip()
        return true
    }

    private func dismissTooltip() {
        tooltipAnchorPoint = nil
    }

    static func shouldDismissTooltip(
        for location: CGPoint,
        highlightedRects: [CGRect],
        tooltipFrame _: CGRect?
    ) -> Bool {
        !highlightedRects.contains(where: { $0.contains(location) })
    }

    static func paddedHighlightRect(_ rect: CGRect, within frameRect: CGRect) -> CGRect {
        guard !rect.isEmpty else { return .zero }
        guard !frameRect.isEmpty else { return rect }

        let horizontalOutset = min(max(rect.height * 0.21, 4), 10)
        let verticalOutset = min(max(rect.height * 0.12, 3), 8)
        return rect
            .insetBy(dx: -horizontalOutset, dy: -verticalOutset)
            .intersection(frameRect)
    }

    private func screenRect(for node: OCRNodeWithText) -> CGRect {
        let rect = CGRect(
            x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + (node.y * actualFrameRect.height),
            width: node.width * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
        return Self.paddedHighlightRect(rect, within: actualFrameRect)
    }

    private func screenRect(for node: OCRNodeWithText, range: Range<String.Index>) -> CGRect {
        guard !node.text.isEmpty else { return screenRect(for: node) }

        let spanFractions = OCRTextLayoutEstimator.spanFractions(in: node.text, range: range)
        let rect = CGRect(
            x: actualFrameRect.origin.x + ((node.x + (node.width * spanFractions.start)) * actualFrameRect.width),
            y: actualFrameRect.origin.y + (node.y * actualFrameRect.height),
            width: node.width * max(spanFractions.end - spanFractions.start, 0) * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
        return Self.paddedHighlightRect(rect, within: actualFrameRect)
    }
}

private struct SearchHighlightHoverTracker: NSViewRepresentable {
    let highlightedRects: [CGRect]
    let onHoverLocationChanged: (CGPoint?) -> Void
    let onPrimaryClick: (CGPoint) -> Bool

    func makeNSView(context: Context) -> SearchHighlightHoverTrackingView {
        let view = SearchHighlightHoverTrackingView()
        view.onHoverLocationChanged = onHoverLocationChanged
        view.onPrimaryClick = onPrimaryClick
        return view
    }

    func updateNSView(_ nsView: SearchHighlightHoverTrackingView, context: Context) {
        let didRectsChange = nsView.highlightedRects != highlightedRects
        nsView.highlightedRects = highlightedRects
        nsView.onHoverLocationChanged = onHoverLocationChanged
        nsView.onPrimaryClick = onPrimaryClick
        if didRectsChange || !nsView.hasPerformedInitialHoverSync {
            nsView.refreshHoverStateForCurrentMouseLocation()
            nsView.hasPerformedInitialHoverSync = true
        }
    }
}

private final class SearchHighlightHoverTrackingView: NSView {
    var highlightedRects: [CGRect] = []
    var onHoverLocationChanged: ((CGPoint?) -> Void)?
    var onPrimaryClick: ((CGPoint) -> Bool)?
    var hasPerformedInitialHoverSync = false

    private var trackingArea: NSTrackingArea?
    private var localMouseDownMonitor: Any?

    override var isFlipped: Bool { true }

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

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverLocationChanged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverLocationChanged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverLocationChanged?(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refreshHoverStateForCurrentMouseLocation() {
        guard let window else { return }
        onHoverLocationChanged?(convert(window.mouseLocationOutsideOfEventStream, from: nil))
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
}

struct OCRDebugOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect

    private let tileSize: CGFloat = 64
    private let matchTolerance: CGFloat = 0.01

    private var categorizedNodes: (new: [OCRNodeWithText], removed: [OCRNodeWithText], unchanged: [OCRNodeWithText]) {
        let current = viewModel.ocrNodes
        let previous = viewModel.previousOcrNodes

        guard !previous.isEmpty else {
            return (new: current, removed: [], unchanged: [])
        }

        var newNodes: [OCRNodeWithText] = []
        var unchangedNodes: [OCRNodeWithText] = []
        var matchedPreviousIndices = Set<Int>()

        for currentNode in current {
            var foundMatch = false
            for (prevIndex, prevNode) in previous.enumerated() {
                if nodesMatch(currentNode, prevNode) {
                    unchangedNodes.append(currentNode)
                    matchedPreviousIndices.insert(prevIndex)
                    foundMatch = true
                    break
                }
            }
            if !foundMatch {
                newNodes.append(currentNode)
            }
        }

        let removedNodes = previous.enumerated()
            .filter { !matchedPreviousIndices.contains($0.offset) }
            .map(\.element)

        return (new: newNodes, removed: removedNodes, unchanged: unchangedNodes)
    }

    private func nodesMatch(_ a: OCRNodeWithText, _ b: OCRNodeWithText) -> Bool {
        abs(a.x - b.x) < matchTolerance &&
        abs(a.y - b.y) < matchTolerance &&
        abs(a.width - b.width) < matchTolerance &&
        abs(a.height - b.height) < matchTolerance
    }

    var body: some View {
        ZStack {
            tileGridOverlay
            ocrDiffOverlay
        }
        .allowsHitTesting(false)
    }

    private var tileGridOverlay: some View {
        Canvas { context, _ in
            let frameWidth = actualFrameRect.width
            let frameHeight = actualFrameRect.height
            guard frameWidth > 0, frameHeight > 0 else { return }

            let estimatedPixelWidth: CGFloat = 2560
            let estimatedPixelHeight = estimatedPixelWidth * (frameHeight / frameWidth)
            let tilesX = Int(ceil(estimatedPixelWidth / tileSize))
            let tilesY = Int(ceil(estimatedPixelHeight / tileSize))
            let normalizedTileWidth = tileSize / estimatedPixelWidth
            let normalizedTileHeight = tileSize / estimatedPixelHeight

            for col in 0...tilesX {
                let screenX = actualFrameRect.origin.x + (CGFloat(col) * normalizedTileWidth * frameWidth)
                guard screenX <= actualFrameRect.maxX else { break }

                var path = Path()
                path.move(to: CGPoint(x: screenX, y: actualFrameRect.origin.y))
                path.addLine(to: CGPoint(x: screenX, y: actualFrameRect.maxY))
                context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 0.5)
            }

            for row in 0...tilesY {
                let screenY = actualFrameRect.origin.y + (CGFloat(row) * normalizedTileHeight * frameHeight)
                guard screenY <= actualFrameRect.maxY else { break }

                var path = Path()
                path.move(to: CGPoint(x: actualFrameRect.origin.x, y: screenY))
                path.addLine(to: CGPoint(x: actualFrameRect.maxX, y: screenY))
                context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 0.5)
            }
        }
    }

    private var ocrDiffOverlay: some View {
        let nodes = categorizedNodes

        return ZStack {
            ForEach(Array(nodes.removed.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .red, isDashed: true, label: "−")
            }

            ForEach(Array(nodes.unchanged.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .gray, isDashed: false, label: nil)
            }

            ForEach(Array(nodes.new.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .green, isDashed: false, label: "+")
            }

            statsBadge(new: nodes.new.count, removed: nodes.removed.count, unchanged: nodes.unchanged.count)
        }
    }

    @ViewBuilder
    private func nodeBox(node: OCRNodeWithText, color: Color, isDashed: Bool, label: String?) -> some View {
        let screenX = actualFrameRect.origin.x + (node.x * actualFrameRect.width)
        let screenY = actualFrameRect.origin.y + (node.y * actualFrameRect.height)
        let screenWidth = node.width * actualFrameRect.width
        let screenHeight = node.height * actualFrameRect.height

        RoundedRectangle(cornerRadius: 2)
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: isDashed ? 1.5 : 1, dash: isDashed ? [4, 2] : []))
            .frame(width: screenWidth, height: screenHeight)
            .position(x: screenX + screenWidth / 2, y: screenY + screenHeight / 2)

        if let label {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color.opacity(0.9))
                .cornerRadius(3)
                .position(x: screenX + 10, y: screenY + 10)
        }
    }

    @ViewBuilder
    private func statsBadge(new: Int, removed: Int, unchanged: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("New: \(new)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Removed: \(removed)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Unchanged: \(unchanged)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
        .position(x: actualFrameRect.maxX - 70, y: actualFrameRect.origin.y + 50)
    }
}
