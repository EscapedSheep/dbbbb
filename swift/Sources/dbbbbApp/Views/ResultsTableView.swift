import SwiftUI
import AppKit
import dbbbbCore

/// `NSTableView` wrapper for tabular results. SwiftUI `Table` caps column
/// counts (its column builder has no `ForEach`), so wide result sets render
/// here instead: arbitrary columns, horizontal scrolling, row selection, and
/// the same copy/edit context menu as the rest of the results UI.
struct ResultsTableView: NSViewRepresentable {
    let columns: [ColumnMeta]
    let rows: [RowModel]
    @Binding var selection: Set<Int>
    /// Edit/Delete menu entries are offered only when the session allows
    /// editing (`store.editingObject != nil`); fail-closed stays fail-closed.
    let allowsEditing: Bool
    let onCopy: (_ rows: Set<Int>, _ asTSV: Bool) -> Void
    let onEdit: (_ row: Int) -> Void
    let onDelete: (_ row: Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsNSTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        // No column autoresizing: wide tables scroll horizontally instead of
        // squeezing every column into the window.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.menu(for: row)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ResultsNSTableView else { return }
        context.coordinator.update(parent: self, tableView: table)
    }

    /// NSTableView subclass with a row-aware context menu: right-clicking an
    /// unselected row selects it first (standard macOS behavior), right-clicking
    /// empty space shows no menu, matching `contextMenu(forSelectionType:)`.
    final class ResultsNSTableView: NSTableView {
        var menuProvider: ((Int) -> NSMenu?)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return nil }
            return menuProvider?(row)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: ResultsTableView?
        private weak var tableView: ResultsNSTableView?
        /// Column signature of the currently built `NSTableColumn`s.
        private var builtColumns: [String] = []
        /// Set while pushing the SwiftUI selection into the table, so the
        /// delegate callback does not echo the same value back.
        private var isSyncingSelection = false

        private let cellIdentifier = NSUserInterfaceItemIdentifier("cell")

        func update(parent: ResultsTableView, tableView: ResultsNSTableView) {
            self.parent = parent
            self.tableView = tableView

            let signature = parent.columns.map(\.name)
            if signature != builtColumns {
                builtColumns = signature
                rebuildColumns(in: tableView)
            }
            tableView.reloadData()
            syncSelection(parent.selection, in: tableView)
        }

        private func rebuildColumns(in tableView: NSTableView) {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            guard let parent else { return }
            for (index, meta) in parent.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
                column.title = meta.name
                let headerWidth = CGFloat(meta.name.count) * 8 + 24
                column.minWidth = 50
                column.width = min(max(headerWidth, 100), 300)
                column.maxWidth = 2000
                tableView.addTableColumn(column)
            }
        }

        private func syncSelection(_ selection: Set<Int>, in tableView: NSTableView) {
            let target = IndexSet(selection.filter { $0 >= 0 })
            guard target != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(target, byExtendingSelection: false)
            isSyncingSelection = false
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn,
                  let index = tableView.tableColumns.firstIndex(of: tableColumn),
                  parent.rows.indices.contains(row), index < parent.columns.count
            else { return nil }
            let model = parent.rows[row]
            let column = parent.columns[index]
            let text = index < model.cells.count ? model.cells[index] : ""
            let isNull = index < model.values.count && model.values[index] == .null

            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = cellIdentifier
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
            }
            cell.stringValue = text
            // Full value on hover, mirroring the SwiftUI cell's `.help(text)`.
            cell.toolTip = text
            cell.font = column.numeric
                ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize)
            // `labelColor`/`tertiaryLabelColor` follow dark/light automatically.
            cell.textColor = isNull ? .tertiaryLabelColor : .labelColor
            cell.alignment = column.numeric ? .right : .left
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let parent, let tableView else { return }
            var selected = Set(tableView.selectedRowIndexes)
            selected.formIntersection(Set(parent.rows.indices))
            guard selected != parent.selection else { return }
            parent.selection = selected
        }

        // MARK: Context menu

        func menu(for row: Int) -> NSMenu? {
            guard let parent, let tableView, parent.rows.indices.contains(row) else { return nil }
            if !tableView.selectedRowIndexes.contains(row) {
                isSyncingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSyncingSelection = false
                parent.selection = [row]
            }
            let selection = Set(tableView.selectedRowIndexes)
            guard !selection.isEmpty else { return nil }

            let menu = NSMenu()
            let tsv = NSMenuItem(title: "Copy as TSV", action: #selector(copyAsTSV), keyEquivalent: "")
            tsv.target = self
            menu.addItem(tsv)
            let json = NSMenuItem(title: "Copy as JSON", action: #selector(copyAsJSON), keyEquivalent: "")
            json.target = self
            menu.addItem(json)
            if selection.count == 1, let id = selection.first, parent.allowsEditing {
                menu.addItem(.separator())
                let edit = NSMenuItem(title: "Edit Row…", action: #selector(editRow(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = NSNumber(value: id)
                menu.addItem(edit)
                let delete = NSMenuItem(title: "Delete Row…", action: #selector(deleteRow(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = NSNumber(value: id)
                menu.addItem(delete)
            }
            return menu
        }

        @objc private func copyAsTSV() { copySelection(asTSV: true) }
        @objc private func copyAsJSON() { copySelection(asTSV: false) }

        private func copySelection(asTSV: Bool) {
            guard let parent, let tableView else { return }
            parent.onCopy(Set(tableView.selectedRowIndexes), asTSV)
        }

        @objc private func editRow(_ item: NSMenuItem) {
            guard let id = (item.representedObject as? NSNumber)?.intValue else { return }
            parent?.onEdit(id)
        }

        @objc private func deleteRow(_ item: NSMenuItem) {
            guard let id = (item.representedObject as? NSNumber)?.intValue else { return }
            parent?.onDelete(id)
        }
    }
}
