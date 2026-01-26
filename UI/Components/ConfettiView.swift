import SwiftUI

/// A single confetti particle
struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGSize
    let position: CGPoint
    let rotation: Double
    let rotationSpeed: Double
    let velocity: CGVector
    let shape: ConfettiShape
    let startTime: Date

    enum ConfettiShape {
        case rectangle
        case circle
        case triangle
    }
}

/// Confetti effect overlay - Raycast-style celebration
struct ConfettiView: View {
    let particleCount: Int
    let burstCount: Int // Number of confetti bursts (1 for 100h, 3 for 1000h)

    @State private var particles: [ConfettiParticle] = []
    @State private var currentTime: Date = Date()

    private let colors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink,
        Color(red: 255/255, green: 215/255, blue: 0/255), // Gold
        Color(red: 0/255, green: 255/255, blue: 127/255), // Spring green
        Color(red: 255/255, green: 105/255, blue: 180/255) // Hot pink
    ]

    private let animationDuration: Double = 2.5
    private let timer = Timer.publish(every: 1/60, on: .main, in: .common).autoconnect()

    init(particleCount: Int = 150, burstCount: Int = 1) {
        self.particleCount = particleCount
        self.burstCount = burstCount
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    ConfettiParticleView(particle: particle, currentTime: currentTime, animationDuration: animationDuration)
                }
            }
            .onAppear {
                // Delay before confetti starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    triggerBurst(in: geometry.size, burstNumber: 0)
                }
            }
            .onReceive(timer) { time in
                currentTime = time
            }
        }
        .allowsHitTesting(false)
    }

    private func triggerBurst(in size: CGSize, burstNumber: Int) {
        guard burstNumber < burstCount else { return }

        // Calculate burst origin
        // For single burst (100h): center behind the card
        // For multiple bursts (1000h/10000h): spread across screen
        let origin: CGPoint
        if burstCount == 1 {
            // Single burst - center behind the card
            origin = CGPoint(x: size.width / 2, y: size.height * 0.4)
        } else if burstCount >= 5 {
            // 5+ bursts (10000h) - all corners and center for maximum celebration
            let origins: [CGPoint] = [
                CGPoint(x: size.width / 2, y: size.height * 0.15),      // Top center
                CGPoint(x: size.width * 0.15, y: size.height * 0.1),   // Top left
                CGPoint(x: size.width * 0.85, y: size.height * 0.1),   // Top right
                CGPoint(x: size.width * 0.1, y: size.height * 0.5),    // Middle left
                CGPoint(x: size.width * 0.9, y: size.height * 0.5)     // Middle right
            ]
            origin = origins[burstNumber % origins.count]
        } else {
            // 3 bursts (1000h) - positioned near top of screen
            let origins: [CGPoint] = [
                CGPoint(x: size.width / 2, y: size.height * 0.15),
                CGPoint(x: size.width * 0.25, y: size.height * 0.12),
                CGPoint(x: size.width * 0.75, y: size.height * 0.12)
            ]
            origin = origins[burstNumber % origins.count]
        }
        let burstTime = Date()

        // Generate particles for this burst
        let newParticles = (0..<particleCount).map { _ in
            createParticle(origin: origin, containerSize: size, startTime: burstTime)
        }

        particles.append(contentsOf: newParticles)

        // Schedule next burst if needed
        if burstNumber + 1 < burstCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                triggerBurst(in: size, burstNumber: burstNumber + 1)
            }
        }

        // Clean up particles after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.5 + Double(burstCount) * 0.3) {
            if burstNumber == burstCount - 1 {
                particles.removeAll()
            }
        }
    }

    private func createParticle(origin: CGPoint, containerSize: CGSize, startTime: Date) -> ConfettiParticle {
        let angle = Double.random(in: 0...(2 * .pi))
        let speed = Double.random(in: 300...600)

        // Bias upward and outward
        let velocityX = cos(angle) * speed
        let velocityY = sin(angle) * speed - 200 // Bias upward

        return ConfettiParticle(
            color: colors.randomElement()!,
            size: CGSize(
                width: CGFloat.random(in: 6...12),
                height: CGFloat.random(in: 8...16)
            ),
            position: origin,
            rotation: Double.random(in: 0...360),
            rotationSpeed: Double.random(in: -720...720),
            velocity: CGVector(dx: velocityX, dy: velocityY),
            shape: [.rectangle, .circle, .triangle].randomElement()!,
            startTime: startTime
        )
    }
}

/// Individual confetti particle view
struct ConfettiParticleView: View {
    let particle: ConfettiParticle
    let currentTime: Date
    let animationDuration: Double

    private let gravity: CGFloat = 800

    private var progress: CGFloat {
        let elapsed = currentTime.timeIntervalSince(particle.startTime)
        return CGFloat(min(max(elapsed / animationDuration, 0), 1))
    }

    var body: some View {
        particleShape
            .frame(width: particle.size.width, height: particle.size.height)
            .rotationEffect(.degrees(particle.rotation + particle.rotationSpeed * Double(progress)))
            .position(currentPosition)
            .opacity(opacity)
    }

    private var currentPosition: CGPoint {
        let time = Double(progress) * animationDuration

        let x = particle.position.x + particle.velocity.dx * time * 0.5
        let y = particle.position.y + particle.velocity.dy * time * 0.5 + 0.5 * gravity * time * time * 0.3

        return CGPoint(x: x, y: y)
    }

    private var opacity: Double {
        // Fade out in the last 30% of animation
        if progress > 0.7 {
            return Double(1 - (progress - 0.7) / 0.3)
        }
        return 1
    }

    @ViewBuilder
    private var particleShape: some View {
        switch particle.shape {
        case .rectangle:
            Rectangle()
                .fill(particle.color)
        case .circle:
            Circle()
                .fill(particle.color)
        case .triangle:
            Triangle()
                .fill(particle.color)
        }
    }
}

/// Triangle shape for confetti
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#if DEBUG
struct ConfettiView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ConfettiView(particleCount: 100, burstCount: 3)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
