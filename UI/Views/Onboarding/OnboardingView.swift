import SwiftUI
import AppKit
import App
import Database
import Shared
import ServiceManagement
import Carbon

/// Softer button color that blends with the dark blue onboarding background
/// A muted blue that's visible but not as sharp as the primary accent
private let onboardingButtonColor = Color(red: 35/255, green: 75/255, blue: 145/255)

private struct AutomationPreflightTarget: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let appURL: URL?

    var id: String { bundleID }
}

private struct UnsupportedAutomationTarget: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let appURL: URL?

    var id: String { bundleID }
}

private enum AutomationPreflightStatus: String, Sendable {
    case granted
    case skipped
    case denied
    case timedOut
    case failed
}

private enum AutomationPermissionProbeResult: Sendable {
    case granted
    case denied
    case requiresUserConsent
    case unavailable(OSStatus)
}

/// Main onboarding flow with 10 steps
/// Step 1: Welcome
/// Step 2: Creator features
/// Step 3: Core permissions (screen recording + accessibility)
/// Step 4: App URL permissions
/// Step 5: Menu Bar Icon info
/// Step 6: Launch at Login option
/// Step 7: Rewind data decision
/// Step 8: Keyboard shortcuts
/// Step 9: Early Alpha / Safety info
/// Step 10: Completion (prompts to test timeline)
public struct OnboardingView: View {

    // MARK: - Properties

