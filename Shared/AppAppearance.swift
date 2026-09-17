import SwiftUI

/// User-selectable *appearance* for this app specifically — distinct from
/// iOS's own Dark Mode setting, which the app follows today because nothing
/// overrides it. That means someone who runs their phone in Dark Mode
/// system-wide (for battery, for eyestrain, for any reason unrelated to this
/// one app) has no way to see ReceiptDrop in Light Mode without changing
/// their entire phone, and vice versa. This exists to let ReceiptDrop's
/// appearance be set independently, the same way `AppTextSize` lets its
/// text size be set independently of the system Text Size setting.
///
/// In its own file (rather than folded into `AppTextSize.swift` or
/// `ReceiptModels.swift`) for the same reason as `AppTextSize` and
/// `AppCurrency`: it is compiled into the share extension too, and one
/// concept per file is the existing convention there. The share extension
/// does not read this key — it deliberately keeps its own dark card styling
/// regardless of the app's appearance setting — but the App Group suite
/// means it *could*, so nothing here assumes it won't.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "follow the system setting, override nothing" — the
    /// default, and the only value existing installs should ever see. Mirrors
    /// `AppTextSize.dynamicTypeSize`: a `nil` here must leave `ColorScheme`
    /// completely untouched rather than pinning to `.light`, since `.light`
    /// and "system, currently light" are not the same thing (one survives the
    /// phone flipping to Dark Mode later; the other doesn't).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
