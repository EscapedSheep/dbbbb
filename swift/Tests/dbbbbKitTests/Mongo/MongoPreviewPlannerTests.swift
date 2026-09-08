import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

struct MongoPreviewPlannerTests {
    private let object = DatabaseObject(id: "mongo:x", parentID: nil, name: "events", kind: .collection)

    private func request(
        offset: Int = 0,
        limit: Int = 100,
        sort: PreviewRequest.Sort? = nil,
        filter: PreviewRequest.Filter? = nil
    ) -> PreviewRequest {
        PreviewRequest(object: object, offset: offset, limit: limit, sort: sort, filter: filter)
    }

    private func pairs(_ request: PreviewRequest) throws -> [(key: String, value: BSONValue)] {
        try MongoPreviewPlanner.findCommandPairs(collection: "events", request: request, timeoutMs: 30_000)
    }

    @Test func defaultRequestIsFirstUnshapedPage() throws {
        let command = try pairs(request())
        #expect(command.map(\.key) == ["find", "filter", "limit", "maxTimeMS"])
        #expect(command[0].value == .string("events"))
        #expect(command[1].value == .document([]))
        #expect(command[2].value == .int64(101))
        #expect(command[3].value == .int64(30_000))
    }

    @Test func pagingAddsSkipAndLimitPlusOne() throws {
        let command = try pairs(request(offset: 200, limit: 50))
        #expect(command.map(\.key) == ["find", "filter", "skip", "limit", "maxTimeMS"])
        #expect(command[2].value == .int64(200))
        #expect(command[3].value == .int64(51))
    }

    @Test func sortIsABsonDocument() throws {
        let asc = try pairs(request(sort: PreviewRequest.Sort(column: "ts", ascending: true)))
        #expect(asc[2].key == "sort")
        #expect(asc[2].value == .document([("ts", .int32(1))]))
        let desc = try pairs(request(sort: PreviewRequest.Sort(column: "ts", ascending: false)))
        #expect(desc[2].value == .document([("ts", .int32(-1))]))
    }

    @Test func filterIsARegexDocument() throws {
        let command = try pairs(request(filter: PreviewRequest.Filter(column: "name", contains: "alice")))
        #expect(command[1].key == "filter")
        #expect(command[1].value == .document([
            ("name", .document([("$regex", .regex(pattern: "alice", options: ""))])),
        ]))
    }

    /// Regex metacharacters are escaped so the filter is a literal substring
    /// match — no operator injection, no user-crafted regex.
    @Test func filterEscapesRegexMetacharacters() throws {
        let cases: [(input: String, pattern: String)] = [
            ("a.b", #"a\.b"#),
            ("x*", #"x\*"#),
            ("(a|b)", #"\(a\|b\)"#),
            ("$gt", #"\$gt"#),
            ("a+b?", #"a\+b\?"#),
            ("[0-9]", #"\[0-9\]"#),
            (#"back\slash"#, #"back\\slash"#),
            ("plain", "plain"),
        ]
        for (input, expected) in cases {
            let command = try pairs(request(filter: PreviewRequest.Filter(column: "f", contains: input)))
            guard case .document(let outer) = command[1].value,
                  case .document(let inner) = outer.first?.value,
                  case .regex(let pattern, let options) = inner.first?.value
            else {
                Issue.record("unexpected filter shape: \(command[1].value)")
                continue
            }
            #expect(pattern == expected, Comment(rawValue: "input: \(input)"))
            #expect(options == "")
        }
    }

    /// Field names that could change the command's meaning fail closed.
    @Test func dangerousFieldNamesFailClosed() {
        #expect(throws: MongoAdapterError.invalidPreviewField) {
            try pairs(request(filter: PreviewRequest.Filter(column: "$where", contains: "x")))
        }
        #expect(throws: MongoAdapterError.invalidPreviewField) {
            try pairs(request(sort: PreviewRequest.Sort(column: "$natural", ascending: true)))
        }
        #expect(throws: MongoAdapterError.invalidPreviewField) {
            try pairs(request(filter: PreviewRequest.Filter(column: "", contains: "x")))
        }
        #expect(throws: MongoAdapterError.invalidPreviewField) {
            try pairs(request(sort: PreviewRequest.Sort(column: "a\0b", ascending: true)))
        }
    }

    @Test func filterSortAndPagingComposeInOrder() throws {
        let command = try pairs(request(
            offset: 100,
            sort: PreviewRequest.Sort(column: "ts", ascending: false),
            filter: PreviewRequest.Filter(column: "name", contains: "v")))
        #expect(command.map(\.key) == ["find", "filter", "sort", "skip", "limit", "maxTimeMS"])
        #expect(command[3].value == .int64(100))
        #expect(command[4].value == .int64(101))
    }

    /// MongoDB has no foreign keys, so equality filters (the FK-jump
    /// predicate, ROADMAP M1 ⑤) fail closed instead of being approximated.
    @Test func equalityFiltersFailClosed() {
        #expect(throws: MongoAdapterError.previewEqualityUnsupported) {
            try pairs(PreviewRequest(
                object: object,
                equalities: [PreviewRequest.Equality(column: "_id", value: .number(1))]))
        }
    }
}