    // UserDefaults keys
    private static let onboardingStepKey = "onboardingCurrentStep"
    private static let timelineShortcutKey = "timelineShortcutConfig"
    private static let dashboardShortcutKey = "dashboardShortcutConfig"
    private static let automationPreflightStatusesKey = "onboardingAutomationPreflightStatuses.v1"
    private static let automationPreflightUserAllowTimeoutSeconds: TimeInterval = 60.0
    private static let automationPreflightBackgroundTimeoutSeconds: TimeInterval = 3.0
    private static let automationPreflightRecheckIntervalSeconds: TimeInterval = 4.0
    private static let automationForcedSweepIntervalSeconds: TimeInterval = 1.0
    private static let automationPreflightUnknownProbeMaxPerPass = 2
    private static let automationPermissionProbeRetryCooldownSeconds: TimeInterval = 30.0
    private static let automationPermissionTargetNotRunningStatus = OSStatus(procNotFound)
    private static let automationPermissionProbeTimeoutStatus = OSStatus(errAETimeout)
    private static let automationPermissionProbeQueue = DispatchQueue(
        label: "io.retrace.onboarding.automationPermissionProbe",
        qos: .utility,
        attributes: .concurrent
    )
    private static let systemSettingsReturnCheckIntervalSeconds: TimeInterval = 0.5
    private static let systemSettingsBundleIDs: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.systemsettings",
    ]
    private static let automationChromiumAppShimPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.google.Chrome.canary.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app.",
        "com.vivaldi.Vivaldi.app.",
        "com.operasoftware.Opera.app.",
        "org.chromium.Chromium.app.",
        "com.cometbrowser.Comet.app.",
        "com.aspect.browser.app.",
        "com.sigmaos.sigmaos.app.",
        "com.openai.chat.app.",
        "com.nicklockwood.Thorium.app.",
    ]
    private static let automationChromiumHostBundleIDs: Set<String> = Set(
        automationChromiumAppShimPrefixes.compactMap { prefix in
            guard prefix.hasSuffix(".app.") else { return nil }
            return String(prefix.dropLast(5))
        }
    )
    private static let unsupportedFirefoxBundleIDs: [String] = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]
    // Exact apps where Retrace uses AppleScript-based URL extraction.
    private static let automationPreflightBaseTargets: [AutomationPreflightTarget] = [
        AutomationPreflightTarget(bundleID: "com.apple.finder", displayName: "Finder", appURL: nil),
        AutomationPreflightTarget(bundleID: "company.thebrowser.Browser", displayName: "Arc", appURL: nil),
    ]

    // Load saved shortcuts or use defaults
    private static func loadTimelineShortcut() -> ShortcutConfig {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard let data = defaults.data(forKey: timelineShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultTimeline
        }
        return config
    }

    private static func loadDashboardShortcut() -> ShortcutConfig {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard let data = defaults.data(forKey: dashboardShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultDashboard
        }
        return config
    }

    @State private var currentStep: Int = UserDefaults.standard.integer(forKey: OnboardingView.onboardingStepKey).clamped(to: 1...10) == 0 ? 1 : UserDefaults.standard.integer(forKey: OnboardingView.onboardingStepKey).clamped(to: 1...10)
    @State private var hasScreenRecordingPermission = false
    @State private var hasAccessibilityPermission = false
    @State private var isCheckingPermissions = false
    @State private var permissionCheckTimer: Timer? = nil
    @State private var screenRecordingDenied = false  // User explicitly denied in system prompt
    @State private var screenRecordingRequested = false  // User has clicked Enable once
    @State private var accessibilityRequested = false  // User has clicked Enable Accessibility once
    @State private var hasTriggeredCaptureDialog = false  // macOS 15+ "Allow to record" dialog triggered
    @State private var automationPreflightTargets: [AutomationPreflightTarget] = []
    @State private var automationPreflightStatusByBundleID: [String: AutomationPreflightStatus] = [:]
    @State private var automationPreflightRunningBundleIDs: Set<String> = []
    @State private var automationPreflightBusyBundleIDs: Set<String> = []
    @State private var automationPreflightIconByBundleID: [String: NSImage] = [:]
    @State private var automationPreflightLaunchedByOnboardingBundleIDs: Set<String> = []
    @State private var hasLoadedAutomationPreflightTargets = false
    @State private var lastAutomationPreflightRecheckAt = Date.distantPast
    @State private var isRecheckingAutomationPreflightPermissions = false
    @State private var automationPreflightUnknownProbeAttemptedBundleIDs: Set<String> = []
    @State private var automationPermissionProbeCooldownUntilByBundleID: [String: Date] = [:]
    @State private var automationPermissionProbeTimeoutCountByBundleID: [String: Int] = [:]
    @State private var automationForcedSweepTimer: Timer? = nil
    @State private var isBulkAllowingAutomationTargets = false
    @State private var isBulkSkippingAutomationTargets = false
    @State private var isClosingLaunchedAutomationApps = false
    @State private var isRefreshingAutomationPreflightList = false
    @State private var automationWorkspaceObserverTokens: [NSObjectProtocol] = []
    @State private var showBulkAllowAllConfirmation = false
    @State private var bulkAllowAllLaunchPreviewNames: [String] = []
    @State private var systemSettingsReturnCheckTimer: Timer? = nil
    @State private var waitingForSystemSettingsReturn = false
    @State private var observedSystemSettingsForeground = false
    @State private var isHoveringAppURLContinueButton = false
    @State private var automationPermissionDecisionMonitorTasksByBundleID: [String: Task<Void, Never>] = [:]
    @State private var creatorProfileImage: NSImage? = nil
    @State private var unsupportedAutomationTargets: [UnsupportedAutomationTarget] = []

    // Rewind data flow state
    @State private var hasRewindData: Bool? = nil
    @State private var wantsRewindData: Bool? = (UserDefaults(suiteName: "io.retrace.app") ?? .standard).object(forKey: "useRewindData") as? Bool
    @State private var rewindDataSizeGB: Double? = nil

    // Keyboard shortcuts - initialized from saved values or defaults
    @State private var timelineShortcut = ShortcutKey(from: Self.loadTimelineShortcut())
    @State private var dashboardShortcut = ShortcutKey(from: Self.loadDashboardShortcut())
    @State private var isRecordingTimelineShortcut = false
    @State private var isRecordingDashboardShortcut = false
    @State private var recordingTimeoutTask: Task<Void, Never>? = nil

    // Encryption
    @State private var encryptionEnabled: Bool? = false

    // Launch at login - defaults to true (recommended)
    @State private var launchAtLogin: Bool = true

    let coordinator: AppCoordinator
    let onComplete: () -> Void

    private let totalSteps = 10

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background with gradient orbs (matching dashboard style)
            ZStack {
                Color.retraceBackground

                // Dashboard-style ambient glow background
                onboardingAmbientBackground
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                    .padding(.top, .spacingL)

                // Content (scrollable area)
                ScrollView {
                    VStack(spacing: .spacingXL) {
                        stepContent
                            .transition(.opacity)
                            .id(currentStep)
                    }
                    .padding(.horizontal, .spacingXL)
                    .padding(.vertical, .spacingL)
                    .frame(maxWidth: 900, alignment: .top)
                }
                .frame(maxWidth: 900)
                .scrollDisabled(currentStep == 4)

                // Fixed navigation buttons at bottom
                navigationButtonsFixed
                    .padding(.horizontal, .spacingXL)
                    .padding(.bottom, .spacingL)
                    .frame(maxWidth: 900)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onTapGesture {
            guard currentStep == 1 else { return }
            advanceFromWelcomeStep()
        }
        .task {
            // Only auto-detect Rewind data on first load
            // Don't check permissions until user reaches permissions step
            await detectRewindData()
            // Pre-fetch creator image early so later slides render instantly
            await prefetchCreatorImage()
        }
        .onChange(of: currentStep) { newStep in
            // Save the current step so user can resume if they quit
            UserDefaults.standard.set(newStep, forKey: Self.onboardingStepKey)
        }
    }

    // MARK: - Fixed Navigation Buttons

    private var navigationButtonsFixed: some View {
        HStack {
            // Back button (hidden on step 1)
            if currentStep > 1 {
                Button(action: {
                    withAnimation {
                        // Skip Rewind data step (7) when going back if no Rewind data exists
                        if currentStep == 8 && hasRewindData != true {
                            currentStep = 6
                        } else {
                            currentStep -= 1
                        }
                    }
                }) {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            } else {
                // Invisible placeholder to maintain layout
                HStack(spacing: .spacingS) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.retraceBody)
                .foregroundColor(.clear)
            }

            Spacer()

            // Continue button - different states based on current step
            continueButton
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        switch currentStep {
        case 1:
            // Welcome - No button here (it's in the step itself)
            EmptyView()

        case 2:
            // Creator features
            Button(action: { withAnimation { currentStep = 3 } }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        case 3:
            // Core permissions - requires screen recording + accessibility
            Button(action: { withAnimation { currentStep = 4 } }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(
                        hasScreenRecordingPermission && hasAccessibilityPermission
                            ? onboardingButtonColor
                            : Color.retraceSecondaryColor
                    )
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)
            .disabled(!hasScreenRecordingPermission || !hasAccessibilityPermission)

        case 4:
            // App URL permissions - requires all eligible targets handled, then starts recording
            ZStack {
                Button(action: {
                    stopPermissionMonitoring()
                    Task {
                        try? await coordinator.startPipeline()
                    }
                    MenuBarManager.shared?.reloadShortcuts()
                    withAnimation { currentStep = 5 }
                }) {
                    Text("Continue")
                        .font(.retraceHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, .spacingL)
                        .padding(.vertical, .spacingM)
                        .background(hasAutomationAccessEnabled ? onboardingButtonColor : Color.retraceSecondaryColor)
                        .cornerRadius(.cornerRadiusM)
                }
                .buttonStyle(.plain)
                .disabled(!hasAutomationAccessEnabled)
            }
            .onHover { hovering in
                isHoveringAppURLContinueButton = hovering
            }
            .instantTooltip(
                "Handle each app to continue",
                isVisible: .constant(isHoveringAppURLContinueButton && !hasAutomationAccessEnabled)
            )

        case 5:
            // Menu bar icon info
            Button(action: { withAnimation { currentStep = 6 } }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        case 6:
            // Launch at login - save setting and continue
            // Skip Rewind data step (7) if no Rewind data exists
            Button(action: {
                setLaunchAtLogin(enabled: launchAtLogin)
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                defaults.set(launchAtLogin, forKey: "launchAtLogin")
                withAnimation { currentStep = hasRewindData == true ? 7 : 8 }
            }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        // case 6: - COMMENTED OUT - Screen Recording Indicator step not needed for now
        // case 7: - COMMENTED OUT - Encryption step removed (no reliable encrypt/decrypt migration)

        case 7:
            // Rewind data - requires selection if data exists
            Button(action: {
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                defaults.set(wantsRewindData == true, forKey: "useRewindData")
                withAnimation { currentStep = 8 }
            }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background((hasRewindData == false || wantsRewindData != nil) ? onboardingButtonColor : Color.retraceSecondaryColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)
            .disabled(hasRewindData == true && wantsRewindData == nil)

        case 8:
            // Keyboard shortcuts
            Button(action: {
                Task {
                    // Save shortcuts to UserDefaults (full config with key + modifiers)
                    await coordinator.onboardingManager.setTimelineShortcut(timelineShortcut.toConfig)
                    await coordinator.onboardingManager.setDashboardShortcut(dashboardShortcut.toConfig)
                }
                withAnimation { currentStep = 9 }
            }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        case 9:
            // Safety info
            Button(action: { withAnimation { currentStep = 10 } }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        case 10:
            // Completion - just finish onboarding (recording started on step 4)
            Button(action: {
                // Clear saved step since onboarding is complete
                UserDefaults.standard.removeObject(forKey: Self.onboardingStepKey)
                Task {
                    await coordinator.onboardingManager.markOnboardingCompleted()
                    // Register Rewind data source if user opted in during onboarding
                    try? await coordinator.registerRewindSourceIfEnabled()
                }
                onComplete()
            }) {
                Text("Finish")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        default:
            EmptyView()
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: .spacingS) {
            Text("\(currentStep)/\(totalSteps)")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(1...totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.retraceAccent : Color.retraceSecondaryColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, .spacingL)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 1:
            welcomeStep
        case 2:
            creatorFeaturesStep
        case 3:
            corePermissionsStep
        case 4:
            appURLPermissionsStep
        case 5:
            menuBarIconStep
        // case 6: - COMMENTED OUT - Screen Recording Indicator step not needed for now
        //     screenRecordingIndicatorStep
        // case 7: - COMMENTED OUT - Encryption step removed (no reliable encrypt/decrypt migration)
        //     encryptionStep
        case 6:
            launchAtLoginStep
        case 7:
            rewindDataStep
        case 8:
            keyboardShortcutsStep
        case 9:
            safetyInfoStep
        case 10:
            completionStep
        default:
            EmptyView()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            // Logo
            retraceLogo
                .frame(width: 120, height: 120)

            Text("Welcome to Retrace")
                .font(.retraceDisplay2)
                .foregroundColor(.retracePrimary)

            Text("Remember everything.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            // Get Started button centered in welcome step - goes to creator features
            Button(action: advanceFromWelcomeStep) {
                Text("Get Started")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity) // Match width with other steps to prevent layout jumping
    }

    private func advanceFromWelcomeStep() {
        withAnimation { currentStep = 2 }
    }

    // MARK: - Step 3: Core Permissions

    private var corePermissionsStep: some View {
        VStack(spacing: .spacingXL) {
            Text("Permission Required")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Step 1 of 2: enable core permissions first.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: .spacingL) {
                // Screen Recording Permission
                permissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    subtitle: "Required to capture your screen",
                    isGranted: hasScreenRecordingPermission,
                    isDenied: screenRecordingDenied,
                    action: requestScreenRecording,
                    openSettingsAction: openScreenRecordingSettings
                )

                // Accessibility Permission
                permissionRow(
                    icon: "hand.point.up.braille",
                    title: "Accessibility",
                    subtitle: "Required to detect active windows and extract text",
                    isGranted: hasAccessibilityPermission,
                    action: requestAccessibility
                )
            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            if !hasScreenRecordingPermission || !hasAccessibilityPermission {
                HStack(spacing: .spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.retraceWarning)
                    Text("Screen Recording and Accessibility are required to continue")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceWarning)
                }
            }

            Text("Next: App URL permissions on the following step.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            Spacer()
        }
        .task {
            await checkPermissions()
        }
        .onAppear {
            startPermissionMonitoring()
        }
        .onDisappear {
            stopPermissionMonitoring()
        }
    }

    // MARK: - Step 4: App URL Permissions

    private var appURLPermissionsStep: some View {
        VStack(spacing: .spacingXL) {
            Text("App URL Permissions")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Step 2 of 2: allow Retrace to Extract the URL out of the Following websites.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            appURLPermissionsPanel

            Spacer(minLength: appURLPermissionsBottomMargin)
        }
        .padding(.bottom, appURLPermissionsBottomMargin)
        .onAppear {
            startPermissionMonitoring()
            startAutomationWorkspaceObservation()
            startAutomationForcedSweepMonitoring()
            Task {
                await refreshAutomationPreflightList(reason: "step4-onAppear")
            }
        }
        .onDisappear {
            stopPermissionMonitoring()
            stopAutomationWorkspaceObservation()
        }
        .alert("Allow All Apps?", isPresented: $showBulkAllowAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                Task {
                    await bulkAllowAllAutomationTargetsConfirmed()
                }
            }
        } message: {
            if bulkAllowAllLaunchPreviewNames.isEmpty {
                Text("All pending apps are already running. Retrace will request automation permission for each pending app.")
            } else {
                let appList = bulkAllowAllLaunchPreviewNames.map { "• \($0)" }.joined(separator: "\n")
                Text(
                    "This will launch these apps in order to request permissions:\n\n\(appList)\n\nContinue?"
                )
            }
        }
    }

    private var onboardingWindowHeightForLayout: CGFloat {
        NSApp.keyWindow?.contentView?.bounds.height
            ?? NSApp.mainWindow?.contentView?.bounds.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 900
    }

    private var appURLPermissionsListViewportHeight: CGFloat {
        // Relative to the actual onboarding window, not full screen.
        let relativeHeight = onboardingWindowHeightForLayout * 0.34
        return max(270, min(relativeHeight, 430))
    }

    private var appURLPermissionsBottomMargin: CGFloat {
        let relativeMargin = onboardingWindowHeightForLayout * 0.08
        return max(44, min(relativeMargin, 80))
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        isDenied: Bool = false,
        action: @escaping () -> Void,
        openSettingsAction: (() -> Void)? = nil,
        isActionDisabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            HStack(spacing: .spacingM) {
                Image(systemName: icon)
                    .font(.retraceTitle)
                    .foregroundColor(isGranted ? .retraceSuccess : (isDenied ? .retraceWarning : .retraceAccent))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)

                        Text("(Required)")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceWarning)
                    }

                    Text(subtitle)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.retraceTitle2)
                        .foregroundColor(.retraceSuccess)
                } else if isDenied, let openSettings = openSettingsAction {
                    Button(action: openSettings) {
                        Text("Open Settings")
                            .font(.retraceBody)
                            .foregroundColor(.white)
                            .padding(.horizontal, .spacingM)
                            .padding(.vertical, .spacingS)
                            .background(Color.retraceWarning)
                            .cornerRadius(.cornerRadiusM)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: action) {
                        Text("Enable")
                            .font(.retraceBody)
                            .foregroundColor(.white)
                            .padding(.horizontal, .spacingM)
                            .padding(.vertical, .spacingS)
                            .background(onboardingButtonColor)
                            .cornerRadius(.cornerRadiusM)
                    }
                    .buttonStyle(.plain)
                    .disabled(isActionDisabled)
                }
            }

            // Show denial message with instructions
            if isDenied && !isGranted {
                VStack(alignment: .leading, spacing: .spacingXS) {
                    HStack(spacing: .spacingXS) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.retraceWarning)
                            .font(.retraceCaption2)
                        Text("Permission may have been denied in the past")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceWarning)
                            .fontWeight(.medium)
                    }
                    Text("To enable, open System Settings → Privacy & Security → Screen Recording, then toggle Retrace on.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 44 + .spacingM) // Align with text above
            }
        }
        .padding(.spacingM)
    }

    private var appURLPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            if !hasLoadedAutomationPreflightTargets {
                HStack(spacing: .spacingS) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning apps used for URL extraction...")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            } else if automationPreflightTargets.isEmpty && unsupportedAutomationTargets.isEmpty {
                Text("No eligible apps found on this Mac.")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            } else {
                HStack(alignment: .top, spacing: .spacingM) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apps")
                            .font(.retraceTitle2)
                            .foregroundColor(.retracePrimary)
                        Text("Click 'Allow' to grant permission to Retrace. Click 'Skip' to skip this app.")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }

                    Spacer()

                    HStack(spacing: .spacingS) {
                        Button {
                            presentBulkAllowAllConfirmation()
                        } label: {
                            if isBulkAllowingAutomationTargets {
                                HStack(spacing: .spacingXS) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Allowing...")
                                }
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(onboardingButtonColor)
                                .cornerRadius(.cornerRadiusM)
                                .frame(height: 28)
                            } else {
                                Text("Allow All")
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(onboardingButtonColor)
                                    .cornerRadius(.cornerRadiusM)
                                    .frame(height: 28)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            isBulkAllowingAutomationTargets ||
                            isBulkSkippingAutomationTargets ||
                            actionableAutomationPreflightTargets.isEmpty
                        )

                        if skippedAutomationPreflightTargets.isEmpty {
                            Button {
                                bulkSkipAllAutomationTargets()
                            } label: {
                                if isBulkSkippingAutomationTargets {
                                    HStack(spacing: .spacingXS) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Skipping...")
                                    }
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(Color.retraceSecondaryColor)
                                    .cornerRadius(.cornerRadiusM)
                                    .frame(height: 28)
                                } else {
                                    Text("Skip All")
                                        .font(.retraceCaption)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, .spacingM)
                                        .padding(.vertical, .spacingXS)
                                        .background(Color.retraceSecondaryColor)
                                        .cornerRadius(.cornerRadiusM)
                                        .frame(height: 28)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                isBulkAllowingAutomationTargets ||
                                isBulkSkippingAutomationTargets ||
                                actionableAutomationPreflightTargets.isEmpty
                            )
                        } else {
                            Button {
                                bulkUnskipAllAutomationTargets()
                            } label: {
                                Text("Undo All")
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(Color.retraceSecondaryColor)
                                    .cornerRadius(.cornerRadiusM)
                                    .frame(height: 28)
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                isBulkAllowingAutomationTargets ||
                                isBulkSkippingAutomationTargets
                            )
                        }
                    }
                }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(automationPreflightTargets.enumerated()), id: \.element.id) { index, target in
                            automationPreflightTargetRow(target: target)
                            if index < automationPreflightTargets.count - 1 || !unsupportedAutomationTargets.isEmpty {
                                Divider()
                                    .background(Color.white.opacity(0.08))
                            }
                        }
                        ForEach(Array(unsupportedAutomationTargets.enumerated()), id: \.element.id) { index, target in
                            unsupportedAutomationTargetRow(target: target)
                            if index < unsupportedAutomationTargets.count - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.08))
                            }
                        }
                    }
                }
                .frame(maxHeight: appURLPermissionsListViewportHeight)
                .background(Color.retraceBackground.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: .cornerRadiusM))

                if showCloseLaunchedAppsAction {
                    HStack {
                        Spacer()

                        Button {
                            Task {
                                await closeLaunchedAutomationApps()
                            }
                        } label: {
                            if isClosingLaunchedAutomationApps {
                                HStack(spacing: .spacingXS) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Closing...")
                                }
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(Color.retraceSecondaryColor)
                                .cornerRadius(.cornerRadiusM)
                            } else {
                                Text("Close Launched Apps (\(launchedAutomationRunningCount))")
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(onboardingButtonColor)
                                    .cornerRadius(.cornerRadiusM)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isClosingLaunchedAutomationApps)
                    }
                }

            }
        }
        .padding(36)
        .background(Color.retraceSecondaryBackground)
        .overlay(
            RoundedRectangle(cornerRadius: .cornerRadiusL)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(.cornerRadiusL)
    }

    @MainActor
    private func refreshUnsupportedAutomationTargets() async {
        unsupportedAutomationTargets = Self.unsupportedFirefoxBundleIDs.compactMap { bundleID in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }

            let displayName: String
            if let bundle = Bundle(url: appURL) {
                displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent
            } else {
                displayName = appURL.deletingPathExtension().lastPathComponent
            }

            return UnsupportedAutomationTarget(
                bundleID: bundleID,
                displayName: displayName,
                appURL: appURL
            )
        }
    }

    private func unsupportedAutomationTargetRow(target: UnsupportedAutomationTarget) -> some View {
        HStack(spacing: .spacingL) {
            Group {
                if let appURL = target.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "app.fill")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 30)
                }
            }

            VStack(alignment: .leading, spacing: .spacingS) {
                Text(target.displayName)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary.opacity(0.7))

                Text("Firefox is not supported for in-page URL extraction.")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Text("Not supported")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, .spacingS)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .padding(.horizontal, .spacingL)
        .padding(.vertical, .spacingM)
        .opacity(0.85)
    }

    private func automationPreflightTargetRow(target: AutomationPreflightTarget) -> some View {
        let status = automationStatus(for: target)
        let isRunning = automationPreflightRunningBundleIDs.contains(target.bundleID)

        return HStack(spacing: .spacingL) {
            Group {
                if let icon = automationPreflightIconByBundleID[target.bundleID] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "app.fill")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 30, height: 30)
                }
            }

            VStack(alignment: .leading, spacing: .spacingS) {
                Text(target.displayName)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)

                if status != nil {
                    automationInlineStatusBadge(for: target)
                } else {
                    Text(isRunning ? "Ready to allow" : "Not running")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            if automationPreflightBusyBundleIDs.contains(target.bundleID) {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: .spacingS) {
                    if status == .granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.retraceBody)
                            .foregroundColor(.retraceSuccess)
                    } else if status == .skipped {
                        Button {
                            unskipAutomationTarget(target)
                        } label: {
                            Text("Undo")
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(Color.retraceSecondaryColor)
                                .cornerRadius(.cornerRadiusM)
                        }
                        .buttonStyle(.plain)
                    } else if status == .denied {
                        Button(action: openAutomationSettings) {
                            Text("Open Settings")
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(Color.retraceWarning)
                                .cornerRadius(.cornerRadiusM)
                        }
                        .buttonStyle(.plain)

                        Button {
                            skipAutomationTarget(target)
                        } label: {
                            Text("Skip")
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(Color.retraceSecondaryColor)
                                .cornerRadius(.cornerRadiusM)
                        }
                        .buttonStyle(.plain)
                    } else {
                        if isRunning {
                            Button {
                                Task {
                                    await enableAutomationPermission(for: target)
                                }
                            } label: {
                                Text("Allow")
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(onboardingButtonColor)
                                    .cornerRadius(.cornerRadiusM)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                Task {
                                    await launchAutomationTarget(target)
                                }
                            } label: {
                                Text("Launch")
                                    .font(.retraceCaption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, .spacingM)
                                    .padding(.vertical, .spacingXS)
                                    .background(onboardingButtonColor)
                                    .cornerRadius(.cornerRadiusM)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            skipAutomationTarget(target)
                        } label: {
                            Text("Skip")
                                .font(.retraceCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, .spacingM)
                                .padding(.vertical, .spacingXS)
                                .background(Color.retraceSecondaryColor)
                                .cornerRadius(.cornerRadiusM)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, .spacingL)
        .padding(.vertical, .spacingM)
    }

    private func automationInlineStatusBadge(for target: AutomationPreflightTarget) -> some View {
        Text(automationStatusDescription(for: target))
            .font(.retraceCaption2)
            .foregroundColor(automationStatusColor(for: target))
            .padding(.horizontal, .spacingS)
            .padding(.vertical, 4)
            .background(automationStatusColor(for: target).opacity(0.16))
            .clipShape(Capsule())
    }

    private var actionableAutomationPreflightTargets: [AutomationPreflightTarget] {
        automationPreflightTargets.filter { target in
            let status = automationPreflightStatusByBundleID[target.bundleID]
            return status != .granted && status != .skipped
        }
    }

    private var skippedAutomationPreflightTargets: [AutomationPreflightTarget] {
        automationPreflightTargets.filter { target in
            automationPreflightStatusByBundleID[target.bundleID] == .skipped
        }
    }

    private var hasAutomationAccessEnabled: Bool {
        guard hasLoadedAutomationPreflightTargets else {
            return false
        }

        guard !automationPreflightTargets.isEmpty else {
            return true
        }

        return automationPreflightTargets.allSatisfy { target in
            guard let status = automationPreflightStatusByBundleID[target.bundleID] else {
                return false
            }
            return status == .granted || status == .skipped
        }
    }

    private var automationEnabledCount: Int {
        automationPreflightTargets.filter { target in
            automationPreflightStatusByBundleID[target.bundleID] == .granted
        }.count
    }

    private var automationSkippedCount: Int {
        automationPreflightTargets.filter { target in
            automationPreflightStatusByBundleID[target.bundleID] == .skipped
        }.count
    }

    private var automationRemainingCount: Int {
        automationPreflightTargets.count - automationEnabledCount - automationSkippedCount
    }

    private var launchedAutomationRunningCount: Int {
        automationPreflightLaunchedByOnboardingBundleIDs
            .intersection(automationPreflightRunningBundleIDs)
            .count
    }

    private var showCloseLaunchedAppsAction: Bool {
        hasAutomationAccessEnabled && launchedAutomationRunningCount > 0
    }

    // MARK: - Optional Screen Recording Indicator Step

    private var screenRecordingIndicatorStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            Text("Screen Capture Indicator...")
                .font(.retraceDisplay3)
                .foregroundColor(.retracePrimary)

            Text("Look for this indicator in your menu bar")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            // Screen recording indicator mockup
            screenRecordingIndicator
                .frame(width: 80, height: 80)

            VStack(spacing: .spacingM) {
                Text("This purple icon appears whenever your screen is being recorded.")
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .multilineTextAlignment(.center)

                Text("This is Apple's updated Screen Capture UI — it lets you know Retrace is running and capturing your screen in the background.")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, .spacingXL)
            .frame(maxWidth: 500)

            Spacer()
        }
    }

    // MARK: - Menu Bar Icon Step

    private var menuBarIconStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            Text("Menu Bar Icon")
                .font(.retraceDisplay3)
                .foregroundColor(.retracePrimary)

            Text("Look for this icon in your menu bar")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            // Menu bar mockup
            menuBarMockup
                .frame(height: 100)
                .padding(.horizontal, .spacingXL)

            VStack(spacing: .spacingM) {
                Text("The Retrace icon lives in your menu bar while the app is running.")
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .multilineTextAlignment(.center)

                HStack(spacing: .spacingM) {
                    // Recording state indicator
                    HStack(spacing: .spacingS) {
                        menuBarIconView(recording: true)
                            .frame(width: 30, height: 20)
                        Text("Recording")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }

                    Text("•")
                        .foregroundColor(.retraceSecondary)

                    // Paused state indicator
                    HStack(spacing: .spacingS) {
                        menuBarIconView(recording: false)
                            .frame(width: 30, height: 20)
                        Text("Paused")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }
                }
                .padding(.top, .spacingS)

                // Text("The left triangle fills in when recording is active.")
                //     .font(.retraceCaption)
                //     .foregroundColor(.retraceSecondary)
                //     .multilineTextAlignment(.center)
            }
            .padding(.horizontal, .spacingXL)
            .frame(maxWidth: 680)

            Spacer()
        }
    }

    /// Mockup of the macOS menu bar with the Retrace icon
    private var menuBarMockup: some View {
        VStack(spacing: 0) {
            // Menu bar background
            HStack(spacing: .spacingM) {
                Spacer()

                // Retrace icon - highlighted (leftmost in the right-side icons)
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.retraceAccent.opacity(0.2))
                        .frame(width: 36, height: 24)

                    menuBarIconView(recording: true)
                        .frame(width: 26, height: 18)
                }

                // Other menu bar icons (mockup)
                Image(systemName: "wifi")
                    .font(.system(size: 14))
                    .foregroundColor(.retracePrimary.opacity(0.5))

                Image(systemName: "battery.75")
                    .font(.system(size: 14))
                    .foregroundColor(.retracePrimary.opacity(0.5))

                // Clock mockup
                Text("12:34")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.retracePrimary.opacity(0.5))

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.retracePrimary.opacity(0.5))
            }
            .padding(.horizontal, .spacingL)
            .padding(.vertical, .spacingS)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.retraceSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.retraceBorder, lineWidth: 1)
                    )
            )

            // Arrow pointing to the Retrace icon (now leftmost)
            HStack {
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.retraceAccent)
                Spacer()
                    .frame(width: 190) // Offset to align with the Retrace icon position
            }
            .padding(.top, .spacingS)
        }
    }

    /// SwiftUI recreation of the menu bar icon (matching MenuBarManager)
    private func menuBarIconView(recording: Bool) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let triangleHeight = height * 0.75
            let triangleWidth = width * 0.36
            let verticalCenter = height / 2
            let gap = width * 0.14

            // Left triangle - Points left ◁ (recording indicator)
            // When recording: filled solid, no border
            // When paused: outlined only
            if recording {
                Path { path in
                    let leftTip = width * 0.09
                    let leftBase = leftTip + triangleWidth
                    path.move(to: CGPoint(x: leftTip, y: verticalCenter))
                    path.addLine(to: CGPoint(x: leftBase, y: verticalCenter - triangleHeight / 2))
                    path.addLine(to: CGPoint(x: leftBase, y: verticalCenter + triangleHeight / 2))
                    path.closeSubpath()
                }
                .fill(Color.retracePrimary)
            } else {
                Path { path in
                    let leftTip = width * 0.09
                    let leftBase = leftTip + triangleWidth
                    path.move(to: CGPoint(x: leftTip, y: verticalCenter))
                    path.addLine(to: CGPoint(x: leftBase, y: verticalCenter - triangleHeight / 2))
                    path.addLine(to: CGPoint(x: leftBase, y: verticalCenter + triangleHeight / 2))
                    path.closeSubpath()
                }
                .stroke(Color.retracePrimary, lineWidth: 1.2)
            }

            // Right triangle - Points right ▷ (always outlined)
            Path { path in
                let leftTip = width * 0.09
                let leftBase = leftTip + triangleWidth
                let rightBase = leftBase + gap
                let rightTip = rightBase + triangleWidth
                path.move(to: CGPoint(x: rightTip, y: verticalCenter))
                path.addLine(to: CGPoint(x: rightBase, y: verticalCenter - triangleHeight / 2))
                path.addLine(to: CGPoint(x: rightBase, y: verticalCenter + triangleHeight / 2))
                path.closeSubpath()
            }
            .stroke(Color.retracePrimary, lineWidth: 1.2)
        }
    }

    // MARK: - Step 6: Launch at Login

    private var launchAtLoginStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceAccent.opacity(0.3), Color.retraceDeepBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "power")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(.retracePrimary)
            }

            Text("Launch at Login")
                .font(.retraceDisplay3)
                .foregroundColor(.retracePrimary)

            Text("We recommend launching Retrace at login so it's always running in the background, but you can turn this off if you prefer.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .spacingXL)
                .frame(maxWidth: 500)

            // Toggle
            HStack(spacing: .spacingM) {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(SwitchToggleStyle(tint: Color.retraceAccent))
                    .labelsHidden()

                Text(launchAtLogin ? "Launch at login enabled" : "Launch at login disabled")
                    .font(.retraceBody)
                    .foregroundColor(launchAtLogin ? .retracePrimary : .retraceSecondary)
            }
            .padding(.vertical, .spacingM)

            Text("You can always change this later in Settings.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    // MARK: - Step 6: Encryption

    private var encryptionStep: some View {
        VStack(spacing: .spacingL) {
            // Lock icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceAccent.opacity(0.3), Color.retraceDeepBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: encryptionEnabled == true ? "lock.shield.fill" : "lock.open.fill")
                    .font(.retraceDisplay)
                    .foregroundColor(encryptionEnabled == true ? .retraceSuccess : .retraceSecondary)
            }

            Text("Database Encryption")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Would you like to encrypt your database? This adds an extra layer of security.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .spacingL)

            VStack(alignment: .leading, spacing: .spacingM) {
                HStack(spacing: .spacingM) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.retraceSuccess)
                    Text("All data is stored locally on your machine")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }


                HStack(spacing: .spacingM) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.retraceSuccess)
                    Text("You can unencrypt at any time in Settings")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }


            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            // Yes/No buttons
            HStack(spacing: .spacingM) {
                Button(action: {
                    withAnimation {
                        encryptionEnabled = true
                    }
                }) {
                    HStack(spacing: .spacingM) {
                        Image(systemName: encryptionEnabled == true ? "checkmark.circle.fill" : "circle")
                            .font(.retraceTitle2)
                            .foregroundColor(encryptionEnabled == true ? .retraceSuccess : .retraceSecondary)

                        Text("Yes")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)
                    }
                    .padding(.spacingM)
                    .frame(width: 150)
                    .background(encryptionEnabled == true ? Color.retraceSuccess.opacity(0.1) : Color.retraceSecondaryBackground)
                    .cornerRadius(.cornerRadiusM)
                    .overlay(
                        RoundedRectangle(cornerRadius: .cornerRadiusM)
                            .stroke(encryptionEnabled == true ? Color.retraceSuccess : Color.retraceBorder, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation {
                        encryptionEnabled = false
                    }
                }) {
                    HStack(spacing: .spacingM) {
                        Image(systemName: encryptionEnabled == false ? "checkmark.circle.fill" : "circle")
                            .font(.retraceTitle2)
                            .foregroundColor(encryptionEnabled == false ? .retraceAccent : .retraceSecondary)

                        Text("No")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)
                    }
                    .padding(.spacingM)
                    .frame(width: 150)
                    .background(encryptionEnabled == false ? Color.retraceAccent.opacity(0.1) : Color.retraceSecondaryBackground)
                    .cornerRadius(.cornerRadiusM)
                    .overlay(
                        RoundedRectangle(cornerRadius: .cornerRadiusM)
                            .stroke(encryptionEnabled == false ? Color.retraceAccent : Color.retraceBorder, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
            }

            Text("You can change this later in Settings.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            Spacer()
        }
    }

    // MARK: - Creator Header

    private var creatorHeader: some View {
        VStack(spacing: .spacingM) {
            // Profile picture centered - bundled locally (no network request needed)
            creatorProfileImageView(size: 80)

            Text("Hey, thanks for trying Retrace!")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            ensureCreatorProfileImageLoaded(reason: "creator-header-onAppear")
        }
    }

    private var creatorPlaceholder: some View {
        Circle()
            .fill(Color.retraceAccent.opacity(0.3))
            .overlay(
                Text("H")
                    .font(.retraceDisplay3)
                    .foregroundColor(.white)
            )
    }

    private func prefetchCreatorImage() async {
        ensureCreatorProfileImageLoaded(reason: "prefetch")
    }

    // MARK: - Step 2: Creator Features

    private var creatorFeaturesStep: some View {
        VStack(spacing: 0) {
            // Fixed header
            creatorHeader
                .padding(.bottom, .spacingL)

            // Scrollable features container with fixed height
            ScrollView {
                VStack(alignment: .leading, spacing: .spacingL) { 
                    // What this version has (green)
                    VStack(alignment: .leading, spacing: .spacingM) {
                        Text("What This Version Has")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceSuccess)

                        VStack(alignment: .leading, spacing: .spacingS) {
                            featureItem(icon: "checkmark.circle.fill", text: "Easy Connection to Old Rewind Data", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Timeline Scrolling", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Continuous Screen Capture", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Basic Search", color: .retraceSuccess)
                            // featureItem(icon: "checkmark.circle.fill", text: "Basic Keyboard Shortcuts", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Deletion of Data", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Basic Settings", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Daily Dashboard", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Search Highlighting", color: .retraceSuccess)
                            featureItem(icon: "checkmark.circle.fill", text: "Exclude Apps / Private Windows", color: .retraceSuccess)
                        }
                    }
                    .padding(.spacingL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceSuccess.opacity(0.05))
                    .cornerRadius(.cornerRadiusL)

                    // Coming soon (yellow)
                    VStack(alignment: .leading, spacing: .spacingM) {
                        Text("Coming Soon")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceWarning)

                        VStack(alignment: .leading, spacing: .spacingS) {
                            featureItem(icon: "circle.fill", text: "Audio Recording", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "Optimized Power & Storage", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "Decrypt and Backup your Rewind Database", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "More Advanced Shortcuts", color: .retraceWarning)
                        }
                    }
                    .padding(.spacingL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceWarning.opacity(0.05))
                    .cornerRadius(.cornerRadiusL)

                    // Not planned yet (red)
                    VStack(alignment: .leading, spacing: .spacingM) {
                        Text("Not Yet Planned")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceDanger)

                        VStack(alignment: .leading, spacing: .spacingS) {
                            featureItem(icon: "xmark.circle.fill", text: "'Ask Retrace' Chatbot", color: .retraceDanger)
                            featureItem(icon: "xmark.circle.fill", text: "Embeddings / Vector Search", color: .retraceDanger)
                        }
                    }
                    .padding(.spacingL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceDanger.opacity(0.05))
                    .cornerRadius(.cornerRadiusL)
                }
                .frame(maxWidth: 600)
                .padding(.spacingM)
            }
            .frame(minHeight: 350, maxHeight: .infinity)
            .background(Color.retraceSecondaryBackground.opacity(0.5))
            .cornerRadius(.cornerRadiusL)
        }
    }

    private func featureItem(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: .spacingS) {
            Image(systemName: icon)
                .font(.retraceCaption2)
                .foregroundColor(color)
            Text(text)
                .font(.retraceBody)
                .foregroundColor(.retracePrimary)
        }
    }

    private func featureSection(title: String, features: [(String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            Text(title)
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            ForEach(features, id: \.1) { icon, text, color in
                HStack(spacing: .spacingS) {
                    Image(systemName: icon)
                        .font(.retraceCaption2)
                        .foregroundColor(color)
                    Text(text)
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }
            }
        }
    }

    // MARK: - Step 7: Rewind Data

    private var rewindDataStep: some View {
        VStack(spacing: .spacingL) {
            if hasRewindData == true {
                // Rewind data detected - ask if they want to include it on Timeline
                VStack(spacing: .spacingL) {
                    // Rewind-style double arrow icon
                    rewindIcon
                        .frame(width: 100, height: 100)

                    Text("Use Rewind Data?")
                        .font(.retraceTitle)
                        .foregroundColor(.retracePrimary)
                    // File info card
                    VStack(alignment: .center, spacing: .spacingM) {
                        HStack(spacing: .spacingM) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.retraceSuccess)
                            Text("Rewind database detected")
                                .font(.retraceBody)
                                .foregroundColor(.retracePrimary)
                        }

                        VStack(alignment: .center, spacing: .spacingS) {
                            HStack(spacing: .spacingS) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(LinearGradient.retraceAccentGradient)
                                Text("Location")
                                    .font(.retraceCaption)
                                    .foregroundColor(.retraceSecondary)
                            }

                            Text(AppPaths.rewindStorageRoot)
                                .font(.retraceMonoSmall)
                                .foregroundColor(.retracePrimary)
                                .multilineTextAlignment(.center)

                            if let sizeGB = rewindDataSizeGB {
                                Text(String(format: "%.1f GB", sizeGB))
                                    .font(.retraceCaption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(LinearGradient.retraceAccentGradient)
                            }
                        }
                    }
                    .padding(.spacingL)
                    .frame(maxWidth: 500)
                    .background(Color.retraceSecondaryBackground)
                    .cornerRadius(.cornerRadiusL)

                    // Yes/No buttons
                    HStack(spacing: .spacingM) {
                        Button(action: {
                            withAnimation {
                                wantsRewindData = true
                            }
                        }) {
                            HStack(spacing: .spacingM) {
                                Image(systemName: wantsRewindData == true ? "checkmark.circle.fill" : "circle")
                                    .font(.retraceTitle2)
                                    .foregroundColor(wantsRewindData == true ? .retraceSuccess : .retraceSecondary)

                                Text("Yes, Use")
                                    .font(.retraceHeadline)
                                    .foregroundColor(.retracePrimary)
                            }
                            .padding(.spacingM)
                            .frame(width: 180)
                            .background(wantsRewindData == true ? Color.retraceSuccess.opacity(0.1) : Color.retraceSecondaryBackground)
                            .cornerRadius(.cornerRadiusM)
                            .overlay(
                                RoundedRectangle(cornerRadius: .cornerRadiusM)
                                    .stroke(wantsRewindData == true ? Color.retraceSuccess : Color.retraceBorder, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation {
                                wantsRewindData = false
                            }
                        }) {
                            HStack(spacing: .spacingM) {
                                Image(systemName: wantsRewindData == false ? "checkmark.circle.fill" : "circle")
                                    .font(.retraceTitle2)
                                    .foregroundColor(wantsRewindData == false ? .retraceAccent : .retraceSecondary)

                                Text("No, Don't Use")
                                    .font(.retraceHeadline)
                                    .foregroundColor(.retracePrimary)
                            }
                            .padding(.spacingM)
                            .frame(width: 200)
                            .background(wantsRewindData == false ? Color.retraceAccent.opacity(0.1) : Color.retraceSecondaryBackground)
                            .cornerRadius(.cornerRadiusM)
                            .overlay(
                                RoundedRectangle(cornerRadius: .cornerRadiusM)
                                    .stroke(wantsRewindData == false ? Color.retraceAccent : Color.retraceBorder, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("You can import Rewind data later from Settings.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
                .padding(.spacingXL)
                .background(Color.clear)
                .cornerRadius(.cornerRadiusL)

            } else if hasRewindData == false {
                // No Rewind data found - show embellished view
                VStack(spacing: .spacingL) {
                    // Rewind icon in muted/grey state
                    rewindIconMuted
                        .frame(width: 100, height: 100)

                    Text("Import Rewind Data")
                        .font(.retraceTitle)
                        .foregroundColor(.retracePrimary)

                    VStack(spacing: .spacingM) {
                        HStack(spacing: .spacingM) {
                            Image(systemName: "info.circle.fill")
                                .font(.retraceTitle3)
                                .foregroundColor(.retraceSecondary)
                            Text("No Rewind data found on this machine")
                                .font(.retraceBody)
                                .foregroundColor(.retraceSecondary)
                        }

                        Text("If you have Rewind data you'd like to import later, you can do so from Settings.")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.spacingL)
                    .background(Color.retraceSecondaryBackground)
                    .cornerRadius(.cornerRadiusL)
                }
                .padding(.spacingXL)
                .background(Color.clear)
                .cornerRadius(.cornerRadiusL)
            }

            Spacer()
        }
    }

    // MARK: - Step 8: Keyboard Shortcuts

    @State private var shortcutError: String? = nil

    private var keyboardShortcutsStep: some View {
        VStack(spacing: .spacingL) {
            Text("Customize Keyboard Shortcuts")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Click on a shortcut to record a new key. Press Escape or click elsewhere to cancel.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)

            VStack(spacing: .spacingL) {
                shortcutRecorderRow(
                    label: "Launch Timeline",
                    shortcut: $timelineShortcut,
                    isRecording: $isRecordingTimelineShortcut,
                    otherShortcut: dashboardShortcut,
                    onShortcutCaptured: { newShortcut in
                        // Save and apply timeline shortcut immediately
                        Task {
                            await coordinator.onboardingManager.setTimelineShortcut(newShortcut.toConfig)
                            // Reload shortcuts and re-register hotkeys so the new shortcut works immediately
                            MenuBarManager.shared?.reloadShortcuts()
                        }
                    }
                )

                Divider()
                    .background(Color.retraceBorder)

                shortcutRecorderRow(
                    label: "Launch Dashboard",
                    shortcut: $dashboardShortcut,
                    isRecording: $isRecordingDashboardShortcut,
                    otherShortcut: timelineShortcut,
                    onShortcutCaptured: { newShortcut in
                        // Save and apply dashboard shortcut immediately
                        Task {
                            await coordinator.onboardingManager.setDashboardShortcut(newShortcut.toConfig)
                            // Reload shortcuts and re-register hotkeys so the new shortcut works immediately
                            MenuBarManager.shared?.reloadShortcuts()
                        }
                    }
                )
            }
            .padding(.spacingXL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)
            .frame(maxWidth: 600)

            if let error = shortcutError {
                HStack(spacing: .spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.retraceWarning)
                    Text(error)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceWarning)
                }
            }

            Text("You can change these later in Settings.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Cancel recording if user clicks outside the shortcut buttons
            if isRecordingTimelineShortcut || isRecordingDashboardShortcut {
                isRecordingTimelineShortcut = false
                isRecordingDashboardShortcut = false
                recordingTimeoutTask?.cancel()
            }
        }
    }

    private func shortcutRecorderRow(
        label: String,
        shortcut: Binding<ShortcutKey>,
        isRecording: Binding<Bool>,
        otherShortcut: ShortcutKey,
        onShortcutCaptured: @escaping (ShortcutKey) -> Void
    ) -> some View {
        HStack(spacing: .spacingL) {
            VStack(alignment: .leading, spacing: .spacingS) {
                Text(label)
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            // Shortcut display/recorder button
            Button(action: {
                // Cancel any other recording first
                isRecordingTimelineShortcut = false
                isRecordingDashboardShortcut = false
                shortcutError = nil
                recordingTimeoutTask?.cancel()

                // Then start this one
                isRecording.wrappedValue = true

                // Start 10 second timeout
                recordingTimeoutTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(10_000_000_000)), clock: .continuous) // 10 seconds
                    if !Task.isCancelled {
                        await MainActor.run {
                            isRecording.wrappedValue = false
                        }
                    }
                }
            }) {
                Group {
                    if isRecording.wrappedValue {
                        // Show "Press key combo..." when recording
                        Text("Press key combo...")
                            .font(.retraceBody)
                            .foregroundStyle(LinearGradient.retraceAccentGradient)
                            .frame(minWidth: 150, minHeight: 32)
                    } else {
                        // Show actual shortcut when not recording
                        HStack(spacing: .spacingS) {
                            // Display modifier keys dynamically
                            ForEach(shortcut.wrappedValue.modifierSymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.retraceHeadline)
                                    .foregroundColor(.retraceSecondary)
                                    .frame(width: 32, height: 32)
                                    .background(Color.retraceCard)
                                    .cornerRadius(.cornerRadiusS)
                            }

                            if !shortcut.wrappedValue.modifierSymbols.isEmpty {
                                Text("+")
                                    .font(.retraceBody)
                                    .foregroundColor(.retraceSecondary)
                            }

                            // Key
                            Text(shortcut.wrappedValue.key)
                                .font(.retraceHeadline)
                                .foregroundColor(.retracePrimary)
                                .frame(minWidth: 50, minHeight: 32)
                                .padding(.horizontal, .spacingM)
                                .background(Color.retraceCard)
                                .cornerRadius(.cornerRadiusS)
                        }
                    }
                }
                .padding(.spacingS)
                .background(isRecording.wrappedValue ? Color.retraceAccent.opacity(0.1) : Color.retraceSecondaryBackground)
                .cornerRadius(.cornerRadiusM)
                .overlay(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .stroke(isRecording.wrappedValue ? Color.retraceAccent : Color.retraceBorder, lineWidth: isRecording.wrappedValue ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .background(
                // Key capture happens in a focused view
                ShortcutCaptureField(
                    isRecording: isRecording,
                    capturedShortcut: shortcut,
                    otherShortcut: otherShortcut,
                    onDuplicateAttempt: {
                        shortcutError = "This shortcut is already in use"
                    },
                    onShortcutCaptured: onShortcutCaptured
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    // MARK: - Step 9: Early Alpha / Safety Info

    private var safetyInfoStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            // Alpha warning badge
            VStack(spacing: .spacingM) {
                ZStack {
                    // Outer glow
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.retraceWarning.opacity(0.15))
                        .frame(width: 180, height: 50)
                        .blur(radius: 10)

                    // Badge
                    HStack(spacing: .spacingS) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.retraceHeadline)
                        Text("EARLY ALPHA")
                            .font(.retraceHeadline)
                    }
                    .foregroundColor(.retraceWarning)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.retraceWarning.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.retraceWarning.opacity(0.5), lineWidth: 2)
                            )
                    )
                }

                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            // Creator section
            VStack(spacing: .spacingM) {
                // Profile picture - bundled locally
                creatorProfileImageView(
                    size: 70,
                    ringColor: Color.retraceAccent.opacity(0.3),
                    ringWidth: 2
                )

                Text("Thanks for being an early user!")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)
            }
            .onAppear {
                ensureCreatorProfileImageLoaded(reason: "safety-step-onAppear")
            }

            // Info card
            VStack(alignment: .leading, spacing: .spacingM) {
                HStack(spacing: .spacingM) {
                    Image(systemName: "ant.fill")
                        .font(.retraceTitle3)
                        .foregroundColor(.retraceWarning)
                    Text("Expect bugs - things will break")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }

                HStack(spacing: .spacingM) {
                    Image(systemName: "message.fill")
                        .font(.retraceTitle3)
                        .foregroundStyle(LinearGradient.retraceAccentGradient)
                    Text("Please report issues often")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }

                HStack(spacing: .spacingM) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.retraceTitle3)
                        .foregroundColor(.retraceSuccess)
                    Text("Fixes ship fast")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }
            }
            .padding(.spacingL)
            .frame(maxWidth: 400)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            Spacer()
        }
    }

    // MARK: - Step 10: Completion

    private var completionStep: some View {
        VStack(spacing: .spacingL) {
            Spacer()

            // Logo
            retraceLogo
                .frame(width: 120, height: 120)

            Text("You're All Set!")
                .font(.retraceDisplay2)
                .foregroundColor(.retracePrimary)

            Text("Retrace is now capturing your screen in the background.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .spacingXL)

            // Prompt to test timeline
            VStack(spacing: .spacingM) {
                Text("Test it out!")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("Press your timeline shortcut to see what you've recorded:")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)

                // Display the timeline shortcut
                HStack(spacing: .spacingS) {
                    // Display modifier keys dynamically
                    ForEach(timelineShortcut.modifierSymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.retraceTitle3)
                            .foregroundColor(.retraceSecondary)
                            .frame(width: 40, height: 40)
                            .background(Color.retraceCard)
                            .cornerRadius(.cornerRadiusS)
                    }

                    if !timelineShortcut.modifierSymbols.isEmpty {
                        Text("+")
                            .font(.retraceBody)
                            .foregroundColor(.retraceSecondary)
                    }

                    // Key
                    Text(timelineShortcut.key)
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                        .frame(minWidth: 60, minHeight: 40)
                        .padding(.horizontal, .spacingM)
                        .background(onboardingButtonColor)
                        .cornerRadius(.cornerRadiusS)
                }
            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)
            .frame(maxWidth: 500)

            Spacer()
        }
    }

    @ViewBuilder
    private func creatorProfileImageView(
        size: CGFloat,
        ringColor: Color = .clear,
        ringWidth: CGFloat = 0
    ) -> some View {
        if let creatorProfileImage {
            Image(nsImage: creatorProfileImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(ringColor, lineWidth: ringWidth)
                )
        } else {
            creatorPlaceholder
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(ringColor, lineWidth: ringWidth)
                )
        }
    }

    private func ensureCreatorProfileImageLoaded(reason: String) {
        guard creatorProfileImage == nil else { return }
        creatorProfileImage = resolveCreatorProfileImage(logContext: "[OnboardingView] \(reason)")
    }

    private func resolveCreatorProfileImage(logContext: String) -> NSImage? {
        let imageName = NSImage.Name("CreatorProfile")

        if let image = NSImage(named: imageName) {
            Log.info("\(logContext) Loaded CreatorProfile via NSImage(named:)", category: .ui)
            return image
        }

        if let image = Bundle.main.image(forResource: imageName) {
            Log.info("\(logContext) Loaded CreatorProfile via Bundle.main.image(forResource:)", category: .ui)
            return image
        }

#if SWIFT_PACKAGE
        if let image = Bundle.module.image(forResource: imageName) {
            Log.info("\(logContext) Loaded CreatorProfile via Bundle.module.image(forResource:)", category: .ui)
            return image
        }
#endif

        let fileManager = FileManager.default
        let resourcePath = Bundle.main.resourcePath ?? ""
        let bundleCandidates: [(label: String, path: String)] = [
            ("bundle/CreatorProfile.png", "\(resourcePath)/CreatorProfile.png"),
            ("bundle/haseab.png", "\(resourcePath)/haseab.png"),
            ("bundle/Assets.xcassets/CreatorProfile.imageset/haseab.png", "\(resourcePath)/Assets.xcassets/CreatorProfile.imageset/haseab.png")
        ]

        for candidate in bundleCandidates where fileManager.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOfFile: candidate.path) {
                Log.warning("\(logContext) Loaded creator profile via file fallback \(candidate.label)", category: .ui)
                return image
            }
        }

