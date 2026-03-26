import SwiftUI
import Shared

struct RetentionTagsChip<PopoverContent: View>: View {
    let selectedTagIds: Set<Int64>
    let availableTags: [Tag]
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false

    private var selectedTags: [Tag] {
        availableTags.filter { selectedTagIds.contains($0.id.value) }
    }

    private var isActive: Bool {
        !selectedTagIds.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12))

                if selectedTags.count == 1 {
                    Text(selectedTags[0].name)
                        .font(.retraceCaptionMedium)
                        .lineLimit(1)
                } else if selectedTags.count > 1 {
                    Text("\(selectedTags.count) tags")
                        .font(.retraceCaptionMedium)
                } else {
                    Text("None")
                        .font(.retraceCaptionMedium)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTagIds)
            .foregroundColor(isActive ? .white : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.retraceAccent.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.retraceAccent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }
}
