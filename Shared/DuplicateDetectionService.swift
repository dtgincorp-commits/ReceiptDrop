import Foundation

/// Finds receipts that look like duplicates of each other. Two independent
/// signals, either of which is enough to flag a pair — never both required:
///
/// 1. Same printed date and amount. Deliberately does NOT require vendor to
///    match: vendor is AI-extracted, so the identical physical receipt
///    scanned twice (or re-scanned after switching providers — Claude vs.
///    Gemini vs. Azure routinely disagree on capitalization/suffix for the
///    same business) can produce two different vendor strings. Requiring an
///    exact match there would silently miss exactly the duplicates this
///    exists to catch, so vendor only ranks confidence here, never gates it.
/// 2. Matching vendor and a work date within a few days — with NO
///    requirement that the amount also matches. Two earlier, narrower
///    versions of this signal each required one of (date, amount) to match
///    exactly while letting the other drift; a real receipt (same physical
///    bill, scanned once from a phone screenshot and once from the paper
///    itself) had BOTH fields come out slightly different between the two
///    scans — one day off on the date, and a different total (tax/tip) —
///    which satisfied neither narrower signal. Vendor is the one anchor
///    proven stable enough to gate on here; date and amount are both
///    allowed to disagree. Weaker signal than 1 (a nearby date could
///    genuinely be a separate visit to the same place), so it's labeled
///    distinctly rather than "likely," with the label reflecting exactly
///    which field(s) actually differ.
///
///    One exception widens (never removes) the date part of (2): if the two
///    amounts differ by a plausible tip (see `isTipShaped`), the dates only
///    have to be within the wider `tipDateWindow` rather than
///    `nearbyDateWindow`. That covers the same bill entered twice — once
///    before the tip was written in, once after — where the work date on one
///    copy was read wrong and landed just outside the normal window.
///
///    This exception used to waive the date check entirely, which turned out
///    to be far too loose in the field: two genuinely unrelated Home Depot
///    receipts (Costa Mesa, 2026-07-07, $417.55 and Laguna Niguel,
///    2026-08-19, $333.63 — different stores, different cards, no shared
///    line items) were flagged "One May Include Tip" purely because
///    417.55/333.63 = 1.2515 lands inside `tipRatioRange`. With the date
///    requirement gone, any two same-vendor receipts sitting 10–30% apart
///    paired up at unlimited distance in time — extremely common at a store
///    someone shops at repeatedly. Two independent guards now bound it:
///    the finite `tipDateWindow`, and a vendor-type check (see
///    `tipPlausible`) that suppresses the tip signal entirely at businesses
///    where nobody tips. Vendor name still gates it as before.
///
/// Amount comparisons throughout are numeric, not exact-string — "245.60"
/// and "245.6" are the same amount, but different extraction passes don't
/// always agree on trailing-zero formatting.
///
/// Never deletes anything itself — flags candidates for a human to look at
/// the actual photos and decide, same as the existing submit-time duplicate
/// check (`SubmissionPipeline.run`) treats a match as "stop and ask," not
/// "silently drop."
enum DuplicateDetectionService {
    struct Pair: Identifiable {
        let id: String
        let first: HistoryEntry
        let second: HistoryEntry
        let confidence: Confidence

        enum Confidence: String {
            case likely = "Likely Duplicate"
            case possibleDifferentVendor = "Possible Duplicate — Different Vendor"
            case possibleDifferentAmount = "Possible Duplicate — Different Amount (check tax/tip)"
            case possibleDifferentDate = "Possible Duplicate — Check the Date"
            case possibleDifferentDateAndAmount = "Possible Duplicate — Check the Date and Amount"
            case possibleTipAdded = "Possible Duplicate — One May Include Tip"
        }
    }

    /// Entries with an empty/unreadable work date (the app flags these
    /// elsewhere as "Date unreadable, defaulted to today") can't be keyed by
    /// date, so they're matched on amount alone within this window of each
    /// other's scan time — wide enough to catch "scanned it twice in a row"
    /// without pairing unrelated same-amount receipts scanned weeks apart.
    private static let undatedWindow: TimeInterval = 24 * 60 * 60

    /// How far apart two work dates can be and still trigger Signal 2 — wide
    /// enough to catch an AI defaulting to "today" when the real date was a
    /// day or two earlier, without pairing up unrelated visits weeks apart.
    private static let nearbyDateWindow: TimeInterval = 3 * 24 * 60 * 60

