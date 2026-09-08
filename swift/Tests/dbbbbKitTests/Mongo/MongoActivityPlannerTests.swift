import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

/// The currentOp/killOp command shapes and reply parsing (ROADMAP M2 ⑨):
/// opid type fidelity (integer vs sharded string), missing/NULL fields, and
/// the statement excerpt cap.
struct MongoActivityPlannerTests {
    @Test func currentOpTargetsActiveOpsOnly() {
        let command = MongoActivityPlanner.currentOpCommandPairs()
        #expect(command.map(\.key) == ["currentOp", "active"])
        #expect(command[0].value == .int32(1))
        #expect(command[1].value == .bool(true))
    }

    @Test func killOpKeepsTheReportedOpidType() {
        let integer = MongoActivityPlanner.killOpCommandPairs(opid: .int64(22041))
        #expect(integer.map(\.key) == ["killOp", "op"])
        #expect(integer[1].value == .int64(22041))
        let sharded = MongoActivityPlanner.killOpCommandPairs(opid: .string("shard01:22041"))
        #expect(sharded[1].value == .string("shard01:22041"))
    }

    /// Integer-looking kill handles re-encode as int64 (mongod opids);
    /// sharded "shard:opid" handles cross as strings; empty is invalid.
    @Test func opidCodecRoundTrip() {
        #expect(MongoActivityPlanner.opidText(.int32(7)) == "7")
        #expect(MongoActivityPlanner.opidText(.int64(22041)) == "22041")
        #expect(MongoActivityPlanner.opidText(.string("shard01:22041")) == "shard01:22041")
        #expect(MongoActivityPlanner.opidText(.string("")) == nil)
        #expect(MongoActivityPlanner.opidText(nil) == nil)
        #expect(MongoActivityPlanner.opidText(.bool(true)) == nil)

        #expect(MongoActivityPlanner.opidValue("22041") == .int64(22041))
        #expect(MongoActivityPlanner.opidValue("shard01:22041") == .string("shard01:22041"))
        #expect(MongoActivityPlanner.opidValue("") == nil)
    }

    @Test func parsesFullReply() {
        let activities = MongoActivityPlanner.activities(reply: [
            ("inprog", .array([
                .document([
                    ("opid", .int64(22041)),
                    ("op", .string("query")),
                    ("ns", .string("analytics.events")),
                    ("secs_running", .int64(12)),
                    ("effectiveUsers", .array([.document([("user", .string("etl"))])])),
                    ("command", .document([
                        ("find", .string("events")),
                        ("filter", .document([("type", .string("purchase"))])),
                    ])),
                ]),
            ])),
            ("ok", .double(1)),
        ])
        #expect(activities.count == 1)
        let activity = activities[0]
        #expect(activity.id == "22041")
        #expect(activity.user == "etl")
        #expect(activity.database == "analytics")
        #expect(activity.state == "query")
        #expect(activity.age == .seconds(12))
        #expect(activity.statement == #"{"find":"events","filter":{"type":"purchase"}}"#)
    }

    /// Missing fields degrade to nil; ops without a usable opid cannot be
    /// killed and are dropped; a missing inprog array is an empty list.
    @Test func missingFieldsAndMissingInprog() {
        #expect(MongoActivityPlanner.activities(reply: [("ok", .double(1))]).isEmpty)

        let activities = MongoActivityPlanner.activities(reply: [
            ("inprog", .array([
                // No opid → dropped.
                .document([("op", .string("none"))]),
                .document([
                    ("opid", .int32(5)),
                    ("op", .string("command")),
                    ("ns", .string("")),
                    ("secs_running", .int64(-1)),
                ]),
            ])),
        ])
        #expect(activities.count == 1)
        let activity = activities[0]
        #expect(activity.id == "5")
        #expect(activity.user == nil)
        #expect(activity.database == nil)
        #expect(activity.statement == nil)
        #expect(activity.age == nil)
        #expect(activity.state == "command")
    }

    @Test func shardedOpidSurvivesAsString() {
        let activities = MongoActivityPlanner.activities(reply: [
            ("inprog", .array([
                .document([("opid", .string("shard01:22041"))]),
            ])),
        ])
        #expect(activities.map(\.id) == ["shard01:22041"])
    }

    /// The command document is excerpted to the shared statement limit.
    @Test func commandIsTruncated() {
        let long = String(repeating: "x", count: 500)
        let text = MongoActivityPlanner.commandText(.document([("note", .string(long))]))
        #expect(text?.count == ServerActivity.statementLimit + 1)
        #expect(text?.hasSuffix("…") == true)
        #expect(MongoActivityPlanner.commandText(.string("db.currentOp()")) == "db.currentOp()")
        #expect(MongoActivityPlanner.commandText(.string("")) == nil)
        #expect(MongoActivityPlanner.commandText(nil) == nil)
        #expect(MongoActivityPlanner.commandText(.int32(1)) == nil)
    }

    @Test func secsRunningAcceptsEveryNumericType() {
        #expect(MongoActivityPlanner.seconds(.int32(7)) == .seconds(7))
        #expect(MongoActivityPlanner.seconds(.int64(11)) == .seconds(11))
        #expect(MongoActivityPlanner.seconds(.double(1.5)) == .milliseconds(1_500))
        #expect(MongoActivityPlanner.seconds(.double(.nan)) == nil)
        #expect(MongoActivityPlanner.seconds(nil) == nil)
        #expect(MongoActivityPlanner.seconds(.string("12")) == nil)
    }
}
