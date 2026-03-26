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
    @ViewBuilder
    var privateModeAutomationSetupSection: some View {
        let hasDeniedTargets = privateModeAutomationTargets.contains {
            privateModeAutomationPermissionStateByBundleID[$0.bundleID] == .denied
        }
        let hasNeedsConsentTargets = privateModeAutomationTargets.contains {
            privateModeAutomationPermissionStateByBundleID[$0.bundleID] == .needsConsent
        }
        let accessibilityState: InPageURLPermissionState = hasAccessibilityPermission ? .granted : .needsConsent

        VStack(alignment: .leading, spacing: 10) {
            Text("Step 1: Compatible browsers")
                .font(.retraceCaption2Bold)
                .foregroundColor(.retracePrimary)

            if privateModeAXCompatibleTargets.isEmpty {
                Text("No compatible browsers detected.")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(privateModeAXCompatibleTargets.enumerated()), id: \.element.bundleID) { index, target in
                        privateModeAXCompatibleBrowserRow(
                            target: target,
                            accessibilityState: accessibilityState
                        )
                        if index < privateModeAXCompatibleTargets.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            Text("Step 2: Grant Additional Permissions for these browsers")
                .font(.retraceCaption2Bold)
                .foregroundColor(.retracePrimary)

            if privateModeAutomationTargets.isEmpty {
                if isRefreshingPrivateModeAutomationTargets {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning for browsers that require mode-based private detection...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                } else {
                    Text("No installed browsers currently require `mode`-based private detection.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(privateModeAutomationTargets.enumerated()), id: \.element.bundleID) { index, target in
                        privateModeAutomationPermissionRow(target: target)
                        if index < privateModeAutomationTargets.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: {
                    Task { await refreshPrivateModeAutomationTargets(force: true) }
                }) {
                    HStack(spacing: 6) {
                        if isRefreshingPrivateModeAutomationTargets {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        Text(isRefreshingPrivateModeAutomationTargets ? "Refreshing..." : "Refresh Browser List")
                            .font(.retraceCaption2)
                    }
                    .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingPrivateModeAutomationTargets)
            }

            if hasDeniedTargets || hasNeedsConsentTargets {
                Text(hasDeniedTargets ? "One or more browsers are currently denied." : "At least one browser still needs Allow.")
                    .font(.retraceCaption2)
                    .foregroundColor(hasDeniedTargets ? .retraceDanger : .retraceWarning)
            }
        }
    }

    @ViewBuilder
    func privateModeAXCompatibleBrowserRow(
        target: PrivateModeAutomationTarget,
        accessibilityState: InPageURLPermissionState
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = inPageURLIconByBundleID[target.bundleID] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 20, height: 20)
                }
            }

            Text(target.displayName)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            inPageURLPermissionBadge(for: accessibilityState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            scheduleInPageURLIconLoad(bundleID: target.bundleID, appURL: target.appURL)
        }
    }

    @ViewBuilder
    func privateModeAutomationPermissionRow(target: PrivateModeAutomationTarget) -> some View {
        let permissionState = privateModeAutomationPermissionStateByBundleID[target.bundleID]
        let isRunning = privateModeAutomationRunningBundleIDs.contains(target.bundleID)
        let isGranted = permissionState == .granted
        let buttonTitle = isGranted ? "Change" : (isRunning ? "Allow" : "Launch")
        let buttonBusyTitle = isRunning ? "Allowing..." : "Launching..."

        HStack(spacing: 12) {
            Group {
                if let icon = inPageURLIconByBundleID[target.bundleID] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 20, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            inPageURLPermissionBadge(for: permissionState)

            Button(action: {
                if isGranted || permissionState == .denied {
                    openAutomationSettings()
                    recordPrivateWindowRedactionMetric(
                        action: isGranted ? "change_permission_open_settings" : "denied_permission_open_settings",
                        browserBundleID: target.bundleID,
                        permissionState: permissionState
                    )
                    return
                }

                Task {
                    if isRunning {
                        await requestPrivateModeAutomationPermission(for: target)
                    } else {
                        await launchPrivateModeAutomationTarget(target)
                    }
                }
            }) {
                if privateModeAutomationBusyBundleIDs.contains(target.bundleID) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(buttonBusyTitle)
                    }
                } else {
                    Text(buttonTitle)
                }
            }
            .font(.retraceCaption2Bold)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.retraceAccent.opacity(0.75))
            .cornerRadius(8)
            .buttonStyle(.plain)
            .disabled(privateModeAutomationBusyBundleIDs.contains(target.bundleID))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            scheduleInPageURLIconLoad(bundleID: target.bundleID, appURL: target.appURL)
        }
    }
}
