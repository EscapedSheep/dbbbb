import Foundation
import dbbbbCore
import Synchronization

/// Options for `BullmqAdapter.collectBullmqJobs` (snapshot export stream).
public struct BullmqCollectOptions: Sendable {
    public var queue: String
    public var states: [BullmqJobState]?
    public var requestID: UUID?
    public init(queue: String, states: [BullmqJobState]? = nil, requestID: UUID? = nil) {
        self.queue = queue; self.states = states; self.requestID = requestID
    }
}

/// BullMQ adapter: talks raw Redis commands instead of linking bullmq itself.
/// State queries hit the per-state indexes directly (failed/completed/delayed/
/// prioritized/waiting-children as zsets, wait/active/paused as lists), and
/// content filters page through them in batches under a scan budget so a huge
/// queue cannot stall the app. Each page is fetched server-side by one Lua
/// script wrapped in an injectable fetcher, so unit tests run the identical
/// logic over a fake client. Semantics mirror the Electron reference adapter.
///
/// Read-only by construction: the adapter never conforms to any write
/// capability protocol.
public final class BullmqAdapter: DatabaseAdapter, Sendable {
    public let profile: ConnectionProfile

    private let input: ConnectionInput.BullmqInput
    private let client: any RedisClienting
    private let fetcher: any BullmqPageFetching

    private struct State {
        var closed = false
        var connected = false
        var knownQueues: Set<String> = []
        var activeRequestIDs: Set<UUID> = []
        var cancelledRequestIDs: Set<UUID> = []
        var timedOutRequestIDs: Set<UUID> = []
    }

    private let state: Mutex<State>

    private static let filterBatchSize = 200
    private static let collectBatchSize = 500
    // COUNT is only a server-side hint: queue discovery is O(keyspace × RTT),
    // so on a slow remote with tens of thousands of keys a small COUNT means
    // hundreds of round trips (measured: ~290 RTTs ≈ 102 s at 350 ms RTT).
    // 10 000 keeps even a large keyspace to a handful of round trips.
    private static let scanCount = 10_000
    private static let defaultMaxBytes = 5 * 1024 * 1024

    public convenience init(input: ConnectionInput.BullmqInput) throws {
        let client = RedisConnection(
            host: input.host, port: input.port, password: input.password,
            database: input.database, tls: input.tls)
        try self.init(input: input, client: client, fetcher: nil)
    }

    /// Dependency-injected form: tests and the demo adapter hand in an
    /// in-memory client and the JS page fetcher; production uses
    /// `RedisConnection` and the Lua fetcher (nil fetcher).
    public init(input: ConnectionInput.BullmqInput, client: any RedisClienting, fetcher: (any BullmqPageFetching)?) throws {
        guard !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(input.port),
              (0...15).contains(input.database),
              input.prefix.range(of: #"^[A-Za-z0-9:_-]{1,64}$"#, options: .regularExpression) != nil
        else {
            throw BullmqAdapterError.invalidConfiguration
        }
        self.input = input
        self.client = client
        self.fetcher = fetcher ?? BullmqLuaPageFetcher(client: client)
        self.state = Mutex(State())
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .bullmq,
            endpoint: "\(input.host):\(input.port)",
            database: String(input.database),
            environment: input.environment,
            readOnly: input.readOnly)
    }

    // MARK: - DatabaseAdapter

    /// Explicit connect, idempotent. Kept public for callers that want the
    /// round trip up front (SessionStore probes with it at add time).
    public func connect() async throws {
        try assertOpen()
        if state.withLock({ $0.connected }) { return }
        do {
            try await client.connect()
            try await client.ping()
        } catch {
            await client.disconnect()
            throw BullmqErrorMapper.map(error)
        }
        state.withLock { $0.connected = true }
    }

