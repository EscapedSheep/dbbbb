import Foundation
import CryptoKit
import dbbbbCore

/// File management for BullMQ snapshots. Snapshots live in
/// `~/Library/Application Support/dbbbb/bullmq-snapshots/` (directory 0700,
/// the same discipline as the connection manifest) and are named
/// `<slug>-<digest>.sqlite`, where the digest is SHA-256 of
/// `<connectionID>\0<queue>` — stable per connection+queue so a re-sync
/// overwrites the same file, and collision-safe regardless of the queue
/// name's characters. Mirrors the Electron reference's
/// `bullmqSnapshotFileName`.
///
/// Snapshots are session-scoped and never persisted, so cleanup has three
/// triggers, all confined to files matching the managed naming rule (foreign
/// files in the directory are left alone):
/// - startup: sweep leftovers from a previous run;
/// - session removal: delete that session's file;
/// - app exit: delete every managed file.
public struct BullmqSnapshotStore: Sendable {
    public let directory: URL

    public init() {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: applicationSupport
            .appendingPathComponent("dbbbb", isDirectory: true)
            .appendingPathComponent("bullmq-snapshots", isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The final snapshot path for one connection+queue.
    public func snapshotFileURL(connectionID: UUID, queue: String) -> URL {
        directory.appendingPathComponent(Self.fileName(connectionID: connectionID, queue: queue))
    }

    /// The temp path the writer fills; renamed over the final path on success.
    public func temporaryFileURL(for finalURL: URL) -> URL {
        directory.appendingPathComponent(finalURL.lastPathComponent + ".tmp")
    }

    /// `<slug>-<digest>.sqlite`, identical to the Electron reference.
    public static func fileName(connectionID: UUID, queue: String) -> String {
        let digest = SHA256.hash(data: Data("\(connectionID.uuidString)\0\(queue)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let slug = queue
            .replacing(#/[^A-Za-z0-9._-]+/#, with: { _ in "-" })
            .replacing(#/^-+|-+$/#, with: { _ in "" })
        let clipped = String(slug.prefix(48))
        return "\(clipped.isEmpty ? "queue" : clipped)-\(digest).sqlite"
    }

    /// A file is managed iff its name follows the snapshot rule; sweeps never
    /// touch anything else in the directory.
    public static func isManagedFileName(_ name: String) -> Bool {
        name.range(
            of: #"^[A-Za-z0-9._-]{1,48}-[0-9a-f]{16}\.sqlite(\.tmp)?$"#,
            options: .regularExpression) != nil
    }

    /// Creates the directory if needed (0700) and tightens a pre-existing one.
    public func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Deletes every managed snapshot/temp file; other files stay.
    public func sweepManagedFiles() throws {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.isManagedFileName(name) {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Deletes one snapshot file (session removal); a missing file is fine.
    public func deleteSnapshot(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
