import SwiftUI
import dbbbbCore
import dbbbbKit

/// Editing-flow state for the results views: a draft being edited, or a
/// reviewed change (update or delete) awaiting confirmation. One sheet hosts
/// both phases, mirroring the Electron RecordEditorDialog's edit → review →
/// confirm flow: production connections confirm updates a second time by
/// typing APPLY, and deletes always require typing DELETE.
enum RecordEditingState: Identifiable {
    case editing(RecordDraft)
    case reviewing(RecordReview)

    var id: UUID {
        switch self {
        case .editing(let draft): draft.id
        case .reviewing(let review): review.id
        }
    }
}

/// A record open for editing. `original` is the optimistic-concurrency
/// baseline — the values exactly as displayed.
struct RecordDraft: Identifiable {
    let id = UUID()
    let object: DatabaseObject
    let environment: ConnectionEnvironment
    /// Result columns for tabular rows; empty for MongoDB documents.
    let columns: [ColumnMeta]
    let original: [(key: String, value: DisplayValue)]

    var isDocument: Bool { columns.isEmpty }
}

/// A reviewed change ready to apply. `changes`/`changed` are empty for a
/// delete.
struct RecordReview: Identifiable {
    let id = UUID()
    let draft: RecordDraft
    /// Field-level changes for display; `before` is nil for added fields.
    let changes: [(key: String, before: DisplayValue?, after: DisplayValue)]
    /// Values actually sent with an update.
    let changed: [String: DisplayValue]
    let isDelete: Bool

    var dataChange: DataChange {
        DataChange(
            object: draft.object,
            original: Dictionary(draft.original.map { ($0.key, $0.value) }) { first, _ in first },
            operation: isDelete ? .delete : .update(changed: changed))
    }
}

/// Draft-phase validation failures; safe to show verbatim.
private struct RecordDraftError: dbbbbError {
    let userMessage: String
    init(_ message: String) { userMessage = message }
}

/// The editing sheet: draft phase and review phase in one container so the
/// edit → review transition does not re-present.
struct RecordEditingSheet: View {
    @Binding var state: RecordEditingState?

    var body: some View {
        switch state {
        case .editing(let draft):
            RecordDraftEditor(
                draft: draft,
                onReview: { review in state = .reviewing(review) },
                onCancel: { state = nil })
        case .reviewing(let review):
            RecordReviewView(
                review: review,
                onBack: review.isDelete ? nil : { state = .editing(review.draft) },
                onDone: { state = nil })
        case .none:
            Text("Nothing to review.")
                .padding()
        }
    }
}

// MARK: - Draft phase

private struct RecordDraftEditor: View {
    let draft: RecordDraft
    let onReview: (RecordReview) -> Void
    let onCancel: () -> Void

    @State private var texts: [String]
    @State private var nulls: [Bool]
    @State private var documentText: String
    @State private var error: String?

