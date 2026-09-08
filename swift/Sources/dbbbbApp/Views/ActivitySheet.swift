import SwiftUI
import dbbbbCore

/// Server-activity viewer (ROADMAP M2 ⑨): the selected connection's in-flight
/// operations as a table (id / user / database / age / state / statement
/// excerpt), with manual refresh and a per-row kill behind a confirmation
/// naming the target. Refresh and kill state live in `SessionStore` — the
/// sheet renders the live snapshot, and failures surface through the
/// redacted banner (and inline for kills).
struct ActivitySheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selection: ServerActivity.ID?
    @State private var killTarget: ServerActivity?
    @State private var confirmation = ""
    @State private var isKilling = false
    @State private var killError: String?

    private var activities: [ServerActivity] {
        store.serverActivity?.activities ?? []
    }

    private var isProduction: Bool {
        store.selectedSession?.profile.environment == .production
    }

    /// The token production connections must type before a kill starts (the
    /// editing milestone's APPLY pattern).
    private let confirmationToken = "KILL"

    private var canConfirmKill: Bool {
        !isProduction || confirmation == confirmationToken
    }

    private var selectedActivity: ServerActivity? {
        activities.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let killTarget {
                confirmView(killTarget)
            } else if activities.isEmpty, !store.isLoadingActivity {
                ContentUnavailableView(
                    "No Active Operations",
                    systemImage: "checkmark.circle",
                    description: Text("The server is idle right now."))
            } else {
                tableView
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 440)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 0) {
            Text("Activity — \(store.selectedSession?.profile.name ?? "")")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isProduction ? 4 : 10)
            if isProduction {
                Label("Production connection — kills interrupt real server work.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.production)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
        }
    }

    private var tableView: some View {
        Table(activities, selection: $selection) {
            TableColumn("ID", value: \.id)
                .width(70)
            TableColumn("User") { activity in
                Text(activity.user ?? "—")
            }
            .width(90)
            TableColumn("Database") { activity in
                Text(activity.database ?? "—")
            }
            .width(90)
            TableColumn("Age") { activity in
                Text(DisplayFormatting.ageText(activity.age))
            }
            .width(60)
            TableColumn("State") { activity in
                Text(activity.state ?? "—")
            }
            .width(70)
            TableColumn("Statement") { activity in
                Text(activity.statement ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func confirmView(_ activity: ServerActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirm kill")
                        .font(.headline)
                    Text("Kill operation **\(activity.id)**"
                        + (activity.user.map { " by **\($0)**" } ?? "")
                        + " on **\(store.selectedSession?.profile.name ?? "")**?")
                        .font(.callout)
                    if let statement = activity.statement {
                        Text(Self.statementExcerpt(statement))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(AppColors.production)
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Killing interrupts server work")
                        .font(.callout.weight(.medium))
                    Text(killSemanticsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
            }
            if let killError {
                Text(killError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if isProduction {
                LabeledContent {
                    TextField("", text: $confirmation)
                } label: {
                    Text("Type **\(confirmationToken)** to confirm")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var killSemanticsText: String {
        switch store.selectedSession?.profile.engine {
        case .postgresql:
            "PostgreSQL cancels the running statement; the client connection and its transaction stay alive."
        case .mysql:
            "MySQL kills the whole connection, not just the running statement."
        case .mongodb:
            "MongoDB aborts the operation; the client connection stays alive."
        case .sqlite, nil:
            ""
        }
    }

    private var footer: some View {
        HStack {
            if killTarget != nil {
                Button("Back") {
                    killTarget = nil
                    confirmation = ""
                    killError = nil
                }
                .disabled(isKilling)
                Spacer()
                Button("Confirm Kill") {
                    if let killTarget { kill(killTarget) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirmKill || isKilling)
            } else {
                if store.isLoadingActivity {
                    ProgressView()
                        .controlSize(.small)
                }
                if let reason = store.killActivityUnavailableReason, selectedActivity != nil {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { store.refreshServerActivity() }
                    .disabled(store.isLoadingActivity)
                Button("Kill…") {
                    if let selectedActivity { killTarget = selectedActivity }
                }
                .disabled(selectedActivity == nil || !store.canKillServerActivity)
                .help(store.killActivityUnavailableReason ?? "Cancel the selected operation")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func kill(_ activity: ServerActivity) {
        isKilling = true
        killError = nil
        Task { @MainActor in
            let succeeded = await store.killServerActivity(id: activity.id)
            isKilling = false
            if succeeded {
                killTarget = nil
                confirmation = ""
                selection = nil
            } else {
                // The store already surfaced the redacted banner; show it
                // inline too, since the sheet covers the main window.
                killError = store.errorMessage
            }
        }
    }

    /// The excerpt the confirmation names the target by.
    static func statementExcerpt(_ statement: String) -> String {
        ServerActivity.truncatedStatement(statement, limit: 160)
    }
}
