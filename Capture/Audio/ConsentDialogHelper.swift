import Foundation
import AppKit

/// Helper for showing consent dialogs related to audio capture
/// Used when user tries to enable potentially privacy-invasive features
public struct ConsentDialogHelper {

    // MARK: - Meeting Recording Consent

    /// Show consent dialog for recording system audio during meetings
    /// Returns: true if user consented, false if declined
    @MainActor
    public static func requestMeetingRecordingConsent() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow System Audio Recording During Meetings?"
        alert.informativeText = """
        You're about to enable system audio recording during video calls.

        ⚠️ Privacy Warning:
        This will record other participants' voices in your meetings without their knowledge.

        • Only enable this if you have explicit permission from all meeting participants
        • Many jurisdictions require consent from all parties for call recording
        • Unauthorized recording may violate privacy laws and platform terms of service

        Consider:
        • Your microphone will still be recorded (with Voice Isolation enabled)
        • System audio is automatically muted during meetings by default to protect privacy
        • You can record tutorials, videos, and media without this permission

        Do you want to proceed?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "I Have Consent - Enable")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    // MARK: - Voice Isolation Disable Warning

    /// Show warning when user tries to disable Voice Processing
    /// This feature is non-negotiable per privacy policy, so we show a warning and refuse
    @MainActor
    public static func showVoiceIsolationRequiredDialog() {
        let alert = NSAlert()
        alert.messageText = "Voice Isolation Cannot Be Disabled"
        alert.informativeText = """
        Voice Processing (Voice Isolation) is required by Retrace's privacy policy.

        Why it's required:
        • Removes background conversations to protect others' privacy
        • Prevents recording of nearby people without their consent
        • Provides hardware-accelerated echo cancellation
        • Ensures only YOUR voice is captured, not ambient audio

        This setting cannot be changed.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - System Audio Enable Confirmation

    /// Show confirmation when enabling system audio for the first time
    /// Returns: true if user wants to proceed
    @MainActor
    public static func confirmSystemAudioEnable() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable System Audio Recording?"
        alert.informativeText = """
        System audio recording will capture:
        • Music and videos you play
        • Notification sounds
        • Application audio
        • Video tutorials you watch

        Privacy Protection:
        ✓ System audio is automatically MUTED during video calls (Zoom, Teams, Meet, etc.)
        ✓ This prevents recording other people's voices without consent
        ✓ Your microphone will continue recording with Voice Isolation enabled

        To record during meetings, you'll need to separately enable that option and confirm you have consent.

        Enable system audio recording?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    // MARK: - Meeting Detected During System Audio

    /// Show notification when system audio is auto-muted due to meeting detection
    @MainActor
    public static func showMeetingDetectedNotification(appName: String?) {
        let notification = NSUserNotification()
        notification.title = "System Audio Muted"
        notification.informativeText = """
        Meeting detected\(appName.map { " in \($0)" } ?? ""). System audio recording has been automatically muted to protect privacy.
        """
        notification.soundName = nil  // Silent notification

        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Meeting Ended

    /// Show notification when meeting ends and system audio is re-enabled
    @MainActor
    public static func showMeetingEndedNotification() {
        let notification = NSUserNotification()
        notification.title = "System Audio Resumed"
        notification.informativeText = "Meeting ended. System audio recording has been automatically resumed."
        notification.soundName = nil

        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Permission Denied

    /// Show dialog when microphone permission is denied
    @MainActor
    public static func showMicrophonePermissionDenied() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = """
        Retrace needs access to your microphone to record audio.

        To enable microphone access:
        1. Open System Settings
        2. Go to Privacy & Security → Microphone
        3. Enable access for Retrace

        Would you like to open System Settings now?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Screen Recording Permission (for System Audio)

    /// Show dialog when screen recording permission is denied (needed for system audio)
    @MainActor
    public static func showScreenRecordingPermissionDenied() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        System audio capture requires Screen Recording permission.

        To enable screen recording access:
        1. Open System Settings
        2. Go to Privacy & Security → Screen Recording
        3. Enable access for Retrace
        4. Restart Retrace

        Would you like to open System Settings now?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - MenuBar Toggle Support

/// Helper for menu bar UI toggles
public struct AudioCaptureMenuBarHelper {

    /// Configuration for menu bar toggles
    public struct MenuBarState {
        public var screenCaptureEnabled: Bool
        public var systemAudioEnabled: Bool
        public var microphoneEnabled: Bool
        public var isInMeeting: Bool
        public var hasConsentedToMeetingRecording: Bool

        public init(
            screenCaptureEnabled: Bool = false,
            systemAudioEnabled: Bool = false,
            microphoneEnabled: Bool = true,
            isInMeeting: Bool = false,
            hasConsentedToMeetingRecording: Bool = false
        ) {
            self.screenCaptureEnabled = screenCaptureEnabled
            self.systemAudioEnabled = systemAudioEnabled
            self.microphoneEnabled = microphoneEnabled
            self.isInMeeting = isInMeeting
            self.hasConsentedToMeetingRecording = hasConsentedToMeetingRecording
        }
    }

    /// Validate and potentially show consent dialogs when toggling system audio
    @MainActor
    public static func handleSystemAudioToggle(
        currentState: MenuBarState,
        newValue: Bool
    ) async -> Bool {
        // If enabling system audio
        if newValue && !currentState.systemAudioEnabled {

            // First-time enable confirmation
            let confirmed = await ConsentDialogHelper.confirmSystemAudioEnable()
            if !confirmed {
                return false  // User cancelled
            }

            // If currently in a meeting, warn and request consent
            if currentState.isInMeeting && !currentState.hasConsentedToMeetingRecording {
                let consented = await ConsentDialogHelper.requestMeetingRecordingConsent()
                if consented {
                    // User consented - need to update config
                    return true
                } else {
                    // User declined - still enable system audio but it will be muted during meetings
                    return true
                }
            }
        }

        return true  // Allow toggle
    }

    /// Show warning when trying to disable Voice Isolation
    @MainActor
    public static func handleVoiceIsolationToggle() -> Bool {
        ConsentDialogHelper.showVoiceIsolationRequiredDialog()
        return false  // Don't allow disabling
    }
}
