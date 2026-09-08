import Foundation

/// Supported database engines.
public enum DatabaseEngine: String, Codable, Sendable, CaseIterable {
    case postgresql, mysql, mongodb, sqlite

    public var displayName: String {
        switch self {
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .mongodb: "MongoDB"
        case .sqlite: "SQLite"
        }
    }

    /// SQL-family engines share the text-command model.
    public var isSQLFamily: Bool { self != .mongodb }
}

/// Deployment environment tag shown in the UI; production requires extra confirmation for writes.
public enum ConnectionEnvironment: String, Codable, Sendable, CaseIterable {
    case development, staging, production
}

/// SSL mode for server-based SQL engines.
public enum SSLMode: String, Codable, Sendable, CaseIterable {
    case disable, require, verifyFull = "verify-full"
}

/// Connection inputs, one case per engine. Passwords stay in the session layer;
/// they are persisted only through the Keychain vault and never in the query library.
public enum ConnectionInput: Codable, Sendable {
    case postgres(PostgresInput)
    case mysql(MySQLInput)
    case mongo(MongoInput)
    case sqlite(SQLiteInput)

    public struct PostgresInput: Codable, Sendable {
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        public var database: String
        public var sslMode: SSLMode
        public var environment: ConnectionEnvironment
        public var readOnly: Bool
        public init(name: String, host: String, port: Int = 5432, username: String, password: String, database: String, sslMode: SSLMode, environment: ConnectionEnvironment = .development, readOnly: Bool = false) {
            self.name = name; self.host = host; self.port = port; self.username = username; self.password = password
            self.database = database; self.sslMode = sslMode; self.environment = environment; self.readOnly = readOnly
        }
    }

    public struct MySQLInput: Codable, Sendable {
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        public var database: String
        public var sslMode: SSLMode
        public var environment: ConnectionEnvironment
        public var readOnly: Bool
        public init(name: String, host: String, port: Int = 3306, username: String, password: String, database: String, sslMode: SSLMode, environment: ConnectionEnvironment = .development, readOnly: Bool = false) {
            self.name = name; self.host = host; self.port = port; self.username = username; self.password = password
            self.database = database; self.sslMode = sslMode; self.environment = environment; self.readOnly = readOnly
        }
    }

    public struct MongoInput: Codable, Sendable {
        public var name: String
        public var uri: String
        public var database: String
        public var tls: Bool
        public var environment: ConnectionEnvironment
        public var readOnly: Bool
        public init(name: String, uri: String, database: String, tls: Bool = true, environment: ConnectionEnvironment = .development, readOnly: Bool = false) {
            self.name = name; self.uri = uri; self.database = database; self.tls = tls
            self.environment = environment; self.readOnly = readOnly
        }
    }

    public struct SQLiteInput: Codable, Sendable {
        public var name: String
        public var filePath: String
        public var environment: ConnectionEnvironment
        public var readOnly: Bool
        public init(name: String, filePath: String, environment: ConnectionEnvironment = .development, readOnly: Bool = false) {
            self.name = name; self.filePath = filePath; self.environment = environment; self.readOnly = readOnly
        }
    }

    public var engine: DatabaseEngine {
        switch self {
        case .postgres: .postgresql
        case .mysql: .mysql
        case .mongo: .mongodb
        case .sqlite: .sqlite
        }
    }

    public var name: String {
        switch self {
        case .postgres(let i): i.name
        case .mysql(let i): i.name
        case .mongo(let i): i.name
        case .sqlite(let i): i.name
        }
    }

    public var database: String {
        switch self {
        case .postgres(let i): i.database
        case .mysql(let i): i.database
        case .mongo(let i): i.database
        case .sqlite(let i): (i.filePath as NSString).lastPathComponent
        }
    }

    public var environment: ConnectionEnvironment {
        switch self {
        case .postgres(let i): i.environment
        case .mysql(let i): i.environment
        case .mongo(let i): i.environment
        case .sqlite(let i): i.environment
        }
    }

    public var readOnly: Bool {
        switch self {
        case .postgres(let i): i.readOnly
        case .mysql(let i): i.readOnly
        case .mongo(let i): i.readOnly
        case .sqlite(let i): i.readOnly
        }
    }

