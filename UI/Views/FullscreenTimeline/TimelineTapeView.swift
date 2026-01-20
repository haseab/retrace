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

    // Tape dimensions
    private let tapeHeight: CGFloat = 42
    private let blockSpacing: CGFloat = 2
    private var pixelsPerFrame: CGFloat { viewModel.pixelsPerFrame }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background (tap to clear selection)
            Rectangle()
                .fill(Color.black.opacity(0.85))
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.clearSelection()
                }

            // Scrollable tape content
            tapeContent

            // Fixed center playhead (on top of everything)
            playhead
        }
        .frame(height: tapeHeight)
    }

    // MARK: - Tape Content

    private var tapeContent: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let blocks = viewModel.appBlocks

            // Calculate offset to center current frame
            let currentFrameOffset = offsetForFrame(viewModel.currentIndex, in: blocks)
            let unclampedTapeOffset = centerX - currentFrameOffset

            // Calculate total tape width
            let totalTapeWidth = calculateTotalTapeWidth(blocks: blocks)

            // Clamp tape offset to prevent scrolling past content
            // - At the start: tape's left edge shouldn't go past centerX
            // - At the end: tape's right edge shouldn't go past centerX
            let maxOffset = centerX // Start of tape at center (for first frame)
            let minOffset = centerX - totalTapeWidth // End of tape at center (for last frame)

            let tapeOffset = max(minOffset, min(maxOffset, unclampedTapeOffset))

            HStack(spacing: blockSpacing) {
                ForEach(blocks) { block in
                    appBlockView(block: block)
                }
            }
            .offset(x: tapeOffset)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentIndex)
            .animation(.easeOut(duration: 0.2), value: viewModel.zoomLevel)
        }
    }

    // MARK: - App Block View

    private func appBlockView(block: AppBlock) -> some View {
        let isCurrentBlock = viewModel.currentIndex >= block.startIndex && viewModel.currentIndex <= block.endIndex
        let isSelectedBlock = viewModel.selectedFrameIndex.map { $0 >= block.startIndex && $0 <= block.endIndex } ?? false
        let color = blockColor(for: block)
        let blockWidth = block.width(pixelsPerFrame: pixelsPerFrame)

        return ZStack {
            // Background block
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: blockWidth, height: tapeHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelectedBlock ? Color.retraceAccent : (isCurrentBlock ? Color.white : Color.clear), lineWidth: isSelectedBlock ? 2 : 1.5)
                )
                .opacity(isCurrentBlock || isSelectedBlock ? 1.0 : 0.7)

            // Individual frame segments (clickable)
            HStack(spacing: 0) {
                ForEach(block.startIndex...block.endIndex, id: \.self) { frameIndex in
                    frameSegment(at: frameIndex, in: block)
                }
            }
            .frame(width: blockWidth, height: tapeHeight)

            // App icon (only show if block is wide enough)
            if blockWidth > 40, let bundleID = block.bundleID {
                appIcon(for: bundleID)
                    .frame(width: 30, height: 30)
                    .allowsHitTesting(false) // Allow clicks to pass through to frame segments
            }
        }
    }

    // MARK: - Frame Segment View

    private func frameSegment(at frameIndex: Int, in block: AppBlock) -> some View {
        let isSelected = viewModel.selectedFrameIndex == frameIndex

        return Rectangle()
            .fill(Color.clear)
            .frame(width: pixelsPerFrame, height: tapeHeight)
            // .overlay(
            //     // Selection highlight
            //     isSelected ? RoundedRectangle(cornerRadius: 2)
            //         .fill(Color.retraceAccent.opacity(0.4))
            //         .padding(2) : nil
            // )
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectFrame(at: frameIndex)
            }
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    // MARK: - Helper Functions

    /// Calculate the total width of the timeline tape
    private func calculateTotalTapeWidth(blocks: [AppBlock]) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }

        // Sum all block widths plus spacing between blocks
        let blocksWidth = blocks.reduce(0) { $0 + $1.width(pixelsPerFrame: pixelsPerFrame) }
        let totalSpacing = CGFloat(blocks.count - 1) * blockSpacing

        return blocksWidth + totalSpacing
    }

    /// Calculate the horizontal offset for a given frame index
    private func offsetForFrame(_ frameIndex: Int, in blocks: [AppBlock]) -> CGFloat {
        var offset: CGFloat = 0
        var blockCount = 0

        for block in blocks {
            if frameIndex >= block.startIndex && frameIndex <= block.endIndex {
                // Frame is in this block - calculate exact pixel position within block
                let framePositionInBlock = frameIndex - block.startIndex
                // Add spacing for all blocks before this one
                let spacingBeforeBlock = CGFloat(blockCount) * blockSpacing
                // Add exact pixel position within this block (centered on the frame's pixel)
                offset += CGFloat(framePositionInBlock) * pixelsPerFrame + pixelsPerFrame / 2 + spacingBeforeBlock
                break
            } else {
                // Add full block width (spacing handled separately)
                offset += block.width(pixelsPerFrame: pixelsPerFrame)
                blockCount += 1
            }
        }

        return offset
    }

    private func blockColor(for block: AppBlock) -> Color {
        if let bundleID = block.bundleID {
            return Color.segmentColor(for: bundleID)
        }
        return Color.gray.opacity(0.5)
    }

    private func appIcon(for bundleID: String) -> some View {
        Group {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback icon
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Fixed Playhead

    private var playhead: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2

            ZStack {
                // Datetime button (truly centered)
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.isDateSearchActive = true
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(viewModel.currentDateString)
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.white.opacity(0.7))

                        Text(viewModel.currentTimeString)
                            .font(.retraceMono)
                            .foregroundColor(.white)

                        Image(systemName: "chevron.down")
                            .font(.retraceTinyBold)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.15))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .position(x: centerX, y: -55)

                // Left side controls (hide UI + search)
                HStack(spacing: 12) {
                    ControlsToggleButton(viewModel: viewModel)
                    SearchButton(viewModel: viewModel)
                }
                .position(x: 120, y: -55)

                // Right side controls (zoom + more options)
                HStack(spacing: 12) {
                    ZoomControl(viewModel: viewModel)
                    MoreOptionsMenu(viewModel: viewModel)
                }
                .position(x: geometry.size.width - 100, y: -55)

                // Playhead vertical line (fixed at center)
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 3)
                    .fill(Color.white)
                    .frame(width: 6, height: tapeHeight * 2.5)
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
                            viewModel.isDateSearchActive = false
                            viewModel.dateSearchText = ""
                        },
                        enableFrameIDSearch: viewModel.enableFrameIDSearch,
                        viewModel: viewModel
                    )
                    .position(x: centerX, y: -175)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)).combined(with: .offset(y: 10)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                    ))
                }

                // Calendar picker (appears when calendar button is clicked)
                if viewModel.isCalendarPickerVisible {
                    CalendarPickerView(viewModel: viewModel)
                        .position(x: centerX, y: -280)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)).combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                        ))
                }
            }
        }
    }

}

