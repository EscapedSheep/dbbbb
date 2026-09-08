import SwiftUI
import UniformTypeIdentifiers
import dbbbbKit

/// Bottom bar: engine, environment, read-only marker, elapsed time, row count,
/// and a truncation warning when the result hit the row cap. The trailing
/// actions export the visible result, open the import flow, and start the
/// insert flow; import and insert are only offered when the session allows
/// them (fail-closed gating in the store). The insert sheet (blank Add Row or
/// prefilled Duplicate Row) is hosted here so both the button and the grid's
/// context menu can drive it through `store.recordEditingState`.
struct StatusBarView: View {
    @Environment(SessionStore.self) private var store

    @State private var showingImport = false

    /// Binding into the observable store for the insert sheet.
    private var recordEditingState: Binding<RecordEditingState?> {
        Binding(
            get: { store.recordEditingState },
            set: { store.recordEditingState = $0 })
    }

    var body: some View {
        HStack(spacing: 12) {
            if let session = store.selectedSession {
                Label(
                    session.profile.engine.displayName,
                    systemImage: EngineIcon.systemName(for: session.profile.engine)
                )
                EnvironmentBadge(environment: session.profile.environment)
                if session.profile.readOnly {
                    Label("Read Only", systemImage: "lock.fill")
                }
            }
            Spacer()
            if store.isImporting {
                Text("Importing…")
            }
            if store.canExportResult {
                exportControl
            }
            if let object = store.importingObject,
               let format = store.importFormat(for: object) {
                Button {
                    showingImport = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .help("Import a \(format.rawValue.uppercased()) file into \(object.name)")
                .sheet(isPresented: $showingImport) {
                    ImportSheet(object: object, format: format)
                }
            }
            if let object = store.editingObject {
                Button {
                    store.beginInsert()
                } label: {
                    Label(
                        object.kind == .collection ? "Add Document…" : "Add Row…",
                        systemImage: "plus")
                }
                .help("Insert a new \(object.kind == .collection ? "document" : "row") into \(object.name)")
            }
            if store.isExecuting {
                Text("Running…")
            } else if let meta = store.result?.meta {
                // For previews, truncation signals another page — the pager
                // next to it carries that meaning, so no warning is shown.
                if meta.truncated, store.previewedObject == nil {
                    Label("Truncated", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                        .help("The result was capped; refine the query to see more.")
                }
                Text("\(meta.count) \(store.resultIsDocuments ? "documents" : "rows")")
                Text("\(meta.elapsedMilliseconds) ms")
            }
            if store.previewedObject != nil {
                Divider()
                    .frame(height: 14)
                Button {
                    store.previousPreviewPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!store.previewHasPreviousPage || store.isExecuting)
                .help("Previous page")
                Text("Page \(store.previewPageIndex + 1)")
                    .monospacedDigit()
                Button {
                    store.nextPreviewPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!store.previewHasNextPage || store.isExecuting)
                .help("Next page")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .sheet(item: recordEditingState) { _ in
            RecordEditingSheet(
                state: recordEditingState,
                onStage: { review in store.stage(review) })
        }
    }

    /// Export affordance: document results offer only JSONL (one button); row
    /// results offer CSV, plus INSERT statements when the target table is
    /// known (previews only) — a small menu keeps the bar uncluttered.
    @ViewBuilder
    private var exportControl: some View {
        if store.resultIsDocuments {
            Button {
                exportResult(fileExtension: "jsonl", title: "Export result as JSON Lines")
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
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
            .fixedSize()
            .help("Export the visible result")
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
