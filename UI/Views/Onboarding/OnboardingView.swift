import SwiftUI
import App
import Inject

/// Main onboarding flow with 9 steps
/// Step 1: Welcome
/// Step 2: Permissions
/// Step 3: Encryption choice
/// Step 4: Creator message with features
/// Step 5: Rewind data decision
/// Step 6: Keyboard shortcuts
/// Step 7: Safety info
/// Step 8: Quiz
/// Step 9: Completion
public struct OnboardingView: View {

    // MARK: - Properties

    @ObserveInjection var inject
    @State private var currentStep: Int = 1
    @State private var hasScreenRecordingPermission = false
    @State private var hasAccessibilityPermission = false
    @State private var isCheckingPermissions = false
    @State private var permissionCheckTimer: Timer? = nil

    // Rewind data flow state
    @State private var hasRewindData: Bool? = nil
    @State private var wantsBackup: Bool? = nil
    @State private var showRewindMigration = false
    @State private var showRewindBackup = false

    // Keyboard shortcuts (matching Rewind defaults)
    @State private var timelineShortcut = "Space"
    @State private var dashboardShortcut = "D"
    @State private var isRecordingTimelineShortcut = false
    @State private var isRecordingDashboardShortcut = false

    // Quiz
    @State private var selectedQuizAnswer: Int? = nil
    @State private var quizAnswered = false

    // Encryption
    @State private var encryptionEnabled = false

    let coordinator: AppCoordinator
    let onComplete: () -> Void

    private let totalSteps = 9

    // MARK: - Body

    public var body: some View {
        let _ = print("🔥 [Hot Reload] OnboardingView.body called at \(Date())")

        ZStack {
            // Background
            Color.retraceBackground
                .ignoresSafeArea()
                .enableInjection()

            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                    .padding(.top, .spacingL)

                // Content
                ScrollView {
                    VStack(spacing: .spacingXL) {
                        stepContent
                    }
                    .padding(.horizontal, .spacingXL)
                    .padding(.vertical, .spacingL)
                }
                .frame(maxWidth: 900)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .task {
            // Only auto-detect Rewind data on first load
            // Don't check permissions until user reaches permissions step
            await detectRewindData()
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
            permissionsStep
        case 3:
            encryptionStep
        case 4:
            creatorMessageStep
        case 5:
            rewindDataStep
        case 6:
            keyboardShortcutsStep
        case 7:
            safetyInfoStep
        case 8:
            quizStep
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
                .frame(height: .spacingXXL)

            // Logo
            retraceLogo
                .frame(width: 120, height: 120)

            Text("Welcome to Retrace")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.retracePrimary)

            Text("Your personal screen memory")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: .spacingXXL)

            Button(action: { withAnimation { currentStep = 2 } }) {
                Text("Get Started")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .frame(width: 200)
                    .padding(.vertical, .spacingM)
                    .background(Color.retraceAccent)
                    .cornerRadius(.cornerRadiusL)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Step 2: Permissions

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
                    action: requestScreenRecording
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

            navigationButtons(
                canContinue: hasScreenRecordingPermission && hasAccessibilityPermission,
                continueAction: {
                    // Stop permission monitoring
                    stopPermissionMonitoring()

                    // Don't start pipeline here - it triggers the permission dialog
                    // Pipeline will be started at the end of onboarding
                    withAnimation { currentStep = 3 }
                }
            )
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
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: .spacingM) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(isGranted ? .retraceSuccess : .retraceAccent)
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
                    .font(.system(size: 24))
                    .foregroundColor(.retraceSuccess)
            } else {
                Button(action: action) {
                    Text("Enable")
                        .font(.retraceBody)
                        .foregroundColor(.white)
                        .padding(.horizontal, .spacingM)
                        .padding(.vertical, .spacingS)
                        .background(Color.retraceAccent)
                        .cornerRadius(.cornerRadiusM)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.spacingM)
    }

    // MARK: - Step 3: Encryption

    private var encryptionStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()
                .frame(height: .spacingL)

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

