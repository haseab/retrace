import App
import AppKit
import Foundation
import Shared
import UniformTypeIdentifiers

enum MasterKeyRecoveryMethod: String {
    case manualText = "manual_text"
    case txtImport = "txt_import"
}

enum MissingMasterKeyPromptAction {
    case recover
    case createNew
    case cancel
}

enum MasterKeyRecoveryPromptAction {
    case recover(text: String, method: MasterKeyRecoveryMethod, storagePolicy: MasterKeyStoragePolicy)
    case cancel
}

enum MasterKeyRecoverySaveResult {
    case saved
    case cancelled
    case failed
}

enum MasterKeyRedactionPromptContext {
    case startup
    case settings
}

struct MasterKeyRedactionFlowMetrics {
    let promptShown: String
    let recoverSelected: String
    let createSelected: String
    let dismissed: String
    let importSelected: String
    let recovered: String
    let alreadyExists: String
    let recoverFailed: String
    let recoverCancelled: String
    let createCancelled: String
    let createConfirmed: String
    let createdFresh: String
    let createFailed: String
}

struct MasterKeyRedactionFlowConfiguration {
    let promptContext: MasterKeyRedactionPromptContext
    let recoverButtonTitle: String
    let createButtonTitle: String
    let cancelButtonTitle: String
    let metrics: MasterKeyRedactionFlowMetrics

    static let startup = MasterKeyRedactionFlowConfiguration(
        promptContext: .startup,
        recoverButtonTitle: "Recover",
        createButtonTitle: "Create New Master Key",
        cancelButtonTitle: "Not Now",
        metrics: MasterKeyRedactionFlowMetrics(
            promptShown: "startup_missing_key_prompt_shown",
            recoverSelected: "startup_missing_key_recover_selected",
            createSelected: "startup_missing_key_create_selected",
            dismissed: "startup_missing_key_deferred",
            importSelected: "startup_missing_key_import_selected",
            recovered: "startup_missing_key_recovered",
            alreadyExists: "startup_missing_key_already_exists",
            recoverFailed: "startup_missing_key_recover_failed",
            recoverCancelled: "startup_missing_key_recover_cancelled",
            createCancelled: "startup_missing_key_create_cancelled",
            createConfirmed: "startup_missing_key_create_confirmed",
            createdFresh: "startup_missing_key_created_fresh",
            createFailed: "startup_missing_key_create_failed"
        )
    )

    static let settings = MasterKeyRedactionFlowConfiguration(
        promptContext: .settings,
        recoverButtonTitle: "Recover Existing Key",
        createButtonTitle: "Create New Master Key",
        cancelButtonTitle: "Cancel",
        metrics: MasterKeyRedactionFlowMetrics(
            promptShown: "missing_key_prompt_shown",
            recoverSelected: "missing_key_recover_selected",
            createSelected: "missing_key_create_selected",
            dismissed: "missing_key_prompt_cancelled",
            importSelected: "missing_key_import_selected",
            recovered: "missing_key_recovered",
            alreadyExists: "missing_key_already_exists",
            recoverFailed: "missing_key_recover_failed",
            recoverCancelled: "missing_key_recover_cancelled",
            createCancelled: "missing_key_create_cancelled",
            createConfirmed: "missing_key_create_confirmed",
            createdFresh: "missing_key_created_fresh",
            createFailed: "missing_key_create_failed"
        )
    )
}

enum MasterKeyRedactionFlowOutcome: Equatable {
    case deferred
    case recoveredExistingKey
    case keyAlreadyAvailable
    case createdFreshKey(
        recoveryPhrase: String,
        storagePolicy: MasterKeyStoragePolicy,
        abandonedRewriteCount: Int
    )
}

