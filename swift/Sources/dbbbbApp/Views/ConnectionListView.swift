import SwiftUI
import Foundation
import dbbbbCore

/// Sidebar: the list of connections. Selection drives the whole window.
struct ConnectionListView: View {
    @Environment(SessionStore.self) private var store
    @State private var pendingRemoval: UUID?

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "cylinder")
                } description: {
                    Text("Create a connection to start exploring.")
                } actions: {
                    Button("New Connection…") { store.showingNewConnection = true }
                }
            } else {
                List(selection: Binding(
                    get: { store.selectedConnectionID },
                    set: { store.selectConnection($0) }
                )) {
                    ForEach(store.sessions) { session in
                        ConnectionRow(profile: session.profile)
                            .tag(session.id)
                            .contextMenu {
                                Button("Remove Connection…", role: .destructive) {
                                    pendingRemoval = session.id
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.showingNewConnection = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .help("New Connection (⌘N)")
                if store.selectedConnectionID != nil {
                    Button(role: .destructive) {
                        pendingRemoval = store.selectedConnectionID
                    } label: {
                        Label("Remove Connection", systemImage: "minus")
                    }
                    .help("Remove Selected Connection")
                }
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Connection", role: .destructive) {
                if let id = pendingRemoval { store.removeConnection(id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The connection is removed from this window. This cannot be undone.")
        }
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EngineIcon.systemName(for: profile.engine))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .lineLimit(1)
                    EnvironmentBadge(environment: profile.environment)
                    if profile.readOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Read-only connection")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [profile.engine.displayName, endpointDisplay]
        if profile.demo { parts.append("Demo") }
        return parts.joined(separator: " · ")
    }

    /// SQLite endpoints are local absolute paths; show only the file name.
    private var endpointDisplay: String {
        guard profile.engine == .sqlite else { return profile.endpoint }
        return (profile.endpoint as NSString).lastPathComponent
    }
}
