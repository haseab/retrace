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

    /// Estimate storage impact using observed bitrate tiers normalized to the
    /// 50% quality baseline used by the default 2s capture estimate.
    /// 40% ≈ 7.29 Mbps, 50% ≈ 8.61 Mbps, 70% ≈ 11.31 Mbps,
    /// 80% ≈ 13.00 Mbps, 100% ≈ 65.75 Mbps.
    /// 90% ≈ 14.48 Mbps, 100% ≈ 65.75 Mbps.
    /// 95% ≈ 15.31 Mbps, 100% ≈ 65.75 Mbps.
    private static func videoQualityMultiplier(for videoQuality: Double) -> Double {
        interpolateVideoQuality(
            normalizedVideoQuality(videoQuality),
            points: [
                (quality: 0.00, bpppf: 3.207 / 8.61),
                (quality: 0.40, bpppf: 7.29 / 8.61),
                (quality: 0.50, bpppf: 1.00),
                (quality: 0.70, bpppf: 11.31 / 8.61),
                (quality: 0.80, bpppf: 13.0 / 8.61),
                (quality: 0.90, bpppf: 14.48 / 8.61),
                (quality: 0.95, bpppf: 15.31 / 8.61),
                (quality: 1.00, bpppf: 65.75 / 8.61),
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

    private static let intervalOnlyBaselineLowGBAtTwoSeconds = 8.0
    private static let intervalOnlyBaselineHighGBAtTwoSeconds = 13.0
    static let deduplicationThresholdSliderStep = 0.0005
    private static let keepFramesOnMouseMovementStorageMultiplier = 1.15

    // Empirical frame-keep curve for the similarity threshold slider, normalized so the
    // default 99.85% threshold remains the 1.0x storage baseline for the 2s timer-only
    // estimate. Values through 99.80% come from the observed log sweep; 99.95% and 100%
    // use the anchored keep-count examples selected for the settings estimate.
    private static let deduplicationStorageMultiplierBaselineFrameCount = 18_016.0
    private static let deduplicationStorageMultiplierPoints: [(threshold: Double, multiplier: Double)] = [
        (threshold: 0.9800, multiplier: 16_295.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9805, multiplier: 16_306.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9810, multiplier: 16_317.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9815, multiplier: 16_328.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9820, multiplier: 16_337.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9825, multiplier: 16_353.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9830, multiplier: 16_362.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9835, multiplier: 16_382.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9840, multiplier: 16_391.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9845, multiplier: 16_401.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9850, multiplier: 16_411.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9855, multiplier: 16_424.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9860, multiplier: 16_436.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9865, multiplier: 16_458.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9870, multiplier: 16_469.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9875, multiplier: 16_479.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9880, multiplier: 16_500.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9885, multiplier: 16_510.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9890, multiplier: 16_546.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9895, multiplier: 16_573.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9900, multiplier: 16_588.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9905, multiplier: 16_599.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9910, multiplier: 16_617.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9915, multiplier: 16_637.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9920, multiplier: 16_655.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9925, multiplier: 16_667.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9930, multiplier: 16_688.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9935, multiplier: 16_707.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9940, multiplier: 16_726.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9945, multiplier: 16_739.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9950, multiplier: 16_757.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9955, multiplier: 16_776.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9960, multiplier: 16_804.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9965, multiplier: 16_837.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9970, multiplier: 16_872.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9975, multiplier: 16_915.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9980, multiplier: 17_002.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 0.9985, multiplier: 1.0),
        (threshold: 0.9995, multiplier: 23_610.0 / deduplicationStorageMultiplierBaselineFrameCount),
        (threshold: 1.0000, multiplier: 25_916.0 / deduplicationStorageMultiplierBaselineFrameCount),
    ]

    // Observed trigger split across tracked provenance days after capture_trigger rollout.
    // Window-change uses the observed low/high range from that split. Mouse-click keeps the
    // same low-side estimate but uses a product-calibrated 6.5 GB/month upper bound.
    private static let mouseClickEventShare = 0.6394960927384343
    private static let windowChangeEventShare = 0.36050390726156567
    private static let minimumIntervalCaptureShare = 0.50
    private static let maximumIntervalCaptureShare = 0.75
    private static let calibratedMouseClickHighGBAtTwoSeconds = 6.5

    private static func storageOverheadMultiplier(intervalCaptureShare: Double) -> Double {
        guard intervalCaptureShare > 0 else { return 0 }
        return (1.0 - intervalCaptureShare) / intervalCaptureShare
    }

    private static func deduplicationStorageMultiplier(for deduplicationThreshold: Double) -> Double {
        let normalizedThreshold = min(max(deduplicationThreshold, 0.98), 1.0)
        guard let firstPoint = deduplicationStorageMultiplierPoints.first else { return 1.0 }
        guard let lastPoint = deduplicationStorageMultiplierPoints.last else { return firstPoint.multiplier }

        if normalizedThreshold <= firstPoint.threshold {
            return firstPoint.multiplier
        }

        for index in 0..<(deduplicationStorageMultiplierPoints.count - 1) {
            let lower = deduplicationStorageMultiplierPoints[index]
            let upper = deduplicationStorageMultiplierPoints[index + 1]
            guard normalizedThreshold <= upper.threshold else { continue }

            let span = upper.threshold - lower.threshold
            guard span > 0 else { return upper.multiplier }
            let t = (normalizedThreshold - lower.threshold) / span
            return lower.multiplier + t * (upper.multiplier - lower.multiplier)
        }

        return lastPoint.multiplier
    }

    static func eventDrivenCaptureStorageHeuristicGB(
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool
    ) -> (lowGB: Double, highGB: Double) {
        let lowExtraMultiplier = storageOverheadMultiplier(
            intervalCaptureShare: maximumIntervalCaptureShare
        )
        let highExtraMultiplier = storageOverheadMultiplier(
            intervalCaptureShare: minimumIntervalCaptureShare
        )

        var lowGB = 0.0
        var highGB = 0.0

        if captureOnWindowChange {
            lowGB += intervalOnlyBaselineLowGBAtTwoSeconds * lowExtraMultiplier * windowChangeEventShare
            highGB += intervalOnlyBaselineHighGBAtTwoSeconds * highExtraMultiplier * windowChangeEventShare
        }

        if captureOnMouseClick {
            lowGB += intervalOnlyBaselineLowGBAtTwoSeconds * lowExtraMultiplier * mouseClickEventShare
            highGB += calibratedMouseClickHighGBAtTwoSeconds
        }

        return (lowGB, highGB)
    }

    private static func sanitizedStorageEstimateRange(lowGB: Double, highGB: Double) -> StorageEstimateRange {
        let sanitizedLowGB = max(lowGB, 0)
        let sanitizedHighGB = max(highGB, sanitizedLowGB)
        return StorageEstimateRange(lowGB: sanitizedLowGB, highGB: sanitizedHighGB)
    }

    private static func formatStorageEstimate(range: StorageEstimateRange) -> String {
        let sanitizedLowGB = range.lowGB
        let sanitizedHighGB = range.highGB
        let lowStr = String(format: "%.1f", sanitizedLowGB)
        let highStr = String(format: "%.1f", sanitizedHighGB)

        if sanitizedHighGB < 0.1 {
            return "Estimated: <0.1 GB per month"
        } else if lowStr == highStr {
            return "Estimated: ~\(lowStr) GB per month"
        }

        return "Estimated: ~\(lowStr) to \(highStr) GB per month"
    }

    static func captureStorageEstimateText(
        videoQuality: Double,
        captureIntervalSeconds: Double,
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool,
        deduplicationThreshold: Double = CaptureConfig.defaultDeduplicationThreshold,
        keepFramesOnMouseMovement: Bool = false
    ) -> String {
        let range = captureStorageEstimateRange(
            videoQuality: videoQuality,
            captureIntervalSeconds: captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick,
            deduplicationThreshold: deduplicationThreshold,
            keepFramesOnMouseMovement: keepFramesOnMouseMovement
        )
        return Self.formatStorageEstimate(range: range)
    }

    static func captureStorageEstimateRange(
        videoQuality: Double,
        captureIntervalSeconds: Double,
        captureOnWindowChange: Bool,
        captureOnMouseClick: Bool,
        deduplicationThreshold: Double = CaptureConfig.defaultDeduplicationThreshold,
        keepFramesOnMouseMovement: Bool = false
    ) -> StorageEstimateRange {
        let qualityMultiplier = Self.videoQualityMultiplier(for: normalizedVideoQuality(videoQuality))
        let intervalMultiplier = Self.captureIntervalMultiplier(for: captureIntervalSeconds)
        let deduplicationMultiplier = Self.deduplicationStorageMultiplier(
            for: deduplicationThreshold
        )
        let mouseMovementMultiplier = keepFramesOnMouseMovement
            ? Self.keepFramesOnMouseMovementStorageMultiplier
            : 1.0
        let eventDrivenHeuristic = Self.eventDrivenCaptureStorageHeuristicGB(
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick
        )

        let baselineLowGB = (intervalOnlyBaselineLowGBAtTwoSeconds * intervalMultiplier) + eventDrivenHeuristic.lowGB
        let baselineHighGB = (intervalOnlyBaselineHighGBAtTwoSeconds * intervalMultiplier) + eventDrivenHeuristic.highGB
        let lowGB = baselineLowGB * qualityMultiplier * deduplicationMultiplier * mouseMovementMultiplier
        let highGB = baselineHighGB * qualityMultiplier * deduplicationMultiplier * mouseMovementMultiplier
        return Self.sanitizedStorageEstimateRange(lowGB: lowGB, highGB: highGB)
    }

    /// Estimated storage per month based on video quality and capture interval settings.
    /// Reference: 50% quality at 2s interval ≈ 8-13 GB/month before event-driven uplift.
    var videoQualityEstimateText: String {
        Self.captureStorageEstimateText(
            videoQuality: videoQuality,
            captureIntervalSeconds: captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick,
            deduplicationThreshold: deduplicationThreshold,
            keepFramesOnMouseMovement: effectiveMousePositionStorageMultiplierEnabled
        )
    }

    var storageEstimateValueText: String {
        videoQualityEstimateText.replacingOccurrences(of: "Estimated: ", with: "")
    }

    var storageEstimateRange: StorageEstimateRange {
        Self.captureStorageEstimateRange(
            videoQuality: videoQuality,
            captureIntervalSeconds: captureIntervalSeconds,
            captureOnWindowChange: captureOnWindowChange,
            captureOnMouseClick: captureOnMouseClick,
            deduplicationThreshold: deduplicationThreshold,
            keepFramesOnMouseMovement: effectiveMousePositionStorageMultiplierEnabled
        )
    }

    static func shouldApplyMousePositionStorageMultiplier(captureMousePosition: Bool) -> Bool {
        captureMousePosition
    }

    var effectiveMousePositionStorageMultiplierEnabled: Bool {
        Self.shouldApplyMousePositionStorageMultiplier(captureMousePosition: captureMousePosition)
    }

    static func storageEstimateDeltaDirection(
        previous: StorageEstimateRange,
        current: StorageEstimateRange
    ) -> StorageEstimateDeltaDirection? {
        let delta = current.midpointGB - previous.midpointGB
        if delta > 0.0001 {
            return .increase
        }
        if delta < -0.0001 {
            return .decrease
        }
        return nil
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
            return "Keep the next frame when: a single word changes"
        } else if threshold >= 0.999 {
            return "Keep the next frame when: a few words change"
        } else if threshold >= 0.9985 {
            return "Keep the next frame when: several words change"
        } else if threshold >= 0.995 {
            return "Keep the next frame when: a line changes"
        } else if threshold >= 0.99 {
            return "Keep the next frame when: multiple lines change"
        } else {
            return "Keep the next frame when: a paragraph changes"
        }
    }

    var retentionDisplayText: String {
        retentionDisplayTextFor(retentionDays)
    }
}
