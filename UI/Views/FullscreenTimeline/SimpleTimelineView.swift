import SwiftUI
import AVKit
import Shared
import App

/// Redesigned fullscreen timeline view with scrolling tape and fixed playhead
/// The timeline tape moves left/right while the playhead stays fixed in center
public struct SimpleTimelineView: View {

    // MARK: - Properties

    @ObservedObject private var viewModel: SimpleTimelineViewModel
    @State private var hasInitialized = false

    let coordinator: AppCoordinator
    let onClose: () -> Void

    // MARK: - Initialization

    /// Initialize with an external view model (scroll events handled by TimelineWindowController)
    public init(coordinator: AppCoordinator, viewModel: SimpleTimelineViewModel, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Full screen frame display
                frameDisplay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Timeline tape overlay at bottom
                VStack {
                    Spacer()
                    TimelineTapeView(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                    .padding(.bottom, 20)
                }

                // Close button (top-right)
                VStack {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    Spacer()
                }
                .padding(.spacingL)

                // App info overlay (top-left) - timestamp now on playhead
                VStack {
                    HStack {
                        appInfoOverlay
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.spacingL)

                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }

                // Error overlay
                if let error = viewModel.error {
                    errorOverlay(error)
                }

                // Delete confirmation dialog
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
            }
            .background(Color.black)
            .ignoresSafeArea()
            .onAppear {
                if !hasInitialized {
                    hasInitialized = true
                    Task {
                        await viewModel.loadMostRecentFrame()
                    }
                }
            }
            // Note: Scroll events are now captured by TimelineWindowController
            // at the window level for more reliable event handling
        }
    }

    // MARK: - Frame Display

    @ViewBuilder
    private var frameDisplay: some View {
        if let videoInfo = viewModel.currentVideoInfo {
            // Video-based frame (Rewind) with URL overlay
            FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                SimpleVideoFrameView(videoInfo: videoInfo)
            }
        } else if let image = viewModel.currentImage {
            // Static image (Retrace) with URL overlay
            FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        } else if !viewModel.isLoading {
            // Empty state
            VStack(spacing: .spacingM) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.3))
                Text("No frames recorded")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Info Overlay

    private var appInfoOverlay: some View {
        Group {
            if let frame = viewModel.currentFrame, let appName = frame.metadata.appName {
                HStack(spacing: .spacingS) {
                    Circle()
                        .fill(Color.sessionColor(for: frame.metadata.appBundleID ?? ""))
                        .frame(width: 10, height: 10)
                    Text(appName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .fill(Color.black.opacity(0.5))
                )
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: .spacingM) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.retraceWarning)
            Text(message)
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.spacingL)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusM)
                .fill(Color.black.opacity(0.8))
        )
    }
}

// MARK: - Simple Video Frame View

/// Simplified video frame view using AVPlayer
/// Optimized to only reload video when path changes, just seek when frame changes
struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false

        // Create player immediately
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        playerView.player = player

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        guard let player = playerView.player else { return }

        let currentPath = context.coordinator.currentVideoPath
        let currentFrameIdx = context.coordinator.currentFrameIndex

        print("[VideoView] updateNSView: frameIndex=\(videoInfo.frameIndex), coordFrameIdx=\(currentFrameIdx ?? -1)")

        // If same video and same frame, nothing to do
        if currentPath == videoInfo.videoPath && currentFrameIdx == videoInfo.frameIndex {
            print("[VideoView] Same video and frame, skipping")
            return
        }

        // Update coordinator state
        context.coordinator.currentFrameIndex = videoInfo.frameIndex

        // If same video, just seek (fast path - no flickering)
        if currentPath == videoInfo.videoPath {
            print("[VideoView] Same video, SEEKING to frame \(videoInfo.frameIndex)")
            let time = CMTime(seconds: videoInfo.timeInSeconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        print("[VideoView] LOADING NEW VIDEO: \(videoInfo.videoPath.suffix(30))")

        // Different video - need to load new player item
        context.coordinator.currentVideoPath = videoInfo.videoPath

        // Check if file exists
        guard FileManager.default.fileExists(atPath: videoInfo.videoPath) else {
            Log.error("[SimpleVideoFrameView] Video file not found: \(videoInfo.videoPath)", category: .app)
            return
        }

        // Create symlink with .mp4 extension (Rewind videos don't have extensions)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = (videoInfo.videoPath as NSString).lastPathComponent
        let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

        // Only create symlink if it doesn't exist
        if !FileManager.default.fileExists(atPath: symlinkPath) {
            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: videoInfo.videoPath)
            } catch {
                Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                return
            }
        }

        // Load new video
        let url = URL(fileURLWithPath: symlinkPath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        // Clear old observers
        context.coordinator.observers.forEach { $0.invalidate() }
        context.coordinator.observers.removeAll()

        player.replaceCurrentItem(with: playerItem)

        // Seek to frame when ready
        let targetTime = videoInfo.timeInSeconds
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { item, _ in
            guard item.status == .readyToPlay else { return }

            let time = CMTime(seconds: targetTime, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.pause()
            }
        }

        context.coordinator.observers.append(observer)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var observers: [NSKeyValueObservation] = []
        var currentVideoPath: String?
        var currentFrameIndex: Int?

        deinit {
            observers.forEach { $0.invalidate() }
        }
    }
}

