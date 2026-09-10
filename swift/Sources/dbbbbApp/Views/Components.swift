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
            badge("STAGING", color: AppColors.warning, soft: AppColors.warningSoft)
        case .production:
            badge("PROD", color: AppColors.production, soft: AppColors.production.opacity(0.16))
        }
    }

    private func badge(_ text: String, color: Color, soft: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(soft))
            .accessibilityLabel("\(environment.rawValue) environment")
    }
}

/// Inline, dismissable error surface (reference `.form-error` styling).
/// Messages arrive pre-redacted.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.danger)
            Text(message)
                .lineLimit(3)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(AppIconButtonStyle(size: 20))
            .help("Dismiss")
        }
        .font(.system(size: 12))
        .foregroundStyle(AppColors.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.dangerSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.danger.opacity(0.3)).frame(height: 1)
        }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
