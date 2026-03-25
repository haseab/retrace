import SwiftUI
import AppKit

enum CommentContextPreviewStyle {
    static let previewWidth: CGFloat = 192
    static let previewHeight: CGFloat = 124
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let metadataRowMinHeight: CGFloat = 16
    static let sectionCornerRadius: CGFloat = 14
    static let collapsedColumnWidth: CGFloat = 164
    static let collapseButtonSize: CGFloat = 24
    static let collapseButtonHitArea: CGFloat = 34
    static let collapseButtonInset: CGFloat = 34
    static let expandedPreviewTrailingInset: CGFloat = 30
}

private enum CommentContextPreviewFormatters {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum CommentContextPreviewMetadataLayout {
    case inline
    case stacked
}

struct CommentContextPreviewCard<TagsContent: View, FooterContent: View>: View {
    let title: String
    let subtitle: String?
    let timestamp: Date
    let appBundleID: String?
    let previewImage: NSImage?
    let isPreviewLoading: Bool
    let shouldUseExpandedTitle: Bool
    let metadataLayout: CommentContextPreviewMetadataLayout
    let isCollapsed: Bool
    let onToggleCollapsed: (() -> Void)?
    let tagsContent: TagsContent
    let footerContent: FooterContent

    @State private var isHoveringCollapseButton = false

    init(
        title: String,
        subtitle: String?,
        timestamp: Date,
        appBundleID: String?,
        previewImage: NSImage?,
        isPreviewLoading: Bool,
        shouldUseExpandedTitle: Bool,
        metadataLayout: CommentContextPreviewMetadataLayout = .inline,
        isCollapsed: Bool = false,
        onToggleCollapsed: (() -> Void)? = nil,
        @ViewBuilder tagsContent: () -> TagsContent,
        @ViewBuilder footerContent: () -> FooterContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.previewImage = previewImage
        self.isPreviewLoading = isPreviewLoading
        self.shouldUseExpandedTitle = shouldUseExpandedTitle
        self.metadataLayout = metadataLayout
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
        self.tagsContent = tagsContent()
        self.footerContent = footerContent()
    }

    init(
        title: String,
        subtitle: String?,
        timestamp: Date,
        appBundleID: String?,
        previewImage: NSImage?,
        isPreviewLoading: Bool,
        shouldUseExpandedTitle: Bool,
        metadataLayout: CommentContextPreviewMetadataLayout = .inline,
        isCollapsed: Bool = false,
        onToggleCollapsed: (() -> Void)? = nil,
        @ViewBuilder tagsContent: () -> TagsContent
    ) where FooterContent == EmptyView {
        self.init(
            title: title,
            subtitle: subtitle,
            timestamp: timestamp,
            appBundleID: appBundleID,
            previewImage: previewImage,
            isPreviewLoading: isPreviewLoading,
            shouldUseExpandedTitle: shouldUseExpandedTitle,
            metadataLayout: metadataLayout,
            isCollapsed: isCollapsed,
            onToggleCollapsed: onToggleCollapsed,
            tagsContent: tagsContent,
            footerContent: { EmptyView() }
        )
    }

    var body: some View {
        CommentChromeSectionCard(cornerRadius: CommentContextPreviewStyle.sectionCornerRadius) {
            VStack(alignment: .leading, spacing: 10) {
                if isCollapsed {
                    collapsedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)),
                                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing))
                            )
                        )
                } else {
                    expandedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)),
                                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing))
                            )
                        )
                }

                footerContent
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onToggleCollapsed {
                collapseToggleButton(action: onToggleCollapsed)
                    .padding(10)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isCollapsed)
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: CommentContextPreviewStyle.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.96))
                    .lineLimit(2)
                    .padding(.leading, 4)

                HStack(alignment: .top, spacing: 10) {
                    previewAppIcon
                    previewTextStack(
                        titleLineLimit: shouldUseExpandedTitle ? 2 : 1,
                        showsSubtitle: true
                    )
                }

                expandedMetadataContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            previewSurface
                .frame(
                    width: CommentContextPreviewStyle.previewWidth,
                    height: CommentContextPreviewStyle.previewHeight
                )
                .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.expandedPreviewTrailingInset)
        }
    }

    private var collapsedContent: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.96))
                    .lineLimit(1)

                timestampLabel
            }
            .frame(
                width: CommentContextPreviewStyle.collapsedColumnWidth,
                alignment: .leading
            )

            previewAppIcon

            previewTextStack(
                titleLineLimit: shouldUseExpandedTitle ? 2 : 1,
                showsSubtitle: !shouldUseExpandedTitle
            )
                .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.collapseButtonInset)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }

    @ViewBuilder
    private var expandedMetadataContent: some View {
        switch metadataLayout {
        case .inline:
            HStack(alignment: .center, spacing: 12) {
                timestampLabel
                tagsContent
            }
            .frame(
                maxWidth: .infinity,
                minHeight: CommentContextPreviewStyle.metadataRowMinHeight,
                alignment: .leading
            )
        case .stacked:
            VStack(alignment: .leading, spacing: 10) {
                timestampLabel
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CommentContextPreviewStyle.metadataRowMinHeight,
                        alignment: .leading
                    )
                tagsContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timestampLabel: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.88))
                .frame(width: 14)

            Text(CommentContextPreviewFormatters.dateFormatter.string(from: timestamp))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.retraceSecondary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewTextStack(titleLineLimit: Int, showsSubtitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.97))
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsSubtitle,
               let subtitle,
               subtitle != title {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapseToggleButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(
                    isHoveringCollapseButton
                    ? Color.retracePrimary.opacity(0.98)
                    : Color.retraceSecondary.opacity(0.92)
                )
                .frame(
                    width: CommentContextPreviewStyle.collapseButtonSize,
                    height: CommentContextPreviewStyle.collapseButtonSize
                )
                .frame(
                    width: CommentContextPreviewStyle.collapseButtonHitArea,
                    height: CommentContextPreviewStyle.collapseButtonHitArea
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringCollapseButton = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private var previewAppIcon: some View {
        if let appBundleID {
            AppIconView(bundleID: appBundleID, size: 34)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if isPreviewLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.9))
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct CommentContextPreviewLoadingCard: View {
    let title: String
    let detail: String

    var body: some View {
        CommentChromeSectionCard(cornerRadius: CommentContextPreviewStyle.sectionCornerRadius) {
            HStack(alignment: .top, spacing: CommentContextPreviewStyle.sectionSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.96))
                        .padding(.leading, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.11))
                            .frame(width: 184, height: 14)

                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 108, height: 11)
                    }
                    .padding(.top, 2)

                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.07))
                        .frame(height: CommentContextPreviewStyle.metadataRowMinHeight)

                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.retraceSecondary.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.07))
                    .frame(
                        width: CommentContextPreviewStyle.previewWidth,
                        height: CommentContextPreviewStyle.previewHeight
                    )
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading preview")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.retraceSecondary.opacity(0.88))
                        }
                    )
            }
        }
    }
}
