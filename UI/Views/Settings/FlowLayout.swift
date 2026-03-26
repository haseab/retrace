import SwiftUI

struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content()
        }
    }
}
