import SwiftUI
import Shared

/// Selects how newly matched phrases are protected.
struct PhraseRedactionMethodPicker: View {
    @Binding var mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Redaction method", selection: $mode) {
                Text("Scramble (default)").tag(PhraseRedactionMode.scramble.rawValue)
                Text("Permanently redact").tag(PhraseRedactionMode.permanent.rawValue)
            }
            .pickerStyle(.menu)
            Text(mode == PhraseRedactionMode.permanent.rawValue
                ? "Matching text and image regions are removed and cannot be revealed. Applies to newly processed matches; existing recordings keep their current protection."
                : "Matching regions are scrambled and can be revealed with your master key. Applies to newly processed matches.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
