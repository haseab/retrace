import SwiftUI
import AppKit

final class SettingsSearchTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Search results contain editable settings; keep their shortcuts with the focused control.
        guard let responder = window?.firstResponder,
              responder === self || responder === currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            if let editor = activeFieldEditor() {
                editor.selectAll(nil)
            } else {
                selectText(nil)
            }
            return true
        case "c":
            guard let editor = activeFieldEditor() else {
                return super.performKeyEquivalent(with: event)
            }
            editor.copy(nil)
            return true
        case "x":
            guard let editor = activeFieldEditor() else {
                return super.performKeyEquivalent(with: event)
            }
            editor.cut(nil)
            return true
        case "v":
            guard let editor = activeFieldEditor() else {
                return super.performKeyEquivalent(with: event)
            }
            editor.paste(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func activeFieldEditor() -> NSTextView? {
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

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let onEscape: () -> Void

    func makeNSView(context: Context) -> SettingsSearchTextField {
        let textField = SettingsSearchTextField()
        textField.placeholderAttributedString = NSAttributedString(
            string: "Search settings...",
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
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textField.window?.makeFirstResponder(textField)
        }

        return textField
    }

    func updateNSView(_ textField: SettingsSearchTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsSearchField

        init(_ parent: SettingsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
