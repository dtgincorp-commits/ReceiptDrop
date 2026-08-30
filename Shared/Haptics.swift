import UIKit

/// Physical confirmation for the few moments that actually warrant it.
///
/// Deliberately UIKit's generators rather than SwiftUI's `.sensoryFeedback`:
/// that modifier is iOS 17+, and this app's deployment target is 16.0 (see
/// `project.yml`). Wrapping it in an availability check for a three-line
/// convenience would cost more than it saves, and `UINotificationFeedback-
/// Generator` has been available since iOS 10 with identical behavior.
///
/// Kept to three calls on purpose. Haptics read as confirmation, but only
/// while they stay rare — an app that buzzes on every tap trains people to
/// stop noticing, which costs exactly the moments below their meaning.
/// Every call site here is a point where the user has committed something
/// and needs to know it landed without reading the screen.
///
/// iOS silences these automatically when the ring switch is off or Low
/// Power Mode is on, so there is nothing to gate on here.
enum Haptics {
    /// A receipt made it all the way through the pipeline and was saved.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something needs a decision before it can proceed — a duplicate, or a
    /// value the app refused to trust. Distinct from `success` so a stopped
    /// submission doesn't feel like a completed one in the pocket.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
