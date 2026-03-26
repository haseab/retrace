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
        let percentage = Int(videoQuality * 100)
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

    /// Calculate storage multiplier based on video quality setting
    /// Reference: 50% quality = 1.0x multiplier
    private static func videoQualityMultiplier(for videoQuality: Double) -> Double {
        // Interpolation based on quality percentage
        // At 50% (0.5): baseline multiplier = 1.0
        // Multipliers relative to 50%:
        // 5% → 0.22x, 15% → 0.48x, 30% → 0.76x, 50% → 1.0x, 85% → 3.65x
        if videoQuality <= 0.05 {
            return 0.22
        } else if videoQuality <= 0.15 {
            // Interpolate between 0.05 (0.22) and 0.15 (0.48)
            let t = (videoQuality - 0.05) / 0.10
            return 0.22 + t * (0.48 - 0.22)
        } else if videoQuality <= 0.30 {
            // Interpolate between 0.15 (0.48) and 0.30 (0.76)
            let t = (videoQuality - 0.15) / 0.15
            return 0.48 + t * (0.76 - 0.48)
        } else if videoQuality <= 0.50 {
            // Interpolate between 0.30 (0.76) and 0.50 (1.0)
            let t = (videoQuality - 0.30) / 0.20
            return 0.76 + t * (1.0 - 0.76)
        } else if videoQuality <= 0.85 {
            // Interpolate between 0.50 (1.0) and 0.85 (3.65)
            let t = (videoQuality - 0.50) / 0.35
            return 1.0 + t * (3.65 - 1.0)
        } else {
            // Interpolate between 0.85 (3.65) and 1.0 (estimated ~5.0)
            let t = (videoQuality - 0.85) / 0.15
            return 3.65 + t * (5.0 - 3.65)
        }
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
        let qualityMultiplier = Self.videoQualityMultiplier(for: videoQuality)
        let intervalMultiplier = Self.captureIntervalMultiplier(for: captureIntervalSeconds)
        let combinedMultiplier = qualityMultiplier * intervalMultiplier
        let eventDrivenHeuristic = Self.eventDrivenCaptureStorageHeuristicGB(
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )

        let lowGB = (6.0 * combinedMultiplier) + eventDrivenHeuristic.lowGB
        let highGB = (14.0 * combinedMultiplier) + eventDrivenHeuristic.highGB
        return Self.formatStorageEstimate(lowGB: lowGB, highGB: highGB)
    }

    /// Estimated storage per month based on video quality and capture interval settings
    /// Reference: 50% quality at 2s interval ≈ 6-14 GB/month
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
