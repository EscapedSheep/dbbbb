import Foundation
import dbbbbCore

/// Pure command construction + reply parsing for the MongoDB activity viewer
/// (ROADMAP M2 ⑨): `currentOp` for the list, `killOp` for the kill. Both are
/// admin commands and need admin-ish privileges; a server refusal surfaces
/// through `MongoErrorMapper` as a sanitized error, never a crash.
enum MongoActivityPlanner {
    /// currentOp/killOp live on the admin database, not the browsed one.
    static let adminDatabase = "admin"

    /// `currentOp` filtered to in-flight operations only.
    static func currentOpCommandPairs() -> [(key: String, value: BSONValue)] {
        [("currentOp", .int32(1)), ("active", .bool(true))]
    }

    static func killOpCommandPairs(opid: BSONValue) -> [(key: String, value: BSONValue)] {
        [("killOp", .int32(1)), ("op", opid)]
    }

    /// Activity id ↔ killOp `op` codec. A mongod opid is an integer, a
    /// sharded-cluster opid the "shard:opid" string; killOp expects the same
    /// type currentOp reported, so integer-looking text re-encodes as int64
    /// and everything else crosses as a string.
    static func opidText(_ value: BSONValue?) -> String? {
        switch value {
        case .int32(let value): String(value)
        case .int64(let value): String(value)
        case .string(let text): text.isEmpty ? nil : text
        default: nil
        }
    }

    static func opidValue(_ id: String) -> BSONValue? {
        guard !id.isEmpty else { return nil }
        if let integer = Int64(id) { return .int64(integer) }
        return .string(id)
    }

    /// Maps the `inprog` array. Ops without a usable opid cannot be kill
    /// targets and are dropped; every other missing field degrades to nil.
    static func activities(reply pairs: [(key: String, value: BSONValue)]) -> [ServerActivity] {
        guard case .array(let ops)? = field("inprog", of: pairs) else { return [] }
        var activities: [ServerActivity] = []
        for op in ops {
            guard case .document(let fields) = op,
                  let id = opidText(field("opid", of: fields))
            else { continue }
            activities.append(ServerActivity(
                id: id,
                user: user(of: fields),
                database: database(of: fields),
                statement: commandText(field("command", of: fields)),
                age: seconds(field("secs_running", of: fields)),
                state: string(field("op", of: fields))))
        }
        return activities
    }

    /// The first effective user's name; nil on no-auth deployments.
    static func user(of fields: [(key: String, value: BSONValue)]) -> String? {
        guard case .array(let users)? = field("effectiveUsers", of: fields),
              case .document(let first)? = users.first
        else { return nil }
        return string(field("user", of: first))
    }

    /// The database part of `ns` ("db.collection"); empty namespaces (server
    /// commands) report no database.
    static func database(of fields: [(key: String, value: BSONValue)]) -> String? {
        guard let namespace = string(field("ns", of: fields)), !namespace.isEmpty else { return nil }
        return namespace.split(separator: ".", maxSplits: 1).first.map(String.init)
    }

    /// The operation's command document as a truncated canonical-EJSON
    /// excerpt; string commands truncate the same way.
    static func commandText(_ value: BSONValue?) -> String? {
        switch value {
        case .document(let pairs):
            return ServerActivity.truncatedStatement(EJSONSerializer.serialize(.document(pairs)))
        case .string(let text):
            return text.isEmpty ? nil : ServerActivity.truncatedStatement(text)
        default:
            return nil
        }
    }

    /// `secs_running` arrives as int32/int64/double depending on the server;
    /// negative or non-finite values mean "unknown", never zero.
    static func seconds(_ value: BSONValue?) -> Duration? {
        let seconds: Double
        switch value {
        case .int32(let value): seconds = Double(value)
        case .int64(let value): seconds = Double(value)
        case .double(let value): seconds = value
        default: return nil
        }
        guard seconds.isFinite, seconds >= 0, seconds < 9e15 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    static func string(_ value: BSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    static func field(_ name: String, of pairs: [(key: String, value: BSONValue)]) -> BSONValue? {
        pairs.first(where: { $0.key == name })?.value
    }
}
