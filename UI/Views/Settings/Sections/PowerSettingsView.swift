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
    var powerSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Energy usage banner (informational, not a settings card)
            powerEnergyBanner

            Color.clear
                .frame(height: 0)
                .id(Self.powerOCRCardAnchorID)
            ocrProcessingCard

            appFilterCard

            Color.clear
                .frame(height: 0)
                .id(Self.powerOCRPriorityAnchorID)
            powerEfficiencyCard

            // Tips card (informational)
            powerTipsCard
        }
        .onAppear {
            updatePowerSourceStatus()
            loadOCRFilteredApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PowerSourceDidChange"))) { _ in
            updatePowerSourceStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            updatePowerSourceStatus()
        }
    }

    // MARK: - Power Cards (extracted for search)

    var powerEnergyBanner: some View {
        HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("OCR is the main source of energy usage")
                        .font(.retraceCalloutBold)
                        .foregroundColor(.retracePrimary)
                    Text("Screen recording uses minimal power. Text extraction (OCR) uses most CPU. Adjust settings below to reduce energy consumption.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    var ocrProcessingCard: some View {
        ModernSettingsCard(title: "OCR Processing", icon: "text.viewfinder") {
                VStack(spacing: 16) {
                    ModernToggleRow(
                        title: "Pause OCR",
                        subtitle: "Stop OCR for now; captured frames will be processed when resumed",
                        isOn: Binding(
                            get: { !ocrEnabled },
                            set: { shouldPause in
                                ocrEnabled = !shouldPause
                            }
                        )
                    )
                    .onChange(of: ocrEnabled) { _ in
                        notifyPowerSettingsChanged()
                    }

                    if !ocrEnabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                .foregroundColor(.orange)
                                .font(.system(size: 13))

                            VStack(alignment: .leading, spacing: 6) {
                                Text("OCR is paused. New frames are still captured and queued, then processed later when you resume.")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)

                                Button("Open System Monitor") {
                                    NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
                                }
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.retraceAccent)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.retraceCard)
                        .cornerRadius(8)
                    }

                    if ocrEnabled {
                        Divider()
                            .background(Color.retraceBorder)

                        ModernToggleRow(
                            title: "Process only when plugged in",
                            subtitle: "Queue OCR on battery, process when connected to power",
                            isOn: $ocrOnlyWhenPluggedIn
                        )
                        .onChange(of: ocrOnlyWhenPluggedIn) { _ in
                            notifyPowerSettingsChanged()
                        }

                        ModernToggleRow(
                            title: "Pause in Low Power Mode",
                            subtitle: "Queue OCR while macOS Low Power Mode is enabled",
                            isOn: $ocrPauseInLowPowerMode
                        )
                        .onChange(of: ocrPauseInLowPowerMode) { _ in
                            notifyPowerSettingsChanged()
                        }

                        // Show power status when plugged-in mode is enabled
                        if ocrOnlyWhenPluggedIn {
                            HStack(spacing: 8) {
                                Image(systemName: currentPowerSource == .ac ? "bolt.fill" : "battery.50")
                                    .foregroundColor(currentPowerSource == .ac ? .green : .orange)
                                    .font(.system(size: 14))
                                Text(currentPowerSource == .ac ? "On AC power - processing OCR" : "On battery - OCR queued")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.retraceCard)
                            .cornerRadius(8)
                        }

                        if ocrPauseInLowPowerMode {
                            HStack(spacing: 8) {
                                Image(systemName: isLowPowerModeEnabled ? "leaf.fill" : "leaf")
                                    .foregroundColor(isLowPowerModeEnabled ? .orange : .green)
                                    .font(.system(size: 14))
                                Text(isLowPowerModeEnabled ? "Low Power Mode is on - OCR queued" : "Low Power Mode is off - processing OCR")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.retraceCard)
                            .cornerRadius(8)
                        }
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color.retraceAccent.opacity(shellViewModel.isOCRCardHighlighted ? 0.92 : 0),
                    lineWidth: shellViewModel.isOCRCardHighlighted ? 2.5 : 0
                )
                .shadow(
                    color: Color.retraceAccent.opacity(shellViewModel.isOCRCardHighlighted ? 0.45 : 0),
                    radius: 12
                )
                .animation(.easeInOut(duration: 0.2), value: shellViewModel.isOCRCardHighlighted)
        }
    }

    @ViewBuilder
    var powerEfficiencyCard: some View {
        ModernSettingsCard(title: "Processing Speed", icon: "gauge.with.dots.needle.33percent") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("OCR Priority")
                                    .font(.retraceCalloutMedium)
                                    .foregroundColor(.retracePrimary)
                                Spacer()
                                Text(processingLevelDisplayText)
                                    .font(.retraceCalloutBold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(processingLevelColor.opacity(0.3))
                                    .cornerRadius(8)
                            }

                            // 5-level discrete slider: Efficiency (1) to Max (5)
                            ModernSlider(
                                value: Binding(
                                    get: { Double(ocrProcessingLevel) },
                                    set: { ocrProcessingLevel = Int($0) }
                                ),
                                range: 1...5,
                                step: 1
                            )
                                .onChange(of: ocrProcessingLevel) { _ in
                                    notifyPowerSettingsChanged()
                                }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    shellViewModel.isOCRPrioritySliderHighlighted
                                        ? Color.retraceAccent.opacity(0.15)
                                        : Color.white.opacity(0.02)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    Color.retraceAccent.opacity(shellViewModel.isOCRPrioritySliderHighlighted ? 0.94 : 0.10),
                                    lineWidth: shellViewModel.isOCRPrioritySliderHighlighted ? 2.8 : 1
                                )
                                .shadow(
                                    color: Color.retraceAccent.opacity(shellViewModel.isOCRPrioritySliderHighlighted ? 0.55 : 0),
                                    radius: 12
                                )
                        )
                        .animation(.easeInOut(duration: 0.2), value: shellViewModel.isOCRPrioritySliderHighlighted)

                        // CPU profile visualization
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 0) {
                                Text("CPU over time")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.retraceSecondary.opacity(0.5))
                                Spacer()
                                Text(processingLevelSummary)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.retraceSecondary.opacity(0.5))
                            }

                            cpuProfileGraph
                                .frame(height: cpuProfileGraphHeight)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(processingLevelBullets, id: \.self) { bullet in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•")
                                            .font(.retraceCaption2)
                                            .foregroundColor(.retraceSecondary.opacity(0.6))
                                        Text(bullet)
                                            .font(.retraceCaption2)
                                            .foregroundColor(.retraceSecondary)
                                    }
                                }
                            }
                            .frame(minHeight: processingLevelBulletsMinHeight, alignment: .top)
                        }

                        if ocrProcessingLevel != SettingsDefaults.ocrProcessingLevel {
                            HStack {
                                Spacer()
                                Button(action: {
                                    ocrProcessingLevel = SettingsDefaults.ocrProcessingLevel
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10))
                                        Text("Reset to default")
                                            .font(.retraceCaption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()
                            .background(Color.retraceBorder)

                        ModernToggleRow(
                            title: "Auto Max when idle & charging",
                            subtitle: "Boost to Max when screen is off, plugged in, and battery over 80%",
                            isOn: $autoMaxOCR
                        )
                        .onChange(of: autoMaxOCR) { _ in
                            notifyPowerSettingsChanged()
                        }

                    }
        }
    }

    @ViewBuilder
    var appFilterCard: some View {
        ModernSettingsCard(title: "App Filter", icon: "app.badge") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Skip OCR for specific apps to save power")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)

                        // Show selected apps as chips
                        if !ocrFilteredApps.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(ocrFilteredApps, id: \.bundleID) { app in
                                    HStack(spacing: 6) {
                                        // App icon
                                        if let icon = AppIconProvider.shared.icon(for: app.bundleID) {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                        } else {
                                            Image(systemName: "app.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.retraceSecondary)
                                        }
                                        Text(app.name)
                                            .font(.retraceCaption2Medium)
                                            .foregroundColor(.retracePrimary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        // Include/Exclude indicator
                                        Text(ocrAppFilterMode == .onlyTheseApps ? "only" : "skip")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(ocrAppFilterMode == .onlyTheseApps ? .green : .orange)
                                        Button(action: {
                                            removeOCRFilteredApp(app)
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.retraceSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.retraceCard)
                                    .cornerRadius(6)
                                    .fixedSize()
                                }
                            }
                        }

                        // Add app button with popover
                        Button(action: {
                            ocrFilteredAppsPopoverShown = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 14))
                                Text(ocrFilteredApps.isEmpty ? "Add apps to filter" : "Add more apps")
                                    .font(.retraceCaption2Medium)
                            }
                            .foregroundColor(.retraceAccent)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $ocrFilteredAppsPopoverShown) {
                            AppsFilterPopover(
                                apps: installedAppsForOCR,
                                otherApps: [],
                                selectedApps: Set(ocrFilteredApps.map(\.bundleID)),
                                filterMode: ocrAppFilterMode == .onlyTheseApps ? .include : .exclude,
                                allowMultiSelect: true,
                                showAllOption: false,
                                onSelectApp: { bundleID in
                                    guard let bundleID = bundleID else { return }
                                    toggleOCRFilteredApp(bundleID)
                                },
                                onFilterModeChange: { mode in
                                    ocrAppFilterMode = mode == .include ? .onlyTheseApps : .allExceptTheseApps
                                    notifyPowerSettingsChanged()
                                },
                                onDismiss: {
                                    ocrFilteredAppsPopoverShown = false
                                }
                            )
                        }

                        // Explanation of current mode
                        if !ocrFilteredApps.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: ocrAppFilterMode == .onlyTheseApps ? "checkmark.circle" : "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(ocrAppFilterMode == .onlyTheseApps ? .green : .orange)
                                Text(ocrAppFilterMode == .onlyTheseApps
                                     ? "OCR runs only for these apps"
                                     : "OCR skipped for these apps")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary.opacity(0.8))
                            }
                        }
                    }
                }
        }

    var powerTipsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 4) {
                Text("Tips for reducing energy usage")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retracePrimary)
                Text("• Lower the OCR rate to reduce fan noise\n• Use \"Process only when plugged in\" for laptops\n• Exclude apps where text search isn't needed")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08))
        .cornerRadius(10)
    }

    var processingLevelDisplayText: String {
        switch ocrProcessingLevel {
        case 1: return "Efficiency"
        case 2: return "Light"
        case 3: return "Balanced"
        case 4: return "Performance"
        case 5: return "Max"
        default: return "Balanced"
        }
    }

    var processingLevelColor: Color {
        switch ocrProcessingLevel {
        case 1: return .green
        case 2: return .green
        case 3: return .retraceAccent
        case 4: return .orange
        case 5: return .red
        default: return .retraceAccent
        }
    }

    var processingLevelSummary: String {
        switch ocrProcessingLevel {
        case 1: return "Low CPU, always running"
        case 2: return "Low CPU, mostly running"
        case 3: return "Moderate bursts, some idle"
        case 4: return "Intense bursts, more idle"
        case 5: return "Intense spikes, done fast"
        default: return "Moderate bursts, some idle"
        }
    }

    var cpuProfileGraphHeight: CGFloat { 44 }

    var processingLevelBulletsMinHeight: CGFloat { 58 }

    /// CPU usage profile pattern for each level
    /// Values represent relative CPU intensity (0–1) over time slices
    var cpuProfilePattern: [CGFloat] {
        switch ocrProcessingLevel {
        case 1: // Constant low hum, never stops
            return [0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19, 0.18, 0.20, 0.19]
        case 2: // Low steady with occasional tiny dips
            return [0.35, 0.38, 0.36, 0.34, 0.37, 0.35, 0.33, 0.36, 0.34, 0.08, 0.35, 0.37, 0.34, 0.36, 0.35, 0.33, 0.37, 0.35, 0.08, 0.34, 0.36, 0.35, 0.37, 0.34]
        case 3: // Moderate bursts with short idle gaps
            return [0.65, 0.70, 0.60, 0.55, 0.08, 0.08, 0.08, 0.60, 0.68, 0.65, 0.55, 0.08, 0.08, 0.08, 0.62, 0.70, 0.58, 0.08, 0.08, 0.08, 0.65, 0.68, 0.60, 0.08, 0.08, 0.08, 0.55, 0.62]
        case 4: // Tall spikes with longer idle periods
            return [0.85, 0.90, 0.80, 0.08, 0.08, 0.08, 0.08, 0.08, 0.82, 0.88, 0.85, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.86, 0.92, 0.80, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08]
        case 5: // Intense sharp spikes, lots of silence
            return [1.0, 0.95, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.92, 1.0, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.95, 1.0, 0.08, 0.08, 0.08, 0.08, 0.08]
        default:
            return [0.65, 0.70, 0.60, 0.55, 0.08, 0.08, 0.08, 0.60, 0.68, 0.65, 0.55, 0.08, 0.08, 0.08, 0.62, 0.70, 0.58, 0.08, 0.08, 0.08, 0.65, 0.68, 0.60, 0.08, 0.08, 0.08, 0.55, 0.62]
        }
    }

    @ViewBuilder
    var cpuProfileGraph: some View {
        let pattern = cpuProfilePattern
        let color = processingLevelColor
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("100")
                Spacer()
                Text("50")
                Spacer()
                Text("0")
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundColor(.retraceSecondary.opacity(0.45))
            .padding(.vertical, 3)

            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))

                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                        Spacer()
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                        Spacer()
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                    }
                    .padding(.vertical, 3)

                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(0..<pattern.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color.opacity(pattern[i] > 0.1 ? 0.72 : 0.18))
                                .frame(height: max(2, (geo.size.height - 6) * pattern[i]))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var processingLevelBullets: [String] {
        switch ocrProcessingLevel {
        case 1: return [
            "~0.5 frames/sec  ·  70–90% CPU",
            "Low CPU but always running — the queue will grow and never catch up",
            "Use if you rarely search for recent activity"
        ]
        case 2: return [
            "~1 frame/sec  ·  110–130% CPU",
            "Low intensity, mostly running — may fall behind during busy sessions but catches up when idle"
        ]
        case 3: return [
            "~1.5 frames/sec  ·  150–200% CPU  ·  1 worker",
            "Moderate bursts then idle — keeps up with most workflows",
            "Recommended for most users"
        ]
        case 4: return [
            "~2 frames/sec  ·  200–300% CPU",
            "Intense bursts then longer idle periods — stays current even during fast-paced work"
        ]
        case 5: return [
            "~3–4 frames/sec  ·  250–450% CPU  ·  2 workers",
            "Sharp spikes then done — everything is searchable almost instantly"
        ]
        default: return [
            "~1.5 frames/sec  ·  150–200% CPU  ·  1 worker",
            "Moderate bursts then idle — keeps up with most workflows",
            "Recommended for most users"
        ]
        }
    }

    var ocrFilteredApps: [ExcludedAppInfo] {
        guard !ocrFilteredAppsString.isEmpty,
              let data = ocrFilteredAppsString.data(using: .utf8),
              let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return []
        }
        return apps
    }

    func loadOCRFilteredApps() {
        // Load apps from capture history (database) - these have the actual bundle IDs
        // that match what's recorded during screen capture
        Task {
            do {
                let bundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let apps: [(bundleID: String, name: String)] = await Task.detached(
                    priority: .utility
                ) { () -> [(bundleID: String, name: String)] in
                    let resolvedApps = bundleIDs
                        .map { bundleID in
                            let name = AppNameResolver.shared.displayName(for: bundleID)
                            return (bundleID: bundleID, name: name)
                        }
                    return resolvedApps.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }.value

                await MainActor.run {
                    installedAppsForOCR = apps
                }
            } catch {
                Log.error("[SettingsView] Failed to load apps for OCR filter: \(error)", category: .ui)
                // Fallback to installed apps if database query fails
                let installed = AppNameResolver.shared.getInstalledApps()
                installedAppsForOCR = installed.map { (bundleID: $0.bundleID, name: $0.name) }
            }
        }
    }

    func addOCRFilteredApp(_ app: ExcludedAppInfo) {
        var apps = ocrFilteredApps
        if !apps.contains(where: { $0.bundleID == app.bundleID }) {
            apps.append(app)
            saveOCRFilteredApps(apps)
            notifyPowerSettingsChanged()
        }
    }

    func removeOCRFilteredApp(_ app: ExcludedAppInfo) {
        var apps = ocrFilteredApps
        apps.removeAll { $0.bundleID == app.bundleID }
        saveOCRFilteredApps(apps)
        // If no apps left, reset to "all apps" mode
        if apps.isEmpty {
            ocrAppFilterMode = .allApps
        }
        notifyPowerSettingsChanged()
    }

    func toggleOCRFilteredApp(_ bundleID: String) {
        var apps = ocrFilteredApps
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            // Remove if already selected
            apps.remove(at: index)
            // If no apps left, reset to "all apps" mode
            if apps.isEmpty {
                ocrAppFilterMode = .allApps
            }
        } else {
            // Add the app
            let name = installedAppsForOCR.first(where: { $0.bundleID == bundleID })?.name ?? bundleID
            apps.append(ExcludedAppInfo(bundleID: bundleID, name: name, iconPath: nil))
            // If mode is "allApps", switch to exclude mode when first app is added
            if ocrAppFilterMode == .allApps {
                ocrAppFilterMode = .allExceptTheseApps
            }
        }
        saveOCRFilteredApps(apps)
        notifyPowerSettingsChanged()
    }

    func saveOCRFilteredApps(_ apps: [ExcludedAppInfo]) {
        if let data = try? JSONEncoder().encode(apps),
           let string = String(data: data, encoding: .utf8) {
            ocrFilteredAppsString = string
        } else {
            ocrFilteredAppsString = ""
        }
    }


    func updatePowerSourceStatus() {
        currentPowerSource = PowerStateMonitor.shared.getCurrentPowerSource()
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func notifyPowerSettingsChanged() {
        let snapshot = OCRPowerSettingsSnapshot(
            ocrEnabled: ocrEnabled,
            pauseOnBattery: ocrOnlyWhenPluggedIn,
            pauseOnLowPowerMode: ocrPauseInLowPowerMode,
            processingLevel: ocrProcessingLevel,
            appFilterModeRaw: ocrAppFilterMode.rawValue,
            filteredAppsJSON: ocrFilteredAppsString,
            autoMaxOCR: autoMaxOCR
        )

        NotificationCenter.default.post(name: OCRPowerSettingsNotification.didChange, object: snapshot)
    }

    func resetPowerSettings() {
        ocrEnabled = SettingsDefaults.ocrEnabled
        ocrOnlyWhenPluggedIn = SettingsDefaults.ocrOnlyWhenPluggedIn
        ocrPauseInLowPowerMode = SettingsDefaults.ocrPauseInLowPowerMode
        ocrProcessingLevel = SettingsDefaults.ocrProcessingLevel
        ocrAppFilterMode = SettingsDefaults.ocrAppFilterMode
        ocrFilteredAppsString = SettingsDefaults.ocrFilteredApps
        autoMaxOCR = SettingsDefaults.autoMaxOCR
        notifyPowerSettingsChanged()
    }

    // MARK: - Tag Management Settings
}
