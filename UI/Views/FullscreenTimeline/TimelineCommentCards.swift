import AppKit
import Foundation
import Shared
import SwiftUI

private struct TimelineCommentMetaChip: View {
    let text: String
    let icon: String
    let accent: Color

    var body: some View {
        CommentChromeChip(
            text: text,
            icon: icon,
            foregroundColor: accent,
            backgroundColor: Color.white.opacity(0.08),
            borderColor: Color.white.opacity(0.12)
        )
    }
}

private struct TimelineCommentMarkdownBodyView: View {
    let source: String

    var body: some View {
        let lines = TimelineCommentPresentationSupport.normalizedLines(from: source)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Text(" ")
                } else if let headingLevel = TimelineCommentPresentationSupport.markdownHeadingLevel(in: line) {
                    Text(renderedMarkdownLine(from: line))
                        .font(markdownHeadingFont(for: headingLevel))
                } else {
                    Text(renderedMarkdownLine(from: line))
                }
            }
        }
    }

    private func renderedMarkdownLine(from source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }

    private func markdownHeadingFont(for level: Int) -> Font {
        let size = max(13.0, 20.0 - (Double(level - 1) * 1.8))
        return .system(size: size, weight: .semibold)
    }
}

struct TimelineAllCommentsCard: View {
    let presentation: TimelineAllCommentsCardPresentation
    let isHovered: Bool
    let onOpen: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                if let bundleID = presentation.appBundleID {
                    AppIconView(bundleID: bundleID, size: 20)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.07))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.headerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.95))
                        .lineLimit(1)

                    if let headerSubtitle = presentation.headerSubtitle {
                        Text(headerSubtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.retraceSecondary.opacity(0.82))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    if let tagName = presentation.primaryTagName {
                        TimelineCommentMetaChip(
                            text: tagName,
                            icon: "tag.fill",
                            accent: Color.retracePrimary.opacity(0.88)
                        )
                    }

                    TimelineCommentMetaChip(
                        text: presentation.timestampText,
                        icon: "clock",
                        accent: Color.retraceSecondary.opacity(0.88)
                    )
                }
            }

            Text(presentation.previewText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retracePrimary.opacity(0.95))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let browserURL = presentation.browserURL {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary.opacity(0.84))
                    Text(browserURL)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.retraceSecondary.opacity(0.88))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    presentation.isAnchor
                    ? Color.retraceSubmitAccent.opacity(0.16)
                    : (presentation.isSearchHighlighted ? Color.retraceSubmitAccent.opacity(0.12) : Color.white.opacity(0.055))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    presentation.isAnchor
                    ? Color.retraceSubmitAccent.opacity(0.42)
                    : (presentation.isSearchHighlighted ? Color.retraceSubmitAccent.opacity(0.34) : Color.white.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            onHoverChanged(hovering)
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

struct TimelineAllCommentsCardPresentation: Equatable {
    let appBundleID: String?
    let headerLabel: String
    let headerSubtitle: String?
    let primaryTagName: String?
    let timestampText: String
    let previewText: String
    let browserURL: String?
    let isAnchor: Bool
    let isSearchHighlighted: Bool
}

struct TimelineThreadCommentCardPresentation: Equatable {
    let author: String
    let timestampText: String
    let showsDeleteAction: Bool
}

enum TimelineCommentPresentationSupport {
    static func makeAllCommentsCardPresentation(
        row: CommentTimelineRow,
        anchorID: SegmentCommentID?,
        highlightedID: SegmentCommentID?,
        dateFormatter: DateFormatter
    ) -> TimelineAllCommentsCardPresentation {
        let appName = row.context?.appName
        let appBundleID = row.context?.appBundleID
        let isAnchor = row.id == anchorID &&
            (highlightedID == nil || highlightedID == anchorID)

        return TimelineAllCommentsCardPresentation(
            appBundleID: appBundleID,
            headerLabel: appName ?? appBundleID ?? row.comment.author,
            headerSubtitle: appName == nil ? nil : appBundleID,
            primaryTagName: row.primaryTagName,
            timestampText: dateFormatter.string(from: row.comment.createdAt),
            previewText: previewText(from: row.comment.body),
            browserURL: row.context?.browserURL,
            isAnchor: isAnchor,
            isSearchHighlighted: row.id == highlightedID
        )
    }

    static func makeThreadCommentCardPresentation(
        comment: SegmentComment,
        hoveredCommentID: SegmentCommentID?,
        dateFormatter: DateFormatter
    ) -> TimelineThreadCommentCardPresentation {
        TimelineThreadCommentCardPresentation(
            author: comment.author,
            timestampText: dateFormatter.string(from: comment.createdAt),
            showsDeleteAction: hoveredCommentID == comment.id
        )
    }

    static func previewText(
        from body: String,
        truncationLimit: Int = 180
    ) -> String {
        let candidate = normalizedLines(from: body)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "No preview"

        if candidate.count <= truncationLimit {
            return candidate
        }

        let index = candidate.index(candidate.startIndex, offsetBy: truncationLimit)
        return "\(candidate[..<index])..."
    }

    static func normalizedLines(from source: String) -> [String] {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func markdownHeadingLevel(in line: String) -> Int? {
        let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
        guard !trimmedLeading.isEmpty else { return nil }

        var index = trimmedLeading.startIndex
        var level = 0
        while index < trimmedLeading.endIndex,
              trimmedLeading[index] == "#",
              level < 6 {
            level += 1
            index = trimmedLeading.index(after: index)
        }

        guard level > 0, index < trimmedLeading.endIndex else { return nil }
        guard trimmedLeading[index].isWhitespace else { return nil }
        return level
    }
}

struct TimelineThreadCommentCard: View {
    let comment: SegmentComment
    let presentation: TimelineThreadCommentCardPresentation
    let isHovered: Bool
    let onDelete: () -> Void
    let onOpen: () -> Void
    let onAttachmentOpen: (SegmentCommentAttachment) -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(presentation.author)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.retracePrimary)

                Text(presentation.timestampText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.85))

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.95))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.retraceDanger.opacity(0.14))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.retraceDanger.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .opacity(presentation.showsDeleteAction ? 1 : 0)
                .allowsHitTesting(presentation.showsDeleteAction)
                .animation(.easeOut(duration: 0.12), value: presentation.showsDeleteAction)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TimelineCommentMarkdownBodyView(source: comment.body)
                    .foregroundColor(.retracePrimary.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })

                if !comment.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(comment.attachments) { attachment in
                            Button(action: { onAttachmentOpen(attachment) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.retraceSecondary.opacity(0.9))
                                    Text(attachment.fileName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.retracePrimary.opacity(0.95))
                                        .lineLimit(1)
                                    Spacer()
                                    if let sizeBytes = attachment.sizeBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.retraceSecondary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.075),
                                Color.white.opacity(0.038)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .padding(.trailing, 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            onHoverChanged(hovering)
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
