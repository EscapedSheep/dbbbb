import Testing
@testable import dbbbbKit

struct PlaceholderTests {
    @Test func adapterErrorMessages() {
        #expect(!AdapterError.cancellationUnsupported.userMessage.isEmpty)
    }
}
