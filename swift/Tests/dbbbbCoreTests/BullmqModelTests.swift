import Foundation
import Testing
import dbbbbCore

/// BullMQ core contracts: engine/input/command Codable round trips and the
/// job-query JSON wire shape (compatible with the Electron reference).
struct BullmqModelTests {
    @Test func engineCatalogIncludesBullMQ() {
        #expect(DatabaseEngine.bullmq.displayName == "BullMQ")
        #expect(!DatabaseEngine.bullmq.isSQLFamily)
        #expect(DatabaseEngine.allCases.contains(.bullmq))
    }

    @Test func bullmqConnectionInputRoundTripsThroughCodable() throws {
        let input = ConnectionInput.bullmq(.init(
            name: "Queues", host: "redis.internal", port: 6380,
            password: "s3cret", database: 3, tls: true, prefix: "jobs",
            environment: .staging, readOnly: true))
        let decoded = try JSONDecoder().decode(ConnectionInput.self, from: JSONEncoder().encode(input))
        guard case .bullmq(let bullmq) = decoded else {
            Issue.record("expected a bullmq input")
            return
        }
        #expect(bullmq.host == "redis.internal")
        #expect(bullmq.port == 6380)
        #expect(bullmq.password == "s3cret")
        #expect(bullmq.database == 3)
        #expect(bullmq.tls)
        #expect(bullmq.prefix == "jobs")
        #expect(bullmq.environment == .staging)
        #expect(bullmq.readOnly)
        #expect(input.engine == .bullmq)
        #expect(input.endpoint == "redis.internal:6380")
        #expect(input.database == "3")
    }

    @Test func bullmqJobsCommandCarriesTheQueryText() throws {
        let command = DatabaseCommand.bullmqJobs(#"{"queue":"emails","state":"failed"}"#)
        #expect(command.text == #"{"queue":"emails","state":"failed"}"#)
        let decoded = try JSONDecoder().decode(DatabaseCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded == command)
    }

    @Test func jobStateIndexKeysAndZsetMembership() {
        #expect(BullmqJobState.waiting.indexKey == "wait")
        #expect(BullmqJobState.waitingChildren.indexKey == "waiting-children")
        #expect(BullmqJobState.allCases.count == 8)
        #expect(BullmqJobState.allCases.map(\.rawValue) == [
            "failed", "completed", "active", "waiting",
            "delayed", "prioritized", "paused", "waiting-children",
        ])
        #expect(Set(BullmqJobState.allCases.filter(\.isZset)) == [
            .failed, .completed, .delayed, .prioritized, .waitingChildren,
        ])
    }

    @Test func jobQueryDecodesFromPlainJSON() throws {
        let json = #"{"queue":"emails","state":"failed","from":150,"to":300,"name":"welcome-*","where":{"user.id":2},"limit":50,"scanBudget":1000,"cursor":4,"includeLogs":true}"#
        let query = try JSONDecoder().decode(BullmqJobQuery.self, from: Data(json.utf8))
        #expect(query.queue == "emails")
        #expect(query.state == .failed)
        #expect(query.from == 150)
        #expect(query.to == 300)
        #expect(query.name == "welcome-*")
        #expect(query.whereClauses == ["user.id": .number(2)])
        #expect(query.limit == 50)
        #expect(query.scanBudget == 1000)
        #expect(query.cursor == 4)
        #expect(query.includeLogs == true)
    }

    @Test func jobQueryEncodesToPlainJSONWithTheWhereKey() throws {
        let query = BullmqJobQuery(
            queue: "emails", state: .delayed,
            whereClauses: ["user.tier": .string("pro")], limit: 100)
        let encoded = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
        #expect(encoded.contains(#""state":"delayed""#))
        #expect(encoded.contains(#""where":{"user.tier":"pro"}"#))
        let decoded = try JSONDecoder().decode(BullmqJobQuery.self, from: Data(encoded.utf8))
        #expect(decoded == query)
    }

    @Test func plainJSONConvertsToDisplayValuePreservingScalars() {
        let json: PlainJSON = .object([
            "n": .null, "b": .bool(true), "i": .number(4), "s": .string("x"),
            "a": .array([.number(1)]),
        ])
        guard case .object(let pairs) = json.displayValue else {
            Issue.record("expected an object")
            return
        }
        #expect(Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) }) == [
            "n": .null, "b": .bool(true), "i": .number(4), "s": .string("x"),
            "a": .array([.number(1)]),
        ])
    }

    @Test func resultMetaCarriesOptionalScanFields() throws {
        let bare = ResultMeta(count: 3, truncated: false, elapsedMilliseconds: 5)
        #expect(bare.scanned == nil && bare.total == nil && bare.nextCursor == nil)
        // Older persisted metadata without the new keys still decodes.
        let legacy = #"{"count":3,"truncated":false,"elapsedMilliseconds":5}"#
        let decoded = try JSONDecoder().decode(ResultMeta.self, from: Data(legacy.utf8))
        #expect(decoded == bare)

        let scanned = ResultMeta(count: 2, truncated: true, elapsedMilliseconds: 7, scanned: 2, total: 5, nextCursor: 2)
        #expect(scanned.scanned == 2 && scanned.total == 5 && scanned.nextCursor == 2)
    }

    @Test func databaseObjectDetailStaysOptional() throws {
        let node = DatabaseObject(id: "q:failed", parentID: "q", name: "failed", kind: .table, detail: "3 jobs")
        #expect(node.detail == "3 jobs")
        let plain = DatabaseObject(id: "t", parentID: nil, name: "t", kind: .table)
        #expect(plain.detail == nil)
        let legacy = #"{"id":"t","name":"t","kind":"table"}"#
        let decoded = try JSONDecoder().decode(DatabaseObject.self, from: Data(legacy.utf8))
        #expect(decoded.detail == nil)
    }
}
