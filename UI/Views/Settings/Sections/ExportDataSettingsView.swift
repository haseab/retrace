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
    var exportDataSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            comingSoonCard
        }
    }

    // MARK: - Export & Data Cards (extracted for search)

    @ViewBuilder
    var comingSoonCard: some View {
        ModernSettingsCard(title: "Coming Soon", icon: "clock") {
            VStack(alignment: .leading, spacing: 8) {
                Text("These settings will be provided in the next update!")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Text("Major exporting and importing flexibility")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary.opacity(0.7))
            }
        }
    }

    // MARK: - Privacy Settings
}
