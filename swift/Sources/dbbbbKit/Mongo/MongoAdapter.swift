import Foundation
import dbbbbCore
import Logging
import MongoClient
import MongoKitten
import Synchronization

/// Cancellation/timeout handle for one in-flight request. Closing the server
/// cursor (killCursors) is MongoDB's real interruption mechanism; the flags
/// decide how the resulting driver error is reported.
final class MongoRequestState: Sendable {
    private struct Box {
        var cursor: MongoCursor?
        var cancelRequested = false
        var timedOut = false
    }

    private let box = Mutex(Box())

    func attach(_ cursor: MongoCursor) {
        let shouldClose = box.withLock { box -> Bool in
            box.cursor = cursor
            return box.cancelRequested || box.timedOut
        }
        if shouldClose { Self.close(cursor) }
    }

    func cancel() {
        let cursor = box.withLock { box -> MongoCursor? in
            box.cancelRequested = true
            return box.cursor
        }
        if let cursor { Self.close(cursor) }
    }

    func fireTimeout() {
        let cursor = box.withLock { box -> MongoCursor? in
            box.timedOut = true
            return box.cursor
        }
        if let cursor { Self.close(cursor) }
    }

    var cancelRequested: Bool { box.withLock { $0.cancelRequested } }
    var timedOut: Bool { box.withLock { $0.timedOut } }

    private static func close(_ cursor: MongoCursor) {
        guard !cursor.isDrained else { return }
        Task { try? await cursor.close() }
    }
}

/// MongoDB adapter on MongoKitten.
///
/// Read-only by construction: the only accepted commands are find and
/// aggregation, and pipelines containing write stages (`$out`/`$merge`, scanned
/// across *every* key of every stage) are rejected before anything reaches the
/// server. Input is canonical Extended JSON parsed by dbbbb's own codec —
/// never evaluated code (`$code` and legacy tags are refused).
///
/// Timeouts are enforced twice: `maxTimeMS` on the command and a client-side
/// watchdog that closes the cursor. Cancellation (`cancel(requestID:)` or Task
/// cancellation) closes the cursor as well; request IDs can be pre-registered
/// for cancellation before `execute` starts, matching the other engines.
public final class MongoAdapter: DatabaseAdapter, Sendable {
    public let profile: ConnectionProfile

    private let cluster: MongoCluster
    private let databaseName: String

    private struct State {
        var closed = false
        var active: [UUID: MongoRequestState] = [:]
        var cancelledRequestIDs: Set<UUID> = []
    }

    private let state: Mutex<State>

    private static let previewLimit = 100
    private static let writeStages: Set<String> = ["$out", "$merge"]

