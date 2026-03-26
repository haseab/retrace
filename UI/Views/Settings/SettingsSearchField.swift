import SwiftUI
import AppKit

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textField.window?.makeFirstResponder(textField)
        }

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
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
