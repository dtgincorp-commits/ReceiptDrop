import Foundation

/// Deterministic, on-device best-guesses for the three manual-entry fields
/// on `ReceiptSubmitView` (vendor / amount / work date) when no AI provider
/// is configured (`ExtractionSettings.aiConfigured == false`). The view OCRs
/// the attachment with `VisionOCRService` and hands the recognized text to
/// the functions below.
///
/// Deliberately reuses the exact detectors the AI pipeline already relies on
/// to cross-check a *model's* answer — `BillTotalsParser` (grand-total
/// selection), `ReceiptAmountDetector` (every currency-shaped figure on the
/// receipt) and `ReceiptDateDetector` (every printed date) — rather than
/// inventing a second, slightly different notion of "the total" or "the
/// date." That also means the no-AI banner's claim ("found by simple
/// on-device text matching") is literally true, not aspirational.
///
/// Every function here is a pure `String -> Guess?` so it can be unit
/// tested against realistic OCR text without running Vision or touching a
/// real image — see `ManualEntryOCRPrefillTests`.
enum ManualEntryOCRPrefill {

    /// Best guess at the grand total.
    ///
    /// Tries `BillTotalsParser` first — it already implements the
    /// convention real receipts follow: subtotal and tax lines come first,
    /// and the final "Total" / "Grand Total" / "Amount Due" label is always
    /// the *last* such labeled line. That beats "take the largest number on
    /// the receipt": a single expensive line item, or a tip line added
    /// after the total, can easily print a bigger figure than the actual
    /// total.
    ///
    /// Falls back to the largest currency-shaped figure `ReceiptAmountDetector`
    /// finds only when no labeled total line was found at all (e.g. OCR
    /// merged the "Total" label onto a different visual line than its
    /// number, which flat OCR text — no layout info — can't always avoid).
    /// On an unlabeled receipt, the grand total is still very often simply
    /// the largest number printed.
    static func likelyGrandTotal(in text: String) -> String? {
        let labeled = BillTotalsParser.extractTotals(from: text).total
        if !labeled.isEmpty { return labeled }

        let candidates = ReceiptAmountDetector.amounts(in: text).compactMap(Double.init)
        guard let largest = candidates.max() else { return nil }
        return String(format: "%.2f", largest)
    }

    /// Best guess at the receipt date — only returned when exactly one date
    /// is printed anywhere on the receipt.
    ///
    /// Mirrors the caution `ExtractedReceipt.build` and the `.needsDate`
    /// flow in `ReceiptSubmitView` already apply to AI-read dates: silently
    /// picking one of *several* candidate dates (an order date vs. a "valid
    /// through" date, a loyalty-card expiration, etc.) risks writing the
    /// wrong date into a tax record with no signal to the user that it was
    /// ever ambiguous. Zero or multiple matches both return nil, leaving
    /// the field at its default for the user to set by hand themselves —
    /// same "don't silently guess" principle as the AI path's "couldn't
    /// read the date" prompt, just surfaced before saving instead of after.
    static func likelyReceiptDate(in text: String) -> Date? {
        let dates = ReceiptDateDetector.dates(in: text)
        return dates.count == 1 ? dates[0] : nil
    }

    /// Best guess at the vendor name: the first OCR line that plausibly
    /// reads as a business name rather than an amount, date, phone number,
    /// address, or receipt boilerplate.
    ///
    /// Vendor is the hardest of the three fields to get right
    /// deterministically — there's no consistent label like "Total" to
    /// anchor on, and no machine-parseable format like a date. This stays
    /// deliberately conservative: a line only qualifies after clearing
    /// several cheap disqualifiers below, and returns nil (leave the field
    /// empty for the user to type) rather than risk confidently prefilling
    /// a street address or "Thank you for shopping with us" as the vendor.
    static func likelyVendorLine(in text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for line in lines where !line.isEmpty {
            if isPlausibleVendorLine(line) { return line }
        }
        return nil
    }

    private static func isPlausibleVendorLine(_ line: String) -> Bool {
        // Needs a real run of letters — rules out amounts, phone numbers,
        // order/invoice numbers, and separator/punctuation-only lines.
        let letters = line.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }

        // A date or amount that happens to occupy its own line isn't a
        // vendor name even though it may contain letters (e.g. "3:45 PM",
        // "AUG 18, 2026").
        if ReceiptDateDetector.dates(in: line).count == 1 { return false }
        if !ReceiptAmountDetector.amounts(in: line).isEmpty { return false }

        // Street addresses, phone numbers, and receipt metadata lines are
        // digit-heavy relative to their letter count — a real vendor name
        // almost never is. ("7-Eleven" is a rare miss this heuristic
        // accepts in exchange for avoiding far more common false positives
        // like "123 Main St, Springfield IL 62701".)
        let digits = line.filter { $0.isNumber }
        if digits.count > letters.count { return false }

        // A line that *starts* with a number followed by whitespace is a
        // street address ("123 Main St") often enough — and never a vendor
        // name — that it's worth its own check even when the digit-heavy
        // test above doesn't catch it (a short house number next to a long
        // street name can still have more letters than digits).
        if line.range(of: #"^\d+\s"#, options: .regularExpression) != nil { return false }

        // Common boilerplate that shows up as the first non-empty OCR line
        // on many receipts but is never the business name.
        let lower = line.lowercased()
        let boilerplatePrefixes = [
            "receipt", "invoice", "order #", "order#", "order number",
            "tel:", "phone", "www.", "http", "thank you", "welcome to",
            "customer copy", "merchant copy",
        ]
        if boilerplatePrefixes.contains(where: { lower.hasPrefix($0) }) { return false }

        return true
    }
}