    /// How far apart two work dates can be when the amounts are tip-shaped —
    /// wider than `nearbyDateWindow` because the motivating Water Grill case
    /// had a misread work date landing 4 days apart (one day past the normal
    /// window), but finite, unlike the unbounded waiver this replaced. 14
    /// days leaves comfortable margin over that 4-day case while rejecting
    /// the 43-day Home Depot false positive described in the type comment.
    private static let tipDateWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Ratio band for "these are the same bill, one of them tipped." Covers
    /// the realistic US restaurant range — 10%, 15%, 18%, 20%, 25% all land
    /// inside it, and the 1.30 ceiling absorbs a generous tipper or a tip
    /// calculated on the tax-inclusive total. Deliberately not wider:
    /// past ~30% this starts colliding with genuinely separate visits to the
    /// same restaurant (a $100 dinner and a $140 dinner are 40% apart and
    /// are not the same bill).
    ///
    /// Note this band is narrow in ratio but not remotely rare in practice —
    /// two unrelated Home Depot runs came in at $417.55 and $333.63 (ratio
    /// 1.2515, squarely inside the band). That's why the ratio alone was
    /// never enough to waive the date check, and why `tipPlausible` also has
    /// to agree the vendor is somewhere a tip could exist at all.
    private static let tipRatioRange: ClosedRange<Double> = 1.10...1.30

    /// Vendor types where a tip is simply not part of the transaction, so a
    /// tip-shaped ratio between two receipts there carries no information —
    /// it's just two different-sized shopping trips. Gas, groceries,
    /// hardware, retail, medical, utilities, auto repair and professional
    /// services all bill a fixed amount; the Home Depot false positive that
    /// motivated this was `hardware_home_improvement`. Restaurant, lodging
    /// and entertainment are deliberately absent — tipping is real at all
    /// three.
    private static let nonTippingVendorTypes: Set<VendorType> = [
        .gasStation, .grocery, .hardwareHomeImprovement, .retail,
        .medical, .utilities, .autoRepair, .professionalServices,
    ]

    /// Whether the tip signal is allowed for this pair. Deliberately
    /// asymmetric: it suppresses only when we POSITIVELY know a vendor type
    /// that doesn't tip. `VendorType.from` returns nil for anything
    /// unrecognized — an empty string (manual entries and everything saved
    /// before the field existed), or a user-defined custom type from
    /// `CustomVendorTypeStore` ("Tiki Bar" tips; we can't know) — and nil,
    /// like `.other`, allows the signal. Suppressing on unknown types would
    /// silently switch the tip rule off for the entire pre-existing history,
    /// which is the opposite of the narrowing intended here. Either entry
    /// being a known non-tipping type is enough to suppress.
    private static func tipPlausible(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        for entry in [a, b] {
            if let type = VendorType.from(entry.vendorType), nonTippingVendorTypes.contains(type) {
                return false
            }
        }
        return true
    }

    /// True when the two amounts differ by a plausible tip. Direction is
    /// deliberately NOT constrained to "the later receipt is the larger one":
    /// in the real case this was built for, the *earlier* work date carried
    /// the with-tip total ($342.39 on Jul 26) and the later one the pre-tip
    /// total ($297.39 on Jul 30) — a direction rule would have rejected the
    /// actual duplicate it exists to catch. Ordering of scans and dates is
    /// too unreliable here; the ratio itself is the signal.
    ///
    /// The ratio is only ever half the test — callers must also check the
    /// pair is inside `tipDateWindow` and passes `tipPlausible`, since a
    /// ratio in this band happens routinely between unrelated receipts.
    private static func isTipShaped(_ a: String, _ b: String) -> Bool {
        guard let x = Double(a), let y = Double(b), x > 0, y > 0 else { return false }
        let ratio = max(x, y) / min(x, y)
        return tipRatioRange.contains(ratio)
    }