    /// Redacted, credential-free endpoint string for display.
    public var endpoint: String {
        switch self {
        case .postgres(let i): "\(i.host):\(i.port)"
        case .mysql(let i): "\(i.host):\(i.port)"
        case .mongo(let i): Self.redactMongoURI(i.uri)
        case .sqlite(let i): i.filePath
        }
    }

    static func redactMongoURI(_ uri: String) -> String {
        guard let schemeRange = uri.range(of: "://"),
              let atRange = uri.range(of: "@", options: .backwards, range: schemeRange.upperBound..<uri.endIndex) else { return uri }
        return uri.replacingCharacters(in: schemeRange.upperBound..<atRange.lowerBound, with: "***")
    }
}

/// A redacted, credential-free description of an established connection.
public struct ConnectionProfile: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let engine: DatabaseEngine
    public let endpoint: String
    public let database: String
    public let environment: ConnectionEnvironment
    public let readOnly: Bool
    public let demo: Bool
    public init(id: UUID = UUID(), name: String, engine: DatabaseEngine, endpoint: String, database: String, environment: ConnectionEnvironment, readOnly: Bool, demo: Bool = false) {
        self.id = id; self.name = name; self.engine = engine; self.endpoint = endpoint
        self.database = database; self.environment = environment; self.readOnly = readOnly; self.demo = demo
    }
}

/// Object tree kinds for the navigator.
public enum DatabaseObjectKind: String, Codable, Sendable {
    case database, schema, table, view, collection
}

/// One foreign key of a table: the constrained columns, the referenced
/// object, and the referenced columns in the same ordinal order. Multi-column
/// keys pair `columns[i]` with `referencedColumns[i]`. `referencedObject.id`
/// uses the same adapter-generated handle shape `listObjects` emits, so it
/// can be previewed directly (ROADMAP M1 ⑤).
public struct ForeignKey: Sendable, Equatable {
    public let columns: [String]
    public let referencedObject: DatabaseObject
    public let referencedColumns: [String]
    public init(columns: [String], referencedObject: DatabaseObject, referencedColumns: [String]) {
        self.columns = columns
        self.referencedObject = referencedObject
        self.referencedColumns = referencedColumns
    }
}

/// One column of a table's structured schema ("View Schema"). `dataType` is
/// the engine's display type name (PostgreSQL `format_type`, MySQL
/// `COLUMN_TYPE`, SQLite's declared type — possibly empty).
public struct ColumnSchema: Sendable, Equatable {
    public let name: String
    public let dataType: String
    public let nullable: Bool
    /// The 1-based position within the primary key; 0 when the column is not
    /// part of it (same convention as `InsertableColumn.primaryKeyOrdinal`).
    public let primaryKeyOrdinal: Int
    public init(name: String, dataType: String, nullable: Bool, primaryKeyOrdinal: Int) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.primaryKeyOrdinal = primaryKeyOrdinal
    }

    public var isPrimaryKey: Bool { primaryKeyOrdinal > 0 }
}

/// One index of a table's structured schema. Expression indexes carry only
/// their plain columns (engines that cannot enumerate the expression report
/// the index without them).
public struct IndexSchema: Sendable, Equatable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public init(name: String, columns: [String], isUnique: Bool) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

/// The structured schema of one table: its columns (with nullability and
/// primary-key positions), foreign keys, and indexes. The viewer counterpart
/// of the DDL text `SupportsIntrospection` reconstructs.
public struct TableSchema: Sendable, Equatable {
    public let object: DatabaseObject
    public let columns: [ColumnSchema]
    public let foreignKeys: [ForeignKey]
    public let indexes: [IndexSchema]
    public init(object: DatabaseObject, columns: [ColumnSchema], foreignKeys: [ForeignKey], indexes: [IndexSchema]) {
        self.object = object
        self.columns = columns
        self.foreignKeys = foreignKeys
        self.indexes = indexes
    }
}