// MARK: - Zoom Control

/// Zoom control that expands from a magnifier button to a slider
struct ZoomControl: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Zoom out icon (when expanded)
            if viewModel.isZoomSliderExpanded {
                Image(systemName: "minus.magnifyingglass")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                    .transition(.opacity.combined(with: .scale))
            }

            // Slider (when expanded)
            if viewModel.isZoomSliderExpanded {
                ZoomSlider(value: $viewModel.zoomLevel)
                    .frame(width: 100)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            }

            // Zoom in icon (when expanded)
            if viewModel.isZoomSliderExpanded {
                Image(systemName: "plus.magnifyingglass")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                    .transition(.opacity.combined(with: .scale))
            }

            // Zoom button (always visible)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.isZoomSliderExpanded.toggle()
                }
            }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(isHovering || viewModel.isZoomSliderExpanded ? .white : .white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(viewModel.isZoomSliderExpanded ? Color.white.opacity(0.15) : Color(white: 0.15))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, viewModel.isZoomSliderExpanded ? 12 : 0)
        .padding(.vertical, viewModel.isZoomSliderExpanded ? 8 : 0)
        .background(
            Group {
                if viewModel.isZoomSliderExpanded {
                    Capsule()
                        .fill(Color(white: 0.15))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
            }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isZoomSliderExpanded)
    }
}

