import Foundation
import SwiftUI
import Shared

struct ZoomRegionDragPreview: View {
    let start: CGPoint
    let end: CGPoint
    let containerSize: CGSize
    let actualFrameRect: CGRect

    private var previewRect: CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)

        return CGRect(
            x: actualFrameRect.origin.x + (minX * actualFrameRect.width),
            y: actualFrameRect.origin.y + (minY * actualFrameRect.height),
            width: width * actualFrameRect.width,
            height: height * actualFrameRect.height
        )
    }

    var body: some View {
        let rect = previewRect

        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

struct ZoomedTextSelectionOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let zoomedRect: CGRect

    var body: some View {
        ZoomedTextSelectionNSView(
            viewModel: viewModel,
            zoomRegion: zoomRegion,
            enlargedSize: CGSize(width: zoomedRect.width, height: zoomedRect.height),
            containerSize: containerSize
        )
        .frame(width: zoomedRect.width, height: zoomedRect.height)
        .position(x: zoomedRect.midX, y: zoomedRect.midY)
    }
}

struct ZoomedTextSelectionNSView: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let enlargedSize: CGSize
    let containerSize: CGSize

    func makeNSView(context: Context) -> ZoomedSelectionView {
        Log.debug("[ZoomedTextSelectionNSView] makeNSView - creating new ZoomedSelectionView", category: .ui)
        let view = ZoomedSelectionView()
        view.onDragStart = { point, isCommandDrag in
            viewModel.startDragSelection(
                at: point,
                mode: isCommandDrag ? .box : .character
            )
        }
        view.onDragUpdate = { point, isCommandDrag in
            viewModel.updateDragSelection(
                to: point,
                mode: isCommandDrag ? .box : .character
            )
        }
        view.onDragEnd = { viewModel.endDragSelection() }
        view.onClearSelection = {
            Log.debug("[ZoomedTextSelectionNSView] onClearSelection callback triggered", category: .ui)
            viewModel.clearTextSelection()
        }
        view.onCopyImage = { [weak viewModel] in viewModel?.copyZoomedRegionImage() }
        view.onDoubleClick = { point in viewModel.selectWordAt(point: point) }
        view.onTripleClick = { point in viewModel.selectNodeAt(point: point) }
        return view
    }

    func updateNSView(_ nsView: ZoomedSelectionView, context: Context) {
        nsView.zoomRegion = zoomRegion
        nsView.enlargedSize = enlargedSize

        nsView.nodeData = viewModel.ocrNodes.compactMap { node -> ZoomedSelectionView.NodeData? in
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = zoomRegion.origin.x + zoomRegion.width
            let regionBottom = zoomRegion.origin.y + zoomRegion.height

            if nodeRight < zoomRegion.origin.x || node.x > regionRight ||
                nodeBottom < zoomRegion.origin.y || node.y > regionBottom {
                return nil
            }

            let clippedX = max(node.x, zoomRegion.origin.x)
            let clippedY = max(node.y, zoomRegion.origin.y)
            let clippedRight = min(nodeRight, regionRight)
            let clippedBottom = min(nodeBottom, regionBottom)
            let clippedWidth = clippedRight - clippedX
            let clippedHeight = clippedBottom - clippedY

            let textLength = node.text.count
            let visibleStartFraction = (clippedX - node.x) / node.width
            let visibleEndFraction = (clippedRight - node.x) / node.width
            let visibleStartChar = OCRTextLayoutEstimator.characterIndex(
                in: node.text,
                atFraction: visibleStartFraction
            )
            let visibleEndChar = OCRTextLayoutEstimator.characterIndex(
                in: node.text,
                atFraction: visibleEndFraction
            )

            let visibleText: String
            if visibleStartChar < visibleEndChar && visibleStartChar >= 0 && visibleEndChar <= textLength {
                let startIdx = node.text.index(node.text.startIndex, offsetBy: visibleStartChar)
                let endIdx = node.text.index(node.text.startIndex, offsetBy: visibleEndChar)
                visibleText = String(node.text[startIdx..<endIdx])
            } else {
                visibleText = node.text
            }

            let transformedX = (clippedX - zoomRegion.origin.x) / zoomRegion.width
            let transformedY = (clippedY - zoomRegion.origin.y) / zoomRegion.height
            let transformedW = clippedWidth / zoomRegion.width
            let transformedH = clippedHeight / zoomRegion.height

            let rect = NSRect(
                x: transformedX * enlargedSize.width,
                y: (1.0 - transformedY - transformedH) * enlargedSize.height,
                width: transformedW * enlargedSize.width,
                height: transformedH * enlargedSize.height
            )

            var adjustedSelectionRange: (start: Int, end: Int)? = nil
            if let selectionRange = viewModel.getSelectionRange(for: node.id) {
                let adjustedStart = max(0, selectionRange.start - visibleStartChar)
                let adjustedEnd = min(visibleText.count, selectionRange.end - visibleStartChar)
                if adjustedEnd > adjustedStart {
                    adjustedSelectionRange = (start: adjustedStart, end: adjustedEnd)
                }
            }

            return ZoomedSelectionView.NodeData(
                id: node.id,
                rect: rect,
                text: visibleText,
                selectionRange: adjustedSelectionRange,
                isRedacted: node.isRedacted,
                visibleCharOffset: visibleStartChar,
                originalX: node.x,
                originalY: node.y,
                originalW: node.width,
                originalH: node.height
            )
        }

        nsView.refreshCursorForCurrentMouseLocation()
        nsView.needsDisplay = true
    }
}

