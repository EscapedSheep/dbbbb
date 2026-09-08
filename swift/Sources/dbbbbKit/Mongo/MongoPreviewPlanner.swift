import Foundation
import dbbbbCore

/// Pure planner for paged/sorted/filtered MongoDB previews: the find command
/// as ordered BSON pairs. The grid filter becomes `{field: {$regex: …}}` with
/// every regex metacharacter escaped (literal substring match; user input can
/// neither inject operators nor craft a pathological pattern), the sort a
/// `{field: 1/-1}` document, and paging `skip`/`limit` — `limit` is the page
/// size + 1 so the caller can tell whether a next page exists.
enum MongoPreviewPlanner {
    static func findCommandPairs(
        collection: String,
        request: PreviewRequest,
        timeoutMs: Int64
    ) throws -> [(key: String, value: BSONValue)] {
        var pairs: [(key: String, value: BSONValue)] = [
            ("find", .string(collection)),
        ]
        // Fail closed: MongoDB has no foreign keys, so nothing legitimate
        // produces equality filters here (ROADMAP M1 ⑤).
        guard request.equalities.isEmpty else {
            throw MongoAdapterError.previewEqualityUnsupported
        }
        if let filter = request.filter {
            try validateField(filter.column)
            let regex = PreviewRequest.mongoRegexEscaped(filter.contains)
            pairs.append(("filter", .document([
                (filter.column, .document([("$regex", .regex(pattern: regex, options: ""))])),
            ])))
        } else {
            pairs.append(("filter", .document([])))
        }
        if let sort = request.sort {
            try validateField(sort.column)
            pairs.append(("sort", .document([
                (sort.column, .int32(sort.ascending ? 1 : -1)),
            ])))
        }
        // skip+limit paging walks the collection from the top on every page —
        // large skips are O(offset) server-side. Acceptable for a browsing
        // tool; deep pagination is what the query editor is for.
        if request.normalizedOffset > 0 {
            pairs.append(("skip", .int64(Int64(request.normalizedOffset))))
        }
        pairs.append(("limit", .int64(Int64(request.normalizedLimit) + 1)))
        pairs.append(("maxTimeMS", .int64(timeoutMs)))
        return pairs
    }

    /// Fail closed on field names that could change the command's meaning: a
    /// leading `$` would be an operator position in some contexts, and NUL is
    /// never valid in a BSON key.
    private static func validateField(_ field: String) throws {
        guard !field.isEmpty, !field.hasPrefix("$"), !field.contains("\0") else {
            throw MongoAdapterError.invalidPreviewField
        }
    }
}
