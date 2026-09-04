import Foundation
import dbbbbCore

/// Errors from the query library. Messages are pre-redacted: query text and
/// connection details are never included.
public enum QueryLibraryError: dbbbbError, Equatable {
    /// The Electron reference surfaces this as an explicit user error; entries
    /// must never be dropped silently to make room.
    case storageFullOfFavorites
    case invalidText

    public var userMessage: String {
        switch self {
        case .storageFullOfFavorites:
            "Query library storage is full of favorites. Remove one before adding more."
        case .invalidText:
            "The query text is empty or exceeds the 32 KB library limit."
        }
    }
}

/// One saved query. `connectionID` is an opaque reference only; connection
/// details and credentials are never stored here.
public struct QueryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let connectionID: UUID
    public let title: String
    public let engine: DatabaseEngine
    public let text: String
    /// MongoDB target collection; nil for SQL-family engines.
    public let collection: String?
    public let createdAt: Date
    public var favorite: Bool

    public init(id: UUID = UUID(), connectionID: UUID, title: String, engine: DatabaseEngine,
                text: String, collection: String? = nil, createdAt: Date, favorite: Bool = false) {
        self.id = id; self.connectionID = connectionID; self.title = title
        self.engine = engine; self.text = text; self.collection = collection
        self.createdAt = createdAt; self.favorite = favorite
    }
}

/// Query history + favorites, persisted as JSON at
/// `~/Library/Application Support/dbbbb/query-library.json`. Semantics mirror
/// the Electron reference (`src/renderer/src/lib/query-library.ts`):
/// - newest first; recording the same query twice in a row refreshes the
///   newest entry instead of appending;
/// - at most 100 non-favorite entries (oldest dropped), favorites never
///   dropped by the history cap;
/// - a 4 MB storage budget — when everything left is a favorite, mutations
///   throw `storageFullOfFavorites` instead of dropping silently;
/// - a file from an unknown schema version is left untouched: the session
///   keeps working in memory and never overwrites the user's file.
public final class QueryLibraryStore: @unchecked Sendable {
    public static let fileVersion = 1
    public static let maxHistory = 100
    public static let maxTextLength = 32_768
    static let defaultMaxLibraryBytes = 4 * 1024 * 1024
    private static let maxTitleLength = 200

    private struct LibraryFile: Codable {
        var version: Int
        var entries: [QueryEntry]
    }

    private let fileURL: URL
    private let maxLibraryBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Newest first. Value type copies mean callers can never mutate the store.
    public var entries: [QueryEntry] { lock.withLock { storedEntries } }
    /// Backing storage for `entries`; accessed only while holding `lock`.
    private var storedEntries: [QueryEntry]
    /// False when the on-disk file uses a schema we do not understand —
    /// mutations then run in memory only so the user's file is never clobbered.
    private var writeEnabled: Bool

