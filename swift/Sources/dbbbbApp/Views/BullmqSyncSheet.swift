import SwiftUI

/// "Sync to local SQL" sheet for BullMQ connections: pick a queue (the
/// discovered collection nodes), watch progress, cancel. Materializes every
/// job of the queue into a local SQLite table that opens as a new read-only
/// SQL session; Redis is never modified. Mirrors the Electron reference's
/// `BullmqSyncDialog`.
struct BullmqSyncSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var queue = ""
    @State private var syncing = false

    private var queues: [String] { store.bullmqSyncQueues }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Snapshot") {
                    Text("Materialize every job of one queue into a local SQLite table. The snapshot opens as a new read-only SQL connection with a jobs table. Redis is never modified; re-syncing a queue replaces its previous snapshot.")
                        .foregroundStyle(.secondary)
                    Picker("Queue", selection: $queue) {
                        ForEach(queues, id: \.self) { candidate in
                            Text(candidate).tag(candidate)
                        }
                    }
                    .disabled(syncing)
                    if queues.isEmpty {
                        Text("No queues discovered — refresh the object list after Redis has created at least one queue.")
                            .foregroundStyle(.secondary)
                    }
                    if syncing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Syncing \(queue)")
                                Text("\(store.bullmqSyncProgress.formatted()) jobs written so far.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bgPanel)
            HStack {
                Text("All eight job states are included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if syncing {
                    Button("Cancel Sync") { store.cancelBullmqSync() }
                        .buttonStyle(.appSecondary)
                } else {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.appSecondary)
                }
                Button {
                    startSync()
                } label: {
                    Label(syncing ? "Syncing" : "Sync Queue", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.appPrimary)
                .disabled(syncing || queue.isEmpty)
            }
            .padding()
            .background(AppColors.bgSubtle)
            .overlay(alignment: .top) {
                Rectangle().fill(AppColors.border).frame(height: 1)
            }
        }
        .frame(minWidth: 480, minHeight: 240)
        .onAppear {
            if !queues.contains(queue) { queue = queues.first ?? "" }
        }
        .onChange(of: queues) {
            // Sync targets are re-derived when the object list refreshes.
            if !queues.contains(queue) { queue = queues.first ?? "" }
        }
        // Escape must not dismiss mid-sync; the cancel path is explicit.
        .interactiveDismissDisabled(syncing)
    }

    private func startSync() {
        guard !queue.isEmpty else { return }
        syncing = true
        Task { @MainActor in
            let succeeded = await store.syncBullmqSnapshot(queue: queue)
            syncing = false
            if succeeded { dismiss() }
        }
    }
}
