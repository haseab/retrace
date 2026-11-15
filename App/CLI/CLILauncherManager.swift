import Foundation
import Shared

public struct CLILauncherStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case unsupportedAppLocation
        case bundledCLIMissing
        case notInstalled
        case installed
        case needsRepair
    }

    public let state: State
    public let currentAppBundlePath: String
    public let supportedAppBundlePath: String
    public let bundledCLIExecutablePath: String
    public let launcherPath: String
    public let detail: String

    public init(
        state: State,
        currentAppBundlePath: String,
        supportedAppBundlePath: String,
        bundledCLIExecutablePath: String,
        launcherPath: String,
        detail: String
    ) {
        self.state = state
        self.currentAppBundlePath = currentAppBundlePath
        self.supportedAppBundlePath = supportedAppBundlePath
        self.bundledCLIExecutablePath = bundledCLIExecutablePath
        self.launcherPath = launcherPath
        self.detail = detail
    }

    public var launcherExistsOrNeedsRepair: Bool {
        state == .installed || state == .needsRepair
    }
}

public struct CLILauncherOperationResult: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case install
        case repair
        case remove
    }

    public let action: Action
    public let launcherPath: String
    public let usedPrivileges: Bool

    public init(action: Action, launcherPath: String, usedPrivileges: Bool) {
        self.action = action
        self.launcherPath = launcherPath
        self.usedPrivileges = usedPrivileges
    }
}

public enum CLILauncherManagerError: LocalizedError, Sendable, Equatable {
    case unsupportedAppLocation(currentPath: String, supportedPath: String)
    case bundledCLIMissing(String)
    case privilegedOperationCancelled
    case privilegedOperationFailed(String)
    case launcherWriteFailed(String)
    case launcherRemoveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAppLocation(let currentPath, let supportedPath):
            return "Retrace CLI installation is only supported when Retrace.app is installed at \(supportedPath). Current location: \(currentPath)."
        case .bundledCLIMissing(let path):
            return "The bundled RetraceCLI executable was not found at \(path)."
        case .privilegedOperationCancelled:
            return "Administrator authorization was cancelled."
        case .privilegedOperationFailed(let message):
            return message
        case .launcherWriteFailed(let path):
            return "Couldn't install the terminal command at \(path)."
        case .launcherRemoveFailed(let path):
            return "Couldn't remove the terminal command at \(path)."
        }
    }
}

public struct CLILauncherManager {
    public typealias PrivilegedCommandRunner = (String) throws -> Void

    public static let defaultSupportedAppBundlePath = "/Applications/Retrace.app"
    public static let defaultLauncherPath = "/usr/local/bin/retrace"

    private let fileManager: FileManager
    private let supportedAppBundlePath: String
    private let launcherPath: String
    private let currentAppBundlePathProvider: () -> String
    private let privilegedCommandRunner: PrivilegedCommandRunner

    public init(
        fileManager: FileManager = .default,
        supportedAppBundlePath: String = defaultSupportedAppBundlePath,
        launcherPath: String = defaultLauncherPath,
        currentAppBundlePathProvider: @escaping () -> String = { Bundle.main.bundlePath },
        privilegedCommandRunner: @escaping PrivilegedCommandRunner = Self.runPrivilegedShellCommand
    ) {
        self.fileManager = fileManager
        self.supportedAppBundlePath = Self.normalizedPath(supportedAppBundlePath)
        self.launcherPath = Self.normalizedPath(launcherPath)
        self.currentAppBundlePathProvider = currentAppBundlePathProvider
        self.privilegedCommandRunner = privilegedCommandRunner
    }

    public var bundledCLIExecutablePath: String {
        "\(supportedAppBundlePath)/Contents/MacOS/RetraceCLI"
    }

    public var expectedWrapperScript: String {
        """
        #!/bin/sh
        exec "\(bundledCLIExecutablePath)" "$@"
        """
        + "\n"
    }

