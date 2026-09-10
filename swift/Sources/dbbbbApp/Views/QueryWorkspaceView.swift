import SwiftUI
import dbbbbCore
import dbbbbKit

/// The workspace column: tab strip, query panel (toolbar + editor), and the
/// results panel. Chrome follows the Electron reference — a 36px tab strip,
/// a 38px query toolbar with the language label on the left and actions
/// (Sync/Import/History/Format/Explain, then the blue Run with its ⌘↩ chip)
/// on the right.
struct QueryWorkspaceView: View {
    @Environment(SessionStore.self) private var store
    @State private var showingHistory = false
    @State private var showingBullmqSync = false
    @State private var showingImport = false

    var body: some View {
        Group {
            if store.selectedSession == nil {
                WorkspaceEmptyView()
            } else {
                VStack(spacing: 0) {
                    QueryTabBar()
                        .frame(height: AppMetrics.tabStripHeight)
                    if let message = store.errorMessage {
                        ErrorBanner(message: message) { store.errorMessage = nil }
                    }
                    queryToolbar
                    QueryEditorView()
                        .frame(minHeight: 140, idealHeight: 180, maxHeight: 260)
                        .clipped()
                    Divider().overlay(AppColors.borderStrong)
                    ResultsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(AppColors.bgPanel)
            }
        }
        .sheet(isPresented: $showingBullmqSync) {
            BullmqSyncSheet()
        }
        .background(
            Button("XXZXX") { store.formatCurrentQuery() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .sheet(isPresented: $showingImport) {
            if let object = store.importingObject,
               let format = store.importFormat(for: object) {
                ImportSheet(object: object, format: format)
            }
        }
    }

    // MARK: Query toolbar

    /// Left: language label, Mongo mode/collection, read-only badge.
    /// Right: engine actions, then Format/Explain and Run (⌘↩) or Cancel.
    private var queryToolbar: some View {
        HStack(spacing: 10) {
            if let session = store.selectedSession {
                Text(languageLabel(for: session.profile.engine))
                    .font(AppFonts.monoUI(11, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                if session.profile.engine == .mongodb {
                    mongoModePicker
                }
                if session.profile.readOnly {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("Read only")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textDisabled)
                }
            }
            Spacer()
            HStack(spacing: 7) {
                if store.canSyncBullmqSnapshot {
                    Button {
                        showingBullmqSync = true
                    } label: {
                        Label("Sync to local SQL", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.appSecondary)
                    .disabled(store.isExecuting)
                    .help("Materialize a queue into a local SQLite table for SQL analysis. Redis is never modified.")
                }
                if let object = store.importingObject,
                   let format = store.importFormat(for: object) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.appSecondary)
                    .help("Import a \(format.rawValue.uppercased()) file into \(object.name)")
                }
                Button {
                    showingHistory.toggle()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.appIcon)
                .help("Query history and favorites")
                .popover(isPresented: $showingHistory) {
                    QueryHistoryView()
                }
                if store.isExecuting {
                    Button {
                        store.cancelQuery()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Cancel the running query (⌘.)")
                } else {
                    Button {
                        store.formatCurrentQuery()
                    } label: {
                        Image(systemName: "text.alignleft")
                    }
                    .buttonStyle(.appIcon)
                    .disabled(!store.canFormatQuery)
                    .help("Format the SQL query (⇧⌘F)")
                    Button {
                        store.explainCurrentQuery()
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.appIcon)
                    .disabled(!store.canExplainQuery)
                    .help("Explain the current query (query plan, never executes it)")
                    Button {
                        store.runQuery()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Run")
                            Text("⌘↩")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.selectedSession == nil
                              || store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run query (⌘Return)")
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .frame(height: AppMetrics.toolbarHeight)
        .background(AppColors.bgPanel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
    }

    /// Reference `.language-label`: SQL / MONGO FILTER / BULLMQ JOBS.
    private func languageLabel(for engine: DatabaseEngine) -> String {
        switch engine {
        case .mongodb: "Mongo filter"
        case .bullmq: "BullMQ jobs"
        default: "SQL"
        }
    }

    /// The find/aggregate segmented control (reference `.segmented-control`).
    private var mongoModePicker: some View {
        HStack(spacing: 0) {
            ForEach(SessionStore.MongoQueryMode.allCases, id: \.self) { mode in
                let isActive = store.mongoQueryMode == mode
                Button(mode == .find ? "Find" : "Aggregate") {
                    store.setMongoQueryMode(mode)
                }
                .font(AppFonts.monoUI(11))
                .foregroundStyle(isActive ? AppColors.text : AppColors.textSecondary)
                .frame(height: 22)
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? AppColors.bgPanel : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isActive ? AppColors.border : .clear, lineWidth: 1))
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(AppColors.bgSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                .stroke(AppColors.border, lineWidth: 1))
        .help("MongoDB query mode: a find filter document, or an aggregation pipeline array")
    }
}

/// The zero-connection workspace state (reference `.workspace-empty`).
private struct WorkspaceEmptyView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.textDisabled)
            Text("No connection selected")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Text("Pick a connection from the sidebar, or create a new one with ⌘N.")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.bgApp)
    }
}
