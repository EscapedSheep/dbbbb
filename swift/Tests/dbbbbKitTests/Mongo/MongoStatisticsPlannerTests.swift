import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

/// The collStats command shape and reply parsing (ROADMAP M2 ⑩), including
/// the numeric-type spread across server versions and missing stats.
struct MongoStatisticsPlannerTests {
    @Test func collStatsCommandTargetsTheCollection() {
        let command = MongoStatisticsPlanner.collStatsCommandPairs(collection: "events")
        #expect(command.map(\.key) == ["collStats"])
        #expect(command[0].value == .string("events"))
    }

    @Test func parsesAFullReply() {
        let stats = MongoStatisticsPlanner.statistics(reply: [
            ("ns", .string("analytics.events")),
            ("size", .int64(2_048)),
            ("count", .int64(42)),
            ("storageSize", .int64(4_096)),
            ("totalIndexSize", .int64(1_024)),
            ("ok", .double(1)),
        ])
        #expect(stats.estimatedRows == 42)
        #expect(stats.totalBytes == 4_096)
        #expect(stats.indexBytes == 1_024)
        #expect(stats.extras == [
            TableStatistics.Entry(name: "Data size (uncompressed)", value: "2048 bytes"),
        ])
    }

    @Test func acceptsInt32AndDoubleNumbers() {
        #expect(MongoStatisticsPlanner.int64(.int32(7)) == 7)
        #expect(MongoStatisticsPlanner.int64(.double(9)) == 9)
        #expect(MongoStatisticsPlanner.int64(.int64(11)) == 11)
    }

    /// Missing/NULL/negative/non-finite fields degrade to nil, never to
    /// misleading zeros.
    @Test func missingAndInvalidStatsAreNil() {
        let stats = MongoStatisticsPlanner.statistics(reply: [
            ("count", .null),
            ("storageSize", .double(.nan)),
            ("totalIndexSize", .int64(-1)),
        ])
        #expect(stats.estimatedRows == nil)
        #expect(stats.totalBytes == nil)
        #expect(stats.indexBytes == nil)
        #expect(stats.extras.isEmpty)
        #expect(MongoStatisticsPlanner.int64(nil) == nil)
        #expect(MongoStatisticsPlanner.int64(.string("42")) == nil)
    }
}
