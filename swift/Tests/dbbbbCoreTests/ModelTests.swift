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
}
