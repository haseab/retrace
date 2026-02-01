import SwiftUI
import Shared

/// A compact row for expanded results within a segment stack
/// Shows timestamp and snippet for quick scanning
struct ExpandedResultRow: View {
    let result: SearchResult
    let searchQuery: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: .spacingM) {
            // Indent spacer to align with main row content (after thumbnail)
            Color.clear.frame(width: 120)

            // Time indicator
            Text(formatTime(result.timestamp))
                .font(.retraceMonoSmall)
                .foregroundColor(.retraceSecondary)
                .frame(width: 70, alignment: .leading)

            // Snippet preview with highlighting
            highlightedSnippet
                .font(.retraceCaption)
                .lineLimit(1)

            Spacer()

            // Arrow indicator on hover
            Image(systemName: "arrow.right")
                .font(.retraceTiny)
                .foregroundColor(.retraceSecondary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .background(isHovered ? Color.retraceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var highlightedSnippet: Text {
        let query = searchQuery.lowercased().replacingOccurrences(of: "\"", with: "")
        let snippet = result.snippet

        // Find the query in the snippet (case-insensitive)
        if let range = snippet.lowercased().range(of: query) {
            let before = String(snippet[..<range.lowerBound])
            let match = String(snippet[range])
            let after = String(snippet[range.upperBound...])

            return Text(before).foregroundColor(.retraceSecondary) +
                   Text(match).foregroundColor(.retracePrimary).bold() +
                   Text(after).foregroundColor(.retraceSecondary)
        } else {
            return Text(snippet).foregroundColor(.retraceSecondary)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ExpandedResultRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            ExpandedResultRow(
                result: SearchResult(
                    id: FrameID(value: 1),
                    timestamp: Date(),
                    snippet: "Error: Cannot read property 'user' of undefined",
                    matchedText: "Error",
                    relevanceScore: 0.95,
                    metadata: FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Chrome",
                        windowName: "GitHub",
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: AppSegmentID(value: 1),
                    frameIndex: 0
                ),
                searchQuery: "error"
            ) {
                print("Selected")
            }

            ExpandedResultRow(
                result: SearchResult(
                    id: FrameID(value: 2),
                    timestamp: Date().addingTimeInterval(-300),
                    snippet: "TODO: Fix error handling in auth",
                    matchedText: "error",
                    relevanceScore: 0.85,
                    metadata: FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Chrome",
                        windowName: "GitHub",
                        browserURL: nil,
                        displayID: 0
                    ),
                    segmentID: AppSegmentID(value: 1),
                    frameIndex: 5
                ),
                searchQuery: "error"
            ) {
                print("Selected")
            }
        }
        .background(Color.retraceSecondaryBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