// MARK: - Controls Toggle Button

/// Button to toggle timeline controls visibility
struct ControlsToggleButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            viewModel.toggleControlsVisibility()
        }) {
            Image(systemName: viewModel.areControlsHidden ? "rectangle.bottomhalf.inset.filled" : "rectangle.bottomhalf.filled")
                .font(.retraceCalloutMedium)
                .foregroundColor(isHovering ? .white : .white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color(white: 0.15))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .help(viewModel.areControlsHidden ? "Show Controls (Cmd+.)" : "Hide Controls (Cmd+.)")
    }
}

// MARK: - Search Button

/// Search button styled as an input field that opens the spotlight search overlay
struct SearchButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
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
            viewModel.clearSearchHighlight()
            viewModel.isSearchOverlayVisible = true
        }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(hasSearchQuery ? .white.opacity(0.9) : (isHovering ? .white.opacity(0.9) : .white.opacity(0.5)))

                Text(displayText)
                    .font(.retraceCaption)
                    .foregroundColor(hasSearchQuery ? .white.opacity(0.9) : (isHovering ? .white.opacity(0.8) : .white.opacity(0.4)))
                    .lineLimit(1)

                Spacer()

                // Keyboard shortcut hint
                Text("⌘K")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(isHovering ? .white.opacity(0.7) : .white.opacity(0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.1))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 160)
            .background(
                Capsule()
                    .fill(Color(white: 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
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

/// Three-dot menu button with dropdown options using SwiftUI popover
struct MoreOptionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var showMenu = false

    var body: some View {
        Button(action: { showMenu.toggle() }) {
            Image(systemName: "ellipsis")
                .font(.retraceCalloutMedium)
                .foregroundColor(isHovering || showMenu ? .white : .white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(showMenu ? Color.white.opacity(0.15) : Color(white: 0.15))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .popover(isPresented: $showMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            MoreOptionsPopoverContent(viewModel: viewModel, showMenu: $showMenu)
        }
    }
}

// MARK: - More Options Popover Content

/// Custom styled popover content for more options menu
struct MoreOptionsPopoverContent: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var showMenu: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Save Image", icon: "square.and.arrow.down") {
                showMenu = false
                saveImage()
            }

            MenuRow(title: "Copy Image", icon: "doc.on.doc", shortcut: "⇧⌘C") {
                showMenu = false
                copyImageToClipboard()
            }

            MenuRow(title: "Moment Deeplink", icon: "link") {
                showMenu = false
                // TODO: Implement moment deeplink
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            MenuRow(title: "Dashboard", icon: "square.grid.2x2") {
                showMenu = false
                openDashboard()
            }

            MenuRow(title: "Settings", icon: "gear") {
                showMenu = false
                openSettings()
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.9))
    }

    // MARK: - Actions

    private func saveImage() {
        getCurrentFrameImage { image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            savePanel.nameFieldStringValue = "retrace-\(formattedTimestamp()).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                    }
                }
            }
        }
    }

    private func copyImageToClipboard() {
        getCurrentFrameImage { image in
            guard let image = image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    private func openDashboard() {
        TimelineWindowController.shared.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openDashboard, object: nil)
        }
    }

    private func openSettings() {
        TimelineWindowController.shared.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }

    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
        if let image = viewModel.currentImage {
            completion(image)
            return
        }

        guard let videoInfo = viewModel.currentVideoInfo else {
            completion(nil)
            return
        }

        // Check if file exists (try both with and without .mp4 extension)
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                completion(nil)
                return
            }
        }

        // Determine the URL to use - if file already has .mp4 extension, use directly
        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = (actualVideoPath as NSString).lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

            if !FileManager.default.fileExists(atPath: symlinkPath) {
                do {
                    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                } catch {
                    completion(nil)
                    return
                }
            }
            url = URL(fileURLWithPath: symlinkPath)
        }
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        // Use integer arithmetic to avoid floating point precision issues
        let time = videoInfo.frameTimeCMTime

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: viewModel.currentTimestamp ?? Date())
    }
}

