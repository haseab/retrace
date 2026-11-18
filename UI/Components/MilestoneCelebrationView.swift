import SwiftUI
import AppKit
import Shared

/// A celebration dialog shown when users reach screen time milestones
/// Features a personal message from the creator with profile picture
/// Animation: Title/icon appears centered in dialog, does effects, then moves up while content fades in
struct MilestoneCelebrationView: View {
    let milestone: MilestoneCelebrationManager.Milestone
    let onDismiss: () -> Void
    let onMaybeLater: () -> Void
    let onSupport: () -> Void

    enum ActionLayout: Equatable {
        case continueOnly
        case maybeLaterAndSupport
        case acceptCrown
    }

    enum SingleButtonAction: Equatable {
        case dismiss
        case maybeLater
    }

    /// Creator profile image cached after first successful resolve.
    @State private var creatorProfileImage: NSImage? = nil

    // Animation states
    @State private var showIcon = false
    @State private var showTitle = false
    @State private var iconGlow = false
    @State private var glowPulse = false  // For pulsing glow animation
    @State private var showContent = false
    @State private var showConfetti = false
    @State private var headerExpanded = false  // false = title centered, true = title at top

    var body: some View {
        ZStack {
            // Confetti layer (behind the dialog)
            if showConfetti && milestone != .tenHours {
                ConfettiView(
                    particleCount: milestone == .tenThousandHours ? 400 : (milestone == .thousandHours ? 200 : 150),
                    burstCount: milestone == .tenThousandHours ? 5 : (milestone == .thousandHours ? 3 : 1)
                )
                .ignoresSafeArea()
            }

            // Main dialog
            dialogContent
        }
        .onAppear {
            ensureCreatorProfileImageLoaded(reason: "dialog-onAppear")
            startAnimationSequence()
        }
    }

    private var dialogContent: some View {
        ZStack {
            // Background
            Color.retraceBackground
                .cornerRadius(16)

            VStack(spacing: 0) {
                // Header area with gradient
                ZStack {
                    // Gradient background for header
                    LinearGradient(
                        colors: [
                            Color.retraceAccent.opacity(0.3),
                            Color.retraceAccent.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    // Celebration title/icon with glow behind it
                    celebrationHeader
                }
                .frame(height: headerExpanded ? (milestone == .tenThousandHours ? 250 : (milestone == .thousandHours ? 220 : 180)) : 300)

                // Content area - only visible when expanded
                if showContent {
                    contentSection
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.5), value: headerExpanded)
        .animation(.easeInOut(duration: 0.4), value: showContent)
    }

    // MARK: - Celebration Header

    private var celebrationHeader: some View {
        ZStack {
            // Glow effect behind everything for 100h and 1000h
            if milestone != .tenHours && iconGlow {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [glowColor.opacity(0.6), glowColor.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)
                    .blur(radius: 30)
                    .scaleEffect(glowPulse ? 1.15 : 0.9)
                    .opacity(glowPulse ? 1 : 0.7)
                    .offset(y: -20) // Slight offset to center on icon
            }

            VStack(spacing: 8) {
                if milestone == .tenHours {
                    // Simple title for 10h
                    Text(milestone.title)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.retracePrimary)
                        .opacity(showTitle ? 1 : 0)
                        .scaleEffect(showTitle ? 1 : 0.5)
                } else {
                    // Icon for 100h and 1000h
                    ZStack {
                        // Pulsing glow rings for both 100h and 1000h
                        if iconGlow {
                            let ringCount = milestone == .tenThousandHours ? 5 : (milestone == .thousandHours ? 3 : 2)
                            ForEach(0..<ringCount, id: \.self) { ring in
                                Circle()
                                    .stroke(glowColor.opacity(0.3 - Double(ring) * 0.1), lineWidth: 2)
                                    .frame(width: CGFloat(70 + ring * 25), height: CGFloat(70 + ring * 25))
                                    .scaleEffect(glowPulse ? 1.3 : 1.0)
                                    .opacity(glowPulse ? 0.7 : 0.4)
                            }
                        }

                        Image(systemName: celebrationIcon)
                            .font(.system(size: 56))
                            .foregroundStyle(iconGradient)
                            .shadow(color: glowColor.opacity(glowPulse ? 1.0 : 0.6), radius: glowPulse ? 30 : 20)
                            .scaleEffect(showIcon ? 1 : 0)
                            .opacity(showIcon ? 1 : 0)
                    }

                    // Title appears after icon
                    Text(milestone.title)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.retracePrimary)
                        .opacity(showTitle ? 1 : 0)
                        .scaleEffect(showTitle ? 1 : 0.8)
                }
            }
            .padding(.vertical, milestone == .tenThousandHours ? 16 : (milestone == .thousandHours ? 24 : 0))
            .offset(y: milestone == .tenThousandHours ? -10 : 0)
        }
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: glowPulse)
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                // Profile section
                profileSection

                // Personal message
                Text(milestone.message)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)

