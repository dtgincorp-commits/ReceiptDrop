import SwiftUI

extension View {
    /// Segmented for a short, fixed-feeling list; menu once it's long enough
    /// that segmented would start truncating names.
    ///
    /// `.pickerStyle(.segmented)` divides its width equally across every
    /// segment, so it silently degrades as categories are added — 3 or 4
    /// short names read fine, but 6 categories in the same width truncates
    /// everything to a few characters ("SAM…" indistinguishable from
    /// another "SAM…"), with no way to see the full name short of renaming
    /// it shorter. `.menu` shows the full selected name and lists every
    /// option at full length when tapped, so it doesn't have this failure
    /// mode regardless of category count or name length — the tradeoff is
    /// an extra tap to see all the options at once, which is only worth
    /// avoiding when the list is short enough that segmented actually reads
    /// cleanly.
    ///
    /// The threshold (3) is deliberately conservative: even 4 short names
    /// can start feeling tight on a compact iPhone in portrait, and menu's
    /// downside (one extra tap) is minor compared to segmented's (unreadable
    /// labels), so this favors menu sooner rather than later.
    @ViewBuilder
    func adaptiveCategoryPickerStyle(count: Int) -> some View {
        if count <= 3 {
            self.pickerStyle(.segmented)
        } else {
            self.pickerStyle(.menu)
        }
    }
}
