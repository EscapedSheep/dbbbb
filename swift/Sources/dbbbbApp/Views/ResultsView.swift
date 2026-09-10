import SwiftUI
import UniformTypeIdentifiers
import dbbbbCore
import dbbbbKit

/// Result area: a 36px toolbar (Results title, count, scan/elapsed meta,
/// truncation badge, Continue scan, Export), then the content — progress while
/// running, a grid for rows, tree for documents. While a preview is shown, a
/// filter/sort bar sits on top (ROADMAP M1 ②).
struct ResultsView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            resultToolbar
            if store.isExecuting {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Running…")
                        .foregroundStyle(AppColors.textSecondary)
                    Button("Cancel") { store.cancelQuery() }
                        .buttonStyle(.appSecondary)
                        .keyboardShortcut(".", modifiers: .command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = store.result {
                VStack(spacing: 0) {
                    if store.previewedObject != nil {
                        PreviewFilterBar(result: result)
                        Divider().overlay(AppColors.border)
                    }
                    if !store.pendingChanges.isEmpty {
                        PendingChangesBar()
                        Divider().overlay(AppColors.border)
                    }
                    switch result {
                    case .rows(let columns, let rows, _):
                        RowsTableView(columns: columns, rows: rows)
                    case .documents(let documents, _):
                        DocumentTreeView(documents: documents)
                    }
                }
            } else {
                ResultsEmptyView()
            }
        }
    }

    /// Reference `.result-toolbar`: title + count on the left, meta and
    /// actions on the right, subtle background.
    private var resultToolbar: some View {
        HStack(spacing: 7) {
            Image(systemName: store.resultIsDocuments ? "curlybraces" : "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textSecondary)
            Text("Results")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.text)
            if let meta = store.result?.meta {
                Text("\(meta.count) \(store.resultIsDocuments ? "documents" : "rows")")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textDisabled)
            }
            Spacer()
            if let meta = store.result?.meta {
                if store.selectedSession?.profile.engine == .bullmq, let scanned = meta.scanned {
                    Text("Scanned \(scanned.formatted())"
                        + (meta.total.map { " of \($0.formatted())" } ?? ""))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textDisabled)
                        .help("Index entries examined for this result")
                }
                Text("\(meta.elapsedMilliseconds) ms")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textDisabled)
                if meta.truncated {
                    Text("Truncated")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.warning)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(AppColors.warningSoft))
                        .overlay(Capsule().stroke(AppColors.warning.opacity(0.3), lineWidth: 1))
                        .help("The result was capped; refine the query or continue the scan to see more.")
                }
                if store.canContinueScan {
                    Button {
                        store.continueScan()
                    } label: {
                        Label("Continue scan", systemImage: "forward.fill")
                    }
                    .buttonStyle(.appSecondaryCompact)
                    .help("Resume the scan from \(meta.nextCursor ?? 0) and append the next page")
                }
                exportControl
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .frame(height: AppMetrics.resultToolbarHeight)
        .background(AppColors.bgSubtle)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
    }

    /// Export affordance: document results offer only JSONL (one button); row
    /// results offer CSV, plus INSERT statements when the target table is
    /// known (previews only) — a small menu keeps the bar uncluttered.
    @ViewBuilder
    private var exportControl: some View {
        if store.canExportResult {
            if store.resultIsDocuments {
                Button {
                    exportResult(fileExtension: "jsonl", title: "Export result as JSON Lines")
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.appSecondaryCompact)
                .help("Export the visible result as JSON Lines")
            } else {
                Menu {
                    Button("Export as CSV…") {
                        exportResult(fileExtension: "csv", title: "Export result as CSV")
                    }
                    if let table = store.insertExportTable {
                        Button("Export as INSERT Statements…") {
                            exportResult(
                                fileExtension: "sql",
                                title: "Export result as INSERT statements",
                                format: .insertStatements(table: table))
                        }
                    }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11, weight: .medium))
                .help("Export the visible result")
            }
        }
    }

    /// Save-panel export of the visible (already capped) result.
    private func exportResult(
        fileExtension: String,
        title: String,
        format: ResultExporter.Format = .automatic
    ) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = "\(store.suggestedExportBaseName()).\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportResult(to: url, format: format)
    }
}

/// The zero-result state (reference `.result-empty`).
private struct ResultsEmptyView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(AppColors.textDisabled)
            Text("No results yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.top, 8)
            Text("Write a query and press ⌘Return to run it.")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textDisabled)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(AppColors.textSecondary)
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
                .foregroundStyle(AppColors.textSecondary)
                .help("Clear the filter")
            }

            Divider()
                .frame(height: 14)

            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(AppColors.textSecondary)
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
        .font(.system(size: 11))
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColors.bgPanel)
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
    /// The value-editor popup's target (ROADMAP M3 值编辑器).
    @State private var valueEdit: ValueEditTarget?
    /// The review a value-editor commit produced; presented from the popup's
    /// `onDismiss` so the two sheets chain cleanly.
    @State private var pendingValueReview: RecordReview?
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
                        onCollapse: { showsRowDetail = false },
                        onEditValue: store.editingObject == nil
                            ? nil
                            : { columnIndex in beginValueEdit(columnIndex: columnIndex) }
                    )
                    .frame(width: 300)
                } else {
                    rowDetailStrip
                }
            }
            .sheet(item: $editingState) { _ in
                RecordEditingSheet(
                    state: $editingState,
                    onStage: { review in store.stage(review) })
            }
            .sheet(item: $valueEdit, onDismiss: presentPendingValueReview) { target in
                ValueEditorSheet(
                    column: columns[target.columnIndex].name,
                    kind: target.kind,
                    initialText: ValueEditing.initialText(for: target.value, kind: target.kind),
                    onCommit: { newValue in
                        pendingValueReview = store.valueEditReview(
                            column: columns[target.columnIndex].name,
                            newValue: newValue,
                            columns: columns,
                            row: zip(columns, target.row.values).map { ($0.0.name, $0.1) })
                    })
            }
        }
    }

    /// One cell open in the popup value editor.
    struct ValueEditTarget: Identifiable {
        let id = UUID()
        let columnIndex: Int
        let kind: ValueEditKind
        let value: DisplayValue
        let row: RowModel
    }

    /// Opens the value editor for one detail-pane cell. Fails closed: only a
    /// singly-selected row of an editable preview, a complete (untruncated)
    /// value, and a kind the editor supports may open it.
    private func beginValueEdit(columnIndex: Int) {
        guard let row = selectedRow,
              columnIndex < row.values.count, columnIndex < columns.count
        else { return }
        let value = row.values[columnIndex]
        let item = RowDetailItem.make(
            index: columnIndex, column: columns[columnIndex].name, value: value)
        guard item.isValueEditable, let kind = ValueEditing.kind(for: value) else { return }
        valueEdit = ValueEditTarget(columnIndex: columnIndex, kind: kind, value: value, row: row)
    }

    /// After the value editor closes: a committed edit flows into the standard
    /// review sheet (production gate and `applyDataChange` included); a
    /// cancelled or gated-out edit leaves nothing pending.
    private func presentPendingValueReview() {
        guard let review = pendingValueReview else { return }
        pendingValueReview = nil
        editingState = .reviewing(review)
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
