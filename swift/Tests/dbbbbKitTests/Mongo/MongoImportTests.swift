import Foundation
import Testing
@testable import dbbbbKit

/// Offline tests for the MongoDB JSONL import planner (Swift Testing, like
/// the rest of the Mongo suite).
struct MongoImportTests {
    @Test
    func plainJSONDocumentParses() throws {
        let pairs = try MongoImportPlanner.document(
            line: 1, content: #"{"name": "Ada", "n": 3, "ok": true, "note": null}"#)
        #expect(pairs.map(\.key) == ["name", "n", "ok", "note"])
        #expect(pairs[0].value == .string("Ada"))
        #expect(pairs[1].value == .int32(3))
        #expect(pairs[2].value == .bool(true))
        #expect(pairs[3].value == .null)
    }

    @Test
    func ejsonTagsParseThroughTheCanonicalCodec() throws {
        let pairs = try MongoImportPlanner.document(
            line: 1,
            content: #"{"_id": {"$oid": "0123456789abcdef01234567"}, "big": {"$numberLong": "9007199254740993"}, "when": {"$date": "2024-01-01T00:00:00Z"}}"#)
        #expect(pairs.count == 3)
        #expect(pairs[0].value == .objectID(Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67])))
        #expect(pairs[1].value == .int64(9_007_199_254_740_993))
        #expect(pairs[2].value == .date(milliseconds: 1_704_067_200_000))
    }

    @Test
    func nonDocumentLinesAreDocumentTypeErrors() {
        for content in ["[1, 2]", "\"text\"", "42", "null"] {
            do {
                _ = try MongoImportPlanner.document(line: 7, content: content)
                Issue.record("expected documentType error for \(content)")
            } catch let error as ImportError {
                #expect(error == .documentType(line: 7))
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test
    func invalidJSONIsAParseFailureWithTheLineNumber() {
        do {
            _ = try MongoImportPlanner.document(line: 3, content: "{unclosed")
            Issue.record("expected parseFailure")
        } catch let error as ImportError {
            #expect(error == .parseFailure(detail: "Invalid JSON on JSONL line 3."))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func dangerousKeysAndUnsupportedTagsAreParseFailures() {
        do {
            _ = try MongoImportPlanner.document(line: 1, content: #"{"__proto__": {"x": 1}}"#)
            Issue.record("expected parseFailure")
        } catch let error as ImportError {
            guard case .parseFailure = error else {
                Issue.record("expected parseFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        do {
            _ = try MongoImportPlanner.document(line: 1, content: #"{"f": {"$code": "evil()"}}"#)
            Issue.record("expected parseFailure")
        } catch let error as ImportError {
            guard case .parseFailure = error else {
                Issue.record("expected parseFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func insertCommandIsOrderedAndCapped() {
        let command = MongoImportPlanner.insertCommand(
            collection: "people",
            documents: [[("a", .int32(1))], [("a", .int32(2))]],
            maxTimeMS: 30_000)
        #expect(command.count == 4)
        #expect(command[0].key == "insert")
        #expect(command[0].value == .string("people"))
        #expect(command[1].key == "documents")
        #expect(command[1].value == .array([.document([("a", .int32(1))]), .document([("a", .int32(2))])]))
        #expect(command[2].value == .bool(true))
        #expect(command[3].value == .int64(30_000))
    }
}
