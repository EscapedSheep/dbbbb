import SwiftUI
import dbbbbCore
import dbbbbKit

/// History/favorites popover: clicking an entry loads its text into the query
/// editor; entries can be favorited, deleted, or cleared (favorites survive).
struct QueryHistoryView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if store.queryEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Queries Yet", systemImage: "clock")
                } description: {
                    Text("Executed queries show up here.")
                }
            } else {
                List {
                    let favorites = store.queryEntries.filter(\.favorite)
                    let history = store.queryEntries.filter { !$0.favorite }
                    if !favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(favorites) { entry in QueryEntryRow(entry: entry, dismiss: dismiss) }
                        }
                    }
                    if !history.isEmpty {
                        Section("History") {
                            ForEach(history) { entry in QueryEntryRow(entry: entry, dismiss: dismiss) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Clear History") { store.clearQueryHistory() }
                    .disabled(store.queryEntries.allSatisfy(\.favorite))
                    .help("Remove all non-favorite entries")
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 380, height: 440)
    }
}

private struct QueryEntryRow: View {
    @Environment(SessionStore.self) private var store
    let entry: QueryEntry
    let dismiss: DismissAction

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.loadQueryEntry(entry)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: EngineIcon.systemName(for: entry.engine))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                store.toggleFavorite(entryID: entry.id)
            } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .foregroundStyle(entry.favorite ? AppColors.warning : .secondary)
            }
            .buttonStyle(.borderless)
            .help(entry.favorite ? "Remove from favorites" : "Add to favorites")
            Button {
                store.removeQueryEntry(entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete this entry")
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [entry.engine.displayName]
        if let collection = entry.collection { parts.append(collection) }
        parts.append(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
