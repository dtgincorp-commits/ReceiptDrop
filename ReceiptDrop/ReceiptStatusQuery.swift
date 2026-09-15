import Foundation

/// Recognises search queries that name one of the three fixed statuses this
/// screen already tracks — "needs review", "duplicates", "queued" — so the
/// search field can answer them with the exact same banner the main list
/// already shows for that status, instead of returning "No Matches".
///
/// This is deliberately NOT part of `QueryParseResult` / the AI's search
/// schema. That schema exists to turn open-ended, arbitrarily-worded claims
/// ("restaurants over $100 last month") into structured filters, which is a
/// job only a model can do. These three concepts are the opposite: a fixed,
/// small vocabulary the app itself defines, whose wording doesn't vary by
/// receipt or user. Routing them through a model round-trip would add
/// latency, an API cost, and a chance of misparsing exact words a plain
/// substring match gets right every time — and this codebase already prefers
/// a deterministic read over model inference wherever one is available (see
/// the vendor-type equality check in `ReceiptsView.semanticResults`, which
/// exists for the same reason).
///
/// False positives are tolerated on purpose. A vendor genuinely named, say,
/// "Peer Review Inc" also matches `needsReview` here. That's harmless: the
/// banner this produces is shown IN ADDITION to the normal search results,
/// never in place of them, so a coincidental match adds an extra (ignorable)
/// banner rather than hiding anything the user was looking for.
enum ReceiptStatusQuery {
    enum Intent: CaseIterable {
        case needsReview
        case duplicates
        case queued
    }

    /// Longest phrases first within each intent, so stripping "needs review"
    /// doesn't leave a stray "needs" (or "review") behind for the plain-text
    /// search to choke on.
    private static let phrases: [Intent: [String]] = [
        .needsReview: ["needs reviews", "needs review", "need reviews", "need review",
                       "needing review", "to review", "flagged", "review"],
        .duplicates: ["duplicates", "duplicate", "dupes", "dupe"],
        .queued: ["queued", "queue", "pending", "processing", "waiting", "overnight"],
    ]

    /// Every status intent named anywhere in `query`, case-insensitive,
    /// matched by substring containment.
    static func intents(in query: String) -> Set<Intent> {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        var found: Set<Intent> = []
        for intent in Intent.allCases {
            if phrases[intent]!.contains(where: { normalized.contains($0) }) {
                found.insert(intent)
            }
        }
        return found
    }

    /// `query` with every matched status phrase removed and the result
    /// trimmed. An empty return means the query was ONLY a status request —
    /// the caller's signal to skip the AI search entirely rather than firing
    /// it on the empty remainder.
    static func strippingIntents(from query: String) -> String {
        var normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for intent in Intent.allCases {
            for phrase in phrases[intent]! {
                normalized = normalized.replacingOccurrences(of: phrase, with: "")
            }
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
