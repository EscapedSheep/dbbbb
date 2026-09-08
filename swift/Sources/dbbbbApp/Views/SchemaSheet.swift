import SwiftUI
import dbbbbCore

/// Read-only structured-schema viewer ("View Schema"): table list on the
/// left, the selected table's columns/indexes/foreign keys on the right, and
/// the database-wide relationship list (every foreign-key edge) below. The
/// snapshot is fetched beforehand by `SessionStore`; errors never reach this
/// sheet (they surface in the redacted banner).
struct SchemaSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: SessionStore.SchemaPresentation

    /// The selected table's `DatabaseObject.id`; defaults to the first table.
    @State private var selectedTableID: String?

    private var selectedTable: TableSchema? {
        presentation.tables.first { $0.object.id == selectedTableID } ?? presentation.tables.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schema — \(presentation.databaseName)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VSplitView {
                HSplitView {
                    tableList
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    tableDetail
                        .frame(minWidth: 360)
                }
                .frame(minHeight: 220)

                relationships
                    .frame(minHeight: 120, idealHeight: 160)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 760, height: 560)
        .onAppear {
            selectedTableID = selectedTableID ?? presentation.tables.first?.object.id
        }
    }

    // MARK: Table list (left)

    private var tableList: some View {
        List(selection: $selectedTableID) {
            ForEach(presentation.tables, id: \.object.id) { table in
                Label(table.object.name, systemImage: "tablecells")
                    .font(.system(.body, design: .monospaced))
                    .tag(table.object.id)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Table detail (right)

    @ViewBuilder
    private var tableDetail: some View {
        if let table = selectedTable {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    columnsSection(table)
                    indexesSection(table)
                    foreignKeysSection(table)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No Tables",
                systemImage: "tablecells",
                description: Text("This database has no tables to describe.")
            )
        }
    }

    private func columnsSection(_ table: TableSchema) -> some View {
        schemaSection("Columns") {
            if table.columns.isEmpty {
                emptyNote("No columns")
            } else {
                ForEach(table.columns, id: \.name) { column in
                    HStack(alignment: .firstTextBaseline) {
                        Text(column.name)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if column.isPrimaryKey {
                            Text("PK\(table.columns.filter(\.isPrimaryKey).count > 1 ? " \(column.primaryKeyOrdinal)" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(column.dataType.isEmpty ? "—" : column.dataType)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(column.nullable ? "NULL" : "NOT NULL")
                            .font(.caption)
                            .foregroundStyle(column.nullable ? .tertiary : .secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func indexesSection(_ table: TableSchema) -> some View {
        schemaSection("Indexes") {
            if table.indexes.isEmpty {
                emptyNote("No indexes")
            } else {
                ForEach(table.indexes, id: \.name) { index in
                    HStack(alignment: .firstTextBaseline) {
                        Text(index.name)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if index.isUnique {
                            Text("UNIQUE")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(index.columns.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func foreignKeysSection(_ table: TableSchema) -> some View {
        schemaSection("Foreign Keys") {
            if table.foreignKeys.isEmpty {
                emptyNote("No foreign keys")
            } else {
                ForEach(Array(table.foreignKeys.enumerated()), id: \.offset) { _, key in
                    Text(Self.edgeText(columns: key.columns,
                                       referencedName: key.referencedObject.name,
                                       referencedColumns: key.referencedColumns))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Relationships (bottom)

    private var relationships: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Relationships")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(presentation.relations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if presentation.relations.isEmpty {
                Text("No foreign-key relationships in this database.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(presentation.relations.enumerated()), id: \.offset) { _, relation in
                            Text(Self.edgeText(
                                columns: relation.foreignKey.columns,
                                sourceName: relation.object.name,
                                referencedName: relation.foreignKey.referencedObject.name,
                                referencedColumns: relation.foreignKey.referencedColumns))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
    }

    // MARK: Helpers

    private func schemaSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// "user_id → users.id" for one table's foreign key; "orders.user_id →
    /// users.id" for the database-wide list (source included). Multi-column
    /// keys join their legs with " + ".
    static func edgeText(
        columns: [String],
        sourceName: String? = nil,
        referencedName: String,
        referencedColumns: [String]
    ) -> String {
        let source = columns.joined(separator: " + ")
        let target = referencedColumns.map { "\(referencedName).\($0)" }.joined(separator: " + ")
        if let sourceName {
            return "\(sourceName).\(source) → \(target)"
        }
        return "\(source) → \(target)"
    }
}