/// One foreign-key edge of a whole-database relationship overview: the table
/// holding the constraint plus the foreign key itself (`columns[i]` of
/// `object` references `referencedColumns[i]` of `referencedObject`).
public struct TableRelation: Sendable, Equatable {
    public let object: DatabaseObject
    public let foreignKey: ForeignKey
    public init(object: DatabaseObject, foreignKey: ForeignKey) {
        self.object = object
        self.foreignKey = foreignKey
    }
}

/// A node in the object navigator. `id` is an opaque, adapter-generated handle.
public struct DatabaseObject: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let parentID: String?
    public let name: String
    public let kind: DatabaseObjectKind
    public init(id: String, parentID: String?, name: String, kind: DatabaseObjectKind) {
        self.id = id; self.parentID = parentID; self.name = name; self.kind = kind
    }
}

/// Commands accepted by adapters. SQL-family engines share `.sql`;
/// MongoDB accepts canonical Extended JSON only — never evaluated code.
/// Mongo commands carry the target collection explicitly; the editor text
/// stays pure Extended JSON.
public enum DatabaseCommand: Codable, Sendable, Equatable {
    case sql(String)
    case mongoFind(collection: String, filter: String)
    case mongoAggregate(collection: String, pipeline: String)

    public var text: String {
        switch self {
        case .sql(let text): text
        case .mongoFind(_, let filter): filter
        case .mongoAggregate(_, let pipeline): pipeline
        }
    }
}

/// Display-safe value tree. Precision-sensitive database values (bigint, decimal,
/// non-finite numbers, dates) cross as strings; binary crosses as tagged data.
/// Single over-long values are truncated by adapters with a visible marker.
public indirect enum DisplayValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case binary(Data)
    case array([DisplayValue])
    case object([(key: String, value: DisplayValue)])

    public static func object(_ pairs: [String: DisplayValue]) -> DisplayValue {
        .object(pairs.map { ($0.key, $0.value) })
    }
}

// Equatable is manual because tuple associated values do not synthesize conformance.
extension DisplayValue {
    public static func == (lhs: DisplayValue, rhs: DisplayValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.binary(let a), .binary(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }
}

// Codable for object with ordered keys.
extension DisplayValue {
    private enum CodingKeys: String, CodingKey { case kind, bool, number, string, binary, array, pairs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "null": self = .null
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .bool))
        case "number": self = .number(try c.decode(Double.self, forKey: .number))
        case "string": self = .string(try c.decode(String.self, forKey: .string))
        case "binary": self = .binary(try c.decode(Data.self, forKey: .binary))
        case "array": self = .array(try c.decode([DisplayValue].self, forKey: .array))
        case "object":
            let raw = try c.decode([[String: DisplayValue]].self, forKey: .pairs)
            self = .object(raw.compactMap { entry in
                guard let k = entry["k"], case .string(let key) = k, let v = entry["v"] else { return nil }
                return (key, v)
            })
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown DisplayValue kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try c.encode("null", forKey: .kind)
        case .bool(let v): try c.encode("bool", forKey: .kind); try c.encode(v, forKey: .bool)
        case .number(let v): try c.encode("number", forKey: .kind); try c.encode(v, forKey: .number)
        case .string(let v): try c.encode("string", forKey: .kind); try c.encode(v, forKey: .string)
        case .binary(let v): try c.encode("binary", forKey: .kind); try c.encode(v, forKey: .binary)
        case .array(let v): try c.encode("array", forKey: .kind); try c.encode(v, forKey: .array)
        case .object(let pairs):
            try c.encode("object", forKey: .kind)
            try c.encode(pairs.map { ["k": DisplayValue.string($0.key), "v": $0.value] }, forKey: .pairs)
        }
    }
}

