import Foundation
import dbbbbCore

/// CSV header validation, ported from the Electron `validateCsvHeader` with
/// the PostgreSQL adapter's settings (no trimming, unknown or dangerous
/// columns rejected — no interactive remap).
enum CSVHeaderMapping {
    /// JS-era prototype-pollution guards; the Electron runner rejects these
    /// header names outright, and so do we.
    static let dangerousColumns: Set<String> = ["__proto__", "prototype", "constructor"]

    /// Validates a parsed CSV header against the known table columns and
    /// returns the target column names in source order.
    static func validate(header: [String], knownColumns: [String]) throws -> [String] {
        guard !header.isEmpty else {
            throw ImportError.headerInvalid(detail: "the header row is missing.")
        }
        let known = Set(knownColumns)
        var seen: Set<String> = []
        var targets: [String] = []
        for (index, column) in header.enumerated() {
            let position = index + 1
            guard !column.isEmpty else {
                throw ImportError.headerInvalid(detail: "header column \(position) is empty.")
            }
            guard seen.insert(column).inserted else {
                throw ImportError.headerInvalid(
                    detail: "header column \(position) duplicates an earlier column.")
            }
            guard !dangerousColumns.contains(column.lowercased()) else {
                throw ImportError.headerInvalid(
                    detail: "header column \(position) (\(column)) is not importable.")
            }
            guard known.contains(column) else {
                throw ImportError.headerInvalid(
                    detail: "header column \(position) (\(column)) is not a table column.")
            }
            targets.append(column)
        }
        return targets
    }
}

/// Shared file preflight + chunked reading. Paths never reach error messages.
enum ImportFileReader {
    static let maxFileBytes = 1024 * 1024 * 1024
    static let chunkBytes = 64 * 1024

    /// Validates the file (regular, non-empty, within the 1 GB limit) and
    /// opens it for reading. Errors are mapped to scrubbed `ImportError`s.
    static func open(_ url: URL) throws -> (handle: FileHandle, size: Int) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw mapError(error)
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw ImportError.fileUnavailable
        }
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
            throw ImportError.fileEmpty
        }
        guard size <= maxFileBytes else {
            throw ImportError.fileTooLarge
        }
        do {
            return (try FileHandle(forReadingFrom: url), size)
        } catch {
            throw mapError(error)
        }
    }

    /// Maps file-system errors without ever leaking the path (the Electron
    /// `safeImportError` wording).
    static func mapError(_ error: Error) -> ImportError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .fileUnavailable
            case NSFileReadNoPermissionError:
                return .fileUnreadable
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT): return .fileUnavailable
            case Int(EACCES), Int(EPERM): return .fileUnreadable
            default: break
            }
        }
        return .fileUnreadable
    }
}

/// Streaming CSV import driver, ported from the Electron `runCsvImport` with
/// `errorMode: 'all-or-stop'`: header validation, strict column counts, a
/// 1 000 000-row limit, 500-record batches, per-batch progress, and
/// cooperative cancellation. The engine adapter supplies `insertBatch`.
enum CSVImportDriver {
    static let defaultBatchSize = 500
    static let maxRows = 1_000_000

    /// - Parameter knownColumns: the target table's insertable columns. With
    ///   `hasHeader` they validate the CSV header; without it they are the
    ///   explicit column list (Electron's `explicitHeader`).
    /// - Parameter insertBatch: inserts one batch and returns how many rows
    ///   were actually inserted; a partial count aborts the import.
    static func run(
        fileURL: URL,
        hasHeader: Bool,
        knownColumns: [String],
        batchSize: Int = defaultBatchSize,
        isCancelled: @Sendable () -> Bool,
        onProgress: @Sendable (ImportProgress) -> Void,
        insertBatch: @Sendable (_ columns: [String], _ rows: [[String]]) async throws -> Int
    ) async throws -> ImportSummary {
        precondition(batchSize >= 1 && !knownColumns.isEmpty)
        let (handle, fileSize) = try ImportFileReader.open(fileURL)
        defer { try? handle.close() }

        var parser = try CSVParser()
        var decoder = UTF8ChunkDecoder()
        var progress = ImportProgress()
        /// nil until the header record is consumed; the explicit column list
        /// from the start for header-less files.
        var columns: [String]? = hasHeader ? nil : knownColumns
        var batch: [[String]] = []
        var sourceNumber = hasHeader ? 1 : 0

        func flushBatch() async throws {
            guard !batch.isEmpty, let targets = columns else { return }
            if isCancelled() { throw ImportError.cancelled }
            let firstRecord = sourceNumber - batch.count + 1
            let rows = batch
            batch = []
            let inserted: Int
            do {
                inserted = try await insertBatch(targets, rows)
            } catch let error as ImportError {
                throw error
            } catch {
                progress.failed += rows.count
                onProgress(progress)
                if let error = error as? dbbbbError {
                    throw ImportError.insertFailed(record: firstRecord, detail: error.userMessage)
                }
                throw ImportError.insertFailed(record: firstRecord, detail: "a batch could not be inserted.")
            }
            guard inserted >= 0, inserted <= rows.count else {
                throw ImportError.insertFailed(
                    record: firstRecord, detail: "the insert returned an invalid row count.")
            }
            progress.inserted += inserted
            let failed = rows.count - inserted
            progress.failed += failed
            onProgress(progress)
            if failed > 0 {
                throw ImportError.insertFailed(
                    record: firstRecord, detail: "a batch was only partially inserted.")
            }
            if isCancelled() { throw ImportError.cancelled }
        }

        func process(_ record: [String]) async throws {
            guard let expected = columns?.count else {
                columns = try CSVHeaderMapping.validate(header: record, knownColumns: knownColumns)
                return
            }
            sourceNumber += 1
            if isCancelled() { throw ImportError.cancelled }
            if progress.processed >= maxRows {
                throw ImportError.rowLimit(maximum: maxRows)
            }
            progress.processed += 1
            guard record.count == expected else {
                progress.failed += 1
                onProgress(progress)
                throw ImportError.columnCount(
                    record: sourceNumber, expected: expected, actual: record.count)
            }
            batch.append(record)
            if batch.count >= batchSize {
                try await flushBatch()
            }
        }

        while true {
            if isCancelled() { throw ImportError.cancelled }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: ImportFileReader.chunkBytes) ?? Data()
            } catch {
                throw ImportFileReader.mapError(error)
            }
            if chunk.isEmpty { break }
            progress.bytes = min(progress.bytes + chunk.count, fileSize)
            let records: [[String]]
            do {
                records = try parser.append(decoder.decode(chunk))
            } catch let error as DelimitedError {
                throw ImportError.parseFailure(detail: error.userMessage)
            }
            for record in records {
                try await process(record)
            }
        }

        do {
            for record in try parser.append(decoder.finish()) {
                try await process(record)
            }
            if let last = try parser.finish() {
                try await process(last)
            }
        } catch let error as DelimitedError {
            throw ImportError.parseFailure(detail: error.userMessage)
        }

        guard columns != nil else {
            throw ImportError.headerInvalid(detail: "the header row is missing.")
        }
        try await flushBatch()
        onProgress(progress)
        return ImportSummary(
            processed: progress.processed, inserted: progress.inserted, failed: progress.failed)
    }
}

