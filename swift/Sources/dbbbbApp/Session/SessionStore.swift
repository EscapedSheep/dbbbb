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

    /// Builds an adapter for a newly added connection. The four demo connections
    /// are seeded at launch with `DemoAdapter` and never go through this factory.
    var makeAdapter: @Sendable (ConnectionInput) async throws -> any DatabaseAdapter = { input in
        switch input {
        case .postgres(let input): try PostgresAdapter(input: input)
        case .mysql(let input): try MySQLAdapter(input: input)
        case .mongo(let input): try await MongoAdapter(input: input)
        case .sqlite(let input): try SQLiteAdapter(input: input)
        }
    }

    private(set) var sessions: [Session] = []
    private(set) var selectedConnectionID: UUID?
    private(set) var objects: [DatabaseObject] = []
    /// The object the user last clicked or previewed; MongoDB queries run
    /// against it (the editor text is pure Extended JSON).
    private(set) var selectedObject: DatabaseObject?
    /// The object whose preview is currently shown; nil after ad-hoc queries.
    /// Editing is offered only for previews — ad-hoc results have no known
    /// single change target.
    private(set) var previewedObject: DatabaseObject?
    private(set) var isLoadingObjects = false
    var queryText = ""
    /// Find vs. aggregate for MongoDB connections; the editor text is the
    /// filter document or the pipeline array respectively. SQL engines ignore it.
    var mongoQueryMode: MongoQueryMode = .find
    private(set) var result: QueryResult?
    private(set) var isExecuting = false
    private(set) var isApplyingChange = false
    /// Redacted message shown in the inline error banner.
    var errorMessage: String?
    var showingNewConnection = false

    /// Persistence for non-demo connections; nil disables it (tests, previews).
    private let connectionStore: ConnectionStore?
    /// Query history + favorites; nil disables recording.
    private let queryLibrary: QueryLibraryStore?
    /// Snapshot of the library, newest first; refreshed after every mutation.
    private(set) var queryEntries: [QueryEntry] = []

    private var executionTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    /// Set when the user cancelled the in-flight request; adapter-specific
    /// cancellation errors are then silenced even when they are not
    /// `CancellationError` (each engine has its own cancelled type).
    private var cancellationRequested = false

    var selectedSession: Session? { sessions.first { $0.id == selectedConnectionID } }

    var resultIsDocuments: Bool {
        if case .documents = result { return true }
        return false
    }

    init(connectionStore: ConnectionStore? = ConnectionStore(),
         queryLibrary: QueryLibraryStore? = QueryLibraryStore()) {
        self.connectionStore = connectionStore
        self.queryLibrary = queryLibrary
        queryEntries = queryLibrary?.entries ?? []
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
        objects = []
        selectedObject = nil
        previewedObject = nil
        result = nil
        errorMessage = nil
        queryText = ""
        mongoQueryMode = .find
    }

    func refreshObjects() {
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
        let adapter = try await makeAdapter(input)
        do {
            _ = try await adapter.listObjects()
        } catch {
            await adapter.close()
            throw error
        }
        let session = Session(profile: adapter.profile, adapter: adapter)
        sessions.append(session)
        selectConnection(session.id)
        // After selectConnection, which clears the error banner.
        persist(input, id: session.id)
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
        // Demo connections never touch disk or the Keychain.
        if !session.profile.demo, let connectionStore {
            do {
                try connectionStore.remove(id: id)
            } catch {
                errorMessage = Self.redactedMessage(for: error)
            }
        }
        Task { await session.adapter.close() }
    }

    static func defaultQuery(for engine: DatabaseEngine, objects: [DatabaseObject]) -> String {
        let firstLeaf = objects.first { $0.kind == .table || $0.kind == .collection }
        if engine == .mongodb {
            return "{ }"
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
        } else {
            queryText = "select * from \(object.name) limit 100;"
        }
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

    func preview(_ object: DatabaseObject) {
        guard let session = selectedSession, !isExecuting else { return }
        let connectionID = session.id
        selectedObject = object
        previewedObject = object
        errorMessage = nil
        isExecuting = true
        // Previews register a request ID just like queries, so Cancel works.
        let requestID = ExecuteOptions().requestID
        activeRequestID = requestID
        let adapter = session.adapter
        executionTask = Task { @MainActor in
            defer { finishExecution(for: requestID) }
            do {
                let previewed = try await adapter.previewObject(object)
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID, activeRequestID == requestID else { return }
                result = previewed
            } catch {
                guard activeRequestID == requestID else { return }
                // The screen still shows the previous data; never leave the
                // preview pointer aimed at the object that never loaded.
                previewedObject = nil
                // Cancelled: keep the previous result, no banner.
                guard !cancellationRequested, !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID else { return }
                result = nil
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func runQuery() {
        guard let session = selectedSession, !isExecuting else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        previewedObject = nil
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
        } else {
            command = .sql(text)
        }
        errorMessage = nil
        isExecuting = true
        let connectionID = session.id
        let options = ExecuteOptions()
        let requestID = options.requestID
        activeRequestID = requestID
        let adapter = session.adapter
        executionTask = Task { @MainActor in
            defer { finishExecution(for: requestID) }
            do {
                let executed = try await adapter.execute(command, options: options)
                // Ignore stale completions after the user switched connections.
                guard selectedConnectionID == connectionID, activeRequestID == requestID else { return }
                result = executed
                recordQuery(command, session: session)
            } catch {
                // Cancelled: keep the previous result, no banner.
                guard !cancellationRequested, !Self.isCancellation(error) else { return }
                guard selectedConnectionID == connectionID, activeRequestID == requestID else { return }
                errorMessage = Self.redactedMessage(for: error)
            }
        }
    }

    func cancelQuery() {
        guard let requestID = activeRequestID, let session = selectedSession else { return }
        cancellationRequested = true
        executionTask?.cancel()
        Task { try? await session.adapter.cancel(requestID: requestID) }
    }

    /// Cancels any in-flight query/preview and resets execution state; used
    /// when the selected connection changes or goes away.
    private func cancelInFlight() {
        guard isExecuting else { return }
        let requestID = activeRequestID
        let session = selectedSession
        executionTask?.cancel()
        executionTask = nil
        isExecuting = false
        activeRequestID = nil
        cancellationRequested = false
        if let requestID, let session {
            Task { try? await session.adapter.cancel(requestID: requestID) }
        }
    }

    /// Resets execution state, but only when this request is still the
    /// current one — a stale task must not clobber a newer execution.
    private func finishExecution(for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        isExecuting = false
        activeRequestID = nil
        cancellationRequested = false
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

    /// Applies one reviewed change through the editing capability, then
    /// re-previews the object so the visible result reflects it. Fails
    /// closed: any missing precondition becomes a banner error, never a
    /// write. Returns false (with `errorMessage` set) on failure.
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
        errorMessage = nil
        isApplyingChange = true
        defer { isApplyingChange = false }
        do {
            _ = try await adapter.applyDataChange(change)
            if let object = previewedObject, selectedConnectionID == connectionID {
                result = try await adapter.previewObject(object)
            }
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            guard selectedConnectionID == connectionID else { return false }
            errorMessage = Self.redactedMessage(for: error)
            return false
        }
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

    /// Serializes the current result and writes it atomically. Errors are
    /// redacted: `ResultExportError` messages are safe by contract, and any
    /// file-system failure collapses to a fixed path-free message.
    func exportResult(to url: URL) {
        guard let result else { return }
        do {
            let exported = try ResultExporter.exportData(for: result)
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
                // Refresh the preview so the imported rows are visible.
                if let object = previewedObject, selectedConnectionID == session.id {
                    result = try? await adapter.previewObject(object)
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
