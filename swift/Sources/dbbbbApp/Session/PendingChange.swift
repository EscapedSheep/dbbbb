import Foundation
import dbbbbCore

/// One staged change in the batch-editing buffer (ROADMAP M3 批量编辑暂存).
/// The payload is the same `RecordReview` a single edit produces, so staging
/// adds no new write path: applying the batch replays each review's
/// `dataChange` — optimistic-lock baseline included — in order.
struct PendingChange: Identifiable {
    let id = UUID()
    let review: RecordReview

    init(review: RecordReview) { self.review = review }

    var isDelete: Bool { review.isDelete }
    var isInsert: Bool { review.draft.isInsert }

    /// SF Symbol for the change kind, shown in the staging bar and the
    /// batch review list.
    var icon: String {
        if review.isDelete { return "trash" }
        if review.draft.isInsert { return "plus.rectangle" }
        return "pencil"
    }

    /// One-line summary: "Update status, note on id=1 — orders",
    /// "Delete row id=1 — orders", "Insert id, name — orders".
    var summaryText: String {
        let target = review.draft.object.name
        if review.isDelete {
            return "Delete \(Self.rowLabel(from: review.draft.original)) — \(target)"
        }
        if review.draft.isInsert {
            let keys = review.changes.map(\.key)
            return keys.isEmpty
                ? "Insert with column defaults — \(target)"
                : "Insert \(keys.joined(separator: ", ")) — \(target)"
        }
        let keys = review.changes.map(\.key).joined(separator: ", ")
        return "Update \(keys) on \(Self.rowLabel(from: review.draft.original)) — \(target)"
    }

    /// Identifies the row an update/delete targets by its first original
    /// field ("id=1") — the primary key is unknown at this layer, and the
    /// first column is the conventional key position.
    private static func rowLabel(from original: [(key: String, value: DisplayValue)]) -> String {
        guard let first = original.first else { return "row" }
        return "row \(first.key)=\(DisplayFormatting.cellText(first.value))"
    }
}

/// Batch-level rules over a set of staged changes.
enum PendingBatch {
    /// The confirmation token for applying a batch, mirroring the
    /// single-change discipline: a batch containing any delete always
    /// requires DELETE (destructive beats production); otherwise production
    /// connections require APPLY; development batches apply directly.
    static func confirmationToken(
        containsDelete: Bool,
        environment: ConnectionEnvironment
    ) -> String? {
        if containsDelete { return "DELETE" }
        return environment == .production ? "APPLY" : nil
    }
}