@MainActor
enum MasterKeyRedactionFlowCoordinator {
    static func resolveMissingKey(
        coordinator: AppCoordinator,
        state: AppCoordinator.MissingMasterKeyRedactionState,
        defaults: UserDefaults,
        configuration: MasterKeyRedactionFlowConfiguration,
        recordMetric: @escaping (_ action: String, _ metadata: [String: Any]) -> Void
    ) async -> MasterKeyRedactionFlowOutcome {
        recordMetric(
            configuration.metrics.promptShown,
            [
                "phraseLevelRedactionEnabled": state.phraseLevelRedactionEnabled,
                "hasProtectedRedactionData": state.hasProtectedRedactionData,
                "hasPendingRedactionRewrites": state.hasPendingRedactionRewrites
            ]
        )

        while true {
            switch MasterKeyPromptUI.presentMissingKeyPrompt(
                message: state.recoveryPromptMessage(for: configuration.promptContext),
                recoverButtonTitle: configuration.recoverButtonTitle,
                createButtonTitle: configuration.createButtonTitle,
                cancelButtonTitle: configuration.cancelButtonTitle
            ) {
            case .recover:
                recordMetric(configuration.metrics.recoverSelected, [:])
                if let outcome = await recoverExistingKey(
                    coordinator: coordinator,
                    state: state,
                    defaults: defaults,
                    metrics: configuration.metrics,
                    recordMetric: recordMetric
                ) {
                    return outcome
                }
            case .createNew:
                recordMetric(configuration.metrics.createSelected, [:])
                if let outcome = await createFreshKey(
                    coordinator: coordinator,
                    state: state,
                    defaults: defaults,
                    metrics: configuration.metrics,
                    recordMetric: recordMetric
                ) {
                    return outcome
                }
            case .cancel:
                recordMetric(configuration.metrics.dismissed, [:])
                return .deferred
            }
        }
    }

    private static func recoverExistingKey(
        coordinator: AppCoordinator,
        state: AppCoordinator.MissingMasterKeyRedactionState,
        defaults: UserDefaults,
        metrics: MasterKeyRedactionFlowMetrics,
        recordMetric: @escaping (_ action: String, _ metadata: [String: Any]) -> Void
    ) async -> MasterKeyRedactionFlowOutcome? {
        while true {
            switch MasterKeyPromptUI.presentRecoveryPrompt(
                onImportSelection: {
                    recordMetric(metrics.importSelected, [:])
                }
            ) {
            case .recover(let recoveryText, let method, let storagePolicy):
                do {
                    let restored = try await MasterKeyManager.restoreMasterKeyAsync(
                        fromRecoveryText: recoveryText,
                        defaults: defaults,
                        storagePolicy: storagePolicy
                    )
                    if state.hasPendingRedactionRewrites {
                        await coordinator.recoverPendingPhraseRedactionRewritesIfPossible()
                    }
                    recordMetric(
                        restored ? metrics.recovered : metrics.alreadyExists,
                        [
                            "method": method.rawValue,
                            "storagePolicy": storagePolicy.rawValue
                        ]
                    )
                    return restored ? .recoveredExistingKey : .keyAlreadyAvailable
                } catch {
                    recordMetric(
                        metrics.recoverFailed,
                        [
                            "method": method.rawValue,
                            "storagePolicy": storagePolicy.rawValue,
                            "error": error.localizedDescription
                        ]
                    )
                    MasterKeyPromptUI.showRecoveryErrorAlert(error.localizedDescription)
                }
            case .cancel:
                recordMetric(metrics.recoverCancelled, [:])
                return nil
            }
        }
    }

