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
    static func defaultShortcut(for kind: ManagedShortcutKind) -> SettingsShortcutKey {
        switch kind {
        case .timeline:
            return SettingsShortcutKey(from: .defaultTimeline)
        case .dashboard:
            return SettingsShortcutKey(from: .defaultDashboard)
        case .recording:
            return SettingsShortcutKey(from: .defaultRecording)
        case .systemMonitor:
            return SettingsShortcutKey(from: .defaultSystemMonitor)
        case .comment:
            return SettingsShortcutKey(from: .defaultCommentCapture)
        }
    }

    static func usesDefaultShortcut(_ shortcut: SettingsShortcutKey, for kind: ManagedShortcutKind) -> Bool {
        shortcut == defaultShortcut(for: kind)
    }

    static func canClearShortcut(_ shortcut: SettingsShortcutKey) -> Bool {
        !shortcut.isEmpty
    }

    func currentShortcut(for kind: ManagedShortcutKind) -> SettingsShortcutKey {
        switch kind {
        case .timeline:
            return timelineShortcut
        case .dashboard:
            return dashboardShortcut
        case .recording:
            return recordingShortcut
        case .systemMonitor:
            return systemMonitorShortcut
        case .comment:
            return commentShortcut
        }
    }

    func recordShortcutDefaultStateMetric(for kind: ManagedShortcutKind) {
        let settingKey: String
        switch kind {
        case .timeline:
            settingKey = "timelineShortcutUsesDefault"
        case .dashboard:
            settingKey = "dashboardShortcutUsesDefault"
        case .recording:
            settingKey = "recordingShortcutUsesDefault"
        case .systemMonitor:
            settingKey = "systemMonitorShortcutUsesDefault"
        case .comment:
            settingKey = "commentShortcutUsesDefault"
        }

        DashboardViewModel.recordDeveloperSettingToggle(
            coordinator: coordinatorWrapper.coordinator,
            source: "settings.shortcuts",
            settingKey: settingKey,
            isEnabled: Self.usesDefaultShortcut(currentShortcut(for: kind), for: kind)
        )
    }

    var dashboardAppUsageViewModeSelection: DashboardAppUsageViewModeSetting {
        DashboardAppUsageViewModeSetting(rawValue: dashboardAppUsageViewMode) ?? .list
    }

    var dashboardAppUsageViewModeBinding: Binding<DashboardAppUsageViewModeSetting> {
        Binding(
            get: {
                dashboardAppUsageViewModeSelection
            },
            set: { newValue in
                dashboardAppUsageViewMode = newValue.rawValue
                DashboardViewModel.recordDeveloperSettingToggle(
                    coordinator: coordinatorWrapper.coordinator,
                    source: "settings.appearance",
                    settingKey: "dashboardAppUsageViewMode",
                    isEnabled: newValue == .hardDrive
                )
            }
        )
    }

    var pauseReminderDisplayText: String {
        if pauseReminderDelayMinutes == 0 {
            return "Never"
        } else if pauseReminderDelayMinutes < 60 {
            return "\(Int(pauseReminderDelayMinutes)) min"
        } else {
            let hours = Int(pauseReminderDelayMinutes / 60)
            return "\(hours) hr"
        }
    }

    var captureIntervalDisplayText: String {
        Self.captureIntervalDisplayText(for: captureIntervalSeconds)
    }

    static func captureIntervalDisplayText(for captureIntervalSeconds: Double) -> String {
        if captureIntervalSeconds <= 0 {
            return "None"
        } else if captureIntervalSeconds >= 60 {
            let minutes = Int(captureIntervalSeconds / 60)
            return "Every \(minutes) min"
        } else {
            return "Every \(Int(captureIntervalSeconds))s"
        }
    }

    static func hasAutomaticCaptureTrigger(
        captureIntervalSeconds: Double,
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool
    ) -> Bool {
        captureIntervalSeconds > 0 || captureOnWindowChange || captureOnMouseClick
    }

    static func shouldRejectCaptureIntervalSelection(
        _ captureIntervalSeconds: Double,
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool
    ) -> Bool {
        !hasAutomaticCaptureTrigger(
            captureIntervalSeconds: captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )
    }

    static func shouldRejectEventDrivenTriggerDisable(
        captureIntervalSeconds: Double,
        otherEventDrivenTriggerEnabled: Bool
    ) -> Bool {
        captureIntervalSeconds <= 0 && !otherEventDrivenTriggerEnabled
    }

    var videoQualityDisplayText: String {
        let percentage = Int(Self.normalizedVideoQuality(videoQuality) * 100)
        return "\(percentage)%"
    }

    var scrubbingAnimationDisplayText: String {
        if scrubbingAnimationDuration == 0 {
            return "None"
        } else {
            let ms = Int(scrubbingAnimationDuration * 1000)
            return "\(ms)ms"
        }
    }

    var scrubbingAnimationDescriptionText: String {
        if scrubbingAnimationDuration == 0 {
            return "Instant scrubbing with no animation"
        } else if scrubbingAnimationDuration <= 0.05 {
            return "Minimal animation for quick scrubbing"
        } else if scrubbingAnimationDuration <= 0.10 {
            return "Smooth animation for comfortable navigation"
        } else if scrubbingAnimationDuration <= 0.15 {
            return "Moderate animation for visual feedback"
        } else {
            return "Maximum animation for cinematic feel"
        }
    }

    var scrollSensitivityDisplayText: String {
        return "\(Int(scrollSensitivity * 100))%"
    }

    var scrollSensitivityDescriptionText: String {
        if scrollSensitivity <= 0.25 {
            return "Slow, precise frame-by-frame navigation"
        } else if scrollSensitivity <= 0.50 {
            return "Moderate scroll speed for careful browsing"
        } else if scrollSensitivity <= 0.75 {
            return "Balanced scroll speed for general use"
        } else {
            return "Fast scrolling for quick navigation"
        }
    }

    private static func normalizedVideoQuality(_ videoQuality: Double) -> Double {
        min(max(videoQuality, 0.0), 1.0)
    }

    private static func effectiveEncoderVideoQuality(for videoQuality: Double) -> Double {
        interpolateVideoQuality(
            normalizedVideoQuality(videoQuality),
            points: [
                (quality: 0.00, bpppf: 0.00),
                (quality: 0.40, bpppf: 0.3469026324777675),
                (quality: 0.70, bpppf: 0.55),
                (quality: 1.00, bpppf: 1.00),
            ]
        )
    }

    private static func baseScreenContentBitsPerPixelPerFrame(for videoQuality: Double) -> Double {
        let encoderQuality = effectiveEncoderVideoQuality(for: videoQuality)
        return interpolateVideoQuality(
            encoderQuality,
            points: [
                (quality: 0.00, bpppf: 0.018),
                (quality: 0.25, bpppf: 0.032),
                (quality: 0.50, bpppf: 0.055),
                (quality: 0.75, bpppf: 0.070),
                (quality: 1.00, bpppf: 0.085),
            ]
        )
    }

    /// Estimate storage impact using observed monthly storage normalization.
    /// 40% maps to the legacy ~7.29 Mbps tier, and 70% maps to the current
    /// observed ~11.14 Mbps tier that users experience in practice.
    private static func videoQualityMultiplier(for videoQuality: Double) -> Double {
        interpolateVideoQuality(
            normalizedVideoQuality(videoQuality),
            points: [
                (quality: 0.00, bpppf: 3.207 / 11.14),
                (quality: 0.40, bpppf: 7.29 / 11.14),
                (quality: 0.70, bpppf: 1.00),
                (quality: 1.00, bpppf: 15.145 / 11.14),
            ]
        )
    }

    private static func interpolateVideoQuality(
        _ videoQuality: Double,
        points: [(quality: Double, bpppf: Double)]
    ) -> Double {
        guard let firstPoint = points.first else { return 0.0 }
        guard let lastPoint = points.last else { return firstPoint.bpppf }

        if videoQuality <= firstPoint.quality {
            return firstPoint.bpppf
        }

        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            guard videoQuality <= upper.quality else { continue }

            let span = upper.quality - lower.quality
            guard span > 0 else { return upper.bpppf }
            let t = (videoQuality - lower.quality) / span
            return lower.bpppf + t * (upper.bpppf - lower.bpppf)
        }

        return lastPoint.bpppf
    }

    /// Calculate storage multiplier based on capture interval
    /// Reference: 2 seconds = 1.0x multiplier (baseline)
    /// Longer intervals = less storage (linear relationship)
    private static func captureIntervalMultiplier(for captureIntervalSeconds: Double) -> Double {
        guard captureIntervalSeconds > 0 else { return 0 }
        return 2.0 / captureIntervalSeconds
    }

    static func eventDrivenCaptureStorageHeuristicGB(
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool
    ) -> (lowGB: Double, highGB: Double) {
        var lowGB = 0.0
        var highGB = 0.0

        if captureOnWindowChange {
            lowGB += 0.5
            highGB += 2.0
        }

        if captureOnMouseClick {
            lowGB += 0.25
            highGB += 1.0
        }

        return (lowGB, highGB)
    }

    private static func formatStorageEstimate(lowGB: Double, highGB: Double) -> String {
        let sanitizedLowGB = max(lowGB, 0)
        let sanitizedHighGB = max(highGB, sanitizedLowGB)
        let lowStr = String(format: "%.1f", sanitizedLowGB)
        let highStr = String(format: "%.1f", sanitizedHighGB)

        if sanitizedHighGB < 0.1 {
            return "Estimated: <0.1 GB per month"
        } else if lowStr == highStr {
            return "Estimated: ~\(lowStr) GB per month"
        }

        return "Estimated: ~\(lowStr)-\(highStr) GB per month"
    }

    static func captureStorageEstimateText(
        videoQuality: Double,
        captureIntervalSeconds: Double,
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool
    ) -> String {
        let qualityMultiplier = Self.videoQualityMultiplier(for: normalizedVideoQuality(videoQuality))
        let intervalMultiplier = Self.captureIntervalMultiplier(for: captureIntervalSeconds)
        let eventDrivenHeuristic = Self.eventDrivenCaptureStorageHeuristicGB(
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )

        let baselineLowGB = (6.0 * intervalMultiplier) + eventDrivenHeuristic.lowGB
        let baselineHighGB = (14.0 * intervalMultiplier) + eventDrivenHeuristic.highGB
        let lowGB = baselineLowGB * qualityMultiplier
        let highGB = baselineHighGB * qualityMultiplier
        return Self.formatStorageEstimate(lowGB: lowGB, highGB: highGB)
    }

    /// Estimated storage per month based on video quality and capture interval settings
    /// Reference: 70% quality at 2s interval ≈ 6-14 GB/month
    var videoQualityEstimateText: String {
        Self.captureStorageEstimateText(
            videoQuality: videoQuality,
            captureIntervalSeconds: captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )
    }

    /// Estimated storage for capture interval section (same calculation)
    var captureIntervalEstimateText: String {
        videoQualityEstimateText
    }

    var deduplicationThresholdDisplayText: String {
        let percentage = deduplicationThreshold * 100
        return String(format: "%.2f%%", percentage)
    }

    /// Sensitivity description based on deduplication threshold
    var deduplicationSensitivityText: String {
        let threshold = deduplicationThreshold
        if threshold >= 1.0 {
            return "Records every frame (no deduplication)"
        } else if threshold >= 0.9998 {
            return "New frame on: a single word changing"
        } else if threshold >= 0.999 {
            return "New frame on: a few words changing"
        } else if threshold >= 0.9985 {
            return "New frame on: several words changing"
        } else if threshold >= 0.995 {
            return "New frame on: line changes"
        } else if threshold >= 0.99 {
            return "New frame on: multiple line changes"
        } else {
            return "New frame on: paragraph changes"
        }
    }

    var retentionDisplayText: String {
        retentionDisplayTextFor(retentionDays)
    }
}
