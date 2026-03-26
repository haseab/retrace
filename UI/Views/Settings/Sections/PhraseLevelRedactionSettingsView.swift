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
    var phraseLevelRedactionPhrases: [String] {
        if let data = phraseLevelRedactionPhrasesRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return normalizePhraseLevelRedactionPhrases(decoded)
        }

        let fallback = phraseLevelRedactionPhrasesRaw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map(String.init)
        return normalizePhraseLevelRedactionPhrases(fallback)
    }

    @ViewBuilder
    func redactionSettingsSubcard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    var phraseLevelRedactionCard: some View {
        ModernSettingsCard(title: "Phrase Level Redaction", icon: "text.viewfinder") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Redact matching OCR text with reversible scrambling from manual keywords.")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)

                redactionSettingsSubcard {
                    ModernToggleRow(
                        title: "Redact on Keyword",
                        subtitle: hasMasterKeyInKeychain
                            ? "Scramble matching OCR text using the master key stored in Keychain"
                            : "Requires creating a master key in Keychain before this feature can turn on",
                        isOn: phraseLevelRedactionBinding
                    )

                    if phraseLevelRedactionEnabled {
                        Divider()
                            .background(Color.white.opacity(0.08))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Keywords and phrases")
                                .font(.retraceCaptionBold)
                                .foregroundColor(.retraceSecondary)

                            HStack(spacing: 10) {
                                TextField("Type a phrase and press Return", text: $phraseLevelRedactionInput)
                                    .textFieldStyle(.plain)
                                    .font(.retraceCallout)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.white.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                    .onSubmit {
                                        addPhraseLevelRedactionPhrase()
                                    }

                                Button("Add") {
                                    addPhraseLevelRedactionPhrase()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(phraseLevelRedactionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }

                        if phraseLevelRedactionPhrases.isEmpty {
                            Text("No keywords configured yet.")
                                .font(.retraceCaption)
                                .foregroundColor(.retraceSecondary.opacity(0.8))
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(phraseLevelRedactionPhrases, id: \.self) { phrase in
                                    HStack(spacing: 8) {
                                        Text(phrase)
                                            .font(.retraceCaption)
                                            .foregroundColor(.retracePrimary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Spacer(minLength: 0)

                                        Button {
                                            removePhraseLevelRedactionPhrase(phrase)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.white.opacity(0.75))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.08))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func normalizePhraseLevelRedactionPhrases(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(phrases.count)

        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let dedupeKey = trimmed.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }

    func persistPhraseLevelRedactionPhrases(_ phrases: [String], action: String) {
        let normalized = normalizePhraseLevelRedactionPhrases(phrases)
        if let data = try? JSONEncoder().encode(normalized),
           let encoded = String(data: data, encoding: .utf8) {
            phraseLevelRedactionPhrasesRaw = encoded
            Task { @MainActor in
                showSettingsToast("Keyword redaction rules updated")
            }
            recordPhraseLevelRedactionRulesMetric(action: action, phraseCount: normalized.count)
            return
        }
        phraseLevelRedactionPhrasesRaw = "[]"
    }

    func addPhraseLevelRedactionPhrase() {
        guard phraseLevelRedactionEnabled else { return }
        let input = phraseLevelRedactionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        var phrases = phraseLevelRedactionPhrases
        phrases.append(input)
        persistPhraseLevelRedactionPhrases(phrases, action: "add")
        phraseLevelRedactionInput = ""
    }

    func removePhraseLevelRedactionPhrase(_ phrase: String) {
        guard phraseLevelRedactionEnabled else { return }
        var phrases = phraseLevelRedactionPhrases
        phrases.removeAll { $0.caseInsensitiveCompare(phrase) == .orderedSame }
        persistPhraseLevelRedactionPhrases(phrases, action: "remove")
    }

    func recordPhraseLevelRedactionRulesMetric(action: String, phraseCount: Int) {
        Task {
            let payload: [String: Any] = [
                "action": action,
                "phraseCount": phraseCount
            ]
            let metadata = Self.inPageURLMetricMetadata(payload)
            try? await coordinatorWrapper.coordinator.recordMetricEvent(
                metricType: .phraseLevelRedactionRulesUpdated,
                metadata: metadata
            )
        }
    }

    @ViewBuilder
    func redactionRuleEditor(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.32))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: text)
                .font(.retraceCaption)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(minHeight: 90)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }
}
