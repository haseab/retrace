import AppKit
import Carbon.HIToolbox

/// Manages global keyboard shortcuts for the application
/// Allows timeline to be triggered even when app is not in focus
public class HotkeyManager: NSObject {

    // MARK: - Singleton

    public static let shared = HotkeyManager()

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Registered hotkeys with their callbacks
    private var hotkeys: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, callback: () -> Void)] = []

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

    /// Register a global hotkey
    /// - Parameters:
    ///   - keyCode: The virtual key code
    ///   - modifiers: Modifier flags (command, shift, option, control)
    ///   - callback: Action to perform when hotkey is pressed
    public func registerHotkey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        callback: @escaping () -> Void
    ) {
        // Add to hotkeys array
        hotkeys.append((keyCode, modifiers, callback))

        // Start monitoring if not already
        startEventTap()
    }

    /// Register hotkey using string key representation
    /// - Parameters:
    ///   - key: Key string (e.g., "Space", "T", "D")
    ///   - modifiers: Modifier flags
    ///   - callback: Action to perform
    public func registerHotkey(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        callback: @escaping () -> Void
    ) {
        let keyCode = keyCodeForString(key)
        registerHotkey(keyCode: keyCode, modifiers: modifiers, callback: callback)
    }

    /// Unregister all hotkeys
    public func unregisterAll() {
        stopEventTap()
        hotkeys.removeAll()
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
            print("[HotkeyManager] Failed to create event tap. Check accessibility permissions.")
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

        print("[HotkeyManager] Global hotkey monitoring started")
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

        // Convert CGEventFlags to NSEvent.ModifierFlags for comparison
        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }

        // Check if this matches any registered hotkey
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        for hotkey in hotkeys {
            if keyCode == hotkey.keyCode &&
               eventModifiers.intersection(relevantModifiers) == hotkey.modifiers.intersection(relevantModifiers) {

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

    // MARK: - Key Code Mapping

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
