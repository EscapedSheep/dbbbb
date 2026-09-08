import SwiftUI
import dbbbbCore

/// Staging indicator strip (ROADMAP M3 批量编辑暂存): sits between the filter
/// bar and the results while the batch is non-empty. Shows the count, expands
/// to a per-change list (kind icon + summary + per-item remove), and offers
/// Clear and the batch review. Applying happens only through the review sheet.
struct PendingChangesBar: View {
    @Environment(SessionStore.self) private var store

    @State private var expanded = false
    @State private var showingReview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.secondary)
                Text("\(store.pendingChanges.count) staged \(store.pendingChanges.count == 1 ? "change" : "changes")")
                    .font(.callout)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(expanded ? "Hide the staged changes" : "List the staged changes")
                Spacer()
                Button("Clear") { store.clearPendingChanges() }
                    .help("Discard every staged change")
                Button("Review & Apply…") { showingReview = true }
                    .disabled(!store.canApplyPendingChanges)
                    .help("Review the batch and apply it in order")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if expanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(store.pendingChanges) { pending in
                        HStack(spacing: 8) {
                            Image(systemName: pending.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(pending.summaryText)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                store.removePendingChange(id: pending.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove this change from the batch")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(.bar)
        .sheet(isPresented: $showingReview) {
            BatchReviewSheet(isPresented: $showingReview)
        }
    }
}

/// Batch review (ROADMAP M3 批量编辑暂存): every staged change listed with its
/// field-level before → after, one confirmation for the whole batch (deletes
/// keep the type-DELETE discipline, production keeps type-APPLY), then a
/// sequential apply that stops at the first failure — applied entries are
/// already written and leave the list, the rest stay staged.
struct BatchReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var store

    @Binding var isPresented: Bool

    @State private var confirmation = ""
    @State private var applying = false
    @State private var error: String?

    private var environment: ConnectionEnvironment {
        store.selectedSession?.profile.environment ?? .development
    }

    private var confirmationToken: String? {
        PendingBatch.confirmationToken(
            containsDelete: store.pendingChanges.contains { $0.isDelete },
            environment: environment)
    }

    private var canApply: Bool {
        !applying && store.canApplyPendingChanges
            && (confirmationToken == nil || confirmation == confirmationToken)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Review Staged Changes (\(store.pendingChanges.count))")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, environment == .development ? 10 : 4)
            if environment == .production {
                Label("Production connection — review every change before applying.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.production)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Text("Changes apply in order; the batch stops at the first failure — already-applied changes stay applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.pendingChanges) { pending in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(pending.summaryText, systemImage: pending.icon)
                                .font(.callout.weight(.medium))
                            if !pending.review.isDelete {
                                ForEach(Array(pending.review.changes.enumerated()), id: \.offset) { _, change in
                                    HStack(spacing: 6) {
                                        Text(change.key)
                                            .foregroundStyle(.secondary)
                                        Text(change.before.map(DisplayFormatting.cellText) ?? "—")
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.tertiary)
                                        Text(DisplayFormatting.cellText(change.after))
                                            .lineLimit(1)
                                    }
                                    .font(.caption)
                                    .padding(.leading, 24)
                                }
                                ForEach(pending.review.omittedKeys, id: \.self) { key in
                                    Text("\(key): (column default)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 24)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            if let token = confirmationToken {
                Divider()
                LabeledContent {
                    TextField("", text: $confirmation)
                } label: {
                    Text("Type **\(token)** to confirm")
                }
                .padding(12)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(applying
                       ? "Applying…"
                       : "Apply \(store.pendingChanges.count) \(store.pendingChanges.count == 1 ? "Change" : "Changes")") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380)
    }

    private func apply() {
        guard canApply else { return }
        applying = true
        error = nil
        Task {
            let applied = await store.applyPendingChanges()
            applying = false
            if applied {
                isPresented = false
                dismiss()
            } else {
                // Partial success: the store's banner message is mirrored here;
                // the remaining entries are still listed for fixing/retry.
                error = store.errorMessage ?? "The batch was not applied."
            }
        }
    }
}
