import SwiftUI
import dbbbbKit

/// Bottom bar (24px, reference `.status-bar`): connection facts on the left
/// (engine, environment, read-only, demo), preview pager and the insert flow
/// on the right. The insert sheet (blank Add Row or prefilled Duplicate Row)
/// is hosted here so both the button and the grid's context menu can drive it
/// through `store.recordEditingState`.
struct StatusBarView: View {
    @Environment(SessionStore.self) private var store

    /// Binding into the observable store for the insert sheet.
    private var recordEditingState: Binding<RecordEditingState?> {
        Binding(
            get: { store.recordEditingState },
            set: { store.recordEditingState = $0 })
    }

    var body: some View {
        HStack(spacing: 14) {
            if let session = store.selectedSession {
                HStack(spacing: 5) {
                    Circle()
                        .fill(AppColors.success)
                        .frame(width: 6, height: 6)
                    Text(session.profile.engine.displayName)
                        .foregroundStyle(AppColors.textDisabled)
                }
                if session.profile.demo {
                    Text("Demo")
                        .foregroundStyle(AppColors.textDisabled)
                }
                EnvironmentBadge(environment: session.profile.environment)
                if session.profile.readOnly {
                    Text("Read only")
                        .foregroundStyle(AppColors.textDisabled)
                }
                if store.isImporting {
                    Text("Importing…")
                        .foregroundStyle(AppColors.textDisabled)
                }
            }
            Spacer()
            if store.isExecuting {
                Text("Running…")
                    .foregroundStyle(AppColors.textDisabled)
            }
            if store.previewedObject != nil {
                Button {
                    store.previousPreviewPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(AppIconButtonStyle(size: 18))
                .disabled(!store.previewHasPreviousPage || store.isExecuting)
                .help("Previous page")
                Text("Page \(store.previewPageIndex + 1)")
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textDisabled)
                Button {
                    store.nextPreviewPage()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(AppIconButtonStyle(size: 18))
                .disabled(!store.previewHasNextPage || store.isExecuting)
                .help("Next page")
            }
            if let object = store.editingObject {
                Button {
                    store.beginInsert()
                } label: {
                    Label(
                        object.kind == .collection ? "Add Document…" : "Add Row…",
                        systemImage: "plus")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(AppColors.textSecondary)
                .buttonStyle(.plain)
                .help("Insert a new \(object.kind == .collection ? "document" : "row") into \(object.name)")
            }
            Text("UTF-8")
                .foregroundStyle(AppColors.textDisabled)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.bgPanel)
        .overlay(alignment: .top) {
            Rectangle().fill(AppColors.border).frame(height: 1)
        }
        .sheet(item: recordEditingState) { _ in
            RecordEditingSheet(
                state: recordEditingState,
                onStage: { review in store.stage(review) })
        }
    }
}
