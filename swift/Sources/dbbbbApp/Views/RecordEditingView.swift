import Foundation
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
struct RecordDraft: Identifiable {    let id = UUID()
    let object: DatabaseObject
    let environment: ConnectionEnvironment
    /// Result columns for tabular rows; empty for MongoDB documents.
    let columns: [ColumnMeta]
    let original: [(key: String, value: DisplayValue)]
    /// Insert drafts: the form's seeded fields — blank `.null` seeds for
    /// Add Row, the duplicated row's values (primary keys blanked) for
    /// Duplicate Row. Nil for edit drafts. Insert drafts have no baseline,
    /// so `original` is empty.
    var insertPrefill: [(key: String, value: DisplayValue)]? = nil

    var isInsert: Bool { insertPrefill != nil }
    var isDocument: Bool { columns.isEmpty }
}

/// A reviewed change ready to apply. `changes`/`changed` are empty for a
/// delete.
struct RecordReview: Identifiable {
    let id = UUID()
    let draft: RecordDraft
    /// Field-level changes for display; `before` is nil for added fields.
    let changes: [(key: String, before: DisplayValue?, after: DisplayValue)]
    /// Values actually sent with an update or insert.
    let changed: [String: DisplayValue]
    /// Insert reviews only: fields omitted from the INSERT, so the column
    /// default (server-generated keys included) applies.
    var omittedKeys: [String] = []
    let isDelete: Bool

