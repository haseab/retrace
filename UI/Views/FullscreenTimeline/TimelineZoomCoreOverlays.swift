import Foundation
import SwiftUI
import Shared

extension View {
    func reverseMask<Mask: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask(
            Rectangle()
                .overlay(alignment: alignment) {
                    mask()
                        .blendMode(.destinationOut)
                }
        )
    }
}

struct ZoomTransitionOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let content: () -> Content

    var body: some View {
        let progress = viewModel.zoomTransitionProgress
        let blurOpacity = viewModel.zoomTransitionBlurOpacity

        let startRect = CGRect(
            x: zoomRegion.origin.x * containerSize.width,
            y: zoomRegion.origin.y * containerSize.height,
            width: zoomRegion.width * containerSize.width,
            height: zoomRegion.height * containerSize.height
        )

        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let endRect = CGRect(
            x: (containerSize.width - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        let currentRect = CGRect(
            x: lerp(startRect.origin.x, endRect.origin.x, progress),
            y: lerp(startRect.origin.y, endRect.origin.y, progress),
            width: lerp(startRect.width, endRect.width, progress),
            height: lerp(startRect.height, endRect.height, progress)
        )

        let currentScale = lerp(1.0, scaleToFit, progress)
        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            if blurOpacity > 0 {
                ZoomBackgroundOverlay()
                    .opacity(blurOpacity)
            }

            Color.black.opacity(0.6 * blurOpacity)
                .reverseMask {
                    Rectangle()
                        .frame(width: currentRect.width, height: currentRect.height)
                        .position(x: currentRect.midX, y: currentRect.midY)
                }

            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(currentScale, anchor: .center)
                .offset(
                    x: lerp(0, (containerSize.width / 2 - zoomCenterX) * scaleToFit, progress),
                    y: lerp(0, (containerSize.height / 2 - zoomCenterY) * scaleToFit, progress)
                )
                .frame(width: currentRect.width, height: currentRect.height)
                .clipped()
                .position(x: currentRect.midX, y: currentRect.midY)

            RoundedRectangle(cornerRadius: lerp(0, 8, progress))
                .stroke(Color.white.opacity(0.9), lineWidth: lerp(2, 3, progress))
                .frame(width: currentRect.width, height: currentRect.height)
                .position(x: currentRect.midX, y: currentRect.midY)
        }
        .allowsHitTesting(false)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

struct InverseRoundedRectCutout: Shape {
    var cutoutRect: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            .init(
                .init(cutoutRect.origin.x, cutoutRect.origin.y),
                .init(.init(cutoutRect.size.width, cutoutRect.size.height), cornerRadius)
            )
        }
        set {
            cutoutRect.origin.x = newValue.first.first
            cutoutRect.origin.y = newValue.first.second
            cutoutRect.size.width = newValue.second.first.first
            cutoutRect.size.height = newValue.second.first.second
            cornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: cutoutRect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}

struct ZoomUnifiedOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isTransitioning: Bool
    let isExitTransitioning: Bool
    let content: () -> Content

    @State private var animationProgress: CGFloat = 0
    @State private var frozenZoomSnapshot: NSImage?

    @MainActor
    private func startLocalTransitionAnimation() {
        animationProgress = 0
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                animationProgress = 1.0
            }
        }
    }

    @MainActor
    private func startExitAnimation() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            animationProgress = 0.0
        }
    }

    @ViewBuilder
    private func zoomedContentView() -> some View {
        if viewModel.isInLiveMode {
            ZStack {
                Color.black
                if let snapshot = frozenZoomSnapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.identity)
                } else {
                    content()
                        .transition(.identity)
                }
            }
        } else {
            ZStack {
                Color.black
                if let snapshot = frozenZoomSnapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.identity)
                } else {
                    content()
                        .transition(.identity)
                }
            }
        }
    }

    var body: some View {
        let progress: CGFloat = (isTransitioning || isExitTransitioning) ? animationProgress : 1.0
        let regionMinX = zoomRegion.origin.x
        let regionMinY = zoomRegion.origin.y

        let startRect = CGRect(
            x: actualFrameRect.origin.x + regionMinX * actualFrameRect.width,
            y: actualFrameRect.origin.y + regionMinY * actualFrameRect.height,
            width: zoomRegion.width * actualFrameRect.width,
            height: zoomRegion.height * actualFrameRect.height
        )

        let menuWidth: CGFloat = 180
        let menuGap: CGFloat = 30
        let maxWidth = containerSize.width * 0.70
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * actualFrameRect.width
        let regionHeight = zoomRegion.height * actualFrameRect.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit

        let availableWidth = containerSize.width - menuWidth - menuGap
        let endRect = CGRect(
            x: (availableWidth - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        let menuX = endRect.maxX + menuGap
        let menuY = endRect.midY

        let targetRect = CGRect(
            x: lerp(startRect.origin.x, endRect.origin.x, progress),
            y: lerp(startRect.origin.y, endRect.origin.y, progress),
            width: lerp(startRect.width, endRect.width, progress),
            height: lerp(startRect.height, endRect.height, progress)
        )
        let targetScale = lerp(1.0, scaleToFit, progress)
        let targetBlur = progress

        let zoomCenterX = actualFrameRect.origin.x + (zoomRegion.origin.x + zoomRegion.width / 2) * actualFrameRect.width
        let zoomCenterY = actualFrameRect.origin.y + (zoomRegion.origin.y + zoomRegion.height / 2) * actualFrameRect.height

        let scaledZoomCenterX = containerSize.width / 2 + (zoomCenterX - containerSize.width / 2) * scaleToFit
        let scaledZoomCenterY = containerSize.height / 2 + (zoomCenterY - containerSize.height / 2) * scaleToFit
        let finalOffsetX = endRect.midX - scaledZoomCenterX
        let finalOffsetY = endRect.midY - scaledZoomCenterY
        let targetOffsetX = lerp(0.0, finalOffsetX, progress)
        let targetOffsetY = lerp(0.0, finalOffsetY, progress)

        ZStack {
            if !isTransitioning && !isExitTransitioning {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Log.debug("[ZoomDismiss] Dismiss overlay tapped - exiting zoom region", category: .ui)
                        viewModel.exitZoomRegion()
                    }
            }

            Rectangle()
                .fill(.regularMaterial)
                .opacity(targetBlur * 0.3)
                .allowsHitTesting(false)

            InverseRoundedRectCutout(
                cutoutRect: targetRect,
                cornerRadius: 12
            )
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
                .frame(width: targetRect.width, height: targetRect.height)
                .position(x: targetRect.midX, y: targetRect.midY)
                .allowsHitTesting(false)

            zoomedContentView()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(targetScale, anchor: .center)
                .offset(x: targetOffsetX, y: targetOffsetY)
                .compositingGroup()
                .mask {
                    RoundedRectangle(cornerRadius: 12)
                        .frame(width: targetRect.width, height: targetRect.height)
                        .position(x: targetRect.midX, y: targetRect.midY)
                }
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.9), lineWidth: lerp(2, 3, progress))
                .frame(width: targetRect.width, height: targetRect.height)
                .position(x: targetRect.midX, y: targetRect.midY)
                .allowsHitTesting(false)

            if !isTransitioning && !isExitTransitioning && !viewModel.ocrNodes.isEmpty {
                ZoomedTextSelectionOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    containerSize: containerSize,
                    zoomedRect: endRect
                )

                ZoomedRedactedNodeRevealOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    zoomedRect: endRect
                )
                .allowsHitTesting(false)
            }

            ZoomActionMenu(
                viewModel: viewModel,
                zoomRegion: zoomRegion
            )
            .frame(width: menuWidth)
            .position(x: menuX + menuWidth / 2, y: menuY)
            .opacity(progress)
            .offset(x: lerp(30, 0, progress))
            .onTapGesture {
                Log.debug("[ZoomDismiss] Menu area tapped - ignoring", category: .ui)
            }
        }
        .allowsHitTesting(!isTransitioning && !isExitTransitioning)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: animationProgress)
        .animation(nil, value: viewModel.shiftDragDisplaySnapshotFrameID)
        .onAppear {
            frozenZoomSnapshot = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.shiftDragDisplaySnapshot

            if isTransitioning {
                startLocalTransitionAnimation()
            } else if isExitTransitioning {
                animationProgress = 1.0
                startExitAnimation()
            } else {
                animationProgress = 1.0
            }
        }
        .onChange(of: isTransitioning) { newValue in
            if newValue {
                frozenZoomSnapshot = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.shiftDragDisplaySnapshot
                startLocalTransitionAnimation()
            }
        }
        .onChange(of: isExitTransitioning) { newValue in
            if newValue {
                startExitAnimation()
            }
        }
        .onChange(of: viewModel.shiftDragDisplaySnapshot) { newValue in
            if (isTransitioning || !viewModel.isInLiveMode), let image = newValue {
                var noAnimationTransaction = Transaction()
                noAnimationTransaction.animation = nil
                withTransaction(noAnimationTransaction) {
                    frozenZoomSnapshot = image
                }
            }
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

struct ZoomActionMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZoomActionMenuRow(title: "Share", icon: "square.and.arrow.up") {
                shareZoomedImage()
            }

            ZoomActionMenuRow(title: "Copy Image", icon: "doc.on.doc") {
                copyZoomedImageToClipboard()
            }

            if hasTextInZoomRegion {
                ZoomActionMenuRow(title: "Copy Text", icon: "doc.on.clipboard") {
                    copyTextFromZoomRegion()
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            ZoomActionMenuRow(title: "Save Image", icon: "square.and.arrow.down") {
                saveZoomedImage()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .fill(RetraceMenuStyle.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
        )
    }

    private var hasTextInZoomRegion: Bool {
        !viewModel.ocrNodes.isEmpty && viewModel.ocrNodes.contains { node in
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = zoomRegion.origin.x + zoomRegion.width
            let regionBottom = zoomRegion.origin.y + zoomRegion.height

            return nodeRight > zoomRegion.origin.x &&
                   node.x < regionRight &&
                   nodeBottom > zoomRegion.origin.y &&
                   node.y < regionBottom
        }
    }

    private func shareZoomedImage() {
        getZoomedImage { image in
            guard let image = image else {
                return
            }

            let picker = NSSharingServicePicker(items: [image])
            if let window = NSApp.keyWindow,
               let contentView = window.contentView {
                let menuRect = CGRect(
                    x: contentView.bounds.width - 200,
                    y: contentView.bounds.height / 2,
                    width: 180,
                    height: 40
                )
                picker.show(relativeTo: menuRect, of: contentView, preferredEdge: .minX)

                for delay in [0.05, 0.1, 0.2, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        for appWindow in NSApp.windows {
                            let className = String(describing: type(of: appWindow))
                            let isStatusBar = className == "NSStatusBarWindow"
                            let isTimeline = className == "KeyableWindow"
                            let isDashboard = className == "NSWindow" && appWindow.level.rawValue == 0

                            if appWindow.level.rawValue < NSWindow.Level.screenSaver.rawValue &&
                               appWindow.isVisible &&
                               !isStatusBar &&
                               !isTimeline &&
                               !isDashboard {
                                appWindow.level = .screenSaver + 1
                            }
                        }
                    }
                }
            }
        }
    }

    private func copyZoomedImageToClipboard() {
        viewModel.copyZoomedRegionImage()
        viewModel.exitZoomRegion()
    }

    private func copyTextFromZoomRegion() {
        viewModel.copyZoomedRegionText()
        viewModel.exitZoomRegion()
    }

    private func saveZoomedImage() {
        getZoomedImage { image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            savePanel.nameFieldStringValue = "retrace-zoom-\(formattedTimestamp()).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                    }
                }
            }
        }
    }

    private func getZoomedImage(completion: @escaping (NSImage?) -> Void) {
        guard let fullImage = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.displayableCurrentImage else {
            completion(nil)
            return
        }

        let imageSize = fullImage.size
        let cropRect = CGRect(
            x: zoomRegion.origin.x * imageSize.width,
            y: zoomRegion.origin.y * imageSize.height,
            width: zoomRegion.width * imageSize.width,
            height: zoomRegion.height * imageSize.height
        )

        guard let cgImage = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(nil)
            return
        }

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            completion(nil)
            return
        }

        let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: cropRect.width, height: cropRect.height))
        completion(croppedImage)
    }

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: viewModel.currentTimestamp ?? Date())
    }
}