#if SWIFT_PACKAGE
        let moduleResourcePath = Bundle.module.resourcePath ?? ""
        let moduleCandidates: [(label: String, path: String)] = [
            ("module/CreatorProfile.png", "\(moduleResourcePath)/CreatorProfile.png"),
            ("module/haseab.png", "\(moduleResourcePath)/haseab.png"),
            ("module/Assets.xcassets/CreatorProfile.imageset/haseab.png", "\(moduleResourcePath)/Assets.xcassets/CreatorProfile.imageset/haseab.png")
        ]
        for candidate in moduleCandidates where fileManager.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOfFile: candidate.path) {
                Log.warning("\(logContext) Loaded creator profile via SwiftPM module file fallback \(candidate.label)", category: .ui)
                return image
            }
        }
#endif

        let debugWorkingTreePath = "\(fileManager.currentDirectoryPath)/UI/Assets.xcassets/CreatorProfile.imageset/haseab.png"
        if fileManager.fileExists(atPath: debugWorkingTreePath),
           let image = NSImage(contentsOfFile: debugWorkingTreePath) {
            Log.warning("\(logContext) Loaded creator profile via working-tree fallback path", category: .ui)
            return image
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let bundlePath = Bundle.main.bundlePath
        let hasAssetsCar = fileManager.fileExists(atPath: "\(resourcePath)/Assets.car")
        let candidateSummary = bundleCandidates
            .map { "\($0.label)=\(fileManager.fileExists(atPath: $0.path) ? "exists" : "missing")" }
            .joined(separator: ",")

        Log.error(
            "\(logContext) CreatorProfile missing. bundleID=\(bundleID), bundlePath=\(bundlePath), hasAssetsCar=\(hasAssetsCar), fileCandidates=\(candidateSummary)",
            category: .ui
        )
        return nil
    }

    // MARK: - Screen Recording Indicator

    private var screenRecordingIndicator: some View {
        ZStack {
            // Purple rounded rectangle background (matching Apple's indicator)
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.6, green: 0.4, blue: 0.9), Color(red: 0.5, green: 0.3, blue: 0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Person with screen icon
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.retraceDisplay2)
                .foregroundColor(.white)
        }
    }

    // MARK: - Helper Functions

    /// Enable or disable launch at login using SMAppService (macOS 13+)
    private func setLaunchAtLogin(enabled: Bool) {
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
            Log.error("[OnboardingView] Failed to \(enabled ? "enable" : "disable") launch at login: \(error)", category: .ui)
        }
    }

    // MARK: - Helper Views

    /// Dashboard-style ambient background with blue glow orbs
    private var onboardingAmbientBackground: some View {
        // Blue theme colors (matching dashboard)
        let ambientGlowColor = Color(red: 14/255, green: 42/255, blue: 104/255)  // Deeper blue orb: #0e2a68

        return GeometryReader { geometry in
            ZStack {
                // Primary accent orb (top-left) - uses theme color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.retraceAccent.opacity(0.10), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .offset(x: -200, y: -100)
                    .blur(radius: 60)

                // Secondary orb (top-left) - theme glow color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(0.3), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(x: -150, y: -50)
                    .blur(radius: 50)

                // Top edge glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ambientGlowColor.opacity(0.6), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .position(x: geometry.size.width / 2, y: 0)
                    .blur(radius: 30)

                // Bottom-right corner glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(0.5), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 400
                        )
                    )
                    .frame(width: 800, height: 800)
                    .position(x: geometry.size.width, y: geometry.size.height)
                    .blur(radius: 80)
            }
        }
    }

    private var retraceLogo: some View {
        // Recreate the SVG logo in SwiftUI - just the triangles, no background circle
        ZStack {
            // Left triangle pointing left
            Path { path in
                path.move(to: CGPoint(x: 15, y: 60))
                path.addLine(to: CGPoint(x: 54, y: 33))
                path.addLine(to: CGPoint(x: 54, y: 87))
                path.closeSubpath()
            }
            .fill(Color.retracePrimary.opacity(0.9))

            // Right triangle pointing right
            Path { path in
                path.move(to: CGPoint(x: 105, y: 60))
                path.addLine(to: CGPoint(x: 66, y: 33))
                path.addLine(to: CGPoint(x: 66, y: 87))
                path.closeSubpath()
            }
            .fill(Color.retracePrimary.opacity(0.9))
        }
    }

    /// Rewind-style double arrow icon (⏪) matching the app's color scheme
    private var rewindIcon: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let centerX = size / 2
            let centerY = size / 2
            let arrowHeight = size * 0.45
            let arrowWidth = size * 0.28
            let gap = size * 0.02  // Small gap between arrows
            let leftOffset = size * 0.08  // Shift arrows to the left

            // Total width of both arrows + gap, centered around centerX, then shifted left
            let totalWidth = arrowWidth * 2 + gap
            let startX = centerX - totalWidth / 2 - leftOffset

            ZStack {
                // Background circle with gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceAccent.opacity(0.3), Color.retraceDeepBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Left arrow (first rewind arrow)
                Path { path in
                    let tipX = startX
                    let baseX = tipX + arrowWidth
                    path.move(to: CGPoint(x: tipX, y: centerY))
                    path.addLine(to: CGPoint(x: baseX, y: centerY - arrowHeight / 2))
                    path.addLine(to: CGPoint(x: baseX, y: centerY + arrowHeight / 2))
                    path.closeSubpath()
                }
                .fill(Color.retraceAccent)

                // Right arrow (second rewind arrow)
                Path { path in
                    let tipX = startX + arrowWidth + gap
                    let baseX = tipX + arrowWidth
                    path.move(to: CGPoint(x: tipX, y: centerY))
                    path.addLine(to: CGPoint(x: baseX, y: centerY - arrowHeight / 2))
                    path.addLine(to: CGPoint(x: baseX, y: centerY + arrowHeight / 2))
                    path.closeSubpath()
                }
                .fill(Color.retraceAccent)
            }
        }
    }

    /// Muted version of rewind icon for "no data found" state
    private var rewindIconMuted: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let centerX = size / 2
            let centerY = size / 2
            let arrowHeight = size * 0.45
            let arrowWidth = size * 0.28
            let gap = size * 0.02  // Small gap between arrows
            let leftOffset = size * 0.08  // Shift arrows to the left

            // Total width of both arrows + gap, centered around centerX, then shifted left
            let totalWidth = arrowWidth * 2 + gap
            let startX = centerX - totalWidth / 2 - leftOffset

            ZStack {
                // Background circle with muted gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceSecondary.opacity(0.3), Color.retraceDeepBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Left arrow (first rewind arrow) - muted
                Path { path in
                    let tipX = startX
                    let baseX = tipX + arrowWidth
                    path.move(to: CGPoint(x: tipX, y: centerY))
                    path.addLine(to: CGPoint(x: baseX, y: centerY - arrowHeight / 2))
                    path.addLine(to: CGPoint(x: baseX, y: centerY + arrowHeight / 2))
                    path.closeSubpath()
                }
                .fill(Color.retraceSecondary)

                // Right arrow (second rewind arrow) - muted
                Path { path in
                    let tipX = startX + arrowWidth + gap
                    let baseX = tipX + arrowWidth
                    path.move(to: CGPoint(x: tipX, y: centerY))
                    path.addLine(to: CGPoint(x: baseX, y: centerY - arrowHeight / 2))
                    path.addLine(to: CGPoint(x: baseX, y: centerY + arrowHeight / 2))
                    path.closeSubpath()
                }
                .fill(Color.retraceSecondary)
            }
        }
    }

    // MARK: - Permission Handling

    private func checkPermissions() async {
        // Check screen recording
        hasScreenRecordingPermission = await checkScreenRecordingPermission()

        // Check accessibility without prompting so granted state is restored on app restart.
        hasAccessibilityPermission = checkAccessibilityPermission()
        if hasAccessibilityPermission {
            accessibilityRequested = true
        }
    }

    private func checkScreenRecordingPermission() async -> Bool {
        // Use CGPreflightScreenCaptureAccess - this never triggers a prompt
        // This is the only reliable way to check permission status without triggering dialogs
        return CGPreflightScreenCaptureAccess()
    }

    private func checkAccessibilityPermission() -> Bool {
        // Don't prompt, just check current status
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ]
        return AXIsProcessTrustedWithOptions(options) as Bool
    }

    private func requestScreenRecording() {
        // If already granted, nothing to do
        if CGPreflightScreenCaptureAccess() {
            return
        }

        // If we've already detected a denial, open settings instead
        if screenRecordingDenied {
            openScreenRecordingSettings()
            return
        }

        // Mark that we've requested permission BEFORE making the request
        screenRecordingRequested = true

        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                let errorDescription = error.localizedDescription
                Log.warning("[OnboardingView] Screen recording permission request: \(error)", category: .ui)

                // If we get the TCC "declined" error, they denied
                if errorDescription.contains("declined") {
                    await MainActor.run {
                        screenRecordingDenied = true
                    }
                    Log.info("[OnboardingView] User denied - showing Open Settings button", category: .ui)
                }
            }
        }
    }

    private func openScreenRecordingSettings() {
        // Open System Settings to Screen Recording privacy pane
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if NSWorkspace.shared.open(url) {
            startWaitingForSystemSettingsReturn()
        } else {
            Log.warning("[OnboardingView] Failed to open Screen Recording settings URL", category: .ui)
        }
    }

    private func openAutomationSettings() {
        // Open System Settings to Automation privacy pane
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        if NSWorkspace.shared.open(url) {
            startWaitingForSystemSettingsReturn()
        } else {
            Log.warning("[OnboardingView] Failed to open Automation settings URL", category: .ui)
        }
    }

    private func requestAccessibility() {
        // Mark that user has requested accessibility - this enables polling for this permission
        accessibilityRequested = true

        // Request accessibility permission with prompt
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)

        // Start polling for permission
        Task {
            for _ in 0..<30 { // Check for up to 30 seconds
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous)

                // Check without prompting during polling
                let checkOptions: NSDictionary = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
                ]
                let granted = AXIsProcessTrustedWithOptions(checkOptions) as Bool

                if granted {
                    await MainActor.run {
                        hasAccessibilityPermission = true
                    }
                    break
                }
            }
        }
    }

    // MARK: - Permission Monitoring

    @MainActor
    private func startPermissionMonitoring() {
        Log.info("[OnboardingView] Permission monitoring started", category: .ui)
        // Start timer to continuously check permissions every 2 seconds
        // Note: Initial check is done in .task block, not here
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                // Check screen recording
                let previousScreenRecording = hasScreenRecordingPermission
                hasScreenRecordingPermission = await checkScreenRecordingPermission()
                if !previousScreenRecording && hasScreenRecordingPermission {
                    bringOnboardingToFront(reason: "screen-recording-granted")
                }

                // Check accessibility without prompting so state stays in sync after relaunch.
                let previousAccessibility = hasAccessibilityPermission
                hasAccessibilityPermission = checkAccessibilityPermission()
                if hasAccessibilityPermission {
                    accessibilityRequested = true
                }

                // If accessibility was just granted, retry setting up global hotkeys
                if !previousAccessibility && hasAccessibilityPermission {
                    HotkeyManager.shared.retrySetupIfNeeded()
                    bringOnboardingToFront(reason: "accessibility-granted")
                }

                // On macOS 15+, when both permissions are granted, trigger the capture dialog
                // This shows "Allow [App] to record screen & audio" dialog while still on permissions step
                if hasScreenRecordingPermission && hasAccessibilityPermission && !hasTriggeredCaptureDialog {
                    triggerMacOS15CaptureDialog()
                }

                let previousRunningBundleIDs = automationPreflightRunningBundleIDs
                await refreshAutomationRunningBundleIDs()
                if previousRunningBundleIDs != automationPreflightRunningBundleIDs {
                    await refreshAutomationPreflightPermissionStateIfNeeded(reason: "running-set-changed")
                } else {
                    Log.debug(
                        "[OnboardingView] Skipping automation permission recheck on tick: running set unchanged",
                        category: .ui
                    )
                }
                checkForSystemSettingsReturn()
            }
        }
    }

    @MainActor
    private func startAutomationForcedSweepMonitoring() {
        guard automationForcedSweepTimer == nil else {
            Log.debug("[OnboardingView] Forced automation sweep monitoring already active", category: .ui)
            return
        }

        Log.info(
            "[OnboardingView] Forced automation sweep monitoring started (interval=\(Self.automationForcedSweepIntervalSeconds)s)",
            category: .ui
        )
        automationForcedSweepTimer = Timer.scheduledTimer(
            withTimeInterval: Self.automationForcedSweepIntervalSeconds,
            repeats: true
        ) { _ in
            Task { @MainActor in
                guard currentStep == 4 else { return }
                await refreshAutomationPreflightPermissionStateIfNeeded(
                    force: true,
                    reason: "step4-forced-sweep-tick"
                )
            }
        }
    }

    @MainActor
    private func stopAutomationForcedSweepMonitoring() {
        guard automationForcedSweepTimer != nil else {
            Log.debug("[OnboardingView] Forced automation sweep monitoring already stopped", category: .ui)
            return
        }

        automationForcedSweepTimer?.invalidate()
        automationForcedSweepTimer = nil
        Log.info("[OnboardingView] Forced automation sweep monitoring stopped", category: .ui)
    }

    /// Triggers a single screen capture to prompt the macOS 15+ "Allow to record screen & audio" dialog.
    /// This ensures the dialog appears on the permissions step rather than after moving to the next step.
    private func triggerMacOS15CaptureDialog() {
        hasTriggeredCaptureDialog = true

        // A single CGDisplayCreateImage call is enough to trigger the system dialog on macOS 15+
        // We don't need to use the result - we just need to make the API call
        _ = CGDisplayCreateImage(CGMainDisplayID())
    }

    @MainActor
    private func stopPermissionMonitoring() {
        Log.info("[OnboardingView] Permission monitoring stopped", category: .ui)
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        stopAutomationForcedSweepMonitoring()
        stopSystemSettingsReturnCheckTimer()
        for task in automationPermissionDecisionMonitorTasksByBundleID.values {
            task.cancel()
        }
        automationPermissionDecisionMonitorTasksByBundleID.removeAll()
    }

    @MainActor
    private func startAutomationWorkspaceObservation() {
        guard automationWorkspaceObserverTokens.isEmpty else {
            Log.debug("[OnboardingView] Workspace observation already active", category: .ui)
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter

        let launchToken = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = runningApp?.bundleIdentifier else { return }
            Task { @MainActor in
                await handleAutomationWorkspaceEvent(bundleID: bundleID, event: "launch")
            }
        }

        let terminateToken = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = runningApp?.bundleIdentifier else { return }
            Task { @MainActor in
                await handleAutomationWorkspaceEvent(bundleID: bundleID, event: "terminate")
            }
        }

        automationWorkspaceObserverTokens = [launchToken, terminateToken]
        Log.info("[OnboardingView] Workspace observation started (launch+terminate)", category: .ui)
    }

    @MainActor
    private func stopAutomationWorkspaceObservation() {
        guard !automationWorkspaceObserverTokens.isEmpty else {
            Log.debug("[OnboardingView] Workspace observation already stopped", category: .ui)
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        let tokenCount = automationWorkspaceObserverTokens.count
        for token in automationWorkspaceObserverTokens {
            notificationCenter.removeObserver(token)
        }
        automationWorkspaceObserverTokens.removeAll()
        Log.info("[OnboardingView] Workspace observation stopped (removed \(tokenCount) tokens)", category: .ui)
    }

    @MainActor
    private func handleAutomationWorkspaceEvent(bundleID: String, event: String) async {
        guard let relevanceReason = automationWorkspaceEventRelevanceReason(bundleID: bundleID) else {
            Log.debug(
                "[OnboardingView] Ignoring workspace event \(event) for non-automation bundle \(bundleID)",
                category: .ui
            )
            return
        }

        Log.info(
            "[OnboardingView] Automation workspace event \(event) for \(bundleID) (reason=\(relevanceReason)) - refreshing preflight list",
            category: .ui
        )
        await refreshAutomationPreflightList(reason: "workspace-\(event):\(bundleID)")
    }

    @MainActor
    private func automationWorkspaceEventRelevanceReason(bundleID: String) -> String? {
        if automationPreflightTargets.contains(where: { $0.bundleID == bundleID }) {
            return "direct-target"
        }

        if automationPreflightTargets.contains(where: {
            Self.automationPermissionRequiredBundleIDs(forTargetBundleID: $0.bundleID).contains(bundleID)
        }) {
            return "required-probe-target"
        }

        if Self.automationPreflightBaseTargets.contains(where: { $0.bundleID == bundleID }) {
            return "base-target"
        }

        if Self.automationChromiumHostBundleIDs.contains(bundleID) {
            return "chromium-host"
        }

        if Self.automationChromiumAppShimPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return "chromium-shim"
        }

        return nil
    }

    @MainActor
    private func refreshAutomationPreflightList(reason: String) async {
        guard !isRefreshingAutomationPreflightList else {
            Log.debug(
                "[OnboardingView] Skipping preflight refresh; already in progress (reason=\(reason))",
                category: .ui
            )
            return
        }
        let refreshStartedAt = Date()
        isRefreshingAutomationPreflightList = true
        defer {
            isRefreshingAutomationPreflightList = false
            let elapsedMS = Int(Date().timeIntervalSince(refreshStartedAt) * 1000)
            Log.info(
                "[OnboardingView] Automation preflight list refresh finished (reason=\(reason), elapsed=\(elapsedMS)ms, targets=\(automationPreflightTargets.count), running=\(automationPreflightRunningBundleIDs.count))",
                category: .ui
            )
        }

        Log.info("[OnboardingView] Automation preflight list refresh started (reason=\(reason))", category: .ui)
        await refreshAutomationPreflightTargets()
        Log.debug(
            "[OnboardingView] Refresh stage complete: targets loaded count=\(automationPreflightTargets.count) (reason=\(reason))",
            category: .ui
        )
        await refreshAutomationRunningBundleIDs()
        Log.debug(
            "[OnboardingView] Refresh stage complete: running bundle count=\(automationPreflightRunningBundleIDs.count) (reason=\(reason))",
            category: .ui
        )
        await refreshAutomationPreflightPermissionStateIfNeeded(force: true, reason: reason)
    }

    @MainActor
    private func refreshAutomationPreflightTargets() async {
        let previousTargetCount = automationPreflightTargets.count
        let previousStatusCount = automationPreflightStatusByBundleID.count
        await refreshUnsupportedAutomationTargets()
        let targets = await buildAutomationPreflightTargets()
        automationPreflightTargets = targets
        hasLoadedAutomationPreflightTargets = true

        let validBundleIDs = Set(targets.map(\.bundleID))
        let validProbeBundleIDs = Set(
            targets.flatMap { target in
                Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
            }
        )
        automationPreflightStatusByBundleID = automationPreflightStatusByBundleID.filter { validBundleIDs.contains($0.key) }
        automationPreflightRunningBundleIDs = Set(automationPreflightRunningBundleIDs.filter { validBundleIDs.contains($0) })
        automationPreflightBusyBundleIDs = Set(automationPreflightBusyBundleIDs.filter { validBundleIDs.contains($0) })
        automationPreflightUnknownProbeAttemptedBundleIDs = Set(
            automationPreflightUnknownProbeAttemptedBundleIDs.filter { validBundleIDs.contains($0) }
        )
        automationPermissionProbeCooldownUntilByBundleID = automationPermissionProbeCooldownUntilByBundleID.filter {
            validProbeBundleIDs.contains($0.key)
        }
        automationPermissionProbeTimeoutCountByBundleID = automationPermissionProbeTimeoutCountByBundleID.filter {
            validProbeBundleIDs.contains($0.key)
        }
        automationPreflightLaunchedByOnboardingBundleIDs = Set(
            automationPreflightLaunchedByOnboardingBundleIDs.filter { validBundleIDs.contains($0) }
        )
        automationPreflightIconByBundleID = loadAutomationPreflightIcons(for: targets)
        let persistedStatuses = loadPersistedAutomationPreflightStatuses()
        for target in targets {
            guard automationPreflightStatusByBundleID[target.bundleID] == nil,
                  let persistedStatus = persistedStatuses[target.bundleID] else {
                continue
            }
            automationPreflightStatusByBundleID[target.bundleID] = persistedStatus
        }
        persistAutomationPreflightStatuses()
        lastAutomationPreflightRecheckAt = Date.distantPast
        Log.info(
            "[OnboardingView] Preflight targets refreshed (previousTargets=\(previousTargetCount), newTargets=\(targets.count), previousStatuses=\(previousStatusCount), newStatuses=\(automationPreflightStatusByBundleID.count))",
            category: .ui
        )
    }

    @MainActor
    private func refreshAutomationRunningBundleIDs() async {
        let targetBundleIDs = Set(automationPreflightTargets.map(\.bundleID))
        guard !targetBundleIDs.isEmpty else {
            if !automationPreflightRunningBundleIDs.isEmpty {
                Log.info(
                    "[OnboardingView] Running automation bundles cleared because target list is empty",
                    category: .ui
                )
            }
            automationPreflightRunningBundleIDs = []
            return
        }

        let previousRunningBundleIDs = automationPreflightRunningBundleIDs
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                .filter { targetBundleIDs.contains($0) }
        )
        automationPreflightRunningBundleIDs = runningBundleIDs

        if previousRunningBundleIDs != runningBundleIDs {
            let added = runningBundleIDs.subtracting(previousRunningBundleIDs)
            let removed = previousRunningBundleIDs.subtracting(runningBundleIDs)
            let addedText = added.isEmpty ? "-" : added.sorted().joined(separator: ",")
            let removedText = removed.isEmpty ? "-" : removed.sorted().joined(separator: ",")
            Log.info(
                "[OnboardingView] Running automation bundles changed (count=\(runningBundleIDs.count), added=\(addedText), removed=\(removedText))",
                category: .ui
            )
        }
    }

    @MainActor
    private func startWaitingForSystemSettingsReturn() {
        waitingForSystemSettingsReturn = true
        observedSystemSettingsForeground = false
        startSystemSettingsReturnCheckTimer()
        Log.info("[OnboardingView] Waiting for return from System Settings", category: .ui)
    }

    @MainActor
    private func checkForSystemSettingsReturn() {
        guard waitingForSystemSettingsReturn else { return }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isSettingsFrontmost = frontmostBundleID.map { Self.systemSettingsBundleIDs.contains($0) } ?? false

        if isSettingsFrontmost {
            observedSystemSettingsForeground = true
            return
        }

        guard observedSystemSettingsForeground else { return }

        waitingForSystemSettingsReturn = false
        observedSystemSettingsForeground = false
        stopSystemSettingsReturnCheckTimer()
        bringOnboardingToFront(reason: "returned-from-system-settings")
        Task { @MainActor in
            await refreshAutomationPreflightList(reason: "system-settings-return")
        }
    }

    @MainActor
    private func startSystemSettingsReturnCheckTimer() {
        stopSystemSettingsReturnCheckTimer()
        systemSettingsReturnCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.systemSettingsReturnCheckIntervalSeconds,
            repeats: true
        ) { _ in
            Task { @MainActor in
                checkForSystemSettingsReturn()
            }
        }
    }

    @MainActor
    private func stopSystemSettingsReturnCheckTimer() {
        systemSettingsReturnCheckTimer?.invalidate()
        systemSettingsReturnCheckTimer = nil
    }

    @MainActor
    private func bringOnboardingToFront(reason: String) {
        NSApp.activate(ignoringOtherApps: true)

        if let frontWindow = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            frontWindow.makeKeyAndOrderFront(nil)
        } else {
            for window in NSApp.windows where window.isVisible {
                window.orderFrontRegardless()
            }
        }

        Log.info("[OnboardingView] Brought onboarding to front reason=\(reason)", category: .ui)
    }

    @MainActor
    private func bringOnboardingToFrontAfterLaunchWithRetries(reason: String) {
        bringOnboardingToFront(reason: reason)

        // Step-2-only launch retries to reclaim focus when the launched app steals it back.
        guard currentStep == 4 else { return }

        let retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(700),
            .milliseconds(1200),
        ]

        for (index, delay) in retryDelays.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: delay, clock: .continuous)
                guard currentStep == 4 else { return }
                bringOnboardingToFront(reason: "\(reason)-launch-retry-\(index + 1)")
            }
        }
    }

    @MainActor
    private func refreshAutomationPreflightPermissionStateIfNeeded(force: Bool = false, reason: String = "unspecified") async {
        guard hasLoadedAutomationPreflightTargets else {
            Log.debug(
                "[OnboardingView] Skip automation permission recheck: targets not loaded yet (reason=\(reason), force=\(force))",
                category: .ui
            )
            return
        }
        guard !isRecheckingAutomationPreflightPermissions else {
            Log.debug(
                "[OnboardingView] Skip automation permission recheck: already running (reason=\(reason), force=\(force))",
                category: .ui
            )
            return
        }

        let now = Date()
        if !force && now.timeIntervalSince(lastAutomationPreflightRecheckAt) < Self.automationPreflightRecheckIntervalSeconds {
            let elapsedMS = Int(now.timeIntervalSince(lastAutomationPreflightRecheckAt) * 1000)
            let throttleMS = Int(Self.automationPreflightRecheckIntervalSeconds * 1000)
            Log.debug(
                "[OnboardingView] Skip automation permission recheck: throttled (reason=\(reason), elapsed=\(elapsedMS)ms, throttle=\(throttleMS)ms)",
                category: .ui
            )
            return
        }
        lastAutomationPreflightRecheckAt = now

        let targetsToRecheck = automationPreflightTargets.filter { target in
            guard !automationPreflightBusyBundleIDs.contains(target.bundleID) else {
                return false
            }

            let status = automationPreflightStatusByBundleID[target.bundleID]
            guard status != .skipped else {
                return false
            }

            // Always recheck persisted granted/denied states, even if the target app is not running.
            // This keeps stale rows in sync after tccutil reset.
            if status == .granted || status == .denied {
                return true
            }

            // Still allow lightweight auto-detection for running apps with unknown state.
            return automationPreflightRunningBundleIDs.contains(target.bundleID)
        }
        guard !targetsToRecheck.isEmpty else {
            Log.debug(
                "[OnboardingView] Automation permission recheck found no eligible targets (reason=\(reason), totalTargets=\(automationPreflightTargets.count), running=\(automationPreflightRunningBundleIDs.count))",
                category: .ui
            )
            return
        }

        Log.info(
            "[OnboardingView] Automation permission recheck started (reason=\(reason), force=\(force), targetCount=\(targetsToRecheck.count))",
            category: .ui
        )
        Log.debug(
            "[OnboardingView] Recheck targets=\(targetsToRecheck.map(\.bundleID).joined(separator: ","))",
            category: .ui
        )

        isRecheckingAutomationPreflightPermissions = true
        defer {
            isRecheckingAutomationPreflightPermissions = false
            Log.info(
                "[OnboardingView] Automation permission recheck finished (reason=\(reason))",
                category: .ui
            )
        }

        var requiredBundleIDsInOrder: [String] = []
        var targetCountByRequiredBundleID: [String: Int] = [:]
        for target in targetsToRecheck {
            let requiredBundleIDs = Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
            for requiredBundleID in requiredBundleIDs {
                if targetCountByRequiredBundleID[requiredBundleID] == nil {
                    requiredBundleIDsInOrder.append(requiredBundleID)
                }
                targetCountByRequiredBundleID[requiredBundleID, default: 0] += 1
            }
        }

        Log.debug(
            "[OnboardingView] Required probe groups=\(requiredBundleIDsInOrder.map { "\($0):\(targetCountByRequiredBundleID[$0] ?? 0)" }.joined(separator: ","))",
            category: .ui
        )

        var probeResultByRequiredBundleID: [String: AutomationPermissionProbeResult] = [:]
        for requiredBundleID in requiredBundleIDsInOrder {
            let now = Date()
            if !force, let cooldownUntil = automationPermissionProbeCooldownUntilByBundleID[requiredBundleID], cooldownUntil > now {
                let remainingMS = Int(cooldownUntil.timeIntervalSince(now) * 1000)
                Log.debug(
                    "[OnboardingView] Skipping probe bundle \(requiredBundleID) due to timeout cooldown remaining=\(remainingMS)ms",
                    category: .ui
                )
                continue
            }

            Log.debug(
                "[OnboardingView] Probing automation bundle \(requiredBundleID) for \(targetCountByRequiredBundleID[requiredBundleID] ?? 0) target(s)",
                category: .ui
            )
            let probeResult = await automationPermissionProbeResult(
                for: requiredBundleID,
                askUserIfNeeded: false
            )
            probeResultByRequiredBundleID[requiredBundleID] = probeResult
        }

        if probeResultByRequiredBundleID.isEmpty {
            Log.debug(
                "[OnboardingView] Automation permission recheck skipped all probes due to cooldown (reason=\(reason))",
                category: .ui
            )
            return
        }

        var timeoutHandledRequiredBundleIDs: Set<String> = []
        let clearStaleStatusesOnForce = force

        for target in targetsToRecheck {
            let previousStatus = automationPreflightStatusByBundleID[target.bundleID]
            let requiredBundleIDs = Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
            let requiredLabel = requiredBundleIDs.joined(separator: "+")

            var requiredResults: [(bundleID: String, result: AutomationPermissionProbeResult)] = []
            var missingRequiredBundleIDs: [String] = []
            for requiredBundleID in requiredBundleIDs {
                guard let probeResult = probeResultByRequiredBundleID[requiredBundleID] else {
                    missingRequiredBundleIDs.append(requiredBundleID)
                    continue
                }
                requiredResults.append((bundleID: requiredBundleID, result: probeResult))
            }

            if !missingRequiredBundleIDs.isEmpty {
                Log.debug(
                    "[OnboardingView] Rechecking automation permission target=\(target.bundleID), required=\(requiredLabel), skipping due to missing probe result(s)=\(missingRequiredBundleIDs.joined(separator: ","))",
                    category: .ui
                )
                continue
            }

            Log.debug(
                "[OnboardingView] Rechecking automation permission target=\(target.bundleID), required=\(requiredLabel), previousStatus=\(String(describing: previousStatus))",
                category: .ui
            )

            let timeoutBundleIDs = requiredResults.compactMap { entry -> String? in
                if case .unavailable(let statusCode) = entry.result,
                   statusCode == Self.automationPermissionProbeTimeoutStatus {
                    return entry.bundleID
                }
                return nil
            }
            if !timeoutBundleIDs.isEmpty {
                for requiredBundleID in timeoutBundleIDs {
                    let cooldownUntil = Date().addingTimeInterval(Self.automationPermissionProbeRetryCooldownSeconds)
                    automationPermissionProbeCooldownUntilByBundleID[requiredBundleID] = cooldownUntil
                    let timeoutCount = (automationPermissionProbeTimeoutCountByBundleID[requiredBundleID] ?? 0) + 1
                    automationPermissionProbeTimeoutCountByBundleID[requiredBundleID] = timeoutCount

                    if !timeoutHandledRequiredBundleIDs.contains(requiredBundleID) {
                        timeoutHandledRequiredBundleIDs.insert(requiredBundleID)
                        let cooldownMS = Int(Self.automationPermissionProbeRetryCooldownSeconds * 1000)
                        Log.warning(
                            "[OnboardingView] Automation preflight silent-check timed out for required bundle=\(requiredBundleID); timeoutCount=\(timeoutCount), force=\(force), setting cooldown=\(cooldownMS)ms and continuing recheck pass",
                            category: .ui
                        )
                    }
                }

                if clearStaleStatusesOnForce,
                   (previousStatus == .granted || previousStatus == .denied) {
                    automationPreflightStatusByBundleID.removeValue(forKey: target.bundleID)
                    persistAutomationPreflightStatuses()
                    Log.warning(
                        "[OnboardingView] Cleared cached automation status for \(target.bundleID) because required probe(s) \(timeoutBundleIDs.joined(separator: ",")) timed out during forced refresh",
                        category: .ui
                    )
                }
                continue
            }

            let deniedBundleIDs = requiredResults.compactMap { entry -> String? in
                if case .denied = entry.result {
                    return entry.bundleID
                }
                return nil
            }
            if !deniedBundleIDs.isEmpty {
                for requiredBundleID in requiredBundleIDs {
                    automationPermissionProbeCooldownUntilByBundleID.removeValue(forKey: requiredBundleID)
                    automationPermissionProbeTimeoutCountByBundleID.removeValue(forKey: requiredBundleID)
                }
                if previousStatus != .denied {
                    automationPreflightStatusByBundleID[target.bundleID] = .denied
                    persistAutomationPreflightStatuses()
                    Log.warning(
                        "[OnboardingView] Automation preflight silent-check denied for \(target.bundleID) (required=\(requiredLabel), denied=\(deniedBundleIDs.joined(separator: ","))); status -> denied",
                        category: .ui
                    )
                }
                continue
            }

            let requiresConsentBundleIDs = requiredResults.compactMap { entry -> String? in
                if case .requiresUserConsent = entry.result {
                    return entry.bundleID
                }
                return nil
            }
            if !requiresConsentBundleIDs.isEmpty {
                for requiredBundleID in requiredBundleIDs {
                    automationPermissionProbeCooldownUntilByBundleID.removeValue(forKey: requiredBundleID)
                    automationPermissionProbeTimeoutCountByBundleID.removeValue(forKey: requiredBundleID)
                }
                // No prompt on background checks. Keep this app in "Ready to allow" state.
                if previousStatus != nil && previousStatus != .skipped {
                    automationPreflightStatusByBundleID.removeValue(forKey: target.bundleID)
                    persistAutomationPreflightStatuses()
                    Log.info(
                        "[OnboardingView] Automation preflight silent-check requires consent for \(target.bundleID) (required=\(requiredLabel), pending=\(requiresConsentBundleIDs.joined(separator: ","))); status -> ready-to-allow",
                        category: .ui
                    )
                }
                continue
            }

            let procNotFoundBundleIDs = requiredResults.compactMap { entry -> String? in
                if case .unavailable(let statusCode) = entry.result,
                   statusCode == Self.automationPermissionTargetNotRunningStatus {
                    return entry.bundleID
                }
                return nil
            }
            if !procNotFoundBundleIDs.isEmpty {
                for requiredBundleID in procNotFoundBundleIDs {
                    automationPermissionProbeCooldownUntilByBundleID.removeValue(forKey: requiredBundleID)
                    automationPermissionProbeTimeoutCountByBundleID.removeValue(forKey: requiredBundleID)
                }
                Log.info(
                    "[OnboardingView] Automation preflight silent-check unavailable for \(target.bundleID) (required=\(requiredLabel)); preserving previous status=\(String(describing: previousStatus)), notRunning=\(procNotFoundBundleIDs.joined(separator: ","))",
                    category: .ui
                )
                continue
            }

            if let unavailableEntry = requiredResults.first(where: { entry in
                if case .unavailable(let statusCode) = entry.result {
                    return statusCode != Self.automationPermissionProbeTimeoutStatus &&
                        statusCode != Self.automationPermissionTargetNotRunningStatus
                }
                return false
            }),
               case .unavailable(let statusCode) = unavailableEntry.result {
                automationPermissionProbeCooldownUntilByBundleID.removeValue(forKey: unavailableEntry.bundleID)
                automationPermissionProbeTimeoutCountByBundleID.removeValue(forKey: unavailableEntry.bundleID)
                if previousStatus == .granted {
                    automationPreflightStatusByBundleID.removeValue(forKey: target.bundleID)
                    persistAutomationPreflightStatuses()
                    Log.info(
                        "[OnboardingView] Automation preflight silent-check unavailable for \(target.bundleID) (required=\(requiredLabel)); cleared stale granted status to ready-to-allow, unavailableBundle=\(unavailableEntry.bundleID), osstatus=\(statusCode)",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "[OnboardingView] Automation preflight silent-check unavailable for \(target.bundleID) (required=\(requiredLabel)); unavailableBundle=\(unavailableEntry.bundleID), osstatus=\(statusCode)",
                        category: .ui
                    )
                }
                continue
            }

            for requiredBundleID in requiredBundleIDs {
                automationPermissionProbeCooldownUntilByBundleID.removeValue(forKey: requiredBundleID)
                automationPermissionProbeTimeoutCountByBundleID.removeValue(forKey: requiredBundleID)
            }
            if previousStatus != .granted {
                automationPreflightStatusByBundleID[target.bundleID] = .granted
                persistAutomationPreflightStatuses()
                Log.info(
                    "[OnboardingView] Automation preflight silent-check granted for \(target.bundleID) (required=\(requiredLabel)); status -> granted",
                    category: .ui
                )
            }
        }
    }

    private func automationPermissionProbeResult(
        for bundleID: String,
        askUserIfNeeded: Bool
    ) async -> AutomationPermissionProbeResult {
        let status = await automationPermissionStatusAsync(
            for: bundleID,
            askUserIfNeeded: askUserIfNeeded
        )
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .requiresUserConsent
        default:
            return .unavailable(status)
        }
    }

    private func automationPermissionProbeResult(
        for target: AutomationPreflightTarget,
        askUserIfNeeded: Bool
    ) async -> AutomationPermissionProbeResult {
        let requiredBundleIDs = Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
        var requiredResults: [(bundleID: String, result: AutomationPermissionProbeResult)] = []
        for requiredBundleID in requiredBundleIDs {
            let result = await automationPermissionProbeResult(
                for: requiredBundleID,
                askUserIfNeeded: askUserIfNeeded
            )
            requiredResults.append((bundleID: requiredBundleID, result: result))
        }

        let aggregateResult = aggregateAutomationPermissionProbeResult(
            requiredResults
        )
        if requiredBundleIDs.count > 1 {
            Log.debug(
                "[OnboardingView] Aggregated automation probe target=\(target.bundleID), required=\(requiredBundleIDs.joined(separator: "+")), askUserIfNeeded=\(askUserIfNeeded), result=\(aggregateResult)",
                category: .ui
            )
        }
        return aggregateResult
    }

    private func aggregateAutomationPermissionProbeResult(
        _ requiredResults: [(bundleID: String, result: AutomationPermissionProbeResult)]
    ) -> AutomationPermissionProbeResult {
        guard !requiredResults.isEmpty else {
            return .unavailable(Self.automationPermissionTargetNotRunningStatus)
        }

        if requiredResults.contains(where: { entry in
            if case .unavailable(let statusCode) = entry.result {
                return statusCode == Self.automationPermissionProbeTimeoutStatus
            }
            return false
        }) {
            return .unavailable(Self.automationPermissionProbeTimeoutStatus)
        }

        if requiredResults.contains(where: { entry in
            if case .denied = entry.result { return true }
            return false
        }) {
            return .denied
        }

        if requiredResults.contains(where: { entry in
            if case .requiresUserConsent = entry.result { return true }
            return false
        }) {
            return .requiresUserConsent
        }

        if requiredResults.contains(where: { entry in
            if case .unavailable(let statusCode) = entry.result {
                return statusCode == Self.automationPermissionTargetNotRunningStatus
            }
            return false
        }) {
            return .unavailable(Self.automationPermissionTargetNotRunningStatus)
        }

        if let unavailableEntry = requiredResults.first(where: { entry in
            if case .unavailable = entry.result { return true }
            return false
        }),
           case .unavailable(let statusCode) = unavailableEntry.result {
            return .unavailable(statusCode)
        }

        return .granted
    }

    private func automationPermissionStatusAsync(
        for bundleID: String,
        askUserIfNeeded: Bool
    ) async -> OSStatus {
        let timeoutSeconds = askUserIfNeeded
            ? Self.automationPreflightUserAllowTimeoutSeconds
            : Self.automationPreflightBackgroundTimeoutSeconds
        let probeStartedAt = Date()

        Log.debug(
            "[OnboardingView] Automation permission probe scheduled bundle=\(bundleID), askUserIfNeeded=\(askUserIfNeeded), timeoutSeconds=\(timeoutSeconds)",
            category: .ui
        )

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            @discardableResult
            func finish(_ status: OSStatus, source: String) -> Bool {
                lock.lock()
                guard !hasResumed else {
                    lock.unlock()
                    return false
                }
                hasResumed = true
                lock.unlock()

                let elapsedMS = Int(Date().timeIntervalSince(probeStartedAt) * 1000)
                Log.debug(
                    "[OnboardingView] Automation permission probe completed bundle=\(bundleID), askUserIfNeeded=\(askUserIfNeeded), source=\(source), status=\(status), elapsed=\(elapsedMS)ms",
                    category: .ui
                )
                continuation.resume(returning: status)
                return true
            }

            Self.automationPermissionProbeQueue.async {
                let status = Self.automationPermissionStatus(for: bundleID, askUserIfNeeded: askUserIfNeeded)
                _ = finish(status, source: "probe")
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                let didTimeOut = finish(Self.automationPermissionProbeTimeoutStatus, source: "timeout")
                if didTimeOut {
                    Log.warning(
                        "[OnboardingView] Automation permission probe timeout bundle=\(bundleID), askUserIfNeeded=\(askUserIfNeeded), timeoutSeconds=\(timeoutSeconds)",
                        category: .ui
                    )
                }
            }
        }
    }

    nonisolated private static func automationPermissionStatus(
        for bundleID: String,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        var targetDesc = AEDesc()
        let bundleIDCString = bundleID.utf8CString
        let createStatus = bundleIDCString.withUnsafeBufferPointer { bufferPointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bufferPointer.baseAddress,
                max(0, bufferPointer.count - 1),
                &targetDesc
            )
        }

        guard createStatus == noErr else {
            return OSStatus(createStatus)
        }
        defer { AEDisposeDesc(&targetDesc) }

        return AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    private func automationStatus(for target: AutomationPreflightTarget) -> AutomationPreflightStatus? {
        automationPreflightStatusByBundleID[target.bundleID]
    }

    @MainActor
    private func loadAutomationPreflightIcons(for targets: [AutomationPreflightTarget]) -> [String: NSImage] {
        var iconsByBundleID: [String: NSImage] = [:]

        for target in targets {
            let appURL = target.appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID)
            if let appURL {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 20, height: 20)
                iconsByBundleID[target.bundleID] = icon
            }
        }

        return iconsByBundleID
    }

    private func automationStatusDescription(for target: AutomationPreflightTarget) -> String {
        if let status = automationStatus(for: target) {
            switch status {
            case .granted:
                return automationPreflightRunningBundleIDs.contains(target.bundleID)
                    ? "Enabled"
                    : "Enabled (last check)"
            case .skipped:
                return "Skipped"
            case .denied:
                return "You Denied Permissions"
            case .timedOut:
                return "Allow timed out"
            case .failed:
                return "Allow failed"
            }
        }

        if automationPreflightRunningBundleIDs.contains(target.bundleID) {
            return "Ready to allow"
        }

        return "Not running"
    }

    private func automationStatusColor(for target: AutomationPreflightTarget) -> Color {
        if let status = automationStatus(for: target) {
            switch status {
            case .granted:
                return .retraceSuccess
            case .skipped:
                return .retraceSecondary
            case .denied, .timedOut, .failed:
                return .retraceWarning
            }
        }

        return .retraceSecondary
    }

    private func skipAutomationTarget(_ target: AutomationPreflightTarget) {
        automationPreflightStatusByBundleID[target.bundleID] = .skipped
        persistAutomationPreflightStatuses()
        Log.info("[OnboardingView] App URL preflight \(target.bundleID) -> skipped", category: .ui)
    }

    private func unskipAutomationTarget(_ target: AutomationPreflightTarget) {
        guard automationPreflightStatusByBundleID[target.bundleID] == .skipped else {
            return
        }
        automationPreflightStatusByBundleID.removeValue(forKey: target.bundleID)
        persistAutomationPreflightStatuses()
        Log.info("[OnboardingView] App URL preflight \(target.bundleID) -> unskipped", category: .ui)
    }

    @MainActor
    private func bulkSkipAllAutomationTargets() {
        guard !isBulkAllowingAutomationTargets && !isBulkSkippingAutomationTargets else {
            return
        }

        let targets = actionableAutomationPreflightTargets
        guard !targets.isEmpty else { return }

        isBulkSkippingAutomationTargets = true
        defer {
            isBulkSkippingAutomationTargets = false
        }

        for target in targets {
            skipAutomationTarget(target)
        }
    }

    @MainActor
    private func bulkUnskipAllAutomationTargets() {
        guard !isBulkAllowingAutomationTargets && !isBulkSkippingAutomationTargets else {
            return
        }

        let targets = skippedAutomationPreflightTargets
        guard !targets.isEmpty else { return }

        for target in targets {
            unskipAutomationTarget(target)
        }
    }

    @MainActor
    private func presentBulkAllowAllConfirmation() {
        guard !isBulkAllowingAutomationTargets && !isBulkSkippingAutomationTargets else {
            return
        }

        let targets = actionableAutomationPreflightTargets
        guard !targets.isEmpty else { return }

        bulkAllowAllLaunchPreviewNames = bulkAllowAllLaunchPreviewNames(for: targets)
        showBulkAllowAllConfirmation = true
    }

    @MainActor
    private func bulkAllowAllLaunchPreviewNames(for targets: [AutomationPreflightTarget]) -> [String] {
        let directLaunchTargets = targets.filter { !automationPreflightRunningBundleIDs.contains($0.bundleID) }
        guard !directLaunchTargets.isEmpty else { return [] }

        var orderedNames: [String] = []
        var seenNames: Set<String> = []

        func appendNameIfNeeded(_ name: String) {
            guard !seenNames.contains(name) else { return }
            seenNames.insert(name)
            orderedNames.append(name)
        }

        for target in directLaunchTargets {
            appendNameIfNeeded(target.displayName)

            // Chromium app shims can trigger host browser launch as a side effect.
            guard let hostBundleID = Self.hostBrowserBundleID(forChromiumAppShim: target.bundleID),
                  !automationPreflightRunningBundleIDs.contains(hostBundleID) else {
                continue
            }

            if let hostTarget = automationPreflightTargets.first(where: { $0.bundleID == hostBundleID }) {
                appendNameIfNeeded(hostTarget.displayName)
            } else {
                appendNameIfNeeded(hostBundleID)
            }
        }

        return orderedNames
    }

    @MainActor
    private func bulkAllowAllAutomationTargetsConfirmed() async {
        guard !isBulkAllowingAutomationTargets && !isBulkSkippingAutomationTargets else {
            return
        }

        let initialTargets = actionableAutomationPreflightTargets
        guard !initialTargets.isEmpty else { return }

        isBulkAllowingAutomationTargets = true
        defer {
            isBulkAllowingAutomationTargets = false
            bulkAllowAllLaunchPreviewNames = []
        }

        let targetsToLaunch = initialTargets.filter { target in
            !automationPreflightRunningBundleIDs.contains(target.bundleID)
        }

        for target in targetsToLaunch {
            await launchAutomationTarget(target)
        }

        await refreshAutomationRunningBundleIDs()

        let targetsToAllow = actionableAutomationPreflightTargets
        for target in targetsToAllow {
            await enableAutomationPermission(for: target)
        }

        bringOnboardingToFront(reason: "bulk-allow-all-finished")
    }

    @MainActor
    private func launchAutomationTarget(_ target: AutomationPreflightTarget) async {
        guard !automationPreflightBusyBundleIDs.contains(target.bundleID) else { return }
        automationPreflightBusyBundleIDs.insert(target.bundleID)
        defer {
            automationPreflightBusyBundleIDs.remove(target.bundleID)
        }

        guard let appURL = target.appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            Log.warning("[OnboardingView] No app URL found for \(target.bundleID)", category: .ui)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            Log.info("[OnboardingView] Launched app URL target \(target.bundleID)", category: .ui)
            automationPreflightLaunchedByOnboardingBundleIDs.insert(target.bundleID)
            bringOnboardingToFrontAfterLaunchWithRetries(reason: "app-launched-\(target.bundleID)")
        } catch {
            Log.warning("[OnboardingView] Failed to launch app URL target \(target.bundleID): \(error)", category: .ui)
        }

        await refreshAutomationRunningBundleIDs()
    }

    @MainActor
    private func closeLaunchedAutomationApps() async {
        guard !isClosingLaunchedAutomationApps else { return }
        isClosingLaunchedAutomationApps = true
        defer {
            isClosingLaunchedAutomationApps = false
        }

        let bundleIDsToClose = automationPreflightLaunchedByOnboardingBundleIDs
            .intersection(automationPreflightRunningBundleIDs)
        guard !bundleIDsToClose.isEmpty else {
            return
        }

        let appsToClose = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleIDsToClose.contains(bundleID)
        }

        for app in appsToClose {
            guard let bundleID = app.bundleIdentifier else { continue }
            _ = app.terminate()
            Log.info("[OnboardingView] Requested close for onboarding-launched app \(bundleID)", category: .ui)
        }

        // Give the system a brief moment to process terminations before re-reading running apps.
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        await refreshAutomationRunningBundleIDs()

        automationPreflightLaunchedByOnboardingBundleIDs = automationPreflightLaunchedByOnboardingBundleIDs
            .intersection(automationPreflightRunningBundleIDs)
    }

    @MainActor
    private func enableAutomationPermission(for target: AutomationPreflightTarget) async {
        guard automationPreflightRunningBundleIDs.contains(target.bundleID) else {
            Log.info("[OnboardingView] Skipping enable for non-running target \(target.bundleID)", category: .ui)
            return
        }

        let requiredBundleIDs = Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
        for requiredBundleID in requiredBundleIDs where requiredBundleID != target.bundleID {
            guard !automationPreflightRunningBundleIDs.contains(requiredBundleID) else { continue }
            if let requiredTarget = automationPreflightTargets.first(where: { $0.bundleID == requiredBundleID }) {
                Log.info(
                    "[OnboardingView] Launching required host target \(requiredBundleID) before allow flow for \(target.bundleID)",
                    category: .ui
                )
                await launchAutomationTarget(requiredTarget)
            } else if let requiredTarget = await installedAutomationTarget(
                bundleID: requiredBundleID,
                fallbackDisplayName: requiredBundleID
            ) {
                Log.info(
                    "[OnboardingView] Launching discovered required host target \(requiredBundleID) before allow flow for \(target.bundleID)",
                    category: .ui
                )
                await launchAutomationTarget(requiredTarget)
            } else {
                Log.warning(
                    "[OnboardingView] Missing required host target \(requiredBundleID) for allow flow \(target.bundleID)",
                    category: .ui
                )
            }
            await refreshAutomationRunningBundleIDs()
        }

        guard !automationPreflightBusyBundleIDs.contains(target.bundleID) else { return }

        automationPreflightBusyBundleIDs.insert(target.bundleID)
        defer {
            automationPreflightBusyBundleIDs.remove(target.bundleID)
        }

        let previousStatus = automationPreflightStatusByBundleID[target.bundleID]
        Log.info(
            "[OnboardingView] Starting app URL allow attempt bundle=\(target.bundleID), previousStatus=\(String(describing: previousStatus))",
            category: .ui
        )
        let status = await requestAutomationPermission(for: target, userInitiated: true)
        automationPreflightStatusByBundleID[target.bundleID] = status
        persistAutomationPreflightStatuses()
        if status == .granted {
            bringOnboardingToFront(reason: "automation-granted-\(target.bundleID)")
        } else if status == .denied {
            bringOnboardingToFront(reason: "automation-denied-\(target.bundleID)")
        } else if status == .timedOut || status == .failed {
            // Some AppleEvents flows report "failed"/timeout before the user finishes the prompt.
            // Keep polling silently so we can refocus onboarding right after the Allow/Deny decision.
            startAutomationPermissionDecisionMonitor(for: target)
        }
        Log.info(
            "[OnboardingView] Completed app URL allow attempt bundle=\(target.bundleID), previousStatus=\(String(describing: previousStatus)), newStatus=\(status)",
            category: .ui
        )
    }

    @MainActor
    private func startAutomationPermissionDecisionMonitor(for target: AutomationPreflightTarget) {
        guard currentStep == 4 else { return }
        guard automationPermissionDecisionMonitorTasksByBundleID[target.bundleID] == nil else { return }

        let bundleID = target.bundleID
        let task = Task { @MainActor in
            defer {
                automationPermissionDecisionMonitorTasksByBundleID.removeValue(forKey: bundleID)
            }

            Log.info("[OnboardingView] Started automation decision monitor for \(bundleID)", category: .ui)
            let timeoutDate = Date().addingTimeInterval(Self.automationPreflightUserAllowTimeoutSeconds)

            while !Task.isCancelled && Date() < timeoutDate && currentStep == 4 {
                try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
                guard !Task.isCancelled else { return }

                let result = await automationPermissionProbeResult(
                    for: target,
                    askUserIfNeeded: false
                )

                switch result {
                case .granted:
                    automationPreflightStatusByBundleID[bundleID] = .granted
                    persistAutomationPreflightStatuses()
                    bringOnboardingToFront(reason: "automation-granted-after-dialog-\(bundleID)")
                    Log.info("[OnboardingView] Automation decision resolved granted for \(bundleID)", category: .ui)
                    return
                case .denied:
                    automationPreflightStatusByBundleID[bundleID] = .denied
                    persistAutomationPreflightStatuses()
                    bringOnboardingToFront(reason: "automation-denied-after-dialog-\(bundleID)")
                    Log.info("[OnboardingView] Automation decision resolved denied for \(bundleID)", category: .ui)
                    return
                case .requiresUserConsent:
                    continue
                case .unavailable(let statusCode):
                    // App closed; stop waiting and leave row in retry state.
                    if statusCode == Self.automationPermissionTargetNotRunningStatus {
                        let existingStatus = automationPreflightStatusByBundleID[bundleID]
                        if existingStatus != .granted && existingStatus != .denied && existingStatus != .skipped {
                            automationPreflightStatusByBundleID.removeValue(forKey: bundleID)
                            persistAutomationPreflightStatuses()
                        }
                        Log.info(
                            "[OnboardingView] Automation decision monitor stopped for \(bundleID): target not running, preservedStatus=\(String(describing: existingStatus))",
                            category: .ui
                        )
                        return
                    }
                    continue
                }
            }

            Log.info("[OnboardingView] Automation decision monitor timed out for \(bundleID)", category: .ui)
        }

        automationPermissionDecisionMonitorTasksByBundleID[bundleID] = task
    }

    @MainActor
    private func loadPersistedAutomationPreflightStatuses() -> [String: AutomationPreflightStatus] {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard let rawStatuses = defaults.dictionary(forKey: Self.automationPreflightStatusesKey) as? [String: String] else {
            return [:]
        }

        var statuses: [String: AutomationPreflightStatus] = [:]
        for (bundleID, rawStatus) in rawStatuses {
            guard let status = AutomationPreflightStatus(rawValue: rawStatus) else {
                continue
            }
            statuses[bundleID] = status
        }
        return statuses
    }

    @MainActor
    private func persistAutomationPreflightStatuses() {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let persistableStatuses: [String: String] = automationPreflightStatusByBundleID.compactMapValues { status in
            switch status {
            case .granted, .skipped, .denied:
                return status.rawValue
            case .timedOut, .failed:
                return nil
            }
        }
        defaults.set(persistableStatuses, forKey: Self.automationPreflightStatusesKey)
    }

    private func buildAutomationPreflightTargets() async -> [AutomationPreflightTarget] {
        let runningApps = await MainActor.run {
            NSWorkspace.shared.runningApplications
        }

        var targetsByBundleID: [String: AutomationPreflightTarget] = [:]
        for target in Self.automationPreflightBaseTargets {
            if let installedTarget = await installedAutomationTarget(
                bundleID: target.bundleID,
                fallbackDisplayName: target.displayName
            ) {
                targetsByBundleID[installedTarget.bundleID] = installedTarget
            }
        }

        // Include all installed Chromium web apps from known app folders.
        for target in discoverInstalledWebAppAutomationTargets() {
            targetsByBundleID[target.bundleID] = target

            if let hostBundleID = Self.hostBrowserBundleID(forChromiumAppShim: target.bundleID),
               let hostTarget = await installedAutomationTarget(
                bundleID: hostBundleID,
                fallbackDisplayName: hostBundleID
               ) {
                targetsByBundleID[hostTarget.bundleID] = hostTarget
            }
        }

        // Also include currently running Chromium web-app shims (covers non-standard install paths).
        for runningApp in runningApps {
            guard let bundleID = runningApp.bundleIdentifier else { continue }

            let isChromiumAppShim = Self.automationChromiumAppShimPrefixes.contains {
                bundleID.hasPrefix($0)
            }
            guard isChromiumAppShim else { continue }

            let displayName = runningApp.localizedName ?? bundleID
            targetsByBundleID[bundleID] = AutomationPreflightTarget(
                bundleID: bundleID,
                displayName: displayName,
                appURL: runningApp.bundleURL
            )

            if let hostBundleID = Self.hostBrowserBundleID(forChromiumAppShim: bundleID),
               let hostTarget = await installedAutomationTarget(
                bundleID: hostBundleID,
                fallbackDisplayName: hostBundleID
               ) {
                targetsByBundleID[hostTarget.bundleID] = hostTarget
            }
        }

        return targetsByBundleID.values.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
    }

    private func requestAutomationPermission(
        for target: AutomationPreflightTarget,
        userInitiated: Bool
    ) async -> AutomationPreflightStatus {
        let requiredBundleIDs = Self.automationPermissionRequiredBundleIDs(forTargetBundleID: target.bundleID)
        let result = await automationPermissionProbeResult(
            for: target,
            askUserIfNeeded: userInitiated
        )

        switch result {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .requiresUserConsent:
            // User dismissed prompt or no decision yet.
            return userInitiated ? .timedOut : .failed
        case .unavailable(let statusCode):
            Log.warning(
                "[OnboardingView] Automation probe unavailable for \(target.bundleID) (required=\(requiredBundleIDs.joined(separator: "+"))); osstatus=\(statusCode), mode=\(userInitiated ? "user" : "background")",
                category: .ui
            )
            return .failed
        }
    }

    private func automationPreflightProbe(for target: AutomationPreflightTarget) -> (source: String, label: String) {
        let bundleID = target.bundleID

        if bundleID == "com.apple.finder" {
            return (
                """
                tell application id "com.apple.finder"
                    if (count of Finder windows) > 0 then
                        try
                            set u to URL of target of front Finder window
                            if u is not missing value and u is not "" then return u
                        end try
                    end if
                    return URL of desktop
                end tell
                """,
                "finder-target-url-probe"
            )
        }

        if bundleID == "company.thebrowser.Browser" {
            return (
                """
                tell application "Arc"
                    if (count of windows) > 0 then
                        try
                            set u to URL of active tab of front window
                            if u is not missing value and u is not "" then return u
                        end try
                    end if
                    return ""
                end tell
                """,
                "arc-url-probe"
            )
        }

        if let hostBundleID = Self.hostBrowserBundleID(forChromiumAppShim: bundleID) {
            let escapedDisplayName = appleScriptEscaped(target.displayName)
            return (
                """
                set shimTitle to ""
                set shimResolved to false
                try
                    tell application id "\(bundleID)"
                        if (count of windows) > 0 then
                            set shimTitle to name of front window
                        end if
                    end tell
                    set shimResolved to true
                end try

                if shimResolved is false then
                    try
                        tell application "\(escapedDisplayName)"
                            if (count of windows) > 0 then
                                set shimTitle to name of front window
                            end if
                        end tell
                        set shimResolved to true
                    end try
                end if

                if shimResolved is false then return ""

                if shimTitle is missing value then set shimTitle to ""

                tell application id "\(hostBundleID)"
                    if (count of windows) = 0 then return ""

                    repeat with w in windows
                        set tabTitle to ""
                        set tabURL to ""
                        try
                            set tabTitle to title of active tab of w
                            set tabURL to URL of active tab of w
                        end try

                        if tabURL is not "" and shimTitle is not "" and tabTitle is not "" then
                            if shimTitle contains tabTitle or tabTitle contains shimTitle then
                                return tabURL
                            end if
                        end if
                    end repeat
                end tell

                return ""
                """,
                "app-shim-host-browser-probe[\(hostBundleID)]"
            )
        }

        if Self.automationChromiumHostBundleIDs.contains(bundleID) {
            return (
                """
                tell application id "\(bundleID)"
                    if (count of windows) > 0 then
                        try
                            set u to URL of active tab of front window
                            if u is not missing value and u is not "" then return u
                        end try
                    end if
                    return ""
                end tell
                """,
                "chromium-host-url-probe"
            )
        }

        return (
            """
            tell application id "\(bundleID)"
                return count of windows
            end tell
            """,
            "generic-window-count-probe"
        )
    }

    private func installedAutomationTarget(
        bundleID: String,
        fallbackDisplayName: String
    ) async -> AutomationPreflightTarget? {
        await MainActor.run {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }

            let displayName: String
            if let bundle = Bundle(url: appURL) {
                displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent
            } else {
                displayName = fallbackDisplayName
            }

            return AutomationPreflightTarget(bundleID: bundleID, displayName: displayName, appURL: appURL)
        }
    }

    private static func hostBrowserBundleID(forChromiumAppShim bundleID: String) -> String? {
        for prefix in automationChromiumAppShimPrefixes where bundleID.hasPrefix(prefix) {
            guard prefix.hasSuffix(".app.") else { continue }
            return String(prefix.dropLast(5))
        }
        return nil
    }

    private static func automationPermissionRequiredBundleIDs(forTargetBundleID targetBundleID: String) -> [String] {
        if let hostBundleID = hostBrowserBundleID(forChromiumAppShim: targetBundleID),
           hostBundleID != targetBundleID {
            return [targetBundleID, hostBundleID]
        }
        return [targetBundleID]
    }

    private func discoverInstalledWebAppAutomationTargets() -> [AutomationPreflightTarget] {
        let fileManager = FileManager.default
        let appFolders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized"),
        ]

        var targetsByBundleID: [String: AutomationPreflightTarget] = [:]

        for folder in appFolders {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for appURL in contents where appURL.pathExtension == "app" {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty else {
                    continue
                }

                let isChromiumAppShim = Self.automationChromiumAppShimPrefixes.contains {
                    bundleID.hasPrefix($0)
                }
                guard isChromiumAppShim else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent

                targetsByBundleID[bundleID] = AutomationPreflightTarget(
                    bundleID: bundleID,
                    displayName: displayName,
                    appURL: appURL
                )
            }
        }

        return targetsByBundleID.values.sorted(by: {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        })
    }

    private func runAutomationAppleScript(
        for bundleID: String,
        source: String,
        scriptLabel: String,
        timeoutSeconds: TimeInterval,
        mode: String
    ) async -> AutomationPreflightStatus {
        let startTime = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        Log.info(
            "[OnboardingView] AppleScript preflight start bundle=\(bundleID), script=\(scriptLabel), mode=\(mode), timeoutSeconds=\(timeoutSeconds)",
            category: .ui
        )

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            Log.warning("[OnboardingView] Failed to launch AppleScript preflight for \(bundleID): \(error)", category: .ui)
            return .failed
        }

        let timedOut = await waitForProcessExitOrTimeout(
            process,
            timeoutSeconds: timeoutSeconds
        )
        if timedOut {
            process.terminate()
            await waitForProcessExit(process)
            let elapsedMs = Date().timeIntervalSince(startTime) * 1000
            Log.warning(
                "[OnboardingView] AppleScript preflight timed out bundle=\(bundleID), script=\(scriptLabel), mode=\(mode), elapsedMs=\(String(format: "%.1f", elapsedMs))",
                category: .ui
            )
            return .timedOut
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let elapsedMs = Date().timeIntervalSince(startTime) * 1000
        let failureCode = parseAutomationFailureCode(from: stderr)

        guard process.terminationStatus == 0 else {
            let failureCodeString = failureCode.map(String.init) ?? "none"
            let safeStdErr = stderr.isEmpty ? "<empty>" : stderr
            Log.warning(
                "[OnboardingView] AppleScript preflight failed bundle=\(bundleID), script=\(scriptLabel), mode=\(mode), exitCode=\(process.terminationStatus), failureCode=\(failureCodeString), elapsedMs=\(String(format: "%.1f", elapsedMs)), stderr=\(safeStdErr)",
                category: .ui
            )

            let isDenied =
                failureCode == -1743 ||
                stderr.contains("-1743") ||
                stderr.localizedCaseInsensitiveContains("not authorized") ||
                stderr.localizedCaseInsensitiveContains("Not authorized to send Apple events")
            if isDenied {
                Log.warning("[OnboardingView] AppleScript automation denied for \(bundleID)", category: .ui)
                return .denied
            }
            return .failed
        }

        let safeStdout = stdout.isEmpty ? "<empty>" : stdout
        Log.info(
            "[OnboardingView] AppleScript preflight success bundle=\(bundleID), script=\(scriptLabel), mode=\(mode), elapsedMs=\(String(format: "%.1f", elapsedMs)), stdout=\(safeStdout)",
            category: .ui
        )
        return .granted
    }

    private func parseAutomationFailureCode(from stderr: String) -> Int? {
        guard let range = stderr.range(of: "(-\\d+)\\)", options: .regularExpression) else {
            return nil
        }

        let matched = String(stderr[range])
        return Int(matched.dropFirst().dropLast())
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func waitForProcessExit(_ process: Process) async {
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(15), clock: .continuous)
        }
    }

    private func waitForProcessExitOrTimeout(_ process: Process, timeoutSeconds: TimeInterval) async -> Bool {
        let timeoutDate = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < timeoutDate {
            try? await Task.sleep(for: .milliseconds(15), clock: .continuous)
        }
        return process.isRunning
    }

    // MARK: - Rewind Data Detection

    private func detectRewindData() async {
        // Check for Rewind memoryVault folder
        let memoryVaultPath = AppPaths.expandedRewindStorageRoot
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: memoryVaultPath) {
            // Found Rewind data
            hasRewindData = true
            // Calculate folder size
            rewindDataSizeGB = calculateFolderSizeGB(atPath: memoryVaultPath)
        } else {
            // No Rewind data found - skip the step entirely
            hasRewindData = false
        }
    }

    private func calculateFolderSizeGB(atPath path: String) -> Double {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return 0
        }

        while let file = enumerator.nextObject() as? String {
            let filePath = (path as NSString).appendingPathComponent(file)
            if let attributes = try? fileManager.attributesOfItem(atPath: filePath),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        // Convert bytes to GB
        return Double(totalSize) / (1024 * 1024 * 1024)
    }
}

