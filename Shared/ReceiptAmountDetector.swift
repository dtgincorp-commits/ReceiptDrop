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
    ///
    /// Locale-agnostic by design, and deliberately independent of the
    /// user's `AppCurrency` display setting: a receipt's printed number
    /// format depends on where the *receipt* was printed, not on where the
    /// phone is or what currency the user chose to display. A US traveler
    /// scanning a German receipt ("1.234,56") needs it parsed correctly
    /// regardless of any app setting — see `separatorNormalized(_:)` below.
    static func amounts(in text: String) -> Set<String> {
        // Deliberately not anchored to end-of-line (unlike BillTotalsParser
        // .trailingAmount, which pulls an amount off a specific labeled
        // line) — this scans the whole receipt for every figure that looks
        // like money, wherever it sits.
        //
        // Requires either a leading currency symbol or at least one
        // separator (comma or period) to count as money — a bare integer
        // ("15", "972", "17") is just as likely to be a sequence number,
        // batch number, or invoice number on a card receipt, and treating
        // those as amounts would create a false-negative risk: a fabricated
        // total that happens to collide with an unrelated integer would
        // wrongly look "printed on the receipt." Verified empirically
        // against a real card receipt (SEQ #, Batch #, INVOICE, Approval
        // Code lines) before landing this, and again when generalizing
        // beyond US "$"/"." formatting — the bare-integer rejection must
        // survive that change.
        //
        // Each grouping cluster after the first digit run is 2 OR 3 digits
        // (not just 3), so Indian lakh/crore grouping extracts as one token
        // instead of being split apart: "1,23,456.78" (lakh) and
        // "1,23,45,678.90" (crore) both group in 2s once past the first
        // cluster, unlike Western thousands-grouping which is always 3.
        // Verified against both before landing this, alongside the
        // bare-integer regression above — a looser grouping count is exactly
        // the kind of change that could accidentally let a sequence number
        // through.
        let pattern = #"[$€£₹¥]\s*\d{1,3}(?:[.,]\d{2,3})*(?:[.,]\d{1,2})?|\d{1,3}(?:[.,]\d{2,3})*[.,]\d{1,2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let fullRange = NSRange(text.startIndex..., in: text)
        var results = Set<String>()
        for match in regex.matches(in: text, options: [], range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = AppCurrency.stripKnownSymbols(from: String(text[range]))
                .trimmingCharacters(in: .whitespaces)
            guard let value = separatorNormalized(raw) else { continue }
            results.insert(String(format: "%.2f", value))
        }
        return results
    }

    /// Turns a raw digit-plus-separator string (symbol already stripped)
    /// into its numeric value, without assuming which of "," and "." is the
    /// decimal separator — that depends on where the receipt was printed,
    /// not on the device's locale. "Last separator wins": whichever
    /// character appears closest to the end of the string is read as the
    /// decimal point.
    static func separatorNormalized(_ raw: String) -> Double? {
        let hasComma = raw.contains(",")
        let hasPeriod = raw.contains(".")

        var normalized = raw
        if hasComma, hasPeriod {
            // Both present — the last one is the decimal separator, the
            // other is grouping.
            // "1.234,56" -> "1234.56"   ·   "1,234.56" -> "1234.56"
            // "1,23,456.78" -> "123456.78" (lakh grouping)
            // "1,23,45,678.90" -> "12345678.90" (crore grouping — any number
            // of grouping separators is fine here, since every one of them
            // gets stripped regardless of how many 2-digit clusters there are)
            let lastComma = raw.range(of: ",", options: .backwards)!.lowerBound
            let lastPeriod = raw.range(of: ".", options: .backwards)!.lowerBound
            let decimalIsComma = lastComma > lastPeriod
            let groupingChar: Character = decimalIsComma ? "." : ","
            let decimalChar: Character = decimalIsComma ? "," : "."
            normalized = String(raw.filter { $0 != groupingChar })
            normalized = normalized.replacingOccurrences(of: String(decimalChar), with: ".")
        } else if hasComma || hasPeriod {
            let separator: Character = hasComma ? "," : "."
            let count = raw.filter { $0 == separator }.count
            if count > 1 {
                // Only one kind of separator, appearing more than once —
                // can only be grouping ("1.234.567" -> 1234567).
                normalized = String(raw.filter { $0 != separator })
            } else {
                // Exactly one separator. Three digits after it reads as
                // grouping ("1,234" -> 1234); one or two digits reads as a
                // decimal point ("342,39" -> 342.39, "12.5" -> 12.5).
                //
                // "1.234" is the one genuinely ambiguous case here — it
                // could be €1,234 (grouping) or $1.234 (three decimal
                // places). Treated as grouping: three decimal places on a
                // receipt total is far rarer than European thousands
                // grouping, so that's the safer default.
                let digitsAfter = raw.split(separator: separator).last?.count ?? 0
                if digitsAfter == 3 {
                    normalized = String(raw.filter { $0 != separator })
                } else {
                    normalized = raw.replacingOccurrences(of: String(separator), with: ".")
                }
            }
        }
        return Double(normalized)
    }
}
