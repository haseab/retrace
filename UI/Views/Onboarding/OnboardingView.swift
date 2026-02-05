import SwiftUI
import AppKit
import App
import Database
import Shared
import ServiceManagement

/// Softer button color that blends with the dark blue onboarding background
/// A muted blue that's visible but not as sharp as the primary accent
private let onboardingButtonColor = Color(red: 35/255, green: 75/255, blue: 145/255)

/// Main onboarding flow with 9 steps
/// Step 1: Welcome
/// Step 2: Creator features
/// Step 3: Permissions (starts recording on continue)
/// Step 4: Menu Bar Icon info
/// Step 5: Launch at Login option
/// Step 6: Rewind data decision
/// Step 7: Keyboard shortcuts
/// Step 8: Early Alpha / Safety info
/// Step 9: Completion (prompts to test timeline)
public struct OnboardingView: View {

    // MARK: - Properties

    // UserDefaults keys
    private static let onboardingStepKey = "onboardingCurrentStep"
    private static let timelineShortcutKey = "timelineShortcutConfig"
    private static let dashboardShortcutKey = "dashboardShortcutConfig"

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

    @State private var currentStep: Int = UserDefaults.standard.integer(forKey: OnboardingView.onboardingStepKey).clamped(to: 1...9) == 0 ? 1 : UserDefaults.standard.integer(forKey: OnboardingView.onboardingStepKey).clamped(to: 1...9)
    @State private var hasScreenRecordingPermission = false
    @State private var hasAccessibilityPermission = false
    @State private var isCheckingPermissions = false
    @State private var permissionCheckTimer: Timer? = nil
    @State private var screenRecordingDenied = false  // User explicitly denied in system prompt
    @State private var screenRecordingRequested = false  // User has clicked Enable once
    @State private var accessibilityRequested = false  // User has clicked Enable Accessibility once
    @State private var hasTriggeredCaptureDialog = false  // macOS 15+ "Allow to record" dialog triggered

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

    private let totalSteps = 9

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

