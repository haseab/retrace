import SwiftUI
import AppKit
import AVFoundation
import Shared
import App

// MARK: - Shared Context Menu Content

/// Shared context menu content used by both the right-click floating menu and the three-dot menu
struct ContextMenuContent: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var showMenu: Bool
    var highlightControlsVisibilityRow: Bool = false
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ContextMenuRow(
                title: "Copy Moment Link",
                icon: "link",
                shortcut: "⌥⇧L",
                isDisabled: viewModel.isInLiveMode
            ) {
                showMenu = false
                copyMomentLink()
            }

            ContextMenuRow(
                title: "Copy URL Link",
                icon: "link",
                shortcut: "⌘L",
                isDisabled: viewModel.isInLiveMode || !hasCurrentBrowserURL
            ) {
                showMenu = false
                copyURLLink()
            }

            ContextMenuRow(title: "Copy Image", icon: "doc.on.doc", shortcut: "⌘C") {
                showMenu = false
                copyImageToClipboard()
            }

            ContextMenuRow(title: "Save Image", icon: "square.and.arrow.down", shortcut: "⌘S") {
                showMenu = false
                saveImage()
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            ContextMenuRow(
                title: viewModel.areControlsHidden ? "Show Controls" : "Hide Controls",
                icon: viewModel.areControlsHidden ? "menubar.arrow.up.rectangle" : "menubar.arrow.down.rectangle",
                shortcut: "⌘H",
                showGuideRing: highlightControlsVisibilityRow
            ) {
                showMenu = false
                viewModel.toggleControlsVisibility()
            }

            ContextMenuRow(title: "Dashboard", icon: "square.grid.2x2", shortcut: "⌘⇧D") {
                showMenu = false
                openDashboard()
            }

            ContextMenuRow(title: "System Monitor", icon: "waveform.path.ecg", shortcut: "⌘⇧M") {
                showMenu = false
                openSystemMonitor()
            }

            ContextMenuRow(title: "Get Help", icon: "exclamationmark.bubble", shortcut: "⌘⇧H") {
                showMenu = false
                openFeedback()
            }

            ContextMenuRow(title: "Settings", icon: "gear", shortcut: "⌘,") {
                showMenu = false
                openSettings()
            }
        }
    }

    // MARK: - Actions

    private var hasCurrentBrowserURL: Bool {
        guard let urlString = viewModel.currentFrame?.metadata.browserURL,
              !urlString.isEmpty else {
            return false
        }
        return URL(string: urlString) != nil
    }

    private func copyMomentLink() {
        guard !viewModel.isInLiveMode else { return }
        guard let timestamp = viewModel.currentTimestamp else { return }

        if let url = DeeplinkHandler.generateTimelineLink(timestamp: timestamp) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            // Record deeplink copy metric with the URL
            DashboardViewModel.recordDeeplinkCopy(coordinator: coordinatorWrapper.coordinator, url: url.absoluteString)
        }
    }

    private func copyURLLink() {
        _ = viewModel.copyCurrentBrowserURL()
    }

    private func saveImage() {
        let coordinator = coordinatorWrapper.coordinator
        let frameID = viewModel.currentFrame?.id.value
        getCurrentFrameImage { image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            savePanel.nameFieldStringValue = "retrace-\(formattedTimestamp()).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                        // Record image save metric with frame ID
                        DashboardViewModel.recordImageSave(coordinator: coordinator, frameID: frameID)
                    }
                }
            }
        }
    }

    private func copyImageToClipboard() {
        let coordinator = coordinatorWrapper.coordinator
        let frameID = viewModel.currentFrame?.id.value
        getCurrentFrameImage { image in
            guard let image = image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            // Record image copy metric with frame ID
            DashboardViewModel.recordImageCopy(coordinator: coordinator, frameID: frameID)
        }
    }

    private func openDashboard() {
        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openDashboard, object: nil)
            DashboardWindowController.shared.show()
        }
    }

    private func openSettings() {
        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openSettings, object: nil)
            DashboardWindowController.shared.show()
        }
    }

    private func openSystemMonitor() {
        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
        }
    }

    private func openFeedback() {
        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openFeedback, object: nil)
        }
    }

    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
        if viewModel.isInLiveMode {
            completion(viewModel.liveScreenshot)
            return
        }

        if let image = viewModel.currentImage {
            completion(image)
            return
        }

        guard let videoInfo = viewModel.currentVideoInfo else {
            completion(nil)
            return
        }

        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                completion(nil)
                return
            }
        }

        guard let url = MP4SymlinkResolver.resolveURL(for: actualVideoPath) else {
            completion(nil)
            return
        }

        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let time = videoInfo.frameTimeCMTime

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: viewModel.currentTimestamp ?? Date())
    }
}

// MARK: - Context Menu Row

/// Styled menu row for context menus - now uses unified RetraceMenuStyle
struct ContextMenuRow: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var showGuideRing: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var guidePulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(foregroundColor)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                Text(title)
                    .font(RetraceMenuStyle.font)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(RetraceMenuStyle.shortcutFont)
                        .foregroundColor(shortcutColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: RetraceMenuStyle.shortcutColumnMinWidth, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                        .fill(isHovering && !isDisabled ? RetraceMenuStyle.itemHoverColor : Color.clear)

                    if showGuideRing {
                        RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                            .stroke(
                                Color.yellow.opacity(guidePulse ? 0.95 : 0.7),
                                lineWidth: guidePulse ? 2.6 : 2.0
                            )
                            .shadow(
                                color: Color.yellow.opacity(guidePulse ? 0.45 : 0.25),
                                radius: guidePulse ? 8 : 5
                            )
                            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: guidePulse)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onAppear {
            if showGuideRing {
                guidePulse = true
            }
        }
        .onChange(of: showGuideRing) { isEnabled in
            if isEnabled {
                guidePulse = true
            } else {
                guidePulse = false
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering {
                if !isDisabled {
                    NSCursor.pointingHand.push()
                }
            } else if !isDisabled {
                NSCursor.pop()
            }
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return RetraceMenuStyle.textColorMuted.opacity(0.5)
        }
        return isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
    }

    private var shortcutColor: Color {
        if isDisabled {
            return RetraceMenuStyle.textColorMuted.opacity(0.4)
        }
        return .white.opacity(0.4)
    }
}
