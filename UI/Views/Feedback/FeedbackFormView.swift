import SwiftUI

// MARK: - Feedback Form View

public struct FeedbackFormView: View {

    // MARK: - Properties

    @StateObject private var viewModel = FeedbackViewModel()
    @EnvironmentObject private var coordinatorWrapper: AppCoordinatorWrapper
    @Environment(\.dismiss) private var dismiss

    private let liveChatURL = URL(string: "https://retrace.to")!

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background with gradient orbs
            backgroundView

            // Content
            if viewModel.isSubmitted {
                successView
            } else {
                formView
            }
        }
        .frame(width: 480, height: 540)
        .onAppear {
            viewModel.setCoordinator(coordinatorWrapper)
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Color.retraceBackground

            // Subtle gradient orbs for depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.retraceAccent.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: -150, y: -200)
                .blur(radius: 50)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.06), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 180, y: 200)
                .blur(radius: 40)
        }
    }

    // MARK: - Form View

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            header

            // Feedback Type Picker
            feedbackTypeSection

            // Email
            emailSection

            // Description
            descriptionSection

            // Diagnostics Preview
            diagnosticsSection

            // Image Attachment
            imageAttachmentSection

            // Error
            if let error = viewModel.error {
                errorBanner(error)
            }

            Spacer(minLength: 0)

            // Actions
            actionButtons
        }
        .padding(20)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                        .frame(width: 36, height: 36)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LinearGradient.retraceAccentGradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Feedback")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.retracePrimary)

                    Text("Help us improve Retrace")
                        .font(.system(size: 11))
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Feedback Type Section

    private var feedbackTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            HStack(spacing: 8) {
                ForEach(FeedbackType.allCases) { type in
                    feedbackTypeButton(type)
                }
            }
        }
    }

    private func feedbackTypeButton(_ type: FeedbackType) -> some View {
        let isSelected = viewModel.feedbackType == type

        return Button(action: { viewModel.feedbackType = type }) {
            HStack(spacing: 5) {
                Image(systemName: type.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(type.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .retracePrimary : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.retraceAccent.opacity(0.15) : Color.white.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.retraceAccent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Email Section

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            TextField("your@email.com", text: $viewModel.email)
                .font(.retraceCaption)
                .foregroundColor(.retracePrimary)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            viewModel.showEmailError ? Color.retraceDanger.opacity(0.5) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )

            if viewModel.showEmailError {
                Text("Please enter a valid email address")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceDanger)
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.description)
                    .font(.retraceCaption)
                    .foregroundColor(.retracePrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )

                if viewModel.description.isEmpty {
                    Text(viewModel.feedbackType.placeholder)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary.opacity(0.5))
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                    Text("What's Included")
                        .font(.retraceCaptionBold)
                        .foregroundColor(.retracePrimary)
                }

                Spacer()

                Button(action: {
                    viewModel.showDiagnosticsDetail.toggle()
                    if viewModel.showDiagnosticsDetail {
                        viewModel.loadDiagnosticsIfNeeded()
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(viewModel.showDiagnosticsDetail ? "Hide" : "Details")
                            .font(.retraceCaption2Medium)
                        Image(systemName: viewModel.showDiagnosticsDetail ? "chevron.up" : "chevron.down")
                            .font(.retraceTinyBold)
                    }
                    .foregroundColor(.retraceAccent)
                }
                .buttonStyle(.plain)
            }

            // Compact summary - single line
            HStack(spacing: 12) {
                diagnosticChip(icon: "app.badge", text: "Version")
                diagnosticChip(icon: "desktopcomputer", text: "Device")
                diagnosticChip(icon: "cylinder", text: "Stats")
                diagnosticChip(icon: "doc.text", text: "Logs")
            }

            // Expanded details (lazy loaded)
            if viewModel.showDiagnosticsDetail {
                Divider()
                    .background(Color.white.opacity(0.06))

                if let diagnostics = viewModel.diagnostics {
                    Text(diagnostics.formattedText())
                        .font(.retraceMonoSmall)
                        .foregroundColor(.retraceSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: 100)
                } else {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading diagnostics...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func diagnosticChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.retraceSecondary)
    }

    // MARK: - Image Attachment Section

    @State private var isDropTargeted = false

    private var imageAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = viewModel.attachedImage {
                // Show attached image preview
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 50)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image attached")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.retracePrimary)
                        if let data = viewModel.attachedImageData {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                                .font(.system(size: 10))
                                .foregroundColor(.retraceSecondary)
                        }
                    }

                    Spacer()

                    Button(action: { viewModel.removeAttachedImage() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.retraceSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.retraceAccent.opacity(0.3), lineWidth: 1)
                )
            } else {
                // Drop zone / select button
                Button(action: { viewModel.selectImageFromFinder() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 12))
                            .foregroundColor(.retraceSecondary)
                        Text("Attach image")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                        Spacer()
                        Text("Drop or click")
                            .font(.system(size: 10))
                            .foregroundColor(.retraceSecondary.opacity(0.6))
                    }
                    .padding(10)
                    .background(isDropTargeted ? Color.retraceAccent.opacity(0.1) : Color.white.opacity(0.03))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isDropTargeted ? Color.retraceAccent.opacity(0.5) : Color.white.opacity(0.06),
                                style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [4])
                            )
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                    handleImageDrop(providers)
                }
            }
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try to load as image directly
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { image, error in
                if let nsImage = image as? NSImage {
                    Task { @MainActor in
                        viewModel.attachImage(nsImage)
                    }
                }
            }
            return true
        }

        // Try to load as file URL
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        viewModel.attachImage(from: url)
                    }
                }
            }
            return true
        }

        return false
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.retraceCallout)
                .foregroundColor(.retraceDanger)
            Text(message)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceDanger)
            Spacer()
        }
        .padding(14)
        .background(Color.retraceDanger.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.retraceDanger.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: { Task { await viewModel.submit() } }) {
                HStack(spacing: 8) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(viewModel.isSubmitting ? "Sending..." : "Send Feedback")
                        .font(.retraceCalloutBold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(viewModel.canSubmit ? Color.retraceAccent : Color.retraceAccent.opacity(0.4))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
        }
        .padding(.top, 4)
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Success icon with glow
            ZStack {
                Circle()
                    .fill(Color.retraceSuccess.opacity(0.15))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceSuccess.opacity(0.3), Color.retraceSuccess.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                Image(systemName: "checkmark")
                    .font(.retraceDisplay2)
                    .foregroundColor(.retraceSuccess)
            }

            VStack(spacing: 8) {
                Text("Feedback Sent!")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)

                Text("Thanks for helping improve Retrace.")
                    .font(.retraceBodyMedium)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Live chat link
            VStack(spacing: 14) {
                Text("Need a faster response?")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)

                Link(destination: liveChatURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.retraceCallout)
                        Text("Chat with us on retrace.to")
                            .font(.retraceCalloutMedium)
                    }
                    .foregroundColor(.retraceAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.retraceAccent.opacity(0.1))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.retraceAccent.opacity(0.3), lineWidth: 1)
                    )
                }
            }

            Spacer()

            // Close button
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(Color.retraceAccent)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(28)
    }
}

// MARK: - Preview

#if DEBUG
struct FeedbackFormView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackFormView()
            .preferredColorScheme(.dark)
    }
}
#endif