    public init(input: ConnectionInput.MongoInput) async throws {
        let uri = try Self.effectiveURI(input: input)
        let settings: ConnectionSettings
        do {
            settings = try ConnectionSettings(uri)
        } catch {
            throw MongoAdapterError.invalidConfiguration("The MongoDB URI is invalid.")
        }

        let cluster: MongoCluster
        do {
            cluster = try await MongoCluster(connectingTo: settings, logger: Logger(label: "dev.dbbbb.mongodb"))
        } catch {
            throw MongoErrorMapper.map(error)
        }

        self.cluster = cluster
        self.databaseName = input.database
        self.state = Mutex(State())
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .mongodb,
            endpoint: ConnectionInput.mongo(input).endpoint,
            database: input.database,
            environment: input.environment,
            readOnly: input.readOnly
        )
    }

    // MARK: - DatabaseAdapter

    public func listObjects() async throws -> [DatabaseObject] {
        try assertOpen()
        do {
            let collections = try await cluster[databaseName].listCollections()
            let databaseID = Self.databaseID(for: databaseName)
            var objects = [DatabaseObject(id: databaseID, parentID: nil, name: databaseName, kind: .database)]
            for name in collections.map(\.name).sorted() {
                objects.append(DatabaseObject(
                    id: Self.collectionID(for: name, database: databaseName),
                    parentID: databaseID,
                    name: name,
                    kind: .collection
                ))
            }
            return objects
        } catch let error as MongoAdapterError {
            throw error
        } catch {
            throw MongoErrorMapper.map(error)
        }
    }

    public func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        try assertOpen()
        guard object.kind == .collection else {
            throw AdapterError.notFound("This MongoDB object cannot be previewed.")
        }
        let collection = try Self.collectionName(from: object.id, database: databaseName)
        return try await execute(
            .mongoFind(collection: collection, filter: "{}"),
            options: ExecuteOptions(maxRows: Self.previewLimit)
        )
    }

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        try assertOpen()

        enum Kind { case find, aggregate }
        let kind: Kind
        let text: String
        let collection: String
        switch command {
        case .mongoFind(let target, let filter):
            kind = .find; text = filter; collection = target
        case .mongoAggregate(let target, let pipeline):
            kind = .aggregate; text = pipeline; collection = target
        case .sql: throw AdapterError.engineMismatch
        }
        guard !collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MongoAdapterError.noCollectionSelected
        }

        let requestState = MongoRequestState()
        try state.withLock { state in
            if state.closed { throw AdapterError.sessionClosed }
            if state.cancelledRequestIDs.remove(options.requestID) != nil {
                throw MongoAdapterError.cancelled
            }
            if state.active[options.requestID] != nil {
                throw MongoAdapterError.duplicateRequest
            }
            state.active[options.requestID] = requestState
        }
        defer {
            state.withLock { state in
                state.active.removeValue(forKey: options.requestID)
                state.cancelledRequestIDs.remove(options.requestID)
            }
        }

        // Parse and validate before anything reaches the server.
        let timeoutMs = Self.timeoutMilliseconds(options.timeout)
        let commandPairs: [(key: String, value: BSONValue)]
        do {
            switch kind {
            case .find:
                let filter = try EJSON.parseDocument(text, label: "A find filter")
                commandPairs = [
                    ("find", .string(collection)),
                    ("filter", filter),
                    ("limit", .int64(Int64(options.maxRows) + 1)),
                    ("maxTimeMS", .int64(timeoutMs)),
                ]
            case .aggregate:
                let stages = try EJSON.parsePipeline(text)
                try Self.assertReadOnlyPipeline(stages)
                commandPairs = [
                    ("aggregate", .string(collection)),
                    ("pipeline", .array(stages)),
                    ("cursor", .document([])),
                    ("maxTimeMS", .int64(timeoutMs)),
                ]
            }
        } catch let error as EJSONError {
            throw MongoAdapterError.invalidExtendedJSON(error.userMessage)
        }

        let startedAt = ContinuousClock.now
        let watchdog = Task { [requestState, timeout = options.timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            requestState.fireTimeout()
        }
        defer { watchdog.cancel() }

        do {
            let fetched = try await withTaskCancellationHandler {
                try await runCursor(
                    commandPairs: commandPairs,
                    collection: collection,
                    options: options,
                    requestState: requestState
                )
            } onCancel: {
                requestState.cancel()
            }
            let elapsed = max(0, Int((ContinuousClock.now - startedAt) / .milliseconds(1)))
            return try assembleResult(fetched: fetched, options: options, elapsed: elapsed)
        } catch let error as MongoAdapterError {
            throw error
        } catch let error as EJSONError {
            throw MongoAdapterError.invalidExtendedJSON(error.userMessage)
        } catch {
            throw MongoErrorMapper.map(error, requestState: requestState)
        }
    }

    /// MongoDB supports real cancellation (killCursors), so this never throws
    /// `cancellationUnsupported`. Unknown IDs are pre-registered: a later
    /// `execute` with the same ID fails immediately, as on the other engines.
    public func cancel(requestID: UUID) async throws {
        let handle = state.withLock { state -> MongoRequestState? in
            state.cancelledRequestIDs.insert(requestID)
            return state.active[requestID]
        }
        handle?.cancel()
    }

    public func close() async {
        let handles = state.withLock { state -> [MongoRequestState] in
            guard !state.closed else { return [] }
            state.closed = true
            return Array(state.active.values)
        }
        for handle in handles { handle.cancel() }
        await cluster.disconnect()
    }

    // MARK: - Cursor execution

    private struct FetchedDocuments: Sendable {
        var documents: [Document]
        var serverHasMore: Bool
    }

    private func runCursor(
        commandPairs: [(key: String, value: BSONValue)],
        collection: String,
        options: ExecuteOptions,
        requestState: MongoRequestState
    ) async throws -> FetchedDocuments {
        let commandData = try BSONWriter.encode(document: commandPairs)
        let connection = try await cluster.next(for: .basic)

        let reply = try await connection.executeCodable(
            Document(data: commandData),
            decodeAs: MongoCursorResponse.self,
            namespace: MongoNamespace(to: "$cmd", inDatabase: databaseName),
            sessionId: connection.implicitSessionId
        )
        let cursor = MongoCursor(
            reply: reply.cursor,
            in: MongoNamespace(to: collection, inDatabase: databaseName),
            connection: connection,
            session: connection.implicitSession,
            transaction: nil
        )
        cursor.maxTimeMS = Int32(clamping: Self.timeoutMilliseconds(options.timeout))
        requestState.attach(cursor)
        if requestState.cancelRequested { throw MongoAdapterError.cancelled }
        if requestState.timedOut { throw MongoAdapterError.timedOut }

        var documents: [Document] = []
        let wanted = options.maxRows + 1
        do {
            while documents.count < wanted, !cursor.isDrained {
                let batch = try await cursor.getMore(batchSize: max(1, min(101, wanted - documents.count)))
                if batch.isEmpty, !cursor.isDrained { break }
                documents.append(contentsOf: batch)
            }
        } catch {
            if !cursor.isDrained { try? await cursor.close() }
            throw error
        }

        let serverHasMore = !cursor.isDrained
        if serverHasMore { try? await cursor.close() }
        return FetchedDocuments(documents: documents, serverHasMore: serverHasMore)
    }

    private func assembleResult(
        fetched: FetchedDocuments,
        options: ExecuteOptions,
        elapsed: Int
    ) throws -> QueryResult {
        var documents: [DisplayValue] = []
        var bytes = 0
        var truncated = fetched.serverHasMore || fetched.documents.count > options.maxRows

        for document in fetched.documents.prefix(options.maxRows) {
            var reader = BSONReader(data: document.makeData())
            let pairs = try reader.readDocument()
            let documentBytes = EJSONSerializer.serialize(document: pairs).utf8.count
            if bytes + documentBytes > options.maxBytes {
                truncated = true
                break
            }
            bytes += documentBytes
            documents.append(MongoDisplayValue.convert(document: pairs))
        }

        return .documents(
            documents,
            meta: ResultMeta(count: documents.count, truncated: truncated, elapsedMilliseconds: elapsed)
        )
    }

    // MARK: - Pipeline guard

    /// Write stages are scanned across every key of every stage — a stage with
    /// extra keys smuggled next to a read operator is still rejected.
    static func assertReadOnlyPipeline(_ stages: [BSONValue]) throws {
        for stage in stages {
            guard case .document(let pairs) = stage else { throw EJSONError.stageNotDocument }
            for pair in pairs where writeStages.contains(pair.key) {
                throw MongoAdapterError.writeStageRejected(pair.key)
            }
        }
    }

    // MARK: - Configuration

    /// Fail-closed validation and normalization of the connection URI. SRV URIs
    /// require TLS (the driver's SRV path would silently upgrade otherwise);
    /// the UI's TLS toggle is authoritative and rewrites any tls/ssl URI param.
    static func effectiveURI(input: ConnectionInput.MongoInput) throws -> String {
        let uri = input.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else {
            throw MongoAdapterError.invalidConfiguration("The MongoDB URI cannot be empty.")
        }
        let lowered = uri.lowercased()
        let isSRV = lowered.hasPrefix("mongodb+srv://")
        guard isSRV || lowered.hasPrefix("mongodb://") else {
            throw MongoAdapterError.invalidConfiguration("The MongoDB URI must start with mongodb:// or mongodb+srv://.")
        }
        if isSRV, !input.tls {
            throw MongoAdapterError.invalidConfiguration(
                "MongoDB SRV URIs (mongodb+srv://) require TLS. Enable TLS or use a standard mongodb:// URI."
            )
        }

        let split = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(split[0])
        var parameters: [String] = split.count == 2
            ? split[1].split(separator: "&").map(String.init).filter { parameter in
                let key = parameter.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                return key != "tls" && key != "ssl" && !key.isEmpty
            }
            : []
        parameters.append("tls=\(input.tls)")
        if !parameters.contains(where: { $0.lowercased().hasPrefix("appname=") }) {
            parameters.append("appName=dbbbb")
        }
        if !parameters.contains(where: { $0.lowercased().hasPrefix("connecttimeoutms=") }) {
            parameters.append("connectTimeoutMS=10000")
        }
        return base + "?" + parameters.joined(separator: "&")
    }

    static func timeoutMilliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let millis = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        return max(1, min(millis, Int64(Int32.max)))
    }

    // MARK: - Object identifiers

    /// Opaque object handles, same scheme as the Electron reference:
    /// `mongo:collection:<base64url(database \0 collection)>`.
    static func databaseID(for database: String) -> String {
        "mongo:database:\(base64url(Data(database.utf8)))"
    }

    static func collectionID(for collection: String, database: String) -> String {
        "mongo:collection:\(base64url(Data((database + "\0" + collection).utf8)))"
    }

    static func collectionName(from id: String, database: String) throws -> String {
        let prefix = "mongo:collection:"
        guard id.hasPrefix(prefix), let data = Self.data(base64url: String(id.dropFirst(prefix.count))),
              let decoded = String(data: data, encoding: .utf8),
              let separator = decoded.firstIndex(of: "\0")
        else {
            throw AdapterError.notFound("Unknown MongoDB object. Refresh the object list and try again.")
        }
        let decodedDatabase = String(decoded[..<separator])
        guard decodedDatabase == database else {
            throw AdapterError.notFound("This MongoDB object belongs to a different database.")
        }
        return String(decoded[decoded.index(after: separator)...])
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func data(base64url: String) -> Data? {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - State

    private func assertOpen() throws {
        if state.withLock({ $0.closed }) { throw AdapterError.sessionClosed }
    }
}

// MARK: - Editing

extension MongoAdapter: SupportsEditing {
    /// Reply of one update/delete command: `n` is the matched (update) or
    /// deleted count; write errors (e.g. unique-index violations) arrive with
    /// `ok: 1` and must be read off the reply.
    private struct MongoWriteReply: Decodable {
        struct WriteError: Decodable {
            let code: Int?
        }
        let n: Int
        let writeErrors: [WriteError]?
    }

    /// Same fixed server-side cap as the Electron adapter.
    private static let dataChangeMaxTimeMS: Int64 = 30_000

    /// Applies one reviewed single-document change. The whole original
    /// document is the optimistic-concurrency baseline: a zero matched/deleted
    /// count means the document changed or vanished underneath the edit.
    /// Read-only sessions are refused client-side here; server-side
    /// authorization is the second layer.
    public func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        try assertOpen()
        if profile.readOnly {
            throw MongoAdapterError.server(
                "Document changes are disabled for read-only MongoDB connections.")
        }
        guard change.object.kind == .collection else {
            throw AdapterError.notFound("MongoDB document changes require a collection target.")
        }
        let collection = try Self.collectionName(from: change.object.id, database: databaseName)

        let startedAt = ContinuousClock.now
        let original = try MongoChangePlanner.documentEntries(
            change.original, label: "MongoDB original document")

        let commandPairs: [(key: String, value: BSONValue)]
        switch change.operation {
        case .update(let changed):
            let changedEntries = try MongoChangePlanner.documentEntries(
                changed, label: "MongoDB current document")
            var current = original
            for entry in changedEntries {
                if let index = current.firstIndex(where: { $0.field == entry.field }) {
                    current[index] = entry
                } else {
                    current.append(entry)
                }
            }
            let plan = try MongoChangePlanner.planUpdate(original: original, current: current)
            var update: [(key: String, value: BSONValue)] = []
            if !plan.set.isEmpty { update.append(("$set", .document(plan.set))) }
            if !plan.unset.isEmpty {
                update.append(("$unset", .document(plan.unset.map { ($0, .string("")) })))
            }
            commandPairs = [
                ("update", .string(collection)),
                ("updates", .array([.document([
                    ("q", .document(plan.filter)),
                    ("u", .document(update)),
                    ("upsert", .bool(false)),
                    ("multi", .bool(false)),
                ])])),
                ("maxTimeMS", .int64(Self.dataChangeMaxTimeMS)),
            ]
        case .delete:
            let filter = try MongoChangePlanner.planDeleteFilter(original: original)
            commandPairs = [
                ("delete", .string(collection)),
                ("deletes", .array([.document([
                    ("q", .document(filter)),
                    ("limit", .int32(1)),
                ])])),
                ("maxTimeMS", .int64(Self.dataChangeMaxTimeMS)),
            ]
        }

        do {
            let reply = try await runWriteCommand(commandPairs)
            if let writeError = reply.writeErrors?.first {
                throw MongoErrorMapper.mapDataChangeCode(writeError.code)
                    ?? .server("MongoDB could not apply the document change.")
            }
            guard reply.n > 0 else {
                throw MongoAdapterError.server(
                    "MongoDB document changed or was deleted after it was loaded. Refresh it and try again.")
            }
            let elapsed = max(0, Int((ContinuousClock.now - startedAt) / .milliseconds(1)))
            return .documents([], meta: ResultMeta(
                count: 0, truncated: false, elapsedMilliseconds: elapsed))
        } catch let error as MongoAdapterError {
            throw error
        } catch {
            throw MongoErrorMapper.mapDataChange(error)
        }
    }

    /// Runs one update/delete command and returns the server's affected-count
    /// reply. Write commands share the find path's raw-command construction:
    /// dbbbb's own BSON writer, wrapped in a `Document`, decoded as a reply.
    private func runWriteCommand(
        _ commandPairs: [(key: String, value: BSONValue)]
    ) async throws -> MongoWriteReply {
        let commandData = try BSONWriter.encode(document: commandPairs)
        let connection = try await cluster.next(for: .basic)
        return try await connection.executeCodable(
            Document(data: commandData),
            decodeAs: MongoWriteReply.self,
            namespace: MongoNamespace(to: "$cmd", inDatabase: databaseName),
            sessionId: connection.implicitSessionId
        )
    }
}