class ZoomedSelectionView: NSView {
    enum CursorMode: Equatable {
        case none
        case iBeam
        case pointingHand
    }

    struct NodeData {
        let id: Int
        let rect: NSRect
        let text: String
        let selectionRange: (start: Int, end: Int)?
        let isRedacted: Bool
        let visibleCharOffset: Int
        let originalX: CGFloat
        let originalY: CGFloat
        let originalW: CGFloat
        let originalH: CGFloat
    }

    var nodeData: [NodeData] = []
    var zoomRegion: CGRect = .zero
    var enlargedSize: CGSize = .zero

    var onDragStart: ((CGPoint, Bool) -> Void)?
    var onDragUpdate: ((CGPoint, Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?

    private var isDragging = false
    private var isCommandDragging = false
    private var hasMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var commandDragStartPoint: CGPoint?
    private var commandDragCurrentPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var cursorMode: CursorMode = .none
    private let boundingBoxPadding: CGFloat = 8.0

    override var acceptsFirstResponder: Bool { true }

    deinit {
        if cursorMode != .none {
            NSCursor.pop()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
        refreshCursorForCurrentMouseLocation()
    }

    func refreshCursorForCurrentMouseLocation() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForLocation(location)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateCursorForLocation(location)
    }

    override func mouseExited(with event: NSEvent) {
        applyCursorMode(.none)
    }

    private func applyCursorMode(_ mode: CursorMode) {
        guard mode != cursorMode else { return }

        if cursorMode != .none {
            NSCursor.pop()
        }

        switch mode {
        case .none:
            break
        case .iBeam:
            NSCursor.iBeam.push()
        case .pointingHand:
            NSCursor.pointingHand.push()
        }

        cursorMode = mode
    }

    static func preferredCursorMode(
        at screenPoint: CGPoint,
        nodeData: [NodeData],
        boundingBoxPadding: CGFloat = 8
    ) -> CursorMode {
        guard let node = nodeData.first(where: {
            $0.rect.insetBy(dx: -boundingBoxPadding, dy: -boundingBoxPadding).contains(screenPoint)
        }) else {
            return .none
        }

        return node.isRedacted ? .pointingHand : .iBeam
    }

    private func updateCursorForLocation(_ location: CGPoint) {
        applyCursorMode(
            Self.preferredCursorMode(
                at: location,
                nodeData: nodeData,
                boundingBoxPadding: boundingBoxPadding
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil

        let normalizedPoint = screenToOriginalCoords(location)
        let isCommandDrag = event.modifierFlags.contains(.command)
        let clickCount = event.clickCount
        Log.debug("[ZoomedSelectionView] mouseDown clickCount=\(clickCount) isDragging=\(isDragging)", category: .ui)
        if clickCount == 2, !isCommandDrag {
            Log.debug("[ZoomedSelectionView] Double-click detected, calling onDoubleClick", category: .ui)
            onDoubleClick?(normalizedPoint)
            isDragging = false
            isCommandDragging = false
        } else if clickCount >= 3, !isCommandDrag {
            Log.debug("[ZoomedSelectionView] Triple-click detected, calling onTripleClick", category: .ui)
            onTripleClick?(normalizedPoint)
            isDragging = false
            isCommandDragging = false
        } else {
            isDragging = true
            isCommandDragging = isCommandDrag
            if isCommandDragging {
                commandDragStartPoint = location
                commandDragCurrentPoint = location
            }
            onDragStart?(normalizedPoint, isCommandDragging)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        let distance = hypot(location.x - mouseDownPoint.x, location.y - mouseDownPoint.y)
        if distance > 3 {
            hasMoved = true
        }

        let clampedX = max(0, min(bounds.width, location.x))
        let clampedY = max(0, min(bounds.height, location.y))

        let normalizedPoint = screenToOriginalCoords(CGPoint(x: clampedX, y: clampedY))
        if isCommandDragging {
            commandDragCurrentPoint = CGPoint(x: clampedX, y: clampedY)
        }
        onDragUpdate?(normalizedPoint, isCommandDragging)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        Log.debug("[ZoomedSelectionView] mouseUp isDragging=\(isDragging) hasMoved=\(hasMoved)", category: .ui)
        if isDragging {
            isDragging = false
            if !hasMoved {
                Log.debug("[ZoomedSelectionView] Single click without drag, clearing selection", category: .ui)
                onClearSelection?()
            } else {
                onDragEnd?()
            }
        }
        isCommandDragging = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Image", action: #selector(copyImageAction), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImageAction() {
        onCopyImage?()
    }

    private func screenToOriginalCoords(_ point: CGPoint) -> CGPoint {
        guard enlargedSize.width > 0, enlargedSize.height > 0 else { return .zero }

        let normalizedInZoom = CGPoint(
            x: point.x / enlargedSize.width,
            y: 1.0 - (point.y / enlargedSize.height)
        )

        return CGPoint(
            x: normalizedInZoom.x * zoomRegion.width + zoomRegion.origin.x,
            y: normalizedInZoom.y * zoomRegion.height + zoomRegion.origin.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let selectionColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.4)

        for node in nodeData {
            guard let range = node.selectionRange, range.end > range.start else { continue }

            let textLength = node.text.count
            guard textLength > 0 else { continue }

            let spanFractions = OCRTextLayoutEstimator.spanFractions(
                in: node.text,
                start: range.start,
                end: range.end
            )

            let highlightRect = NSRect(
                x: node.rect.origin.x + node.rect.width * spanFractions.start,
                y: node.rect.origin.y,
                width: node.rect.width * max(spanFractions.end - spanFractions.start, 0),
                height: node.rect.height
            )

            selectionColor.setFill()
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 2, yRadius: 2)
            path.fill()
        }

        if isDragging,
           isCommandDragging,
           let start = commandDragStartPoint,
           let end = commandDragCurrentPoint {
            let marqueeRect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )

            let fillColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.15)
            fillColor.setFill()
            let fillPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            fillPath.fill()

            let borderPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            borderPath.lineWidth = 1.5
            borderPath.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.95).setStroke()
            borderPath.stroke()
        }
    }
}
