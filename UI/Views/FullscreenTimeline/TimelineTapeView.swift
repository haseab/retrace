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
    private let tapeHeight: CGFloat = 30
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
            let tapeOffset = centerX - currentFrameOffset

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
                    .frame(width: 22, height: 22)
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
            .overlay(
                // Selection highlight
                isSelected ? RoundedRectangle(cornerRadius: 2)
                    .fill(Color.retraceAccent.opacity(0.4))
                    .padding(2) : nil
            )
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
            return Color.sessionColor(for: bundleID)
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))

                        Text(viewModel.currentTimeString)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
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

                // Right side controls (zoom + more options)
                HStack(spacing: 12) {
                    ZoomControl(viewModel: viewModel)
                    MoreOptionsMenu(viewModel: viewModel)
                }
                .position(x: geometry.size.width - 120, y: -55)

                // Playhead vertical line (fixed at center)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: tapeHeight * 2.5)
                    .position(x: centerX, y: tapeHeight / 2)

                // Floating search input (appears above the datetime button when active)
                if viewModel.isDateSearchActive {
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
                        }
                    )
                    .position(x: centerX, y: -175)
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
                    .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovering || viewModel.isZoomSliderExpanded ? .white : .white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(viewModel.isZoomSliderExpanded ? Color.white.opacity(0.15) : Color.black.opacity(0.5))
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
                        .fill(Color.black.opacity(0.75))
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

// MARK: - More Options Menu

/// Three-dot menu button with dropdown options using SwiftUI popover
struct MoreOptionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var showMenu = false

    var body: some View {
        Button(action: { showMenu.toggle() }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isHovering || showMenu ? .white : .white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(showMenu ? Color.white.opacity(0.15) : Color.black.opacity(0.5))
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

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = (videoInfo.videoPath as NSString).lastPathComponent
        let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

        if !FileManager.default.fileExists(atPath: symlinkPath) {
            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: videoInfo.videoPath)
            } catch {
                completion(nil)
                return
            }
        }

        let url = URL(fileURLWithPath: symlinkPath)
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: videoInfo.timeInSeconds, preferredTimescale: 600)

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
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.white)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
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

    @State private var isHovering = false
    /// Accumulated position from completed drags
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private let suggestions = [
        ("30 min ago", "clock.arrow.circlepath"),
        ("yesterday", "calendar"),
        ("last week", "calendar.badge.clock")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and close button - this is the drag handle
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 4)

                Text("Jump to")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
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
                    onCancel: onCancel
                )
                .frame(height: 28)

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
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

            // Helper text
            Text("Try natural phrases like \"2 hours ago\" or \"Dec 15 3pm\"")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 12)
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
                    .font(.system(size: 10, weight: .medium))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
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

// MARK: - Date Search Field

/// Custom text field for date searching with auto-focus
struct DateSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = "Enter a date or time..."
        textField.placeholderAttributedString = NSAttributedString(
            string: "Enter a date or time...",
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
