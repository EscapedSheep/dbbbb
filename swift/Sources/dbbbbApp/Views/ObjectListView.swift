import SwiftUI
import dbbbbCore

/// Middle column: the object navigator for the selected connection.
struct ObjectListView: View {
    @Environment(SessionStore.self) private var store
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// Two-way binding over the store's presentation; dismissing the sheet
    /// clears it.
    private var createStatementBinding: Binding<SessionStore.CreateStatementPresentation?> {
        Binding(
            get: { store.createStatement },
            set: { if $0 == nil { store.dismissCreateStatement() } }
        )
    }

    /// Same for the statistics sheet.
    private var tableStatisticsBinding: Binding<SessionStore.TableStatisticsPresentation?> {
        Binding(
            get: { store.tableStatistics },
            set: { if $0 == nil { store.dismissTableStatistics() } }
        )
    }

    /// Same for the activity sheet (ROADMAP M2 ⑨).
    private var serverActivityBinding: Binding<SessionStore.ServerActivityPresentation?> {
        Binding(
            get: { store.serverActivity },
            set: { if $0 == nil { store.dismissServerActivity() } }
        )
    }

    /// Same for the schema sheet ("View Schema").
    private var schemaBinding: Binding<SessionStore.SchemaPresentation?> {
        Binding(
            get: { store.schemaPresentation },
            set: { if $0 == nil { store.dismissSchema() } }
        )
    }

    /// Quick-search result: hits with their ancestor chains (subtrees below a
    /// hit stay whole). Only consulted while the search text is non-empty.
    private var filteredTree: [SessionStore.ObjectNode] {
        ObjectTreeFilter.filter(store.objectTree, query: searchText)
    }

    var body: some View {
        Group {
            if store.selectedSession == nil {
                ContentUnavailableView(
                    "No Connection Selected",
                    systemImage: "cylinder",
                    description: Text("Pick a connection to browse its objects.")
                )
            } else if store.isLoadingObjects && store.objects.isEmpty {
                ProgressView("Loading objects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.objects.isEmpty {
                ContentUnavailableView(
                    "No Objects",
                    systemImage: "tray",
                    description: Text("This database has no visible objects.")
                )
            } else {
                browser
            }
        }
        .navigationTitle(store.selectedSession?.profile.database ?? "Objects")
        .sheet(item: serverActivityBinding) { _ in
            ActivitySheet()
        }
        .sheet(item: schemaBinding) { presentation in
            SchemaSheet(presentation: presentation)
        }
        .toolbar {
            if store.canShowSchema {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.showSchema()
                    } label: {
                        Label("Schema…", systemImage: "tablecells")
                    }
                    .disabled(store.isLoadingSchema)
                    .help("View the database schema")
                }
            }
            if store.canShowServerActivity {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.showServerActivity()
                    } label: {
                        Label("Activity…", systemImage: "waveform.path.ecg")
                    }
                    .disabled(store.isLoadingActivity)
                    .help("Show server activity")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refreshObjects()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.selectedSession == nil || store.isLoadingObjects)
                .help("Reload objects")
            }
        }
    }

    /// The browser once a connection has objects: quick search on top
    /// (⌘F focuses, Esc clears), the tree below — the empty/loading states
    /// above never see the search field.
    private var browser: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List {
                if searchText.isEmpty {
                    OutlineGroup(store.objectTree, children: \.children) { node in
                        InteractiveObjectRow(node: node)
                    }
                } else if filteredTree.isEmpty {
                    Text("No objects match “\(searchText)”")
                        .foregroundStyle(.secondary)
                } else {
                    FilteredObjectRows(nodes: filteredTree)
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(item: createStatementBinding) { presentation in
            CreateStatementSheet(presentation: presentation)
        }
        .sheet(item: tableStatisticsBinding) { presentation in
            TableStatisticsSheet(presentation: presentation)
        }
        // Zero-size button whose only job is the ⌘F shortcut; `.hidden()`
        // would unregister the shortcut, so it stays at opacity 0.
        .background(
            Button("Filter Objects") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter objects", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { searchText = "" }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the filter (Esc)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One navigator row with its full interaction set (double-click runs the
/// SELECT, single click drops the template, context menu) — shared by the
/// plain OutlineGroup and the filtered DisclosureGroup rendering.
private struct InteractiveObjectRow: View {
    @Environment(SessionStore.self) private var store
    let node: SessionStore.ObjectNode

    var body: some View {
        ObjectRow(node: node)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // Double-click on a leaf runs its SELECT right away.
                if node.children == nil { store.runSelectLimit100(for: node.object) }
            }
            .onTapGesture(count: 1) {
                // Single click on a leaf drops a runnable template into the editor.
                if node.children == nil { store.insertQueryTemplate(for: node.object) }
            }
            .contextMenu {
                Button("Preview First 100") { store.preview(node.object) }
                if store.canShowCreateStatement(for: node.object) {
                    Button("View Create Statement") {
                        store.showCreateStatement(for: node.object)
                    }
                }
                if store.canShowTableStatistics(for: node.object) {
                    Button("Statistics…") {
                        store.showTableStatistics(for: node.object)
                    }
                }
                Button("Copy Name") { copyToPasteboard(node.object.name) }
            }
    }
}

/// While the search field is non-empty, hits render as a recursive
/// DisclosureGroup tree: OutlineGroup exposes no expansion binding, and
/// filtering must auto-expand the ancestor chain of every hit, so the
/// filtered rendering owns its expansion state (every level starts expanded;
/// nodes that re-enter the filter reset to expanded).
private struct FilteredObjectRows: View {
    let nodes: [SessionStore.ObjectNode]

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                ExpandableFilteredNode(node: node, children: children)
            } else {
                InteractiveObjectRow(node: node)
            }
        }
    }
}

private struct ExpandableFilteredNode: View {
    let node: SessionStore.ObjectNode
    let children: [SessionStore.ObjectNode]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            FilteredObjectRows(nodes: children)
        } label: {
            InteractiveObjectRow(node: node)
        }
    }
}

private struct ObjectRow: View {
    let node: SessionStore.ObjectNode

    var body: some View {
        Label(node.object.name, systemImage: Self.icon(for: node.object.kind))
            .font(.system(.body, design: .monospaced))
    }

    static func icon(for kind: DatabaseObjectKind) -> String {
        switch kind {
        case .database: "cylinder"
        case .schema: "folder"
        case .table: "tablecells"
        case .view: "eye"
        case .collection: "leaf"
        }
    }
}
