import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Sendable clock for the `@Sendable now` parameter: whole-second dates so
/// ISO-8601 persistence round-trips exactly.
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0

    func next() -> Date {
        lock.withLock {
            tick += 1
            return Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(tick))
        }
    }
}

/// Query history/favorites: semantics mirror the Electron reference
/// (`src/renderer/src/lib/query-library.ts`).
final class QueryLibraryStoreTests: XCTestCase {
    private var directory: URL!
    private var ticker: Ticker!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-library-test-\(UUID().uuidString)")
        ticker = Ticker()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent("query-library.json") }

    private func makeStore(maxLibraryBytes: Int = QueryLibraryStore.defaultMaxLibraryBytes) -> QueryLibraryStore {
        let ticker = ticker!
        return QueryLibraryStore(directory: directory, now: { ticker.next() }, maxLibraryBytes: maxLibraryBytes)
    }

    private let connectionA = UUID()
    private let connectionB = UUID()

    // MARK: - Recording

    func testRecordCreatesNewestFirstEntryWithTitle() throws {
        let store = makeStore()
        let entry = try store.record(connectionID: connectionA, engine: .postgresql, text: "select * from  users\nlimit 10;")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(entry.title, "select * from users")
        XCTAssertEqual(entry.connectionID, connectionA)
        XCTAssertFalse(entry.favorite)
        XCTAssertNil(entry.collection)
    }

    func testAdjacentDuplicateRefreshesInsteadOfAppending() throws {
        let store = makeStore()
        let first = try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        let second = try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(second.createdAt > first.createdAt)
    }

    func testDifferentConnectionOrTextAppends() throws {
        let store = makeStore()
        try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        try store.record(connectionID: connectionB, engine: .sqlite, text: "select 1;")
        try store.record(connectionID: connectionA, engine: .sqlite, text: "select 2;")
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.text), ["select 2;", "select 1;", "select 1;"])
    }

    func testMongoEntriesKeepTheirCollection() throws {
        let store = makeStore()
        let entry = try store.record(
            connectionID: connectionA, engine: .mongodb, text: "{ }", collection: "events")
        XCTAssertEqual(entry.collection, "events")
        // Same filter on a different collection is a different query.
        try store.record(connectionID: connectionA, engine: .mongodb, text: "{ }", collection: "users")
        XCTAssertEqual(store.entries.count, 2)
    }

    func testRecordRejectsInvalidText() {
        let store = makeStore()
        XCTAssertThrowsError(try store.record(connectionID: connectionA, engine: .sqlite, text: "   ")) {
            XCTAssertEqual($0 as? QueryLibraryError, .invalidText)
        }
        let oversized = String(repeating: "x", count: QueryLibraryStore.maxTextLength + 1)
        XCTAssertThrowsError(try store.record(connectionID: connectionA, engine: .sqlite, text: oversized)) {
            XCTAssertEqual($0 as? QueryLibraryError, .invalidText)
        }
    }

    /// The 32 KB limit counts UTF-8 bytes, not grapheme clusters: 9 000 emoji
    /// are few characters but 36 000 bytes and must be rejected.
    func testTextLimitCountsUTF8Bytes() throws {
        let store = makeStore()
        let overLimit = String(repeating: "😀", count: QueryLibraryStore.maxTextLength / 4 + 1)
        XCTAssertLessThanOrEqual(overLimit.count, QueryLibraryStore.maxTextLength)
        XCTAssertGreaterThan(overLimit.utf8.count, QueryLibraryStore.maxTextLength)
        XCTAssertThrowsError(try store.record(connectionID: connectionA, engine: .sqlite, text: overLimit)) {
            XCTAssertEqual($0 as? QueryLibraryError, .invalidText)
        }

        let atLimit = String(repeating: "😀", count: QueryLibraryStore.maxTextLength / 4)
        XCTAssertEqual(atLimit.utf8.count, QueryLibraryStore.maxTextLength)
        let entry = try store.record(connectionID: connectionA, engine: .sqlite, text: atLimit)
        XCTAssertEqual(entry.text, atLimit)
    }

    // MARK: - History cap and favorites

    func testHistoryIsCappedAtOneHundred() throws {
        let store = makeStore()
        for index in 1...105 {
            try store.record(connectionID: connectionA, engine: .sqlite, text: "select \(index);")
        }
        XCTAssertEqual(store.entries.count, QueryLibraryStore.maxHistory)
        XCTAssertEqual(store.entries.first?.text, "select 105;")
        XCTAssertEqual(store.entries.last?.text, "select 6;")
    }

    func testFavoritesSurviveTheHistoryCap() throws {
        let store = makeStore()
        let keeper = try store.record(connectionID: connectionA, engine: .sqlite, text: "select keeper;")
        _ = try store.toggleFavorite(id: keeper.id)
        for index in 1...105 {
            try store.record(connectionID: connectionA, engine: .sqlite, text: "select \(index);")
        }
        XCTAssertEqual(store.entries.count, QueryLibraryStore.maxHistory + 1)
        XCTAssertEqual(store.entries.first(where: { $0.id == keeper.id })?.favorite, true)
    }

    func testStorageFullOfFavoritesIsAnExplicitError() throws {
        // Budget derived from the one-entry file size, so the test does not
        // depend on exact JSON byte counts: one entry fits, two do not.
        let seed = makeStore()
        let first = try seed.record(connectionID: connectionA, engine: .sqlite, text: "select seed;")
        let oneEntryBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)

        let store = makeStore(maxLibraryBytes: oneEntryBytes)
        _ = try store.toggleFavorite(id: first.id)
        XCTAssertThrowsError(
            try store.record(connectionID: connectionA, engine: .sqlite, text: "select overflow;")
        ) {
            XCTAssertEqual($0 as? QueryLibraryError, .storageFullOfFavorites)
            XCTAssertFalse(($0 as? QueryLibraryError)?.userMessage.isEmpty ?? true)
        }
        // The failed record must not mutate the in-memory library.
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, first.id)
    }

    // MARK: - Mutations

    func testToggleFavoriteRoundTrips() throws {
        let store = makeStore()
        let entry = try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        XCTAssertEqual(try store.toggleFavorite(id: entry.id)?.favorite, true)
        XCTAssertEqual(try store.toggleFavorite(id: entry.id)?.favorite, false)
        XCTAssertNil(try store.toggleFavorite(id: UUID()))
    }

    func testRemoveAndClearHistory() throws {
        let store = makeStore()
        let keep = try store.record(connectionID: connectionA, engine: .sqlite, text: "select keep;")
        _ = try store.toggleFavorite(id: keep.id)
        let drop = try store.record(connectionID: connectionA, engine: .sqlite, text: "select drop;")

        XCTAssertFalse(store.remove(id: UUID()))
        XCTAssertTrue(store.remove(id: drop.id))
        XCTAssertEqual(store.entries.count, 1)

        _ = try store.record(connectionID: connectionA, engine: .sqlite, text: "select history;")
        store.clearHistory()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, keep.id)
    }

    /// Persistence failures are surfaced through `onPersistError`, not
    /// swallowed: the in-memory mutation stands, the caller sees the error.
    func testRemoveReportsPersistFailure() throws {
        let store = makeStore()
        let entry = try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        try replaceDirectoryWithFile()

        var reported: (any Error)?
        let removed = store.remove(id: entry.id) { reported = $0 }
        XCTAssertTrue(removed)
        XCTAssertNotNil(reported)
        XCTAssertEqual(store.entries.count, 0)
    }

    func testClearHistoryReportsPersistFailure() throws {
        let store = makeStore()
        _ = try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        try replaceDirectoryWithFile()

        var reported: (any Error)?
        store.clearHistory { reported = $0 }
        XCTAssertNotNil(reported)
        XCTAssertEqual(store.entries.count, 0)
    }

    /// After this, writes into the store's directory fail: a regular file
    /// occupies the directory's path.
    private func replaceDirectoryWithFile() throws {
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() throws {
        let store = makeStore()
        let entry = try store.record(connectionID: connectionA, engine: .mysql, text: "select 1;")
        _ = try store.toggleFavorite(id: entry.id)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0], store.entries[0])

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\":1"))
    }

    func testVersionMismatchKeepsFileUntouched() throws {
        let foreign = #"{"version": 2, "entries": []}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try foreign.write(to: fileURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        // The session keeps working in memory but must never rewrite the file.
        try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), foreign)
        XCTAssertTrue(try corruptBackups().isEmpty, "a foreign-version file is never renamed")
    }

    func testCorruptFileIsBackedUpThenRewritable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{ broken".write(to: fileURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        // The corrupt original is quarantined before any rewrite, never lost.
        let backups = try corruptBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "{ broken")

        try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        XCTAssertEqual(makeStore().entries.count, 1)
        XCTAssertEqual(try corruptBackups().count, 1, "the backup survives the rewrite")
    }

    func testMissingVersionKeyIsBackedUpThenRewritable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"entries": []}"#.write(to: fileURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try corruptBackups().count, 1)
        try store.record(connectionID: connectionA, engine: .sqlite, text: "select 1;")
        XCTAssertEqual(makeStore().entries.count, 1)
    }

    private func corruptBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("query-library.json.corrupt-") }
            .map { directory.appendingPathComponent($0) }
    }

    func testLoadDropsInvalidEntriesAndSortsNewestFirst() throws {
        let validOld = QueryEntry(
            connectionID: connectionA, title: "old", engine: .sqlite,
            text: "select old;", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let validNew = QueryEntry(
            connectionID: connectionA, title: "new", engine: .sqlite,
            text: "select new;", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let emptyText = QueryEntry(
            connectionID: connectionA, title: "bad", engine: .sqlite,
            text: "   ", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        struct Manual: Codable { var version: Int; var entries: [QueryEntry] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(Manual(version: 1, entries: [validOld, emptyText, validNew])).write(to: fileURL)

        let store = makeStore()
        XCTAssertEqual(store.entries.map(\.title), ["new", "old"])
    }
}
