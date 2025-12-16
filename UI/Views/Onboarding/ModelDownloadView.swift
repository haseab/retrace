import SwiftUI

/// Onboarding view for downloading AI models on first launch
/// Shows model information, download progress, and privacy assurance
/// Owner: UI module
struct ModelDownloadView: View {

    @StateObject private var viewModel = ModelDownloadViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)

                Text("Download AI Models")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Retrace needs to download AI models for local processing")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            // Privacy assurance
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("100% Local & Private")
                        .font(.headline)
                    Text("All processing happens on your Mac. No data leaves your device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)

            // Model list
            VStack(spacing: 12) {
                ForEach(viewModel.models, id: \.name) { model in
                    ModelRow(
                        model: model,
                        status: viewModel.modelStatuses[model.name],
                        progress: viewModel.downloadProgress[model.name]
                    )
                }
            }

            Spacer()

            // Total size
            HStack {
                Text("Total download size:")
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.totalSizeString)
                    .fontWeight(.semibold)
            }
            .font(.subheadline)

            // Action buttons
            HStack(spacing: 16) {
                Button("Skip for Now") {
                    viewModel.skip()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(action: {
                    Task {
                        await viewModel.downloadModels()
                    }
                }) {
                    HStack {
                        if viewModel.isDownloading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(viewModel.isDownloading ? "Downloading..." : "Download Models")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isDownloading || viewModel.allModelsDownloaded)
            }
            .padding(.bottom, 20)
        }
        .padding(32)
        .frame(width: 600, height: 550)
        .task {
            await viewModel.checkModelStatuses()
        }
        .onChange(of: viewModel.allModelsDownloaded) { allDownloaded in
            if allDownloaded && viewModel.isDownloading {
                // Auto-dismiss after successful download
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let model: ModelDownloadViewModel.ModelInfo
    let status: ModelDownloadViewModel.ModelStatus?
    let progress: ModelDownloadViewModel.DownloadProgress?

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 32)

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)

                Text(model.purpose)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status/Progress
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = progress {
                    Text("\(progress.downloadedMB) / \(progress.totalMB) MB")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ProgressView(value: progress.percentage)
                        .frame(width: 100)
                } else if status?.isDownloaded == true {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Downloaded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(model.sizeMB) MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var iconName: String {
        if progress != nil {
            return "arrow.down.circle"
        } else if status?.isDownloaded == true {
            return "checkmark.circle.fill"
        } else {
            return "circle"
        }
    }

    private var iconColor: Color {
        if progress != nil {
            return .blue
        } else if status?.isDownloaded == true {
            return .green
        } else {
            return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    ModelDownloadView()
}
