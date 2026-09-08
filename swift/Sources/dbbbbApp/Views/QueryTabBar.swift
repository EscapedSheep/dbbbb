import SwiftUI

/// The workspace's result tab bar (ROADMAP M3 多结果标签页): one chip per tab
/// (title, spinner while its query runs, close button), a trailing "+" to
/// open a tab. Switching never loses a tab's state — editor text, result,
/// preview paging, and staged batch all live on the tab.
struct QueryTabBar: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == store.selectedTabID)
                }
                Button {
                    store.newTab()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .help("New tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

private struct TabChip: View {
    @Environment(SessionStore.self) private var store

    let tab: QueryTab
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if tab.isExecuting {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(tab.title)
                .lineLimit(1)
                .foregroundStyle(tab.isDraft && !isSelected ? .tertiary : .primary)
            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close tab")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(tab.id) }
        .help(tab.title)
    }
}
