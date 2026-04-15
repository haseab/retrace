import Foundation
import SwiftUI
import AppKit
import Shared

struct TextSelectionOverlay: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let hyperlinkMatches: [OCRHyperlinkMatch]
    let onHyperlinkOpen: (OCRHyperlinkMatch) -> Void
    var isInteractionDisabled: Bool = false
    let onDragStart: (CGPoint, Bool) -> Void
    let onDragUpdate: (CGPoint, Bool) -> Void
    let onDragEnd: () -> Void
    let onClearSelection: () -> Void
    let onZoomRegionStart: (CGPoint) -> Void
    let onZoomRegionUpdate: (CGPoint) -> Void
    let onZoomRegionEnd: () -> Void
    let onDoubleClick: (CGPoint) -> Void
    let onTripleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> TextSelectionView {
        let view = TextSelectionView()
        view.onDragStart = onDragStart
        view.onDragUpdate = onDragUpdate
        view.onDragEnd = onDragEnd
        view.onClearSelection = onClearSelection
        view.onZoomRegionStart = onZoomRegionStart
        view.onZoomRegionUpdate = onZoomRegionUpdate
        view.onZoomRegionEnd = onZoomRegionEnd
        view.onDoubleClick = onDoubleClick
        view.onTripleClick = onTripleClick
        view.onHyperlinkOpen = onHyperlinkOpen
        return view
    }

    func updateNSView(_ nsView: TextSelectionView, context: Context) {
        nsView.nodeData = viewModel.ocrNodes.map { node in
            let rect = NSRect(
                x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
                y: actualFrameRect.origin.y + ((1.0 - node.y - node.height) * actualFrameRect.height),
                width: node.width * actualFrameRect.width,
                height: node.height * actualFrameRect.height
            )
            return TextSelectionView.NodeData(
                id: node.id,
                rect: rect,
                text: node.text,
                selectionRange: viewModel.getSelectionRange(for: node.id),
                isRedacted: node.isRedacted
            )
        }
        nsView.searchHighlightedRects = searchHighlightedRects()
        nsView.containerSize = containerSize
        nsView.actualFrameRect = actualFrameRect
        nsView.onHyperlinkOpen = onHyperlinkOpen
        nsView.hyperlinkEntries = hyperlinkMatches.compactMap { match in
            let rect = NSRect(
                x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
                y: actualFrameRect.origin.y + ((1.0 - match.y - match.height) * actualFrameRect.height),
                width: match.highlightWidth * actualFrameRect.width,
                height: match.height * actualFrameRect.height
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return TextSelectionView.HyperlinkEntry(match: match, rect: rect)
        }
        nsView.isDraggingSelection = viewModel.dragStartPoint != nil
        nsView.isDraggingZoomRegion = viewModel.isDraggingZoomRegion
        nsView.isInteractionDisabled = isInteractionDisabled
        nsView.refreshCursorForCurrentMouseLocation()
        nsView.needsDisplay = true
    }

    private func searchHighlightedRects() -> [CGRect] {
        guard viewModel.isShowingSearchHighlight else { return [] }

        return viewModel.searchHighlightNodes.flatMap { match in
            let rects = match.ranges.compactMap { range -> CGRect? in
                let rect = TextSelectionView.searchHighlightRect(for: match.node, range: range, in: actualFrameRect)
                return rect.isEmpty ? nil : rect
            }

            if rects.isEmpty {
                let fallbackRect = TextSelectionView.searchHighlightRect(for: match.node, in: actualFrameRect)
                return fallbackRect.isEmpty ? [] : [fallbackRect]
            }

            return rects
        }
    }
}

struct URLBoundingBoxOverlay: NSViewRepresentable {
    let boundingBox: URLBoundingBox
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isHovering: Bool
    let onHoverChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> URLOverlayView {
        let view = URLOverlayView()
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: URLOverlayView, context: Context) {
        let rect = NSRect(
            x: actualFrameRect.origin.x + (boundingBox.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + ((1.0 - boundingBox.y - boundingBox.height) * actualFrameRect.height),
            width: boundingBox.width * actualFrameRect.width,
            height: boundingBox.height * actualFrameRect.height
        )

        nsView.boundingRect = rect
        nsView.isHoveringURL = isHovering
        nsView.url = boundingBox.url
        nsView.needsDisplay = true
    }
}

final class URLOverlayView: NSView {
    static let outlinePadding: CGFloat = 4

