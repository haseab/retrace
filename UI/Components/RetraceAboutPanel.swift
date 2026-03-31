import AppKit
import SwiftUI

enum RetraceAboutPanel {
    struct Content {
        static let defaultWindowSize = NSSize(width: 480, height: 560)
        static let defaultDescriptionText =
            "Retrace is an open source, local-first screen memory for macOS. It continuously captures what you see, extracts text with on-device OCR, and makes your screen history searchable without sending it to the cloud."
        static let repositoryURL = URL(string: "https://github.com/haseab/retrace")!
        static let creatorURL = URL(string: "https://dub.sh/haseab-twitter")!

        let appName: String
        let versionText: String
        let branchText: String?
        let descriptionText: String
        let repositoryURL: URL
        let creatorURL: URL
        let windowSize: NSSize
    }

    static func makeContent(appName: String) -> Content {
        Content(
            appName: appName,
            versionText: BuildInfo.displayVersion,
            branchText: BuildInfo.displayBranch,
            descriptionText: Content.defaultDescriptionText,
            repositoryURL: Content.repositoryURL,
            creatorURL: Content.creatorURL,
            windowSize: Content.defaultWindowSize
        )
    }

    @MainActor
    static func makeWindow(appName: String) -> NSWindow {
        let content = makeContent(appName: appName)
        let hostingController = NSHostingController(rootView: RetraceAboutPanelView(content: content))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = "About \(appName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(content.windowSize)
        window.center()

        return window
    }
}

private struct RetraceAboutPanelView: View {
    let content: RetraceAboutPanel.Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 28)

                VStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)

                    VStack(spacing: 8) {
                        Text(content.appName)
                            .font(.system(size: 30, weight: .semibold))

                        Text("Local-first screen memory for macOS")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(content.versionText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        if let branchText = content.branchText {
                            Text(branchText)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                    .multilineTextAlignment(.center)
                }

                Divider()
                    .padding(.top, 28)

                VStack(spacing: 22) {
                    Text(content.descriptionText)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 390)

                    HStack(spacing: 12) {
                        aboutLink(
                            title: "Open Source Repo",
                            systemImage: "arrow.up.right.square",
                            url: content.repositoryURL
                        )
                        aboutLink(
                            title: "@haseab on X",
                            systemImage: "person.crop.circle",
                            url: content.creatorURL
                        )
                    }
                    .frame(maxWidth: 390)
                }
                .padding(.top, 28)

                Spacer(minLength: 28)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: content.windowSize.width, height: content.windowSize.height)
    }

    private func aboutLink(title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
