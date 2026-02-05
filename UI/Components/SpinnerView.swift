import SwiftUI

/// A modern spinning arc loading indicator
/// Uses native ProgressView for power efficiency (no idle wakeups)
struct SpinnerView: View {
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3
    var color: Color = .retraceAccent

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(size / 24)
            .tint(color)
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
