import SwiftUI

/// Detail column: error banner, query editor, results, and the status bar.
struct QueryWorkspaceView: View {
    @Environment(SessionStore.self) private var store
    @State private var showingHistory = false

    var body: some View {
        Group {
            if store.selectedSession == nil {
                ContentUnavailableView(
                    "No Connection Selected",
                    systemImage: "cylinder.split.1x2",
                    description: Text("Pick a connection from the sidebar, or create a new one with ⌘N.")
                )
            } else {
                VStack(spacing: 0) {
                    QueryTabBar()
                    Divider()
                    if let message = store.errorMessage {
                        ErrorBanner(message: message) { store.errorMessage = nil }
                        Divider()
                    }
                    QueryEditorView()
                        .frame(minHeight: 140, idealHeight: 180, maxHeight: 260)
                    Divider()
                    ResultsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    StatusBarView()
                }
            }
        }
        .navigationTitle(store.selectedSession?.profile.name ?? "dbbbb")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.selectedSession?.profile.engine == .mongodb {
                    Picker("MongoDB Mode", selection: Binding(
                        get: { store.mongoQueryMode },
                        set: { store.setMongoQueryMode($0) }
                    )) {
                        Text("Find").tag(SessionStore.MongoQueryMode.find)
                        Text("Aggregate").tag(SessionStore.MongoQueryMode.aggregate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .help("MongoDB query mode: a find filter document, or an aggregation pipeline array")
                }
                Button {
                    showingHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
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
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Cancel the running query (⌘.)")
                } else {
                    Button {
                        store.formatCurrentQuery()
                    } label: {
                        Label("Format", systemImage: "textformat")
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!store.canFormatQuery)
                    .help("Format the SQL query (⇧⌘F)")
                    Button {
                        store.explainCurrentQuery()
                    } label: {
                        Label("Explain", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(!store.canExplainQuery)
                    .help("Explain the current query (query plan, never executes it)")
                    Button {
                        store.runQuery()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.selectedSession == nil
                              || store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run query (⌘Return)")
                }
            }
        }
    }
}
