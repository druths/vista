import SwiftUI

/// Light/dark preference.
///
/// Three-way rather than a toggle: `.system` doesn't pick a side, it declines
/// to override, so Vista follows the device — including its automatic
/// light-to-dark schedule. That is the default, and the only value that keeps
/// working when the device switches on its own.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What to hand `preferredColorScheme`. `nil` means "don't override".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "vista.appearance"
}
