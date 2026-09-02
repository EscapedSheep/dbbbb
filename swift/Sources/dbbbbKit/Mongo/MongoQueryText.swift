import Foundation

/// Editor-text classification for MongoDB queries: find filters are Extended
/// JSON documents, aggregation pipelines are Extended JSON arrays. Used to
/// restore the Find/Aggregate mode when a history entry is loaded.
public enum MongoQueryText {
    public static func isPipeline(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
    }
}
