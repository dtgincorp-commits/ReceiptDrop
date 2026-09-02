import Foundation

/// Decides how likely it is that a photograph is of a receipt, from OCR text
/// alone — the Phase 0 question in AUTO_IMPORT_RESEARCH.md, "is detection good
/// enough to justify asking for the photo-library permission?"
///
/// Deliberately has no PhotoKit and no Vision dependency: it takes recognized
/// text plus a couple of cheap asset hints and returns a score. That keeps it
/// unit-testable without a photo library, lets the DEBUG eval screen drive it
/// over arbitrary picked photos, and means Phase 1's real scanner can reuse it
/// unchanged.
///
/// This is a *pre-filter*, not an extractor. Its only job is to be cheap and
/// to rank; nothing it decides is ever saved or submitted on its own. A false
/// positive costs the user one glance at a thumbnail in the suggestions tray,
/// which is the property the whole feature depends on — see the research
/// note's "Detect locally, then ask. Never auto-submit."
enum ReceiptPhotoClassifier {
    /// What the classifier was given about the photo, beyond its text.
    /// `PHAsset.mediaSubtypes.contains(.photoScreenshot)` is the real source
    /// in Phase 1; the eval screen supplies it from `PhotosPickerItem`
    /// metadata where it can, and `false` where it can't.
    struct AssetHints {
        var isScreenshot: Bool = false
        /// height / width. Receipts photographed on a counter are usually
        /// distinctly tall; this is a weak signal on its own and is weighted
        /// accordingly.
        var aspectRatio: Double?

        init(isScreenshot: Bool = false, aspectRatio: Double? = nil) {
            self.isScreenshot = isScreenshot
            self.aspectRatio = aspectRatio
        }
    }

    /// One contributing signal, kept alongside the score so the eval screen —
    /// and later the suggestions tray — can show *why* a photo was flagged
    /// ("total + tax + 4 currency amounts") rather than an unexplained number.
    struct Signal {
        let name: String
        let weight: Double
    }

    struct Result {
        let score: Double
        let signals: [Signal]

        /// The signals that actually fired, most influential first, as one
        /// short line. Empty string when nothing fired.
        var reason: String {
            signals
                .filter { $0.weight != 0 }
                .sorted { abs($0.weight) > abs($1.weight) }
                .map(\.name)
                .joined(separator: ", ")
        }
    }

    /// Score threshold above which a photo is worth putting in the tray.
    ///
    /// A starting point, NOT a tuned value — Phase 0 exists to replace this
    /// number with one measured against real negatives. The eval screen has a
    /// slider precisely so this constant can be chosen from a curve rather
    /// than guessed.
    static let suggestedThreshold: Double = 0.5

    /// Words that appear on receipts and rarely on anything else. Matched
    /// case-insensitively against word-ish boundaries, so "SUBTOTAL" does not
    /// also count as a "TOTAL" hit (see `matches(_:in:)`).
    private static let strongKeywords = [
        "subtotal", "grand total", "amount due", "balance due", "amount paid",
        "sales tax", "cardholder", "merchant id", "auth code", "approval code",
        "card ending", "contactless", "chip read", "tender", "change due",
    ]

    /// Weaker words: common on receipts, but also on menus, invoices,
    /// statements and shop signage. Individually near-worthless; useful in
    /// aggregate, which is why they are counted rather than OR'd.
    private static let weakKeywords = [
        "total", "tax", "cash", "visa", "mastercard", "amex", "debit",
        "credit", "receipt", "invoice", "qty", "thank you", "server",
        "table", "order", "store", "register", "transaction", "vat", "gst",
        "hst", "tip", "gratuity", "purchase", "payment",
    ]

    /// Words that argue *against* a receipt even when receipt-ish words are
    /// present. The research note names the expected false positives —
    /// menus, business cards, whiteboards, bank statements — and these are
    /// what separates them from a till roll.
    private static let negativeKeywords = [
        "statement period", "opening balance", "closing balance",
        "minimum payment", "annual percentage", "account summary",
        "boarding pass", "gate", "linkedin",
        "menu", "appetizers", "entrees", "desserts", "wine list",
        "prescription", "terms and conditions", "privacy policy",
    ]

    /// Scores one photo. Cheap: a handful of substring scans over text that
    /// Vision has already produced.
    static func classify(text: String, hints: AssetHints = AssetHints()) -> Result {
        let haystack = text.lowercased()
        var signals: [Signal] = []

        // Currency-shaped figures, via the same detector the AI cross-check
        // uses (`ReceiptAmountDetector`), so the classifier and the guardrail
        // agree on what "an amount" means. One amount is a price tag; several
        // is a bill.
        let amounts = ReceiptAmountDetector.amounts(in: text)
        switch amounts.count {
        case 0: break
        case 1: signals.append(Signal(name: "1 currency amount", weight: 0.08))
        case 2...3: signals.append(Signal(name: "\(amounts.count) currency amounts", weight: 0.20))
        default: signals.append(Signal(name: "\(amounts.count) currency amounts", weight: 0.28))
        }

        // A date is close to mandatory on a receipt, and is what makes the
        // record useful for tax at all.
        if !ReceiptDateDetector.dates(in: text).isEmpty {
            signals.append(Signal(name: "date", weight: 0.15))
        }

        let strongHits = strongKeywords.filter { matches($0, in: haystack) }
        if !strongHits.isEmpty {
            // Capped: three strong words is already conclusive, and letting
            // this run away would drown the negative signals below.
            let weight = min(0.36, 0.14 * Double(strongHits.count))
            signals.append(Signal(name: strongHits.prefix(3).joined(separator: "/"), weight: weight))
        }

        let weakHits = weakKeywords.filter { matches($0, in: haystack) }
        if !weakHits.isEmpty {
            let weight = min(0.22, 0.045 * Double(weakHits.count))
            signals.append(Signal(name: "\(weakHits.count) receipt words", weight: weight))
        }

        // Word-boundary matched, exactly like the positive keywords above.
        // Raw `contains` let "menu" fire inside longer words and zeroed out a
        // real payment-confirmation receipt during the first eval run — and a
        // negative hit is heavy enough (-0.3) that one spurious match sinks a
        // photo on its own, so this is the list that can least afford a loose
        // match.
        let negativeHits = negativeKeywords.filter { matches($0, in: haystack) }
        if !negativeHits.isEmpty {
            signals.append(Signal(name: "not-a-receipt: \(negativeHits.prefix(2).joined(separator: "/"))",
                                  weight: -0.3 * Double(min(negativeHits.count, 2))))
        }

        // Almost no text at all: a photo of a person, a pet, a landscape.
        // Worth its own signal because it is the single most common thing in
        // a camera roll, and the cheapest to rule out.
        let wordCount = haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        if wordCount < 8 {
            signals.append(Signal(name: "almost no text", weight: -0.35))
        }

        if hints.isScreenshot {
            // Several real receipts in this project's own fixtures are
            // screenshots (emailed confirmations, app order summaries), but
            // so is most of what is in a camera roll — hence small.
            signals.append(Signal(name: "screenshot", weight: 0.05))
        }

        if let ratio = hints.aspectRatio, ratio >= 1.6 {
            signals.append(Signal(name: "tall crop", weight: 0.05))
        }

        let raw = signals.reduce(0.0) { $0 + $1.weight }
        return Result(score: min(1.0, max(0.0, raw)), signals: signals)
    }

    /// Substring match that will not fire inside a longer word — so "tax"
    /// does not hit "taxi" and "total" does not hit "subtotal" (which is
    /// scored separately, and more strongly).
    private static func matches(_ needle: String, in haystack: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}
