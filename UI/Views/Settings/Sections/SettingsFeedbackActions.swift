import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

extension SettingsView {
    func recordInPageURLMetric(
        type: DailyMetricsQueries.MetricType,
        payload: [String: Any]
    ) {
        Task {
            let metadata = Self.inPageURLMetricMetadata(payload)
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: type,
                metadata: metadata
            )
        }
    }

    func recordPrivateWindowRedactionMetric(
        action: String,
        browserBundleID: String?,
        permissionState: InPageURLPermissionState?
    ) {
        Task {
            var payload: [String: Any] = [
                "action": action
            ]
            if let browserBundleID {
                payload["bundleID"] = browserBundleID
            }
            if let permissionState {
                payload["permission"] = inPageURLPermissionDescription(for: permissionState)
            }

            let metadata = Self.inPageURLMetricMetadata(payload)
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .privateWindowRedactionToggle,
                metadata: metadata
            )
        }
    }

    func recordRewindCutoffMetric(_ cutoffDate: Date) {
        Task {
            let metadata = Self.inPageURLMetricMetadata([
                "cutoffTimestampMs": Int64(cutoffDate.timeIntervalSince1970 * 1000)
            ])
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .rewindCutoffDateUpdated,
                metadata: metadata
            )
        }
    }

    func applyRewindCutoffDate(_ cutoffDate: Date) {
        guard cutoffDate != rewindCutoffDateSelection else {
            return
        }

        rewindCutoffDateSelection = cutoffDate
        settingsStore.set(cutoffDate, forKey: rewindCutoffDateDefaultsKey)
        Log.info("Updated Rewind cutoff date to: \(cutoffDate)", category: .ui)
        recordRewindCutoffMetric(cutoffDate)
        rewindCutoffRefreshTask?.cancel()
        isRefreshingRewindCutoff = true

        let shouldRefreshLiveSource = useRewindData
        rewindCutoffRefreshTask = Task {
            if shouldRefreshLiveSource {
                let refreshed = await coordinatorWrapper.coordinator.refreshRewindCutoffDate()
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    isRefreshingRewindCutoff = false
                    if refreshed {
                        SearchViewModel.clearPersistedSearchCache()
                        NotificationCenter.default.post(name: .dataSourceDidChange, object: nil)
                        Log.info("✓ Timeline notified of Rewind cutoff change", category: .ui)
                        showSettingsToast("Rewind cutoff updated")
                    } else {
                        showSettingsToast("Saved cutoff, but couldn't refresh Rewind data", isError: true)
                    }
                }
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                isRefreshingRewindCutoff = false
                showSettingsToast("Rewind cutoff saved")
            }
        }
    }

    @MainActor
    func showSettingsToast(
        _ message: String,
        isError: Bool = false,
        duration: Duration = .seconds(2.4)
    ) {
        settingsToastDismissTask?.cancel()
        settingsToastMessage = message
        settingsToastIsError = isError

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            settingsToastVisible = true
        }

        settingsToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.18)) {
                settingsToastVisible = false
            }

            try? await Task.sleep(for: .seconds(0.2))
            guard !Task.isCancelled else { return }

            settingsToastMessage = nil
            settingsToastIsError = false
        }
    }

    static func inPageURLMetricMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

}

private struct InPageURLInstructionImageBox: @unchecked Sendable {
    let image: NSImage?
}

private enum InPageURLInstructionAssetLoadState {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

private actor InPageURLInstructionImageLoader {
    static let shared = InPageURLInstructionImageLoader()

    private var cache: [String: InPageURLInstructionImageBox] = [:]

    func load(
        assetName: String,
        fileName: String,
        logName: String
    ) -> InPageURLInstructionImageBox {
        let cacheKey = "\(assetName)|\(fileName)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let loaded = InPageURLInstructionImageBox(
            image: Self.resolveInstructionImageSync(
                assetName: assetName,
                fileName: fileName,
                logName: logName
            )
        )
        if loaded.image != nil {
            cache[cacheKey] = loaded
        }
        return loaded
    }