    public func status() -> CLILauncherStatus {
        let currentAppBundlePath = Self.normalizedPath(currentAppBundlePathProvider())
        let bundledCLIExecutablePath = Self.normalizedPath(self.bundledCLIExecutablePath)
        let launcherPath = Self.normalizedPath(self.launcherPath)

        guard currentAppBundlePath == supportedAppBundlePath else {
            return CLILauncherStatus(
                state: .unsupportedAppLocation,
                currentAppBundlePath: currentAppBundlePath,
                supportedAppBundlePath: supportedAppBundlePath,
                bundledCLIExecutablePath: bundledCLIExecutablePath,
                launcherPath: launcherPath,
                detail: "Move Retrace.app to /Applications to install the `retrace` terminal command."
            )
        }

        guard fileManager.isExecutableFile(atPath: bundledCLIExecutablePath) else {
            return CLILauncherStatus(
                state: .bundledCLIMissing,
                currentAppBundlePath: currentAppBundlePath,
                supportedAppBundlePath: supportedAppBundlePath,
                bundledCLIExecutablePath: bundledCLIExecutablePath,
                launcherPath: launcherPath,
                detail: "RetraceCLI is not bundled inside the installed app yet."
            )
        }

        guard fileManager.fileExists(atPath: launcherPath) else {
            return CLILauncherStatus(
                state: .notInstalled,
                currentAppBundlePath: currentAppBundlePath,
                supportedAppBundlePath: supportedAppBundlePath,
                bundledCLIExecutablePath: bundledCLIExecutablePath,
                launcherPath: launcherPath,
                detail: "The terminal launcher is not installed."
            )
        }

        guard let installedLauncherContents = try? String(contentsOfFile: launcherPath, encoding: .utf8),
              installedLauncherContents == expectedWrapperScript else {
            return CLILauncherStatus(
                state: .needsRepair,
                currentAppBundlePath: currentAppBundlePath,
                supportedAppBundlePath: supportedAppBundlePath,
                bundledCLIExecutablePath: bundledCLIExecutablePath,
                launcherPath: launcherPath,
                detail: "The installed terminal launcher needs repair."
            )
        }

        return CLILauncherStatus(
            state: .installed,
            currentAppBundlePath: currentAppBundlePath,
            supportedAppBundlePath: supportedAppBundlePath,
            bundledCLIExecutablePath: bundledCLIExecutablePath,
            launcherPath: launcherPath,
            detail: "The `retrace` terminal command is installed and ready."
        )
    }

    public func installLauncher() throws -> CLILauncherOperationResult {
        try validateInstallEnvironment()
        let usedPrivileges = try writeLauncherScript()
        return CLILauncherOperationResult(
            action: .install,
            launcherPath: launcherPath,
            usedPrivileges: usedPrivileges
        )
    }

    public func repairLauncher() throws -> CLILauncherOperationResult {
        try validateInstallEnvironment()
        let usedPrivileges = try writeLauncherScript()
        return CLILauncherOperationResult(
            action: .repair,
            launcherPath: launcherPath,
            usedPrivileges: usedPrivileges
        )
    }

    public func removeLauncher() throws -> CLILauncherOperationResult {
        let launcherURL = URL(fileURLWithPath: launcherPath)

        guard fileManager.fileExists(atPath: launcherPath) else {
            return CLILauncherOperationResult(action: .remove, launcherPath: launcherPath, usedPrivileges: false)
        }

        do {
            try fileManager.removeItem(at: launcherURL)
            return CLILauncherOperationResult(action: .remove, launcherPath: launcherPath, usedPrivileges: false)
        } catch {
            guard Self.requiresPrivileges(for: error) else {
                throw CLILauncherManagerError.launcherRemoveFailed(launcherPath)
            }
        }

        do {
            try privilegedCommandRunner("/bin/rm -f \(Self.shQuote(launcherPath))")
            return CLILauncherOperationResult(action: .remove, launcherPath: launcherPath, usedPrivileges: true)
        } catch let launcherError as CLILauncherManagerError {
            throw launcherError
        } catch {
            throw CLILauncherManagerError.launcherRemoveFailed(launcherPath)
        }
    }

    private func validateInstallEnvironment() throws {
        let status = status()

        switch status.state {
        case .unsupportedAppLocation:
            throw CLILauncherManagerError.unsupportedAppLocation(
                currentPath: status.currentAppBundlePath,
                supportedPath: status.supportedAppBundlePath
            )
        case .bundledCLIMissing:
            throw CLILauncherManagerError.bundledCLIMissing(status.bundledCLIExecutablePath)
        case .notInstalled, .installed, .needsRepair:
            return
        }
    }

    private func writeLauncherScript() throws -> Bool {
        let launcherDirectoryURL = URL(fileURLWithPath: launcherPath).deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: launcherDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try expectedWrapperScript.write(toFile: launcherPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
            return false
        } catch {
            guard Self.requiresPrivileges(for: error) else {
                throw CLILauncherManagerError.launcherWriteFailed(launcherPath)
            }
        }

        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("retrace-cli-wrapper-\(UUID().uuidString)", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }
        do {
            try expectedWrapperScript.write(to: tempURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
            let shellCommand = """
            /bin/mkdir -p \(Self.shQuote(launcherDirectoryURL.path)) && \
            /usr/bin/install -m 755 \(Self.shQuote(tempURL.path)) \(Self.shQuote(launcherPath))
            """
            try privilegedCommandRunner(shellCommand)
            return true
        } catch let launcherError as CLILauncherManagerError {
            throw launcherError
        } catch {
            throw CLILauncherManagerError.launcherWriteFailed(launcherPath)
        }
    }

    public static func runPrivilegedShellCommand(_ shellCommand: String) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if stderr.localizedCaseInsensitiveContains("User canceled") ||
                stderr.localizedCaseInsensitiveContains("User cancelled") {
                throw CLILauncherManagerError.privilegedOperationCancelled
            }

            throw CLILauncherManagerError.privilegedOperationFailed(
                stderr.isEmpty ? "Administrator authorization failed." : stderr
            )
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func requiresPrivileges(for error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileWriteNoPermissionError ||
                nsError.code == NSFileWriteVolumeReadOnlyError
        }
        return false
    }

    private static func shQuote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func appleScriptQuote(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
