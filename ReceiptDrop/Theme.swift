import SwiftUI

/// Shared accent color for a brighter, more distinct look.
enum Theme {
    static let skyBlue = Color(red: 0.29, green: 0.69, blue: 0.96)
    static let skyBlueLight = Color(red: 0.85, green: 0.94, blue: 1.0)
    /// A more vivid, saturated blue for small high-contrast accents like badges.
    static let skyBlueBright = Color(red: 0.20, green: 0.72, blue: 1.0)
    /// iOS system blue (#0A84FF) — reserved for the one primary action on a
    /// screen (the floating "New Receipt" button), so it reads as *the* thing
    /// to tap rather than blending into the sky-blue used for ordinary accents.
    static let actionBlue = Color(red: 0.039, green: 0.518, blue: 1.0)
}
