import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

struct MongoAdapterGuardTests {
    // MARK: Connection validation (fail-closed, no network needed)

    @Test func srvWithoutTLSRejected() async {
        let input = ConnectionInput.MongoInput(
            name: "atlas", uri: "mongodb+srv://cluster0.example.mongodb.net/app", database: "app", tls: false
        )
        do {
            _ = try await MongoAdapter(input: input)
            Issue.record("SRV URI with tls=false must be rejected")
        } catch let error as MongoAdapterError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(message.contains("require TLS"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func badSchemeRejected() {
        let input = ConnectionInput.MongoInput(name: "x", uri: "http://example.com", database: "db", tls: true)
        #expect { try MongoAdapter.effectiveURI(input: input) } throws: { _ in true }
    }

    @Test func emptyURIRejected() {
        let input = ConnectionInput.MongoInput(name: "x", uri: "  ", database: "db", tls: true)
        #expect { try MongoAdapter.effectiveURI(input: input) } throws: { _ in true }
    }

    // MARK: URI normalization

    @Test func effectiveURIRewritesTLSParam() throws {
        let off = ConnectionInput.MongoInput(
            name: "x", uri: "mongodb://u:p@h:27017/db?tls=true&replicaSet=rs0", database: "db", tls: false
        )
        let uri = try MongoAdapter.effectiveURI(input: off)
        #expect(uri.hasPrefix("mongodb://u:p@h:27017/db?"))
        #expect(uri.contains("replicaSet=rs0"))
        #expect(uri.contains("tls=false"))
        #expect(!uri.contains("tls=true"))
        #expect(uri.contains("appName=dbbbb"))

        let on = ConnectionInput.MongoInput(name: "x", uri: "mongodb://h/db", database: "db", tls: true)
        #expect(try MongoAdapter.effectiveURI(input: on).contains("tls=true"))

        // ssl= is an alias and must also be rewritten by the toggle.
        let alias = ConnectionInput.MongoInput(name: "x", uri: "mongodb://h/db?ssl=true", database: "db", tls: false)
        let rewritten = try MongoAdapter.effectiveURI(input: alias)
        #expect(!rewritten.contains("ssl=true"))
        #expect(rewritten.contains("tls=false"))
    }

    @Test func srvWithTLSPassesValidation() throws {
        let input = ConnectionInput.MongoInput(
            name: "x", uri: "mongodb+srv://cluster0.example.net/db", database: "db", tls: true
        )
        _ = try MongoAdapter.effectiveURI(input: input)
    }

    // MARK: Object identifiers

    @Test func collectionIDRoundTrip() throws {
        let id = MongoAdapter.collectionID(for: "events", database: "analytics")
        #expect(id.hasPrefix("mongo:collection:"))
        #expect(try MongoAdapter.collectionName(from: id, database: "analytics") == "events")
    }

    @Test func collectionIDRejectsForeignDatabase() {
        let id = MongoAdapter.collectionID(for: "events", database: "analytics")
        #expect { try MongoAdapter.collectionName(from: id, database: "other") } throws: { _ in true }
    }

    @Test func collectionIDRejectsGarbage() {
        #expect { try MongoAdapter.collectionName(from: "mongo:collection:!!!", database: "db") } throws: { _ in true }
        #expect { try MongoAdapter.collectionName(from: "sqlite:abc", database: "db") } throws: { _ in true }
    }

    // MARK: Error mapping

    @Test func errorRedaction() {
        let dirty = "connect to mongodb+srv://user:secretpw@cluster.example.net/db failed, password=hunter2"
        let clean = MongoErrorMapper.redact(dirty)
        #expect(!clean.contains("secretpw"))
        #expect(!clean.contains("hunter2"))
        #expect(clean.contains("[credentials]"))
    }

    @Test func errorRedactionTruncates() {
        let long = String(repeating: "e", count: 5000)
        #expect(MongoErrorMapper.redact(long).count == 600)
    }
}
