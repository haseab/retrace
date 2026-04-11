import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

extension SettingsView {
    /// Enable or disable launch at login using SMAppService (macOS 13+)
    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                guard case SMAppService.Status.enabled = SMAppService.mainApp.status else {
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("[SettingsView] Failed to \(enabled ? "enable" : "disable") launch at login: \(error)", category: .ui)
        }
    }

    /// Show or hide the Dock icon (and Cmd+Tab presence) for Retrace.
    func setDockIconVisibility(visible: Bool) {
        let foregroundWindow = currentForegroundAppWindow()
        let targetPolicy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        let changed = NSApp.setActivationPolicy(targetPolicy)
        let policyName = visible ? "regular" : "accessory"

        Log.info(
            "[SettingsView] Dock icon visibility updated visible=\(visible) policy=\(policyName) changed=\(changed)",
            category: .ui
        )

        (NSApp.delegate as? AppDelegate)?.installMainMenuIfNeeded(force: true)

        if visible {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
        } else if let foregroundWindow {
            keepForegroundWindowVisibleAfterDockRemoval(foregroundWindow)
        }

        recordDockIconVisibilityMetric(enabled: visible)
    }

    private func currentForegroundAppWindow() -> NSWindow? {
        NSApp.windows.first { candidate in
            guard candidate.level == .normal else { return false }
            guard candidate.isVisible, !candidate.isMiniaturized else { return false }
            guard candidate.alphaValue > 0.01 else { return false }

            return candidate.canBecomeKey
                || candidate.canBecomeMain
                || candidate.isKeyWindow
                || candidate.isMainWindow
        }
    }

    private func keepForegroundWindowVisibleAfterDockRemoval(_ window: NSWindow) {
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        Log.info(
            "[SettingsView] Restored foreground window after Dock icon removal title=\(window.title)",
            category: .ui
        )
    }

    /// Show or hide the menu bar icon
    func setMenuBarIconVisibility(visible: Bool) {
        if let menuBarManager = MenuBarManager.shared {
            if visible {
                menuBarManager.show()
            } else {
                menuBarManager.hide()
            }
        }
    }

    func recordDockIconVisibilityMetric(enabled: Bool) {
        Task {
            let metadata = Self.inPageURLMetricMetadata([
                "enabled": enabled,
                "source": "settings_startup_card"
            ])
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .dockIconVisibilityToggle,
                metadata: metadata
            )
        }
    }

    func recordMouseClickCaptureToggleMetric(enabled: Bool, outcome: String) {
        Task {
            let metadata = Self.inPageURLMetricMetadata([
                "enabled": enabled,
                "outcome": outcome,
                "source": "settings_capture_card"
            ])
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .mouseClickCaptureToggle,
                metadata: metadata
            )
        }
    }

    func recordCaptureIntervalUpdatedMetric(seconds: Double) {
        Task {
            let metadata = Self.inPageURLMetricMetadata([
                "seconds": seconds,
                "mode": seconds <= 0 ? "off" : "interval",
                "source": "settings_capture_card"
            ])
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .captureIntervalUpdated,
                metadata: metadata
            )
        }
    }

    /// Apply theme preference
    func applyTheme(_ theme: ThemePreference) {
        switch theme {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applyCaptureConfigMutation(
        successLog: String,
        failureLog: String,
        transform: @escaping @Sendable (CaptureConfig) -> CaptureConfig,
        onSuccess: ((AppCoordinator) async -> Void)? = nil
    ) async {
        let coordinator = coordinatorWrapper.coordinator

        do {
            try await coordinator.updateCaptureConfig(transform)
            if let onSuccess {
                await onSuccess(coordinator)
            }
            Log.info(successLog, category: .ui)
        } catch {
            Log.error("\(failureLog): \(error)", category: .ui)
        }
    }

    func syncCaptureTriggerFallbackState() {
        guard captureIntervalSeconds > 0 else { return }
        lastNonZeroCaptureIntervalSeconds = captureIntervalSeconds
    }

    func showCaptureTriggerRequirementToast() {
        Task { @MainActor in
            showSettingsToast(
                "Enable at least one capture trigger to keep recording active.",
                isError: true,
                duration: .seconds(3.2)
            )
        }
    }

    func updateDeduplicationSetting(enabled: Bool) {
        let threshold = deduplicationThreshold
        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Deduplication setting updated to: \(enabled)",
                failureLog: "[SettingsView] Failed to update deduplication setting",
                transform: {
                    $0.updating(
                        adaptiveCaptureEnabled: enabled,
                        deduplicationThreshold: threshold
                    )
                }
            )
        }
    }

    func updateDeduplicationThreshold() {
        let threshold = deduplicationThreshold
        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Deduplication threshold updated to: \(threshold)",
                failureLog: "[SettingsView] Failed to update deduplication threshold",
                transform: { $0.updating(deduplicationThreshold: threshold) },
                onSuccess: { _ in
                    showCompressionUpdateFeedback()
                }
            )
        }
    }

    func updateKeepFramesOnMouseMovementSetting() {
        let keepFramesEnabled = keepFramesOnMouseMovement
        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Keep frames on mouse movement updated to: \(keepFramesEnabled)",
                failureLog: "[SettingsView] Failed to update keep-frames-on-mouse-movement setting",
                transform: { $0.updating(keepFramesOnMouseMovement: keepFramesEnabled) },
                onSuccess: { _ in
                    showCompressionUpdateFeedback()
                }
            )
        }
    }

    func updateCaptureOnWindowChangeSetting() {
        if isProgrammaticWindowChangeCaptureToggleChange {
            isProgrammaticWindowChangeCaptureToggleChange = false
            return
        }

        let requestedEnabled = captureOnWindowChange
        guard requestedEnabled || !Self.shouldRejectEventDrivenTriggerDisable(
            captureIntervalSeconds: captureIntervalSeconds,
            otherEventDrivenTriggerEnabled: captureOnMouseClick
        ) else {
            isProgrammaticWindowChangeCaptureToggleChange = true
            captureOnWindowChange = true
            showCaptureTriggerRequirementToast()
            return
        }

        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Capture on window change updated to: \(requestedEnabled)",
                failureLog: "[SettingsView] Failed to update capture on window change",
                transform: { $0.updating(captureOnWindowChange: requestedEnabled) },
                onSuccess: { _ in
                    showCaptureUpdateFeedback()
                }
            )
        }
    }

    func updateCaptureIntervalSetting(to captureIntervalSeconds: Double) {
        if isProgrammaticCaptureIntervalChange {
            isProgrammaticCaptureIntervalChange = false
            return
        }

        guard !Self.shouldRejectCaptureIntervalSelection(
            captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        ) else {
            isProgrammaticCaptureIntervalChange = true
            self.captureIntervalSeconds =
                lastNonZeroCaptureIntervalSeconds > 0
                ? lastNonZeroCaptureIntervalSeconds
                : SettingsDefaults.captureIntervalSeconds
            showCaptureTriggerRequirementToast()
            return
        }

        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Capture interval updated to: \(captureIntervalSeconds)s",
                failureLog: "[SettingsView] Failed to update capture interval",
                transform: { $0.updating(captureIntervalSeconds: captureIntervalSeconds) },
                onSuccess: { _ in
                    if captureIntervalSeconds > 0 {
                        await MainActor.run {
                            lastNonZeroCaptureIntervalSeconds = captureIntervalSeconds
                        }
                    }
                    recordCaptureIntervalUpdatedMetric(seconds: captureIntervalSeconds)
                    showCaptureUpdateFeedback()
                }
            )
        }
    }

    func updateVideoQualitySetting(to videoQuality: Double) {
        Task {
            await coordinatorWrapper.coordinator.updateVideoQuality(videoQuality)
            Log.info("[SettingsView] Video quality updated to: \(videoQuality)", category: .ui)
        }
    }

    func updateCaptureOnMouseClickSetting() {
        if isProgrammaticMouseClickCaptureToggleChange {
            isProgrammaticMouseClickCaptureToggleChange = false
            return
        }

        let requestedEnabled = captureOnMouseClick
        guard requestedEnabled || !Self.shouldRejectEventDrivenTriggerDisable(
            captureIntervalSeconds: captureIntervalSeconds,
            otherEventDrivenTriggerEnabled: captureOnWindowChange
        ) else {
            isProgrammaticMouseClickCaptureToggleChange = true
            captureOnMouseClick = true
            showCaptureTriggerRequirementToast()
            return
        }

        Task {
            if requestedEnabled {
                let granted = await requestListenEventAccessIfNeeded()
                guard granted else {
                    await MainActor.run {
                        isProgrammaticMouseClickCaptureToggleChange = true
                        captureOnMouseClick = false
                        recordMouseClickCaptureToggleMetric(enabled: requestedEnabled, outcome: "permission_denied")
                        showSettingsToast(
                            "Mouse click capture needs Input Monitoring permission. Allow Retrace in System Settings, then turn it on again.",
                            isError: true,
                            duration: .seconds(3.6)
                        )
                    }
                    return
                }
            }

            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Capture on mouse click updated to: \(requestedEnabled)",
                failureLog: "[SettingsView] Failed to update capture on mouse click",
                transform: { $0.updating(captureOnMouseClick: requestedEnabled) },
                onSuccess: { _ in
                    recordMouseClickCaptureToggleMetric(enabled: requestedEnabled, outcome: "applied")
                    showCaptureUpdateFeedback()
                }
            )
        }
    }

    /// Show brief "Updated" feedback for compression settings
    func showCompressionUpdateFeedback() {
        Task { @MainActor in
            showSettingsToast("Compression settings updated")
        }
    }

    /// Show brief "Updated" feedback for capture interval settings
    func showCaptureUpdateFeedback() {
        Task { @MainActor in
            showSettingsToast("Capture settings updated")
        }
    }

    /// Show brief "Updated" feedback for scrubbing animation settings
    func showScrubbingAnimationUpdateFeedback() {
        Task { @MainActor in
            showSettingsToast("Scrubbing animation updated")
        }
    }

    // MARK: - Section Reset Functions

    /// Reset all General settings to defaults
    func resetGeneralSettings() {
        // Keyboard shortcuts
        let timelineValue = SettingsShortcutKey(from: .defaultTimeline)
        let dashboardValue = SettingsShortcutKey(from: .defaultDashboard)
        let recordingValue = SettingsShortcutKey(from: .defaultRecording)
        let systemMonitorValue = SettingsShortcutKey(from: .defaultSystemMonitor)
        let commentValue = SettingsShortcutKey(from: .defaultCommentCapture)

        timelineShortcut = timelineValue
        dashboardShortcut = dashboardValue
        recordingShortcut = recordingValue
        systemMonitorShortcut = systemMonitorValue
        commentShortcut = commentValue
        Task { await saveAllShortcuts() }

        // Startup
        launchAtLogin = SettingsDefaults.launchAtLogin
        setLaunchAtLogin(enabled: SettingsDefaults.launchAtLogin)
        showDockIcon = SettingsDefaults.showDockIcon
        showMenuBarIcon = SettingsDefaults.showMenuBarIcon

        // Updates
        UpdaterManager.shared.automaticUpdateChecksEnabled = SettingsDefaults.automaticUpdateChecks
        UpdaterManager.shared.automaticallyDownloadsUpdatesEnabled = SettingsDefaults.automaticallyDownloadUpdates

        // Appearance
        theme = SettingsDefaults.theme
        fontStyle = SettingsDefaults.fontStyle
        RetraceFont.currentStyle = SettingsDefaults.fontStyle
        colorThemePreference = SettingsDefaults.colorTheme
        MilestoneCelebrationManager.setColorThemePreference(.blue)
        timelineColoredBorders = SettingsDefaults.timelineColoredBorders
        scrubbingAnimationDuration = SettingsDefaults.scrubbingAnimationDuration
        scrollSensitivity = SettingsDefaults.scrollSensitivity
        timelineScrollOrientation = SettingsDefaults.timelineScrollOrientation
        dashboardAppUsageViewMode = SettingsDefaults.dashboardAppUsageViewMode
    }

    /// Reset all Capture settings to defaults
    func resetCaptureSettings() {
        pauseReminderDelayMinutes = SettingsDefaults.pauseReminderDelayMinutes
        captureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
        lastNonZeroCaptureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
        videoQuality = SettingsDefaults.videoQuality
        deduplicationThreshold = SettingsDefaults.deduplicationThreshold
        deleteDuplicateFrames = SettingsDefaults.deleteDuplicateFrames
        keepFramesOnMouseMovement = SettingsDefaults.keepFramesOnMouseMovement
        captureOnWindowChange = SettingsDefaults.captureOnWindowChange
        isProgrammaticWindowChangeCaptureToggleChange = false
        captureOnMouseClick = SettingsDefaults.captureOnMouseClick
        isProgrammaticMouseClickCaptureToggleChange = false
        captureMousePosition = SettingsDefaults.captureMousePosition
        collectInPageURLsExperimental = SettingsDefaults.collectInPageURLsExperimental
        inPageURLVerificationByBundleID = [:]
        inPageURLVerificationBusyBundleIDs = []
        inPageURLVerificationSummary = nil

        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Capture settings reset to defaults",
                failureLog: "[SettingsView] Failed to reset capture settings",
                transform: {
                    $0.updating(
                        captureIntervalSeconds: SettingsDefaults.captureIntervalSeconds,
                        adaptiveCaptureEnabled: true,
                        deduplicationThreshold: SettingsDefaults.deduplicationThreshold,
                        keepFramesOnMouseMovement: SettingsDefaults.keepFramesOnMouseMovement,
                        captureOnWindowChange: SettingsDefaults.captureOnWindowChange,
                        captureOnMouseClick: SettingsDefaults.captureOnMouseClick
                    )
                }
            )
        }

        showCaptureUpdateFeedback()
    }

    /// Reset all Storage settings to defaults
    func resetStorageSettings() {
        retentionDays = SettingsDefaults.retentionDays
        maxStorageGB = SettingsDefaults.maxStorageGB
        retentionSettingChanged = true
        startRetentionChangeTimer()
    }

    /// Reset all Privacy settings to defaults
    func resetPrivacySettings() {
        excludedAppsString = SettingsDefaults.excludedApps
        excludePrivateWindows = SettingsDefaults.excludePrivateWindows
        enableCustomPatternWindowRedaction = SettingsDefaults.enableCustomPatternWindowRedaction
        redactWindowTitlePatternsRaw = SettingsDefaults.redactWindowTitlePatterns
        redactBrowserURLPatternsRaw = SettingsDefaults.redactBrowserURLPatterns
        phraseLevelRedactionEnabled = SettingsDefaults.phraseLevelRedactionEnabled
        settingsStore.set(SettingsDefaults.phraseLevelRedactionEnabled, forKey: phraseLevelRedactionEnabledDefaultsKey)
        phraseLevelRedactionPhrasesRaw = SettingsDefaults.phraseLevelRedactionPhrases
        phraseLevelRedactionInput = ""
        excludeSafariPrivate = SettingsDefaults.excludeSafariPrivate
        excludeChromeIncognito = SettingsDefaults.excludeChromeIncognito

        Task {
            await applyCaptureConfigMutation(
                successLog: "[SettingsView] Privacy settings reset to defaults",
                failureLog: "[SettingsView] Failed to reset privacy settings",
                transform: {
                    $0.updating(
                        excludedAppBundleIDs: excludedAppBundleIDsForCaptureConfig(),
                        excludePrivateWindows: SettingsDefaults.excludePrivateWindows,
                        redactWindowTitlePatterns: [],
                        redactBrowserURLPatterns: []
                    )
                }
            )
        }
    }

    func resetMasterKeyForDebug() {
        do {
            let removed = try MasterKeyManager.resetMasterKey(defaults: settingsStore)
            hasMasterKeyInKeychain = MasterKeyManager.hasMasterKey()
            pendingMasterKeyFeature = nil
            masterKeySetupSession = nil
            isCreatingMasterKey = false
            animateMasterKeyCreatedState = false
            phraseLevelRedactionEnabled = false
            settingsStore.set(false, forKey: phraseLevelRedactionEnabledDefaultsKey)

            showSettingsToast(
                removed ? "Master key reset for this Mac" : "No master key was stored on this Mac"
            )
            recordMasterKeyMetric(
                action: removed ? "debug_reset" : "debug_reset_noop",
                source: "developer"
            )
        } catch {
            showSettingsToast("Couldn't reset the master key", isError: true)
            Log.error("[SettingsView] Failed to reset master key: \(error)", category: .ui)
            recordMasterKeyMetric(
                action: "debug_reset_failed",
                source: "developer",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    /// Reset all Advanced settings to defaults
    func resetAdvancedSettings() {
        showFrameIDs = SettingsDefaults.showFrameIDs
        enableFrameIDSearch = SettingsDefaults.enableFrameIDSearch
        showVideoControls = SettingsDefaults.showVideoControls
        showMenuBarCaptureFeedback = SettingsDefaults.showMenuBarCaptureFeedback
    }
}
