import SwiftUI
import dbbbbCore

/// MongoDB results rendered as a monospaced, expandable outline. When the
/// session allows editing (writable preview of one collection), each root
/// document gets an edit/delete context menu.
struct DocumentTreeView: View {
    @Environment(SessionStore.self) private var store

    let documents: [DisplayValue]

    @State private var editingState: RecordEditingState?

    private var roots: [DocNode] {
        documents.enumerated().map {
            DocNode.make(label: "[\($0.offset)]", value: $0.element, documentIndex: $0.offset)
        }
    }

    var body: some View {
        if documents.isEmpty {
            ContentUnavailableView(
                "No Documents",
                systemImage: "doc.text.magnifyingglass",
                description: Text("The query matched nothing.")
            )
        } else {
            ScrollView {
                OutlineGroup(roots, children: \.children) { node in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(node.label)
                            .foregroundStyle(.secondary)
                        if let text = node.valueText {
                            Text(text)
                                .foregroundStyle(node.isNull ? .tertiary : .primary)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .contextMenu {
                        if let index = node.documentIndex, store.editingObject != nil {
                            Button("Edit Document…") {
                                editingState = documentDraft(index).map(RecordEditingState.editing)
                            }
                            Button("Delete Document…") {
                                editingState = documentDraft(index).map {
                                    RecordEditingState.reviewing(RecordReview(
                                        draft: $0, changes: [], changed: [:], isDelete: true))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .sheet(item: $editingState) { _ in
                RecordEditingSheet(state: $editingState)
            }
        }
    }

    /// The editing draft for one document: its displayed fields as the
    /// optimistic-concurrency baseline.
    private func documentDraft(_ index: Int) -> RecordDraft? {
        guard let object = store.editingObject,
              let session = store.selectedSession,
              documents.indices.contains(index),
              case .object(let pairs) = documents[index]
        else { return nil }
        return RecordDraft(
            object: object,
            environment: session.profile.environment,
            columns: [],
            original: pairs)
    }
}