                // Fixed navigation buttons at bottom
                navigationButtonsFixed
                    .padding(.horizontal, .spacingXL)
                    .padding(.bottom, .spacingL)
                    .frame(maxWidth: 900)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .task {
            // Only auto-detect Rewind data on first load
            // Don't check permissions until user reaches permissions step
            await detectRewindData()
            // Pre-fetch creator image so it's ready when user reaches step 4
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
                        // Skip Rewind data step (6) when going back if no Rewind data exists
                        if currentStep == 7 && hasRewindData != true {
                            currentStep = 5
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
            // Permissions - requires both permissions, then shows menu bar icon step
            Button(action: {
                stopPermissionMonitoring()
                // Start recording pipeline here
                Task {
                    try? await coordinator.startPipeline()
                }
                // Now that permissions are granted, setup global hotkeys
                // This was deferred during MenuBarManager.setup() to avoid triggering AXIsProcessTrusted() too early
                MenuBarManager.shared?.reloadShortcuts()
                withAnimation { currentStep = 4 }  // Go to menu bar icon step
            }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(hasScreenRecordingPermission && hasAccessibilityPermission ? onboardingButtonColor : Color.retraceSecondaryColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)
            .disabled(!hasScreenRecordingPermission || !hasAccessibilityPermission)

        case 4:
            // Menu bar icon info
            Button(action: { withAnimation { currentStep = 5 } }) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(onboardingButtonColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)

        case 5:
            // Launch at login - save setting and continue
            // Skip Rewind data step (6) if no Rewind data exists
            Button(action: {
                setLaunchAtLogin(enabled: launchAtLogin)
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                defaults.set(launchAtLogin, forKey: "launchAtLogin")
                withAnimation { currentStep = hasRewindData == true ? 6 : 7 }
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

        case 6:
            // Rewind data - requires selection if data exists
            Button(action: {
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                defaults.set(wantsRewindData == true, forKey: "useRewindData")
                withAnimation { currentStep = 7 }
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

        case 7:
            // Keyboard shortcuts
            Button(action: {
                Task {
                    // Save shortcuts to UserDefaults (full config with key + modifiers)
                    await coordinator.onboardingManager.setTimelineShortcut(timelineShortcut.toConfig)
                    await coordinator.onboardingManager.setDashboardShortcut(dashboardShortcut.toConfig)
                }
                withAnimation { currentStep = 8 }
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

        case 8:
            // Safety info
            Button(action: { withAnimation { currentStep = 9 } }) {
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
            // Completion - Just finish onboarding (recording already started at step 3)
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
            permissionsStep
        case 4:
            menuBarIconStep
        case 5:
            launchAtLoginStep
        // case 6: - COMMENTED OUT - Screen Recording Indicator step not needed for now
        //     screenRecordingIndicatorStep
        // case 7: - COMMENTED OUT - Encryption step removed (no reliable encrypt/decrypt migration)
        //     encryptionStep
        case 6:
            rewindDataStep
        case 7:
            keyboardShortcutsStep
        case 8:
            safetyInfoStep
        case 9:
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
            Button(action: { withAnimation { currentStep = 2 } }) {
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

    // MARK: - Step 4: Permissions

    private var permissionsStep: some View {
        VStack(spacing: .spacingXL) {
            Text("Permission Required")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Retrace needs the following permissions to capture and analyze your screen.")
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
                    Text("Both permissions are required to continue")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceWarning)
                }
            }

            Text("You may need to restart the app if the checkmark doesn't show.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            Spacer()
        }
        .task {
            // Only start checking permissions when user reaches this step
            // This prevents triggering the permission prompt on app launch
            await checkPermissions()
        }
        .onAppear {
            // Start continuous permission monitoring when on permissions step
            startPermissionMonitoring()
        }
        .onDisappear {
            // Stop monitoring when leaving this step
            stopPermissionMonitoring()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        isDenied: Bool = false,
        action: @escaping () -> Void,
        openSettingsAction: (() -> Void)? = nil
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

    // MARK: - Step 5: Screen Recording Indicator

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
            .frame(maxWidth: 500)

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

    // MARK: - Step 5: Launch at Login

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
            // Profile picture centered - preloaded on app launch
            AsyncImage(url: URL(string: "https://cdn.buymeacoffee.com/uploads/profile_pictures/2025/12/TCyQoMlyZfvvIelF.jpg@300w_0e.webp")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    creatorPlaceholder
                case .empty:
                    creatorPlaceholder
                @unknown default:
                    creatorPlaceholder
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())

            Text("Hey, thanks for trying Retrace!")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)
                .multilineTextAlignment(.center)
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
        // Prefetch the image into URLCache
        guard let url = URL(string: "https://cdn.buymeacoffee.com/uploads/profile_pictures/2025/12/TCyQoMlyZfvvIelF.jpg@300w_0e.webp") else { return }
        do {
            let (_, _) = try await URLSession.shared.data(from: url)
        } catch {
            // Ignore errors, the AsyncImage will handle fallback
        }
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
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
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

                Text("v0.5 - February 2026")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            // Creator section
            VStack(spacing: .spacingM) {
                // Profile picture
                AsyncImage(url: URL(string: "https://cdn.buymeacoffee.com/uploads/profile_pictures/2025/12/TCyQoMlyZfvvIelF.jpg@300w_0e.webp")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        creatorPlaceholder
                    case .empty:
                        SpinnerView(size: 20, lineWidth: 2)
                            .frame(width: 70, height: 70)
                    @unknown default:
                        creatorPlaceholder
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.retraceAccent.opacity(0.3), lineWidth: 2)
                )

                Text("Thanks for being an early user!")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)
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

        // Only check accessibility if user has already requested it
        // This prevents AXIsProcessTrustedWithOptions from triggering an early system prompt
        if accessibilityRequested {
            hasAccessibilityPermission = checkAccessibilityPermission()
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
        NSWorkspace.shared.open(url)
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)

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

    private func startPermissionMonitoring() {
        // Start timer to continuously check permissions every 2 seconds
        // Note: Initial check is done in .task block, not here
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                // Check screen recording
                hasScreenRecordingPermission = await checkScreenRecordingPermission()

                // Only check accessibility AFTER user has clicked Enable
                // This prevents AXIsProcessTrustedWithOptions from triggering an early system prompt
                if accessibilityRequested {
                    let previousAccessibility = hasAccessibilityPermission
                    hasAccessibilityPermission = checkAccessibilityPermission()

                    // If accessibility was just granted, retry setting up global hotkeys
                    if !previousAccessibility && hasAccessibilityPermission {
                        HotkeyManager.shared.retrySetupIfNeeded()
                    }
                }

                // On macOS 15+, when both permissions are granted, trigger the capture dialog
                // This shows "Allow [App] to record screen & audio" dialog while still on permissions step
                if hasScreenRecordingPermission && hasAccessibilityPermission && !hasTriggeredCaptureDialog {
                    triggerMacOS15CaptureDialog()
                }
            }
        }
    }

    /// Triggers a single screen capture to prompt the macOS 15+ "Allow to record screen & audio" dialog.
    /// This ensures the dialog appears on the permissions step rather than after moving to the next step.
    private func triggerMacOS15CaptureDialog() {
        hasTriggeredCaptureDialog = true

        // A single CGDisplayCreateImage call is enough to trigger the system dialog on macOS 15+
        // We don't need to use the result - we just need to make the API call
        _ = CGDisplayCreateImage(CGMainDisplayID())
    }

    private func stopPermissionMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
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
