import SwiftUI
import AppKit

/// A celebration dialog shown when users reach screen time milestones
/// Features a personal message from the creator with profile picture
/// Animation: Title/icon appears centered in dialog, does effects, then moves up while content fades in
struct MilestoneCelebrationView: View {
    let milestone: MilestoneCelebrationManager.Milestone
    let onDismiss: () -> Void
    let onSupport: () -> Void

    /// Creator profile image — bundled locally in Assets.xcassets (no network request needed)

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
            Image("CreatorProfile")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.retraceAccent, lineWidth: 1.5)
                )

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
            if milestone == .tenThousandHours {
                // Special button for 10k - no support ask, just celebration
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
            } else {
                HStack(spacing: 16) {
                    // Dismiss button
                    Button(action: onDismiss) {
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
                    onSupport: {}
                )
            }
            .previewDisplayName("10000 Hours - THE GOAT")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