    var boundingRect: NSRect = .zero
    var isHoveringURL: Bool = false
    var url: String = ""
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let outlineRect = Self.outlineRect(for: boundingRect)
        guard !outlineRect.isEmpty else { return }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .mouseMoved]
        trackingArea = NSTrackingArea(rect: outlineRect, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        NSCursor.pointingHand.push()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        NSCursor.pop()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if Self.outlineRect(for: boundingRect).contains(location) {
            onClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if Self.outlineRect(for: boundingRect).contains(point) {
            return super.hitTest(point)
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let outlineRect = Self.outlineRect(for: boundingRect)
        guard isHoveringURL, !outlineRect.isEmpty else { return }

        let path = NSBezierPath(roundedRect: outlineRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2.0
        path.setLineDash([6, 4], count: 2, phase: 0)

        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.9).setStroke()
        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.15).setFill()
        path.stroke()
        path.fill()
    }

    static func outlineRect(for boundingRect: CGRect) -> CGRect {
        boundingRect.insetBy(dx: -outlinePadding, dy: -outlinePadding)
    }
}

struct OCRHyperlinkOverlay: NSViewRepresentable {
    let matches: [OCRHyperlinkMatch]
    let actualFrameRect: CGRect
    let onHoverChanged: (OCRHyperlinkMatch?) -> Void
    let onOpen: (OCRHyperlinkMatch) -> Void

    func makeNSView(context: Context) -> OCRHyperlinkOverlayView {
        let view = OCRHyperlinkOverlayView()
        view.onHoverChanged = onHoverChanged
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ nsView: OCRHyperlinkOverlayView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onOpen = onOpen
        nsView.entries = matches.compactMap { match in
            let rect = CGRect(
                x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
                y: actualFrameRect.origin.y + (match.y * actualFrameRect.height),
                width: match.highlightWidth * actualFrameRect.width,
                height: match.height * actualFrameRect.height
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return OCRHyperlinkOverlayView.Entry(match: match, rect: rect)
        }
    }
}

final class OCRHyperlinkOverlayView: NSView {
    struct Entry {
        let match: OCRHyperlinkMatch
        let rect: CGRect

        var hoverKey: String {
            "\(match.nodeID)|\(match.url)"
        }
    }

