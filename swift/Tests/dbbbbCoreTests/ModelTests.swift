import Testing
@testable import dbbbbCore

struct ModelTests {
    @Test func engineDisplayNames() {
        #expect(DatabaseEngine.mongodb.displayName == "MongoDB")
        #expect(DatabaseEngine.mysql.isSQLFamily)
        #expect(!DatabaseEngine.mongodb.isSQLFamily)
    }

    @Test func mongoEndpointRedaction() {
        let input = ConnectionInput.MongoInput(name: "m", uri: "mongodb://user:secret@host:27017/db", database: "db", tls: true)
        let endpoint = ConnectionInput.mongo(input).endpoint
        #expect(!endpoint.contains("secret"))
        #expect(!endpoint.contains("user"))
    }

    @Test func mongoEndpointRedactionWithAtSignInPassword() {
        // An unencoded @ in the password must not leave a tail behind.
        let endpoint = ConnectionInput.redactMongoURI("mongodb://user:p@ss@host:27017/db")
        #expect(endpoint == "mongodb://***@host:27017/db")
        #expect(!endpoint.contains("p@ss"))
        #expect(!endpoint.contains("ss@"))
        #expect(!endpoint.contains("user"))
    }

    @Test func mongoEndpointRedactionWithMultipleAtSigns() {
        #expect(ConnectionInput.redactMongoURI("mongodb://u:a@b@c@host/db") == "mongodb://***@host/db")
        #expect(ConnectionInput.redactMongoURI("mongodb+srv://u:p@w@cluster.example/db") == "mongodb+srv://***@cluster.example/db")
    }

    @Test func mongoEndpointRedactionWithoutCredentials() {
        #expect(ConnectionInput.redactMongoURI("mongodb://host:27017/db") == "mongodb://host:27017/db")
        #expect(ConnectionInput.redactMongoURI("not-a-uri") == "not-a-uri")
    }

    /// The FK contract (ROADMAP M1 ⑤): value semantics, and the referenced
    /// object rides along as a plain navigator node.
    @Test func foreignKeyContract() {
        let target = DatabaseObject(id: "sqlite:users", parentID: nil, name: "users", kind: .table)
        let key = ForeignKey(columns: ["org", "no"], referencedObject: target, referencedColumns: ["org_id", "order_no"])
        #expect(key.columns == ["org", "no"])
        #expect(key.referencedColumns == ["org_id", "order_no"])
        #expect(key.referencedObject == target)
        #expect(key == ForeignKey(columns: ["org", "no"], referencedObject: target, referencedColumns: ["org_id", "order_no"]))
        #expect(key != ForeignKey(columns: ["org"], referencedObject: target, referencedColumns: ["org_id"]))
    }
}
