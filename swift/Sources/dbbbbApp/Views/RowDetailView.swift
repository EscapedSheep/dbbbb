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
    /// Non-nil only when the session may edit this preview (same gate as the
    /// grid's Edit Record). Called with a column index; truncated values are
    /// shown but never editable (the app does not hold their full bytes).
    var onEditValue: ((Int) -> Void)? = nil

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

    /// The value editor is offered on the long-value kinds (text/JSON/binary);
    /// `item.isValueEditable` decides whether it may actually open.
    private func showsValueEditAffordance(_ item: RowDetailItem) -> Bool {
        switch item.kind {
        case .text, .json, .binary: true
        case .null, .number, .bool: false
        }
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
                if let onEditValue, showsValueEditAffordance(item) {
                    Button {
                        onEditValue(item.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!item.isValueEditable)
                    .help(item.isValueEditable
                        ? "Edit value in a larger editor"
                        : "This value was truncated while loading and cannot be edited.")
                }
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
