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
    @ViewBuilder
    func floatingStorageEstimateCard(
        valueText: String,
        deltaDirection: StorageEstimateDeltaDirection?
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.retraceAccent)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("Estimated Storage")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary.opacity(0.85))

                HStack(spacing: 6) {
                    Text(valueText)
                        .font(.retraceCalloutBold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let deltaDirection {
                        Image(systemName: deltaDirection == .increase ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(deltaDirection == .increase ? .retraceSuccess : .retraceDanger)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.retraceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }

    var captureSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            captureRateCard
            menuBarIconCard
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

                if captureIntervalSeconds != SettingsDefaults.captureIntervalSeconds {
                    HStack {
                        Spacer()

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
                    subtitle: "Store pointer coordinates for each frame and render them in timeline playback. Estimated storage increases while this is enabled.",
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

                if videoQuality != SettingsDefaults.videoQuality {
                    HStack {
                        Spacer()

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
                    Text("Similar Frames Deduplication Threshold")
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

                ModernSlider(
                    value: $deduplicationThreshold,
                    range: 0.98...1.0,
                    step: Self.deduplicationThresholdSliderStep
                )
                    .onChange(of: deduplicationThreshold) { newValue in
                        updateDeduplicationThreshold()
                        deleteDuplicateFrames = newValue < 1.0
                    }

                HStack(alignment: .top) {
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
                        ? "Keep duplicate frames even if only the mouse moved between captures."
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
    var menuBarIconCard: some View {
        ModernSettingsCard(title: "Menu Bar Icon", icon: "menubar.rectangle") {
            ModernToggleRow(
                title: "Show capture animation",
                subtitle: "Animate the menu bar icon like a camera shutter every time Retrace takes a screenshot.",
                isOn: menuBarCaptureFeedbackBinding
            )
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
                    .onChange(of: pauseReminderDelayMinutes) { newValue in
                        NotificationCenter.default.post(
                            name: PauseReminderSettingsNotification.didChange,
                            object: PauseReminderSettingsSnapshot(delayMinutes: newValue)
                        )
                    }

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

private extension SettingsView {
    var menuBarCaptureFeedbackBinding: Binding<Bool> {
        Binding(
            get: {
                showMenuBarCaptureFeedback
            },
            set: { isEnabled in
                showMenuBarCaptureFeedback = isEnabled
                DashboardViewModel.recordDeveloperSettingToggle(
                    coordinator: coordinatorWrapper.coordinator,
                    source: "settings.capture.menuBarIcon",
                    settingKey: menuBarCaptureFeedbackDefaultsKey,
                    isEnabled: isEnabled
                )
            }
        )
    }
}