    var entries: [Entry] = [] {
        didSet {
            if hoveredMatchKey.flatMap({ key in entries.first(where: { $0.hoverKey == key }) }) == nil {
                hoveredMatchKey = nil
            }
            needsDisplay = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onHoverChanged: ((OCRHyperlinkMatch?) -> Void)?
    var onOpen: ((OCRHyperlinkMatch) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoveredMatchKey: String?
    private let idleBorderOffset: CGFloat = 2.5
    private let idleBorderThickness: CGFloat = 1.25
    private let borderCornerRadius: CGFloat = 6
    private let interactionPadding: CGFloat = 3

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let newTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func resetCursorRects() {
        discardCursorRects()
        for entry in entries {
            addCursorRect(interactionRect(for: entry), cursor: .pointingHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard match(at: point) != nil else { return nil }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredMatch(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let match = match(at: location) else {
            super.mouseDown(with: event)
            return
        }

        onOpen?(match)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for entry in entries {
            guard entry.hoverKey != hoveredMatchKey else { continue }
            drawIdleBorder(for: entry)
        }

        if let hoveredEntry {
            let hoverRect = outlineRect(for: hoveredEntry)
            let path = NSBezierPath(
                roundedRect: hoverRect,
                xRadius: borderCornerRadius,
                yRadius: borderCornerRadius
            )
            path.lineWidth = 2
            path.setLineDash([5, 3], count: 2, phase: 0)

            NSColor.systemBlue.withAlphaComponent(0.20).setFill()
            path.fill()

            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }

    private func match(at point: CGPoint) -> OCRHyperlinkMatch? {
        entries.first(where: { interactionRect(for: $0).contains(point) })?.match
    }

    private func updateHoverState(at point: CGPoint) {
        setHoveredMatch(entries.first(where: { interactionRect(for: $0).contains(point) })?.hoverKey)
    }

    private func setHoveredMatch(_ hoverKey: String?) {
        guard hoveredMatchKey != hoverKey else { return }
        hoveredMatchKey = hoverKey
        onHoverChanged?(hoveredEntry?.match)
        needsDisplay = true
    }

    private var hoveredEntry: Entry? {
        guard let hoveredMatchKey else { return nil }
        return entries.first(where: { $0.hoverKey == hoveredMatchKey })
    }

    private func drawIdleBorder(for entry: Entry) {
        let borderPath = NSBezierPath(
            roundedRect: outlineRect(for: entry),
            xRadius: borderCornerRadius,
            yRadius: borderCornerRadius
        )
        borderPath.lineWidth = idleBorderThickness
        NSColor.systemBlue.withAlphaComponent(0.58).setStroke()
        borderPath.stroke()
    }

    private func outlineRect(for entry: Entry) -> CGRect {
        entry.rect.insetBy(dx: -idleBorderOffset, dy: -idleBorderOffset)
    }

    private func interactionRect(for entry: Entry) -> CGRect {
        entry.rect.insetBy(dx: -interactionPadding, dy: -interactionPadding)
    }
}

final class TextSelectionView: NSView {
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
    }

    struct HyperlinkEntry {
        let match: OCRHyperlinkMatch
        let rect: NSRect
    }

    var nodeData: [NodeData] = []
    var searchHighlightedRects: [CGRect] = []
    var containerSize: CGSize = .zero
    var actualFrameRect: CGRect = .zero
    var hyperlinkEntries: [HyperlinkEntry] = []
    var isDraggingSelection: Bool = false
    var isDraggingZoomRegion: Bool = false
    var isInteractionDisabled: Bool = false

    var onDragStart: ((CGPoint, Bool) -> Void)?
    var onDragUpdate: ((CGPoint, Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onZoomRegionStart: ((CGPoint) -> Void)?
    var onZoomRegionUpdate: ((CGPoint) -> Void)?
    var onZoomRegionEnd: (() -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?
    var onHyperlinkOpen: ((OCRHyperlinkMatch) -> Void)?

    private var isDragging = false
    private var isCommandDragging = false
    private var isZoomDragging = false
    private var hasMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var commandDragStartPoint: CGPoint?
    private var commandDragCurrentPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var cursorMode: CursorMode = .none

    private let boundingBoxPadding: CGFloat = 8.0
    private let hyperlinkPadding: CGFloat = 3.0

    deinit {
        if cursorMode != .none {
            NSCursor.pop()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursorForLocation(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        applyCursorMode(.none)
    }

    private func hyperlinkEntryContaining(screenPoint: CGPoint) -> HyperlinkEntry? {
        for entry in hyperlinkEntries {
            if entry.rect.insetBy(dx: -hyperlinkPadding, dy: -hyperlinkPadding).contains(screenPoint) {
                return entry
            }
        }
        return nil
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
        hyperlinkEntries: [HyperlinkEntry],
        searchHighlightedRects: [CGRect] = [],
        boundingBoxPadding: CGFloat = 8,
        hyperlinkPadding: CGFloat = 3
    ) -> CursorMode {
        if searchHighlightedRects.contains(where: { $0.contains(screenPoint) }) {
            return .pointingHand
        }

        if hyperlinkEntries.contains(where: {
            $0.rect.insetBy(dx: -hyperlinkPadding, dy: -hyperlinkPadding).contains(screenPoint)
        }) {
            return .pointingHand
        }

        guard let node = nodeData.first(where: {
            $0.rect.insetBy(dx: -boundingBoxPadding, dy: -boundingBoxPadding).contains(screenPoint)
        }) else {
            return .none
        }

        return node.isRedacted ? .pointingHand : .iBeam
    }

    static func searchHighlightRect(
        for node: OCRNodeWithText,
        in actualFrameRect: CGRect
    ) -> CGRect {
        let rect = CGRect(
            x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + ((1.0 - node.y - node.height) * actualFrameRect.height),
            width: node.width * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
        return SearchHighlightOverlay.paddedHighlightRect(rect, within: actualFrameRect)
    }

    static func searchHighlightRect(
        for node: OCRNodeWithText,
        range: Range<String.Index>,
        in actualFrameRect: CGRect
    ) -> CGRect {
        guard !node.text.isEmpty else {
            return searchHighlightRect(for: node, in: actualFrameRect)
        }

        let spanFractions = OCRTextLayoutEstimator.spanFractions(in: node.text, range: range)
        let rect = CGRect(
            x: actualFrameRect.origin.x + ((node.x + (node.width * spanFractions.start)) * actualFrameRect.width),
            y: actualFrameRect.origin.y + ((1.0 - node.y - node.height) * actualFrameRect.height),
            width: node.width * max(spanFractions.end - spanFractions.start, 0) * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
        return SearchHighlightOverlay.paddedHighlightRect(rect, within: actualFrameRect)
    }

    func refreshCursorForCurrentMouseLocation() {
        guard let window else {
            applyCursorMode(.none)
            return
        }

        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location) else {
            applyCursorMode(.none)
            return
        }

        updateCursorForLocation(location)
    }

    private func updateCursorForLocation(_ location: CGPoint) {
        applyCursorMode(
            Self.preferredCursorMode(
                at: location,
                nodeData: nodeData,
                hyperlinkEntries: hyperlinkEntries,
                searchHighlightedRects: searchHighlightedRects,
                boundingBoxPadding: boundingBoxPadding,
                hyperlinkPadding: hyperlinkPadding
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInteractionDisabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil
        let hyperlinkModifierFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]
        let hasHyperlinkOverrideModifiers = !event.modifierFlags.intersection(hyperlinkModifierFlags).isEmpty

        if event.clickCount == 1,
           !hasHyperlinkOverrideModifiers,
           let hyperlinkEntry = hyperlinkEntryContaining(screenPoint: location) {
            onHyperlinkOpen?(hyperlinkEntry.match)
            return
        }

        let normalizedPoint = screenToNormalizedCoords(location)
        let isCommandDrag = event.modifierFlags.contains(.command)

        if event.modifierFlags.contains(.shift) {
            isZoomDragging = true
            isDragging = false
            isCommandDragging = false
            onZoomRegionStart?(normalizedPoint)
        } else {
            let clickCount = event.clickCount
            if clickCount == 2, !isCommandDrag {
                onDoubleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
                isCommandDragging = false
            } else if clickCount >= 3, !isCommandDrag {
                onTripleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
                isCommandDragging = false
            } else {
                isDragging = true
                isZoomDragging = false
                isCommandDragging = isCommandDrag
                if isCommandDragging {
                    commandDragStartPoint = location
                    commandDragCurrentPoint = location
                }
                onDragStart?(normalizedPoint, isCommandDragging)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionDisabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        if hypot(location.x - mouseDownPoint.x, location.y - mouseDownPoint.y) > 3 {
            hasMoved = true
        }

        let clampedX = max(0, min(bounds.width, location.x))
        let clampedY = max(0, min(bounds.height, location.y))
        let normalizedPoint = screenToNormalizedCoords(CGPoint(x: clampedX, y: clampedY))

        if isZoomDragging {
            onZoomRegionUpdate?(normalizedPoint)
        } else if isDragging {
            if isCommandDragging {
                commandDragCurrentPoint = CGPoint(x: clampedX, y: clampedY)
            }
            onDragUpdate?(normalizedPoint, isCommandDragging)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isZoomDragging {
            isZoomDragging = false
            if hasMoved {
                onZoomRegionEnd?()
            }
        } else if isDragging {
            isDragging = false
            if !hasMoved {
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

    private func screenToNormalizedCoords(_ screenPoint: CGPoint) -> CGPoint {
        guard actualFrameRect.width > 0 && actualFrameRect.height > 0 else {
            guard containerSize.width > 0 && containerSize.height > 0 else { return .zero }
            return CGPoint(
                x: screenPoint.x / containerSize.width,
                y: 1.0 - (screenPoint.y / containerSize.height)
            )
        }

        let frameRelativeX = screenPoint.x - actualFrameRect.origin.x
        let frameRelativeY = screenPoint.y - actualFrameRect.origin.y
        let normalizedX = frameRelativeX / actualFrameRect.width
        let normalizedY = 1.0 - (frameRelativeY / actualFrameRect.height)
        return CGPoint(x: normalizedX, y: normalizedY)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        var highlightRects: [NSRect] = []
        for node in nodeData {
            guard let range = node.selectionRange, range.end > range.start else { continue }
            guard !node.text.isEmpty else { continue }

            let spanFractions = OCRTextLayoutEstimator.spanFractions(
                in: node.text,
                start: range.start,
                end: range.end
            )

            highlightRects.append(
                NSRect(
                    x: node.rect.origin.x + node.rect.width * spanFractions.start,
                    y: node.rect.origin.y,
                    width: node.rect.width * max(spanFractions.end - spanFractions.start, 0),
                    height: node.rect.height
                )
            )
        }

        if !highlightRects.isEmpty {
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            context.saveGState()
            context.setAlpha(0.4)
            context.beginTransparencyLayer(auxiliaryInfo: nil)

            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 1.0).setFill()

            for rect in highlightRects {
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }

            context.endTransparencyLayer()
            context.restoreGState()
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

            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.15).setFill()
            NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4).fill()

            let borderPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            borderPath.lineWidth = 1.5
            borderPath.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.95).setStroke()
            borderPath.stroke()
        }
    }
}
