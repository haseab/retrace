import SwiftUI

/// A pulsing ring loading indicator
/// Uses a single repeating SwiftUI animation — no timers, no geometry recalculations
struct SpinnerView: View {
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3
    var color: Color = .retraceAccent

    @State private var isAnimating = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.3), lineWidth: lineWidth)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: lineWidth)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 0.0 : 1.0)
            )
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.2)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
    }
}

#if DEBUG
struct SpinnerView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 32) {
            SpinnerView()
            SpinnerView(size: 16, lineWidth: 2)
            SpinnerView(size: 32, lineWidth: 4, color: .white)
        }
        .padding(40)
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
