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
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ContextMenuRow(title: "Copy Moment Link", icon: "link") {
                showMenu = false
                copyMomentLink()
            }

            ContextMenuRow(title: "Copy Image", icon: "doc.on.doc") {
                showMenu = false
                copyImageToClipboard()
            }

            ContextMenuRow(title: "Save Image", icon: "square.and.arrow.down") {
                showMenu = false
                saveImage()
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            ContextMenuRow(title: viewModel.areControlsHidden ? "Show Controls" : "Hide Controls", icon: viewModel.areControlsHidden ? "menubar.arrow.up.rectangle" : "menubar.arrow.down.rectangle", shortcut: "⌘H") {
                showMenu = false
                viewModel.toggleControlsVisibility()
            }

            ContextMenuRow(title: "Dashboard", icon: "square.grid.2x2", shortcut: "⌘⇧D") {
                showMenu = false
                openDashboard()
            }

            ContextMenuRow(title: "Settings", icon: "gear", shortcut: "⌘,") {
                showMenu = false
                openSettings()
            }
        }
    }

    // MARK: - Actions

    private func copyMomentLink() {
        guard let timestamp = viewModel.currentTimestamp else { return }

        if let url = DeeplinkHandler.generateTimelineLink(timestamp: timestamp) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            // Record deeplink copy metric with the URL
            DashboardViewModel.recordDeeplinkCopy(coordinator: coordinatorWrapper.coordinator, url: url.absoluteString)
        }
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

    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
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

        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = (actualVideoPath as NSString).lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

            if !FileManager.default.fileExists(atPath: symlinkPath) {
                do {
                    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                } catch {
                    completion(nil)
                    return
                }
            }
            url = URL(fileURLWithPath: symlinkPath)
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                Text(title)
                    .font(RetraceMenuStyle.font)
                    .foregroundColor(isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
