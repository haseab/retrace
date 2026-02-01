import SwiftUI
import Shared

/// Sticky header for a day section in grouped search results
struct DaySectionHeader: View {
    let label: String
    let matchCount: Int
    let segmentCount: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            Spacer()

            Text("\(matchCount) matches in \(segmentCount) \(segmentCount == 1 ? "segment" : "segments")")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)
        }
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .background(Color.retraceBackground.opacity(0.95))
    }
}

// MARK: - Preview

#if DEBUG
struct DaySectionHeader_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            DaySectionHeader(
                label: "Today",
                matchCount: 24,
                segmentCount: 5
            )
            DaySectionHeader(
                label: "Yesterday",
                matchCount: 12,
                segmentCount: 3
            )
            DaySectionHeader(
                label: "Dec 29",
                matchCount: 8,
                segmentCount: 1
            )
        }
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
