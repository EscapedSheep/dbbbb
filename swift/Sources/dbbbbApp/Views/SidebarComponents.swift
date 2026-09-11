import SwiftUI
import dbbbbCore

/// Shared sidebar pieces for the two columns (connections / objects):
/// section headings, placeholders, and both row types with their full
/// interaction sets. Split out of the old single-column SidebarView.
struct SidebarSectionHeading<Actions: View>: View {
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

struct SidebarPlaceholder: View {
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
struct SidebarConnectionRow: View {
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
struct InteractiveObjectRow: View {
    @Environment(SessionStore.self) private var store
    let node: SessionStore.ObjectNode

    var body: some View {
        SidebarObjectRow(node: node)
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
struct FilteredObjectRows: View {
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

/// Compact disclosure arrows matching the tree row column.
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

struct SidebarObjectRow: View {
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
