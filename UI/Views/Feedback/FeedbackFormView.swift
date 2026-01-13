import SwiftUI

// MARK: - Feedback Form View

public struct FeedbackFormView: View {

    // MARK: - Properties

    @StateObject private var viewModel = FeedbackViewModel()
    @Environment(\.dismiss) private var dismiss

    private let liveChatURL = URL(string: "https://retrace.to")!

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSubmitted {
                successView
            } else {
                formView
            }
        }
        .frame(width: 500)
        .background(Color.retraceBackground)
    }

    // MARK: - Form View

    private var formView: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            // Header
            header

            // Feedback Type Picker
            feedbackTypePicker

            // Description
            descriptionField

            // Diagnostics Preview
            diagnosticsSection

            // Screenshot Toggle
            screenshotToggle

            // Error
            if let error = viewModel.error {
                errorBanner(error)
            }

            // Actions
            actionButtons
        }
        .padding(.spacingL)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 24))
                    .foregroundColor(.retraceAccent)

                Text("Share Feedback")
                    .font(.retraceTitle2)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("Help us improve Retrace. Your feedback goes directly to the developer.")
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)
        }
    }

    // MARK: - Feedback Type

    private var feedbackTypePicker: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            Text("Type")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            HStack(spacing: .spacingS) {
                ForEach(FeedbackType.allCases) { type in
                    feedbackTypeButton(type)
                }
            }
        }
    }

    private func feedbackTypeButton(_ type: FeedbackType) -> some View {
        Button(action: { viewModel.feedbackType = type }) {
            HStack(spacing: .spacingS) {
                Image(systemName: type.icon)
                    .font(.system(size: 14))
                Text(type.rawValue)
                    .font(.retraceCaption)
            }
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)
            .background(
                viewModel.feedbackType == type
                    ? Color.retraceAccent.opacity(0.2)
                    : Color.retraceSecondaryBackground
            )
            .foregroundColor(
                viewModel.feedbackType == type
                    ? Color.retraceAccent
                    : Color.retracePrimary
            )
            .cornerRadius(.cornerRadiusM)
            .overlay(
                RoundedRectangle(cornerRadius: .cornerRadiusM)
                    .stroke(
                        viewModel.feedbackType == type
                            ? Color.retraceAccent
                            : Color.retraceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Description

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            Text("Description")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.description)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.spacingS)
                    .background(Color.retraceSecondaryBackground)
                    .cornerRadius(.cornerRadiusM)
                    .overlay(
                        RoundedRectangle(cornerRadius: .cornerRadiusM)
                            .stroke(Color.retraceBorder, lineWidth: 1)
                    )

                if viewModel.description.isEmpty {
                    Text(viewModel.feedbackType.placeholder)
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary.opacity(0.6))
                        .padding(.spacingM)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 120)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            HStack {
                Text("What's Included")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button(action: { viewModel.showDiagnosticsDetail.toggle() }) {
                    HStack(spacing: 4) {
                        Text(viewModel.showDiagnosticsDetail ? "Hide details" : "View details")
                            .font(.retraceCaption)
                        Image(systemName: viewModel.showDiagnosticsDetail ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.retraceAccent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: .spacingS) {
                // Summary items
                diagnosticItem(icon: "app.badge", text: "App version & build number")
                diagnosticItem(icon: "desktopcomputer", text: "macOS version & device model")
                diagnosticItem(icon: "cylinder", text: "Database stats (counts only, no content)")
                diagnosticItem(icon: "exclamationmark.triangle", text: "Recent error logs")

                // Expanded details
                if viewModel.showDiagnosticsDetail {
                    Divider()
                        .background(Color.retraceBorder)
                        .padding(.vertical, .spacingS)

                    if let diagnostics = viewModel.diagnostics {
                        Text(diagnostics.formattedText())
                            .font(.retraceMono)
                            .foregroundColor(.retraceSecondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: .spacingM) {
                        Button(action: { viewModel.copyDiagnostics() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(.retraceCaption)
                        }
                        .buttonStyle(RetraceSecondaryButtonStyle())
                    }
                }
            }
            .padding(.spacingM)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusM)
        }
    }

    private func diagnosticItem(icon: String, text: String) -> some View {
        HStack(spacing: .spacingS) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.retraceSuccess)

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.retraceSecondary)
                .frame(width: 16)

            Text(text)
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)
        }
    }

    // MARK: - Screenshot Toggle

    private var screenshotToggle: some View {
        Toggle(isOn: $viewModel.includeScreenshot) {
            HStack(spacing: .spacingS) {
                Image(systemName: "camera")
                    .foregroundColor(.retraceSecondary)
                Text("Include screenshot")
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: .spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.retraceDanger)
            Text(message)
                .font(.retraceCaption)
                .foregroundColor(.retraceDanger)
        }
        .padding(.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.retraceDanger.opacity(0.1))
        .cornerRadius(.cornerRadiusM)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: .spacingM) {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(RetraceSecondaryButtonStyle())

            Spacer()

            Button(action: { Task { await viewModel.submit() } }) {
                HStack(spacing: .spacingS) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(viewModel.isSubmitting ? "Sending..." : "Send Report")
                }
            }
            .buttonStyle(RetracePrimaryButtonStyle())
            .disabled(!viewModel.canSubmit)
        }
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: .spacingL) {
            Spacer()

            // Success icon
            ZStack {
                Circle()
                    .fill(Color.retraceSuccess.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.retraceSuccess)
            }

            VStack(spacing: .spacingS) {
                Text("Feedback Sent!")
                    .font(.retraceTitle2)
                    .foregroundColor(.retracePrimary)

                Text("Thanks for helping improve Retrace.")
                    .font(.retraceBody)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Live chat link
            VStack(spacing: .spacingM) {
                Text("Need a faster response?")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                Link(destination: liveChatURL) {
                    HStack(spacing: .spacingS) {
                        Image(systemName: "message.fill")
                        Text("Chat with us on retrace.to")
                    }
                    .font(.retraceBody)
                    .foregroundColor(.retraceAccent)
                }
            }

            Spacer()

            // Close button
            Button("Done") {
                dismiss()
            }
            .buttonStyle(RetracePrimaryButtonStyle())
        }
        .padding(.spacingXL)
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
