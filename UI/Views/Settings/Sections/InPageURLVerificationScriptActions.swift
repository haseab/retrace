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
    static var safariWikipediaProbeScriptLines: [String] {
        let targetNeedle = appleScriptEscapedForProbe(wikipediaProbeNeedle)
        return [
            "set __retraceNeedle to \"\(targetNeedle)\"",
            "tell application id \"com.apple.Safari\"",
            "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
            "set t to missing value",
            "set targetWindow to missing value",
            "if __retraceNeedle is not \"\" then",
            "repeat with w in windows",
            "repeat with candidateTab in tabs of w",
            "try",
            "set tabURL to URL of candidateTab",
            "if tabURL contains __retraceNeedle then",
            "set t to candidateTab",
            "set targetWindow to w",
            "exit repeat",
            "end if",
            "end try",
            "end repeat",
            "if t is not missing value then exit repeat",
            "end repeat",
            "end if",
            "if t is missing value then",
            "set targetWindow to front window",
            "set t to current tab of targetWindow",
            "end if",
            "if targetWindow is not missing value then",
            "set index of targetWindow to 1",
            "set current tab of targetWindow to t",
            "end if",
            "activate",
            "delay 0.25",
            "set pageURL to URL of t",
            "set scrapedURLValue to do JavaScript \"(()=>{const link=document.querySelector('a[href]'); return (link && link.href) ? String(link.href) : '';})()\" in t",
            "return pageURL & \"|\" & scrapedURLValue",
            "end tell"
        ]
    }

    static func chromiumWikipediaProbeScriptLines(
        bundleID: String,
        requiresTestPage: Bool
    ) -> [String] {
        let targetNeedle = requiresTestPage ? appleScriptEscapedForProbe(wikipediaProbeNeedle) : ""
        if bundleID == "company.thebrowser.Browser" {
            return [
                "set __retraceNeedle to \"\(targetNeedle)\"",
                "tell application id \"\(bundleID)\"",
                "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
                "set targetWindowIndex to missing value",
                "set targetTabID to missing value",
                "if __retraceNeedle is not \"\" then",
                "repeat with w in windows",
                "repeat with candidateTab in tabs of w",
                "try",
                "set tabURL to URL of candidateTab",
                "if tabURL contains __retraceNeedle then",
                "set targetWindowIndex to index of w",
                "set targetTabID to id of candidateTab",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "if targetTabID is not missing value then exit repeat",
                "end repeat",
                "end if",
                "if targetTabID is missing value then",
                "try",
                "set targetWindowIndex to 1",
                "set targetTabID to id of active tab of front window",
                "end try",
                "end if",
                "if targetTabID is missing value then",
                "repeat with w in windows",
                "repeat with candidateTab in tabs of w",
                "try",
                "set tabURL to URL of candidateTab",
                "if tabURL is not missing value and tabURL is not \"\" then",
                "set targetWindowIndex to index of w",
                "set targetTabID to id of candidateTab",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "if targetTabID is not missing value then exit repeat",
                "end repeat",
                "end if",
                "if targetTabID is missing value then return \"__NO_SCRIPTABLE_TAB__\"",
                "try",
                "set index of window targetWindowIndex to 1",
                "end try",
                "activate",
                "delay 0.25",
                "set pageURL to URL of (tab id targetTabID of window targetWindowIndex)",
                "set scrapedURLValue to execute (tab id targetTabID of window targetWindowIndex) javascript \"(()=>{const link=document.querySelector('a[href]'); return (link && link.href) ? String(link.href) : '';})()\"",
                "return pageURL & \"|\" & scrapedURLValue",
                "end tell"
            ]
        }

        if let hostBrowserBundleID = chromiumHostBrowserBundleID(for: bundleID),
           hostBrowserBundleID != bundleID {
            return [
                "set __retraceNeedle to \"\(targetNeedle)\"",
                "tell application id \"\(hostBrowserBundleID)\"",
                "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
                "set targetWindowIndex to -1",
                "set targetTabIndex to -1",
                "set wIndex to 1",
                "repeat with w in windows",
                "set tIndex to 1",
                "repeat with candidateTab in tabs of w",
                "try",
                "set tabURL to URL of candidateTab",
                "if tabURL contains __retraceNeedle then",
                "set targetWindowIndex to wIndex",
                "set targetTabIndex to tIndex",
                "exit repeat",
                "end if",
                "end try",
                "set tIndex to tIndex + 1",
                "end repeat",
                "if targetTabIndex is not -1 then exit repeat",
                "set wIndex to wIndex + 1",
                "end repeat",
                "if __retraceNeedle is not \"\" and targetTabIndex is -1 then return \"\(inPageURLNoMatchingWindowToken)\"",
                "if targetTabIndex is -1 then",
                "set targetWindowIndex to 1",
                "set targetTabIndex to 1",
                "end if",
                "try",
                "set index of window targetWindowIndex to 1",
                "end try",
                "activate",
                "delay 0.25",
                "set pageURL to URL of tab targetTabIndex of window targetWindowIndex",
                "set scrapedURLValue to execute tab targetTabIndex of window targetWindowIndex javascript \"(()=>{const link=document.querySelector('a[href]'); return (link && link.href) ? String(link.href) : '';})()\"",
                "return pageURL & \"|\" & scrapedURLValue",
                "end tell"
            ]
        }

        return [
            "set __retraceNeedle to \"\(targetNeedle)\"",
            "tell application id \"\(bundleID)\"",
            "if (count of windows) = 0 then return \"__NO_WINDOWS__\"",
            "set targetWindowIndex to -1",
            "set targetTabIndex to -1",
            "set wIndex to 1",
            "if __retraceNeedle is not \"\" then",
            "repeat with w in windows",
            "set tIndex to 1",
            "repeat with candidateTab in tabs of w",
            "try",
            "set tabURL to URL of candidateTab",
            "if tabURL contains __retraceNeedle then",
            "set targetWindowIndex to wIndex",
            "set targetTabIndex to tIndex",
            "exit repeat",
            "end if",
            "end try",
            "set tIndex to tIndex + 1",
            "end repeat",
            "if targetTabIndex is not -1 then exit repeat",
            "set wIndex to wIndex + 1",
            "end repeat",
            "end if",
            "if targetTabIndex is -1 then",
            "set targetWindowIndex to 1",
            "set targetTabIndex to 1",
            "end if",
            "try",
            "set index of window targetWindowIndex to 1",
            "end try",
            "activate",
            "delay 0.25",
            "set pageURL to URL of tab targetTabIndex of window targetWindowIndex",
            "set scrapedURLValue to execute tab targetTabIndex of window targetWindowIndex javascript \"(()=>{const link=document.querySelector('a[href]'); return (link && link.href) ? String(link.href) : '';})()\"",
            "return pageURL & \"|\" & scrapedURLValue",
            "end tell"
        ]
    }

    nonisolated static func chromiumHostBrowserBundleID(for bundleID: String) -> String? {
        InPageURLSettingsViewModel.chromiumHostBrowserBundleID(
            for: bundleID,
            hostBundleIDPrefixes: inPageURLChromiumHostBundleIDPrefixes
        )
    }

    nonisolated static func resolvedInPageURLAutomationBundleID(for bundleID: String) -> String {
        chromiumHostBrowserBundleID(for: bundleID) ?? bundleID
    }

    nonisolated static func isInPageURLChromiumWebAppBundleID(_ bundleID: String) -> Bool {
        InPageURLSettingsViewModel.isChromiumWebAppBundleID(
            bundleID,
            hostBundleIDPrefixes: inPageURLChromiumHostBundleIDPrefixes
        )
    }

    static func shouldUseDedicatedInPageURLTestPage(for bundleID: String) -> Bool {
        if bundleID == "company.thebrowser.Browser" {
            return false
        }
        let automationBundleID = resolvedInPageURLAutomationBundleID(for: bundleID)
        return automationBundleID == bundleID
    }

    static var wikipediaProbeNeedle: String {
        guard let parsedURL = URL(string: inPageURLTestURLString),
              let host = parsedURL.host?.lowercased() else {
            return "wikipedia.org/wiki/cat"
        }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalizedPath = parsedURL.path.lowercased()
        if normalizedPath.isEmpty || normalizedPath == "/" {
            return normalizedHost
        }
        return normalizedHost + normalizedPath
    }

    static func appleScriptEscapedForProbe(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func runAppleScript(
        lines: [String],
        timeoutSeconds: TimeInterval,
        logPrefix: String,
        attempt: Int,
        scriptMode: String
    ) async -> InPageURLAppleScriptRunResult {
        let task = Task.detached(priority: .userInitiated) {
            let startUptime = inPageURLVerificationNow()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = lines.flatMap { ["-e", $0] }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            Log.info(
                "\(logPrefix) stage=osascript_started attempt=\(attempt) scriptMode=\(scriptMode) timeoutSeconds=\(timeoutSeconds) lineCount=\(lines.count)",
                category: .ui
            )

            do {
                try process.run()
                Log.info(
                    "\(logPrefix) stage=osascript_process_launched attempt=\(attempt) scriptMode=\(scriptMode) pid=\(process.processIdentifier)",
                    category: .ui
                )
            } catch {
                let elapsedMs = (inPageURLVerificationNow() - startUptime) * 1000
                Log.warning(
                    "\(logPrefix) stage=osascript_launch_failed attempt=\(attempt) scriptMode=\(scriptMode) elapsedMs=\(inPageURLFormatMilliseconds(elapsedMs)) error=\(error.localizedDescription)",
                    category: .ui
                )
                return InPageURLAppleScriptRunResult(
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: -1,
                    didTimeOut: false,
                    elapsedMs: elapsedMs
                )
            }

            let didTimeOut = await waitForProcessExitOrTimeout(process: process, timeoutSeconds: timeoutSeconds)
            if didTimeOut {
                process.terminate()
                await waitForProcessExit(process)
            }

            let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let elapsedMs = (inPageURLVerificationNow() - startUptime) * 1000

            Log.info(
                "\(logPrefix) stage=osascript_finished attempt=\(attempt) scriptMode=\(scriptMode) elapsedMs=\(inPageURLFormatMilliseconds(elapsedMs)) exitCode=\(process.terminationStatus) didTimeOut=\(didTimeOut) stdoutBytes=\(stdoutData.count) stderrBytes=\(stderrData.count) stdoutPreview=\(inPageURLLogPreview(stdout)) stderrPreview=\(inPageURLLogPreview(stderr))",
                category: .ui
            )

            return InPageURLAppleScriptRunResult(
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus,
                didTimeOut: didTimeOut,
                elapsedMs: elapsedMs
            )
        }
        return await task.value
    }

    static func waitForProcessExit(_ process: Process) async {
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(15), clock: .continuous)
        }
    }

    static func waitForProcessExitOrTimeout(
        process: Process,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        final class ResumeState {
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }
        }

        let state = ResumeState()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                state.resumeOnce(continuation, value: false)
            }

            if !process.isRunning {
                state.resumeOnce(continuation, value: false)
                return
            }

            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(timeoutSeconds), clock: .continuous)
                state.resumeOnce(continuation, value: true)
            }
        }
    }
}
