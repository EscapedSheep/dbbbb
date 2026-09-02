import Foundation
import dbbbbCore

/// Pure planner for MongoDB JSONL imports: one JSONL line → one BSON document
/// through the canonical EJSON codec (plain JSON is a subset, so plain JSON
/// lines parse unchanged), and the ordered `insert` command for a batch.
enum MongoImportPlanner {
    /// Parses one JSONL line into ordered BSON document pairs. Non-document
    /// lines are document-type failures (the Electron runner's
    /// `DOCUMENT_TYPE`); syntax, unsafe-key, and unsupported-tag errors are
    /// parse failures with the line number attached.
    static func document(line: Int, content: String) throws -> [(key: String, value: BSONValue)] {
        let bson: BSONValue
        do {
            bson = try EJSON.parseDocument(content, label: "JSONL line \(line)")
        } catch let error as EJSONError {
            if case .expectedDocument = error {
                throw ImportError.documentType(line: line)
            }
            if case .invalidJSON = error {
                throw ImportError.parseFailure(detail: "Invalid JSON on JSONL line \(line).")
            }
            throw ImportError.parseFailure(
                detail: "JSONL line \(line) could not be parsed: \(error.userMessage)")
        }
        guard case .document(let pairs) = bson else {
            throw ImportError.documentType(line: line)
        }
        return pairs
    }

    /// One ordered `insert` command for a batch: the server stops at the
    /// first failing document, and `n` in the reply is the inserted count.
    static func insertCommand(
        collection: String,
        documents: [[(key: String, value: BSONValue)]],
        maxTimeMS: Int64
    ) -> [(key: String, value: BSONValue)] {
        [
            ("insert", .string(collection)),
            ("documents", .array(documents.map { .document($0) })),
            ("ordered", .bool(true)),
            ("maxTimeMS", .int64(maxTimeMS)),
        ]
    }
}
