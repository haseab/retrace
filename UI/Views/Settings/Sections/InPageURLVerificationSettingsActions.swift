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
    @MainActor
    func openInPageURLTestLink(
        in bundleID: String,
        traceContext: InPageURLVerificationTraceContext
    ) {
        guard let url = URL(string: Self.inPageURLTestURLString),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logInPageURLVerification(
                traceContext,
                stage: "open_test_link_skipped",
                details: "reason=missing_url_or_app appBundleID=\(bundleID)"
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let openStartedAt = Self.inPageURLVerificationNow()

        Self.logInPageURLVerification(
            traceContext,
            stage: "open_test_link_started",
            details: "url=\(Self.inPageURLTestURLString) appPath=\(appURL.path)"
        )

        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                Self.logInPageURLVerification(
                    traceContext,
                    stage: "open_test_link_finished",
                    details: "success=false elapsedMs=\(Self.inPageURLElapsedMilliseconds(since: openStartedAt)) error=\(error.localizedDescription)"
                )
                Log.warning("[SettingsView] Failed to open in-page URL test link in \(bundleID): \(error.localizedDescription)", category: .ui)
            } else {
                Self.logInPageURLVerification(
                    traceContext,
                    stage: "open_test_link_finished",
                    details: "success=true elapsedMs=\(Self.inPageURLElapsedMilliseconds(since: openStartedAt))"
                )
                Log.info("[SettingsView] Opened in-page URL test link in \(bundleID)", category: .ui)
            }
        }

        recordInPageURLMetric(
            type: .inPageURLVerification,
            payload: [
                "phase": "open_test_link",
                "bundleID": bundleID,
                "url": Self.inPageURLTestURLString
            ]
        )
    }

    @MainActor
    func bringRetraceToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    @MainActor
    func runInPageURLVerification(for target: InPageURLBrowserTarget) async {
        let requiresTestPage = Self.shouldUseDedicatedInPageURLTestPage(for: target.bundleID)
        guard !inPageURLVerificationBusyBundleIDs.contains(target.bundleID) else {
            Log.info(
                "[InPageURL][SettingsTest][\(target.bundleID)] duplicate_request_ignored verificationMode=\(requiresTestPage ? "test_page" : "current_page")",
                category: .ui
            )
            return
        }

        let traceContext = Self.makeInPageURLVerificationTraceContext(
            target: target,
            requiresTestPage: requiresTestPage
        )
        let automationBundleID = Self.resolvedInPageURLAutomationBundleID(for: target.bundleID)
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty

        inPageURLVerificationBusyBundleIDs.insert(target.bundleID)
        inPageURLVerificationByBundleID[target.bundleID] = .pending
        inPageURLVerificationSummary = nil

        Self.logInPageURLVerification(
            traceContext,
            stage: "verification_started",
            details: "displayName=\(target.displayName) automationBundleID=\(automationBundleID) isRunning=\(isRunning) appURLPresent=\(target.appURL != nil)"
        )

        recordInPageURLMetric(
            type: .inPageURLVerification,
            payload: [
                "phase": "single_browser_started",
                "bundleID": target.bundleID,
                "verificationMode": requiresTestPage ? "test_page" : "current_page"
            ]
        )

        if requiresTestPage {
            openInPageURLTestLink(in: target.bundleID, traceContext: traceContext)
        } else {
            await activateInPageURLTargetForCurrentPageProbe(target, traceContext: traceContext)
        }

        let preProbeDelayMs = target.bundleID == "company.thebrowser.Browser" && !requiresTestPage ? 1000 : 1400

        Self.logInPageURLVerification(
            traceContext,
            stage: "pre_probe_wait_started",
            details: "delayMs=\(preProbeDelayMs)"
        )
        let preProbeWaitStart = Self.inPageURLVerificationNow()
        try? await Task.sleep(for: .milliseconds(preProbeDelayMs), clock: .continuous)
        Self.logInPageURLVerification(
            traceContext,
            stage: "pre_probe_wait_finished",
            details: "waitElapsedMs=\(Self.inPageURLElapsedMilliseconds(since: preProbeWaitStart))"
        )

        let result = await verifyInPageURLExtractionWithRetry(
            bundleID: target.bundleID,
            requiresTestPage: requiresTestPage,
            traceContext: traceContext
        )
        inPageURLVerificationByBundleID[target.bundleID] = result
        inPageURLVerificationBusyBundleIDs.remove(target.bundleID)
        refreshInPageURLVerificationSummary()
        bringRetraceToFront()

        Self.logInPageURLVerification(
            traceContext,
            stage: "verification_finished",
            details: "result=\(inPageURLVerificationDescription(result))"
        )

        recordInPageURLMetric(
            type: .inPageURLVerification,
            payload: [
                "phase": "single_browser_finished",
                "bundleID": target.bundleID,
                "verificationMode": requiresTestPage ? "test_page" : "current_page",
                "result": inPageURLVerificationDescription(result)
            ]
        )
    }

    @MainActor
    func activateInPageURLTargetForCurrentPageProbe(
        _ target: InPageURLBrowserTarget,
        traceContext: InPageURLVerificationTraceContext
    ) async {
        let activationStart = Self.inPageURLVerificationNow()
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first {
            let activated = runningApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            Self.logInPageURLVerification(
                traceContext,
                stage: "activate_current_page_probe_finished",
                details: "path=running_app activated=\(activated) elapsedMs=\(Self.inPageURLElapsedMilliseconds(since: activationStart))"
            )
            Log.info("[SettingsView] Activated \(target.bundleID) for current-page in-page URL probe (activated=\(activated))", category: .ui)
        } else if let appURL = target.appURL {
            Self.logInPageURLVerification(
                traceContext,
                stage: "activate_current_page_probe_started",
                details: "path=launch_app appPath=\(appURL.path)"
            )
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            Self.logInPageURLVerification(
                traceContext,
                stage: "activate_current_page_probe_finished",
                details: "path=launch_app elapsedMs=\(Self.inPageURLElapsedMilliseconds(since: activationStart))"
            )
            Log.info("[SettingsView] Launched \(target.bundleID) for current-page in-page URL probe", category: .ui)
        } else {
            Self.logInPageURLVerification(
                traceContext,
                stage: "activate_current_page_probe_skipped",
                details: "reason=no_running_app_and_no_app_url"
            )
        }

        recordInPageURLMetric(
            type: .inPageURLVerification,
            payload: [
                "phase": "activate_current_page_probe",
                "bundleID": target.bundleID
            ]
        )
    }

    @MainActor
    func refreshInPageURLVerificationSummary() {
        let grantedBundleIDs = inPageURLTargets
            .filter { inPageURLPermissionStateByBundleID[$0.bundleID] == .granted }
            .map(\.bundleID)

        guard !grantedBundleIDs.isEmpty else {
            inPageURLVerificationSummary = nil
            return
        }

        let finishedResults = grantedBundleIDs.compactMap { inPageURLVerificationByBundleID[$0] }
        guard !finishedResults.isEmpty else {
            inPageURLVerificationSummary = nil
            return
        }

        let allGrantedBrowsersPassed = grantedBundleIDs.allSatisfy { bundleID in
            guard let state = inPageURLVerificationByBundleID[bundleID] else { return false }
            if case .success = state { return true }
            return false
        }

        if allGrantedBrowsersPassed {
            inPageURLVerificationSummary = "Success: in-page URL extraction works for all granted browsers and apps."
        } else {
            inPageURLVerificationSummary = "Some browser or app tests failed. Review each row and retry."
        }
    }

    func verifyInPageURLExtractionWithRetry(
        bundleID: String,
        requiresTestPage: Bool,
        traceContext: InPageURLVerificationTraceContext
    ) async -> InPageURLVerificationState {
        let maxAttempts = bundleID == "company.thebrowser.Browser" && !requiresTestPage ? 1 : 6
        var latestResult: InPageURLVerificationState = .failed("Verification did not run")

        Self.logInPageURLVerification(
            traceContext,
            stage: "retry_loop_started",
            details: "maxAttempts=\(maxAttempts)"
        )

        for attempt in 1...maxAttempts {
            let attemptStart = Self.inPageURLVerificationNow()
            Self.logInPageURLVerification(
                traceContext,
                stage: "attempt_started",
                details: "attempt=\(attempt) of \(maxAttempts)"
            )
            latestResult = await verifyInPageURLExtraction(
                bundleID: bundleID,
                requiresTestPage: requiresTestPage,
                attempt: attempt,
                traceContext: traceContext
            )
            let shouldRetry = shouldRetryInPageURLVerification(latestResult) && attempt < maxAttempts
            Self.logInPageURLVerification(
                traceContext,
                stage: "attempt_finished",
                details: "attempt=\(attempt) result=\(inPageURLVerificationDescription(latestResult)) attemptElapsedMs=\(Self.inPageURLElapsedMilliseconds(since: attemptStart)) willRetry=\(shouldRetry)"
            )
            if !shouldRetry {
                return latestResult
            }

            Self.logInPageURLVerification(
                traceContext,
                stage: "retry_wait_started",
                details: "attempt=\(attempt) delayMs=700"
            )
            try? await Task.sleep(for: .milliseconds(700), clock: .continuous)
        }

        return latestResult
    }

    func shouldRetryInPageURLVerification(_ state: InPageURLVerificationState) -> Bool {
        switch state {
        case .pending, .success:
            return false
        case .warning(let message):
            return
                message.localizedCaseInsensitiveContains("Open \(Self.inPageURLTestURLString)") ||
                message.localizedCaseInsensitiveContains("No URLs detected")
        case .failed(let message):
            return
                message.localizedCaseInsensitiveContains("No browser window is open") ||
                message.localizedCaseInsensitiveContains("Timed out")
        }
    }

    func verifyInPageURLExtraction(
        bundleID: String,
        requiresTestPage: Bool,
        attempt: Int,
        traceContext: InPageURLVerificationTraceContext
    ) async -> InPageURLVerificationState {
        let hostBrowserBundleID = Self.chromiumHostBrowserBundleID(for: bundleID)
        let probeTimeoutSeconds: TimeInterval =
            bundleID == "company.thebrowser.Browser" && !requiresTestPage ? 8 : 25
        let (scriptMode, scriptLines): (String, [String]) = if bundleID == "com.apple.Safari" {
            ("safari", Self.safariWikipediaProbeScriptLines)
        } else if let hostBrowserBundleID, hostBrowserBundleID != bundleID {
            ("chromium_hosted_web_app", Self.chromiumWikipediaProbeScriptLines(
                bundleID: bundleID,
                requiresTestPage: requiresTestPage
            ))
        } else {
            ("chromium_direct", Self.chromiumWikipediaProbeScriptLines(
                bundleID: bundleID,
                requiresTestPage: requiresTestPage
            ))
        }

        Self.logInPageURLVerification(
            traceContext,
            stage: "probe_started",
            details: "attempt=\(attempt) scriptMode=\(scriptMode) hostBundleID=\(hostBrowserBundleID ?? "nil") scriptLines=\(scriptLines.count)"
        )

        let runResult = await Self.runAppleScript(
            lines: scriptLines,
            timeoutSeconds: probeTimeoutSeconds,
            logPrefix: traceContext.logPrefix,
            attempt: attempt,
            scriptMode: scriptMode
        )

        if runResult.didTimeOut {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_timeout",
                details: "attempt=\(attempt) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
            )
            return .failed("Timed out waiting for browser response. Open a url and try again")
        }

        if runResult.exitCode != 0 {
            let stderr = runResult.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_failed",
                details: "attempt=\(attempt) exitCode=\(runResult.exitCode) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs)) stderrPreview=\(Self.inPageURLLogPreview(stderr))"
            )
            if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
                return .failed("Automation permission denied")
            }
            if stderr.contains("Allow JavaScript from Apple Events") {
                return .warning(inPageURLJavaScriptFromAppleEventsReminder(for: bundleID))
            }
            return .failed(stderr.isEmpty ? "AppleScript failed (exit \(runResult.exitCode))" : stderr)
        }

        let output = runResult.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if output == "__NO_WINDOWS__" {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_no_windows",
                details: "attempt=\(attempt) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
            )
            return .failed("No browser window is open")
        }
        if output == "__NO_SCRIPTABLE_TAB__" {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_no_scriptable_tab",
                details: "attempt=\(attempt) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
            )
            return .warning("Open a normal Arc tab first")
        }
        if requiresTestPage && output == Self.inPageURLNoMatchingWindowToken {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_no_matching_window",
                details: "attempt=\(attempt) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
            )
            return .warning("Open \(Self.inPageURLTestURLString) first")
        }

        let parts = output.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_unexpected_output",
                details: "attempt=\(attempt) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs)) outputPreview=\(Self.inPageURLLogPreview(output))"
            )
            return .failed("Unexpected probe response")
        }

        let pageURL = String(parts[0])
        let scrapedURL = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresTestPage && !pageURL.localizedCaseInsensitiveContains("wikipedia.org/wiki/cat") {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_wrong_page",
                details: "attempt=\(attempt) pageURL=\(Self.inPageURLLogPreview(pageURL))"
            )
            return .warning("Open \(Self.inPageURLTestURLString) first (current: \(pageURL))")
        }

        if scrapedURL.isEmpty {
            Self.logInPageURLVerification(
                traceContext,
                stage: "probe_no_scraped_urls",
                details: "attempt=\(attempt) pageURL=\(Self.inPageURLLogPreview(pageURL)) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
            )
            Log.debug(
                "[SettingsView] In-page URL probe returned no scraped URLs for \(bundleID). rawOutput=\(output)",
                category: .ui
            )
            return .warning("No URLs detected on the current page")
        }

        Self.logInPageURLVerification(
            traceContext,
            stage: "probe_succeeded",
            details: "attempt=\(attempt) pageURL=\(Self.inPageURLLogPreview(pageURL)) scrapedURL=\(Self.inPageURLLogPreview(scrapedURL)) appleScriptElapsedMs=\(Self.inPageURLFormatMilliseconds(runResult.elapsedMs))"
        )

        if requiresTestPage {
            return .success("Scraped an in-page URL from \(pageURL)")
        }

        return .success("Scraped an in-page URL from the current page")
    }

    func inPageURLVerificationDescription(_ state: InPageURLVerificationState) -> String {
        switch state {
        case .pending:
            return "Checking..."
        case .success(let message):
            return message
        case .warning(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    nonisolated static func makeInPageURLVerificationTraceContext(
        target: InPageURLBrowserTarget,
        requiresTestPage: Bool
    ) -> InPageURLVerificationTraceContext {
        InPageURLVerificationTraceContext(
            traceID: String(UUID().uuidString.prefix(8)).lowercased(),
            bundleID: target.bundleID,
            displayName: target.displayName,
            verificationMode: requiresTestPage ? "test_page" : "current_page",
            startedAtUptime: inPageURLVerificationNow()
        )
    }

    nonisolated static func inPageURLVerificationNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    nonisolated static func inPageURLElapsedMilliseconds(since start: TimeInterval) -> String {
        inPageURLFormatMilliseconds((inPageURLVerificationNow() - start) * 1000)
    }

    nonisolated static func inPageURLFormatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    nonisolated static func inPageURLLogPreview(_ text: String, limit: Int = 180) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "..."
    }

    nonisolated static func logInPageURLVerification(
        _ traceContext: InPageURLVerificationTraceContext,
        stage: String,
        details: String
    ) {
        Log.info(
            "\(traceContext.logPrefix) stage=\(stage) totalElapsedMs=\(inPageURLElapsedMilliseconds(since: traceContext.startedAtUptime)) displayName=\(traceContext.displayName) verificationMode=\(traceContext.verificationMode) \(details)",
            category: .ui
        )
    }
}
