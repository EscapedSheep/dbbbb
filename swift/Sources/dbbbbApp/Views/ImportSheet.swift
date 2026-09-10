import SwiftUI
import UniformTypeIdentifiers
import dbbbbCore
import dbbbbKit

/// The import sheet: choose file → review (typed IMPORT on production) →
/// progress → summary, mirroring the Electron ImportDialog. It is only
/// reachable when `SessionStore.importingObject` is non-nil, and the store
/// re-checks every precondition before anything is written.
struct ImportSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let object: DatabaseObject
    let format: ImportFormat

    @State private var fileURL: URL?
    @State private var fileName: String?
    @State private var fileSize = 0
    @State private var hasHeader = true
    @State private var confirming = false
    @State private var confirmation = ""
    @State private var error: String?
    @State private var started = false
    @State private var finished = false

    private var isProduction: Bool {
        store.selectedSession?.profile.environment == .production
    }

    /// The token production connections must type before an import starts
    /// (the editing milestone's APPLY pattern).
    private let confirmationToken = "IMPORT"

    private var canConfirm: Bool {
        !isProduction || confirmation == confirmationToken
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Import Data",
                environment: store.selectedSession?.profile.environment ?? .development)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if store.isImporting {
                runningView
            } else if finished, let summary = store.importSummary {
                summaryView(summary)
            } else if confirming, let fileName {
                confirmView(fileName: fileName)
            } else {
                setupView
            }
            Divider()
            footer
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 300)
        .onChange(of: store.isImporting) { _, running in
            guard !running, started else { return }
            if store.importSummary != nil {
                finished = true
            } else {
                // Failure or cancellation: back to setup with the redacted message.
                error = store.errorMessage
                confirming = false
            }
        }
    }

    // MARK: - Phases

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetSummary
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source file")
                        .font(.headline)
                    Text(format == .csv
                         ? "Choose one CSV file for the selected table."
                         : "Choose JSONL with one JSON document per non-empty line.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(fileName == nil ? "Choose .\(format.rawValue)…" : "Change file…") {
                    chooseFile()
                }
            }
            if let fileName {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.callout.weight(.medium))
                        Text("\(Self.fileSizeText(fileSize)) · File contents are not loaded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if format == .csv {
                Toggle(isOn: $hasHeader) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First row contains column names")
                        Text("Turn this off when every row contains table data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            safetyNote
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func confirmView(fileName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirm import")
                        .font(.headline)
                    Text("Import **\(fileName)** into **\(object.name)** on **\(store.selectedSession?.profile.name ?? "")**?")
                        .font(.callout)
                    Text("Format: \(format.rawValue.uppercased())"
                        + (format == .csv ? " · Header row: \(hasHeader ? "Yes" : "No")" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(AppColors.production)
            }
            safetyNote
            if isProduction {
                LabeledContent {
                    TextField("", text: $confirmation)
                } label: {
                    Text("Type **\(confirmationToken)** to confirm")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var runningView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(fileName.map { "Importing \($0)" } ?? "Importing data")
                .font(.headline)
            if let progress = store.importProgress {
                Text("\(progress.processed) processed · \(progress.inserted) inserted"
                    + (progress.failed > 0 ? " · \(progress.failed) failed" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func summaryView(_ summary: ImportSummary) -> some View {
        VStack(spacing: 12) {
            Label("Import completed", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Inserted \(summary.inserted) of \(summary.processed) "
                + (store.resultIsDocuments ? "documents" : "rows")
                + (summary.failed > 0 ? " (\(summary.failed) failed)" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Pieces

    private var targetSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Connection") {
                Text(store.selectedSession?.profile.name ?? "")
            }
            LabeledContent("Target") {
                Text("\(object.name) (\(object.kind.rawValue))")
            }
            LabeledContent("Format") {
                Text(format.rawValue.uppercased())
            }
        }
        .font(.callout)
    }

    private var safetyNote: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Imports write to the selected target")
                    .font(.callout.weight(.medium))
                Text(safetyNoteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.warning)
        }
    }

    private var safetyNoteText: String {
        switch store.selectedSession?.profile.engine {
        case .postgresql, .mysql:
            "The file runs in one transaction and rolls back if a batch fails."
        case .sqlite:
            "Each batch is its own transaction; a failed batch rolls back, earlier batches stay."
        case .mongodb, .bullmq, nil:
            "MongoDB imports are not transactional; a failed import may be partially complete."
        }
    }

    private var footer: some View {
        HStack {
            if store.isImporting {
                Spacer()
                Button("Cancel Import") { store.cancelImport() }
            } else if finished {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if confirming {
                Button("Back") {
                    confirming = false
                    confirmation = ""
                    error = nil
                }
                Spacer()
                Button("Confirm Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Import") {
                    error = nil
                    confirming = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fileURL == nil)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = format == .csv ? "Choose CSV to import" : "Choose JSON Lines to import"
        panel.allowedContentTypes = format.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                error = "The selected file is empty. Choose a file containing rows or documents."
                return
            }
            guard size <= ImportFileLimits.maxFileBytes else {
                error = "Import files are limited to 1 GB in this build."
                return
            }
            fileURL = url
            fileName = url.lastPathComponent
            fileSize = size
            error = nil
        } catch {
            // Path-free, like every import error.
            self.error = "The selected import file is no longer available."
        }
    }

    private func start() {
        guard let fileURL, canConfirm else { return }
        error = nil
        started = true
        finished = false
        store.startImport(format: format, fileURL: fileURL, hasHeader: hasHeader)
        // A fail-closed refusal leaves isImporting false; surface it inline.
        if !store.isImporting {
            error = store.errorMessage
            confirming = false
            started = false
        }
    }

    static func fileSizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

/// The 1 GB import cap, surfaced for the sheet's choose-time validation
/// (the driver enforces it again at start).
enum ImportFileLimits {
    static let maxFileBytes = 1024 * 1024 * 1024
}

/// Shared sheet chrome: title plus the production warning strip (same shape
/// as the editing sheet's header).
private struct SheetHeader: View {
    let title: String
    let environment: ConnectionEnvironment

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, environment == .development ? 10 : 4)
            if environment == .production {
                Label("Production connection — review the file and target before importing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.production)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
        }
    }
}