/// Snapshot of one object's storage/row statistics (ROADMAP M2 ⑩). Every
/// field is optional: engines report only what they know — a never-analyzed
/// PostgreSQL table has no row estimate, a SQLite view has no sizes, and
/// MongoDB's uncompressed data size arrives as an extra.
public struct TableStatistics: Sendable, Equatable {
    /// One engine-specific extra fact, shown as-is in the statistics sheet.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let value: String
        public init(name: String, value: String) {
            self.name = name; self.value = value
        }
    }

    /// Row count: exact for SQLite (`COUNT(*)`) and MongoDB (`collStats`),
    /// the planner's estimate for PostgreSQL/MySQL. Nil when unknown.
    public let estimatedRows: Int64?
    /// Total on-disk bytes including indexes where the engine reports them
    /// together (PostgreSQL `pg_total_relation_size`, MongoDB `storageSize`).
    public let totalBytes: Int64?
    /// Bytes used by indexes alone; nil when the engine does not split them out.
    public let indexBytes: Int64?
    public let extras: [Entry]

    public init(
        estimatedRows: Int64? = nil,
        totalBytes: Int64? = nil,
        indexBytes: Int64? = nil,
        extras: [Entry] = []
    ) {
        self.estimatedRows = estimatedRows
        self.totalBytes = totalBytes
        self.indexBytes = indexBytes
        self.extras = extras
    }
}

/// One in-flight server-side operation (ROADMAP M2 ⑨): a row in the activity
/// viewer. Only `id` is guaranteed — engines report what they know, and every
/// other field is optional (an idle backend has no age, an unauthenticated
/// MongoDB deployment reports no user).
public struct ServerActivity: Sendable, Equatable, Identifiable {
    /// The adapter-defined kill handle, passed verbatim to
    /// `SupportsServerActivity.killActivity(id:)`: PostgreSQL backend pid,
    /// MySQL thread id, MongoDB opid (integer as decimal text, or the
    /// sharded "shard:opid" form).
    public let id: String
    public let user: String?
    public let database: String?
    /// Statement/command excerpt, truncated by the adapters to
    /// `statementLimit` characters.
    public let statement: String?
    /// How long the operation has been running; nil for idle/unknown.
    public let age: Duration?
    public let state: String?

    /// The shared excerpt budget ("a few hundred characters") every engine
    /// and the demo adapter truncate statements to.
    public static let statementLimit = 300

    public init(
        id: String,
        user: String? = nil,
        database: String? = nil,
        statement: String? = nil,
        age: Duration? = nil,
        state: String? = nil
    ) {
        self.id = id
        self.user = user
        self.database = database
        self.statement = statement
        self.age = age
        self.state = state
    }

    /// Truncates an over-long statement to `limit` characters plus an
    /// ellipsis marker; shorter statements pass through verbatim.
    public static func truncatedStatement(_ statement: String, limit: Int = statementLimit) -> String {
        guard statement.count > limit else { return statement }
        return String(statement.prefix(limit)) + "…"
    }
}

public struct ColumnMeta: Codable, Sendable, Equatable {
    public let name: String
    public let typeName: String
    public let numeric: Bool
    public init(name: String, typeName: String, numeric: Bool = false) {
        self.name = name; self.typeName = typeName; self.numeric = numeric
    }
}

public struct ResultMeta: Codable, Sendable, Equatable {
    /// Number of returned rows/documents (not the server-side match total).
    public let count: Int
    public let truncated: Bool
    public let elapsedMilliseconds: Int
    public init(count: Int, truncated: Bool, elapsedMilliseconds: Int) {
        self.count = count; self.truncated = truncated; self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum QueryResult: Sendable {
    case rows(columns: [ColumnMeta], rows: [[DisplayValue]], meta: ResultMeta)
    case documents([DisplayValue], meta: ResultMeta)

    public var meta: ResultMeta {
        switch self {
        case .rows(_, _, let meta): meta
        case .documents(_, let meta): meta
        }
    }
}

/// Execution bounds for a single query.
public struct ExecuteOptions: Sendable {
    public let requestID: UUID
    public let timeout: Duration
    public let maxRows: Int
    public let maxBytes: Int
    public init(requestID: UUID = UUID(), timeout: Duration = .seconds(30), maxRows: Int = 500, maxBytes: Int = 5 * 1024 * 1024) {
        self.requestID = requestID; self.timeout = timeout; self.maxRows = maxRows; self.maxBytes = maxBytes
    }
}

/// Errors surfaced to the UI. Messages must already be redacted — no passwords,
/// credential-bearing URIs, or absolute local paths.
public protocol dbbbbError: Error, Sendable {
    var userMessage: String { get }
}
