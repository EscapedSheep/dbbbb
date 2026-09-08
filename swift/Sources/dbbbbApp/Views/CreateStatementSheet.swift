import SwiftUI
import dbbbbCore

/// Read-only create-statement viewer: monospaced, selectable DDL with a Copy
/// button. The statement is fetched beforehand by `SessionStore`; errors
/// never reach this sheet (they surface in the redacted banner).
struct CreateStatementSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: SessionStore.CreateStatementPresentation

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create Statement — \(presentation.objectName)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                Text(presentation.ddl)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Copy") { copyToPasteboard(presentation.ddl) }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 560, height: 440)
    }
}
