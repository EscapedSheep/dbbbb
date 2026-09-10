import SwiftUI
import dbbbbCore

/// The single left column of the Electron-style shell: one search field on
/// top, the CONNECTIONS section below it, then the OBJECTS tree of the
/// selected connection in the same column. Merges what used to be two
/// NavigationSplitView columns (ConnectionListView + ObjectListView); every
/// interaction is preserved — connection context menu, object single/double
/// click, the object context menu and its sheets, ⌘F search focus.
struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @State private var searchText = ""
    @State private var pendingRemoval: UUID?
    @FocusState private var searchFocused: Bool

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

    /// The search matches connections by name/endpoint and objects by name.
    private var filteredSessions: [SessionStore.Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.profile.name.localizedCaseInsensitiveContains(searchText)
                || $0.profile.endpoint.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            connectionsSection
            Divider()
            objectsSection
        }
        .frame(width: AppMetrics.sidebarWidth)
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
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
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
        // Zero-size button whose only job is the ⌘F shortcut; `.hidden()`
        // would unregister the shortcut, so it stays at opacity 0.
        .background(
            Button("Search Connections") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textSecondary)
            TextField("Search connections", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.text)
                .focused($searchFocused)
                .onExitCommand { searchText = "" }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(AppIconButtonStyle(size: 18))
                .help("Clear the search (Esc)")
            } else {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.textDisabled)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(AppColors.bgApp)
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                .stroke(searchFocused ? AppColors.accent : AppColors.border,
                        lineWidth: searchFocused ? 2 : 1))
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 4)
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(spacing: 0) {
            SectionHeading(title: "Connections") {
                Button {
                    store.showingNewConnection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(AppIconButtonStyle(size: 22))
                .help("New Connection (⌘N)")
            }
            if filteredSessions.isEmpty {
                Text(store.sessions.isEmpty
                     ? "No connections yet — create one with ⌘N."
                     : "No connections match “\(searchText)”")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textDisabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
            } else {
                VStack(spacing: 1) {
                    ForEach(filteredSessions) { session in
                        ConnectionRowView(
                            profile: session.profile,
                            isSelected: session.id == store.selectedConnectionID)
                        .onTapGesture { store.selectConnection(session.id) }
                        .contextMenu {
                            Button("Remove Connection…", role: .destructive) {
                                pendingRemoval = session.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Objects

    private var objectsSection: some View {
        VStack(spacing: 0) {
            SectionHeading(title: "Objects") {
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
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The uppercase 11px section label with trailing actions (reference
/// `.section-heading`).
private struct SectionHeading<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
            actions
        }
        .frame(height: 34)
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}

private struct SidebarPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AppColors.textDisabled)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
    }
}

/// One connection row: engine monogram chip, name (+env dot + read-only
/// lock), endpoint subtitle; hover well, selected blue block with a left
/// accent bar (reference `.connection-item`).
private struct ConnectionRowView: View {
    let profile: ConnectionProfile
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            EngineBadge(engine: profile.engine)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                        .lineLimit(1)
                    if profile.environment != .development {
                        Circle()
                            .fill(profile.environment == .production
                                  ? AppColors.production : AppColors.warning)
                            .frame(width: 6, height: 6)
                            .help("\(profile.environment.rawValue.capitalized) environment")
                    }
                    if profile.readOnly {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppColors.textDisabled)
                            .help("Read-only connection")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textDisabled)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(AppColors.success)
                .frame(width: 8, height: 8)
                .help("Connected")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(isSelected ? AppColors.bgSelected : (hovered ? AppColors.bgHover : .clear))
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppColors.accent)
                        .frame(width: 2)
                        .padding(.vertical, 5)
                }
            })
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var subtitle: String {
        var parts = [endpointDisplay]
        if profile.demo { parts.append("Demo") }
        return parts.joined(separator: " · ")
    }

    /// SQLite endpoints are local absolute paths; show only the file name.
    private var endpointDisplay: String {
        guard profile.engine == .sqlite else { return profile.endpoint }
        return (profile.endpoint as NSString).lastPathComponent
    }
}

/// One navigator row with its full interaction set (double-click runs the
/// SELECT, single click drops the template, context menu).
private struct InteractiveObjectRow: View {
    @Environment(SessionStore.self) private var store
    let node: SessionStore.ObjectNode

    var body: some View {
        ObjectRowView(node: node)
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
/// DisclosureGroup tree (OutlineGroup exposes no expansion binding, and
/// filtering must auto-expand the ancestor chain of every hit).
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
        .disclosureGroupStyle(SidebarDisclosureStyle())
    }
}

/// Compact disclosure arrows matching the 14px tree column.
private struct SidebarDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.textDisabled)
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { configuration.isExpanded.toggle() }
                configuration.label
            }
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct ObjectRowView: View {
    let node: SessionStore.ObjectNode
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.icon(for: node.object.kind))
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 16)
            Text(node.object.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(hovered ? AppColors.text : AppColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let detail = node.object.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.textDisabled)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(minHeight: 29)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                .fill(hovered ? AppColors.bgHover : .clear))
        .onHover { hovered = $0 }
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
