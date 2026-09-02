import SwiftUI

/// Monospaced query editor with a placeholder and a subtle well background.
/// ⌘Return runs the query (toolbar shortcut, so it works while the editor has focus).
struct QueryEditorView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .topLeading) {
            TextEditor(text: $store.queryText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
            if store.queryText.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .background(.quaternary.opacity(0.4))
    }

    private var placeholder: String {
        if store.selectedSession?.profile.engine == .mongodb {
            switch store.mongoQueryMode {
            case .find:
                return "{ \"status\": \"ok\" }   —  ⌘Return to run"
            case .aggregate:
                return "[ { \"$match\": { \"status\": \"ok\" } } ]   —  ⌘Return to run"
            }
        }
        return "select * from …   —  ⌘Return to run"
    }
}