// MARK: - Frame With URL Overlay

/// Wraps a frame display with an interactive URL bounding box overlay
/// Shows a dotted rectangle when hovering over a detected URL, with click-to-open functionality
struct FrameWithURLOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onURLClicked: () -> Void
    let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The actual frame content
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Text selection overlay (always present for drag selection)
                if !viewModel.ocrNodes.isEmpty {
                    TextSelectionOverlay(
                        viewModel: viewModel,
                        containerSize: geometry.size,
                        onDragStart: { point in
                            viewModel.startDragSelection(at: point)
                        },
                        onDragUpdate: { point in
                            viewModel.updateDragSelection(to: point)
                        },
                        onDragEnd: {
                            viewModel.endDragSelection()
                        },
                        onClearSelection: {
                            viewModel.clearTextSelection()
                        }
                    )
                }

                // URL bounding box overlay (if URL detected)
                if let box = viewModel.urlBoundingBox {
                    URLBoundingBoxOverlay(
                        boundingBox: box,
                        containerSize: geometry.size,
                        isHovering: viewModel.isHoveringURL,
                        onHoverChanged: { hovering in
                            viewModel.isHoveringURL = hovering
                        },
                        onClick: {
                            viewModel.openURLInBrowser()
                            // Close the timeline view after opening URL
                            onURLClicked()
                        }
                    )
                }
            }
        }
    }
}

// MARK: - URL Bounding Box Overlay

/// Interactive overlay that shows a dotted rectangle around a detected URL
/// Changes cursor to pointer on hover and opens URL on click
struct URLBoundingBoxOverlay: NSViewRepresentable {
    let boundingBox: RewindDataSource.URLBoundingBox
    let containerSize: CGSize
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
        // Calculate the actual frame rect from normalized coordinates
        // Note: The bounding box coordinates are normalized (0.0-1.0)
        let rect = NSRect(
            x: boundingBox.x * containerSize.width,
            y: (1.0 - boundingBox.y - boundingBox.height) * containerSize.height, // Flip Y (AppKit origin is bottom-left)
            width: boundingBox.width * containerSize.width,
            height: boundingBox.height * containerSize.height
        )

        nsView.boundingRect = rect
        nsView.isHoveringURL = isHovering
        nsView.url = boundingBox.url
        nsView.needsDisplay = true
    }
}

/// Custom NSView for URL overlay with mouse tracking
/// Only intercepts mouse events inside the bounding rect, passes through events outside
class URLOverlayView: NSView {
    var boundingRect: NSRect = .zero
    var isHoveringURL: Bool = false
    var url: String = ""
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking area
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        // Add new tracking area for the bounding box
        guard !boundingRect.isEmpty else { return }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .mouseMoved]
        trackingArea = NSTrackingArea(rect: boundingRect, options: options, owner: self, userInfo: nil)
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
        if boundingRect.contains(location) {
            onClick?()
        } else {
            // Pass event to next responder (TextSelectionView)
            super.mouseDown(with: event)
        }
    }

    /// Only accept events inside the bounding rect - pass through elsewhere
    override func hitTest(_ point: NSPoint) -> NSView? {
        if boundingRect.contains(point) {
            return super.hitTest(point)
        }
        // Return nil to let the event pass through to views below
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Only draw when hovering and we have a valid bounding rect
        guard isHoveringURL, !boundingRect.isEmpty else { return }

        // Draw dotted rectangle around URL
        let path = NSBezierPath(roundedRect: boundingRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2.0

        // Set up dotted line pattern
        let dashPattern: [CGFloat] = [6, 4]
        path.setLineDash(dashPattern, count: 2, phase: 0)

        // Green highlight when hovering
        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.9).setStroke()
        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.15).setFill()
        path.stroke()
        path.fill()
    }
}

// MARK: - Text Selection Overlay

