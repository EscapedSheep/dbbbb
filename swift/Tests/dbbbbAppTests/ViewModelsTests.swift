import Foundation
import Testing
import dbbbbCore
@testable import dbbbbApp

struct ViewModelsTests {
    private func allIDs(_ node: DocNode) -> [String] {
        [node.id] + (node.children ?? []).flatMap(allIDs)
    }

    @Test func docNodeIDsAreStableAcrossRebuilds() {
        let document: DisplayValue = .object([
            ("name", .string("alpha")),
            ("tags", .array([.string("x"), .null])),
            ("nested", .object([("n", .number(1))])),
        ])
        let first = DocNode.make(label: "[0]", value: document, documentIndex: 0)
        let rebuilt = DocNode.make(label: "[0]", value: document, documentIndex: 0)
        #expect(allIDs(first) == allIDs(rebuilt))
        #expect(Set(allIDs(first)).count == allIDs(first).count)
    }

    @Test func docNodeIDsAreUniquePerDocument() {
        let document: DisplayValue = .object([("a", .number(1))])
        let first = DocNode.make(label: "[0]", value: document, documentIndex: 0)
        let second = DocNode.make(label: "[1]", value: document, documentIndex: 1)
        #expect(Set(allIDs(first)).isDisjoint(with: Set(allIDs(second))))
        #expect(first.documentIndex == 0)
        #expect(second.documentIndex == 1)
        // Only root nodes carry the document index.
        #expect(first.children?.first?.documentIndex == nil)
    }

    @Test func docNodeIDsAreUniqueAmongDuplicateKeys() {
        let document: DisplayValue = .object([("k", .number(1)), ("k", .number(2))])
        let node = DocNode.make(label: "[0]", value: document, documentIndex: 0)
        #expect(Set(allIDs(node)).count == allIDs(node).count)
    }
}