// MARK: - Importing

extension MongoAdapter: SupportsImporting {
    /// Same fixed server-side cap as the document-change commands.
    private static let importMaxTimeMS: Int64 = 30_000

    /// Streams a JSON Lines file into one collection, one ordered `insert`
    /// command per batch. Documents parse through the canonical EJSON codec;
    /// the import is *not* transactional — a failed batch may leave earlier
    /// batches (and the ordered prefix of the failing batch) inserted, exactly
    /// like the Electron adapter.
    public func importData(_ request: ImportRequest) async throws -> ImportSummary {
        try assertOpen()
        if profile.readOnly {
            throw ImportError.unsupported(
                "Import is disabled for read-only MongoDB connections.")
        }
        guard request.format == .jsonl else {
            throw ImportError.unsupported("MongoDB collection imports accept JSON Lines files.")
        }
        guard request.target.kind == .collection else {
            throw AdapterError.notFound("MongoDB import requires a collection target.")
        }
        let collection = try Self.collectionName(from: request.target.id, database: databaseName)

        do {
            return try await JSONLImportDriver.run(
                fileURL: request.fileURL,
                isCancelled: request.isCancelled,
                onProgress: request.onProgress,
                parse: { line, content in
                    try MongoImportPlanner.document(line: line, content: content)
                },
                insertBatch: { [self] documents in
                    if request.isCancelled() { throw ImportError.cancelled }
                    let reply = try await runWriteCommand(
                        MongoImportPlanner.insertCommand(
                            collection: collection,
                            documents: documents,
                            maxTimeMS: Self.importMaxTimeMS))
                    // Ordered batches stop at the first failing document; `n`
                    // credits what the server actually inserted and the driver
                    // fails the rest (the Electron runner's insertedCount).
                    return reply.n
                })
        } catch let error as ImportError {
            throw error
        } catch let error as MongoAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw MongoErrorMapper.map(error)
        }
    }
}
