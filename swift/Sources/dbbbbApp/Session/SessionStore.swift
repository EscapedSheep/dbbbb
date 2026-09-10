import Foundation
import Observation
import Synchronization
import dbbbbCore
import dbbbbKit

/// Shared cancellation flag for the running import. `Mutex` is not copyable,
/// so it cannot cross into the request closures; this reference box can.
private final class CancelFlag: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    func reset() { flag.withLock { $0 = false } }
    var isSet: Bool { flag.withLock { $0 } }
}

/// Serializes import progress callbacks onto the main actor. Adapters invoke
/// `onProgress` from their own executor, possibly in bursts; only the latest
/// counters matter, so bursts coalesce into at most one pending hop — no
/// per-event task flood and no out-of-order delivery.
final class ImportProgressRelay: Sendable {
    private let latest = Mutex<ImportProgress?>(nil)
    private let hopScheduled = Mutex(false)

    func send(_ progress: ImportProgress, deliver: @escaping @MainActor @Sendable (ImportProgress) -> Void) {
        latest.withLock { $0 = progress }
        let shouldSchedule = hopScheduled.withLock { scheduled -> Bool in
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor in
            hopScheduled.withLock { $0 = false }
            let progress = latest.withLock { $0 }
            if let progress { deliver(progress) }
        }
    }
}

/// UI-facing session state for one window. Main-actor isolated; adapters are
/// `Sendable` and only called with `await`, so no shared mutable state crosses tasks.
@MainActor
@Observable
final class SessionStore {
    struct Session: Identifiable {
        let profile: ConnectionProfile
        let adapter: any DatabaseAdapter
        var id: UUID { profile.id }
    }

    /// MongoDB editor mode, mirroring the Electron find/aggregate toggle.
    enum MongoQueryMode: String, CaseIterable, Sendable {
        case find
        case aggregate
    }

    /// Builds an adapter for a newly added connection. The demo connections
    /// are seeded at launch with `DemoAdapter` and never go through this factory.
    var makeAdapter: @Sendable (ConnectionInput) async throws -> any DatabaseAdapter = { input in
        switch input {
        case .postgres(let input): try PostgresAdapter(input: input)
        case .mysql(let input): try MySQLAdapter(input: input)
        case .mongo(let input): try await MongoAdapter(input: input)
        case .sqlite(let input): try SQLiteAdapter(input: input)
        case .bullmq(let input): try BullmqAdapter(input: input)
        }
    }

    private(set) var sessions: [Session] = []
    private(set) var selectedConnectionID: UUID?
    private(set) var objects: [DatabaseObject] = []
    /// The object the user last clicked or previewed; MongoDB queries run
    /// against it (the editor text is pure Extended JSON).
    private(set) var selectedObject: DatabaseObject?
    private(set) var isLoadingObjects = false
    private(set) var isApplyingChange = false
    /// Redacted message shown in the inline error banner. Connection-level:
    /// a background tab's failure still surfaces here.
    var errorMessage: String?
    var showingNewConnection = false

    /// Persistence for non-demo connections; nil disables it (tests, previews).
    private let connectionStore: ConnectionStore?
    /// Query history + favorites; nil disables recording.
    private let queryLibrary: QueryLibraryStore?
    /// Snapshot of the library, newest first; refreshed after every mutation.
    private(set) var queryEntries: [QueryEntry] = []

    // MARK: Tabs (ROADMAP M3 多结果标签页)

    /// The workspace's result tabs. Always non-empty (a lone empty draft tab
    /// is the zero state); they belong to the selected connection and are
    /// discarded on connection switch/removal. No hard count limit: every
    /// tab's result is already row- and byte-capped by the adapters.
    private(set) var tabs: [QueryTab] = [QueryTab()]
    private(set) var selectedTabID: UUID?

    /// The tab the workspace currently shows. Every per-tab property below
    /// forwards to it, keeping the pre-tabs API shape for views and tests.
    var activeTab: QueryTab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    /// Per-tab forwards: editor text and Mongo mode.
    var queryText: String {
        get { activeTab.queryText }
        set { activeTab.queryText = newValue }
    }
    var mongoQueryMode: MongoQueryMode {
        get { activeTab.mongoQueryMode }
        set { activeTab.mongoQueryMode = newValue }
    }
    /// Per-tab forwards: the visible result and execution flag.
    private(set) var result: QueryResult? {
        get { activeTab.result }
        set { activeTab.result = newValue }
    }
    private(set) var isExecuting: Bool {
        get { activeTab.isExecuting }
        set { activeTab.isExecuting = newValue }
    }
    /// Per-tab forwards: preview browsing state (the previewed object, paging,
    /// sort/filter, FK-jump equalities, and the previewed object's FKs).
    private(set) var previewedObject: DatabaseObject? {
        get { activeTab.previewedObject }
        set { activeTab.previewedObject = newValue }
    }
    private(set) var previewOffset: Int {
        get { activeTab.previewOffset }
        set { activeTab.previewOffset = newValue }
    }
    private(set) var previewSort: PreviewRequest.Sort? {
        get { activeTab.previewSort }
        set { activeTab.previewSort = newValue }
    }
    private(set) var previewFilter: PreviewRequest.Filter? {
        get { activeTab.previewFilter }
        set { activeTab.previewFilter = newValue }
    }
    private(set) var previewEqualities: [PreviewRequest.Equality] {
        get { activeTab.previewEqualities }
        set { activeTab.previewEqualities = newValue }
    }
    private(set) var previewedForeignKeys: [ForeignKey] {
        get { activeTab.previewedForeignKeys }
        set { activeTab.previewedForeignKeys = newValue }
    }
    /// Per-tab forward: the staged batch (ROADMAP M3 批量编辑暂存).
    private(set) var pendingChanges: [PendingChange] {
        get { activeTab.pendingChanges }
        set { activeTab.pendingChanges = newValue }
    }

    var selectedSession: Session? { sessions.first { $0.id == selectedConnectionID } }

    var resultIsDocuments: Bool {
        if case .documents = result { return true }
        return false
    }

    init(connectionStore: ConnectionStore? = ConnectionStore(),
         queryLibrary: QueryLibraryStore? = QueryLibraryStore(),
         snapshotStore: BullmqSnapshotStore? = nil) {
        self.connectionStore = connectionStore
        self.queryLibrary = queryLibrary
        self.snapshotStore = snapshotStore
        // Startup sweep: snapshots never outlive their session, so anything
        // left in the directory is a leftover from a previous run.
        if let snapshotStore { try? snapshotStore.sweepManagedFiles() }
        queryEntries = queryLibrary?.entries ?? []
        selectedTabID = tabs[0].id
        sessions = DemoAdapter.demoSessions().map { Session(profile: $0.profile, adapter: $0) }
        if let first = sessions.first { selectConnection(first.id) }
        restorePersistedConnections()
    }

    // MARK: Object tree

    struct ObjectNode: Identifiable {
        let object: DatabaseObject
        var children: [ObjectNode]?
        var id: String { object.id }
    }

    var objectTree: [ObjectNode] {
        let byParent = Dictionary(grouping: objects, by: { $0.parentID })
        func build(_ parent: String?) -> [ObjectNode]? {
            byParent[parent]?.map { ObjectNode(object: $0, children: build($0.id)) }
        }
        return build(nil) ?? []
    }

    // MARK: Tab management

