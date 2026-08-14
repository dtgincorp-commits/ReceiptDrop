import Foundation

/// Deterministic amount extraction from raw receipt text — no AI, just a
/// regex over currency-shaped figures. Used as a cross-check on what the AI
/// reports: a language model told to find a grand total that isn't printed
/// (a blank "TOTAL AMOUNT" line, tip left unfilled) can fabricate a
/// plausible-looking number rather than admitting none was found — the same
/// failure mode `ReceiptDateDetector` catches for dates. This lets a caller
/// verify the model's reported amount actually appears somewhere on the
/// receipt before trusting it.
enum ReceiptAmountDetector {
    /// Every currency-shaped amount in `text`, normalized to a 2-decimal
    /// string ("142.51") so callers can compare by simple set membership —
    /// "142.5" and "142.50" match the same printed figure.
    static func amounts(in text: String) -> Set<String> {
        // Deliberately not anchored to end-of-line (unlike BillTotalsParser
        // .trailingAmount, which pulls an amount off a specific labeled
        // line) — this scans the whole receipt for every figure that looks
        // like money, wherever it sits.
        //
        // Requires either a leading "$" or a decimal point to count as
        // money — a bare integer ("15", "972", "17") is just as likely to
        // be a sequence number, batch number, or invoice number on a card
        // receipt, and treating those as amounts would create a
        // false-negative risk: a fabricated total that happens to collide
        // with an unrelated integer would wrongly look "printed on the
        // receipt." Verified empirically against a real card receipt (SEQ
        // #, Batch #, INVOICE, Approval Code lines) before landing this.
        let pattern = #"\$\s*\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d{1,3}(?:,\d{3})*\.\d{1,2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let fullRange = NSRange(text.startIndex..., in: text)
        var results = Set<String>()
        for match in regex.matches(in: text, options: [], range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = text[range]
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let value = Double(raw) else { continue }
            results.insert(String(format: "%.2f", value))
        }
        return results
    }
}