/// Overlay for selecting text from OCR nodes via click-drag or Cmd+A
/// Highlights selected text character-by-character in light purple
struct TextSelectionOverlay: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let onDragStart: (CGPoint) -> Void
    let onDragUpdate: (CGPoint) -> Void
    let onDragEnd: () -> Void
    let onClearSelection: () -> Void

    func makeNSView(context: Context) -> TextSelectionView {
        let view = TextSelectionView()
        view.onDragStart = onDragStart
        view.onDragUpdate = onDragUpdate
        view.onDragEnd = onDragEnd
        view.onClearSelection = onClearSelection
        return view
    }

    func updateNSView(_ nsView: TextSelectionView, context: Context) {
        // Build node data with selection ranges
        nsView.nodeData = viewModel.ocrNodes.map { node in
            let rect = NSRect(
                x: node.x * containerSize.width,
                y: (1.0 - node.y - node.height) * containerSize.height, // Flip Y
                width: node.width * containerSize.width,
                height: node.height * containerSize.height
            )
            let selectionRange = viewModel.getSelectionRange(for: node.id)
            return TextSelectionView.NodeData(
                id: node.id,
                rect: rect,
                text: node.text,
                selectionRange: selectionRange
            )
        }

        nsView.containerSize = containerSize
        nsView.isDraggingSelection = viewModel.dragStartPoint != nil
        nsView.needsDisplay = true
    }
}

/// Custom NSView for text selection with mouse tracking
class TextSelectionView: NSView {
    /// Data for each OCR node including selection state
    struct NodeData {
        let id: Int
        let rect: NSRect
        let text: String
        let selectionRange: (start: Int, end: Int)?  // Character range selected within this node
    }

    var nodeData: [NodeData] = []
    var containerSize: CGSize = .zero
    var isDraggingSelection: Bool = false

    var onDragStart: ((CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?

    private var isDragging = false
    private var hasMoved = false  // Track if mouse moved during drag
    private var mouseDownPoint: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false

        // Convert to normalized coordinates
        guard containerSize.width > 0 && containerSize.height > 0 else { return }
        let normalizedPoint = CGPoint(
            x: location.x / containerSize.width,
            y: 1.0 - (location.y / containerSize.height) // Flip Y back
        )

        isDragging = true
        onDragStart?(normalizedPoint)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let location = convert(event.locationInWindow, from: nil)

        // Check if mouse actually moved (more than 3 pixels to avoid micro-movements)
        let distance = hypot(location.x - mouseDownPoint.x, location.y - mouseDownPoint.y)
        if distance > 3 {
            hasMoved = true
        }

        // Clamp to bounds
        let clampedX = max(0, min(bounds.width, location.x))
        let clampedY = max(0, min(bounds.height, location.y))

        // Convert to normalized coordinates
        guard containerSize.width > 0 && containerSize.height > 0 else { return }
        let normalizedPoint = CGPoint(
            x: clampedX / containerSize.width,
            y: 1.0 - (clampedY / containerSize.height) // Flip Y back
        )

        onDragUpdate?(normalizedPoint)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }

        isDragging = false

        // If mouse didn't move, this was a click - clear selection
        if !hasMoved {
            onClearSelection?()
        } else {
            onDragEnd?()
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Light purple color for selection highlight
        let selectionColor = NSColor(red: 0.7, green: 0.5, blue: 0.9, alpha: 0.4)

        // Draw character-level selections
        for node in nodeData {
            guard let range = node.selectionRange, range.end > range.start else { continue }

            let textLength = node.text.count
            guard textLength > 0 else { continue }

            // Calculate the portion of the node rect to highlight
            let startFraction = CGFloat(range.start) / CGFloat(textLength)
            let endFraction = CGFloat(range.end) / CGFloat(textLength)

            let highlightRect = NSRect(
                x: node.rect.origin.x + node.rect.width * startFraction,
                y: node.rect.origin.y,
                width: node.rect.width * (endFraction - startFraction),
                height: node.rect.height
            )

            selectionColor.setFill()
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 2, yRadius: 2)
            path.fill()
        }
    }
}

// MARK: - Delete Confirmation Dialog

/// Modal dialog for confirming frame or segment deletion
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
            // Dimmed background
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Dialog card
            VStack(spacing: 20) {
                // Icon
                Image(systemName: "trash.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.red.opacity(0.8))

                // Title
                Text("Delete Frame?")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                // Description
                VStack(spacing: 8) {
                    Text("Choose to delete this frame or the entire segment.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))

                    Text("Note: Removes from database only. Video files remain on disk.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .italic()
                }
                .multilineTextAlignment(.center)

                // Buttons
                VStack(spacing: 10) {
                    // Delete Frame button
                    Button(action: onDeleteFrame) {
                        HStack(spacing: 10) {
                            Image(systemName: "square")
                                .font(.system(size: 14))
                            Text("Delete Frame")
                                .font(.system(size: 14, weight: .medium))
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
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }

                    // Delete Segment button
                    Button(action: onDeleteSegment) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 14))
                            Text("Delete Segment (\(segmentFrameCount) frames)")
                                .font(.system(size: 14, weight: .semibold))
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
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }

                    // Cancel button
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .medium))
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
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
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

// MARK: - Preview

#if DEBUG
struct SimpleTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SimpleTimelineView(
            coordinator: coordinator,
            viewModel: SimpleTimelineViewModel(coordinator: coordinator),
            onClose: {}
        )
        .frame(width: 1920, height: 1080)
    }
}
#endif
