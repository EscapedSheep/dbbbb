import Foundation
import Testing
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Snapshot writer (GRDB) and snapshot store (naming, sweeps). The writer
/// tests mirror the reference's `bullmq-snapshot.test.ts` shape: table
/// structure, raw-JSON payload columns, json_extract usability, abort leaves
/// nothing queryable, and a re-sync replaces rather than appends.
struct BullmqSnapshotTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-snapshot-test-\(UUID().uuidString)")
    }

    private func sampleJobs() -> [DisplayValue] {
        [
            .object([
                ("id", .string("1")), ("queue", .string("emails")), ("state", .string("failed")),
                ("name", .string("welcome-email")),
                ("data", .object([("user", .object([("tier", .string("pro"))]))])),
                ("opts", .object([("attempts", .number(3))])),
                ("attemptsMade", .number(2)),
                ("failedReason", .string("SMTP timeout")),
                ("stacktrace", .array([.string("Error: SMTP timeout"), .string("    at send (mail.js:1)")])),
                ("timestamp", .number(1_756_490_000_000)),
                ("processedOn", .number(1_756_490_001_000)),
                ("finishedOn", .number(1_756_490_002_000)),
                ("delay", .number(5_000)),
            ]),
            .object([
                ("id", .string("2")), ("queue", .string("emails")), ("state", .string("waiting")),
                ("name", .string("digest")),
                ("data", .object([("user", .object([("tier", .string("free"))]))])),
                // Sparse job: no opts/attempts/failure/timestamp fields.
            ]),
        ]
    }

    @Test func writesQueryableJobsTableWithIndexes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.sqlite")

        let writer = try BullmqSnapshotWriter(fileURL: file)
        try writer.insertBatch(sampleJobs())
        try writer.commit()

        let database = try DatabaseQueue(path: file.path, configuration: {
            var configuration = GRDB.Configuration()
            configuration.readonly = true
            return configuration
        }())
        try database.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs")
            #expect(total == 2)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(jobs)").map { $0["name"] as String }
            #expect(columns == [
                "id", "queue", "state", "name", "data", "opts",
                "attempts_made", "failed_reason", "stacktrace",
                "timestamp", "processed_on", "finished_on", "delay",
            ])

            let indexes = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
            #expect(indexes == ["idx_jobs_finished_on", "idx_jobs_name", "idx_jobs_state"])

            // Payloads land as raw JSON: json_extract works on them.
            let pro = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM jobs WHERE json_extract(data, '$.user.tier') = 'pro'")
            #expect(pro == 1)

            let failed = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = '1'")
            #expect(failed?["attempts_made"] as Int64? == 2)
            #expect(failed?["failed_reason"] as String? == "SMTP timeout")
            #expect(failed?["stacktrace"] as String? == "Error: SMTP timeout\n    at send (mail.js:1)")
            #expect(failed?["finished_on"] as Int64? == 1_756_490_002_000)
            #expect(failed?["delay"] as Int64? == 5_000)

            // Missing fields stay NULL.
            let waiting = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = '2'")
            #expect(waiting?["opts"] as String? == nil)
            #expect(waiting?["attempts_made"] as Int64? == nil)
            #expect(waiting?["stacktrace"] as String? == nil)
        }
    }

    @Test func resyncReplacesInsteadOfDoubling() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BullmqSnapshotStore(directory: directory)
        let finalURL = store.snapshotFileURL(connectionID: UUID(), queue: "emails")

        // First sync: two jobs.
        let first = try BullmqSnapshotWriter(fileURL: store.temporaryFileURL(for: finalURL))
        try first.insertBatch(sampleJobs())
        try first.commit()
        try FileManager.default.moveItem(at: store.temporaryFileURL(for: finalURL), to: finalURL)

        // Second sync of the same queue: one job, renamed over the first file.
        let second = try BullmqSnapshotWriter(fileURL: store.temporaryFileURL(for: finalURL))
        try second.insertBatch(Array(sampleJobs().prefix(1)))
        try second.commit()
        try FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: store.temporaryFileURL(for: finalURL), to: finalURL)

        let database = try DatabaseQueue(path: finalURL.path)
        let total = try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs") }
        #expect(total == 1)
    }

    @Test func abortRollsBackAndLeavesNothingQueryable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cancelled.sqlite.tmp")

        let writer = try BullmqSnapshotWriter(fileURL: file)
        try writer.insertBatch(sampleJobs())
        writer.abort()
        // The coordinator deletes the temp file on failure.
        try? FileManager.default.removeItem(at: file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Writing after close fails closed.
        #expect(throws: BullmqSnapshotError.writerClosed) {
            try writer.insertBatch(self.sampleJobs())
        }
    }

    @Test func fileNamesAreStableSluggedAndHashed() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let first = BullmqSnapshotStore.fileName(connectionID: id, queue: "emails")
        #expect(first == BullmqSnapshotStore.fileName(connectionID: id, queue: "emails"))
        #expect(first != BullmqSnapshotStore.fileName(connectionID: id, queue: "reports"))
        #expect(first.hasPrefix("emails-"))
        #expect(first.hasSuffix(".sqlite"))
        #expect(BullmqSnapshotStore.isManagedFileName(first))
        #expect(BullmqSnapshotStore.isManagedFileName(first + ".tmp"))

        let weird = BullmqSnapshotStore.fileName(connectionID: id, queue: "ops: nightly/reports ")
        #expect(weird.hasPrefix("ops-nightly-reports-"))
        #expect(BullmqSnapshotStore.isManagedFileName(weird))

        let empty = BullmqSnapshotStore.fileName(connectionID: id, queue: "…")
        #expect(empty.hasPrefix("queue-"))
        // Foreign names are never managed.
        #expect(!BullmqSnapshotStore.isManagedFileName("notes.sqlite"))
        #expect(!BullmqSnapshotStore.isManagedFileName("emails.sqlite"))
    }

    @Test func sweepDeletesManagedFilesAndKeepsForeignOnes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BullmqSnapshotStore(directory: directory)
        try store.prepareDirectory()

        let managed = store.snapshotFileURL(connectionID: UUID(), queue: "emails")
        let staleTemp = store.temporaryFileURL(for: managed)
        let foreign = directory.appendingPathComponent("notes.sqlite")
        try Data("x".utf8).write(to: managed)
        try Data("x".utf8).write(to: staleTemp)
        try Data("x".utf8).write(to: foreign)

        try store.sweepManagedFiles()
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(!FileManager.default.fileExists(atPath: staleTemp.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func directoryPermissionsAreTightened() throws {
        let directory = makeDirectory().appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = BullmqSnapshotStore(directory: directory)
        try store.prepareDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }
}
