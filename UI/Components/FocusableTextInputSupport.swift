import AppKit
import SwiftUI

final class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    var onCancelCallback: (() -> Void)?
    var onClickCallback: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClickCallback?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "g":
            onCancelCallback?()
            return true
        case "a":
            if let editor = activeFieldEditor() {
                editor.selectAll(nil)
            } else {
                selectText(nil)
            }
            return true
        case "c":
            if let editor = activeFieldEditor() {
                editor.copy(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        case "x":
            if let editor = activeFieldEditor() {
                editor.cut(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        case "v":
            if let editor = activeFieldEditor() {
                editor.paste(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    func activeFieldEditor() -> NSTextView? {
        if let editor = currentEditor() as? NSTextView {
            return editor
        }

        if window?.firstResponder !== self {
            _ = window?.makeFirstResponder(self)
        }

        if let editor = currentEditor() as? NSTextView {
            return editor
        }

        return window?.fieldEditor(true, for: self) as? NSTextView
    }
}

struct FocusableTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font: NSFont = .systemFont(ofSize: 13, weight: .regular)
    var onSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var isFocused: (() -> Bool)? = nil
    var setFocused: ((Bool) -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.stringValue = text
        configure(textField, coordinator: context.coordinator)
        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        configure(textField, coordinator: context.coordinator)
        syncFocusIfNeeded(for: textField)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onEscape: onEscape,
            isFocused: isFocused,
            setFocused: setFocused,
            onBlur: onBlur
        )
    }

    private func configure(_ textField: FocusableTextField, coordinator: Coordinator) {
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: font
            ]
        )
        textField.font = font
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true
        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            setFocused?(true)
            onClick?()
        }
    }

    private func syncFocusIfNeeded(for textField: FocusableTextField) {
        guard let isFocused else { return }
        Self.syncResponderFocus(for: textField, wantsFocus: isFocused())
    }

    private static func syncResponderFocus(for textField: FocusableTextField, wantsFocus: Bool) {
        guard let window = textField.window else { return }

        let currentEditor = textField.currentEditor()
        let isCurrentResponder = window.firstResponder === textField || window.firstResponder === currentEditor

        if wantsFocus {
            if !isCurrentResponder {
                _ = window.makeFirstResponder(textField)
            }
            return
        }

        guard isCurrentResponder else { return }

        if !window.makeFirstResponder(nil), let contentView = window.contentView {
            _ = window.makeFirstResponder(contentView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: (() -> Void)?
        let onEscape: (() -> Void)?
        let isFocused: (() -> Bool)?
        let setFocused: ((Bool) -> Void)?
        let onBlur: (() -> Void)?

        init(
            text: Binding<String>,
            onSubmit: (() -> Void)?,
            onEscape: (() -> Void)?,
            isFocused: (() -> Bool)?,
            setFocused: ((Bool) -> Void)?,
            onBlur: (() -> Void)?
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
            self.isFocused = isFocused
            self.setFocused = setFocused
            self.onBlur = onBlur
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            setFocused?(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if isFocused?() == true {
                setFocused?(false)
            }
            onBlur?()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               let onSubmit {
                onSubmit()
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let onEscape {
                onEscape()
                return true
            }

            return false
        }
    }
}

enum FocusableTextInputSupport {
    static func isEditableTextInputView(_ view: NSView?) -> Bool {
        guard let view else { return false }

        if let textView = view as? NSTextView, textView.isEditable {
            return true
        }

        if let textField = view as? NSTextField, textField.isEditable {
            return true
        }

        return isEditableTextInputView(view.superview)
    }

    static func shouldDeferRightClickToTextInput(window: NSWindow, event: NSEvent) -> Bool {
        if let contentView = window.contentView {
            let pointInContentView = contentView.convert(event.locationInWindow, from: nil)
            if isEditableTextInputView(contentView.hitTest(pointInContentView)) {
                return true
            }
        }

        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            let pointInTextView = textView.convert(event.locationInWindow, from: nil)
            if textView.bounds.contains(pointInTextView) {
                return true
            }
        }

        if let textField = window.firstResponder as? NSTextField, textField.isEditable {
            let pointInTextField = textField.convert(event.locationInWindow, from: nil)
            if textField.bounds.contains(pointInTextField) {
                return true
            }
        }

        return false
    }
}