                Image(systemName: encryptionEnabled ? "lock.shield.fill" : "lock.open.fill")
                    .font(.system(size: 44))
                    .foregroundColor(encryptionEnabled ? .retraceSuccess : .retraceSecondary)
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
                    Text("Rewind Also Encrypts the Database")
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

            // Toggle button
            Button(action: {
                withAnimation {
                    encryptionEnabled.toggle()
                }
            }) {
                HStack(spacing: .spacingM) {
                    Image(systemName: encryptionEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 24))
                        .foregroundColor(encryptionEnabled ? .retraceAccent : .retraceSecondary)

                    Text("Enable database encryption")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                }
                .padding(.spacingM)
                .frame(maxWidth: .infinity)
                .background(Color.retraceSecondaryBackground)
                .cornerRadius(.cornerRadiusM)
                .overlay(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .stroke(encryptionEnabled ? Color.retraceAccent : Color.retraceBorder, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)

            Text("You can change this later in Settings.")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)

            Spacer()

            navigationButtons(canContinue: true) {
                // Save encryption preference to UserDefaults
                UserDefaults.standard.set(encryptionEnabled, forKey: "encryptionEnabled")
                withAnimation { currentStep = 4 }
            }
        }
    }

    // MARK: - Step 4: Creator Message

    private var creatorMessageStep: some View {
        VStack(spacing: .spacingL) {
            // Profile header outside card
            HStack(spacing: .spacingL) {
                // Profile picture from GitHub
                AsyncImage(url: URL(string: "https://avatars.githubusercontent.com/u/59128529?v=4")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.retraceAccent.opacity(0.3))
                        .overlay(
                            Text("H")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: .spacingS) {
                    Text("A Message From The Creators")
                        .font(.retraceTitle)
                        .foregroundColor(.retracePrimary)

                    Text("Hey! This is a VERY EARLY alpha of Retrace. Things will break, but I'm tirelessly working towards 1:1 feature parity with Rewind (and way better).")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                }
            }
            .padding(.bottom, .spacingS)

            // Two-column feature layout
            HStack(alignment: .top, spacing: .spacingXL) {
                // Left column: What this version has (green)
                VStack(alignment: .leading, spacing: .spacingM) {
                    Text("What This Version Has")
                        .font(.retraceHeadline)
                        .foregroundColor(.retraceSuccess)

                    VStack(alignment: .leading, spacing: .spacingS) {
                        featureItem(icon: "checkmark.circle.fill", text: "Easy Connection to Old Rewind Data", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Decrypt and Backup your Rewind Database", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Timeline Scrolling", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Continuous Screen Capture", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Basic Search", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Keyboard Shortcuts", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Deletion of Data", color: .retraceSuccess)
                        featureItem(icon: "checkmark.circle.fill", text: "Exclude Apps / Private Windows", color: .retraceSuccess)
                    }
                }
                .padding(.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.retraceSuccess.opacity(0.05))
                .cornerRadius(.cornerRadiusL)

                // Right column: Coming soon (yellow) and Not planned (red)
                VStack(alignment: .leading, spacing: .spacingL) {
                    // Coming soon
                    VStack(alignment: .leading, spacing: .spacingM) {
                        Text("Coming Jan 1")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceWarning)

                        VStack(alignment: .leading, spacing: .spacingS) {
                            featureItem(icon: "circle.fill", text: "Optimized Power & Storage", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "More Settings", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "Daily Dashboard", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "Audio Recording", color: .retraceWarning)
                            featureItem(icon: "circle.fill", text: "Search Highlighting", color: .retraceWarning)
                        }
                    }
                    .padding(.spacingM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceWarning.opacity(0.05))
                    .cornerRadius(.cornerRadiusM)

                    // Not planned yet
                    VStack(alignment: .leading, spacing: .spacingM) {
                        Text("Not Yet Planned")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceDanger)

                        VStack(alignment: .leading, spacing: .spacingS) {
                            featureItem(icon: "xmark.circle.fill", text: "Ask Retrace Chatbot", color: .retraceDanger)
                            featureItem(icon: "xmark.circle.fill", text: "Vector Search", color: .retraceDanger)
                        }
                    }
                    .padding(.spacingM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceDanger.opacity(0.05))
                    .cornerRadius(.cornerRadiusM)
                }
                .padding(.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear)
                .cornerRadius(.cornerRadiusL)
            }

            // Footer
            VStack(alignment: .leading, spacing: .spacingS) {
                HStack {
                    Text("Built in 4 days. Questions?")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)

                    Link("retrace.to/chat", destination: URL(string: "https://retrace.to/chat")!)
                        .font(.retraceBody)
                        .foregroundColor(.retraceAccent)
                }

                HStack(spacing: .spacingS) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.retraceSuccess)
                    Text("All data is local. Nothing leaves your machine.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            }
            .padding(.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusM)

            navigationButtons(canContinue: true) {
                withAnimation { currentStep = 5 }
            }
        }
    }

    private func featureItem(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: .spacingS) {
            Image(systemName: icon)
                .font(.system(size: 12))
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
                        .font(.system(size: 12))
                        .foregroundColor(color)
                    Text(text)
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                }
            }
        }
    }

    // MARK: - Step 4: Rewind Data

    private var rewindDataStep: some View {
        VStack(spacing: .spacingL) {
            Text("Rewind Data")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            if hasRewindData == true && wantsBackup == nil {
                // Rewind data detected - ask if they want to include it on Timeline
                VStack(spacing: .spacingL) {
                    HStack(spacing: .spacingM) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.retraceSuccess)
                        Text("Rewind data detected on this machine!")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceSuccess)
                    }

                    Text("Do you want Retrace to include your Rewind data on the Timeline?")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: .spacingL) {
                        Button(action: {
                            withAnimation {
                                wantsBackup = true
                                showRewindMigration = true
                            }
                        }) {
                            Text("Yes, Import")
                                .font(.retraceHeadline)
                                .foregroundColor(.white)
                                .frame(width: 140)
                                .padding(.vertical, .spacingM)
                                .background(Color.retraceAccent)
                                .cornerRadius(.cornerRadiusM)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation {
                                wantsBackup = false
                                currentStep = 6
                            }
                        }) {
                            Text("No, Skip")
                                .font(.retraceHeadline)
                                .foregroundColor(.retracePrimary)
                                .frame(width: 140)
                                .padding(.vertical, .spacingM)
                                .background(Color.retraceSecondaryBackground)
                                .cornerRadius(.cornerRadiusM)
                                .overlay(
                                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                                        .stroke(Color.retraceBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.spacingXL)
                .background(Color.retraceSecondaryBackground)
                .cornerRadius(.cornerRadiusL)

            } else if hasRewindData == false {
                // No Rewind data found
                VStack(spacing: .spacingL) {
                    HStack(spacing: .spacingM) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.retraceSecondary)
                        Text("No Rewind data found")
                            .font(.retraceHeadline)
                            .foregroundColor(.retraceSecondary)
                    }

                    Text("If you have Rewind data you'd like to import later, you can do so from Settings.")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.spacingXL)
                .background(Color.retraceSecondaryBackground)
                .cornerRadius(.cornerRadiusL)

            } else if showRewindMigration {
                rewindMigrationPlaceholder
            } else if showRewindBackup {
                rewindBackupPlaceholder
            }

            Spacer()

            // Navigation buttons
            HStack {
                Button(action: {
                    withAnimation {
                        // Reset state and go back
                        wantsBackup = nil
                        showRewindBackup = false
                        showRewindMigration = false
                        currentStep = 4
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

                Spacer()

                // Continue button for no-rewind-data case
                if hasRewindData == false {
                    Button(action: { withAnimation { currentStep = 6 } }) {
                        Text("Continue")
                            .font(.retraceHeadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, .spacingL)
                            .padding(.vertical, .spacingM)
                            .background(Color.retraceAccent)
                            .cornerRadius(.cornerRadiusM)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rewindBackupPlaceholder: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.retraceAccent)

            Text("Rewind Decrypt & Backup Center")
                .font(.retraceTitle2)
                .foregroundColor(.retracePrimary)

            Text("This feature is coming soon. You'll be able to decrypt and backup your Rewind database here.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: .spacingM) {
                if hasRewindData == true {
                    Button(action: {
                        withAnimation {
                            showRewindBackup = false
                            showRewindMigration = true
                        }
                    }) {
                        Text("Continue to Migration")
                            .font(.retraceBody)
                            .foregroundColor(.white)
                            .padding(.horizontal, .spacingL)
                            .padding(.vertical, .spacingM)
                            .background(Color.retraceAccent)
                            .cornerRadius(.cornerRadiusM)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { withAnimation { currentStep = 6 } }) {
                    Text("Continue Without Backup")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)
                        .padding(.horizontal, .spacingL)
                        .padding(.vertical, .spacingM)
                        .background(Color.retraceSecondaryBackground)
                        .cornerRadius(.cornerRadiusM)
                        .overlay(
                            RoundedRectangle(cornerRadius: .cornerRadiusM)
                                .stroke(Color.retraceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.spacingXL)
        .background(Color.retraceSecondaryBackground)
        .cornerRadius(.cornerRadiusL)
    }

    private var rewindMigrationPlaceholder: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.retraceAccent)

            Text("Rewind Migration")
                .font(.retraceTitle2)
                .foregroundColor(.retracePrimary)

            Text("This feature is coming soon. You'll be able to import your Rewind data here.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)

            Button(action: { withAnimation { currentStep = 6 } }) {
                Text("Continue")
                    .font(.retraceBody)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(Color.retraceAccent)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)
        }
        .padding(.spacingXL)
        .background(Color.retraceSecondaryBackground)
        .cornerRadius(.cornerRadiusL)
    }

    // MARK: - Step 5: Keyboard Shortcuts

    @State private var shortcutError: String? = nil

    private var keyboardShortcutsStep: some View {
        VStack(spacing: .spacingL) {
            Text("Customize Keyboard Shortcuts")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            Text("Click on a shortcut to record a new key.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)

            VStack(spacing: .spacingL) {
                shortcutRecorderRow(
                    label: "Launch Timeline",
                    shortcut: $timelineShortcut,
                    isRecording: $isRecordingTimelineShortcut,
                    otherShortcut: dashboardShortcut
                )

                Divider()
                    .background(Color.retraceBorder)

                shortcutRecorderRow(
                    label: "Launch Dashboard",
                    shortcut: $dashboardShortcut,
                    isRecording: $isRecordingDashboardShortcut,
                    otherShortcut: timelineShortcut
                )
            }
            .padding(.spacingXL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

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

            navigationButtons(canContinue: true) {
                withAnimation { currentStep = 7 }
            }
        }
    }

    private func shortcutRecorderRow(
        label: String,
        shortcut: Binding<String>,
        isRecording: Binding<Bool>,
        otherShortcut: String
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
                // Then start this one
                isRecording.wrappedValue = true
            }) {
                HStack(spacing: .spacingM) {
                    // Modifier keys
                    Text("⌘")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.retraceCard)
                        .cornerRadius(.cornerRadiusS)

                    Text("⇧")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.retraceCard)
                        .cornerRadius(.cornerRadiusS)

                    Text("+")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)

                    // Key
                    Text(shortcut.wrappedValue)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(isRecording.wrappedValue ? .retraceAccent : .retracePrimary)
                        .frame(minWidth: 50, minHeight: 32)
                        .padding(.horizontal, .spacingM)
                        .background(isRecording.wrappedValue ? Color.retraceAccent.opacity(0.2) : Color.retraceCard)
                        .cornerRadius(.cornerRadiusS)
                        .overlay(
                            RoundedRectangle(cornerRadius: .cornerRadiusS)
                                .stroke(isRecording.wrappedValue ? Color.retraceAccent : Color.clear, lineWidth: 2)
                        )
                }
            }
            .buttonStyle(.plain)
            .background(
                // Key capture happens in a focused view
                ShortcutCaptureField(
                    isRecording: isRecording,
                    capturedKey: shortcut,
                    otherShortcut: otherShortcut,
                    onDuplicateAttempt: {
                        shortcutError = "This shortcut is already in use"
                    }
                )
                .frame(width: 0, height: 0)
            )

            if isRecording.wrappedValue {
                Text("Press a key...")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceAccent)
            }
        }
    }

    // MARK: - Step 6: Safety Info

    private var safetyInfoStep: some View {
        VStack(spacing: .spacingL) {
            Text("Early Alpha Notice")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            VStack(alignment: .leading, spacing: .spacingM) {
                Text("This is an early alpha. If something breaks:")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                VStack(alignment: .leading, spacing: .spacingS) {
                    safetyItem(icon: "pause.circle.fill", text: "You can pause capture")
                    safetyItem(icon: "trash.circle.fill", text: "You can delete all data")
                    safetyItem(icon: "xmark.circle.fill", text: "You can uninstall cleanly")
                }

                Divider()
                    .background(Color.retraceBorder)

                VStack(alignment: .leading, spacing: .spacingS) {
                    Text("Need Support?")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Text("If you want support, I encourage you to send the logfile that is on your machine. I'll ask for it and will be able to see what went wrong!")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)

                    Text("I've tried to deanonymize it as much as I could.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    HStack(spacing: .spacingS) {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.retraceAccent)
                        Link("retrace.to/chat", destination: URL(string: "https://retrace.to/chat")!)
                            .font(.retraceBody)
                            .foregroundColor(.retraceAccent)
                    }
                }
            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            Spacer()

            navigationButtons(canContinue: true) {
                withAnimation { currentStep = 8 }
            }
        }
    }

    private func safetyItem(icon: String, text: String) -> some View {
        HStack(spacing: .spacingM) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.retraceAccent)
            Text(text)
                .font(.retraceBody)
                .foregroundColor(.retracePrimary)
        }
    }

    // MARK: - Step 7: Quiz

    private var quizStep: some View {
        VStack(spacing: .spacingL) {
            Text("Almost There!")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            VStack(alignment: .leading, spacing: .spacingM) {
                Text("Let's test if you remember what I said...")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)

                Text("Which of the features did we say we DON'T have?")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("Hint: You can launch the timeline to see what it was!")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                VStack(spacing: .spacingS) {
                    quizOption(index: 0, text: "Timeline Scrolling")
                    quizOption(index: 1, text: "Audio Recording")
                    quizOption(index: 2, text: "Basic Search")
                    quizOption(index: 3, text: "Delete Data")
                }
            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            if quizAnswered {
                if selectedQuizAnswer == 1 {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.retraceSuccess)
                        Text("Correct! Audio recording is coming in January.")
                            .font(.retraceBody)
                            .foregroundColor(.retraceSuccess)
                    }
                } else {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.retraceDanger)
                        Text("Not quite. Audio recording is what we don't have yet!")
                            .font(.retraceBody)
                            .foregroundColor(.retraceDanger)
                    }
                }
            }

            Spacer()

            HStack {
                Button(action: { withAnimation { currentStep = 7 } }) {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                // Skip option
                Button(action: { withAnimation { currentStep = 9 } }) {
                    Text("Skip")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)

                if quizAnswered {
                    Button(action: { withAnimation { currentStep = 9 } }) {
                        Text("Continue")
                            .font(.retraceHeadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, .spacingL)
                            .padding(.vertical, .spacingM)
                            .background(Color.retraceAccent)
                            .cornerRadius(.cornerRadiusM)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func quizOption(index: Int, text: String) -> some View {
        Button(action: {
            selectedQuizAnswer = index
            quizAnswered = true
        }) {
            HStack {
                Circle()
                    .stroke(selectedQuizAnswer == index ? Color.retraceAccent : Color.retraceBorder, lineWidth: 2)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .fill(selectedQuizAnswer == index ? Color.retraceAccent : Color.clear)
                            .frame(width: 12, height: 12)
                    )

                Text(text)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)

                Spacer()
            }
            .padding(.spacingM)
            .background(selectedQuizAnswer == index ? Color.retraceAccent.opacity(0.1) : Color.clear)
            .cornerRadius(.cornerRadiusM)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 9: Completion

    private var completionStep: some View {
        VStack(spacing: .spacingXL) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.retraceSuccess)

            Text("You're All Set!")
                .font(.retraceTitle)
                .foregroundColor(.retracePrimary)

            VStack(spacing: .spacingM) {
                Text("Launch Retrace Dashboard through:")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)

                VStack(alignment: .leading, spacing: .spacingS) {
                    HStack(spacing: .spacingM) {
                        Image(systemName: "command")
                        Text("Keyboard shortcut: ⌘⇧\(dashboardShortcut)")
                            .font(.retraceMono)
                    }
                    .foregroundColor(.retracePrimary)

                    HStack(spacing: .spacingM) {
                        Image(systemName: "menubar.rectangle")
                        Text("Click the menu bar icon")
                    }
                    .foregroundColor(.retracePrimary)
                }
            }
            .padding(.spacingL)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)

            Spacer()

            Button(action: {
                Task {
                    await coordinator.onboardingManager.markOnboardingCompleted()
                    // Start the capture pipeline after onboarding is complete
                    try? await coordinator.startPipeline()
                }
                onComplete()
            }) {
                Text("Start Using Retrace")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .frame(width: 200)
                    .padding(.vertical, .spacingM)
                    .background(Color.retraceAccent)
                    .cornerRadius(.cornerRadiusL)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Helper Views

    private var retraceLogo: some View {
        // Recreate the SVG logo in SwiftUI
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

    private func navigationButtons(canContinue: Bool, continueAction: @escaping () -> Void) -> some View {
        HStack {
            if currentStep > 1 {
                Button(action: { withAnimation { currentStep -= 1 } }) {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button(action: continueAction) {
                Text("Continue")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, .spacingL)
                    .padding(.vertical, .spacingM)
                    .background(canContinue ? Color.retraceAccent : Color.retraceSecondaryColor)
                    .cornerRadius(.cornerRadiusM)
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
        }
    }

    // MARK: - Permission Handling

    private func checkPermissions() async {
        // Check screen recording
        hasScreenRecordingPermission = await checkScreenRecordingPermission()

        // Check accessibility
        hasAccessibilityPermission = checkAccessibilityPermission()
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
        // Use SCShareableContent to trigger the permission dialog
        // This is an async call that will prompt for screen recording permission
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                // Error is expected if permission is denied
                print("[OnboardingView] Screen recording permission request: \(error)")
            }
        }
    }

    private func requestAccessibility() {
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

                // Check accessibility
                hasAccessibilityPermission = checkAccessibilityPermission()
            }
        }
    }

    private func stopPermissionMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    // MARK: - Rewind Data Detection

    private func detectRewindData() async {
        // Check for Rewind memoryVault folder
        let memoryVaultPath = NSHomeDirectory() + "/Library/Application Support/com.memoryvault.MemoryVault"
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: memoryVaultPath) {
            // Found Rewind data
            hasRewindData = true
        } else {
            // No Rewind data found - skip the step entirely
            hasRewindData = false
        }
    }
}

// MARK: - ScreenCaptureKit Import

import ScreenCaptureKit

// MARK: - Shortcut Capture Field

struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var capturedKey: String
    let otherShortcut: String
    let onDuplicateAttempt: () -> Void

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

        func handleKeyPress(keyCode: UInt16, characters: String?) {
            guard parent.isRecording else { return }

            let keyName = mapKeyCodeToString(keyCode: keyCode, characters: characters)

            // Check for duplicate
            if keyName == parent.otherShortcut {
                parent.onDuplicateAttempt()
                parent.isRecording = false
                return
            }

            parent.capturedKey = keyName
            parent.isRecording = false
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
            default:
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
            coordinator?.handleKeyPress(keyCode: event.keyCode, characters: event.characters)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(coordinator: AppCoordinator()) {
            print("Onboarding complete")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
