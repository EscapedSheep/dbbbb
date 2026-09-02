import SwiftUI
import UniformTypeIdentifiers

/// Bottom bar: engine, environment, read-only marker, elapsed time, row count,
/// and a truncation warning when the result hit the row cap. The trailing
/// actions export the visible result and open the import flow; import is only
/// offered when the session allows it (fail-closed gating in the store).
struct StatusBarView: View {
    @Environment(SessionStore.self) private var store

    @State private var showingImport = false

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
                Button {
                    exportResult()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export the visible result as CSV or JSON Lines")
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
            if store.isExecuting {
                Text("Running…")
            } else if let meta = store.result?.meta {
                if meta.truncated {
                    Label("Truncated", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                        .help("The result was capped; refine the query to see more.")
                }
                Text("\(meta.count) \(store.resultIsDocuments ? "documents" : "rows")")
                Text("\(meta.elapsedMilliseconds) ms")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Save-panel export of the visible (already capped) result: CSV for row
    /// results, JSONL for document results — the same mapping the Electron
    /// result-export dialog offers.
    private func exportResult() {
        let panel = NSSavePanel()
        let fileExtension = store.resultIsDocuments ? "jsonl" : "csv"
        panel.title = store.resultIsDocuments
            ? "Export result as JSON Lines"
            : "Export result as CSV"
        panel.nameFieldStringValue = "\(store.suggestedExportBaseName()).\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportResult(to: url)
    }
}
