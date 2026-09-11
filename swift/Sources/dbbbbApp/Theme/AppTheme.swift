import SwiftUI
import AppKit
import dbbbbCore

/// Manual appearance override; `.system` (the default) follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A color that flips between the light and dark palettes with the effective
/// appearance (mirrors the Electron `styles.css` `:root` / `[data-theme="dark"]`
/// variable pairs, hex for hex).
private func themed(_ light: UInt32, _ dark: UInt32) -> Color {
    func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? srgb(dark) : srgb(light)
    })
}

/// Design tokens, one-to-one with the Electron reference's `styles.css`
/// custom properties. Every view reads colors from here — no scattered system
/// semantic colors. Radii stay small (4px) and borders thin (1px) per the
/// reference's dense, calm look.
enum AppColors {
    static let bgApp = themed(0xF6F7F9, 0x0D1117)
    static let bgPanel = themed(0xFFFFFF, 0x131922)
    static let bgSubtle = themed(0xF0F2F5, 0x19212C)
    static let bgHover = themed(0xEAEDF2, 0x202A37)
    static let bgSelected = themed(0xE7EEFF, 0x1C2D4E)
    static let border = themed(0xD4D9E1, 0x2B3543)
    static let borderStrong = themed(0xAEB6C2, 0x465366)
    static let text = themed(0x171A21, 0xEEF2F7)
    static let textSecondary = themed(0x555F6D, 0xAEB8C6)
    static let textDisabled = themed(0x687182, 0x7B8798)
    static let accent = themed(0x255FD6, 0x79A4FF)
    static let accentFill = themed(0x255FD6, 0x365FC7)
    static let accentSoft = themed(0xE7EEFF, 0x1C2D4E)
    static let success = themed(0x18794E, 0x4BD19A)
    static let successSoft = themed(0xE7F6EF, 0x173328)
    static let warning = themed(0x8A5700, 0xF1B65B)
    static let warningSoft = themed(0xFFF4D6, 0x3A2D17)
    static let danger = themed(0xBA2838, 0xFF727F)
    static let dangerFill = themed(0xBA2838, 0xC4303D)
    static let dangerSoft = themed(0xFFEAED, 0x3D2028)
    static let onDanger = Color.white

    /// Orange stays reserved for production markers (app-specific restraint on
    /// top of the reference palette).
    static let production = Color.orange
}

/// Shared metrics from the reference stylesheet.
enum AppMetrics {
    static let cornerRadius: CGFloat = 4
    static let badgeRadius: CGFloat = 999
    static let headerHeight: CGFloat = 44
    /// The connections and objects columns each take this fixed width.
    static let columnWidth: CGFloat = 240
    static let sidebarWidth: CGFloat = 268
    static let statusBarHeight: CGFloat = 24
    static let tabStripHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 38
    static let resultToolbarHeight: CGFloat = 36
    static let editorGutterWidth: CGFloat = 42
    static let editorFontSize: CGFloat = 13
    static let editorLineHeight: CGFloat = 20
}

/// Monospaced fonts (the reference's `--mono` stack resolves to SF Mono here).
enum AppFonts {
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func monoUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, design: .monospaced).weight(weight)
    }
}

/// The engine chip: a small bordered square with a two-letter monogram,
/// colored per engine (reference `.engine-icon` + `.engine-<name>`).
enum EngineIcon {
    static func monogram(for engine: DatabaseEngine) -> String {
        switch engine {
        case .postgresql: "PG"
        case .mysql: "MY"
        case .mongodb: "MG"
        case .sqlite: "SQ"
        case .bullmq: "BQ"
        }
    }

    static func color(for engine: DatabaseEngine) -> Color {
        switch engine {
        case .postgresql: AppColors.accent
        case .mysql: AppColors.warning
        case .mongodb: AppColors.success
        case .sqlite: AppColors.textSecondary
        case .bullmq: AppColors.danger
        }
    }

    /// Kept for the few spots that still want an SF Symbol (status bar).
    static func systemName(for engine: DatabaseEngine) -> String {
        switch engine {
        case .postgresql: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .mongodb: "leaf"
        case .sqlite: "internaldrive"
        case .bullmq: "square.stack.3d.up"
        }
    }
}

/// The bordered monogram chip itself.
struct EngineBadge: View {
    let engine: DatabaseEngine

    var body: some View {
        Text(EngineIcon.monogram(for: engine))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(EngineIcon.color(for: engine))
            .frame(width: 26, height: 26)
            .background(AppColors.bgPanel)
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(EngineIcon.color(for: engine).opacity(0.55), lineWidth: 1))
    }
}

// MARK: - Button styles (reference .primary-button / .secondary-button / …)

/// Blue filled action, 30px high — Run, dialog primaries.
struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 30)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(AppColors.accentFill)
                    .brightness(configuration.isPressed ? 0.08 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(AppColors.accentFill.opacity(0.7), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

/// Bordered neutral action — Cancel, dialog secondaries, toolbar actions.
struct AppSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(AppColors.text)
            .frame(height: compact ? 26 : 30)
            .padding(.horizontal, compact ? 8 : 11)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(AppColors.bgPanel))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(AppColors.border, lineWidth: 1))
    }
}

/// Filled danger action — destructive dialog primaries.
struct AppDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.onDanger)
            .frame(height: 30)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(AppColors.dangerFill)
                    .brightness(configuration.isPressed ? 0.08 : 0))
    }
}

/// Ghost danger action (text-only until pressed).
struct AppDangerTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.danger)
            .frame(height: 30)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(configuration.isPressed ? AppColors.dangerSoft : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(configuration.isPressed ? AppColors.danger.opacity(0.3) : .clear, lineWidth: 1))
    }
}

/// Borderless square icon button with a hover well (reference `.icon-button`).
struct AppIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(configuration.isPressed ? AppColors.bgHover : .clear))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == AppPrimaryButtonStyle {
    static var appPrimary: AppPrimaryButtonStyle { AppPrimaryButtonStyle() }
}

extension ButtonStyle where Self == AppSecondaryButtonStyle {
    static var appSecondary: AppSecondaryButtonStyle { AppSecondaryButtonStyle() }
    static var appSecondaryCompact: AppSecondaryButtonStyle { AppSecondaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == AppDangerButtonStyle {
    static var appDanger: AppDangerButtonStyle { AppDangerButtonStyle() }
}

extension ButtonStyle where Self == AppDangerTextButtonStyle {
    static var appDangerText: AppDangerTextButtonStyle { AppDangerTextButtonStyle() }
}

extension ButtonStyle where Self == AppIconButtonStyle {
    static var appIcon: AppIconButtonStyle { AppIconButtonStyle() }
}