    init(
        draft: RecordDraft,
        onReview: @escaping (RecordReview) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onReview = onReview
        self.onCancel = onCancel
        _texts = State(initialValue: draft.original.map { Self.editText($0.value) })
        _nulls = State(initialValue: draft.original.map { $0.value == .null })
        _documentText = State(initialValue:
            (try? MongoDocumentCodec.ejsonText(from: draft.original)) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordSheetHeader(
                title: draft.isDocument ? "Edit Document" : "Edit Record",
                environment: draft.environment)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if draft.isDocument {
                Text("Edit the document as canonical Extended JSON.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                TextEditor(text: $documentText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .border(Color(nsColor: .separatorColor))
                    .padding(16)
            } else {
                Form {
                    ForEach(Array(draft.original.enumerated()), id: \.offset) { index, field in
                        if Self.isEditable(field.value) {
                            LabeledContent(field.key) {
                                HStack(spacing: 8) {
                                    TextField("", text: $texts[index])
                                        .disabled(nulls[index])
                                    Toggle("NULL", isOn: $nulls[index])
                                        .toggleStyle(.checkbox)
                                }
                            }
                        } else {
                            LabeledContent(field.key) {
                                Text(DisplayFormatting.cellText(field.value))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help("This value cannot be edited as text.")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review", action: review)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380)
    }

    private func review() {
        do {
            error = nil
            onReview(try draft.isDocument ? makeDocumentReview() : makeRowReview())
        } catch let draftError as dbbbbError {
            error = draftError.userMessage
        } catch {
            self.error = "The record could not be reviewed."
        }
    }

    // MARK: Value parsing

    private static func isEditable(_ value: DisplayValue) -> Bool {
        switch value {
        case .null, .bool, .number, .string: true
        default: false
        }
    }

    private static func editText(_ value: DisplayValue) -> String {
        switch value {
        case .null: ""
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): DisplayFormatting.numberText(number)
        case .string(let text): text
        default: DisplayFormatting.cellText(value)
        }
    }

    /// Parses one edited cell back into a value, keeping the original kind:
    /// strings (including precision-sensitive temporal/decimal text) stay
    /// strings, numbers stay numbers, NULL comes from the toggle.
    private static func parseValue(
        text: String,
        isNull: Bool,
        original: DisplayValue,
        field: String
    ) throws -> DisplayValue {
        if isNull { return .null }
        switch original {
        case .null, .string:
            return .string(text)
        case .number:
            guard let number = Double(text) else {
                throw RecordDraftError("\(field) is not a valid number.")
            }
            return .number(number)
        case .bool:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw RecordDraftError("\(field) must be true or false.")
            }
        default:
            return original
        }
    }

    // MARK: Review assembly

    private func makeRowReview() throws -> RecordReview {
        var changes: [(key: String, before: DisplayValue?, after: DisplayValue)] = []
        var changed: [String: DisplayValue] = [:]
        for (index, field) in draft.original.enumerated() where Self.isEditable(field.value) {
            let after = try Self.parseValue(
                text: texts[index], isNull: nulls[index],
                original: field.value, field: field.key)
            if after != field.value {
                changes.append((field.key, field.value, after))
                changed[field.key] = after
            }
        }
        guard !changes.isEmpty else {
            throw RecordDraftError("Change at least one value before reviewing.")
        }
        return RecordReview(draft: draft, changes: changes, changed: changed, isDelete: false)
    }

    private func makeDocumentReview() throws -> RecordReview {
        let pairs = try MongoDocumentCodec.displayPairs(fromEJSON: documentText)
        let originalValues = Dictionary(draft.original.map { ($0.key, $0.value) }) { first, _ in first }
        let currentKeys = Set(pairs.map(\.key))

        // A reviewed change cannot express field removal yet; fail closed.
        for field in draft.original where !currentKeys.contains(field.key) {
            throw RecordDraftError(
                "Removing fields is not supported — set \(field.key) to null instead.")
        }

        var changes: [(key: String, before: DisplayValue?, after: DisplayValue)] = []
        var changed: [String: DisplayValue] = [:]
        for pair in pairs {
            let before = originalValues[pair.key]
            if pair.key == "_id", let before, before != pair.value {
                throw RecordDraftError("MongoDB _id cannot be edited.")
            }
            if before == nil || before! != pair.value {
                changes.append((pair.key, before, pair.value))
                changed[pair.key] = pair.value
            }
        }
        guard !changes.isEmpty else {
            throw RecordDraftError("Change at least one value before reviewing.")
        }
        return RecordReview(draft: draft, changes: changes, changed: changed, isDelete: false)
    }
}

// MARK: - Review phase

private struct RecordReviewView: View {
    @Environment(SessionStore.self) private var store

    let review: RecordReview
    let onBack: (() -> Void)?
    let onDone: () -> Void

    @State private var confirmation = ""
    @State private var applying = false
    @State private var error: String?

    private var isProduction: Bool { review.draft.environment == .production }
    /// The token the user must type before applying, if any.
    private var confirmationToken: String? {
        review.isDelete ? "DELETE" : (isProduction ? "APPLY" : nil)
    }
    private var canApply: Bool {
        !applying && (confirmationToken == nil || confirmation == confirmationToken)
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordSheetHeader(
                title: review.isDelete ? "Delete Record" : "Review Changes",
                environment: review.draft.environment)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if review.isDelete {
                        Text(review.draft.isDocument
                             ? "This document will be deleted. This cannot be undone."
                             : "This row will be deleted. This cannot be undone.")
                            .font(.callout)
                        ForEach(Array(review.draft.original.prefix(5).enumerated()), id: \.offset) { _, field in
                            LabeledContent(field.key) {
                                Text(DisplayFormatting.cellText(field.value))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                            LabeledContent(change.key) {
                                HStack(spacing: 6) {
                                    Text(change.before.map(DisplayFormatting.cellText) ?? "—")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.tertiary)
                                    Text(DisplayFormatting.cellText(change.after))
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            if let token = confirmationToken {
                Divider()
                LabeledContent {
                    TextField("", text: $confirmation)
                        .onSubmit(apply)
                } label: {
                    Text("Type **\(token)** to confirm")
                }
                .padding(12)
            }
            Divider()
            HStack {
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                if let onBack {
                    Button("Back", action: onBack)
                }
                Spacer()
                Button(review.isDelete ? "Delete" : "Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
                    .if(review.isDelete) { $0.buttonStyle(.borderedProminent).tint(.red) }
            }
            .padding(12)
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 320)
    }

    private func apply() {
        guard canApply else { return }
        applying = true
        error = nil
        let change = review.dataChange
        Task {
            let applied = await store.applyDataChange(change)
            applying = false
            if applied {
                onDone()
            } else {
                error = store.errorMessage ?? "The change was not applied."
            }
        }
    }
}

// MARK: - Shared chrome

private struct RecordSheetHeader: View {
    let title: String
    let environment: ConnectionEnvironment

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, environment == .development ? 10 : 4)
            if environment == .production {
                Label("Production connection — review every field before applying.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.production)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
        }
    }
}

private extension View {
    /// Conditional modifier helper (keeps the button chain readable).
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
