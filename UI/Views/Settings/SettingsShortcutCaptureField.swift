import SwiftUI
import AppKit
import Carbon
import Shared
import App

struct SettingsShortcutKey: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    static let empty = SettingsShortcutKey(key: "", modifiers: [])

    var isEmpty: Bool {
        key.isEmpty
    }

    init(from config: ShortcutConfig) {
        self.key = config.key
        self.modifiers = config.modifiers.nsModifiers
    }

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    var displayString: String {
        if isEmpty { return "None" }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts.joined(separator: " ")
    }

    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    var toConfig: ShortcutConfig {
        ShortcutConfig(key: key, modifiers: ShortcutModifiers(from: modifiers))
    }
}

struct SettingsShortcutCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var capturedShortcut: SettingsShortcutKey
    let otherShortcuts: [SettingsShortcutKey]
    let onDuplicateAttempt: () -> Void
    let onShortcutCaptured: () -> Void

    func makeNSView(context: Context) -> SettingsShortcutCaptureNSView {
        let view = SettingsShortcutCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SettingsShortcutCaptureNSView, context: Context) {
        context.coordinator.parent = self
        nsView.isRecordingEnabled = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator {
        var parent: SettingsShortcutCaptureField

        init(_ parent: SettingsShortcutCaptureField) {
            self.parent = parent
        }

        func handleKeyPress(event: NSEvent) {
            guard parent.isRecording else { return }

            let keyName = mapKeyCodeToString(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

            if event.keyCode == 53 {
                parent.isRecording = false
                return
            }

            if event.keyCode == 51 && modifiers.isEmpty {
                parent.capturedShortcut = .empty
                parent.isRecording = false
                DispatchQueue.main.async { [self] in
                    self.parent.onShortcutCaptured()
                }
                return
            }

            guard !modifiers.isEmpty else { return }

            let newShortcut = SettingsShortcutKey(key: keyName, modifiers: modifiers)
            if parent.otherShortcuts.contains(newShortcut) {
                parent.onDuplicateAttempt()
                parent.isRecording = false
                return
            }

            parent.capturedShortcut = newShortcut
            parent.isRecording = false
            DispatchQueue.main.async { [self] in
                self.parent.onShortcutCaptured()
            }
        }

        private func mapKeyCodeToString(keyCode: UInt16, characters: String?) -> String {
            switch keyCode {
            case 49: return "Space"
            case 36: return "Return"
            case 53: return "Escape"
            case 51: return "Delete"
            case 48: return "Tab"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 23: return "5"
            case 22: return "6"
            case 26: return "7"
            case 28: return "8"
            case 25: return "9"
            case 29: return "0"
            default:
                if let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                   let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) {
                    let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
                    let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
                    var deadKeyState: UInt32 = 0
                    var length: Int = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        keyboardLayout,
                        keyCode,
                        UInt16(kUCKeyActionDown),
                        0,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        4,
                        &length,
                        &chars
                    )
                    if status == noErr, length > 0 {
                        return String(utf16CodeUnits: chars, count: length).uppercased()
                    }
                }
                return "Key\(keyCode)"
            }
        }
    }
}

final class SettingsShortcutCaptureNSView: NSView {
    weak var coordinator: SettingsShortcutCaptureField.Coordinator?
    var isRecordingEnabled = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isRecordingEnabled {
            coordinator?.handleKeyPress(event: event)
        } else {
            super.keyDown(with: event)
        }
    }
}
