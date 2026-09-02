import SwiftUI
import dbbbbCore

/// Result area: progress while running, a grid for rows, tree for documents.
struct ResultsView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        if store.isExecuting {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Running…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelQuery() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = store.result {
            switch result {
            case .rows(let columns, let rows, _):
                RowsTableView(columns: columns, rows: rows)
            case .documents(let documents, _):
                DocumentTreeView(documents: documents)
            }
        } else {
            ContentUnavailableView(
                "No Results",
                systemImage: "play.rectangle",
                description: Text("Write a query and press ⌘Return to run it.")
            )
        }
    }
}

/// Tabular results: numeric columns are monospaced and right-aligned,
/// rows are selectable and copyable as TSV or JSON via the context menu.
/// When the session allows editing (writable preview of one table), the
/// context menu also offers the edit/delete record flow.
/// Rendering goes through `ResultsTableView` (NSTableView): SwiftUI `Table`
/// caps column counts, while arbitrary-width result sets must render fully.
struct RowsTableView: View {
    @Environment(SessionStore.self) private var store

    let columns: [ColumnMeta]
    let rows: [[DisplayValue]]

    @State private var selection = Set<Int>()
    @State private var editingState: RecordEditingState?

    private var models: [RowModel] {
        rows.enumerated().map { RowModel(id: $0.offset, values: $0.element) }
    }

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView(
                "Statement Executed",
                systemImage: "checkmark.circle",
                description: Text("The statement completed without returning rows.")
            )
        } else {
            ResultsTableView(
                columns: columns,
                rows: models,
                selection: $selection,
                allowsEditing: store.editingObject != nil,
                onCopy: copy,
                onEdit: { id in
                    editingState = rowDraft(id).map(RecordEditingState.editing)
                },
                onDelete: { id in
                    editingState = rowDraft(id).map {
                        RecordEditingState.reviewing(RecordReview(
                            draft: $0, changes: [], changed: [:], isDelete: true))
                    }
                }
            )
            .sheet(item: $editingState) { _ in
                RecordEditingSheet(state: $editingState)
            }
        }
    }

    /// The editing draft for one row: every result column with its displayed
    /// value as the optimistic-concurrency baseline.
    private func rowDraft(_ id: Int) -> RecordDraft? {
        guard let object = store.editingObject,
              let session = store.selectedSession,
              let model = models.first(where: { $0.id == id })
        else { return nil }
        return RecordDraft(
            object: object,
            environment: session.profile.environment,
            columns: columns,
            original: zip(columns, model.values).map { ($0.0.name, $0.1) })
    }

    private func copy(_ items: Set<Int>, asTSV: Bool) {
        let selectedRows = models.filter { items.contains($0.id) }.sorted { $0.id < $1.id }.map(\.values)
        let text = asTSV
            ? DisplayFormatting.tsv(columns: columns, rows: selectedRows)
            : DisplayFormatting.jsonRows(columns: columns, rows: selectedRows)
        copyToPasteboard(text)
    }
}