struct ZoomActionMenuRow: View {
    let title: String
    let icon: String
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

struct PureBlurView: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ZoomBackgroundOverlay: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ZoomFinalStateOverlay<Content: View>: View {
    let zoomRegion: CGRect
    let containerSize: CGSize
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let content: () -> Content

    var body: some View {
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let finalRect = CGRect(
            x: (containerSize.width - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            ZoomBackgroundOverlay()

            Color.black.opacity(0.6)
                .reverseMask {
                    Rectangle()
                        .frame(width: finalRect.width, height: finalRect.height)
                        .position(x: finalRect.midX, y: finalRect.midY)
                }

            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(scaleToFit, anchor: .center)
                .offset(
                    x: (containerSize.width / 2 - zoomCenterX) * scaleToFit,
                    y: (containerSize.height / 2 - zoomCenterY) * scaleToFit
                )
                .frame(width: finalRect.width, height: finalRect.height)
                .clipped()
                .position(x: finalRect.midX, y: finalRect.midY)

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: finalRect.width, height: finalRect.height)
                .position(x: finalRect.midX, y: finalRect.midY)

            if !viewModel.ocrNodes.isEmpty {
                ZoomedTextSelectionOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    containerSize: containerSize,
                    zoomedRect: finalRect
                )
            }
        }
    }
}

struct ZoomedRegionView<Content: View>: View {
    let zoomRegion: CGRect
    let containerSize: CGSize
    let content: () -> Content

    var body: some View {
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75

        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height

        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let contentScale = scaleToFit

        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(contentScale, anchor: .center)
                .offset(
                    x: (containerSize.width / 2 - zoomCenterX) * contentScale,
                    y: (containerSize.height / 2 - zoomCenterY) * contentScale
                )
                .frame(width: enlargedWidth, height: enlargedHeight)
                .clipped()

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: enlargedWidth, height: enlargedHeight)
        }
    }
}
