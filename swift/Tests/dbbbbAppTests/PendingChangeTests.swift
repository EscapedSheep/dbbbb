import Foundation
import Testing
import dbbbbCore
@testable import dbbbbApp

/// Batch-staging model (ROADMAP M3 批量编辑暂存): summary lines and the batch
/// confirmation-token rule. Pure, no store.
struct PendingChangeTests {
    private let table = DatabaseObject(id: "t1", parentID: nil, name: "orders", kind: .table)

    private func draft(original: [(key: String, value: DisplayValue)],
                       insert: Bool = false) -> RecordDraft {
        RecordDraft(
            object: table, environment: .development,
            columns: original.map { ColumnMeta(name: $0.key, typeName: "") },
            original: original,
            insertPrefill: insert ? original : nil)
    }

    @Test func updateSummaryNamesFieldsAndRow() {
        let review = RecordReview(
            draft: draft(original: [("id", .number(1)), ("status", .string("open"))]),
            changes: [("status", .string("open"), .string("paid")),
                      ("note", .null, .string("rush"))],
            changed: ["status": .string("paid"), "note": .string("rush")],
            isDelete: false)
        let pending = PendingChange(review: review)
        #expect(pending.summaryText == "Update status, note on row id=1 — orders")
        #expect(pending.icon == "pencil")
        #expect(!pending.isDelete && !pending.isInsert)
    }

    @Test func deleteSummaryNamesRow() {
        let review = RecordReview(
            draft: draft(original: [("id", .number(7))]),
            changes: [], changed: [:], isDelete: true)
        let pending = PendingChange(review: review)
        #expect(pending.summaryText == "Delete row id=7 — orders")
        #expect(pending.icon == "trash")
        #expect(pending.isDelete)
    }

    @Test func insertSummaryListsFields() {
        let review = RecordReview(
            draft: draft(original: [], insert: true),
            changes: [("id", nil, .number(1)), ("name", nil, .string("a"))],
            changed: ["id": .number(1), "name": .string("a")],
            isDelete: false)
        let pending = PendingChange(review: review)
        #expect(pending.summaryText == "Insert id, name — orders")
        #expect(pending.icon == "plus.rectangle")
        #expect(pending.isInsert)
    }

    @Test func insertWithAllDefaultsSaysSo() {
        let review = RecordReview(
            draft: draft(original: [], insert: true),
            changes: [], changed: [:],
            omittedKeys: ["id", "name"], isDelete: false)
        #expect(PendingChange(review: review).summaryText == "Insert with column defaults — orders")
    }

    // MARK: Confirmation token

    /// Deletes keep the type-DELETE discipline even in production;
    /// production without deletes types APPLY; development applies directly.
    @Test func confirmationTokenFollowsSingleChangeDiscipline() {
        #expect(PendingBatch.confirmationToken(containsDelete: true, environment: .production) == "DELETE")
        #expect(PendingBatch.confirmationToken(containsDelete: true, environment: .development) == "DELETE")
        #expect(PendingBatch.confirmationToken(containsDelete: false, environment: .production) == "APPLY")
        #expect(PendingBatch.confirmationToken(containsDelete: false, environment: .development) == nil)
        #expect(PendingBatch.confirmationToken(containsDelete: false, environment: .staging) == nil)
    }
}
