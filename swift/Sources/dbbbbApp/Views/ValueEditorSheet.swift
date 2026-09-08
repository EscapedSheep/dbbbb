import SwiftUI
import dbbbbCore

/// Popup value editor (ROADMAP M3 值编辑器): one multi-line editor for a
/// single column value — plain text, JSON (Format button + live validation),
/// or binary as hex. The commit is a `DisplayValue` handed back through
/// `onCommit`; the caller routes it into the standard record review/apply
/// pipeline (DataChange → planner → optimistic lock → production gate), so
/// this sheet never writes on its own. Type fidelity: text/JSON commits as
/// the verbatim string, binary as decoded bytes.
struct ValueEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let column: String
    let kind: ValueEditKind
    let onCommit: (DisplayValue) -> Void

    @State private var text: String
    @State private var error: String?

    init(column: String, kind: ValueEditKind, initialText: String,
         onCommit: @escaping (DisplayValue) -> Void) {
        self.column = column
        self.kind = kind
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
    }

    /// Live validation for the structured modes; text accepts anything.
    private var validationError: String? {
        switch kind {
        case .text: nil
        case .json: ValueEditing.jsonValidationError(text)
        case .binary: ValueEditing.hexValidationError(text)
        }
    }

    private var title: String {
        switch kind {
        case .text: "Edit Text — \(column)"
        case .json: "Edit JSON — \(column)"
        case .binary: "Edit Hex — \(column)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if kind == .json {
                    Button("Format") { formatJSON() }
                        .disabled(ValueEditing.jsonValidationError(text) != nil
                                  || DisplayFormatting.prettyPrintedJSON(text) == nil)
                        .help("Pretty-print the JSON (objects and arrays only)")
                }
            }
            .padding()

            Divider()

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor))
                .padding(16)

            Divider()

            HStack(spacing: 8) {
                statusLine
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 460)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch kind {
        case .text:
            Text("Saved as text — no type conversion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .json:
            if let validationError {
                Label("Invalid JSON: \(validationError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("Valid JSON — saved as text, no type conversion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .binary:
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                let count = (try? ValueEditing.hexData(text))?.count ?? 0
                Text("\(count) bytes — hex pairs, whitespace ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatJSON() {
        if let pretty = DisplayFormatting.prettyPrintedJSON(text) {
            text = pretty
        }
    }

    private func commit() {
        do {
            let value = try ValueEditing.parse(text, kind: kind)
            onCommit(value)
            dismiss()
        } catch let parseError as dbbbbError {
            self.error = parseError.userMessage
        } catch {
            self.error = "The value could not be parsed."
        }
    }
}
