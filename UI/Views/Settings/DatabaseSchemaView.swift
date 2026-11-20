import SwiftUI
import AppKit

struct DatabaseSchemaView: View {
    let schemaText: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Database Schema")
                    .font(.retraceTitle3)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.retraceBackground)

            Divider()

            ScrollView {
                Text(schemaText.isEmpty ? "Loading..." : schemaText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.retracePrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.opacity(0.3))

            Divider()

            HStack {
                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(schemaText, forType: .string)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy to Clipboard")
                    }
                    .font(.retraceCalloutMedium)
                }
                .buttonStyle(.plain)
                .foregroundColor(.retraceAccent)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.retraceAccent.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
            .background(Color.retraceBackground)
        }
        .frame(width: 600, height: 500)
        .background(Color.retraceBackground)
        .cornerRadius(12)
    }
}