// MARK: - Menu Row

/// Styled menu row for the popover
struct MenuRow: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 18)

                Text(title)
                    .font(.retraceCaption)
                    .foregroundColor(.white)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.retraceCaption2)
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
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
    /// Accumulated position from completed drags
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private let suggestions = [
        ("30 min ago", "clock.arrow.circlepath"),
        ("yesterday", "calendar"),
        ("last week", "calendar.badge.clock")
    ]

    private var helperText: String {
        if enableFrameIDSearch {
            return "Enter a frame # or date like \"2 hours ago\""
        } else {
            return "Try natural phrases like \"2 hours ago\" or \"Dec 15 3pm\""
        }
    }

    private var placeholderText: String {
        if enableFrameIDSearch {
            return "Enter frame # or date..."
        } else {
            return "Enter a date or time..."
        }
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
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            // Quick suggestions
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.0) { suggestion in
                    SuggestionChip(
                        text: suggestion.0,
                        icon: suggestion.1
                    ) {
                        text = suggestion.0
                        onSubmit()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

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
                .foregroundColor(isCalendarButtonHovering ? .white : .white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isCalendarButtonHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(isCalendarButtonHovering ? 0.2 : 0.1), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isCalendarButtonHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            // Helper text
            Text(helperText)
                .font(.retraceCaption2)
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .frame(width: 380)
        .background(
            ZStack {
                // Dark solid background
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.08))

                // Subtle glass overlay
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Border
                RoundedRectangle(cornerRadius: 20)
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
                .frame(width: 280)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 12)

            // Right side: Time list
            timeListView
                .frame(width: 90)
        }
        .frame(height: 340)
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

            // Time list scroll area - always show 00:00 to 23:00
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { hour in
                        let hasFrames = hourHasFrames(hour)
                        TimeSlotButton(
                            hourValue: hour,
                            hasFrames: hasFrames,
                            selectedDate: viewModel.selectedCalendarDate
                        ) {
                            if hasFrames, let selectedDate = viewModel.selectedCalendarDate {
                                let cal = Calendar.current
                                var components = cal.dateComponents([.year, .month, .day], from: selectedDate)
                                components.hour = hour
                                components.minute = 0
                                if let targetDate = cal.date(from: components) {
                                    Task {
                                        await viewModel.navigateToHour(targetDate)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
        }
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
                                        .fill(Color.retraceAccent)
                                } else if isToday {
                                    Circle()
                                        .stroke(Color.retraceAccent, lineWidth: 1.5)
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
                                ? (isHovering ? Color.retraceAccent : Color.white.opacity(0.1))
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

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        textField.stringValue = text

        // Auto-focus when the field appears
        if context.coordinator.shouldFocus {
            DispatchQueue.main.async {
                guard let window = textField.window else { return }
                window.makeKey()
                window.makeFirstResponder(textField)

                // Ensure field editor is created for caret to appear
                if window.fieldEditor(false, for: textField) == nil {
                    _ = window.fieldEditor(true, for: textField)
                    window.makeFirstResponder(textField)
                }
            }
            context.coordinator.shouldFocus = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onCancel: () -> Void
        var shouldFocus = true

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

// MARK: - Preview

#if DEBUG
struct TimelineTapeView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            TimelineTapeView(
                viewModel: SimpleTimelineViewModel(coordinator: AppCoordinator()),
                width: 800
            )
        }
        .frame(width: 800, height: 100)
    }
}
#endif
