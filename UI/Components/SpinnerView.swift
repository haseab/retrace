import SwiftUI

/// A modern spinning arc loading indicator
/// Replaces the default ProgressView with a sleek animated spinner
struct SpinnerView: View {
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3
    var color: Color = .retraceAccent

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                    rotation = 360
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