    static func findPairs(in entries: [HistoryEntry]) -> [Pair] {
        var dated: [String: [HistoryEntry]] = [:]
        var undated: [HistoryEntry] = []
        for entry in entries {
            if entry.workDate.isEmpty {
                undated.append(entry)
            } else {
                dated[entry.workDate + "|" + normalizedAmountKey(entry.amount), default: []].append(entry)
            }
        }

        var pairs: [Pair] = []

        // Signal 1: same date + same amount.
        for group in dated.values where group.count >= 2 {
            pairs.append(contentsOf: allPairs(in: group))
        }

        let undatedByAmount = Dictionary(grouping: undated) { normalizedAmountKey($0.amount) }
        for group in undatedByAmount.values where group.count >= 2 {
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            for i in sorted.indices {
                for j in (i + 1)..<sorted.count
                where sorted[j].timestamp.timeIntervalSince(sorted[i].timestamp) <= undatedWindow {
                    pairs.append(makePair(sorted[i], sorted[j]))
                }
            }
        }

        // Signal 2: matching vendor + date within a few days, amount free
        // to differ or match. Not bucketed by amount (unlike the two
        // signals this replaced) since amount is no longer a gate — pairwise
        // over every dated entry, which is fine at personal-receipt-history
        // scale (this mirrors Signal 1's existing all-pairs-in-a-group
        // approach; neither has ever needed a size cap in practice).
        let datedWithParsedDate: [(entry: HistoryEntry, date: Date)] = entries.compactMap { entry in
            guard !entry.workDate.isEmpty, let date = parseWorkDate(entry.workDate) else { return nil }
            return (entry, date)
        }
        for i in datedWithParsedDate.indices {
            for j in (i + 1)..<datedWithParsedDate.count {
                let (a, dateA) = datedWithParsedDate[i]
                let (b, dateB) = datedWithParsedDate[j]
                let sameDate = a.workDate == b.workDate
                let sameAmount = normalizedAmountKey(a.amount) == normalizedAmountKey(b.amount)
                if sameDate && sameAmount { continue } // Signal 1 already covers this exact case
                // The date requirement stands as before, with one specific
                // exception: a tip-shaped amount difference at a vendor where
                // tipping actually happens buys a wider date window — enough
                // to catch the same bill re-entered with the tip filled in
                // when the work date on one copy was read wrong (a 4-day gap,
                // one day past the normal window). It buys a WIDER window,
                // not exemption from one: waiving the date check outright
                // paired two unrelated Home Depot receipts 43 days apart.
                // Kept as one merged condition rather than a separate pass so
                // a pair that satisfies both can't be flagged twice.
                let gap = abs(dateA.timeIntervalSince(dateB))
                let datesClose = gap <= nearbyDateWindow
                let tipShaped = isTipShaped(a.amount, b.amount)
                    && gap <= tipDateWindow
                    && tipPlausible(a, b)
                guard datesClose || tipShaped else { continue }
                guard BillEvalScorer.namesMatch(a.vendor, b.vendor) else { continue }
                // Tip takes priority over the generic labels — it explains
                // *why* the amounts differ, which is more actionable than
                // just reporting that they do.
                let confidence: Pair.Confidence = tipShaped ? .possibleTipAdded
                    : sameDate ? .possibleDifferentAmount
                    : sameAmount ? .possibleDifferentDate
                    : .possibleDifferentDateAndAmount
                pairs.append(Pair(id: "\(a.id)-\(b.id)", first: a, second: b, confidence: confidence))
            }
        }

        // Stable sort keeps likely-confidence pairs on top without
        // otherwise reordering — Array.sorted is a stable sort in Swift.
        return pairs.sorted { $0.confidence == .likely && $1.confidence != .likely }
    }

    private static func allPairs(in group: [HistoryEntry]) -> [Pair] {
        var result: [Pair] = []
        for i in group.indices {
            for j in (i + 1)..<group.count {
                result.append(makePair(group[i], group[j]))
            }
        }
        return result
    }

    private static func makePair(_ a: HistoryEntry, _ b: HistoryEntry) -> Pair {
        // Reuses the fuzzy vendor matcher already built for the bill-eval
        // harness (normalize → prefix → 50% token overlap) — same problem
        // (comparing AI-extracted names that differ only in formatting),
        // no reason to duplicate the logic.
        let confidence: Pair.Confidence = BillEvalScorer.namesMatch(a.vendor, b.vendor) ? .likely : .possibleDifferentVendor
        return Pair(id: "\(a.id)-\(b.id)", first: a, second: b, confidence: confidence)
    }

    /// Groups/compares amounts by numeric value, not raw text — "245.60"
    /// and "245.6" are the same amount, but different extraction passes
    /// (or a manual edit) don't always agree on trailing-zero formatting.
    /// Falls back to the raw string for anything that isn't a plain number,
    /// so malformed amounts still group with an identical malformed string
    /// rather than silently dropping out of matching entirely.
    private static func normalizedAmountKey(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        return String(format: "%.2f", value)
    }

    private static func parseWorkDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        return formatter.date(from: raw)
    }
}
