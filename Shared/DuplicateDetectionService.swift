import Foundation

/// Finds receipts that look like duplicates of each other — same printed
/// date and amount. Deliberately does NOT require vendor to match: vendor is
/// AI-extracted, so the identical physical receipt scanned twice (or
/// re-scanned after switching providers — Claude vs. Gemini vs. Azure
/// routinely disagree on capitalization/suffix for the same business) can
/// produce two different vendor strings. Requiring an exact match there
/// would silently miss exactly the duplicates this exists to catch, so
/// vendor is used only to rank confidence, never to gate the match. Never
/// deletes anything itself — flags candidates for a human to look at the
/// actual photos and decide, same as the existing submit-time duplicate
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
            case possible = "Possible Duplicate — Different Vendor"
        }
    }

    /// Entries with an empty/unreadable work date (the app flags these
    /// elsewhere as "Date unreadable, defaulted to today") can't be keyed by
    /// date, so they're matched on amount alone within this window of each
    /// other's scan time — wide enough to catch "scanned it twice in a row"
    /// without pairing unrelated same-amount receipts scanned weeks apart.
    private static let undatedWindow: TimeInterval = 24 * 60 * 60

    static func findPairs(in entries: [HistoryEntry]) -> [Pair] {
        var dated: [String: [HistoryEntry]] = [:]
        var undated: [HistoryEntry] = []
        for entry in entries {
            if entry.workDate.isEmpty {
                undated.append(entry)
            } else {
                dated[entry.workDate + "|" + entry.amount, default: []].append(entry)
            }
        }

        var pairs: [Pair] = []
        for group in dated.values where group.count >= 2 {
            pairs.append(contentsOf: allPairs(in: group))
        }

        let undatedByAmount = Dictionary(grouping: undated, by: \.amount)
        for group in undatedByAmount.values where group.count >= 2 {
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            for i in sorted.indices {
                for j in (i + 1)..<sorted.count
                where sorted[j].timestamp.timeIntervalSince(sorted[i].timestamp) <= undatedWindow {
                    pairs.append(makePair(sorted[i], sorted[j]))
                }
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
        let confidence: Pair.Confidence = BillEvalScorer.namesMatch(a.vendor, b.vendor) ? .likely : .possible
        return Pair(id: "\(a.id)-\(b.id)", first: a, second: b, confidence: confidence)
    }
}