    /// Opens a fresh tab (seeded with the default query when the object list
    /// is known) and selects it.
    func newTab() {
        let tab = QueryTab(queryText: seedQueryText())
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func selectTab(_ id: UUID) {
        guard selectedTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    /// Closes one tab, cancelling its in-flight query. Closing the last tab
    /// leaves a fresh draft tab — the workspace always has exactly one.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        cancelInFlight(tabs[index])
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = QueryTab(queryText: seedQueryText())
            tabs = [fresh]
            selectedTabID = fresh.id
        } else if selectedTabID == id || selectedTabID == nil {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    private func seedQueryText() -> String {
        guard let engine = selectedSession?.profile.engine else { return "" }
        return Self.defaultQuery(for: engine, objects: objects)
    }

    // MARK: Connections

    func selectConnection(_ id: UUID?) {
        guard selectedConnectionID != id else { return }
        cancelInFlight()
        selectedConnectionID = id
        resetSelectionState()
        loadObjects()
    }

    /// Clears everything tied to the previously selected connection.
    private func resetSelectionState() {
        // Staged batch edits are scoped to one connection's previews; a
        // connection switch discards every tab's batch with a notice.
        let stagedCount = tabs.reduce(0) { $0 + $1.pendingChanges.count }
        objects = []
        selectedObject = nil
        result = nil
        errorMessage = stagedCount > 0
            ? "Discarded \(stagedCount) staged \(stagedCount == 1 ? "change" : "changes") — the connection changed."
            : nil
        // Fresh workspace: one empty draft tab; loadObjects seeds its text.
        tabs = [QueryTab()]
        selectedTabID = tabs[0].id
        createStatement = nil
        tableStatistics = nil
        serverActivity = nil
        isLoadingActivity = false
        schemaPresentation = nil
        isLoadingSchema = false
    }

    /// Refresh zeroes the browsing state (new data may shift page contents)
    /// and reloads the visible preview from page one; the object list reload
    /// runs independently. Staged batch edits survive a refresh: each staged
    /// change carries its own optimistic-lock baseline, so data that shifted
    /// underneath surfaces as a per-item conflict at apply time instead.
    func refreshObjects() {
        previewOffset = 0
        previewSort = nil
        previewFilter = nil
        previewEqualities = []
        previewedForeignKeys = []
        if let object = previewedObject {
            loadPreview(object)
        }
        loadObjects()
    }

    /// Connects asynchronously; on failure nothing is added and the caller
    /// shows the (already redacted) error. Mirroring the Electron reference,
    /// where `adapter.connect()` performs a server round trip before the
    /// session exists, the new adapter must answer `listObjects()` before it
    /// is added — a dead server surfaces here, not at first query. A
    /// successful connection is persisted (manifest + Keychain secret) so it
    /// survives a restart.
    func addConnection(_ input: ConnectionInput) async throws {
        let makeAdapter = self.makeAdapter
        let adapter = try await probeWithTimeout {
            let adapter = try await makeAdapter(input)
            do {
                _ = try await adapter.listObjects()
            } catch {
                await adapter.close()
                throw error
            }
            return adapter
        } onAbandoned: { adapter in
            // The probe timed out but the connect eventually finished; nobody
            // owns this adapter, so close it instead of leaking the session.
            Task { await adapter.close() }
        }
        let session = Session(profile: adapter.profile, adapter: adapter)
        sessions.append(session)
        selectConnection(session.id)
        // After selectConnection, which clears the error banner.
        persist(input, id: session.id)
    }

    /// Per-instance so tests can shorten the budget without cross-test bleed.
    var connectProbeTimeout: Duration = .seconds(15)

    /// Raised when the connect probe exceeds `connectProbeTimeout`. Pre-redacted.
    struct ConnectProbeTimeoutError: dbbbbError, Equatable {
        var userMessage: String { "Could not connect: the server did not respond in time." }
    }

    /// Exactly-one gate for the probe timeout race: the first claimant wins
    /// and resumes the continuation; the loser cleans up. Mutex-backed.
    private final class ProbeResumeGate: @unchecked Sendable {
        private let claimed = Mutex(false)

        func claim() -> Bool {
            claimed.withLock { flag in
                if flag { return false }
                flag = true
                return true
            }
        }
    }

    /// Races the probe against `connectProbeTimeout` without ever awaiting the
    /// loser — adapter internals may sit on NIO futures that ignore task
    /// cancellation, so awaiting them after cancel() could hang the Add sheet
    /// indefinitely. Exactly one side resumes; a probe that finishes after the
    /// timeout is handed to `onAbandoned`.
    private func probeWithTimeout<T: Sendable>(
        _ probe: @escaping @Sendable () async throws -> T,
        onAbandoned: (@Sendable (T) -> Void)? = nil
    ) async throws -> T {
        let probeTask = Task { try await probe() }
        let gate = ProbeResumeGate()
        let timeout = connectProbeTimeout
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let result = await probeTask.result
                if gate.claim() {
                    continuation.resume(with: result)
                } else if case .success(let value) = result {
                    onAbandoned?(value)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    probeTask.cancel()
                    continuation.resume(throwing: ConnectProbeTimeoutError())
                }
            }
        }
    }

    /// Persist after a successful connect. A persistence failure keeps the
    /// live session but surfaces a redacted error; the entry just won't
    /// survive a restart.
    private func persist(_ input: ConnectionInput, id: UUID) {
        guard let connectionStore else { return }
        do {
            try connectionStore.save(
                PersistedConnection(id: id, input: input),
                secret: PersistedConnection.secret(for: input))
        } catch {
            errorMessage = Self.redactedMessage(for: error)
        }
    }

    /// Restore strategy: reconnect eagerly at launch. Adapters connect at
    /// construction and `Session` requires a live adapter, so lazy connect
    /// would ripple through every view; eager reconnect keeps the change
    /// local to this store. A connection that fails to restore stays in the
    /// manifest and Keychain — only an explicit user removal deletes
    /// persisted state — and surfaces one redacted error.
    private func restorePersistedConnections() {
        guard let connectionStore else { return }
        let persisted = connectionStore.loadConnections()
        guard !persisted.isEmpty else { return }
        Task { @MainActor in
            for record in persisted {
                do {
                    let secret = try connectionStore.secret(for: record.id)
                    let input = try record.makeInput(secret: secret)
                    let adapter = try await makeAdapter(input)
                    // The user may have removed this connection while the
                    // reconnect was in flight; never resurrect a zombie session.
                    guard connectionStore.loadConnections().contains(where: { $0.id == record.id }) else {
                        await adapter.close()
                        continue
                    }
                    // Keep the persisted UUID so the Keychain key and the
                    // manifest entry stay stable across launches.
                    let connected = adapter.profile
                    let profile = ConnectionProfile(
                        id: record.id, name: connected.name, engine: connected.engine,
                        endpoint: connected.endpoint, database: connected.database,
                        environment: connected.environment, readOnly: connected.readOnly)
                    sessions.append(Session(profile: profile, adapter: adapter))
                } catch {
                    errorMessage = Self.redactedMessage(for: error)
                }
            }
        }
    }

    func removeConnection(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if selectedConnectionID == id { cancelInFlight() }
        let session = sessions.remove(at: index)
        if selectedConnectionID == id {
            // Force reselection even if the first session coincides.
            selectedConnectionID = nil
            // selectConnection(nil) early-returns, so reset explicitly; this
            // also unsticks isLoadingObjects when the removed connection was
            // the last one with a load still in flight.
            resetSelectionState()
            isLoadingObjects = false
            selectConnection(sessions.first?.id)
        }
        // Snapshot sessions delete their backing file and never touch the
        // manifest; demo connections never touch disk or the Keychain.
        if let file = snapshotFiles.removeValue(forKey: id) {
            snapshotStore?.deleteSnapshot(at: file)
        } else if !session.profile.demo, let connectionStore {
            do {
                try connectionStore.remove(id: id)
            } catch {
                errorMessage = Self.redactedMessage(for: error)
            }
        }
        Task { await session.adapter.close() }
    }

    static func defaultQuery(for engine: DatabaseEngine, objects: [DatabaseObject]) -> String {
        if engine == .mongodb {
            return "{ }"
        }
        if engine == .bullmq {
            // The reference's DEFAULT_QUERY: a failed-jobs example. The first
            // discovered queue fills in for the placeholder name.
            let queue = objects.first { $0.kind == .collection }?.name ?? "emails"
            return "{\n  \"queue\": \"\(queue)\",\n  \"state\": \"failed\",\n  \"limit\": 100\n}"
        }
        let firstLeaf = objects.first { $0.kind == .table || $0.kind == .collection }
        if let firstLeaf,
           let statement = try? SelectStatementBuilder.selectLimit100(engine: engine, object: firstLeaf) {
            return statement
        }
        return firstLeaf.map { "select * from \($0.name) limit 100;" } ?? "select 1;"
    }

    // MARK: Objects & query

    func insertQueryTemplate(for object: DatabaseObject) {
        guard let session = selectedSession else { return }
        selectedObject = object
        if session.profile.engine == .mongodb {
            mongoQueryMode = .find
            queryText = "{ }"
        } else if session.profile.engine == .bullmq {
            // Node ids are `<queue>` or `<queue>:<state>`; the state tail is
            // matched against the known state names so colon-named queues
            // resolve to their queue. Queue nodes preview the failed state.
            var queue = object.id
            var state = "failed"
            if object.kind == .table,
               let jobState = BullmqJobState.allCases.first(where: { object.id.hasSuffix(":\($0.rawValue)") }) {
                queue = String(object.id.dropLast(jobState.rawValue.count + 1))
                state = jobState.rawValue
            }
            queryText = "{\n  \"queue\": \"\(queue)\",\n  \"state\": \"\(state)\",\n  \"limit\": 100\n}"
        } else {
            queryText = Self.selectStatement(for: object, engine: session.profile.engine)
        }
    }

