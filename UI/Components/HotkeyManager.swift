import AppKit
import Carbon.HIToolbox
import Shared

/// Manages global keyboard shortcuts for the application
/// Allows timeline to be triggered even when app is not in focus
public class HotkeyManager: NSObject {

    // MARK: - Singleton

    public static let shared = HotkeyManager()

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Registered hotkeys with their callbacks
    /// Uses character-based matching to support non-QWERTY keyboard layouts (DVORAK, Colemak, etc.)
    private var hotkeys: [(key: String, modifiers: NSEvent.ModifierFlags, callback: () -> Void)] = []

    /// Whether hotkeys are pending registration (waiting for permissions)
    private var pendingSetup = false

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Permission Check

    /// Check if accessibility permission is granted (required for global hotkeys)
    private func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Public API

    /// Register a global hotkey using key code (deprecated - use string-based registration)
    /// - Parameters:
    ///   - keyCode: The virtual key code
    ///   - modifiers: Modifier flags (command, shift, option, control)
    ///   - callback: Action to perform when hotkey is pressed
    @available(*, deprecated, message: "Use registerHotkey(key:modifiers:callback:) for keyboard layout compatibility")
    public func registerHotkey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        callback: @escaping () -> Void
    ) {
        // Convert key code to character string for layout-independent matching
        let key = stringForKeyCode(keyCode)
        registerHotkey(key: key, modifiers: modifiers, callback: callback)
    }

    /// Register hotkey using string key representation
    /// - Parameters:
    ///   - key: Key string (e.g., "Space", "T", "D")
    ///   - modifiers: Modifier flags
    ///   - callback: Action to perform
    /// - Note: Uses character-based matching to support all keyboard layouts (DVORAK, Colemak, etc.)
    public func registerHotkey(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        callback: @escaping () -> Void
    ) {
        Log.info("[HotkeyManager] Registering hotkey: key='\(key)' modifiers=\(modifierDescription(modifiers))", category: .ui)
        hotkeys.append((key, modifiers, callback))

        // Start monitoring if not already
        startEventTap()
    }

    /// Unregister all hotkeys
    public func unregisterAll() {
        Log.info("[HotkeyManager] Unregistering all hotkeys (count: \(hotkeys.count))", category: .ui)
        stopEventTap()
        hotkeys.removeAll()
    }

    /// Helper to describe modifiers for logging
    private func modifierDescription(_ modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    /// Retry setting up event tap if permissions are now available
    /// Call this after user grants accessibility permission
    public func retrySetupIfNeeded() {
        guard pendingSetup, !hotkeys.isEmpty else { return }
        startEventTap()
    }

    // MARK: - Event Tap

    private func startEventTap() {
        // Check accessibility permission first - don't attempt if not granted
        guard hasAccessibilityPermission() else {
            // Silently skip - hotkeys will be set up when permissions are granted
            // and the app restarts or when retrySetupIfNeeded() is called
            pendingSetup = true
            return
        }

        // Stop existing tap if any
        stopEventTap()

        // Create event tap for key down events
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("[HotkeyManager] Failed to create event tap. Check accessibility permissions.", category: .ui)
            return
        }

        pendingSetup = false

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap

        Log.info("[HotkeyManager] Global hotkey monitoring started", category: .ui)
    }

    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Handle tap disabled event
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable the tap
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Only handle key down events
        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Get the character for this key event, respecting keyboard layout
        let pressedKey = characterForEvent(event, keyCode: keyCode)

        // Convert CGEventFlags to NSEvent.ModifierFlags for comparison
        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }

        // Check if this matches any registered hotkey using character-based comparison
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        Log.info("[HotkeyManager] Key pressed: keyCode=\(keyCode) pressedKey='\(pressedKey)' eventModifiers=\(modifierDescription(eventModifiers))", category: .ui)
        for hotkey in hotkeys {
            // Compare characters case-insensitively for letter keys
            let keysMatch = pressedKey.lowercased() == hotkey.key.lowercased()
            let modifiersMatch = eventModifiers.intersection(relevantModifiers) == hotkey.modifiers.intersection(relevantModifiers)
            Log.info("[HotkeyManager] Comparing: pressedKey='\(pressedKey)' vs hotkeyKey='\(hotkey.key)' keysMatch=\(keysMatch) | eventMods=\(modifierDescription(eventModifiers)) vs hotkeyMods=\(modifierDescription(hotkey.modifiers)) modifiersMatch=\(modifiersMatch)", category: .ui)

            if keysMatch && modifiersMatch {
                // Execute callback on main thread
                let callback = hotkey.callback

                DispatchQueue.main.async {
                    callback()
                }

                // Consume the event to prevent system beep
                // Return nil to indicate the event was handled
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }

    /// Get the character for a CGEvent, respecting the current keyboard layout
    /// - Parameters:
    ///   - event: The CGEvent to extract the character from
    ///   - keyCode: The key code (used for special keys like Space, Return, etc.)
    /// - Returns: The character string representing the pressed key
    private func characterForEvent(_ event: CGEvent, keyCode: UInt16) -> String {
        // Handle special keys that don't have character representations
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        // Function keys
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            break
        }

        // Use UCKeyTranslate to get the keyboard-layout-aware base character
        // without any modifier influence. CGEvent.keyboardGetUnicodeString returns
        // the already-computed character with modifiers applied (e.g., Option+D = "∂"),
        // and setting event.flags doesn't change the cached Unicode string.
        // UCKeyTranslate with modifierKeyState=0 gives us the true base character,
        // respecting Dvorak/Colemak/etc. layouts.
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
                0, // No modifiers
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

        // Fallback: use positional key code mapping
        return stringForKeyCode(keyCode)
    }

    // MARK: - Key Code Mapping

    /// Convert a key code to its string representation (for special keys and fallback)
    /// - Note: This uses QWERTY positions for letter keys as a fallback only.
    ///         The primary matching uses character-based comparison via characterForEvent().
    private func stringForKeyCode(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        // Function keys
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        // Numbers
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
        // Letters (QWERTY positions - fallback only)
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        default:
            return "Key\(keyCode)"
        }
    }

    private func keyCodeForString(_ key: String) -> UInt16 {
        switch key.lowercased() {
        case "space": return 49
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "left", "leftarrow": return 123
        case "right", "rightarrow": return 124
        case "down", "downarrow": return 125
        case "up", "uparrow": return 126

        // Letters
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6

        // Numbers
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25

        // Function keys
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111

        default:
            // Try to get key code from first character
            if let char = key.lowercased().first {
                return keyCodeForCharacter(char)
            }
            return 0
        }
    }

    private func keyCodeForCharacter(_ char: Character) -> UInt16 {
        let keyMap: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47
        ]
        return keyMap[char] ?? 0
    }
}
