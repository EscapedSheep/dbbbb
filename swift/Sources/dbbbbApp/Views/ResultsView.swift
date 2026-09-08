import SwiftUI
import dbbbbCore
import dbbbbKit

/// Result area: progress while running, a grid for rows, tree for documents.
/// While a preview is shown, a filter/sort bar sits on top (ROADMAP M1 ②).
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
            VStack(spacing: 0) {
                if store.previewedObject != nil {
                    PreviewFilterBar(result: result)
                    Divider()
                }
                switch result {
                case .rows(let columns, let rows, _):
                    RowsTableView(columns: columns, rows: rows)
                case .documents(let documents, _):
                    DocumentTreeView(documents: documents)
                }
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

/// Grid filter/sort bar for previews: a column dropdown plus a contains-text
/// field with a clear button, and a sort column dropdown with a direction
/// toggle. Every change re-runs the preview from page one through the
/// SessionStore request/cancellation path. For document results the column
/// choices are the top-level keys of the visible documents.
struct PreviewFilterBar: View {
    @Environment(SessionStore.self) private var store

    let result: QueryResult

    @State private var filterText = ""

    private var columnNames: [String] {
        switch result {
        case .rows(let columns, _, _):
            return columns.map(\.name)
        case .documents(let documents, _):
            var names: [String] = []
            var seen: Set<String> = []
            for document in documents.prefix(100) {
                guard case .object(let pairs) = document else { continue }
                for pair in pairs where seen.insert(pair.key).inserted {
                    names.append(pair.key)
                }
            }
            return names
        }
    }

    /// The filter column: the active filter's column while one is set,
    /// otherwise the field the input would apply to.
    private var filterColumn: String {
        store.previewFilter?.column ?? columnNames.first ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            Picker("Column", selection: filterColumnBinding) {
                ForEach(columnNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120)
            .disabled(columnNames.isEmpty)
            TextField("Contains…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit {
                    applyFilter()
                }
            if store.previewFilter != nil {
                Button {
                    filterText = ""
                    store.setPreviewFilter(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the filter")
            }

            Divider()
                .frame(height: 14)

            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(.secondary)
            Picker("Sort", selection: sortColumnBinding) {
                Text("Unsorted").tag("")
                ForEach(columnNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120)
            .disabled(columnNames.isEmpty)
            if let sort = store.previewSort {
                Button {
                    store.setPreviewSort(PreviewRequest.Sort(column: sort.column, ascending: !sort.ascending))
                } label: {
                    Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                }
                .help(sort.ascending ? "Sorted ascending — click for descending" : "Sorted descending — click for ascending")
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // A fresh preview (or an object switch) resets the input to the
        // store's state of record.
        .onChange(of: store.previewedObject) {
            filterText = store.previewFilter?.contains ?? ""
        }
        .onAppear {
            filterText = store.previewFilter?.contains ?? ""
        }
    }

    private var filterColumnBinding: Binding<String> {
        Binding(
            get: { filterColumn },
            set: { newColumn in
                // Switching the column reapplies the current text immediately.
                store.setPreviewFilter(filterText.isEmpty
                    ? nil
                    : PreviewRequest.Filter(column: newColumn, contains: filterText))
            })
    }

    private var sortColumnBinding: Binding<String> {
        Binding(
            get: { store.previewSort?.column ?? "" },
            set: { newColumn in
                store.setPreviewSort(newColumn.isEmpty
                    ? nil
                    : PreviewRequest.Sort(column: newColumn, ascending: store.previewSort?.ascending ?? true))
            })
    }

    private func applyFilter() {
        guard !filterColumn.isEmpty else { return }
        store.setPreviewFilter(filterText.isEmpty
            ? nil
            : PreviewRequest.Filter(column: filterColumn, contains: filterText))
    }
}

/// Tabular results: numeric columns are monospaced and right-aligned,
/// rows are selectable and copyable as TSV or JSON via the context menu.
/// When the session allows editing (writable preview of one table), the
/// context menu also offers the edit/delete record flow.
/// Rendering goes through `ResultsTableView` (NSTableView): SwiftUI `Table`
/// caps column counts, while arbitrary-width result sets must render fully.
/// A collapsible row-detail pane sits on the right (ROADMAP M2 ⑥); it is a
/// fixed-width sibling in an `HStack`, so the table keeps its own horizontal
/// scrolling untouched.
struct RowsTableView: View {
    @Environment(SessionStore.self) private var store

    let columns: [ColumnMeta]
    let rows: [[DisplayValue]]

    @State private var selection = Set<Int>()
    @State private var editingState: RecordEditingState?
    @State private var showsRowDetail = true

    private var models: [RowModel] {
        rows.enumerated().map { RowModel(id: $0.offset, values: $0.element) }
    }

    /// The detail pane inspects exactly one row; empty or multi-selection
    /// shows its placeholder instead.
    private var selectedRow: RowModel? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return models.first { $0.id == id }
    }

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView(
                "Statement Executed",
                systemImage: "checkmark.circle",
                description: Text("The statement completed without returning rows.")
            )
        } else {
            HStack(spacing: 0) {
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
                Divider()
                if showsRowDetail {
                    RowDetailPane(
                        columns: columns,
                        row: selectedRow,
                        selectionCount: selection.count,
                        onCollapse: { showsRowDetail = false }
                    )
                    .frame(width: 300)
                } else {
                    rowDetailStrip
                }
            }
            .sheet(item: $editingState) { _ in
                RecordEditingSheet(state: $editingState)
            }
        }
    }

    /// Slim right-edge affordance to reopen the collapsed row-detail pane.
    private var rowDetailStrip: some View {
        VStack {
            Button { showsRowDetail = true } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show row detail")
            Spacer()
        }
        .padding(.top, 6)
        .frame(width: 26)
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
