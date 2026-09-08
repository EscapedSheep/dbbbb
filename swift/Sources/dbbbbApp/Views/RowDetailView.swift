import SwiftUI
import dbbbbCore

/// Right-hand pane listing one selected row's columns and values vertically
/// (ROADMAP M2 ⑥). Pure presentation: values arrive as `DisplayValue`s and
/// render through `RowDetailItem`/`DisplayFormatting`; expansion state is
/// local and resets whenever the selected row changes. Long values collapse
/// behind a Show more/less toggle, JSON text is pretty-printed when it
/// parses, binary renders as hex, and adapter-truncated values are flagged.
struct RowDetailPane: View {
    let columns: [ColumnMeta]
    /// The single selected row; nil when the selection is empty or multiple.
    let row: RowModel?
    /// Live selection size, so the placeholder can tell "none" from "many".
    let selectionCount: Int
    let onCollapse: () -> Void

    @State private var expanded: Set<Int> = []

    private var items: [RowDetailItem] {
        guard let row else { return [] }
        return RowDetailItem.items(columns: columns, values: row.values)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if row != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            cell(item)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            if item.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                placeholder
            }
        }
        .onChange(of: row?.id) {
            expanded.removeAll()
        }
    }

    private var header: some View {
        HStack {
            Text("Row Detail")
                .font(.callout.weight(.semibold))
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide row detail")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var placeholder: some View {
        ContentUnavailableView(
            selectionCount > 1 ? "Multiple Rows Selected" : "No Row Selected",
            systemImage: "sidebar.right",
            description: Text("Select a single row to inspect every column.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ item: RowDetailItem) -> some View {
        let isExpanded = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.column)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let omitted = item.truncatedOmittedBytes {
                    Text("truncated · \(omitted) bytes omitted")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    copyToPasteboard(item.fullText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy value")
            }
            Text(isExpanded ? item.fullText : item.collapsedText)
                .font(item.kind == .binary || item.kind == .json
                    ? .system(.callout, design: .monospaced)
                    : .callout)
                .foregroundStyle(item.kind == .null ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.isCollapsible {
                Button(isExpanded ? "Show less" : "Show more") {
                    if isExpanded {
                        expanded.remove(item.id)
                    } else {
                        expanded.insert(item.id)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