    private static func createFreshKey(
        coordinator: AppCoordinator,
        state: AppCoordinator.MissingMasterKeyRedactionState,
        defaults: UserDefaults,
        metrics: MasterKeyRedactionFlowMetrics,
        recordMetric: @escaping (_ action: String, _ metadata: [String: Any]) -> Void
    ) async -> MasterKeyRedactionFlowOutcome? {
        guard MasterKeyPromptUI.confirmFreshKeyCreation(message: state.freshKeyConfirmationMessage) else {
            recordMetric(metrics.createCancelled, [:])
            return nil
        }

        guard let storagePolicy = MasterKeyPromptUI.presentStoragePolicyPrompt(
            title: "Choose Master Key Storage",
            message: "Store the master key only on this Mac or sync it through iCloud Keychain. Retrace will still show a recovery phrase backup."
        ) else {
            recordMetric(metrics.createCancelled, ["reason": "storage_policy_cancelled"])
            return nil
        }

        recordMetric(metrics.createConfirmed, ["storagePolicy": storagePolicy.rawValue])

        do {
            let result = try await MasterKeyManager.createMasterKeyIfNeededAsync(
                defaults: defaults,
                storagePolicy: storagePolicy
            )
            if result.created, let recoveryPhrase = result.recoveryPhrase {
                let abandonedRewriteCount = await coordinator.abandonPendingPhraseRedactionRewritesForFreshKey()
                recordMetric(
                    metrics.createdFresh,
                    [
                        "abandonedRewriteCount": abandonedRewriteCount,
                        "storagePolicy": storagePolicy.rawValue
                    ]
                )
                return .createdFreshKey(
                    recoveryPhrase: recoveryPhrase,
                    storagePolicy: storagePolicy,
                    abandonedRewriteCount: abandonedRewriteCount
                )
            }

            if state.hasPendingRedactionRewrites {
                await coordinator.recoverPendingPhraseRedactionRewritesIfPossible()
            }
            recordMetric(metrics.alreadyExists, ["method": "fresh_create"])
            return .keyAlreadyAvailable
        } catch {
            recordMetric(metrics.createFailed, ["error": error.localizedDescription])
            MasterKeyPromptUI.showRecoveryErrorAlert(error.localizedDescription)
            return nil
        }
    }
}

@MainActor
enum MasterKeyPromptUI {
    static func presentMissingKeyPrompt(
        message: String,
        icon: NSImage? = nil,
        recoverButtonTitle: String = "Recover Existing Key",
        createButtonTitle: String = "Create New Master Key",
        cancelButtonTitle: String = "Cancel"
    ) -> MissingMasterKeyPromptAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = icon ?? NSApp.applicationIconImage
        alert.messageText = "Master Key Missing"
        alert.informativeText = message
        alert.addButton(withTitle: recoverButtonTitle)
        alert.addButton(withTitle: createButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .recover
        case .alertSecondButtonReturn:
            return .createNew
        default:
            return .cancel
        }
    }

    static func presentRecoveryPrompt(
        icon: NSImage? = nil,
        onImportSelection: (() -> Void)? = nil
    ) -> MasterKeyRecoveryPromptAction {
        while true {
            let (accessoryView, textView) = makeRecoveryTextAccessoryView()

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.icon = icon ?? NSApp.applicationIconImage
            alert.messageText = "Recover Master Key"
            alert.informativeText = "Paste the 22-word recovery phrase below, or import the TXT recovery file you previously saved."
            alert.accessoryView = accessoryView
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Import TXT")
            alert.addButton(withTitle: "Cancel")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let recoveryText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !recoveryText.isEmpty else {
                    showRecoveryErrorAlert("Enter the recovery phrase or import the TXT file.")
                    continue
                }
                guard let storagePolicy = presentStoragePolicyPrompt(
                    title: "Restore Master Key To",
                    message: "Choose where Retrace should restore this master key."
                ) else {
                    continue
                }
                return .recover(text: recoveryText, method: .manualText, storagePolicy: storagePolicy)
            case .alertSecondButtonReturn:
                onImportSelection?()
                guard let importedText = importRecoveryTextFile() else {
                    continue
                }
                guard let storagePolicy = presentStoragePolicyPrompt(
                    title: "Restore Master Key To",
                    message: "Choose where Retrace should restore this master key."
                ) else {
                    continue
                }
                return .recover(text: importedText, method: .txtImport, storagePolicy: storagePolicy)
            default:
                return .cancel
            }
        }
    }

    static func confirmFreshKeyCreation(message: String, icon: NSImage? = nil) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = icon ?? NSApp.applicationIconImage
        alert.messageText = "Create New Master Key?"
        alert.informativeText = message
        alert.addButton(withTitle: "Create New Master Key")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func saveRecoveryPhraseDocument(_ recoveryPhrase: String) -> MasterKeyRecoverySaveResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Retrace Recovery Phrase.txt"

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            let contents = MasterKeyManager.recoveryDocumentText(
                recoveryPhrase: recoveryPhrase,
                storagePolicy: MasterKeyManager.storagePolicy()
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .saved
        } catch {
            showRecoveryErrorAlert("Couldn't save the recovery phrase.")
            return .failed
        }
    }

    static func presentStoragePolicyPrompt(
        title: String,
        message: String,
        icon: NSImage? = nil
    ) -> MasterKeyStoragePolicy? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = icon ?? NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "This Mac Only")
        alert.addButton(withTitle: "iCloud Keychain")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .localOnly
        case .alertSecondButtonReturn:
            return .iCloudKeychain
        default:
            return nil
        }
    }

    static func showRecoveredAlert(hasPendingRewrites: Bool, icon: NSImage? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = icon ?? NSApp.applicationIconImage
        alert.messageText = "Master Key Recovered"
        alert.informativeText = hasPendingRewrites
            ? "The master key was restored. Pending phrase-redaction rewrites will resume in the background."
            : "The master key was restored successfully."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func showRecoveryErrorAlert(_ message: String, icon: NSImage? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.icon = icon ?? NSApp.applicationIconImage
        alert.messageText = "Master Key Recovery Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func makeRecoveryTextAccessoryView() -> (NSView, NSTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = ""

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private static func importRecoveryTextFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose the TXT file containing your Retrace recovery phrase"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            showRecoveryErrorAlert("Couldn't read the selected recovery file.")
            return nil
        }
    }
}

