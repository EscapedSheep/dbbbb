import SwiftUI
import AppKit
import dbbbbCore
import dbbbbKit

/// `NSTableView` wrapper for tabular results. SwiftUI `Table` caps column
/// counts (its column builder has no `ForEach`), so wide result sets render
/// here instead: arbitrary columns, horizontal scrolling, row selection, and
/// the same copy/edit context menu as the rest of the results UI.
struct ResultsTableView: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let columns: [ColumnMeta]
    let rows: [RowModel]
    @Binding var selection: Set<Int>
    /// Edit/Delete menu entries are offered only when the session allows
    /// editing (`store.editingObject != nil`); fail-closed stays fail-closed.
    let allowsEditing: Bool
    let onCopy: (_ rows: Set<Int>, _ asTSV: Bool) -> Void
    let onEdit: (_ row: Int) -> Void
    let onDelete: (_ row: Int) -> Void

    /// "Copy as INSERT" needs a target table; only previews know one
    /// (`store.previewedObject`). Ad-hoc results have no known source table,
    /// so the menu entry is not offered there.
    var insertTarget: (object: DatabaseObject, engine: DatabaseEngine)? {
        guard let object = store.previewedObject,
              let engine = store.selectedSession?.profile.engine
        else { return nil }
        return (object, engine)
    }

    /// Renders the selected rows as INSERT statements onto the pasteboard.
    /// Fail-closed values (binary, non-finite numbers) copy nothing and
    /// surface their pre-redacted message in the error banner instead.
    func copyInsert(_ selection: Set<Int>) {
        guard let target = insertTarget else { return }
        let selectedRows = rows
            .filter { selection.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map(\.values)
        do {
            let text = try DisplayFormatting.insertStatements(
                rows: selectedRows, columns: columns,
                object: target.object, engine: target.engine)
            copyToPasteboard(text)
        } catch {
            store.errorMessage = (error as? dbbbbError)?.userMessage ?? error.localizedDescription
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsNSTableView()
        table.headerView = ResultsTableHeaderView()
        // The reference grid: flat rows, hairline separators, no zebra.
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = NSColor(AppColors.bgPanel)
        table.gridColor = NSColor(AppColors.border)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.rowHeight = 33
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
            syncSortIndicators(in: tableView, parent: parent)
        }

        /// Shows the active grid sort on its column header. Only previews
        /// sort (see `tableView(_:didClick:)`), so ad-hoc results never carry
        /// an indicator.
        private func syncSortIndicators(in tableView: NSTableView, parent: ResultsTableView) {
            let sort = parent.store.previewedObject != nil ? parent.store.previewSort : nil
            for (index, column) in tableView.tableColumns.enumerated() {
                let dataIndex = index - 1
                let active = dataIndex >= 0 && dataIndex < parent.columns.count
                    && sort?.column == parent.columns[dataIndex].name
                let image: NSImage? = active
                    ? NSImage(
                        systemSymbolName: sort?.ascending == true ? "chevron.up" : "chevron.down",
                        accessibilityDescription: nil)
                    : nil
                tableView.setIndicatorImage(image, in: column)
            }
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
            guard let parent, let tableColumn else { return nil }
            let index = tableView.tableColumns.firstIndex(of: tableColumn) ?? 0

            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = cellIdentifier
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
            }
            cell.font = AppFonts.mono(12)

            if index == 0 {
                // Row number (1-based, reference `.row-index`).
                cell.stringValue = String(row + 1)
                cell.textColor = NSColor(AppColors.textDisabled)
                cell.alignment = .right
                cell.toolTip = nil
                return cell
            }

            let dataIndex = index - 1
            guard parent.rows.indices.contains(row), dataIndex < parent.columns.count else { return nil }
            let model = parent.rows[row]
            let column = parent.columns[dataIndex]
            let text = dataIndex < model.cells.count ? model.cells[dataIndex] : ""
            let isNull = dataIndex < model.values.count && model.values[dataIndex] == .null
            // NULL renders as an italic "NULL" marker (reference `.null-cell`).
            cell.stringValue = isNull ? "NULL" : text
            // Full value on hover, mirroring the SwiftUI cell's `.help(text)`.
            cell.toolTip = text
            cell.textColor = NSColor(AppColors.text)
            if isNull {
                cell.font = NSFontManager.shared.convert(cell.font!, toHaveTrait: .italicFontMask)
                cell.textColor = NSColor(AppColors.textDisabled)
            }
            cell.alignment = column.numeric ? .right : .left
            return cell
        }

        /// Reference selection color (bg-selected) instead of the system blue.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ResultsTableRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let parent, let tableView else { return }
            var selected = Set(tableView.selectedRowIndexes)
            selected.formIntersection(Set(parent.rows.indices))
            guard selected != parent.selection else { return }
            parent.selection = selected
        }

        /// Header clicks cycle the grid sort asc → desc → none through
        /// `store.setPreviewSort` (which re-runs the preview server-side from
        /// page one). Only preview results are sortable: ad-hoc query results
        /// have no reloadable source to re-sort, so their header clicks do
        /// nothing.
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let parent,
                  let rawIndex = tableView.tableColumns.firstIndex(of: tableColumn),
                  rawIndex > 0, rawIndex - 1 < parent.columns.count,
                  parent.store.previewedObject != nil
            else { return }
            let column = parent.columns[rawIndex - 1].name
            let current = parent.store.previewSort
            if current?.column != column {
                parent.store.setPreviewSort(PreviewRequest.Sort(column: column, ascending: true))
            } else if current?.ascending == true {
                parent.store.setPreviewSort(PreviewRequest.Sort(column: column, ascending: false))
            } else {
                parent.store.setPreviewSort(nil)
            }
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
            if parent.insertTarget != nil {
                let insert = NSMenuItem(title: "Copy as INSERT", action: #selector(copyAsInsert), keyEquivalent: "")
                insert.target = self
                menu.addItem(insert)
            }
            // "Jump to Referenced Row" entries for every FK the row can
            // follow (ROADMAP M1 ⑤); the store hides keys with NULL or
            // missing legs and everything non-conforming/ad-hoc.
            if selection.count == 1, let id = selection.first, parent.rows.indices.contains(id) {
                let model = parent.rows[id]
                let row = zip(parent.columns, model.values).map { (key: $0.0.name, value: $0.1) }
                let jumps = parent.store.foreignKeyJumps(forRow: row)
                if !jumps.isEmpty {
                    menu.addItem(.separator())
                    for foreignKey in jumps {
                        let title = "Jump to Referenced Row: "
                            + foreignKey.columns.joined(separator: ", ")
                            + " → \(foreignKey.referencedObject.name)"
                        let item = NSMenuItem(
                            title: title, action: #selector(jumpToReferencedRow(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = ForeignKeyJumpBox(foreignKey: foreignKey, row: row)
                        menu.addItem(item)
                    }
                }
            }
            if selection.count == 1, let id = selection.first, parent.allowsEditing {
                menu.addItem(.separator())
                let edit = NSMenuItem(title: "Edit Row…", action: #selector(editRow(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = NSNumber(value: id)
                menu.addItem(edit)
                // Duplicate opens the insert draft prefilled from this row;
                // primary-key columns stay blank so the server default applies
                // instead of colliding with the source row's unique key.
                let duplicate = NSMenuItem(title: "Duplicate Row…", action: #selector(duplicateRow(_:)), keyEquivalent: "")
                duplicate.target = self
                duplicate.representedObject = NSNumber(value: id)
                menu.addItem(duplicate)
                let delete = NSMenuItem(title: "Delete Row…", action: #selector(deleteRow(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = NSNumber(value: id)
                menu.addItem(delete)
            }
            return menu
        }

        @objc private func copyAsTSV() { copySelection(asTSV: true) }
        @objc private func copyAsJSON() { copySelection(asTSV: false) }

        @objc private func copyAsInsert() {
            guard let parent, let tableView else { return }
            parent.copyInsert(Set(tableView.selectedRowIndexes))
        }

        private func copySelection(asTSV: Bool) {
            guard let parent, let tableView else { return }
            parent.onCopy(Set(tableView.selectedRowIndexes), asTSV)
        }

        @objc private func editRow(_ item: NSMenuItem) {
            guard let id = (item.representedObject as? NSNumber)?.intValue else { return }
            parent?.onEdit(id)
        }

        @objc private func duplicateRow(_ item: NSMenuItem) {
            guard let parent,
                  let id = (item.representedObject as? NSNumber)?.intValue,
                  let model = parent.rows.first(where: { $0.id == id })
            else { return }
            let row = zip(parent.columns, model.values).map { (key: $0.0.name, value: $0.1) }
            parent.store.beginDuplicate(row: row)
        }

        @objc private func deleteRow(_ item: NSMenuItem) {
            guard let id = (item.representedObject as? NSNumber)?.intValue else { return }
            parent?.onDelete(id)
        }

        @objc private func jumpToReferencedRow(_ item: NSMenuItem) {
            guard let box = item.representedObject as? ForeignKeyJumpBox else { return }
            parent?.store.jumpToReferencedRow(box.foreignKey, row: box.row)
        }
    }
}

/// Menu-item payload for a foreign-key jump: the constraint plus the selected
/// row's column/value pairs (the jump revalidates them before following).
private final class ForeignKeyJumpBox {
    let foreignKey: ForeignKey
    let row: [(key: String, value: DisplayValue)]
    init(foreignKey: ForeignKey, row: [(key: String, value: DisplayValue)]) {
        self.foreignKey = foreignKey
        self.row = row
    }
}


/// Reference `bg-selected` row highlight.
private final class ResultsTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(AppColors.bgSelected).setFill()
        dirtyRect.fill()
    }
}

/// Header strip background (reference `.result-table th` = bg-subtle).
final class ResultsTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(AppColors.bgSubtle).setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
