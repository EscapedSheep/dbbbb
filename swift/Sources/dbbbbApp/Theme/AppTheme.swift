import SwiftUI
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

/// Restrained semantic palette. The system accent color does the heavy lifting;
/// orange is reserved for production markers and truncation warnings only.
enum AppColors {
    static let production = Color.orange
    static let warning = Color.orange
}

enum EngineIcon {
    static func systemName(for engine: DatabaseEngine) -> String {
        switch engine {
        case .postgresql: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .mongodb: "leaf"
        case .sqlite: "internaldrive"
        }
    }
}