private extension AppCoordinator.MissingMasterKeyRedactionState {
    func recoveryPromptMessage(for context: MasterKeyRedactionPromptContext) -> String {
        var paragraphs: [String] = []

        switch context {
        case .startup:
            if phraseLevelRedactionEnabled {
                paragraphs.append("Phrase redaction is enabled, but the Keychain copy of the master key is missing.")
            } else {
                paragraphs.append("Retrace can't find the master key previously used for phrase redaction.")
            }
        case .settings:
            if phraseLevelRedactionEnabled {
                paragraphs.append("Keyword redaction is enabled, but the Keychain copy of the master key is missing.")
            } else {
                paragraphs.append("Retrace can't find the master key previously used for keyword redaction.")
            }
        }

        var impacts: [String] = []
        if hasProtectedRedactionData {
            impacts.append("Previously redacted text can't be unlocked.")
        }
        if hasPendingRedactionRewrites {
            impacts.append("Pending redaction rewrites can't finish until the original key is recovered.")
        }
        if phraseLevelRedactionEnabled {
            impacts.append("New matching OCR text won't be protected until you recover or replace the key.")
        }
        if !impacts.isEmpty {
            paragraphs.append(impacts.map { "• \($0)" }.joined(separator: "\n"))
        }

        switch context {
        case .startup:
            paragraphs.append("What would you like to do?")
        case .settings:
            paragraphs.append("Recover the original key if you still have the recovery phrase. Only create a new key if you are willing to leave older protected data locked.")
        }

        return paragraphs.joined(separator: "\n\n")
    }

    var freshKeyConfirmationMessage: String {
        var lines = ["Creating a new master key will not restore access to data protected with the missing key."]

        if hasProtectedRedactionData {
            lines.append("Previously redacted text in older recordings will stay locked.")
        }
        if hasPendingRedactionRewrites {
            lines.append("Pending redaction rewrites tied to the missing key will be marked failed and won't be retried.")
        }

        lines.append("Only choose this if you do not have the old recovery phrase.")
        return lines.joined(separator: "\n\n")
    }
}
