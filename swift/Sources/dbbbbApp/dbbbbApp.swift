import SwiftUI
import AppKit
import dbbbbKit

@main
struct dbbbbApp: App {
    @State private var store = SessionStore(snapshotStore: BullmqSnapshotStore())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                // Snapshots are session-scoped: every managed file goes on exit.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.deleteAllSnapshots()
                }
                // CLI launches (swift run / .build/debug) start unfocused;
                // come forward like a LaunchServices-launched app would.
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
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
