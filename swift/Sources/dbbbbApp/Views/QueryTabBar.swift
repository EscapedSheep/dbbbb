import SwiftUI

/// The workspace's result tab bar (ROADMAP M3 多结果标签页), restyled to the
/// Electron reference: 32px bottom-anchored tabs on a subtle strip, the active
/// tab panel-colored with top/side borders, a trailing "+" opens a tab.
/// Switching never loses a tab's state — editor text, result, preview paging,
/// and staged batch all live on the tab.
struct QueryTabBar: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(store.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == store.selectedTabID)
                }
                Button {
                    store.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.appIcon)
                .padding(.bottom, 3)
                .help("New tab")
            }
            .padding(.horizontal, 5)
        }
        .background(AppColors.bgSubtle)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
    }
}

private struct TabChip: View {
    @Environment(SessionStore.self) private var store

    let tab: QueryTab
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if tab.isExecuting {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(
                    isSelected ? AppColors.text
                        : tab.isDraft ? AppColors.textDisabled
                        : AppColors.textSecondary)
            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(AppIconButtonStyle(size: 16))
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 100, maxWidth: 200, minHeight: 32)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: AppMetrics.cornerRadius,
                                   topTrailingRadius: AppMetrics.cornerRadius)
                .fill(isSelected ? AppColors.bgPanel
                      : hovered ? AppColors.bgHover : .clear))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: AppMetrics.cornerRadius,
                                   topTrailingRadius: AppMetrics.cornerRadius)
                .stroke(isSelected ? AppColors.border : .clear, lineWidth: 1))
        // Cover the active tab's bottom edge so it reads as part of the panel
        // below, not as a chip floating on the strip.
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle().fill(AppColors.bgPanel).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(tab.id) }
        .onHover { hovered = $0 }
        .help(tab.title)
    }
}
