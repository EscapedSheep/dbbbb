import Foundation
import dbbbbCore

/// Builds the editor statement for "run this object's SELECT" (double-click
/// in the object navigator). Identifiers are quoted with the exact rule each
/// adapter's preview path uses — never interpolated raw — and the schema /
/// database qualification is recovered from the opaque object id the adapter
/// issued. Handles from other sources (demo fixtures) fall back to quoting
/// the bare object name, which always stays a single safe identifier.
public enum SelectStatementBuilder {
    public static func selectLimit100(engine: DatabaseEngine, object: DatabaseObject) throws -> String {
        switch engine {
        case .postgresql:
            // Mirrors PostgresAdapter.previewObject: "schema"."name".
            if let ref = PostgresObjectIDCodec.decode(object.id), let name = ref.name {
                let qualified = try "\(PostgresChangePlanner.quoteIdentifier(ref.schema))"
                    + ".\(PostgresChangePlanner.quoteIdentifier(name))"
                return "select * from \(qualified) limit 100;"
            }
            return try "select * from \(PostgresChangePlanner.quoteIdentifier(object.name)) limit 100;"
        case .mysql:
            // Mirrors MySQLAdapter.previewObject: `database`.`name`.
            if let ref = MySQLObjectRef(id: object.id), let name = ref.name {
                let qualified = MySQLAdapter.quoteIdentifier(ref.database)
                    + "." + MySQLAdapter.quoteIdentifier(name)
                return "select * from \(qualified) limit 100;"
            }
            return "select * from \(MySQLAdapter.quoteIdentifier(object.name)) limit 100;"
        case .sqlite:
            return "select * from \(SQLiteAdapter.quoteIdentifier(object.name)) limit 100;"
        case .mongodb, .bullmq:
            // No SELECT for document/queue engines; SessionStore runs the
            // engine's own template.
            throw AdapterError.engineMismatch
        }
    }
}
