import SwiftUI
import dbbbbCore

/// Middle column: the OBJECTS tree of the selected connection. When the
/// connections column is collapsed, a compact strip on top shows the current
/// connection (badge + name) with an expand chevron, so the switch-back entry
/// point is never lost.
struct ObjectsColumnView: View {
    @Environment(SessionStore.self) private var store
    @Binding var searchText: String
    @Binding var connectionsCollapsed: Bool

    // MARK: Sheet bindings (dismissal clears the store's presentation)

    private var createStatementBinding: Binding<SessionStore.CreateStatementPresentation?> {
        Binding(get: { store.createStatement }, set: { if $0 == nil { store.dismissCreateStatement() } })
    }

    private var tableStatisticsBinding: Binding<SessionStore.TableStatisticsPresentation?> {
        Binding(get: { store.tableStatistics }, set: { if $0 == nil { store.dismissTableStatistics() } })
    }

    private var serverActivityBinding: Binding<SessionStore.ServerActivityPresentation?> {
        Binding(get: { store.serverActivity }, set: { if $0 == nil { store.dismissServerActivity() } })
    }

    private var schemaBinding: Binding<SessionStore.SchemaPresentation?> {
        Binding(get: { store.schemaPresentation }, set: { if $0 == nil { store.dismissSchema() } })
    }

    /// Quick-search hits with their ancestor chains, auto-expanded; only
    /// consulted while the search text is non-empty.
    private var filteredTree: [SessionStore.ObjectNode] {
        ObjectTreeFilter.filter(store.objectTree, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectionsCollapsed {
                collapsedConnectionStrip
            }
            SidebarSectionHeading(title: "Objects") {
                HStack(spacing: 2) {
                    if store.canShowSchema {
                        Button {
                            store.showSchema()
                        } label: {
                            Image(systemName: "tablecells")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(AppIconButtonStyle(size: 22))
                        .disabled(store.isLoadingSchema)
                        .help("View the database schema")
                    }
                    if store.canShowServerActivity {
                        Button {
                            store.showServerActivity()
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(AppIconButtonStyle(size: 22))
                        .disabled(store.isLoadingActivity)
                        .help("Show server activity")
                    }
                    Button {
                        store.refreshObjects()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(AppIconButtonStyle(size: 22))
                    .disabled(store.selectedSession == nil || store.isLoadingObjects)
                    .help("Reload objects")
                }
            }

            if store.selectedSession == nil {
                SidebarPlaceholder(text: "Pick a connection to browse its objects.")
            } else if store.isLoadingObjects && store.objects.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if store.objects.isEmpty {
                SidebarPlaceholder(text: "This database has no visible objects.")
            } else if !searchText.isEmpty && filteredTree.isEmpty {
                SidebarPlaceholder(text: "No objects match “\(searchText)”")
            } else {
                // A plain List keeps OutlineGroup's disclosure behavior; the
                // styling strips it down to the reference's bare tree rows.
                List {
                    if searchText.isEmpty {
                        OutlineGroup(store.objectTree, children: \.children) { node in
                            InteractiveObjectRow(node: node)
                        }
                    } else {
                        FilteredObjectRows(nodes: filteredTree)
                    }
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 23)
                .padding(.horizontal, 0)
                .padding(.bottom, 4)
            }
        }
        .frame(width: AppMetrics.columnWidth)
        .frame(maxHeight: .infinity)
        .background(AppColors.bgPanel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppColors.border).frame(width: 1)
        }
        .sheet(item: createStatementBinding) { presentation in
            CreateStatementSheet(presentation: presentation)
        }
        .sheet(item: tableStatisticsBinding) { presentation in
            TableStatisticsSheet(presentation: presentation)
        }
        .sheet(item: serverActivityBinding) { _ in
            ActivitySheet()
        }
        .sheet(item: schemaBinding) { presentation in
            SchemaSheet(presentation: presentation)
        }
    }

    /// Collapsed-state header: disclosure-style — chevron at the left edge,
    /// then engine badge and name; the whole strip is the expand affordance.
    private var collapsedConnectionStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.textDisabled)
                .frame(width: 14)
            if let profile = store.selectedSession?.profile {
                EngineBadge(engine: profile.engine)
                Text(profile.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.text)
                    .lineLimit(1)
            } else {
                Text("No connection")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textDisabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                connectionsCollapsed = false
            }
        }
        .help("Show the connections column (⌃⌘S)")
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
    }
}
