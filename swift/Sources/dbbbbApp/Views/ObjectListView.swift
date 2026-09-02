import SwiftUI
import dbbbbCore

/// Middle column: the object navigator for the selected connection.
struct ObjectListView: View {
    @Environment(SessionStore.self) private var store

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
                List {
                    OutlineGroup(store.objectTree, children: \.children) { node in
                        ObjectRow(node: node)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Single click on a leaf drops a runnable template into the editor.
                                if node.children == nil { store.insertQueryTemplate(for: node.object) }
                            }
                            .contextMenu {
                                Button("Preview First 100") { store.preview(node.object) }
                                Button("Copy Name") { copyToPasteboard(node.object.name) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle(store.selectedSession?.profile.database ?? "Objects")
        .toolbar {
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