    var dataChange: DataChange {
        if draft.isInsert {
            // An insert has no optimistic-concurrency baseline.
            return DataChange(
                object: draft.object,
                original: [:],
                operation: .insert(values: changed))
        }
        return DataChange(
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

/// One field currently open in the popup value editor (ROADMAP M3 值编辑器).
struct FieldEditTarget: Identifiable {
    let id = UUID()
    let index: Int
    let kind: ValueEditKind
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
    /// Hex-popup edits of binary fields, by field index. Unedited binary
    /// seeds keep their existing behavior (omitted from inserts, unchanged
    /// in updates); an edited value crosses as `.binary` bytes.
    @State private var binaryEdits: [Int: Data] = [:]
    @State private var fieldEdit: FieldEditTarget?
    @State private var documentText: String
    @State private var error: String?

    /// The form's fields: the insert prefill for insert drafts, the original
    /// record for edit drafts.
    private var fields: [(key: String, value: DisplayValue)] {
        draft.insertPrefill ?? draft.original
    }

    init(
        draft: RecordDraft,
        onReview: @escaping (RecordReview) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onReview = onReview
        self.onCancel = onCancel
        let fields = draft.insertPrefill ?? draft.original
        _texts = State(initialValue: fields.map { Self.editText($0.value) })
        _nulls = State(initialValue: fields.map { $0.value == .null })
        _documentText = State(initialValue:
            (try? MongoDocumentCodec.ejsonText(from: fields)) ?? "")
    }

    private var title: String {
        switch (draft.isInsert, draft.isDocument) {
        case (true, true): "New Document"
        case (true, false): "New Record"
        case (false, true): "Edit Document"
        case (false, false): "Edit Record"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordSheetHeader(
                title: title,
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
                Text(draft.isInsert
                     ? "Write the new document as canonical Extended JSON. A missing _id is generated by the server."
                     : "Edit the document as canonical Extended JSON.")
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
                if draft.isInsert {
                    Text("Fields left as NULL are omitted from the INSERT, so the column default applies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
                Form {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if case .binary(let data) = field.value {
                            LabeledContent(field.key) {
                                HStack(spacing: 8) {
                                    Text(binarySummary(index: index, original: data))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button {
                                        fieldEdit = FieldEditTarget(index: index, kind: .binary)
                                    } label: {
                                        Image(systemName: "square.and.pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(nulls[index])
                                    .help("Edit as hex")
                                    Toggle("NULL", isOn: $nulls[index])
                                        .toggleStyle(.checkbox)
                                }
                            }
                        } else if Self.isEditable(field.value) {
                            LabeledContent(field.key) {
                                HStack(spacing: 8) {
                                    TextField("", text: $texts[index])
                                        .disabled(nulls[index])
                                    Button {
                                        fieldEdit = FieldEditTarget(
                                            index: index,
                                            kind: ValueEditing.kind(for: field.value) ?? .text)
                                    } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(nulls[index])
                                    .help("Edit in a larger editor (multi-line / JSON)")
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
        .sheet(item: $fieldEdit) { target in
            ValueEditorSheet(
                column: fields[target.index].key,
                kind: target.kind,
                initialText: popupInitialText(for: target),
                onCommit: { commitFieldEdit(target: target, value: $0) })
        }
    }

    /// The popup's seed content: the field's current text for text/JSON
    /// (keeping anything the user already typed inline), the edited or
    /// original bytes as hex for binary.
    private func popupInitialText(for target: FieldEditTarget) -> String {
        let field = fields[target.index]
        if target.kind == .binary, case .binary(let data) = field.value {
            return DisplayFormatting.hexText(binaryEdits[target.index] ?? data)
        }
        return texts[target.index]
    }

    /// The popup's commit lands back in the draft state — the actual write
    /// still goes through Review/Apply. Text/JSON cross as the verbatim
    /// string; binary as decoded bytes.
    private func commitFieldEdit(target: FieldEditTarget, value: DisplayValue) {
        switch value {
        case .string(let text):
            texts[target.index] = text
        case .binary(let data):
            binaryEdits[target.index] = data
        default:
            break
        }
    }

    private func binarySummary(index: Int, original: Data) -> String {
        if let edited = binaryEdits[index] {
            return "<\(edited.count) bytes> (edited)"
        }
        return "<\(original.count) bytes>"
    }

    private func review() {
        do {
            error = nil
            onReview(try draft.isInsert
                ? (draft.isDocument ? makeInsertDocumentReview() : makeInsertRowReview())
                : (draft.isDocument ? makeDocumentReview() : makeRowReview()))
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
        for (index, field) in draft.original.enumerated() {
            if case .binary = field.value {
                // Binary fields edit through the hex popup; the NULL toggle
                // clears the column. Unedited binary stays unchanged.
                let after: DisplayValue = nulls[index]
                    ? .null
                    : (binaryEdits[index].map(DisplayValue.binary) ?? field.value)
                if after != field.value {
                    changes.append((field.key, field.value, after))
                    changed[field.key] = after
                }
                continue
            }
            guard Self.isEditable(field.value) else { continue }
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

    /// Insert review for rows: fields still NULL-toggled are omitted from the
    /// INSERT (the column default applies — server-generated keys included);
    /// everything else crosses as its parsed value. Non-editable seed values
    /// (e.g. a duplicated binary cell) are omitted too — they cannot be
    /// typed, and a fresh row takes the column default instead. An all-omitted
    /// review is valid: the planner emits `DEFAULT VALUES`.
    private func makeInsertRowReview() throws -> RecordReview {
        var changes: [(key: String, before: DisplayValue?, after: DisplayValue)] = []
        var changed: [String: DisplayValue] = [:]
        var omitted: [String] = []
        for (index, field) in fields.enumerated() {
            if case .binary = field.value {
                // Only a hex-edited binary inserts; an unedited binary seed
                // (e.g. a duplicated blob) keeps its existing behavior and
                // the fresh row takes the column default.
                guard !nulls[index], let data = binaryEdits[index] else {
                    omitted.append(field.key)
                    continue
                }
                let value = DisplayValue.binary(data)
                changes.append((field.key, nil, value))
                changed[field.key] = value
                continue
            }
            guard Self.isEditable(field.value), !nulls[index] else {
                omitted.append(field.key)
                continue
            }
            let value = try Self.parseValue(
                text: texts[index], isNull: false,
                original: field.value, field: field.key)
            changes.append((field.key, nil, value))
            changed[field.key] = value
        }
        return RecordReview(
            draft: draft, changes: changes, changed: changed,
            omittedKeys: omitted, isDelete: false)
    }

    /// Insert review for MongoDB documents: every field of the edited EJSON
    /// document is inserted; an explicit `_id` keeps its tagged BSON type, a
    /// missing one is generated server-side. An empty document is valid.
    private func makeInsertDocumentReview() throws -> RecordReview {
        let pairs = try MongoDocumentCodec.displayPairs(fromEJSON: documentText)
        var changes: [(key: String, before: DisplayValue?, after: DisplayValue)] = []
        var changed: [String: DisplayValue] = [:]
        for pair in pairs {
            changes.append((pair.key, nil, pair.value))
            changed[pair.key] = pair.value
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
    /// The token the user must type before applying, if any. Inserts get the
    /// same production gate as updates.
    private var confirmationToken: String? {
        review.isDelete ? "DELETE" : (isProduction ? "APPLY" : nil)
    }
    private var canApply: Bool {
        !applying && (confirmationToken == nil || confirmation == confirmationToken)
    }
    private var title: String {
        if review.isDelete { return review.draft.isDocument ? "Delete Document" : "Delete Record" }
        if review.draft.isInsert { return review.draft.isDocument ? "New Document" : "New Record" }
        return "Review Changes"
    }
    private var applyTitle: String {
        review.isDelete ? "Delete" : (review.draft.isInsert ? "Insert" : "Apply")
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordSheetHeader(
                title: title,
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
                        // Insert reviews list the omitted fields too, so the
                        // reviewer sees which columns take their default.
                        ForEach(review.omittedKeys, id: \.self) { key in
                            LabeledContent(key) {
                                Text("(column default)")
                                    .foregroundStyle(.secondary)
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
                Button(applyTitle, action: apply)
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