    /// The sibling adapters' lazy pattern (PostgreSQL connects on first
    /// query, MongoDB in its async init): every public operation connects on
    /// first use, so factory-constructed adapters work without an explicit
    /// connect. `close()` still fails closed — a closed adapter never
    /// resurrects itself.
    ///
    /// A concurrent first use may enter `client.connect()` twice;
    /// `RedisConnection.connect` guards on `channel == nil`, so the loser
    /// returns immediately and harmlessly.
    private func ensureConnected() async throws {
        try assertOpen()
        if state.withLock({ $0.connected }) { return }
        try await connect()
    }

    /// Queues as collection nodes plus one state node per queue (all eight
    /// states, even empty ones), with the live job count as the detail.
    public func listObjects() async throws -> [DatabaseObject] {
        try await ensureConnected()
        do {
            let queues = try await discoverQueues()
            state.withLock { $0.knownQueues = Set(queues) }
            var nodes: [DatabaseObject] = []
            for queue in queues {
                nodes.append(DatabaseObject(id: queue, parentID: nil, name: queue, kind: .collection))
                for (jobState, count) in try await stateCounts(queue) {
                    nodes.append(DatabaseObject(
                        id: "\(queue):\(jobState.rawValue)",
                        parentID: queue,
                        name: jobState.rawValue,
                        kind: .table,
                        detail: "\(count) \(count == 1 ? "job" : "jobs")"))
                }
            }
            return nodes
        } catch let error as BullmqAdapterError {
            throw error
        } catch {
            throw BullmqErrorMapper.map(error)
        }
    }

    /// Browses one queue or state node: runs the equivalent of the reference's
    /// preview command (`{queue, state ?? "failed", limit}`) directly. The
    /// preview page offset maps onto the query's cursor — both are offsets
    /// into the state index, so the preview pager pages the index exactly.
    public func previewObject(_ request: PreviewRequest) async throws -> QueryResult {
        try await ensureConnected()
        let knownQueues = state.withLock { $0.knownQueues }
        guard let resolved = BullmqDocumentMapper.resolveObjectID(knownQueues, objectID: request.object.id) else {
            throw BullmqAdapterError.unknownObject
        }
        var pairs: [(key: String, value: DisplayValue)] = [
            ("queue", .string(resolved.queue)),
            ("state", .string((resolved.state ?? .failed).rawValue)),
            ("limit", .number(Double(request.normalizedLimit))),
        ]
        if request.normalizedOffset > 0 {
            pairs.append(("cursor", .number(Double(request.normalizedOffset))))
        }
        let text = BullmqJSON.stringify(.object(pairs))
        return try await execute(
            .bullmqJobs(text),
            options: ExecuteOptions(requestID: request.requestID, maxRows: request.normalizedLimit))
    }

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        try await ensureConnected()
        guard case .bullmqJobs(let text) = command else {
            throw BullmqAdapterError.commandRejected
        }
        guard options.timeout > .zero, options.maxRows >= 1, options.maxBytes >= 1 else {
            throw BullmqAdapterError.invalidOptions
        }
        try register(requestID: options.requestID)
        defer { unregister(requestID: options.requestID) }

        let startedAt = ContinuousClock.now
        let watchdog = Task { [self] in
            try? await Task.sleep(for: options.timeout)
            guard !Task.isCancelled else { return }
            _ = state.withLock { $0.timedOutRequestIDs.insert(options.requestID) }
        }
        defer { watchdog.cancel() }