            Divider()
                .background(Color.retraceBorder)

            // Action buttons
            actionButtons
        }
        .background(Color.retraceBackground)
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        HStack(alignment: .center, spacing: 12) {
            // Profile picture - bundled locally
            if let creatorProfileImage {
                Image(nsImage: creatorProfileImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.retraceAccent, lineWidth: 1.5)
                    )
            } else {
                fallbackProfileImage
                    .overlay(
                        Circle()
                            .stroke(Color.retraceAccent, lineWidth: 1.5)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Haseab")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("Creator of Retrace")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        Group {
            switch Self.actionLayout(for: milestone) {
            case .acceptCrown:
                Button(action: onDismiss) {
                    HStack(spacing: 8) {
                        Text("🐐")
                        Text("I Accept My Crown")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.white)
                        Text("🐐")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 255/255, green: 0/255, blue: 128/255),
                                Color(red: 255/255, green: 165/255, blue: 0/255),
                                Color(red: 255/255, green: 215/255, blue: 0/255)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(24)
            case .continueOnly:
                Button(action: {
                    switch Self.singleButtonAction(for: milestone) {
                    case .dismiss:
                        onDismiss()
                    case .maybeLater:
                        onMaybeLater()
                    }
                }) {
                    Text("Continue")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.retraceAccent, Color.retraceAccent.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(24)
            case .maybeLaterAndSupport:
                HStack(spacing: 16) {
                    // Dismiss button
                    Button(action: onMaybeLater) {
                        Text("Maybe Later")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retraceSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.retraceSecondaryBackground)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.retraceBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    // Support button
                    Button(action: {
                        onSupport()
                        onDismiss()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.white)
                            Text("Support Retrace")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.retraceAccent, Color.retraceAccent.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
        }
    }

    static func actionLayout(for milestone: MilestoneCelebrationManager.Milestone) -> ActionLayout {
        switch milestone {
        case .tenHours:
            return .continueOnly
        case .hundredHours, .thousandHours:
            return .maybeLaterAndSupport
        case .tenThousandHours:
            return .acceptCrown
        }
    }

    static func singleButtonAction(for milestone: MilestoneCelebrationManager.Milestone) -> SingleButtonAction {
        switch milestone {
        case .tenHours:
            return .maybeLater
        case .tenThousandHours:
            return .dismiss
        case .hundredHours, .thousandHours:
            return .dismiss
        }
    }

    // MARK: - Animation Sequence

    private func startAnimationSequence() {
        if milestone == .tenHours {
            // 10h: Title appears centered
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showTitle = true
            }

            // After a moment, shrink header and show content
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    headerExpanded = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showContent = true
                    }
                }
            }
        } else {
            // 100h/1000h: Animated sequence
            // Step 1: Icon appears with spring animation
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
                showIcon = true
            }

            // Step 2: Icon starts glowing
            withAnimation(.easeInOut(duration: 0.6).delay(0.4)) {
                iconGlow = true
            }

            // Step 2b: Start pulsing glow animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                glowPulse = true
            }

            // Step 3: Title appears
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.6)) {
                showTitle = true
            }

            // Step 4: Confetti bursts (earlier for 100h since it comes from behind card)
            let confettiDelay = milestone == .hundredHours ? 0.4 : 0.7
            DispatchQueue.main.asyncAfter(deadline: .now() + confettiDelay) {
                showConfetti = true
            }

            // Step 5: Shrink header and reveal content
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    headerExpanded = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showContent = true
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var celebrationIcon: String {
        switch milestone {
        case .tenHours:
            return "star.fill"
        case .hundredHours:
            return "star.fill"
        case .thousandHours:
            return "crown.fill"
        case .tenThousandHours:
            return "trophy.fill"
        }
    }

    private var iconGradient: LinearGradient {
        switch milestone {
        case .tenHours, .hundredHours:
            return LinearGradient(
                colors: [.yellow, .orange],
                startPoint: .top,
                endPoint: .bottom
            )
        case .thousandHours:
            return LinearGradient(
                colors: [
                    Color(red: 255/255, green: 215/255, blue: 0/255), // Gold
                    Color(red: 255/255, green: 165/255, blue: 0/255), // Orange gold
                    Color(red: 218/255, green: 165/255, blue: 32/255)  // Goldenrod
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .tenThousandHours:
            // Rainbow gradient for the GOAT
            return LinearGradient(
                colors: [
                    Color(red: 255/255, green: 0/255, blue: 128/255),   // Hot pink
                    Color(red: 255/255, green: 215/255, blue: 0/255),   // Gold
                    Color(red: 0/255, green: 255/255, blue: 128/255),   // Spring green
                    Color(red: 0/255, green: 191/255, blue: 255/255),   // Deep sky blue
                    Color(red: 148/255, green: 0/255, blue: 211/255)    // Violet
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var glowColor: Color {
        switch milestone {
        case .tenHours, .hundredHours:
            return .yellow
        case .thousandHours:
            return Color(red: 255/255, green: 215/255, blue: 0/255) // Gold
        case .tenThousandHours:
            return Color(red: 255/255, green: 0/255, blue: 128/255) // Hot pink
        }
    }

    private var fallbackProfileImage: some View {
        Circle()
            .fill(Color.retraceAccent.opacity(0.3))
            .frame(width: 40, height: 40)
            .overlay(
                Text("H")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.retraceAccent)
            )
    }

    private func ensureCreatorProfileImageLoaded(reason: String) {
        guard creatorProfileImage == nil else { return }
        creatorProfileImage = resolveCreatorProfileImage(logContext: "[MilestoneCelebrationView] \(reason)")
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
}

struct DiscordFollowupView: View {
    let onJoin: () -> Void
    let onMaybeLater: () -> Void

    @StateObject private var statsModel = DiscordInviteStatsModel()
    private let refreshTimer = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

    private let discordPurple = Color(red: 88/255, green: 101/255, blue: 242/255)
    private let discordDeepPurple = Color(red: 64/255, green: 78/255, blue: 237/255)
    private let cardBackground = Color(red: 16/255, green: 20/255, blue: 36/255)

    var body: some View {
        VStack(spacing: 0) {
            heroSection

            Divider()
                .background(Color.white.opacity(0.12))

            actionButtons
                .padding(24)
        }
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .task {
            await statsModel.refresh()
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await statsModel.refresh()
            }
        }
    }

    private var heroSection: some View {
        ZStack {
            LinearGradient(
                colors: [discordPurple, discordDeepPurple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 190, height: 190)
                .offset(x: 160, y: -70)

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 140, height: 140)
                .offset(x: -170, y: 90)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    DiscordBrandMark(size: 56)
                    RetraceBrandMark(size: 56)
                }

                Text("Join the Retrace Discord")
                    .font(.retraceTitle3)
                    .foregroundColor(.white)

                Text("All the power users are hanging out here!")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(height: 190)
        .clipShape(TopRoundedRectangle(radius: 18))
    }

    private var actionButtons: some View {
        HStack(spacing: 14) {
            Button(action: onMaybeLater) {
                Text("Maybe Later")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.white.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(9)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onJoin) {
                HStack(spacing: 8) {
                    DiscordBrandMark(size: 18, showsBackground: false)
                    Text("Join Discord")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.white)

                    if let onlineLabel = onlineShortLabel {
                        Text("• \(onlineLabel)")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.white.opacity(0.9))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [discordPurple, discordDeepPurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(9)
                .shadow(color: discordPurple.opacity(0.45), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(.plain)
        }
    }

    private var onlineShortLabel: String? {
        guard let stats = statsModel.stats else { return nil }
        return "\(stats.onlineCount.formatted(.number.grouping(.automatic))) online"
    }
}

private struct DiscordBrandMark: View {
    let size: CGFloat
    var showsBackground: Bool = true

    private static let discordSVG = """
    <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 640 512' fill='#FFFFFF'>
      <path d='M524.531,69.836a1.5,1.5,0,0,0-.764-.7A485.065,485.065,0,0,0,404.081,32.03a1.816,1.816,0,0,0-1.923.91,337.461,337.461,0,0,0-14.9,30.6,447.848,447.848,0,0,0-134.426,0,309.541,309.541,0,0,0-15.135-30.6,1.89,1.89,0,0,0-1.924-.91A483.689,483.689,0,0,0,116.085,69.137a1.712,1.712,0,0,0-.788.676C39.068,183.651,18.186,294.69,28.43,404.354a2.016,2.016,0,0,0,.765,1.375A487.666,487.666,0,0,0,176.02,479.918a1.9,1.9,0,0,0,2.063-.676A348.2,348.2,0,0,0,208.12,430.4a1.86,1.86,0,0,0-1.019-2.588,321.173,321.173,0,0,1-45.868-21.853,1.885,1.885,0,0,1-.185-3.126c3.082-2.309,6.166-4.711,9.109-7.137a1.819,1.819,0,0,1,1.9-.256c96.229,43.917,200.41,43.917,295.5,0a1.812,1.812,0,0,1,1.924.233c2.944,2.426,6.027,4.851,9.132,7.16a1.884,1.884,0,0,1-.162,3.126,301.407,301.407,0,0,1-45.89,21.83,1.875,1.875,0,0,0-1,2.611,391.055,391.055,0,0,0,30.014,48.815,1.864,1.864,0,0,0,2.063.7A486.048,486.048,0,0,0,610.7,405.729a1.882,1.882,0,0,0,.765-1.352C623.729,277.594,590.933,167.465,524.531,69.836ZM222.491,337.58c-28.972,0-52.844-26.587-52.844-59.239S193.056,219.1,222.491,219.1c29.665,0,53.306,26.82,52.843,59.239C275.334,310.993,251.924,337.58,222.491,337.58Zm195.38,0c-28.971,0-52.843-26.587-52.843-59.239S388.437,219.1,417.871,219.1c29.667,0,53.307,26.82,52.844,59.239C470.715,310.993,447.538,337.58,417.871,337.58Z'/>
    </svg>
    """

    private static let logoImage: NSImage? = {
        guard let data = discordSVG.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }()

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }

            if let logoImage = Self.logoImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.58, height: size * 0.58)
            } else {
                Image(systemName: "person.2.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white)
                    .frame(width: size * 0.56, height: size * 0.56)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct RetraceBrandMark: View {
    let size: CGFloat
    var showsBackground: Bool = true

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }

            RetraceGlyph()
                .frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
    }
}

private struct RetraceGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scaleX = width / 120
            let scaleY = height / 120

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 15 * scaleX, y: 60 * scaleY))
                    path.addLine(to: CGPoint(x: 54 * scaleX, y: 33 * scaleY))
                    path.addLine(to: CGPoint(x: 54 * scaleX, y: 87 * scaleY))
                    path.closeSubpath()
                }
                .fill(Color.white)

                Path { path in
                    path.move(to: CGPoint(x: 105 * scaleX, y: 60 * scaleY))
                    path.addLine(to: CGPoint(x: 66 * scaleX, y: 33 * scaleY))
                    path.addLine(to: CGPoint(x: 66 * scaleX, y: 87 * scaleY))
                    path.closeSubpath()
                }
                .fill(Color.white)
            }
        }
    }
}