    nonisolated private static func resolveInstructionImageSync(
        assetName: String,
        fileName: String,
        logName: String
    ) -> NSImage? {
        let imageName = NSImage.Name(assetName)

        if let image = NSImage(named: imageName) {
            Log.info("[SettingsView] Loaded \(logName) via NSImage(named:)", category: .ui)
            return image
        }

        if let image = Bundle.main.image(forResource: imageName) {
            Log.info("[SettingsView] Loaded \(logName) via Bundle.main.image(forResource:)", category: .ui)
            return image
        }

#if SWIFT_PACKAGE
        if let image = Bundle.module.image(forResource: imageName) {
            Log.info("[SettingsView] Loaded \(logName) via Bundle.module.image(forResource:)", category: .ui)
            return image
        }
#endif

        let fileManager = FileManager.default
        let resourcePath = Bundle.main.resourcePath ?? ""
        let bundleCandidates: [(label: String, path: String)] = [
            ("bundle/\(fileName)", "\(resourcePath)/\(fileName)"),
            ("bundle/Assets.xcassets/\(assetName).imageset/\(fileName)", "\(resourcePath)/Assets.xcassets/\(assetName).imageset/\(fileName)")
        ]

        for candidate in bundleCandidates where fileManager.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOfFile: candidate.path) {
                Log.warning("[SettingsView] Loaded \(logName) via file fallback \(candidate.label)", category: .ui)
                return image
            }
        }

#if SWIFT_PACKAGE
        let moduleResourcePath = Bundle.module.resourcePath ?? ""
        let moduleCandidates: [(label: String, path: String)] = [
            ("module/\(fileName)", "\(moduleResourcePath)/\(fileName)"),
            ("module/Assets.xcassets/\(assetName).imageset/\(fileName)", "\(moduleResourcePath)/Assets.xcassets/\(assetName).imageset/\(fileName)")
        ]

        for candidate in moduleCandidates where fileManager.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOfFile: candidate.path) {
                Log.warning("[SettingsView] Loaded \(logName) via SwiftPM module file fallback \(candidate.label)", category: .ui)
                return image
            }
        }
#endif

        let debugWorkingTreePath = "\(fileManager.currentDirectoryPath)/UI/Assets.xcassets/\(assetName).imageset/\(fileName)"
        if fileManager.fileExists(atPath: debugWorkingTreePath),
           let image = NSImage(contentsOfFile: debugWorkingTreePath) {
            Log.warning("[SettingsView] Loaded \(logName) via working-tree fallback path", category: .ui)
            return image
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let bundlePath = Bundle.main.bundlePath
        let hasAssetsCar = fileManager.fileExists(atPath: "\(resourcePath)/Assets.car")
        let candidateSummary = bundleCandidates
            .map { "\($0.label)=\(fileManager.fileExists(atPath: $0.path) ? "exists" : "missing")" }
            .joined(separator: ",")

        Log.error(
            "[SettingsView] \(logName) missing. bundleID=\(bundleID), bundlePath=\(bundlePath), hasAssetsCar=\(hasAssetsCar), fileCandidates=\(candidateSummary)",
            category: .ui
        )

        return nil
    }
}

struct InPageURLInstructionAssetView: View {
    let assetName: String
    let fileName: String
    let logName: String

    @State private var loadState: InPageURLInstructionAssetLoadState = .idle

    var body: some View {
        Group {
            switch loadState {
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 760)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: 760, alignment: .leading)
            case .failed:
                EmptyView()
            }
        }
        .task(id: "\(assetName)|\(fileName)") {
            let shouldLoad = await MainActor.run {
                guard case .idle = loadState else { return false }
                loadState = .loading
                return true
            }
            guard shouldLoad else {
                return
            }

            let loaded = await InPageURLInstructionImageLoader.shared.load(
                assetName: assetName,
                fileName: fileName,
                logName: logName
            )
            guard !Task.isCancelled else {
                await MainActor.run {
                    loadState = .idle
                }
                return
            }

            await MainActor.run {
                if let image = loaded.image {
                    loadState = .loaded(image)
                } else {
                    loadState = .failed
                }
            }
        }
    }
}