        do {
            var query = try BullmqQueryParser.parse(text)
            query.limit = min(query.limit, options.maxRows)
            let filtered = query.name != nil || query.whereClauses != nil
                || (query.state == .prioritized && (query.from != nil || query.to != nil))
            let page: PageResult
            if filtered {
                page = try await scanFiltered(query, options: options)
            } else {
                page = try await readIndexPage(query, options: options)
            }
            let elapsed = ContinuousClock.now - startedAt
            let milliseconds = max(0, Int((elapsed.components.seconds * 1000) + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)))
            return .documents(page.documents, meta: ResultMeta(
                count: page.documents.count,
                truncated: page.truncated,
                elapsedMilliseconds: milliseconds,
                scanned: page.scanned,
                total: page.total,
                nextCursor: page.nextCursor))
        } catch {
            if isTimedOut(options.requestID) { throw BullmqAdapterError.timedOut }
            if isCancelled(options.requestID) { throw BullmqAdapterError.cancelled }
            throw BullmqErrorMapper.map(error)
        }
    }

    /// Cancellation mirrors the Electron adapter: request ids can be
    /// pre-registered (a later `execute` with that id fails immediately), and
    /// running scans check the flag between batches.
    public func cancel(requestID: UUID) async throws {
        _ = state.withLock { $0.cancelledRequestIDs.insert(requestID) }
    }

    public func close() async {
        let alreadyClosed = state.withLock { state -> Bool in
            let wasClosed = state.closed
            state.closed = true
            state.activeRequestIDs.removeAll()
            state.cancelledRequestIDs.removeAll()
            state.timedOutRequestIDs.removeAll()
            return wasClosed
        }
        guard !alreadyClosed else { return }
        await client.disconnect()
    }

    // MARK: - Snapshot collection

    /// Streams every requested state's jobs in plain offset order — no time or
    /// content filters — handing batches to the writer. Logs are never
    /// collected: snapshots stay lightweight. Mirrors the reference's
    /// `collectBullmqJobs`.
    public func collectBullmqJobs(
        options: BullmqCollectOptions,
        onBatch: @Sendable ([DisplayValue]) async throws -> Void
    ) async throws -> Int {
        try await ensureConnected()
        guard !options.queue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              options.queue.count <= 512 else {
            throw BullmqAdapterError.invalidQuery("BullMQ snapshot queue is invalid.")
        }
        let states = options.states ?? BullmqJobState.allCases
        if let requestID = options.requestID {
            try register(requestID: requestID)
        }
        defer {
            if let requestID = options.requestID { unregister(requestID: requestID) }
        }

        var collected = 0
        do {
            for jobState in states {
                let key = keyFor(options.queue, jobState.indexKey)
                let total = jobState.isZset ? try await client.zcard(key) : try await client.llen(key)
                var position = 0
                while position < total {
                    if let requestID = options.requestID, isCancelled(requestID) {
                        throw BullmqAdapterError.cancelled
                    }
                    await Task.yield()
                    let page = try await fetcher.fetch(BullmqPageRequest(
                        indexKey: key,
                        jobKeyPrefix: keyFor(options.queue, ""),
                        kind: jobState.isZset ? .zset : .list,
                        offset: position,
                        count: Self.collectBatchSize))
                    if page.consumed == 0 { break }
                    position += page.consumed
                    var jobs: [DisplayValue] = []
                    for entry in page.entries {
                        if let document = BullmqDocumentMapper.jobHashToDocument(
                            id: entry.id, queue: options.queue, state: jobState, hash: entry.fields) {
                            jobs.append(document)
                        }
                    }
                    collected += jobs.count
                    try await onBatch(jobs)
                }
            }
            return collected
        } catch {
            if let requestID = options.requestID, isCancelled(requestID) {
                throw BullmqAdapterError.cancelled
            }
            throw BullmqErrorMapper.map(error)
        }
    }

    // MARK: - Query internals

    private struct PageResult {
        var documents: [DisplayValue]
        var truncated: Bool
        var scanned: Int
        var total: Int
        var nextCursor: Int
    }

    /// Unfiltered path: one page straight from the index plus the index total.
    private func readIndexPage(_ query: ResolvedBullmqJobQuery, options: ExecuteOptions) async throws -> PageResult {
        async let page = fetcher.fetch(pageRequest(query, offset: query.cursor, count: query.limit))
        async let total = totalFor(query)
        let (fetched, indexTotal) = try await (page, total)
        var candidates: [DisplayValue] = []
        for entry in fetched.entries {
            if let document = entryToDocument(query, entry: entry) { candidates.append(document) }
        }
        let bounded = boundDocuments(candidates, maxBytes: options.maxBytes)
        let nextCursor = query.cursor + fetched.consumed
        return PageResult(
            documents: bounded.documents,
            truncated: bounded.truncated || nextCursor < indexTotal,
            scanned: fetched.consumed,
            total: indexTotal,
            nextCursor: nextCursor)
    }

    /// Filtered path: batch-scan the index under the scan budget, matching
    /// name/where/timestamp in memory. The whole batch counts as scanned,
    /// even entries past the one that fills the limit.
    private func scanFiltered(_ query: ResolvedBullmqJobQuery, options: ExecuteOptions) async throws -> PageResult {
        let total = try await totalFor(query)
        var matches: [DisplayValue] = []
        var position = query.cursor
        var scanned = 0
        var bytes = 0
        var byteTruncated = false

        while matches.count < query.limit && scanned < query.scanBudget && position < total {
            try assertNotInterrupted(options.requestID)
            await Task.yield()
            let batchSize = min(Self.filterBatchSize, query.scanBudget - scanned, total - position)
            let page = try await fetcher.fetch(pageRequest(query, offset: position, count: batchSize))
            if page.consumed == 0 { break }
            position += page.consumed
            scanned += page.consumed
            for entry in page.entries {
                guard let document = entryToDocument(query, entry: entry),
                      BullmqDocumentMatcher.matches(document, query: query) else { continue }
                let documentBytes = BullmqJSON.stringify(document).utf8.count
                if bytes + documentBytes > options.maxBytes {
                    byteTruncated = true
                    break
                }
                bytes += documentBytes
                matches.append(document)
                if matches.count >= query.limit { break }
            }
            if byteTruncated { break }
        }

        return PageResult(
            documents: matches,
            truncated: byteTruncated || position < total,
            scanned: scanned,
            total: total,
            nextCursor: position)
    }

    private func totalFor(_ query: ResolvedBullmqJobQuery) async throws -> Int {
        let key = keyFor(query.queue, query.state.indexKey)
        if !query.state.isZset { return try await client.llen(key) }
        // Prioritized ranges are matched in memory, so the honest total is the
        // whole index, not a score window.
        if query.state == .prioritized || (query.from == nil && query.to == nil) {
            return try await client.zcard(key)
        }
        return try await client.zcount(
            key,
            min: query.from.map(Self.scoreString) ?? "-inf",
            max: query.to.map(Self.scoreString) ?? "+inf")
    }

    private func pageRequest(_ query: ResolvedBullmqJobQuery, offset: Int, count: Int) -> BullmqPageRequest {
        var request = BullmqPageRequest(
            indexKey: keyFor(query.queue, query.state.indexKey),
            jobKeyPrefix: keyFor(query.queue, ""),
            kind: query.state.isZset ? .zset : .list,
            offset: offset,
            count: count)
        // Score ranges are only meaningful for zset indexes whose score is a
        // plain timestamp — prioritized excluded, see totalFor.
        if query.state != .prioritized, query.state.isZset, query.from != nil || query.to != nil {
            request.minScore = query.from.map(Self.scoreString) ?? "-inf"
            request.maxScore = query.to.map(Self.scoreString) ?? "+inf"
        }
        request.includeLogs = query.includeLogs
        return request
    }

    private func entryToDocument(_ query: ResolvedBullmqJobQuery, entry: BullmqPageEntry) -> DisplayValue? {
        guard var document = BullmqDocumentMapper.jobHashToDocument(
            id: entry.id, queue: query.queue, state: query.state, hash: entry.fields) else { return nil }
        if query.includeLogs, case .object(var pairs) = document {
            pairs.append(("logs", .array((entry.logs ?? []).map(DisplayValue.string))))
            pairs.append(("logsTotal", .number(Double(entry.logsTotal ?? 0))))
            document = .object(pairs)
        }
        return document
    }

    private func boundDocuments(_ candidates: [DisplayValue], maxBytes: Int) -> (documents: [DisplayValue], truncated: Bool) {
        var documents: [DisplayValue] = []
        var bytes = 0
        var truncated = false
        for document in candidates {
            let documentBytes = BullmqJSON.stringify(document).utf8.count
            if bytes + documentBytes > maxBytes {
                truncated = true
                break
            }
            bytes += documentBytes
            documents.append(document)
        }
        return (documents, truncated)
    }

    // MARK: - Discovery

    /// SCAN `<prefix>:*:id` — every queue keeps an id counter key.
    private func discoverQueues() async throws -> [String] {
        let prefixMarker = "\(input.prefix):"
        var queues = Set<String>()
        var cursor = "0"
        repeat {
            let reply = try await client.scan(cursor: cursor, match: "\(prefixMarker)*:id", count: Self.scanCount)
            for key in reply.keys where key.hasPrefix(prefixMarker) && key.hasSuffix(":id")
                && key.count > prefixMarker.count + 3 {
                queues.insert(String(key.dropFirst(prefixMarker.count).dropLast(3)))
            }
            cursor = reply.nextCursor
        } while cursor != "0"
        return queues.sorted()
    }

    private func stateCounts(_ queue: String) async throws -> [(BullmqJobState, Int)] {
        let commands = BullmqJobState.allCases.map { jobState in
            [jobState.isZset ? "zcard" : "llen", keyFor(queue, jobState.indexKey)]
        }
        let replies = try await client.pipeline(commands)
        return try BullmqJobState.allCases.enumerated().map { index, jobState in
            guard index < replies.count else { throw RedisError.unexpectedReply }
            switch replies[index] {
            case .error(let text): throw RedisErrorMapper.mapServerError(text)
            case .value(let value): return (jobState, try BullmqLuaPageFetcher.asCount(value))
            }
        }
    }

    // MARK: - Helpers

    private func keyFor(_ segments: String...) -> String {
        "\(input.prefix):\(segments.joined(separator: ":"))"
    }

    /// JS-style number formatting for ZRANGEBYSCORE bounds ("150", not "150.0").
    private static func scoreString(_ value: Double) -> String {
        BullmqJSON.numberString(value)
    }

    private func assertOpen() throws {
        if state.withLock({ $0.closed }) { throw BullmqAdapterError.closed }
    }

    private func isCancelled(_ requestID: UUID) -> Bool {
        state.withLock { $0.cancelledRequestIDs.contains(requestID) }
    }

    private func isTimedOut(_ requestID: UUID) -> Bool {
        state.withLock { $0.timedOutRequestIDs.contains(requestID) }
    }

    private func assertNotInterrupted(_ requestID: UUID) throws {
        if isCancelled(requestID) { throw BullmqAdapterError.cancelled }
        if isTimedOut(requestID) { throw BullmqAdapterError.timedOut }
    }

    /// Pre-registered cancellations fire immediately; duplicates are rejected.
    private func register(requestID: UUID) throws {
        try state.withLock { state in
            if state.cancelledRequestIDs.remove(requestID) != nil {
                throw BullmqAdapterError.cancelled
            }
            if state.activeRequestIDs.contains(requestID) {
                throw BullmqAdapterError.duplicateRequest
            }
            state.activeRequestIDs.insert(requestID)
        }
    }

    private func unregister(requestID: UUID) {
        state.withLock { state in
            state.activeRequestIDs.remove(requestID)
            state.cancelledRequestIDs.remove(requestID)
            state.timedOutRequestIDs.remove(requestID)
        }
    }
}

/// Snapshot-stream capability ("Sync to local SQL"): walks one queue's state
/// indexes in batches and hands display documents to the writer. Read-only —
/// nothing about the queue is modified. The BullMQ adapter conforms; the demo
/// adapter delegates to its embedded BullMQ adapter.
public protocol SupportsBullmqSnapshot: DatabaseAdapter {
    func collectBullmqJobs(
        options: BullmqCollectOptions,
        onBatch: @Sendable ([DisplayValue]) async throws -> Void
    ) async throws -> Int
}

extension BullmqAdapter: SupportsBullmqSnapshot {}