/// Streaming JSON Lines import driver, ported from the Electron
/// `runJsonLinesImport` with `errorMode: 'all-or-stop'`. Each line must parse
/// to one document (the caller's `parse` closure — MongoDB lines go through
/// the canonical EJSON codec); any invalid line aborts the import.
enum JSONLImportDriver {
    static let defaultBatchSize = 500
    static let maxRows = 1_000_000

    static func run<Document>(
        fileURL: URL,
        batchSize: Int = defaultBatchSize,
        isCancelled: @Sendable () -> Bool,
        onProgress: @Sendable (ImportProgress) -> Void,
        parse: @Sendable (_ lineNumber: Int, _ content: String) throws -> Document,
        insertBatch: @Sendable (_ documents: [Document]) async throws -> Int
    ) async throws -> ImportSummary {
        precondition(batchSize >= 1)
        let (handle, fileSize) = try ImportFileReader.open(fileURL)
        defer { try? handle.close() }

        var parser = JSONLinesParser()
        var decoder = UTF8ChunkDecoder()
        var progress = ImportProgress()
        var batch: [Document] = []
        var batchFirstLine = 0

        func flushBatch() async throws {
            guard !batch.isEmpty else { return }
            if isCancelled() { throw ImportError.cancelled }
            let firstLine = batchFirstLine
            let documents = batch
            batch = []
            let inserted: Int
            do {
                inserted = try await insertBatch(documents)
            } catch let error as ImportError {
                throw error
            } catch {
                progress.failed += documents.count
                onProgress(progress)
                if let error = error as? dbbbbError {
                    throw ImportError.insertFailed(record: firstLine, detail: error.userMessage)
                }
                throw ImportError.insertFailed(record: firstLine, detail: "a batch could not be inserted.")
            }
            guard inserted >= 0, inserted <= documents.count else {
                throw ImportError.insertFailed(
                    record: firstLine, detail: "the insert returned an invalid document count.")
            }
            progress.inserted += inserted
            let failed = documents.count - inserted
            progress.failed += failed
            onProgress(progress)
            if failed > 0 {
                throw ImportError.insertFailed(
                    record: firstLine, detail: "a batch was only partially inserted.")
            }
            if isCancelled() { throw ImportError.cancelled }
        }

        func process(_ line: (lineNumber: Int, content: String)) async throws {
            if isCancelled() { throw ImportError.cancelled }
            if progress.processed >= maxRows {
                throw ImportError.rowLimit(maximum: maxRows)
            }
            progress.processed += 1
            let document = try parse(line.lineNumber, line.content)
            if batch.isEmpty { batchFirstLine = line.lineNumber }
            batch.append(document)
            if batch.count >= batchSize {
                try await flushBatch()
            }
        }

        while true {
            if isCancelled() { throw ImportError.cancelled }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: ImportFileReader.chunkBytes) ?? Data()
            } catch {
                throw ImportFileReader.mapError(error)
            }
            if chunk.isEmpty { break }
            progress.bytes = min(progress.bytes + chunk.count, fileSize)
            let lines: [(lineNumber: Int, content: String)]
            do {
                lines = try parser.append(decoder.decode(chunk))
            } catch let error as DelimitedError {
                throw ImportError.parseFailure(detail: error.userMessage)
            }
            for line in lines {
                try await process(line)
            }
        }

        do {
            for line in try parser.append(decoder.finish()) {
                try await process(line)
            }
            if let last = try parser.finish() {
                try await process(last)
            }
        } catch let error as DelimitedError {
            throw ImportError.parseFailure(detail: error.userMessage)
        }

        try await flushBatch()
        onProgress(progress)
        return ImportSummary(
            processed: progress.processed, inserted: progress.inserted, failed: progress.failed)
    }
}
