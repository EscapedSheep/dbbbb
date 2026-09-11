import SwiftUI
import dbbbbCore

/// Left column: the search field (⌘F) and the CONNECTIONS section. The search
/// text is shared with the objects column via a binding — typing filters both
/// (connections by name/endpoint, the object tree through ObjectTreeFilter).
struct ConnectionsColumnView: View {
    @Environment(SessionStore.self) private var store
    @Binding var searchText: String
    @FocusState private var searchFocused: Bool
    @State private var pendingRemoval: UUID?

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
            SidebarSectionHeading(title: "Connections") {
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
                SidebarPlaceholder(text: store.sessions.isEmpty
                    ? "No connections yet — create one with ⌘N."
                    : "No connections match “\(searchText)”")
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(filteredSessions) { session in
                            SidebarConnectionRow(
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
        .frame(width: AppMetrics.columnWidth)
        .frame(maxHeight: .infinity)
        .background(AppColors.bgPanel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppColors.border).frame(width: 1)
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
}
