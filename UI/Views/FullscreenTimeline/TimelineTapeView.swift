import SwiftUI
import Shared
import App

/// Timeline tape view that scrolls horizontally with a fixed center playhead
/// Groups consecutive frames by app and displays app icons
public struct TimelineTapeView: View {

    // MARK: - Properties

    @ObservedObject var viewModel: SimpleTimelineViewModel
    let width: CGFloat

    // Tape dimensions
    private let tapeHeight: CGFloat = 40
    private let blockSpacing: CGFloat = 2
    private var pixelsPerFrame: CGFloat { TimelineConfig.pixelsPerFrame }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.85))

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
            let _ = print("[Tape] currentIndex=\(viewModel.currentIndex), offset=\(tapeOffset), blocks=\(blocks.count)")

            HStack(spacing: blockSpacing) {
                ForEach(blocks) { block in
                    appBlockView(block: block)
                }
            }
            .offset(x: tapeOffset)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentIndex)
        }
    }

    // MARK: - App Block View

    private func appBlockView(block: AppBlock) -> some View {
        let isCurrentBlock = viewModel.currentIndex >= block.startIndex && viewModel.currentIndex <= block.endIndex
        let color = blockColor(for: block)

        return ZStack {
            // Background block
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: block.width, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrentBlock ? Color.white : Color.clear, lineWidth: 1.5)
                )
                .opacity(isCurrentBlock ? 1.0 : 0.7)

            // App icon (only show if block is wide enough)
            if block.width > 40, let bundleID = block.bundleID {
                appIcon(for: bundleID)
                    .frame(width: 22, height: 22)
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
                offset += block.width
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
                // Playhead indicator (fixed at center) - Rewind style
                VStack(spacing: 0) {
                    // Normal date/time display - clickable button with Rewind-style rounded borders
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
                    .offset(y: -12)
                    .opacity(viewModel.isDateSearchActive ? 0.3 : 1.0)
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                    // Simple white vertical line (thicker and taller)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 3, height: tapeHeight * 2.5)
                }
                .position(x: centerX, y: tapeHeight / 2)
                .animation(.easeOut(duration: 0.2), value: viewModel.isDateSearchActive)

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
                    .position(x: centerX, y: -140)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)).combined(with: .offset(y: 10)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                    ))
                }
            }
        }
    }

}

// MARK: - Floating Date Search Panel

/// Elegant floating panel for natural language date/time search
struct FloatingDateSearchPanel: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    private let suggestions = [
        ("30 min ago", "clock.arrow.circlepath"),
        ("yesterday", "calendar"),
        ("last week", "calendar.badge.clock")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and close button
            HStack {
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

            // Search input field
            HStack(spacing: 14) {
                Image(systemName: "clock")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.retraceAccent)

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
                // Blur background
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Glass overlay
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.06)
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
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.05)
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
class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
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
