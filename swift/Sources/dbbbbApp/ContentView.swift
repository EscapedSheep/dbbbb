import SwiftUI

/// Three-column shell: connections (sidebar) · objects (content) · query & results (detail).
struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ConnectionListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ObjectListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            QueryWorkspaceView()
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: $store.showingNewConnection) {
            NewConnectionView()
        }
    }
}
