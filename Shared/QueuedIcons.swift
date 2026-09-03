import SwiftUI

/// A clock, plus a moon when anything in the set is deferred to the overnight
/// run.
///
/// One symbol could not say both things: the clock says "queued, not done" —
/// `clock.badge.checkmark` rather than a bare checkmark, so it reads as
/// scheduled-and-accepted rather than finished — and the moon says when.
///
/// The moon is conditional, which makes its absence meaningful too: a clock
/// on its own means everything here is due imminently, on this or the next
/// foreground. Every surface that reports queued receipts uses this, so the
/// same pair means the same thing on the Receipts banner, in the Pending
/// list, and in the share extension's confirmation.
///
/// Colour is the caller's: `.foregroundStyle` at the call site, so a row can
/// tint it to match its own background without this type knowing about the
/// app's palette (which lives in the app target and is not visible to the
/// extension).
struct QueuedIcons: View {
    /// True when at least one of the receipts being described is waiting for
    /// the deferred run rather than the next foreground.
    let includesDeferred: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.badge.checkmark")
            if includesDeferred {
                Image(systemName: "moon.stars.fill")
            }
        }
    }
}
