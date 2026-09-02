import Foundation
import Synchronization
import XCTest
@testable import dbbbbCore
@testable import dbbbbKit

/// Driver-level tests over real temp files: batching, progress, cancellation,
/// per-row failure policy, and error redaction (no path may leak).
final class ImportDriverTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-import-test-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        temporaryURLs.append(url)
        return url
    }

    // MARK: - CSV header validation

    func testHeaderValidation() throws {
        XCTAssertEqual(
            try CSVHeaderMapping.validate(header: ["id", "name"], knownColumns: ["id", "name", "extra"]),
            ["id", "name"])
        // Subsets and reordering are fine.
        XCTAssertEqual(
            try CSVHeaderMapping.validate(header: ["name", "id"], knownColumns: ["id", "name"]),
            ["name", "id"])

        XCTAssertThrowsError(try CSVHeaderMapping.validate(header: [], knownColumns: ["id"])) { error in
            guard case .headerInvalid = error as? ImportError else {
                return XCTFail("expected headerInvalid, got \(error)")
            }
        }
        XCTAssertThrowsError(try CSVHeaderMapping.validate(header: ["id", ""], knownColumns: ["id"]))
        XCTAssertThrowsError(try CSVHeaderMapping.validate(header: ["id", "id"], knownColumns: ["id"]))
        XCTAssertThrowsError(try CSVHeaderMapping.validate(header: ["nope"], knownColumns: ["id"])) { error in
            XCTAssertEqual(
                error as? ImportError,
                .headerInvalid(detail: "header column 1 (nope) is not a table column."))
        }
        XCTAssertThrowsError(try CSVHeaderMapping.validate(header: ["__proto__"], knownColumns: ["__proto__"]))
    }

    // MARK: - CSV driver

    func testCSVImportWithHeaderBatchesAndProgress() async throws {
        let contents = "id,name\r\n1,Ada\r\n2,Bob\r\n3,Cid\r\n4,Dot\r\n5,Eli\r\n"
        let url = try makeFile(contents)
        let batches = Mutex<[(columns: [String], rows: [[String]])]>([])
        let progressReports = Mutex<[ImportProgress]>([])
        let summary = try await CSVImportDriver.run(
            fileURL: url,
            hasHeader: true,
            knownColumns: ["id", "name"],
            batchSize: 2,
            isCancelled: { false },
            onProgress: { progress in progressReports.withLock { $0.append(progress) } },
            insertBatch: { columns, rows in
                batches.withLock { $0.append((columns, rows)) }
                return rows.count
            })
        XCTAssertEqual(summary, ImportSummary(processed: 5, inserted: 5, failed: 0))
        let captured = batches.withLock { $0 }
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[0].columns, ["id", "name"])
        XCTAssertEqual(captured[0].rows, [["1", "Ada"], ["2", "Bob"]])
        XCTAssertEqual(captured[2].rows, [["5", "Eli"]])
        let reports = progressReports.withLock { $0 }
        XCTAssertFalse(reports.isEmpty)
        XCTAssertEqual(reports.last?.inserted, 5)
        XCTAssertEqual(reports.last?.bytes, contents.utf8.count)
    }

    func testCSVImportWithoutHeaderUsesTableColumns() async throws {
        let url = try makeFile("1,Ada\n2,Bob")
        let batches = Mutex<[[[String]]]>([])
        let summary = try await CSVImportDriver.run(
            fileURL: url,
            hasHeader: false,
            knownColumns: ["id", "name"],
            isCancelled: { false },
            onProgress: { _ in },
            insertBatch: { _, rows in
                batches.withLock { $0.append(rows) }
                return rows.count
            })
        XCTAssertEqual(summary, ImportSummary(processed: 2, inserted: 2, failed: 0))
        XCTAssertEqual(batches.withLock { $0 }, [[["1", "Ada"], ["2", "Bob"]]])
    }

    func testCSVImportColumnCountMismatchStopsImport() async throws {
        let url = try makeFile("id,name\n1,Ada\n2\n3,Cid\n")
        let insertedRows = Mutex(0)
        let lastProgress = Mutex<ImportProgress?>(nil)
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url,
                hasHeader: true,
                knownColumns: ["id", "name"],
                isCancelled: { false },
                onProgress: { progress in lastProgress.withLock { $0 = progress } },
                insertBatch: { _, rows in
                    insertedRows.withLock { $0 += rows.count }
                    return rows.count
                })
            XCTFail("expected columnCount error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .columnCount(record: 3, expected: 2, actual: 1))
            // Record 3 failed; the import stops before any batch is flushed.
            XCTAssertEqual(insertedRows.withLock { $0 }, 0)
            XCTAssertEqual(lastProgress.withLock { $0 }?.failed, 1)
        }
    }

    func testCSVImportParseFailure() async throws {
        let url = try makeFile("id,name\n1,\"unclosed")
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url, hasHeader: true, knownColumns: ["id", "name"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count })
            XCTFail("expected parseFailure error")
        } catch let error as ImportError {
            guard case .parseFailure(let detail) = error else {
                return XCTFail("expected parseFailure, got \(error)")
            }
            XCTAssertTrue(detail.contains("quoted field was not closed"))
        }
    }

    func testCSVImportHeaderErrors() async throws {
        let url = try makeFile("id,unknown\n1,2\n")
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count })
            XCTFail("expected headerInvalid error")
        } catch let error as ImportError {
            guard case .headerInvalid = error else {
                return XCTFail("expected headerInvalid, got \(error)")
            }
        }
    }

    func testCSVImportInsertFailureAborts() async throws {
        struct Failure: dbbbbError {
            var userMessage: String { "duplicate key value violates unique constraint." }
        }
        let url = try makeFile("id\n1\n2\n")
        let lastProgress = Mutex<ImportProgress?>(nil)
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { progress in lastProgress.withLock { $0 = progress } },
                insertBatch: { _, _ in throw Failure() })
            XCTFail("expected insertFailed error")
        } catch let error as ImportError {
            XCTAssertEqual(
                error,
                .insertFailed(record: 2, detail: "duplicate key value violates unique constraint."))
            XCTAssertEqual(lastProgress.withLock { $0 }?.failed, 2)
        }
    }

    func testCSVImportPartialInsertAborts() async throws {
        let url = try makeFile("id\n1\n2\n3\n")
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count - 1 })
            XCTFail("expected insertFailed error")
        } catch let error as ImportError {
            guard case .insertFailed(let record, let detail) = error else {
                return XCTFail("expected insertFailed, got \(error)")
            }
            XCTAssertEqual(record, 2)
            XCTAssertTrue(detail.contains("partially inserted"))
        }
    }

    func testCSVImportCancellation() async throws {
        let url = try makeFile("id\n1\n2\n3\n4\n")
        let processed = Mutex(0)
        do {
            _ = try await CSVImportDriver.run(
                fileURL: url, hasHeader: true, knownColumns: ["id"],
                batchSize: 1,
                isCancelled: { processed.withLock { $0 } >= 2 },
                onProgress: { _ in },
                insertBatch: { _, rows in
                    processed.withLock { $0 += rows.count }
                    return rows.count
                })
            XCTFail("expected cancellation")
        } catch let error as ImportError {
            XCTAssertEqual(error, .cancelled)
            XCTAssertEqual(error.userMessage, "Import was cancelled.")
        }
    }

    // MARK: - File preflight + redaction

    func testMissingEmptyAndDirectoryFiles() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-import-test-\(UUID().uuidString)")
        do {
            _ = try await CSVImportDriver.run(
                fileURL: missing, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count })
            XCTFail("expected fileUnavailable")
        } catch let error as ImportError {
            XCTAssertEqual(error, .fileUnavailable)
            // The redaction boundary: no path leaks into the message.
            XCTAssertFalse(error.userMessage.contains(missing.path))
            XCTAssertEqual(error.userMessage, "The selected import file is no longer available.")
        }

        let empty = try makeFile("")
        do {
            _ = try await CSVImportDriver.run(
                fileURL: empty, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count })
            XCTFail("expected fileEmpty")
        } catch let error as ImportError {
            XCTAssertEqual(error, .fileEmpty)
        }

        let directory = FileManager.default.temporaryDirectory
        do {
            _ = try await CSVImportDriver.run(
                fileURL: directory, hasHeader: true, knownColumns: ["id"],
                isCancelled: { false }, onProgress: { _ in },
                insertBatch: { _, rows in rows.count })
            XCTFail("expected fileUnavailable for a directory")
        } catch let error as ImportError {
            XCTAssertEqual(error, .fileUnavailable)
        }
    }

    // MARK: - JSONL driver

    func testJSONLImportHappyPath() async throws {
        let url = try makeFile("{\"a\":1}\n{\"a\":2}\n{\"a\":3}")
        let batches = Mutex<[[String]]>([])
        let summary = try await JSONLImportDriver.run(
            fileURL: url,
            batchSize: 2,
            isCancelled: { false },
            onProgress: { _ in },
            parse: { _, content in content },
            insertBatch: { documents in
                batches.withLock { $0.append(documents) }
                return documents.count
            })
        XCTAssertEqual(summary, ImportSummary(processed: 3, inserted: 3, failed: 0))
        XCTAssertEqual(batches.withLock { $0 }, [["{\"a\":1}", "{\"a\":2}"], ["{\"a\":3}"]])
    }

    func testJSONLImportParseFailureCarriesLineNumber() async throws {
        let url = try makeFile("{\"a\":1}\nnot-json\n{\"a\":3}\n")
        let insertedCount = Mutex(0)
        do {
            _ = try await JSONLImportDriver.run(
                fileURL: url,
                batchSize: 10,
                isCancelled: { false },
                onProgress: { _ in },
                parse: { line, content in
                    guard content.hasPrefix("{") else {
                        throw ImportError.documentType(line: line)
                    }
                    return content
                },
                insertBatch: { documents in
                    insertedCount.withLock { $0 += documents.count }
                    return documents.count
                })
            XCTFail("expected documentType error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .documentType(line: 2))
            // all-or-stop: nothing was flushed before the bad line aborted the import.
            XCTAssertEqual(insertedCount.withLock { $0 }, 0)
        }
    }

    func testJSONLImportCancellation() async throws {
        let url = try makeFile("1\n2\n3\n")
        let batches = Mutex(0)
        do {
            _ = try await JSONLImportDriver.run(
                fileURL: url,
                batchSize: 1,
                isCancelled: { batches.withLock { $0 } >= 1 },
                onProgress: { _ in },
                parse: { _, content in content },
                insertBatch: { documents in
                    batches.withLock { $0 += 1 }
                    return documents.count
                })
            XCTFail("expected cancellation")
        } catch let error as ImportError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