    /// Double-click on a leaf: load its SELECT into the editor and run it
    /// immediately. SQL text comes from `SelectStatementBuilder` (the same
    /// identifier quoting as previews); a MongoDB collection runs the find
    /// template against it; a BullMQ queue/state node runs its jobs query.
    func runSelectLimit100(for object: DatabaseObject) {
        guard let session = selectedSession, !isExecuting else { return }
        if session.profile.engine == .mongodb {
            guard object.kind == .collection else { return }
        } else if session.profile.engine == .bullmq {
            guard object.kind == .collection || object.kind == .table else { return }
        } else {
            guard object.kind == .table || object.kind == .view else { return }
        }
        insertQueryTemplate(for: object)
        runQuery()
    }

    /// The select-limit-100 template for one object, quoted like previews;
    /// undecodable handles fall back to the plain interpolation.
    private static func selectStatement(for object: DatabaseObject, engine: DatabaseEngine) -> String {
        if let statement = try? SelectStatementBuilder.selectLimit100(engine: engine, object: object) {
            return statement
        }
        return "select * from \(object.name) limit 100;"
    }

    /// Switches the MongoDB editor between find and aggregate. Mirroring the
    /// Electron reference, untouched default text is swapped for the other
    /// mode's starter text so the editor never carries a filter into an
    /// aggregate run (or vice versa).
    func setMongoQueryMode(_ mode: MongoQueryMode) {
        guard mongoQueryMode != mode else { return }
        mongoQueryMode = mode
        let normalized = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalized.filter { !$0.isWhitespace }
        switch mode {
        case .aggregate where compact == "{}":
            queryText = Self.defaultPipeline
        case .find where compact == "[]" || normalized == Self.defaultPipeline:
            queryText = "{ }"
        default:
            break
        }
    }

    /// Starter pipeline shown when switching to aggregate with default text,
    /// identical to the Electron reference.
    static let defaultPipeline = "[\n  { \"$match\": {} }\n]"

    // MARK: Preview browsing (paging / sort / filter)

    /// One page of rows/documents per preview fetch.
    static let previewPageSize = PreviewRequest.defaultLimit

    /// Zero-based page index of the visible preview.
    var previewPageIndex: Int { previewOffset / Self.previewPageSize }
    /// Page-turn affordances for the status bar.
    var previewHasPreviousPage: Bool { previewedObject != nil && previewOffset > 0 }
    /// The adapters fetch page size + 1 rows, so a truncated preview result
    /// means a next page exists (byte-budget truncation is conflated here —
    /// a page of 100 rows almost never reaches it).
    var previewHasNextPage: Bool {
        previewedObject != nil && (result?.meta.truncated ?? false)
    }

    func preview(_ object: DatabaseObject) {
        guard selectedSession != nil, !isExecuting else { return }
        // Staged batch edits are scoped to one object; previewing a different
        // object discards them with a visible notice (set after loadPreview,
        // which clears the banner at its start).
        let discarding = previewedObject != nil && previewedObject?.id != object.id
        // Switching objects zeroes the browsing state.
        previewOffset = 0
        previewSort = nil
        previewFilter = nil
        previewEqualities = []
        previewedForeignKeys = []
        loadPreview(object)
        if discarding {
            discardPendingChanges(reason: "the previewed object changed")
        }
    }

    func nextPreviewPage() {
        guard let object = previewedObject, previewHasNextPage, !isExecuting else { return }
        previewOffset += Self.previewPageSize
        loadPreview(object)
    }

    func previousPreviewPage() {
        guard let object = previewedObject, previewOffset > 0, !isExecuting else { return }
        previewOffset = max(0, previewOffset - Self.previewPageSize)
        loadPreview(object)
    }

    /// Sort changes restart from page one.
    func setPreviewSort(_ sort: PreviewRequest.Sort?) {
        guard let object = previewedObject, !isExecuting, previewSort != sort else { return }
        previewSort = sort
        previewOffset = 0
        loadPreview(object)
    }

    /// Filter changes restart from page one; empty filter text clears.
    func setPreviewFilter(_ filter: PreviewRequest.Filter?) {
        let normalized = filter.flatMap { $0.contains.isEmpty ? nil : $0 }
        guard let object = previewedObject, !isExecuting, previewFilter != normalized else { return }
        previewFilter = normalized
        previewOffset = 0
        loadPreview(object)
    }

    /// The request for the tab's current browsing state; the request id is
    /// the one registered with the tab's `activeRequestID`, so Cancel
    /// interrupts page loads too.
    private func currentPreviewRequest(
        on tab: QueryTab,
        for object: DatabaseObject,
        requestID: UUID = UUID()
    ) -> PreviewRequest {
        PreviewRequest(
            object: object,
            offset: tab.previewOffset,
            limit: Self.previewPageSize,
            sort: tab.previewSort,
            filter: tab.previewFilter,
            equalities: tab.previewEqualities,
            requestID: requestID)
    }

    // MARK: Foreign-key jumps (ROADMAP M1 ⑤)

    /// The FK jumps the selected row can follow: the visible result is a
    /// preview of one table whose adapter opted into `SupportsForeignKeys`,
    /// the referenced object is previewable, and every FK column is present
    /// in the row and non-NULL (a NULL or missing leg can never match, so the
    /// menu hides the entry instead of offering a jump that finds nothing).
    func foreignKeyJumps(forRow row: [(key: String, value: DisplayValue)]) -> [ForeignKey] {
        guard let session = selectedSession,
              previewedObject != nil,
              session.adapter is any SupportsForeignKeys
        else { return [] }
        return previewedForeignKeys.filter { foreignKey in
            (foreignKey.referencedObject.kind == .table || foreignKey.referencedObject.kind == .view)
                && Self.equalityFilters(for: foreignKey, row: row) != nil
        }
    }

    /// The equality predicates one jump needs: each referenced column matched
    /// against the row's value of the paired FK column; nil when any leg is
    /// missing or NULL.
    static func equalityFilters(
        for foreignKey: ForeignKey,
        row: [(key: String, value: DisplayValue)]
    ) -> [PreviewRequest.Equality]? {
        let rowValues = Dictionary(row.map { ($0.key, $0.value) }) { first, _ in first }
        var equalities: [PreviewRequest.Equality] = []
        for (column, referencedColumn) in zip(foreignKey.columns, foreignKey.referencedColumns) {
            guard let value = rowValues[column], value != .null else { return nil }
            equalities.append(PreviewRequest.Equality(column: referencedColumn, value: value))
        }
        return equalities.isEmpty ? nil : equalities
    }

    /// Follows one foreign key from the selected row: the referenced object
    /// opens as a fresh preview (page one, no sort/grid filter, same page
    /// size) filtered to exactly the referenced row(s). Fails closed — a jump
    /// the menu never offered (stale row, non-previewable target) is refused
    /// silently; adapter errors surface in the redacted banner through the
    /// normal preview path.
    func jumpToReferencedRow(_ foreignKey: ForeignKey, row: [(key: String, value: DisplayValue)]) {
        guard let session = selectedSession, !isExecuting,
              previewedObject != nil,
              session.adapter is any SupportsForeignKeys,
              previewedForeignKeys.contains(foreignKey),
              foreignKey.referencedObject.kind == .table
                  || foreignKey.referencedObject.kind == .view,
              let equalities = Self.equalityFilters(for: foreignKey, row: row)
        else { return }
        // The jump lands on a different object; staged batch edits of the
        // previous one are discarded with a visible notice (set after
        // loadPreview, which clears the banner at its start).
        let discarding = previewedObject?.id != foreignKey.referencedObject.id
        previewOffset = 0
        previewSort = nil
        previewFilter = nil
        previewEqualities = equalities
        previewedForeignKeys = []
        loadPreview(foreignKey.referencedObject)
        if discarding {
            discardPendingChanges(reason: "the previewed object changed")
        }
    }

