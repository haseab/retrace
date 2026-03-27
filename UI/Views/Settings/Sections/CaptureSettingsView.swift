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
    var captureSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            captureRateCard
            compressionCard
            Color.clear
                .frame(height: 0)
                .id(Self.pauseReminderCardAnchorID)
            pauseReminderCard
            inPageURLCollectionCard
        }
    }

    // MARK: - Capture Cards

    @ViewBuilder
    var captureRateCard: some View {
        ModernSettingsCard(title: "Capture Rate", icon: "gauge.with.dots.needle.50percent") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Capture interval")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Text(captureIntervalDisplayText)
                        .font(.retraceCalloutBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.3))
                        .cornerRadius(8)
                }

                CaptureIntervalPicker(selectedInterval: $captureIntervalSeconds)
                    .onAppear {
                        syncCaptureTriggerFallbackState()
                    }
                    .onChange(of: captureIntervalSeconds) { newValue in
                        updateCaptureIntervalSetting(to: newValue)
                    }

                HStack {
                    Text(captureIntervalEstimateText)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.7))

                    Spacer()

                    if captureIntervalSeconds != SettingsDefaults.captureIntervalSeconds {
                        Button(action: {
                            captureIntervalSeconds = SettingsDefaults.captureIntervalSeconds
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Reset to Default")
                                    .font(.retraceCaption2)
                            }
                            .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                HStack {
                    ModernToggleRow(
                        title: "Capture on window change",
                        subtitle: "Instantly capture when switching apps or windows",
                        isOn: $captureOnWindowChange
                    )
                    .onChange(of: captureOnWindowChange) { _ in
                        updateCaptureOnWindowChangeSetting()
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                ModernToggleRow(
                    title: "Capture on mouse click",
                    subtitle: hasListenEventAccess
                        ? "Capture shortly after a left click so the frame matches the post-click window metadata."
                        : "Capture shortly after a left click so the frame matches the post-click window metadata. Requires Input Monitoring permission.",
                    isOn: $captureOnMouseClick
                )
                .onChange(of: captureOnMouseClick) { _ in
                    updateCaptureOnMouseClickSetting()
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                ModernToggleRow(
                    title: "Capture mouse position",
                    subtitle: "Store pointer coordinates for each frame and render them in timeline playback.",
                    isOn: $captureMousePosition
                )
                .onChange(of: captureMousePosition) { enabled in
                    if !enabled && keepFramesOnMouseMovement {
                        keepFramesOnMouseMovement = false
                        updateKeepFramesOnMouseMovementSetting()
                        recordInPageURLMetric(
                            type: .mouseMovementDeduplicationToggle,
                            payload: ["enabled": false, "source": "capture_mouse_position_disabled"]
                        )
                    }

                    recordInPageURLMetric(
                        type: .mousePositionCaptureToggle,
                        payload: ["enabled": enabled]
                    )
                }
            }
        }
    }

    @ViewBuilder
    var compressionCard: some View {
        ModernSettingsCard(title: "Compression", icon: "archivebox") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Video quality")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Text(videoQualityDisplayText)
                        .font(.retraceCalloutBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.3))
                        .cornerRadius(8)
                }

                ModernSlider(value: $videoQuality, range: 0...1, step: 0.05)
                    .onChange(of: videoQuality) { newValue in
                        updateVideoQualitySetting(to: newValue)
                        showCompressionUpdateFeedback()
                    }

                HStack {
                    Text(videoQualityEstimateText)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.7))

                    Spacer()

                    if videoQuality != SettingsDefaults.videoQuality {
                        Button(action: {
                            videoQuality = SettingsDefaults.videoQuality
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Reset to Default")
                                    .font(.retraceCaption2)
                            }
                            .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                HStack {
                    Text("Deduplication")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Text(deduplicationThresholdDisplayText)
                        .font(.retraceCalloutBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.3))
                        .cornerRadius(8)
                }

                ModernSlider(value: $deduplicationThreshold, range: 0.98...1.0, step: 0.0001)
                    .onChange(of: deduplicationThreshold) { newValue in
                        updateDeduplicationThreshold()
                        deleteDuplicateFrames = newValue < 1.0
                    }

                HStack {
                    Text(deduplicationSensitivityText)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.7))

                    Spacer()

                    if deduplicationThreshold != SettingsDefaults.deduplicationThreshold {
                        Button(action: {
                            deduplicationThreshold = SettingsDefaults.deduplicationThreshold
                            deleteDuplicateFrames = SettingsDefaults.deleteDuplicateFrames
                            updateDeduplicationThreshold()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Reset to Default")
                                    .font(.retraceCaption2)
                            }
                            .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                ModernToggleRow(
                    title: "Keep frames on mouse movement",
                    subtitle: captureMousePosition
                        ? "Do not deduplicate when the pointer moved between captures."
                        : "Enable \"Capture mouse position\" in Capture Rate to use this setting.",
                    isOn: $keepFramesOnMouseMovement
                )
                .disabled(!captureMousePosition)
                .opacity(captureMousePosition ? 1.0 : 0.6)
                .onChange(of: keepFramesOnMouseMovement) { enabled in
                    guard captureMousePosition else { return }
                    updateKeepFramesOnMouseMovementSetting()
                    recordInPageURLMetric(
                        type: .mouseMovementDeduplicationToggle,
                        payload: ["enabled": enabled]
                    )
                }
            }
        }
    }

    @ViewBuilder
    var pauseReminderCard: some View {
        ModernSettingsCard(title: "Recording Stopped Reminder", icon: "bell.badge") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\"Remind Me Later\" interval")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Text(pauseReminderDisplayText)
                        .font(.retraceCalloutBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.retraceAccent.opacity(0.3))
                        .cornerRadius(8)
                }

                PauseReminderDelayPicker(selectedMinutes: $pauseReminderDelayMinutes)

                HStack {
                    Text("How long to wait before reminding you again when recording is stopped")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.7))

                    Spacer()

                    if pauseReminderDelayMinutes != SettingsDefaults.pauseReminderDelayMinutes {
                        Button(action: {
                            pauseReminderDelayMinutes = SettingsDefaults.pauseReminderDelayMinutes
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Reset to Default")
                                    .font(.retraceCaption2)
                            }
                            .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color.retraceAccent.opacity(shellViewModel.isPauseReminderCardHighlighted ? 0.92 : 0),
                    lineWidth: shellViewModel.isPauseReminderCardHighlighted ? 2.5 : 0
                )
                .shadow(
                    color: Color.retraceAccent.opacity(shellViewModel.isPauseReminderCardHighlighted ? 0.45 : 0),
                    radius: 12
                )
                .animation(.easeInOut(duration: 0.2), value: shellViewModel.isPauseReminderCardHighlighted)
        }
    }
}
