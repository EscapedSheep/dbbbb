import SwiftUI

/// The Electron-style shell: a 44px header (sidebar toggle + wordmark +
/// connection breadcrumb + window actions), then the connections column
/// (collapsible, animated), the objects column, and the workspace, with a
/// 24px status bar across the bottom.
struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    /// Persisted collapse state of the connections column (⌃⌘S toggles).
    @AppStorage("connectionsColumnCollapsed") private var connectionsCollapsed = false
    /// Sidebar search text, shared by both columns (connections + objects).
    @State private var sidebarSearch = ""

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            AppHeaderView(connectionsCollapsed: $connectionsCollapsed)
            HStack(spacing: 0) {
                if !connectionsCollapsed {
                    ConnectionsColumnView(searchText: $sidebarSearch)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ObjectsColumnView(
                    searchText: $sidebarSearch,
                    connectionsCollapsed: $connectionsCollapsed)
                QueryWorkspaceView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            StatusBarView()
                .frame(height: AppMetrics.statusBarHeight)
        }
        .background(AppColors.bgApp)
        .preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: $store.showingNewConnection) {
            NewConnectionView()
        }
    }
}

/// The top bar: sidebar toggle, wordmark, breadcrumb of the selected
/// connection, and the window-level actions (appearance, new connection).
private struct AppHeaderView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @Binding var connectionsCollapsed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    connectionsCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
            }
            .buttonStyle(.appIcon)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(connectionsCollapsed
                  ? "Show the connections column (⌃⌘S)"
                  : "Hide the connections column (⌃⌘S)")
            Wordmark()
            Rectangle()
                .fill(AppColors.border)
                .frame(width: 1, height: 18)
                .padding(.trailing, 6)
            if let profile = store.selectedSession?.profile {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                    Text("/")
                        .foregroundStyle(AppColors.borderStrong)
                    Text(profile.database)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textDisabled)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                ForEach(AppAppearance.allCases) { mode in
                    Button {
                        appearance = mode
                    } label: {
                        if mode == appearance {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .help("Appearance")
        }
        // The hidden title bar's traffic lights occupy their own strip above
        // the header (measured on macOS 26: dots row ends ~28pt above the
        // header row), so no horizontal clearance is needed — a plain 10pt
        // margin makes the toggle the true leftmost element.
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: AppMetrics.headerHeight)
        .background(AppColors.bgPanel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
    }
}

/// The boxed wordmark (reference `.wordmark` / `.wordmark-mark`).
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle()
                        .fill(AppColors.text)
                        .frame(height: 1)
                }
            }
            .frame(width: 12, height: 12)
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(AppColors.text, lineWidth: 1))
            Text("dbbbb")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(AppColors.text)
        }
    }
}
