import SwiftUI
import dbbbbCore

/// Small capsule marking staging/production connections. Development gets no
/// badge — restraint keeps production visually loud by contrast.
struct EnvironmentBadge: View {
    let environment: ConnectionEnvironment

    var body: some View {
        switch environment {
        case .development:
            EmptyView()
        case .staging:
            badge("STAGING", color: .secondary)
        case .production:
            badge("PROD", color: AppColors.production)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .accessibilityLabel("\(environment.rawValue) environment")
    }
}

/// Inline, dismissable error surface. Messages arrive pre-redacted.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(3)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
