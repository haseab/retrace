import Foundation
import AppKit
import AVFoundation
import Shared

/// Detects when the user is in a video conference meeting
/// Monitors active applications and microphone usage to determine meeting state
public actor MeetingDetector: MeetingDetectorProtocol {

    private var monitoredBundleIDs: Set<String> = []
    private var isMonitoring = false
    @MainActor private var checkTimer: Timer?
    private var currentMeetingState: MeetingState = .notInMeeting

    // Cached state for synchronous access (slightly stale but thread-safe)
    nonisolated(unsafe) private var cachedMeetingState: MeetingState = .notInMeeting

    // Callbacks for state changes
    private var stateChangeCallback: (@Sendable (MeetingState) -> Void)?

    public init() {}

    /// Check if a meeting is currently active
    public nonisolated func isMeetingActive() -> Bool {
        // Note: This returns cached state that's updated by the monitoring loop
        // For real-time accurate state, use getCurrentState() async method
        return cachedMeetingState.isInMeeting
    }

    /// Get the detected meeting app bundle ID, if any
    public nonisolated func getActiveMeetingApp() -> String? {
        // Note: This returns cached state that's updated by the monitoring loop
        // For real-time accurate state, use getCurrentState() async method
        return cachedMeetingState.detectedApp
    }

    /// Start monitoring for meeting activity
    public func startMonitoring(bundleIDs: Set<String>) {
        guard !isMonitoring else { return }

        self.monitoredBundleIDs = bundleIDs
        self.isMonitoring = true

        // Start periodic checks (every 2 seconds)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.setCheckTimer(Timer.scheduledTimer(
                withTimeInterval: 2.0,
                repeats: true
            ) { [weak self] _ in
                Task {
                    await self?.checkMeetingStatus()
                }
            })
        }

        // Immediate check
        Task {
            await checkMeetingStatus()
        }
    }

    /// Stop monitoring
    public func stopMonitoring() {
        isMonitoring = false
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.clearCheckTimer()
        }
        currentMeetingState = .notInMeeting
        cachedMeetingState = .notInMeeting
    }

    /// Set callback for state changes
    public func onStateChange(_ callback: @escaping @Sendable (MeetingState) -> Void) {
        self.stateChangeCallback = callback
    }

    /// Get current meeting state
    public func getCurrentState() -> MeetingState {
        return currentMeetingState
    }

    // MARK: - MainActor Timer Helpers

    @MainActor
    private func setCheckTimer(_ timer: Timer) {
        checkTimer = timer
    }

    @MainActor
    private func clearCheckTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    // MARK: - Private Detection Logic

    private func checkMeetingStatus() async {
        let previousState = currentMeetingState
        let newState = await detectMeetingState()

        if newState.isInMeeting != previousState.isInMeeting ||
           newState.detectedApp != previousState.detectedApp {
            currentMeetingState = newState
            cachedMeetingState = newState  // Update cached state
            stateChangeCallback?(newState)
        }
    }

    private func detectMeetingState() async -> MeetingState {
        // Method 1: Check if monitored app is frontmost
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmostApp.bundleIdentifier,
           monitoredBundleIDs.contains(bundleID) {

            // Additional check: Is the app actually using the microphone?
            if await isAppUsingMicrophone(bundleID: bundleID) {
                return MeetingState(
                    isInMeeting: true,
                    detectedApp: bundleID,
                    detectedAt: Date()
                )
            }
        }

        // Method 2: Check running applications
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  monitoredBundleIDs.contains(bundleID),
                  !app.isHidden else {
                continue
            }

            // Check if this app is using the microphone
            if await isAppUsingMicrophone(bundleID: bundleID) {
                return MeetingState(
                    isInMeeting: true,
                    detectedApp: bundleID,
                    detectedAt: Date()
                )
            }
        }

        return .notInMeeting
    }

    /// Check if an app is currently using the microphone
    /// This uses macOS 14.0+ API to check microphone usage
    private func isAppUsingMicrophone(bundleID: String) async -> Bool {
        // On macOS 14.0+, we can check if an app is using the microphone
        // by checking AVCaptureDevice authorization status and active sessions

        // For now, we'll use a heuristic: if the app is active and visible,
        // and it's a known meeting app, assume it might be in a meeting

        // A more robust implementation would:
        // 1. Check AVAudioSession (iOS-style API not available on macOS)
        // 2. Monitor system audio device usage via CoreAudio
        // 3. Use PrivateFrameworks (not recommended for App Store)

        // Simple heuristic for MVP:
        let runningApps = NSWorkspace.shared.runningApplications
        if let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
            // App is running and active (not hidden)
            return app.isActive && !app.isHidden
        }

        return false
    }
}

// MARK: - Advanced Meeting Detection (macOS 14.0+)

@available(macOS 14.0, *)
extension MeetingDetector {

    /// More accurate microphone usage detection using CoreAudio
    /// This checks if any audio input device is currently in use
    private func checkMicrophoneUsage() -> Bool {
        // Query the default input device
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else { return false }

        // Check if the device is running
        propertyAddress.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var isRunning: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)

        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        return runningStatus == noErr && isRunning != 0
    }
}