    public convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dbbbb", isDirectory: true)
        self.init(directory: directory)
    }

    public convenience init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(directory: directory, now: now, maxLibraryBytes: Self.defaultMaxLibraryBytes)
    }

    /// Internal so tests can shrink the storage budget.
    init(directory: URL, now: @escaping @Sendable () -> Date, maxLibraryBytes: Int) {
        fileURL = directory.appendingPathComponent("query-library.json")
        self.now = now
        self.maxLibraryBytes = maxLibraryBytes
        let loaded = Self.loadFile(from: fileURL)
        storedEntries = loaded.entries
        writeEnabled = loaded.writeEnabled
    }

    /// Records an executed query (the Electron reference records successful
    /// executions only, never previews). Re-running the exact same query
    /// back-to-back refreshes the newest entry rather than appending a dupe.
    @discardableResult
    public func record(connectionID: UUID, engine: DatabaseEngine, text: String, collection: String? = nil) throws -> QueryEntry {
        // The 32 KB limit is measured in UTF-8 bytes, not grapheme clusters.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxTextLength else {
            throw QueryLibraryError.invalidText
        }
        return try lock.withLock {
            let createdAt = now()
            let title = Self.title(for: text, engine: engine, collection: collection)
            if let first = storedEntries.first, first.connectionID == connectionID,
               first.engine == engine, first.text == text, first.collection == collection {
                let refreshed = QueryEntry(
                    id: first.id, connectionID: first.connectionID, title: title,
                    engine: first.engine, text: first.text, collection: first.collection,
                    createdAt: createdAt, favorite: first.favorite)
                var next = storedEntries
                next[0] = refreshed
                try persistLocked(next, requiredID: refreshed.id)
                return refreshed
            }
            let entry = QueryEntry(
                connectionID: connectionID, title: title, engine: engine,
                text: text, collection: collection, createdAt: createdAt)
            try persistLocked([entry] + storedEntries, requiredID: entry.id)
            return entry
        }
    }

    @discardableResult
    public func toggleFavorite(id: UUID) throws -> QueryEntry? {
        try lock.withLock {
            guard let index = storedEntries.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = storedEntries[index]
            updated.favorite.toggle()
            var next = storedEntries
            next[index] = updated
            try persistLocked(next, requiredID: updated.id)
            return updated
        }
    }

    /// `onPersistError` receives any failure to write the file (the in-memory
    /// removal still stands), so persistence errors are reported explicitly
    /// instead of being swallowed; the default keeps source compatibility for
    /// callers that predate the error channel.
    @discardableResult
    public func remove(id: UUID, onPersistError: (any Error) -> Void = { _ in }) -> Bool {
        let (removed, persistError): (Bool, (any Error)?) = lock.withLock {
            let next = storedEntries.filter { $0.id != id }
            guard next.count != storedEntries.count else { return (false, nil) }
            do {
                try persistLocked(next)
                return (true, nil)
            } catch {
                return (true, error)
            }
        }
        if let persistError { onPersistError(persistError) }
        return removed
    }

    /// Drops all non-favorite entries. See `remove(id:onPersistError:)` for
    /// the error-reporting contract.
    public func clearHistory(onPersistError: (any Error) -> Void = { _ in }) {
        let persistError: (any Error)? = lock.withLock {
            do {
                try persistLocked(storedEntries.filter(\.favorite))
                return nil
            } catch {
                return error
            }
        }
        if let persistError { onPersistError(persistError) }
    }

    // MARK: Private

    private static func title(for text: String, engine: DatabaseEngine, collection: String?) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") } ?? ""
        let base: String
        if !firstLine.isEmpty {
            base = firstLine
        } else if engine == .mongodb, let collection {
            base = "\(collection) find"
        } else {
            base = engine == .postgresql ? "PostgreSQL query" : "SQL query"
        }
        guard base.count > maxTitleLength else { return base }
        return String(base.prefix(maxTitleLength - 1)) + "…"
    }

    /// Favorites plus the newest `maxHistory` non-favorites.
    private static func limitHistory(_ entries: [QueryEntry]) -> [QueryEntry] {
        var historyCount = 0
        return entries.filter { entry in
            if entry.favorite { return true }
            historyCount += 1
            return historyCount <= maxHistory
        }
    }

    /// Assigns `entries` and persists. Fits the storage budget by dropping the
    /// oldest non-favorites; if nothing droppable remains (or the required
    /// entry would vanish), throws and leaves `entries` untouched.
    private func persistLocked(_ next: [QueryEntry], requiredID: UUID? = nil) throws {
        var fitted = Self.limitHistory(next)
        var data = try Self.encode(fitted)
        while data.count > maxLibraryBytes {
            guard let index = fitted.lastIndex(where: { !$0.favorite }) else {
                throw QueryLibraryError.storageFullOfFavorites
            }
            fitted.remove(at: index)
            data = try Self.encode(fitted)
        }
        if let requiredID, !fitted.contains(where: { $0.id == requiredID }) {
            throw QueryLibraryError.storageFullOfFavorites
        }
        storedEntries = fitted
        guard writeEnabled else { return }
        try AtomicFileWriter.write(data, to: fileURL, securingDirectory: true)
    }

    private static func encode(_ entries: [QueryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(LibraryFile(version: fileVersion, entries: entries))
    }

    private static func loadFile(from fileURL: URL) -> (entries: [QueryEntry], writeEnabled: Bool) {
        struct VersionProbe: Codable { var version: Int? }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return ([], true)
        }
        guard data.count <= defaultMaxLibraryBytes else {
            // Over-limit data belongs to a schema we do not understand; keep it.
            return ([], false)
        }
        // The version is checked before any entry decoding: a file from a
        // schema we do not understand is never overwritten, no matter what
        // its entries look like.
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           let version = probe.version, version != fileVersion {
            return ([], false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(LibraryFile.self, from: data) else {
            // Corrupt file (undecodable or missing version): quarantine it to
            // a `.corrupt-<timestamp>` backup first, then start empty and allow
            // rewriting. If the backup fails, never clobber the original.
            return ([], CorruptFileBackup.backup(fileURL))
        }
        var seen = Set<UUID>()
        let sanitized = file.entries
            .filter { entry in
                !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && entry.text.utf8.count <= maxTextLength
                    && !entry.title.isEmpty && entry.title.count <= maxTitleLength
                    && seen.insert(entry.id).inserted
            }
            .sorted { $0.createdAt > $1.createdAt }
        return (limitHistory(sanitized), true)
    }
}
