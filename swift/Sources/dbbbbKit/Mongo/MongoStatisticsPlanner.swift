import Foundation
import dbbbbCore

/// Pure planner for MongoDB collection statistics (ROADMAP M2 ⑩): the
/// `collStats` command and its reply parsing. Missing or non-numeric fields
/// map to nil — restricted deployments may omit sizes.
enum MongoStatisticsPlanner {
    static func collStatsCommandPairs(collection: String) -> [(key: String, value: BSONValue)] {
        [("collStats", .string(collection))]
    }

    /// Maps `count` → rows and `storageSize`/`totalIndexSize` → byte sizes;
    /// the uncompressed `size` rides along as an extra.
    static func statistics(reply pairs: [(key: String, value: BSONValue)]) -> TableStatistics {
        func field(_ name: String) -> BSONValue? {
            pairs.first(where: { $0.key == name })?.value
        }
        var extras: [TableStatistics.Entry] = []
        if let dataBytes = int64(field("size")) {
            extras.append(TableStatistics.Entry(name: "Data size (uncompressed)", value: "\(dataBytes) bytes"))
        }
        return TableStatistics(
            estimatedRows: int64(field("count")),
            totalBytes: int64(field("storageSize")),
            indexBytes: int64(field("totalIndexSize")),
            extras: extras)
    }

    /// collStats reports numbers as int32/int64/double depending on the
    /// server version; negative or non-finite values are treated as unknown.
    static func int64(_ value: BSONValue?) -> Int64? {
        switch value {
        case .int32(let value):
            value >= 0 ? Int64(value) : nil
        case .int64(let value):
            value >= 0 ? value : nil
        case .double(let value) where value.isFinite && value >= 0 && value <= Double(Int64.max):
            Int64(value)
        default:
            nil
        }
    }
}
