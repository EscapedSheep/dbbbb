import Testing
@testable import dbbbbKit

struct MongoQueryTextTests {
    @Test func pipelinesAreArrays() {
        #expect(MongoQueryText.isPipeline("[]"))
        #expect(MongoQueryText.isPipeline("[ { \"$match\": {} } ]"))
        #expect(MongoQueryText.isPipeline("  \n[\n  { \"$match\": {} }\n]  "))
    }

    @Test func filtersAreDocuments() {
        #expect(!MongoQueryText.isPipeline("{}"))
        #expect(!MongoQueryText.isPipeline("{ }"))
        #expect(!MongoQueryText.isPipeline("\n\t{ \"status\": \"ok\" }\n"))
        #expect(!MongoQueryText.isPipeline(""))
    }
}
