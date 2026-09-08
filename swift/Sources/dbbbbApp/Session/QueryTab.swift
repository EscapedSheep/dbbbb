import Foundation
import Observation
import dbbbbCore
import dbbbbKit

/// One result tab of the query workspace (ROADMAP M3 多结果标签页): its own
/// editor text, result, execution/cancellation state, preview browsing state
/// (page/sort/filter/equalities plus the FK metadata backing row jumps), and
/// staged batch edits.
///
/// Tabs belong to the selected connection — switching or removing the
/// connection discards them (the pre-tabs cleanup discipline, now per tab).
/// Switching tabs never cancels an in-flight query: it keeps running and its
/// result lands back on its own tab (stale guards compare the tab's own
/// request id, so a background completion can never clobber the tab the user
/// is looking at).
@MainActor
@Observable
final class QueryTab: Identifiable {
    let id = UUID()

    /// Editor text; seeded with the default query for new tabs when the
    /// object list is known.
    var queryText: String
    /// Find vs. aggregate for MongoDB connections; SQL engines ignore it.
    var mongoQueryMode: SessionStore.MongoQueryMode = .find

    var result: QueryResult?
    var isExecuting = false

    /// The object whose preview is shown; nil after ad-hoc queries. Editing
    /// is offered only for previews.
    var previewedObject: DatabaseObject?
    /// Paging/sort/filter state of the tab's preview (ROADMAP M1 ①②).
    var previewOffset = 0
    var previewSort: PreviewRequest.Sort?
    var previewFilter: PreviewRequest.Filter?
    /// Exact-match predicates set by a foreign-key jump (ROADMAP M1 ⑤).
    var previewEqualities: [PreviewRequest.Equality] = []
    /// Foreign keys of the previewed object, backing the row context menu.
    var previewedForeignKeys: [ForeignKey] = []

    /// The staged batch (ROADMAP M3 批量编辑暂存). Bound to this tab's
    /// previewed object — the "one batch per previewed object" invariant —
    /// so it follows the tab when switching, never mixing across objects.
    var pendingChanges: [PendingChange] = []

    // In-flight execution bookkeeping (per tab; see the type comment).
    var executionTask: Task<Void, Never>?
    var activeRequestID: UUID?
    /// Set when the user cancelled this tab's in-flight request; the
    /// adapter's cancellation error is then silenced.
    var cancellationRequested = false

    init(queryText: String = "") {
        self.queryText = queryText
    }

    /// Tab label: the previewed object's name, else the query's first line,
    /// else a placeholder.
    var title: String {
        if let object = previewedObject { return object.name }
        let line = queryText
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return String(line.prefix(24)) }
        return result != nil ? "Result" : "New Tab"
    }

    /// Draft tabs never ran anything; the tab bar dims them.
    var isDraft: Bool {
        result == nil && previewedObject == nil && !isExecuting
    }
}
