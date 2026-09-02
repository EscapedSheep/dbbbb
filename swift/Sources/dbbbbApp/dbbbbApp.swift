import SwiftUI

@main
struct dbbbbApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { store.showingNewConnection = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Appearance") {
                AppearanceMenu()
            }
        }
    }
}

/// System / Light / Dark override, persisted via AppStorage and applied
/// with `preferredColorScheme` at the window root.
private struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.inline)
    }
}
