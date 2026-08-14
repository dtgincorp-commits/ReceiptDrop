import SwiftUI

/// User-selectable text size for this app specifically — distinct from
/// iOS's own Text Size setting (Settings → Display & Brightness), which
/// already applies to ReceiptDrop today since the app is built almost
/// entirely from semantic fonts (.caption, .subheadline, .body, etc.). This
/// exists to let someone run ReceiptDrop at a different size than the rest
/// of their phone, and to make that control discoverable in-app.
///
/// In its own file (rather than alongside `ExtractionSettings`/
/// `BackupSettings` in `ReceiptModels.swift`) specifically so `SwiftUI` isn't
/// imported into that file — it's compiled into the share extension too, and
/// keeping it Foundation-only is the existing convention there.
enum AppTextSize: String, CaseIterable, Identifiable {
    case system, small, medium, large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// `nil` means "follow the system setting, override nothing" — the
    /// default, and the only value existing installs should ever see.
    ///
    /// The non-accessibility scale, in order, is:
    /// xSmall, small, medium, **large** (iOS's own default), xLarge, xxLarge,
    /// xxxLarge. Deliberately kept symmetric around that default — Small and
    /// Large are each 2 steps away from it — rather than a first attempt
    /// that mapped Small → `.small` (only 1 step down) while Large → `.xxLarge`
    /// (2 steps up): comparing Small against Large made almost all the
    /// visible difference come from the Large side, with Small barely
    /// smaller than normal. "Medium" maps to `.large` (the default itself),
    /// so it reads as "the normal size every other app uses," not a
    /// third distinct size.
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .small: return .xSmall
        case .medium: return .large
        case .large: return .xxLarge
        }
    }
}
