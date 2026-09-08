import SwiftUI
import dbbbbCore

/// Read-only table-statistics viewer (ROADMAP M2 ⑩): estimated rows and
/// human-readable byte sizes, plus any engine-specific extras. The snapshot
/// is fetched beforehand by `SessionStore`; errors never reach this sheet
/// (they surface in the redacted banner).
struct TableStatisticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: SessionStore.TableStatisticsPresentation

    private var statistics: TableStatistics { presentation.statistics }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Statistics — \(presentation.objectName)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    row("Estimated rows", Self.rowCountText(statistics.estimatedRows))
                    row("Total size", DisplayFormatting.byteText(statistics.totalBytes))
                    row("Index size", DisplayFormatting.byteText(statistics.indexBytes))
                    ForEach(statistics.extras, id: \.name) { entry in
                        row(entry.name, entry.value)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 420, height: 280)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    static func rowCountText(_ count: Int64?) -> String {
        count.map(String.init) ?? "—"
    }
}
