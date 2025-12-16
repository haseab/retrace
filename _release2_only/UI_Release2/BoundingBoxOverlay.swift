import SwiftUI
import Shared

/// Overlay that displays bounding boxes around detected text regions
/// Used in FrameViewer to highlight search matches
public struct BoundingBoxOverlay: View {

    // MARK: - Properties

    let regions: [TextRegion]
    let searchQuery: String?
    let frameSize: CGSize

    @State private var hoveredRegion: TextRegion?
    @State private var selectedRegion: TextRegion?

    // MARK: - Initialization

    public init(
        regions: [TextRegion],
        searchQuery: String? = nil,
        frameSize: CGSize
    ) {
        self.regions = regions
        self.searchQuery = searchQuery
        self.frameSize = frameSize
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(regions) { region in
                    boundingBox(for: region, in: geometry.size)
                }
            }
        }
    }

    // MARK: - Bounding Box

    @ViewBuilder
    private func boundingBox(for region: TextRegion, in viewSize: CGSize) -> some View {
        let matches = regionMatchesQuery(region)
        let isHovered = hoveredRegion?.id == region.id
        let isSelected = selectedRegion?.id == region.id

        Rectangle()
            .strokeBorder(
                strokeColor(matches: matches, isHovered: isHovered, isSelected: isSelected),
                lineWidth: strokeWidth(matches: matches, isHovered: isHovered, isSelected: isSelected)
            )
            .background(
                Rectangle()
                    .fill(fillColor(matches: matches, isHovered: isHovered))
            )
            .frame(
                width: scaledWidth(region, in: viewSize),
                height: scaledHeight(region, in: viewSize)
            )
            .position(
                x: scaledX(region, in: viewSize),
                y: scaledY(region, in: viewSize)
            )
            .onHover { hovering in
                hoveredRegion = hovering ? region : nil
            }
            .onTapGesture {
                selectedRegion = (selectedRegion?.id == region.id) ? nil : region
            }
            .popover(isPresented: .constant(isHovered || isSelected)) {
                regionPopover(for: region, matches: matches)
            }
    }

    // MARK: - Popover

    private func regionPopover(for region: TextRegion, matches: Bool) -> some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            Text(region.text)
                .font(.retraceBody)
                .foregroundColor(.retracePrimary)

            if let confidence = region.confidence {
                HStack {
                    Text("Confidence:")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                    Text("\(Int(confidence * 100))%")
                        .font(.retraceCaption)
                        .foregroundColor(confidenceColor(confidence))
                }
            }

            if matches {
                Text("MATCH")
                    .font(.retraceCaption2)
                    .fontWeight(.bold)
                    .foregroundColor(.retraceSuccess)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.retraceSuccess.opacity(0.2))
                    .cornerRadius(4)
            }

            Divider()

            Button("Copy Text") {
                copyToClipboard(region.text)
            }
            .buttonStyle(.borderless)
            .font(.retraceCallout)
        }
        .padding(.spacingM)
        .frame(maxWidth: 250)
    }

    // MARK: - Styling Helpers

    private func strokeColor(matches: Bool, isHovered: Bool, isSelected: Bool) -> Color {
        if isSelected {
            return .retraceAccent
        } else if matches {
            return .retraceBoundingBox
        } else if isHovered {
            return .retraceBoundingBoxSecondary
        } else {
            return .retraceSecondary.opacity(0.5)
        }
    }

    private func strokeWidth(matches: Bool, isHovered: Bool, isSelected: Bool) -> CGFloat {
        if isSelected {
            return 3
        } else if matches || isHovered {
            return 2
        } else {
            return 1
        }
    }

    private func fillColor(matches: Bool, isHovered: Bool) -> Color {
        if matches {
            return Color.retraceMatchHighlight
        } else if isHovered {
            return Color.retraceHover.opacity(0.2)
        } else {
            return Color.clear
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 {
            return .retraceSuccess
        } else if confidence >= 0.7 {
            return .retraceWarning
        } else {
            return .retraceDanger
        }
    }

    // MARK: - Coordinate Scaling

    /// Scale region coordinates from frame space to view space
    private func scaledX(_ region: TextRegion, in viewSize: CGSize) -> CGFloat {
        let scaleX = viewSize.width / frameSize.width
        return region.bounds.origin.x * scaleX + (region.bounds.width * scaleX) / 2
    }

    private func scaledY(_ region: TextRegion, in viewSize: CGSize) -> CGFloat {
        let scaleY = viewSize.height / frameSize.height
        return region.bounds.origin.y * scaleY + (region.bounds.height * scaleY) / 2
    }

    private func scaledWidth(_ region: TextRegion, in viewSize: CGSize) -> CGFloat {
        let scaleX = viewSize.width / frameSize.width
        return region.bounds.width * scaleX
    }

    private func scaledHeight(_ region: TextRegion, in viewSize: CGSize) -> CGFloat {
        let scaleY = viewSize.height / frameSize.height
        return region.bounds.height * scaleY
    }

    // MARK: - Query Matching

    private func regionMatchesQuery(_ region: TextRegion) -> Bool {
        guard let query = searchQuery?.lowercased(), !query.isEmpty else {
            return false
        }

        return region.text.lowercased().contains(query)
    }

    // MARK: - Clipboard

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Preview

#if DEBUG
struct BoundingBoxOverlay_Previews: PreviewProvider {
    static var previews: some View {
        let sampleRegions = [
            TextRegion(
                id: nil,
                frameID: FrameID(value: UUID()),
                text: "Error message",
                bounds: CGRect(x: 100, y: 100, width: 150, height: 30),
                confidence: 0.95
            ),
            TextRegion(
                id: nil,
                frameID: FrameID(value: UUID()),
                text: "console.log",
                bounds: CGRect(x: 100, y: 150, width: 120, height: 25),
                confidence: 0.88
            ),
            TextRegion(
                id: nil,
                frameID: FrameID(value: UUID()),
                text: "Cannot read property",
                bounds: CGRect(x: 100, y: 200, width: 180, height: 28),
                confidence: 0.92
            )
        ]

        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 800, height: 600)

            BoundingBoxOverlay(
                regions: sampleRegions,
                searchQuery: "error",
                frameSize: CGSize(width: 800, height: 600)
            )
        }
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
    }
}
#endif
