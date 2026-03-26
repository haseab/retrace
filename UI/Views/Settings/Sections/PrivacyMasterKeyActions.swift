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
    func masterKeySetupSheet(_ session: MasterKeySetupSession) -> some View {
        ZStack {
            themeBaseBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.025),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()

            Group {
                if session.step == .created {
                    masterKeyCreatedStep
                } else {
                    masterKeyRecoveryStep(session)
                }
            }
            .padding(28)
            .frame(width: 560)
        }
    }

    @ViewBuilder
    var masterKeyCreatedStep: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Color.retraceSuccess.opacity(0.08))
                    .frame(width: 126, height: 126)
                    .scaleEffect(animateMasterKeyCreatedState ? 1 : 0.9)
                    .opacity(animateMasterKeyCreatedState ? 1 : 0.7)

                Circle()
                    .stroke(Color.retraceSuccess.opacity(0.24), lineWidth: 1)
                    .frame(width: 148, height: 148)
                    .scaleEffect(animateMasterKeyCreatedState ? 1.02 : 0.84)
                    .opacity(animateMasterKeyCreatedState ? 1 : 0.25)

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.retraceSuccess)
                    .scaleEffect(animateMasterKeyCreatedState ? 1 : 0.72)
                    .opacity(animateMasterKeyCreatedState ? 1 : 0)
            }

            VStack(spacing: 8) {
                Text("Master Key Created")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)

                Text("Stored in Keychain on this Mac")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Continue") {
                advanceMasterKeySetupToRecovery()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 360)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .onAppear {
            animateMasterKeyCreatedState = false
            withAnimation(.spring(response: 0.54, dampingFraction: 0.72).delay(0.04)) {
                animateMasterKeyCreatedState = true
            }
        }
    }

    @ViewBuilder
    func masterKeyRecoveryStep(_ session: MasterKeySetupSession) -> some View {
        let recoveryWords = session.recoveryPhrase
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save Your Recovery Phrase")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)

                Text("This is the only recovery path if the Keychain copy on this Mac is lost.")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            alertBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Store this offline and keep it private",
                message: "Anyone with this phrase can recover your protected data. If you lose both this phrase and the Keychain entry on this Mac, that data is gone."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Recovery phrase")
                    .font(.retraceCaptionBold)
                    .foregroundColor(.retraceSecondary)

                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                    Button {
                        copyMasterKeyRecoveryPhrase(session.recoveryPhrase)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.retracePrimary)
                            .padding(10)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(12)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 86), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(Array(recoveryWords.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 6) {
                                Text("\(index + 1).")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.retraceSecondary.opacity(0.75))

                                Text(word)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.retracePrimary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                    .padding(.trailing, 48)
                }
            }

            HStack {
                ModernButton(title: "Download TXT", icon: "arrow.down.doc", style: .secondary) {
                    saveMasterKeyRecoveryPhrase(session.recoveryPhrase)
                }

                Spacer()

                Button("I Saved It") {
                    dismissMasterKeySetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    func alertBanner(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.retraceDanger)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.retraceCaptionBold)
                    .foregroundColor(.retracePrimary)

                Text(message)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.retraceDanger.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.retraceDanger.opacity(0.28), lineWidth: 1)
        )
    }

    func initializeProtectedFeatureStateIfNeeded() {
        guard !phraseLevelRedactionToggleInitialized else { return }

        if let storedValue = settingsStore.object(forKey: phraseLevelRedactionEnabledDefaultsKey) as? Bool {
            phraseLevelRedactionEnabled = storedValue
        } else {
            phraseLevelRedactionEnabled = !phraseLevelRedactionPhrases.isEmpty
        }

        hasMasterKeyInKeychain = MasterKeyManager.hasMasterKey()
        phraseLevelRedactionToggleInitialized = true
    }

    func setPrivateWindowRedactionEnabled(_ enabled: Bool) {
        guard enabled != excludePrivateWindows else { return }

        excludePrivateWindows = enabled
        updatePrivateWindowRedactionSetting()

        if enabled {
            Task { await refreshPrivateModeAutomationTargets(force: true) }
        } else {
            privateModeAXCompatibleTargets = []
            privateModeAutomationTargets = []
            privateModeAutomationPermissionStateByBundleID = [:]
            privateModeAutomationBusyBundleIDs = []
            privateModeAutomationRunningBundleIDs = []
        }
    }

    func setPhraseLevelRedactionEnabled(_ enabled: Bool) {
        guard enabled != phraseLevelRedactionEnabled else { return }

        if enabled && !hasMasterKeyInKeychain {
            promptForMasterKey(feature: .phraseLevelRedaction)
            return
        }

        phraseLevelRedactionEnabled = enabled
        settingsStore.set(enabled, forKey: phraseLevelRedactionEnabledDefaultsKey)
        Task { @MainActor in
            showSettingsToast(enabled ? "Keyword redaction enabled" : "Keyword redaction disabled")
        }
        recordMasterKeyMetric(
            action: enabled ? "feature_enabled" : "feature_disabled",
            source: MasterKeyProtectedFeature.phraseLevelRedaction.metricSource
        )
    }

    func promptForMasterKey(feature: MasterKeyProtectedFeature) {
        Task { @MainActor in
            let state = await coordinatorWrapper.coordinator.missingMasterKeyRedactionState()
            guard state.requiresRecoveryPrompt else {
                pendingMasterKeyFeature = feature
                recordMasterKeyMetric(action: "prompt_shown", source: feature.metricSource)
                return
            }

            let outcome = await MasterKeyRedactionFlowCoordinator.resolveMissingKey(
                coordinator: coordinatorWrapper.coordinator,
                state: state,
                defaults: settingsStore,
                configuration: .settings,
                recordMetric: { action, metadata in
                    recordMasterKeyMetric(action: action, source: feature.metricSource, metadata: metadata)
                }
            )

            hasMasterKeyInKeychain = MasterKeyManager.hasMasterKey()
            switch outcome {
            case .deferred:
                return
            case .recoveredExistingKey, .keyAlreadyAvailable:
                applyProtectedFeatureActivation(feature, showToast: false)
                showSettingsToast(
                    state.hasPendingRedactionRewrites
                        ? "Master key recovered; pending redaction rewrites will resume"
                        : "Master key recovered; keyword redaction enabled"
                )
            case .createdFreshKey(let recoveryPhrase, let abandonedRewriteCount):
                applyProtectedFeatureActivation(feature, showToast: false)
                showSettingsToast(
                    abandonedRewriteCount > 0
                        ? "Master key created; old pending rewrites were marked failed"
                        : "Keyword redaction enabled"
                )
                masterKeySetupSession = MasterKeySetupSession(
                    feature: feature,
                    recoveryPhrase: recoveryPhrase
                )
            }
        }
    }

    func createMasterKeyForPendingFeature(_ feature: MasterKeyProtectedFeature) {
        guard !isCreatingMasterKey else { return }
        isCreatingMasterKey = true

        do {
            let result = try MasterKeyManager.createMasterKeyIfNeeded(defaults: settingsStore)
            hasMasterKeyInKeychain = MasterKeyManager.hasMasterKey()
            pendingMasterKeyFeature = nil
            isCreatingMasterKey = false

            applyProtectedFeatureActivation(feature)
            if feature == .phraseLevelRedaction, hasMasterKeyInKeychain {
                Task {
                    if !result.created {
                        await coordinatorWrapper.coordinator.recoverPendingPhraseRedactionRewritesIfPossible()
                    }
                }
            }

            if result.created, let recoveryPhrase = result.recoveryPhrase {
                masterKeySetupSession = MasterKeySetupSession(
                    feature: feature,
                    recoveryPhrase: recoveryPhrase
                )
                recordMasterKeyMetric(action: "created", source: feature.metricSource)
            } else {
                recordMasterKeyMetric(action: "already_exists", source: feature.metricSource)
            }
        } catch {
            pendingMasterKeyFeature = nil
            isCreatingMasterKey = false
            Task { @MainActor in
                showSettingsToast("Couldn't create the master key", isError: true)
            }
            hasMasterKeyInKeychain = MasterKeyManager.hasMasterKey()
            Log.error("[SettingsView] Failed to create master key: \(error)", category: .ui)
            recordMasterKeyMetric(
                action: "create_failed",
                source: feature.metricSource,
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func applyProtectedFeatureActivation(
        _ feature: MasterKeyProtectedFeature,
        showToast: Bool = true
    ) {
        phraseLevelRedactionEnabled = true
        settingsStore.set(true, forKey: phraseLevelRedactionEnabledDefaultsKey)
        if showToast {
            Task { @MainActor in
                showSettingsToast("Keyword redaction enabled")
            }
        }
    }

    func advanceMasterKeySetupToRecovery() {
        guard var session = masterKeySetupSession else { return }
        session.step = .recovery
        masterKeySetupSession = session
        animateMasterKeyCreatedState = false
        recordMasterKeyMetric(action: "recovery_step_opened", source: session.feature.metricSource)
    }

    func dismissMasterKeySetup() {
        guard let session = masterKeySetupSession else { return }
        MasterKeyManager.noteRecoveryPhraseShown(defaults: settingsStore)
        recordMasterKeyMetric(
            action: "recovery_acknowledged",
            source: session.feature.metricSource
        )
        masterKeySetupSession = nil
    }

    func copyMasterKeyRecoveryPhrase(_ recoveryPhrase: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveryPhrase, forType: .string)
        Task { @MainActor in
            showSettingsToast("Recovery phrase copied")
        }
        if let session = masterKeySetupSession {
            recordMasterKeyMetric(action: "recovery_copied", source: session.feature.metricSource)
        }
    }

    func saveMasterKeyRecoveryPhrase(_ recoveryPhrase: String) {
        switch MasterKeyPromptUI.saveRecoveryPhraseDocument(recoveryPhrase) {
        case .saved:
            Task { @MainActor in
                showSettingsToast("Recovery phrase saved")
            }
            if let session = masterKeySetupSession {
                recordMasterKeyMetric(action: "recovery_downloaded", source: session.feature.metricSource)
            }
        case .failed:
            Task { @MainActor in
                showSettingsToast("Couldn't save the recovery phrase", isError: true)
            }
            if let session = masterKeySetupSession {
                recordMasterKeyMetric(
                    action: "recovery_download_failed",
                    source: session.feature.metricSource,
                    metadata: ["error": "save_failed"]
                )
            }
        case .cancelled:
            break
        }
    }

    func recordMasterKeyMetric(
        action: String,
        source: String,
        metadata: [String: Any] = [:]
    ) {
        Task {
            var payload = metadata
            payload["action"] = action
            payload["source"] = source
            let encodedMetadata = Self.inPageURLMetricMetadata(payload)
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .masterKeyFlow,
                metadata: encodedMetadata
            )
        }
    }

    var retraceDBLocationChanged: Bool {
        guard launchedPathInitialized else { return false }
        return customRetraceDBLocation != launchedWithRetraceDBPath
    }

    var retentionConfirmationMessage: String {
        guard let pendingDays = pendingRetentionDays else {
            return ""
        }
        if pendingDays == 0 {
            return "Are you sure you want to change the retention policy to Forever? All data will be kept indefinitely."
        } else {
            let cutoffDate = Date().addingTimeInterval(-TimeInterval(pendingDays) * 86400)
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"

            var exclusions: [String] = []
            if !retentionExcludedApps.isEmpty {
                let appNames = retentionExcludedApps.compactMap { bundleID in
                    installedAppsForRetention.first(where: { $0.bundleID == bundleID })?.name
                        ?? otherAppsForRetention.first(where: { $0.bundleID == bundleID })?.name
                        ?? bundleID
                }
                exclusions.append("Apps: \(appNames.joined(separator: ", "))")
            }
            if !retentionExcludedTagIds.isEmpty {
                let tagNames = retentionExcludedTagIds.compactMap { tagId in
                    availableTagsForRetention.first(where: { $0.id.value == tagId })?.name
                }
                if !tagNames.isEmpty {
                    exclusions.append("Tags: \(tagNames.joined(separator: ", "))")
                }
            }
            if retentionExcludeHidden {
                exclusions.append("Hidden items")
            }

            var message = "All data before \(formatter.string(from: cutoffDate))"
            if exclusions.isEmpty {
                message += " will be deleted."
            } else {
                message += " that is not in your exclusions will be deleted.\n\nExclusions:\n• \(exclusions.joined(separator: "\n• "))"
            }

            return message
        }
    }

    var themeBaseBackground: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()

        switch theme {
        case .gold:
            return Color(red: 15/255, green: 12/255, blue: 8/255)
        default:
            return Color.retraceBackground
        }
    }
}