private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(min(radius, rect.width / 2), rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

@MainActor
private final class DiscordInviteStatsModel: ObservableObject {
    struct Stats: Equatable {
        let guildName: String
        let memberCount: Int
        let onlineCount: Int
    }

    @Published private(set) var stats: Stats?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var didFail = false

    private var inviteCode: String?
    private var isRefreshing = false

    private static let shortInviteURL = URL(string: "https://retrace.to/l/retrace-discord")!
    private static let fallbackInviteCode = "retrace-discord"

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if stats == nil {
            isLoading = true
        }
        defer {
            isRefreshing = false
            isLoading = false
        }

        do {
            let code = (try? await resolveInviteCode()) ?? Self.fallbackInviteCode
            let latest = try await fetchStats(inviteCode: code)
            stats = latest
            didFail = false
            lastUpdated = Date()
        } catch {
            didFail = true
        }
    }

    private func resolveInviteCode() async throws -> String {
        if let inviteCode {
            return inviteCode
        }

        var request = URLRequest(url: Self.shortInviteURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = response.url,
              let code = Self.extractInviteCode(from: finalURL)
        else {
            throw DiscordInviteError.invalidInviteURL
        }

        inviteCode = code
        return code
    }

    private func fetchStats(inviteCode: String) async throws -> Stats {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "discord.com"
        components.path = "/api/v10/invites/\(inviteCode)"
        components.queryItems = [
            URLQueryItem(name: "with_counts", value: "true"),
            URLQueryItem(name: "with_expiration", value: "true"),
        ]

        guard let url = components.url else {
            throw DiscordInviteError.invalidInviteURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw DiscordInviteError.badStatusCode
        }

        let decoded = try JSONDecoder().decode(DiscordInviteResponse.self, from: data)
        guard let memberCount = decoded.approximateMemberCount,
              let onlineCount = decoded.approximatePresenceCount
        else {
            throw DiscordInviteError.missingCounts
        }

        return Stats(
            guildName: decoded.guild?.name ?? "Retrace Community",
            memberCount: memberCount,
            onlineCount: onlineCount
        )
    }

    private static func extractInviteCode(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if host == "discord.gg" || host == "www.discord.gg" {
            return pathComponents.first
        }

        if host == "discord.com" || host == "www.discord.com" {
            guard let inviteIndex = pathComponents.firstIndex(of: "invite"),
                  pathComponents.indices.contains(inviteIndex + 1)
            else {
                return nil
            }
            return pathComponents[inviteIndex + 1]
        }

        return nil
    }
}

private struct DiscordInviteResponse: Decodable {
    struct Guild: Decodable {
        let name: String
    }

    let guild: Guild?
    let approximateMemberCount: Int?
    let approximatePresenceCount: Int?

    enum CodingKeys: String, CodingKey {
        case guild
        case approximateMemberCount = "approximate_member_count"
        case approximatePresenceCount = "approximate_presence_count"
    }
}

private enum DiscordInviteError: Error {
    case invalidInviteURL
    case badStatusCode
    case missingCounts
}

// MARK: - Preview

#if DEBUG
struct MilestoneCelebrationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                MilestoneCelebrationView(
                    milestone: .tenHours,
                    onDismiss: {},
                    onMaybeLater: {},
                    onSupport: {}
                )
            }
            .previewDisplayName("10 Hours")

            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                MilestoneCelebrationView(
                    milestone: .hundredHours,
                    onDismiss: {},
                    onMaybeLater: {},
                    onSupport: {}
                )
            }
            .previewDisplayName("100 Hours")

            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                MilestoneCelebrationView(
                    milestone: .thousandHours,
                    onDismiss: {},
                    onMaybeLater: {},
                    onSupport: {}
                )
            }
            .previewDisplayName("1000 Hours")

            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                MilestoneCelebrationView(
                    milestone: .tenThousandHours,
                    onDismiss: {},
                    onMaybeLater: {},
                    onSupport: {}
                )
            }
            .previewDisplayName("10000 Hours - THE GOAT")

            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                DiscordFollowupView(
                    onJoin: {},
                    onMaybeLater: {}
                )
            }
            .previewDisplayName("Discord Follow-up")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
