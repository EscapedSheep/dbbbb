import Foundation
import dbbbbCore

/// The engine adapter contract. Implementations own one live session.
/// Editing (`applyDataChange`) and importing (`importData`) are optional capabilities:
/// adapters that do not support them simply leave them unimplemented via `SupportsEditing` /
/// `SupportsImporting`, and callers must fail closed.
public protocol DatabaseAdapter: Sendable {
    var profile: ConnectionProfile { get }
    func listObjects() async throws -> [DatabaseObject]
    /// Browses one object: one page of rows/documents, optionally sorted and
    /// filtered. Implementations fetch `limit + 1` rows and report the extra
    /// row through `ResultMeta.truncated`, so the caller can tell whether a
    /// next page exists.
    func previewObject(_ request: PreviewRequest) async throws -> QueryResult
    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult
    /// Best-effort cancellation of a running request. Engines without server-side
    /// interruption throw `AdapterError.cancellationUnsupported`.
    func cancel(requestID: UUID) async throws
    func close() async
}

public extension DatabaseAdapter {
    /// The pre-pagination call shape: first page, no sort, no filter.
    func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        try await previewObject(PreviewRequest(object: object))
    }
}

/// One page of an object preview: where to start, how much to fetch, and the
/// optional grid sort/filter. All engines share this contract (ROADMAP M1 ①②):
/// SQL adapters render it as `LIMIT/OFFSET` + `ORDER BY` + a bound `LIKE`
/// predicate, MongoDB as `skip`/`limit` + a sort document + a `$regex` filter.
public struct PreviewRequest: Sendable, Equatable {
    /// Grid sort on one column; nil keeps the engine's natural order.
    public struct Sort: Sendable, Equatable {
        public let column: String
        public let ascending: Bool
        public init(column: String, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// The single supported filter operation: text contains (covers the
    /// common "find this value in this column" case).
    public struct Filter: Sendable, Equatable {
        public let column: String
        public let contains: String
        public init(column: String, contains: String) {
            self.column = column
            self.contains = contains
        }
    }

    /// One exact-match predicate on a column (ROADMAP M1 ⑤ foreign-key
    /// jumps). SQL engines render it with their null-safe operator
    /// (PostgreSQL `IS NOT DISTINCT FROM`, MySQL `<=>`, SQLite `IS`/`=`),
    /// the value always crossing as a bound parameter. MongoDB has no
    /// foreign keys and fails closed on equality filters.
    public struct Equality: Sendable, Equatable {
        public let column: String
        public let value: DisplayValue
        public init(column: String, value: DisplayValue) {
            self.column = column
            self.value = value
        }
    }

    public static let defaultLimit = 100

    public let object: DatabaseObject
    public let offset: Int
    public let limit: Int
    public let sort: Sort?
    public let filter: Filter?
    /// Exact-match predicates, AND-ed with each other and with `filter`.
    /// Only the foreign-key jump produces them; the grid filter UI works
    /// through `filter` alone.
    public let equalities: [Equality]
    /// Carried so previews register on the adapter's cancellation path exactly
    /// like ad-hoc queries (`cancel(requestID:)` must interrupt a page load).
    public let requestID: UUID

    public init(
        object: DatabaseObject,
        offset: Int = 0,
        limit: Int = PreviewRequest.defaultLimit,
        sort: Sort? = nil,
        filter: Filter? = nil,
        equalities: [Equality] = [],
        requestID: UUID = UUID()
    ) {
        self.object = object
        self.offset = offset
        self.limit = limit
        self.sort = sort
        self.filter = filter
        self.equalities = equalities
        self.requestID = requestID
    }

    /// Defensive clamps; the UI already keeps these in range.
    public var normalizedOffset: Int { max(0, offset) }
    public var normalizedLimit: Int { max(1, limit) }

    /// `%text%` with the LIKE wildcards `%`/`_` and the backslash escape
    /// character itself escaped — the value still crosses as a bind parameter,
    /// never as SQL text. All three SQL engines use backslash as the LIKE
    /// escape (PostgreSQL/SQLite explicitly via `ESCAPE '\'`, MySQL by
    /// default regardless of NO_BACKSLASH_ESCAPES, which only affects string
    /// literal parsing).
    public static func likePattern(containing text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count + 2)
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    /// Escapes every regular-expression metacharacter so the MongoDB grid
    /// filter is a literal substring match: user input can neither inject
    /// query operators nor craft a pathological regex (ReDoS).
    public static func mongoRegexEscaped(_ text: String) -> String {
        let metacharacters: Set<Character> = ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if metacharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}

/// Optional editing capability (safe single-record changes with optimistic concurrency).
public protocol SupportsEditing: DatabaseAdapter {
    func applyDataChange(_ change: DataChange) async throws -> QueryResult
    /// Insertable columns of one introspected change target, in catalog order,
    /// for building insert drafts. Implementations re-run the same metadata
    /// introspection as `applyDataChange` (generated columns excluded,
    /// round-trip refusal list enforced), so this is a read: read-only
    /// profiles still allow it. MongoDB collections have no fixed columns —
    /// document drafts need no metadata, and the adapter fails closed here.
    func insertableColumns(for object: DatabaseObject) async throws -> [InsertableColumn]
}

/// One insertable column of a change target, for building insert drafts.
public struct InsertableColumn: Sendable, Equatable {
    public let name: String
    /// The 1-based position in the primary key; 0 when not part of it.
    public let primaryKeyOrdinal: Int
    public init(name: String, primaryKeyOrdinal: Int) {
        self.name = name; self.primaryKeyOrdinal = primaryKeyOrdinal
    }
}

/// Optional import capability (streaming file import into one known target).
/// Adapters re-check the read-only guardrail themselves; callers must also
/// fail closed when the adapter does not conform.
public protocol SupportsImporting: DatabaseAdapter {
    func importData(_ request: ImportRequest) async throws -> ImportSummary
}

/// Optional foreign-key introspection capability ("Jump to Referenced Row",
/// ROADMAP M1 ⑤). Engines without foreign keys (MongoDB) simply do not
/// conform, and callers must fail closed. Reading metadata is a read:
/// read-only profiles still allow it.
public protocol SupportsForeignKeys: DatabaseAdapter {
    /// The foreign keys of one introspected table, grouped by constraint
    /// (multi-column keys keep their ordinal column order). Referenced
    /// object ids use the same handle shape `listObjects` emits.
    func foreignKeys(for object: DatabaseObject) async throws -> [ForeignKey]
}

/// Optional DDL introspection capability ("View Create Statement"). Engines
/// without DDL to show (MongoDB) simply do not conform, and callers must
/// fail closed. Reading DDL is a read: read-only profiles still allow it.
public protocol SupportsIntrospection: DatabaseAdapter {
    /// The create statement for one introspected table or view. Other object
    /// kinds fail closed with a sanitized error.
    func createStatement(for object: DatabaseObject) async throws -> String
}

/// Optional structured-schema introspection capability ("View Schema"): the
/// per-table column/index/foreign-key detail plus the whole-database
/// relationship overview. Engines without relational schemas (MongoDB)
/// simply do not conform, and callers must fail closed. Reading metadata is
/// a read: read-only profiles still allow it.
public protocol SupportsSchemaIntrospection: DatabaseAdapter {
    /// The structured schema of one introspected table or view. Other object
    /// kinds fail closed with a sanitized error.
    func schema(for object: DatabaseObject) async throws -> TableSchema
    /// Every foreign-key edge in the connection's scope (PostgreSQL: all user
    /// schemas; MySQL: the connection's database, or all non-system schemas
    /// on server-wide connections; SQLite: the whole file). Source and
    /// referenced object ids use the same handle shape `listObjects` emits.
    func allForeignKeys() async throws -> [TableRelation]
}

/// Optional EXPLAIN capability (ROADMAP M2 ⑧). SQL engines explain through
/// the plain text-command path — the session layer prefixes the editor text
/// with the engine's EXPLAIN form (`ExplainPlanner`) and runs it through
/// `execute`, so they never conform here. Only MongoDB, whose explain is a
/// command document (`{explain: <cmd>, verbosity: "queryPlanner"}`), needs
/// this capability; callers must fail closed on non-conformance.
public protocol SupportsExplain: DatabaseAdapter {
    /// Explains one editor command (find filter or aggregate pipeline) at
    /// queryPlanner verbosity — a plan read, never an execution.
    func explain(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult
}

/// Optional table-statistics capability (ROADMAP M2 ⑩). Adapters without a
/// statistics source simply do not conform, and callers must fail closed.
/// Reading statistics is a read: read-only profiles still allow it.
public protocol SupportsTableStatistics: DatabaseAdapter {
    /// Row/size statistics for one introspected table, view, or collection.
    /// Other object kinds fail closed with a sanitized error.
    func tableStatistics(for object: DatabaseObject) async throws -> TableStatistics
}

/// Optional server-activity capability (ROADMAP M2 ⑨): list the server's
/// in-flight operations and cancel one of them. Engines without server-side
/// processes (SQLite is file-local) simply do not conform, and callers must
/// fail closed. Listing is a read: read-only profiles still allow it. Kill is
/// gated by the session layer (non-read-only, non-demo profiles only) and
/// re-checked by the adapters themselves; it always runs out-of-pool so it
/// never queues behind the pool connection it may be killing.
public protocol SupportsServerActivity: DatabaseAdapter {
    func listActivity() async throws -> [ServerActivity]
    func killActivity(id: String) async throws
}

public enum AdapterError: dbbbbError, Equatable {
    case cancellationUnsupported
    case engineMismatch
    case sessionClosed
    case readOnlyViolation
    case notFound(String)

    public var userMessage: String {
        switch self {
        case .cancellationUnsupported: "This engine cannot cancel a running query; statements run to completion."
        case .engineMismatch: "The command does not match this connection's engine."
        case .sessionClosed: "The connection is closed."
        case .readOnlyViolation: "This session is read-only."
        case .notFound(let what): what
        }
    }
}

/// A reviewed single-record change (update, delete, or insert) against one
/// known object.
public struct DataChange: Sendable {
    public enum Operation: Sendable {
        case update(changed: [String: DisplayValue])
        case delete
        /// A new record: just the column values to insert (empty means
        /// `DEFAULT VALUES` / a document with a server-generated `_id`).
        /// There is no optimistic-concurrency baseline, so `original` stays
        /// empty — columns omitted from `values` take their server default.
        case insert(values: [String: DisplayValue])
    }
    public let object: DatabaseObject
    /// Original values as previously displayed — the optimistic-concurrency
    /// baseline. Empty for inserts (a row that does not exist yet has no
    /// baseline).
    public let original: [String: DisplayValue]
    public let operation: Operation
    public init(object: DatabaseObject, original: [String: DisplayValue], operation: Operation) {
        self.object = object; self.original = original; self.operation = operation
    }
}
