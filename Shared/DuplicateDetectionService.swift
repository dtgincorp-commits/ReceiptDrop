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
                guard abs(dateA.timeIntervalSince(dateB)) <= nearbyDateWindow else { continue }
                guard BillEvalScorer.namesMatch(a.vendor, b.vendor) else { continue }
                let confidence: Pair.Confidence = sameDate ? .possibleDifferentAmount
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