    /// Loads the preview of `object` into the active tab with its current
    /// page/sort/filter state. Previews register a request ID just like
    /// queries, so Cancel works. The task captures its tab: a background tab's
    /// completion lands on its own tab and never clobbers the visible one.
    private func loadPreview(_ object: DatabaseObject) {
        guard let session = selectedSession else { return }
        let tab = activeTab
        guard !tab.isExecuting else { return }
        let connectionID = session.id
        selectedObject = object
        tab.previewedObject = object
        errorMessage = nil
        tab.isExecuting = true
        let requestID = UUID()
        tab.activeRequestID = requestID
        let request = currentPreviewRequest(on: tab, for: object, requestID: requestID)
        let adapter = session.adapter
        tab.executionTask = Task { @MainActor in
            defer { finishExecution(on: tab, for: requestID) }
            do {
                let previewed = try await adapter.previewObject(request)
                // Ignore stale completions after the user switched connections
                // or a newer page load superseded this one on this tab.
                guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                tab.result = previewed
                // FK metadata backs the row context menu's "Jump to
                // Referenced Row"; a metadata failure degrades to no menu
                // entries, never a banner — the preview itself succeeded.
                if let foreignKeyAdapter = adapter as? any SupportsForeignKeys {
                    let keys = (try? await foreignKeyAdapter.foreignKeys(for: object)) ?? []
                    guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                    tab.previewedForeignKeys = keys
                } else {
                    tab.previewedForeignKeys = []
                }
            } catch {
                guard tab.activeRequestID == requestID else { return }
                // The screen still shows the previous data; never leave the
                // preview pointer aimed at the object that never loaded.
                tab.previewedObject = nil
                tab.previewOffset = 0
                tab.previewEqualities = []
                tab.previewedForeignKeys = []
                // Cancelled: keep the previous result, no banner.
                guard !tab.cancellationRequested, !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                tab.result = nil
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func runQuery() {
        guard let session = selectedSession, !isExecuting else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        previewedObject = nil
        previewEqualities = []
        previewedForeignKeys = []
        let command: DatabaseCommand
        if session.profile.engine == .mongodb {
            guard let object = selectedObject, object.kind == .collection else {
                errorMessage = "Select a collection in the object list first — MongoDB queries run against the selected collection."
                return
            }
            switch mongoQueryMode {
            case .find:
                command = .mongoFind(collection: object.name, filter: text)
            case .aggregate:
                command = .mongoAggregate(collection: object.name, pipeline: text)
            }
        } else if session.profile.engine == .bullmq {
            // The queue and state live inside the JSON text; no object needs
            // to be selected (unlike MongoDB's collection-scoped commands).
            command = .bullmqJobs(text)
        } else {
            command = .sql(text)
        }
        executeCommand(session: session, record: command) { adapter, options in
            try await adapter.execute(command, options: options)
        }
    }

    /// Shared execution core for ad-hoc queries and EXPLAIN runs (ROADMAP M2
    /// ⑧): registers the request ID on the active tab (Cancel and the
    /// staleness guards work per tab), surfaces redacted errors, and records
    /// history only for user queries (`record`) — explains are meta-queries
    /// and stay out of the history.
    private func executeCommand(
        session: Session,
        record historyCommand: DatabaseCommand?,
        operation: @escaping @Sendable (any DatabaseAdapter, ExecuteOptions) async throws -> QueryResult
    ) {
        let tab = activeTab
        errorMessage = nil
        tab.isExecuting = true
        let connectionID = session.id
        let adapter = session.adapter
        let options = ExecuteOptions()
        let requestID = options.requestID
        tab.activeRequestID = requestID
        tab.executionTask = Task { @MainActor in
            defer { finishExecution(on: tab, for: requestID) }
            do {
                let executed = try await operation(adapter, options)
                // Ignore stale completions after the user switched connections
                // or the tab started a newer execution.
                guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                tab.result = executed
                if let historyCommand { recordQuery(historyCommand, session: session) }
            } catch {
                // Cancelled: keep the previous result, no banner.
                guard !tab.cancellationRequested, !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    // MARK: Query formatting (ROADMAP M3 查询格式化)

    /// SQL-only: MongoDB editor text is Extended JSON, not SQL — the Format
    /// affordance fails closed there.
    var canFormatQuery: Bool {
        guard let session = selectedSession,
              session.profile.engine.isSQLFamily,
              !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// Formats the active tab's editor text in place. Conservative by
    /// construction (`SQLFormatter` never alters a token and self-verifies):
    /// anything unrecognized comes back unchanged.
    func formatCurrentQuery() {
        guard canFormatQuery else { return }
        queryText = SQLFormatter.format(queryText)
    }

    // MARK: Explain (ROADMAP M2 ⑧)

    /// The Explain affordance: there is query text and, for MongoDB, a
    /// collection is selected (the same gate as Run). BullMQ has no plan API
    /// and fails closed here.
    var canExplainQuery: Bool {
        guard let session = selectedSession, !isExecuting,
              !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if session.profile.engine == .bullmq { return false }
        if session.profile.engine == .mongodb {
            return selectedObject?.kind == .collection
        }
        return true
    }

    /// Explains the current editor query. SQL engines run the EXPLAIN form
    /// of the text (`EXPLAIN QUERY PLAN` on SQLite) through the normal
    /// execute path — bounds, timeout, cancel, and redacted errors all reuse
    /// it, and the plan renders as the normal rows grid. MongoDB wraps the
    /// parsed find/aggregate command as `{explain: …, verbosity:
    /// "queryPlanner"}` through the adapter's explain capability, respecting
    /// the current find/aggregate mode; adapters without it fail closed.
    func explainCurrentQuery() {
        guard let session = selectedSession, !isExecuting else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        previewedObject = nil
        previewEqualities = []
        previewedForeignKeys = []
        if session.profile.engine == .mongodb {
            guard let object = selectedObject, object.kind == .collection else {
                errorMessage = "Select a collection in the object list first — MongoDB queries run against the selected collection."
                return
            }
            guard session.adapter is any SupportsExplain else {
                errorMessage = "This connection does not support explaining queries."
                return
            }
            let command: DatabaseCommand
            switch mongoQueryMode {
            case .find:
                command = .mongoFind(collection: object.name, filter: text)
            case .aggregate:
                command = .mongoAggregate(collection: object.name, pipeline: text)
            }
            executeCommand(session: session, record: nil) { adapter, options in
                guard let explainer = adapter as? any SupportsExplain else {
                    throw AdapterError.notFound("This connection does not support explaining queries.")
                }
                return try await explainer.explain(command, options: options)
            }
        } else {
            guard let statement = ExplainPlanner.statement(engine: session.profile.engine, query: text)
            else { return }
            executeCommand(session: session, record: nil) { adapter, options in
                try await adapter.execute(.sql(statement), options: options)
            }
        }
    }


    /// Cancels the active tab's in-flight query/preview. Other tabs keep
    /// running — cancellation is per tab.
    func cancelQuery() {
        let tab = activeTab
        guard let requestID = tab.activeRequestID, let session = selectedSession else { return }
        tab.cancellationRequested = true
        tab.executionTask?.cancel()
        Task { try? await session.adapter.cancel(requestID: requestID) }
    }

    /// Cancels every tab's in-flight query/preview; used when the selected
    /// connection changes or goes away.
    private func cancelInFlight() {
        for tab in tabs { cancelInFlight(tab) }
    }

    /// Cancels one tab's in-flight request and resets its execution state.
    private func cancelInFlight(_ tab: QueryTab) {
        guard tab.isExecuting else { return }
        let requestID = tab.activeRequestID
        let session = selectedSession
        tab.executionTask?.cancel()
        tab.executionTask = nil
        tab.isExecuting = false
        tab.activeRequestID = nil
        tab.cancellationRequested = false
        if let requestID, let session {
            Task { try? await session.adapter.cancel(requestID: requestID) }
        }
    }

    /// Resets a tab's execution state, but only when this request is still
    /// the tab's current one — a stale task must not clobber a newer
    /// execution (on this or any other tab).
    private func finishExecution(on tab: QueryTab, for requestID: UUID) {
        guard tab.activeRequestID == requestID else { return }
        tab.isExecuting = false
        tab.activeRequestID = nil
        tab.cancellationRequested = false
    }

    // MARK: Record editing

    /// Non-nil when record editing may be offered: the visible result is a
    /// preview of one table/collection, the profile is writable and real, and
    /// the adapter opted into the editing capability (fail closed otherwise).
    var editingObject: DatabaseObject? {
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              let object = previewedObject,
              object.kind == .table || object.kind == .collection,
              session.adapter is any SupportsEditing
        else { return nil }
        return object
    }

    /// Applies one reviewed change (update, delete, or insert) through the
    /// editing capability, then re-previews the object so the visible result
    /// reflects it. Fails closed: any missing precondition becomes a banner
    /// error, never a write. Returns false (with `errorMessage` set) on failure.
    @discardableResult
    func applyDataChange(_ change: DataChange) async -> Bool {
        guard let session = selectedSession,
              !session.profile.readOnly,
              let adapter = session.adapter as? any SupportsEditing
        else {
            errorMessage = "This connection does not support editing records."
            return false
        }
        let connectionID = session.id
        // The edit belongs to the tab whose preview the reviewer saw; capture
        // it so a tab switch mid-apply re-previews the right tab.
        let tab = activeTab
        let rePreview = tab.previewedObject.map { currentPreviewRequest(on: tab, for: $0) }
        errorMessage = nil
        isApplyingChange = true
        defer { isApplyingChange = false }
        do {
            _ = try await adapter.applyDataChange(change)
            // Re-preview at the same page/sort/filter so the reviewer sees the
            // change where they made it.
            if let rePreview, selectedConnectionID == connectionID {
                tab.result = try await adapter.previewObject(rePreview)
            }
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            guard selectedConnectionID == connectionID else { return false }
            errorMessage = Self.redactedMessage(for: error)
            return false
        }
    }

    // MARK: Record insertion

    /// Insert draft in progress, presented by the status bar's sheet. Set only
    /// through `beginInsert()` / `beginDuplicate(row:)`, which enforce the
    /// same fail-closed gates as editing (`editingObject`).
    var recordEditingState: RecordEditingState?

    /// Opens the blank insert draft for the previewed object. SQL targets
    /// introspect the insertable columns first (generated columns never
    /// appear, unknown-column payloads are rejected adapter-side); MongoDB
    /// opens the canonical EJSON document editor with an empty document.
    func beginInsert() {
        guard let object = editingObject, let session = selectedSession else { return }
        if object.kind == .collection {
            recordEditingState = .editing(RecordDraft(
                object: object, environment: session.profile.environment,
                columns: [], original: [], insertPrefill: []))
            return
        }
        loadInsertDraft(object: object, session: session, row: nil)
    }

    /// Opens the duplicate draft for one visible preview row: every insertable
    /// column is prefilled from the row's displayed values, except primary-key
    /// columns, which stay blank so the server default (serial / rowid /
    /// auto-increment) applies instead of colliding with the source row's
    /// unique key.
    func beginDuplicate(row: [(key: String, value: DisplayValue)]) {
        guard let object = editingObject, let session = selectedSession else { return }
        // MongoDB results are documents, never rows; duplicates of documents
        // go through the blank EJSON draft instead.
        guard object.kind == .table else { return }
        loadInsertDraft(object: object, session: session, row: row)
    }

    /// Shared insert-draft loader: introspects insertable columns, then opens
    /// the sheet. Introspection failures surface in the redacted banner; the
    /// sheet simply does not open (fail closed).
    private func loadInsertDraft(
        object: DatabaseObject, session: Session, row: [(key: String, value: DisplayValue)]?
    ) {
        guard let adapter = session.adapter as? any SupportsEditing else { return }
        let connectionID = session.id
        let environment = session.profile.environment
        Task { @MainActor in
            do {
                let insertable = try await adapter.insertableColumns(for: object)
                guard selectedConnectionID == connectionID else { return }
                recordEditingState = .editing(makeInsertDraft(
                    object: object, environment: environment,
                    insertable: insertable, row: row))
            } catch {
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    /// The blank or duplicated insert draft. Seeds: `.null` (NULL toggle on)
    /// for Add Row; the row's values for Duplicate Row with primary keys
    /// blanked (see `beginDuplicate`). At review time, fields still NULL are
    /// *omitted* from the INSERT so the column default applies.
    private func makeInsertDraft(
        object: DatabaseObject,
        environment: ConnectionEnvironment,
        insertable: [InsertableColumn],
        row: [(key: String, value: DisplayValue)]?
    ) -> RecordDraft {
        let rowValues = Dictionary((row ?? []).map { ($0.key, $0.value) }) { first, _ in first }
        let prefill: [(key: String, value: DisplayValue)] = insertable.map { column in
            if column.primaryKeyOrdinal > 0 { return (column.name, .null) }
            return (column.name, rowValues[column.name] ?? .null)
        }
        // Keep the preview's column metadata (numeric alignment) where the
        // preview showed the column; introspected-only columns get defaults.
        var previewColumns: [String: ColumnMeta] = [:]
        if case .rows(let columns, _, _) = result {
            previewColumns = Dictionary(columns.map { ($0.name, $0) }) { first, _ in first }
        }
        return RecordDraft(
            object: object,
            environment: environment,
            columns: insertable.map {
                previewColumns[$0.name] ?? ColumnMeta(name: $0.name, typeName: "")
            },
            original: [],
            insertPrefill: prefill)
    }

    // MARK: - Value editor (ROADMAP M3)

    /// The single-field review a value-editor commit produces (row-detail
    /// pane or grid): the whole visible row is the optimistic-concurrency
    /// baseline, only the edited column changes, and the review sheet still
    /// runs (production gate included) before `applyDataChange` — the exact
    /// pipeline of a cell edit. Fails closed (nil) when the session may not
    /// edit this preview, the column is unknown, the value is unchanged, or
    /// the held value is adapter-truncated: the app does not hold its full
    /// bytes, so committing the visible prefix would silently overwrite the
    /// unseen tail.
    func valueEditReview(
        column: String,
        newValue: DisplayValue,
        columns: [ColumnMeta],
        row: [(key: String, value: DisplayValue)]
    ) -> RecordReview? {
        guard let object = editingObject, let session = selectedSession,
              let before = row.first(where: { $0.key == column })?.value,
              before != newValue
        else { return nil }
        switch before {
        case .string(let text) where DisplayFormatting.truncatedOmittedBytes(of: text) != nil:
            return nil
        case .binary(let data) where DisplayFormatting.binaryTruncationSplit(data) != nil:
            return nil
        default:
            break
        }
        let draft = RecordDraft(
            object: object,
            environment: session.profile.environment,
            columns: columns,
            original: row)
        return RecordReview(
            draft: draft,
            changes: [(column, before, newValue)],
            changed: [column: newValue],
            isDelete: false)
    }

    // MARK: - Batch staging (ROADMAP M3 批量编辑暂存)

    /// The staged batch: changes the user reviewed but has not applied yet.
    /// Per tab (`pendingChanges` forwards to the active tab), scoped to that
    /// tab's `previewedObject` — cross-table batches are not supported.
    /// Lifecycle: discarded (with a notice) on connection switch and on
    /// previewing a different object; kept across tab switches (each tab
    /// keeps its own batch), refreshes, and ad-hoc queries (each entry
    /// carries its own optimistic-lock baseline, so shifted data surfaces as
    /// a per-item conflict at apply time).

    /// Whether reviewed changes may be staged: the same fail-closed gate as
    /// record editing (writable, real preview of one table/collection whose
    /// adapter opted into `SupportsEditing`).
    var canStageChanges: Bool { editingObject != nil }

    /// Adds one reviewed change to the batch. Staging is not a write, so it
    /// needs no production confirmation; the batch apply confirms instead.
    /// Fails closed silently: a review for anything but the currently
    /// editable preview is refused.
    func stage(_ review: RecordReview) {
        guard let object = editingObject, review.draft.object == object else { return }
        pendingChanges.append(PendingChange(review: review))
    }

    func removePendingChange(id: UUID) {
        pendingChanges.removeAll { $0.id == id }
    }

    func clearPendingChanges() {
        pendingChanges = []
    }

    /// Empties the batch with a banner notice; silent when already empty.
    private func discardPendingChanges(reason: String) {
        guard !pendingChanges.isEmpty else { return }
        let count = pendingChanges.count
        pendingChanges = []
        errorMessage = "Discarded \(count) staged \(count == 1 ? "change" : "changes") — \(reason)."
    }

    var canApplyPendingChanges: Bool {
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              !isApplyingChange,
              !pendingChanges.isEmpty,
              session.adapter is any SupportsEditing
        else { return false }
        return true
    }

    /// Applies the batch in order through the exact per-change pipeline
    /// (`adapter.applyDataChange` — planner, optimistic lock, adapter-side
    /// guards), then re-previews once. Failure policy: stop at the first
    /// failure — applied entries are written and leave the batch, the failed
    /// one and everything after it stays staged for fixing/retry, and the
    /// banner reports the honest partial count. Deliberately no fake
    /// transaction wrapping. Returns true only when every entry applied.
    @discardableResult
    func applyPendingChanges() async -> Bool {
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              !isApplyingChange,
              !pendingChanges.isEmpty,
              let adapter = session.adapter as? any SupportsEditing
        else {
            errorMessage = "This connection does not support editing records."
            return false
        }
        let connectionID = session.id
        // The batch belongs to the tab that staged it; capture the tab so a
        // tab switch mid-apply trims and re-previews the right tab.
        let tab = activeTab
        errorMessage = nil
        isApplyingChange = true
        defer { isApplyingChange = false }

        let total = tab.pendingChanges.count
        var applied = 0
        var failure: String?
        var cancelled = false
        for pending in tab.pendingChanges {
            do {
                _ = try await adapter.applyDataChange(pending.review.dataChange)
                applied += 1
            } catch {
                if Self.isCancellation(error) {
                    cancelled = true
                } else {
                    failure = Self.redactedMessage(for: error)
                }
                break
            }
        }
        // Ignore stale completions after the user switched connections; the
        // switch already discarded the batch.
        guard selectedConnectionID == connectionID else { return false }
        tab.pendingChanges.removeFirst(min(applied, tab.pendingChanges.count))
        if cancelled { return false }
        if let failure {
            errorMessage = applied > 0
                ? "Applied \(applied) of \(total) staged changes, then stopped: \(failure)"
                : failure
        }
        // One re-preview at the end so the grid reflects what landed.
        if let object = tab.previewedObject {
            tab.result = try? await adapter.previewObject(currentPreviewRequest(on: tab, for: object))
        }
        return failure == nil
    }

    // MARK: - Result export

    /// Non-nil when there is a result to export. Export works off the
    /// in-memory (already capped) result and needs no adapter capability.
    var canExportResult: Bool { result != nil }

    /// Suggested base name for the export save panel, sanitized like the
    /// Electron `safeBaseName` (no path separators, controls, or leading dots).
    func suggestedExportBaseName() -> String {
        Self.exportBaseName("\(selectedSession?.profile.database ?? "dbbbb")-result")
    }

    /// The qualified target table for INSERT-statement export, when known:
    /// only previews of one object have a known source table; ad-hoc row
    /// results and document results (MongoDB stays JSONL-only) do not.
    var insertExportTable: [String]? {
        guard let object = previewedObject,
              let engine = selectedSession?.profile.engine,
              case .rows = result
        else { return nil }
        return InsertStatementRenderer.tableNameParts(engine: engine, object: object)
    }

    /// Serializes the current result and writes it atomically. Errors are
    /// redacted: `ResultExportError` messages are safe by contract, and any
    /// file-system failure collapses to a fixed path-free message.
    func exportResult(to url: URL, format: ResultExporter.Format = .automatic) {
        guard let result else { return }
        do {
            let exported = try ResultExporter.exportData(for: result, format: format)
            try AtomicFileWriter.write(exported.data, to: url)
            errorMessage = nil
        } catch let error as dbbbbError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The export could not be written to the selected file."
        }
    }

    static func exportBaseName(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var clean = value.components(separatedBy: illegal).joined(separator: "-")
        clean = clean.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = String(clean.prefix(120))
        return clean.isEmpty ? "dbbbb-export" : clean
    }

    // MARK: - Import

    /// Non-nil when import may be offered: the visible result is a preview of
    /// one table/collection, the profile is writable and real, and the adapter
    /// opted into the import capability (fail closed otherwise).
    var importingObject: DatabaseObject? {
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              let object = previewedObject,
              object.kind == .table || object.kind == .collection,
              session.adapter is any SupportsImporting
        else { return nil }
        return object
    }

    /// The import format for a target, mirroring the engine capabilities:
    /// CSV into SQL tables, JSONL into MongoDB collections.
    func importFormat(for object: DatabaseObject) -> ImportFormat? {
        guard let engine = selectedSession?.profile.engine else { return nil }
        switch engine {
        case .postgresql, .mysql, .sqlite:
            return object.kind == .table ? .csv : nil
        case .mongodb:
            return object.kind == .collection ? .jsonl : nil
        case .bullmq:
            return nil
        }
    }

    /// Live progress for the sheet while an import runs.
    private(set) var importProgress: ImportProgress?
    /// Set when the last import finished successfully.
    private(set) var importSummary: ImportSummary?
    private(set) var isImporting = false

    private var importTask: Task<Void, Never>?
    private let importCancelFlag = CancelFlag()

    /// Starts one reviewed import. Fails closed: any missing precondition
    /// becomes a banner error, never a write. Progress and cancellation are
    /// wired through the request closures.
    func startImport(format: ImportFormat, fileURL: URL, hasHeader: Bool) {
        guard !isImporting else { return }
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              let object = importingObject,
              let adapter = session.adapter as? any SupportsImporting
        else {
            errorMessage = "This connection does not support importing data."
            return
        }
        errorMessage = nil
        isImporting = true
        importProgress = ImportProgress()
        importSummary = nil
        let flag = importCancelFlag
        flag.reset()
        let progressRelay = ImportProgressRelay()
        let tab = activeTab
        importTask = Task { @MainActor in
            defer {
                isImporting = false
                importProgress = nil
                importTask = nil
            }
            do {
                let summary = try await adapter.importData(ImportRequest(
                    target: object,
                    format: format,
                    fileURL: fileURL,
                    hasHeader: hasHeader,
                    isCancelled: { flag.isSet },
                    onProgress: { [weak self] progress in
                        progressRelay.send(progress) { [weak self] latest in
                            self?.importProgress = latest
                        }
                    }))
                importSummary = summary
                // Refresh the preview (same page) so the imported rows are
                // visible — on the tab that started the import.
                if let object = tab.previewedObject, selectedConnectionID == session.id {
                    tab.result = try? await adapter.previewObject(
                        currentPreviewRequest(on: tab, for: object))
                }
            } catch {
                importSummary = nil
                if !Self.isCancellation(error) {
                    errorMessage = Self.redactedMessage(for: error)
                }
            }
        }
    }

    func cancelImport() {
        importCancelFlag.set()
    }

    // MARK: - Create statement (DDL viewer)

    /// One fetched create statement, presented read-only in a sheet.
    struct CreateStatementPresentation: Identifiable {
        let id = UUID()
        let objectName: String
        let ddl: String
    }

    /// Non-nil while the create-statement sheet is shown.
    private(set) var createStatement: CreateStatementPresentation?

    /// Whether the context menu may offer "View Create Statement" for an
    /// object. Fail closed: only adapters that opted into
    /// `SupportsIntrospection` and only table/view objects (MongoDB has no
    /// DDL to show and never conforms). Read-only profiles may read DDL.
    func canShowCreateStatement(for object: DatabaseObject) -> Bool {
        guard let session = selectedSession,
              session.adapter is any SupportsIntrospection,
              object.kind == .table || object.kind == .view
        else { return false }
        return true
    }

    /// Fetches the DDL in the background; failures go through the redacted
    /// banner, never into the sheet.
    func showCreateStatement(for object: DatabaseObject) {
        guard canShowCreateStatement(for: object),
              let session = selectedSession,
              let adapter = session.adapter as? any SupportsIntrospection
        else { return }
        let connectionID = session.id
        Task { @MainActor in
            do {
                let ddl = try await adapter.createStatement(for: object)
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID else { return }
                createStatement = CreateStatementPresentation(objectName: object.name, ddl: ddl)
            } catch {
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func dismissCreateStatement() {
        createStatement = nil
    }

    // MARK: - Table statistics (ROADMAP M2 ⑩)

    /// One fetched statistics snapshot, presented read-only in a sheet.
    struct TableStatisticsPresentation: Identifiable {
        let id = UUID()
        let objectName: String
        let statistics: TableStatistics
    }

    /// Non-nil while the statistics sheet is shown.
    private(set) var tableStatistics: TableStatisticsPresentation?

    /// Whether the context menu may offer "Statistics…" for an object. Fail
    /// closed: only adapters that opted into `SupportsTableStatistics` and
    /// only table/view/collection objects. Read-only profiles may read stats.
    func canShowTableStatistics(for object: DatabaseObject) -> Bool {
        guard let session = selectedSession,
              session.adapter is any SupportsTableStatistics,
              object.kind == .table || object.kind == .view || object.kind == .collection
        else { return false }
        return true
    }

    /// Fetches the statistics in the background; failures go through the
    /// redacted banner, never into the sheet.
    func showTableStatistics(for object: DatabaseObject) {
        guard canShowTableStatistics(for: object),
              let session = selectedSession,
              let adapter = session.adapter as? any SupportsTableStatistics
        else { return }
        let connectionID = session.id
        Task { @MainActor in
            do {
                let statistics = try await adapter.tableStatistics(for: object)
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID else { return }
                tableStatistics = TableStatisticsPresentation(
                    objectName: object.name, statistics: statistics)
            } catch {
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func dismissTableStatistics() {
        tableStatistics = nil
    }

    // MARK: - Schema viewer ("View Schema")

    /// One fetched database schema, presented read-only in a sheet: every
    /// table's structured schema plus the database-wide relationship list.
    struct SchemaPresentation: Identifiable {
        let id = UUID()
        let databaseName: String
        var tables: [TableSchema]
        var relations: [TableRelation]
    }

    /// Non-nil while the schema sheet is shown.
    private(set) var schemaPresentation: SchemaPresentation?
    private(set) var isLoadingSchema = false

    /// Whether the toolbar may offer "Schema…". Fail closed: only adapters
    /// that opted into `SupportsSchemaIntrospection` (MongoDB never does).
    /// Reading metadata is a read: read-only profiles may read schemas.
    var canShowSchema: Bool {
        selectedSession?.adapter is any SupportsSchemaIntrospection
    }

    /// Fetches every table's schema plus the database-wide foreign-key edges
    /// in the background; failures go through the redacted banner, never into
    /// the sheet (fail closed — the sheet only ever shows complete data).
    func showSchema() {
        guard canShowSchema, !isLoadingSchema,
              let session = selectedSession,
              let adapter = session.adapter as? any SupportsSchemaIntrospection
        else { return }
        let connectionID = session.id
        let databaseName = session.profile.database
        let tables = objects.filter { $0.kind == .table }
        isLoadingSchema = true
        Task { @MainActor in
            do {
                var schemas: [TableSchema] = []
                for object in tables {
                    schemas.append(try await adapter.schema(for: object))
                }
                let relations = try await adapter.allForeignKeys()
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID else {
                    isLoadingSchema = false
                    return
                }
                schemaPresentation = SchemaPresentation(
                    databaseName: databaseName, tables: schemas, relations: relations)
                isLoadingSchema = false
            } catch {
                isLoadingSchema = false
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func dismissSchema() {
        schemaPresentation = nil
    }

    // MARK: - Server activity (ROADMAP M2 ⑨)

    /// One activity snapshot, presented in the sheet; rows refresh in place.
    struct ServerActivityPresentation: Identifiable {
        let id = UUID()
        var activities: [ServerActivity]
    }

    /// Non-nil while the activity sheet is shown.
    private(set) var serverActivity: ServerActivityPresentation?
    private(set) var isLoadingActivity = false

    /// Whether the toolbar may offer "Activity…". Listing is a read: any
    /// conforming adapter offers it, read-only and demo profiles included;
    /// non-conforming adapters (SQLite) fail closed and never see the entry.
    var canShowServerActivity: Bool {
        selectedSession?.adapter is any SupportsServerActivity
    }

    /// Kill is the destructive half: writable, real (non-demo) profiles only.
    var canKillServerActivity: Bool {
        guard let session = selectedSession,
              !session.profile.readOnly,
              !session.profile.demo,
              session.adapter is any SupportsServerActivity
        else { return false }
        return true
    }

    /// Why the sheet's Kill button stays disabled, when it does; nil when
    /// killing is available.
    var killActivityUnavailableReason: String? {
        guard let session = selectedSession,
              session.adapter is any SupportsServerActivity
        else { return "This connection does not support server activity." }
        if session.profile.demo { return "Demo connections have no real server activity to kill." }
        if session.profile.readOnly { return "Read-only connections cannot kill server activity." }
        return nil
    }

    /// Fetches the activity snapshot and opens the sheet on success; failures
    /// go through the redacted banner, never into the sheet (fail closed).
    func showServerActivity() {
        fetchServerActivity(present: true)
    }

    /// Re-fetches the rows of the open sheet; a failure keeps the previous
    /// rows and surfaces the redacted banner.
    func refreshServerActivity() {
        guard serverActivity != nil else { return }
        fetchServerActivity(present: false)
    }

    func dismissServerActivity() {
        serverActivity = nil
    }

    private func fetchServerActivity(present: Bool) {
        guard let session = selectedSession,
              let adapter = session.adapter as? any SupportsServerActivity
        else { return }
        let connectionID = session.id
        isLoadingActivity = true
        Task { @MainActor in
            do {
                let activities = try await adapter.listActivity()
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID else {
                    isLoadingActivity = false
                    return
                }
                if present {
                    serverActivity = ServerActivityPresentation(activities: activities)
                } else if serverActivity != nil {
                    serverActivity?.activities = activities
                }
                isLoadingActivity = false
            } catch {
                isLoadingActivity = false
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    /// Kills one activity through the capability, then refreshes the list so
    /// the killed row disappears. Fails closed: any missing precondition
    /// becomes a banner error; adapter failures surface redacted. Returns
    /// false (with `errorMessage` set) on failure.
    @discardableResult
    func killServerActivity(id: String) async -> Bool {
        guard canKillServerActivity,
              let session = selectedSession,
              let adapter = session.adapter as? any SupportsServerActivity
        else {
            errorMessage = killActivityUnavailableReason
                ?? "This connection does not support killing server activity."
            return false
        }
        let connectionID = session.id
        do {
            try await adapter.killActivity(id: id)
            // Refresh so the sheet reflects the kill; a refresh failure just
            // keeps the stale row, the kill itself succeeded.
            if selectedConnectionID == connectionID, serverActivity != nil,
               let refreshed = try? await adapter.listActivity() {
                serverActivity?.activities = refreshed
            }
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            guard selectedConnectionID == connectionID else { return false }
            errorMessage = Self.redactedMessage(for: error)
            return false
        }
    }

    // MARK: - BullMQ scan continuation

    /// Whether Continue scan applies: a truncated BullMQ document result with
    /// a resume cursor, not executing, and not a preview (previews page via
    /// the pager). Mirrors the Electron reference's `canContinueScan`.
    var canContinueScan: Bool {
        guard let session = selectedSession,
              session.profile.engine == .bullmq,
              !isExecuting,
              previewedObject == nil,
              case .documents = result,
              let meta = result?.meta,
              meta.truncated, meta.nextCursor != nil
        else { return false }
        return true
    }

    /// Resumes a truncated BullMQ scan: the current query JSON keeps its
    /// filters, only the cursor moves to the returned nextCursor, and the new
    /// page is appended to the documents already on screen. The editor text
    /// itself is left untouched so a fresh Run still starts from the top.
    func continueScan() {
        guard canContinueScan,
              let session = selectedSession,
              let current = result,
              case .documents(let existing, let currentMeta) = current,
              let nextCursor = currentMeta.nextCursor
        else { return }
        guard let text = BullmqQueryText.settingCursor(nextCursor, in: queryText) else {
            errorMessage = "The BullMQ query is not valid JSON; fix it before continuing the scan."
            return
        }
        let command = DatabaseCommand.bullmqJobs(text)
        let tab = activeTab
        errorMessage = nil
        tab.isExecuting = true
        let connectionID = session.id
        let adapter = session.adapter
        let options = ExecuteOptions()
        let requestID = options.requestID
        tab.activeRequestID = requestID
        tab.executionTask = Task { @MainActor in
            defer { finishExecution(on: tab, for: requestID) }
            do {
                let executed = try await adapter.execute(command, options: options)
                // Ignore stale completions after the user switched connections
                // or the tab started a newer execution.
                guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                guard case .documents(let pageDocuments, let pageMeta) = executed else { return }
                // Merge: documents append; count/scanned/elapsed accumulate;
                // truncated/total/nextCursor come from the newest page.
                tab.result = .documents(existing + pageDocuments, meta: ResultMeta(
                    count: currentMeta.count + pageMeta.count,
                    truncated: pageMeta.truncated,
                    elapsedMilliseconds: currentMeta.elapsedMilliseconds + pageMeta.elapsedMilliseconds,
                    scanned: (currentMeta.scanned ?? 0) + (pageMeta.scanned ?? 0),
                    total: pageMeta.total ?? currentMeta.total,
                    nextCursor: pageMeta.nextCursor))
            } catch {
                // Cancelled: keep the previous result, no banner.
                guard !tab.cancellationRequested, !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID, tab.activeRequestID == requestID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    // MARK: - BullMQ snapshots (Sync to local SQL)

    /// Snapshot file bookkeeping; nil disables sync (tests without a store).
    private let snapshotStore: BullmqSnapshotStore?
    /// Session id → snapshot file, for removal-time deletion. Snapshot
    /// sessions are never persisted (no manifest entry, no Keychain secret).
    private var snapshotFiles: [UUID: URL] = [:]

    private(set) var isBullmqSyncing = false
    /// Jobs written so far by the running sync.
    private(set) var bullmqSyncProgress = 0
    private var bullmqSyncRequestID: UUID?

    /// Sync is a read of Redis (a local SQLite file is written), so read-only
    /// and demo BullMQ connections may sync. Fail closed on anything else.
    var canSyncBullmqSnapshot: Bool {
        guard let session = selectedSession,
              session.profile.engine == .bullmq,
              session.adapter is any SupportsBullmqSnapshot
        else { return false }
        return true
    }

    /// The sync targets: discovered queue (collection) nodes.
    var bullmqSyncQueues: [String] {
        objects.filter { $0.kind == .collection }.map(\.name)
    }

    /// Coalesces batch progress callbacks onto the main actor (the adapter's
    /// batches can arrive in bursts; only the latest total matters).
    private final class BullmqSyncProgressRelay: Sendable {
        private let total = Mutex(0)
        private let hopScheduled = Mutex(false)

        func add(_ delta: Int, deliver: @escaping @MainActor @Sendable (Int) -> Void) {
            total.withLock { $0 += delta }
            let shouldSchedule = hopScheduled.withLock { scheduled -> Bool in
                if scheduled { return false }
                scheduled = true
                return true
            }
            guard shouldSchedule else { return }
            Task { @MainActor in
                hopScheduled.withLock { $0 = false }
                deliver(total.withLock { $0 })
            }
        }
    }

    /// Materializes every job of one queue into a local SQLite snapshot and
    /// opens it as a new read-only session named
    /// `Snapshot: <queue> (from <connection>)`. Full rebuild per sync (see
    /// `BullmqSnapshotWriter` for why incremental would keep dirty rows): the
    /// writer fills a `<file>.tmp`, which is renamed over the previous
    /// snapshot only after a successful commit — the previous session is
    /// closed first so its file handle never straddles the rename.
    @discardableResult
    func syncBullmqSnapshot(queue: String) async -> Bool {
        guard !isBullmqSyncing,
              let session = selectedSession,
              session.profile.engine == .bullmq,
              let adapter = session.adapter as? any SupportsBullmqSnapshot,
              let snapshotStore
        else {
            errorMessage = "This connection does not support snapshots."
            return false
        }
        let requestID = UUID()
        bullmqSyncRequestID = requestID
        isBullmqSyncing = true
        bullmqSyncProgress = 0
        defer {
            isBullmqSyncing = false
            bullmqSyncRequestID = nil
        }

        let finalURL = snapshotStore.snapshotFileURL(connectionID: session.id, queue: queue)
        let temporaryURL = snapshotStore.temporaryFileURL(for: finalURL)
        do {
            try snapshotStore.prepareDirectory()
            snapshotStore.deleteSnapshot(at: temporaryURL)
            let writer = try BullmqSnapshotWriter(fileURL: temporaryURL)
            let relay = BullmqSyncProgressRelay()
            do {
                _ = try await adapter.collectBullmqJobs(
                    options: BullmqCollectOptions(queue: queue, requestID: requestID)) { batch in
                    try writer.insertBatch(batch)
                    relay.add(batch.count) { [weak self] total in
                        self?.bullmqSyncProgress = total
                    }
                }
                try writer.commit()
            } catch {
                writer.abort()
                snapshotStore.deleteSnapshot(at: temporaryURL)
                throw error
            }

            // Replace any previous snapshot session for this file before the
            // rename, so its SQLite handle is closed first.
            if let existing = snapshotFiles.first(where: { $0.value == finalURL })?.key {
                removeConnection(existing)
            }
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)

            let snapshotAdapter = try SQLiteAdapter(input: .init(
                name: "Snapshot: \(queue) (from \(session.profile.name))",
                filePath: finalURL.path,
                readOnly: true))
            // Fail fast before registering: a snapshot that cannot be read is
            // never shown as a session.
            _ = try await snapshotAdapter.listObjects()
            let snapshotSession = Session(profile: snapshotAdapter.profile, adapter: snapshotAdapter)
            sessions.append(snapshotSession)
            snapshotFiles[snapshotSession.id] = finalURL
            selectConnection(snapshotSession.id)
            return true
        } catch {
            if !Self.isCancellation(error) {
                errorMessage = Self.redactedMessage(for: error)
            }
            return false
        }
    }

    /// Best-effort cancellation of the running sync (the adapter checks the
    /// flag between batches).
    func cancelBullmqSync() {
        guard let requestID = bullmqSyncRequestID, let session = selectedSession else { return }
        Task { try? await session.adapter.cancel(requestID: requestID) }
    }

    /// App exit: snapshots are session-scoped, so every managed file goes.
    func deleteAllSnapshots() {
        try? snapshotStore?.sweepManagedFiles()
    }

    // MARK: Query history

    /// Records a successfully executed query (matching the Electron reference,
    /// previews and failed executions are not recorded). A recording failure —
    /// e.g. storage full of favorites — surfaces as an explicit redacted error.
    private func recordQuery(_ command: DatabaseCommand, session: Session) {
        guard let queryLibrary else { return }
        let collection: String?
        switch command {
        case .sql: collection = nil
        case .mongoFind(let name, _), .mongoAggregate(let name, _): collection = name
        case .bullmqJobs: collection = nil
        }
        do {
            try queryLibrary.record(
                connectionID: session.id, engine: session.profile.engine,
                text: command.text, collection: collection)
            queryEntries = queryLibrary.entries
        } catch {
            errorMessage = Self.redactedMessage(for: error)
        }
    }

    /// Loads an entry into the editor, switching to its connection when that
    /// connection is still open. MongoDB entries also restore the Find/Aggregate
    /// mode: pipelines are arrays, filters are documents (`MongoQueryText`).
    func loadQueryEntry(_ entry: QueryEntry) {
        if entry.connectionID != selectedConnectionID,
           sessions.contains(where: { $0.id == entry.connectionID }) {
            selectConnection(entry.connectionID)
        }
        queryText = entry.text
        if entry.engine == .mongodb {
            mongoQueryMode = MongoQueryText.isPipeline(entry.text) ? .aggregate : .find
        }
    }

    func toggleFavorite(entryID: UUID) {
        guard let queryLibrary else { return }
        do {
            _ = try queryLibrary.toggleFavorite(id: entryID)
            queryEntries = queryLibrary.entries
        } catch {
            errorMessage = Self.redactedMessage(for: error)
        }
    }

    func removeQueryEntry(_ id: UUID) {
        guard let queryLibrary else { return }
        queryLibrary.remove(id: id) { errorMessage = Self.redactedMessage(for: $0) }
        queryEntries = queryLibrary.entries
    }

    func clearQueryHistory() {
        guard let queryLibrary else { return }
        queryLibrary.clearHistory { errorMessage = Self.redactedMessage(for: $0) }
        queryEntries = queryLibrary.entries
    }

    /// `dbbbbError` messages are contractually pre-redacted; anything else gets
    /// a generic message so no credentials or local paths can leak into the UI.
    static func redactedMessage(for error: Error) -> String {
        if let error = error as? dbbbbError { return error.userMessage }
        return "The operation failed."
    }

    /// Adapters surface cancellation as their own error types (one per
    /// engine), not necessarily `CancellationError`; none of them may reach
    /// the error banner. Every engine's cancelled message contains
    /// "cancelled"; `cancellationUnsupported` ("cannot cancel") deliberately
    /// does not match.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? dbbbbError {
            return error.userMessage.localizedCaseInsensitiveContains("cancelled")
        }
        return false
    }

    // MARK: Private

    private func loadObjects() {
        guard let session = selectedSession else {
            objects = []
            return
        }
        let connectionID = session.id
        let adapter = session.adapter
        isLoadingObjects = true
        Task { @MainActor in
            do {
                let loaded = try await adapter.listObjects()
                // Ignore stale loads after the user switched connections.
                guard selectedConnectionID == connectionID else {
                    isLoadingObjects = false
                    return
                }
                objects = loaded
                isLoadingObjects = false
                // Offer a runnable starter query once the schema is known.
                if queryText.isEmpty, let engine = selectedSession?.profile.engine {
                    queryText = Self.defaultQuery(for: engine, objects: loaded)
                }
            } catch {
                isLoadingObjects = false
                guard !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }
}
