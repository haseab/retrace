import SwiftUI
import Shared
import App
import AppKit

// MARK: - Gallery Result Card

struct GalleryResultCard: View {
    let result: SearchResult
    let thumbnailKey: String
    let thumbnailSize: CGSize
    let index: Int
    let isKeyboardSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var viewModel: SearchViewModel

    @State private var isHovered = false

    private var thumbnail: NSImage? {
        viewModel.thumbnailCache[thumbnailKey]
    }

    private var appIcon: NSImage? {
        viewModel.appIconCache[result.appBundleID ?? ""]
    }

    /// Display title: window name (c2) if available, otherwise app name
    private var displayTitle: String {
        if let windowName = result.windowName, !windowName.isEmpty {
            return windowName
        }
        return result.appName ?? "Unknown"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail (highlight is baked into the cropped thumbnail)
                thumbnailView

                // Title bar with app icon
                HStack(spacing: 8) {
                    // App icon
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                            .frame(width: 30, height: 30)
                    }

                    // Title and timestamp
                    VStack(alignment: .leading, spacing: 2) {
                        // Title with source badge
                        HStack(spacing: 6) {
                            Text(displayTitle)
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            // Source badge
                            Text(result.source == .native ? "Retrace" : "Rewind")
                                .font(.retraceTinyBold)
                                .foregroundColor(result.source == .native ? RetraceMenuStyle.actionBlue : .purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(result.source == .native ? RetraceMenuStyle.actionBlue.opacity(0.2) : Color.purple.opacity(0.2))
                                .cornerRadius(3)
                        }

                        // Timestamp and relevance
                        HStack(spacing: 6) {
                            Text(formatTimestamp(result.timestamp))
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.5))

                            Text("•")
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.3))

                            Text(String(format: "relevance: %.0f%%", result.relevanceScore * 100))
                                .font(.retraceMonoSmall)
                                .foregroundColor(.yellow.opacity(0.7))
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.3) : Color.white.opacity(0.1), lineWidth: isHovered ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.retraceAccent, lineWidth: 2)
                    .opacity(isKeyboardSelected ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.03), value: true)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color.black

            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else {
                SpinnerView(size: 16, lineWidth: 2, color: .white.opacity(0.4))
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
}

struct ResultsAreaHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Spotlight Search Field

/// NSViewRepresentable text field for the spotlight search overlay
/// Uses manual makeFirstResponder for reliable focus in borderless windows
struct SpotlightSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: (Bool) -> Void
    let onEscape: () -> Void
    var onTab: (() -> Void)? = nil
    var onBackTab: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var onArrowDown: (() -> Bool)? = nil
    var onArrowUp: (() -> Bool)? = nil
    var placeholder: String = "Search anything you have seen..."
    var refocusRequest: SearchFieldRefocusRequest = .initial

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 17, weight: .medium)
            ]
        )
        textField.font = .systemFont(ofSize: 17, weight: .medium)
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

        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onBackTab = onBackTab
        context.coordinator.onFocus = onFocus
        context.coordinator.onBlur = onBlur
        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onArrowUp = onArrowUp
        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            self.onFocus?()
        }
        textField.onCommandReturnCallback = {
            self.onSubmit(true)
        }

        // Focus the text field with retry logic for external monitors
        Log.info("\(searchLog)[FieldFocus] makeNSView scheduling initial focus", category: .ui)
        focusTextField(textField, attempt: 1, selectionBehavior: .caretAtEnd)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onBackTab = onBackTab
        context.coordinator.onFocus = onFocus
        context.coordinator.onBlur = onBlur
        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onArrowUp = onArrowUp
        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            self.onFocus?()
        }
        textField.onCommandReturnCallback = {
            self.onSubmit(true)
        }
        // Check if refocus was triggered
        if context.coordinator.lastRefocusRequest != refocusRequest {
            context.coordinator.lastRefocusRequest = refocusRequest
            focusTextField(textField, attempt: 1, selectionBehavior: refocusRequest.selectionBehavior)
        }
    }

    private func focusTextField(
        _ textField: FocusableTextField,
        attempt: Int,
        selectionBehavior: SearchFieldSelectionBehavior
    ) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(
                            textField,
                            attempt: attempt + 1,
                            selectionBehavior: selectionBehavior
                        )
                    }
                }
                return
            }
            self.performFocus(
                textField,
                in: window,
                attempt: attempt,
                selectionBehavior: selectionBehavior
            )
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func performFocus(
        _ textField: FocusableTextField,
        in window: NSWindow,
        attempt: Int,
        selectionBehavior: SearchFieldSelectionBehavior
    ) {
        let maxAttempts = 5

        // Activate the app first — required for makeKey to work on external monitors
        // where NSApp.isActive may be false when the overlay opens
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let success = window.makeFirstResponder(textField)

        // Ensure field editor exists for caret to appear
        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        // Restore either a caret-at-end focus or a select-all replacement affordance.
        if let fieldEditor = window.fieldEditor(false, for: textField) as? NSTextView {
            switch selectionBehavior {
            case .caretAtEnd:
                let endPosition = fieldEditor.string.count
                fieldEditor.setSelectedRange(NSRange(location: endPosition, length: 0))
            case .selectAll:
                fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.count))
            }
        }

        // Keep SwiftUI focus state in sync with programmatic AppKit focus restoration.
        if success {
            onFocus?()
        }

        // If the window isn't key yet (activation is async on external monitors),
        // retry so keystrokes actually reach the text field
        if !window.isKeyWindow && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(
                    textField,
                    attempt: attempt + 1,
                    selectionBehavior: selectionBehavior
                )
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(
                    textField,
                    attempt: attempt + 1,
                    selectionBehavior: selectionBehavior
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onEscape: onEscape,
            onTab: onTab,
            onBackTab: onBackTab,
            onFocus: onFocus,
            onBlur: onBlur,
            onArrowDown: onArrowDown,
            onArrowUp: onArrowUp
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: (Bool) -> Void
        var onEscape: () -> Void
        var onTab: (() -> Void)?
        var onBackTab: (() -> Void)?
        var onFocus: (() -> Void)?
        var onBlur: (() -> Void)?
        var onArrowDown: (() -> Bool)?
        var onArrowUp: (() -> Bool)?
        fileprivate var lastRefocusRequest: SearchFieldRefocusRequest = .initial

        init(
            text: Binding<String>,
            onSubmit: @escaping (Bool) -> Void,
            onEscape: @escaping () -> Void,
            onTab: (() -> Void)?,
            onBackTab: (() -> Void)?,
            onFocus: (() -> Void)?,
            onBlur: (() -> Void)?,
            onArrowDown: (() -> Bool)?,
            onArrowUp: (() -> Bool)?
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
            self.onTab = onTab
            self.onBackTab = onBackTab
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onArrowDown = onArrowDown
            self.onArrowUp = onArrowUp
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            onFocus?()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onBlur?()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                onSubmit(false)
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab?()
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onBackTab?()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return onArrowDown?() ?? false
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return onArrowUp?() ?? false
            }
            return false
        }
    }
}