// MARK: - ScreenCaptureKit Import

import ScreenCaptureKit

// MARK: - Shortcut Capture Field

// MARK: - Shortcut Key Model

struct ShortcutKey: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    /// Create from ShortcutConfig (source of truth)
    init(from config: ShortcutConfig) {
        self.key = config.key
        self.modifiers = config.modifiers.nsModifiers
    }

    /// Create directly with key and modifiers
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts.joined(separator: " ")
    }

    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// Convert to ShortcutConfig for storage
    var toConfig: ShortcutConfig {
        ShortcutConfig(key: key, modifiers: ShortcutModifiers(from: modifiers))
    }

    static func == (lhs: ShortcutKey, rhs: ShortcutKey) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }
}

struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var capturedShortcut: ShortcutKey
    let otherShortcut: ShortcutKey
    let onDuplicateAttempt: () -> Void
    let onShortcutCaptured: ((ShortcutKey) -> Void)?

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.isRecordingEnabled = isRecording
        if isRecording {
            // Become first responder to capture key events
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator {
        var parent: ShortcutCaptureField

        init(_ parent: ShortcutCaptureField) {
            self.parent = parent
        }

        func handleKeyPress(event: NSEvent) {
            guard parent.isRecording else { return }

            let keyName = mapKeyCodeToString(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Escape key cancels recording
            if event.keyCode == 53 { // Escape
                parent.isRecording = false
                return
            }

            // Require at least one modifier key
            if modifiers.isEmpty {
                // Ignore shortcuts without modifiers
                return
            }

            let newShortcut = ShortcutKey(key: keyName, modifiers: modifiers)

            // Check for duplicate (same key AND same modifiers)
            if newShortcut == parent.otherShortcut {
                parent.onDuplicateAttempt()
                parent.isRecording = false
                return
            }

            parent.capturedShortcut = newShortcut
            parent.isRecording = false
            // Call the callback to save immediately
            parent.onShortcutCaptured?(newShortcut)
        }

        private func mapKeyCodeToString(keyCode: UInt16, characters: String?) -> String {
            switch keyCode {
            case 49: return "Space"
            case 36: return "Return"
            case 53: return "Escape"
            case 51: return "Delete"
            case 48: return "Tab"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            // Number keys (top row)
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 23: return "5"
            case 22: return "6"
            case 26: return "7"
            case 28: return "8"
            case 25: return "9"
            case 29: return "0"
            default:
                // Use charactersIgnoringModifiers to get the actual key pressed
                if let chars = characters, !chars.isEmpty {
                    return chars.uppercased()
                }
                return "Key\(keyCode)"
            }
        }
    }
}

class ShortcutCaptureNSView: NSView {
    weak var coordinator: ShortcutCaptureField.Coordinator?
    var isRecordingEnabled = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isRecordingEnabled {
            coordinator?.handleKeyPress(event: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Int Clamped Extension

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(coordinator: AppCoordinator()) {
            Log.info("[OnboardingView] Onboarding complete", category: .ui)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
