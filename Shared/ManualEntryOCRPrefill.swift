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

        // "Largest number on the receipt" is a reasonable last resort, but
        // loyalty/rewards/statement lines are exactly the kind of printed
        // text that reliably beats the real total in magnitude — a
        // "PRO XTRA SPEND" year-to-date figure, a "REWARDS BALANCE", a
        // "POINTS" tally. Drop amounts on lines that read as that kind of
        // statement context before taking the max, so a genuinely
        // labeled-but-differently-worded total ("Balance Due") isn't lost
        // in the process — see `isStatementContextLine` below.
        var candidates: [Double] = []
        for line in text.components(separatedBy: .newlines) where !isStatementContextLine(line) {
            candidates.append(contentsOf: ReceiptAmountDetector.amounts(in: line).compactMap(Double.init))
        }
        guard let largest = candidates.max() else { return nil }
        return String(format: "%.2f", largest)
    }

    /// True when a line's wording suggests its numbers are a loyalty/rewards/
    /// account-statement figure rather than a transaction total — "2026 PRO
    /// XTRA SPEND 07/08: $1,040.81" being the motivating real-world example.
    /// Deliberately narrow (checked only when the "largest amount" fallback
    /// is already in play, never against a labeled Total/Subtotal/Tax line)
    /// and deliberately exempts wording that means "this is the actual amount
    /// owed" even though it shares a trigger word — "Balance Due" must still
    /// count as a total, not get excluded just because it contains "balance".
    private static func isStatementContextLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let statementTriggers = ["pro xtra", "spend", "statement", "rewards", "points", "balance"]
        guard statementTriggers.contains(where: { lower.contains($0) }) else { return false }
        let notActuallyStatement = ["balance due", "year to date", "ytd"]
        return !notActuallyStatement.contains(where: { lower.contains($0) })
    }

    /// Best guess at the receipt date — printed dates go through two cheap,
    /// conservative disambiguation rules (future-date rejection, then
    /// preference for a date paired with a clock time) before falling back
    /// to "only trust this when exactly one date is printed at all."
    ///
    /// Mirrors the caution `ExtractedReceipt.build` and the `.needsDate`
    /// flow in `ReceiptSubmitView` already apply to AI-read dates: silently
    /// picking one of *several* candidate dates (an order date vs. a "valid
    /// through" date, a loyalty-card expiration, etc.) risks writing the
    /// wrong date into a tax record with no signal to the user that it was
    /// ever ambiguous. Zero matches, or matches that stay ambiguous even
    /// after both rules below, return nil, leaving the field at its default
    /// for the user to set by hand themselves — same "don't silently guess"
    /// principle as the AI path's "couldn't read the date" prompt, just
    /// surfaced before saving instead of after.
    ///
    /// Deliberately implemented here rather than in the shared
    /// `ReceiptDateDetector` even though both rules below are receipt-dates
    /// truths in general, not prefill-specific ones. `ReceiptDateDetector`
    /// also backs the AI pipeline's cross-check (`ExtractedReceipt.build`,
    /// via `SubmissionPipeline`), where its job is "does this date the model
    /// reported actually appear on the receipt at all?" — a different
    /// question than "which of several printed dates is the transaction
    /// date?" Teaching the shared detector to filter/rank would change what
    /// that cross-check means (e.g. a model that legitimately read a future
    /// "expires on" date into some other field would no longer be
    /// checkable against it) for a benefit that only matters here, in the
    /// no-AI prefill path. Keeping the selection logic local costs a little
    /// duplication but keeps the shared detector's contract simple: "every
    /// date printed," full stop.
    static func likelyReceiptDate(in text: String) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Rule 1 — reject future dates outright. A receipt's own transaction
        // date can never be after the moment it's being scanned; a "policy
        // expires on", "valid through", or warranty-window date printed on
        // the same receipt can be, and often is, well over a year out. This
        // alone resolves plenty of "several dates printed" receipts without
        // needing rule 2 at all (e.g. a purchase date plus a return-window
        // expiry). Kept here rather than in `ReceiptDateDetector` itself —
        // see the doc comment on this function for why.
        let candidates = ReceiptDateDetector.dates(in: text).filter { $0 <= today }
        if candidates.count == 1 { return candidates[0] }
        guard candidates.count > 1 else { return nil }

        // Rule 2 — among the surviving candidates, prefer one printed right
        // next to a clock time. Point-of-sale systems stamp the actual
        // transaction with both a date and a time on the same line/receipt
        // row ("07/09/26  01:05 PM"); a bare date elsewhere (an account
        // summary window, a loyalty-year figure) usually isn't paired with a
        // time at all. Only acts when it disambiguates cleanly down to a
        // single date — if more than one candidate has a time nearby, or
        // none do, this stays silent and falls through to nil below rather
        // than guess.
        let timeOfDayPattern = #"\d{1,2}:\d{2}(:\d{2})?\s*[AaPp]\.?[Mm]\.?"#
        var datesWithAdjacentTime = Set<Date>()
        for line in text.components(separatedBy: .newlines) {
            guard line.range(of: timeOfDayPattern, options: .regularExpression) != nil else { continue }
            // Only trust a line that prints exactly one date alongside the
            // time — a line with two dates and a time doesn't tell us which
            // date the time belongs to.
            let lineDates = ReceiptDateDetector.dates(in: line)
            guard lineDates.count == 1, let onlyDate = lineDates.first, candidates.contains(onlyDate) else { continue }
            datesWithAdjacentTime.insert(onlyDate)
        }
        if datesWithAdjacentTime.count == 1 { return datesWithAdjacentTime.first }

        // Still genuinely ambiguous — same "don't silently guess" principle
        // as before either rule ran.
        return nil
    }

    /// Best guess at the vendor name.
    ///
    /// Vendor is the hardest of the three fields to get right
    /// deterministically — there's no consistent label like "Total" to
    /// anchor on, and no machine-parseable format like a date. Real-device
    /// testing found the original "first plausible-looking line" heuristic
    /// below confidently picks up a marketing slogan ("How doers get more
    /// done" → "How doers") on receipts that print one above the actual
    /// store name, with nothing about the slogan line itself that
    /// disqualifies it.
    ///
    /// Tries a domain/email match first — see `likelyVendorFromDomain` —
    /// since a business's own email domain is a much stronger, much less
    /// ambiguous brand signal than "which line looks most name-shaped."
    /// Falls back to the line heuristic when no usable domain is printed.
    /// Either way this stays deliberately conservative and returns nil
    /// (leave the field empty for the user to type) rather than risk
    /// confidently prefilling a slogan, a street address, or "Thank you for
    /// shopping with us" as the vendor.
    static func likelyVendorLine(in text: String) -> String? {
        if let fromDomain = likelyVendorFromDomain(in: text) { return fromDomain }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for line in lines where !line.isEmpty {
            if isPlausibleVendorLine(line) { return line }
        }
        return nil
    }

    /// Derives a vendor candidate from an email domain printed on the
    /// receipt (a cashier's or store's `@homedepot.com` address is common on
    /// printed thermal receipts) by taking the registrable part of the
    /// domain and title-casing it — "homedepot.com" → "Homedepot".
    ///
    /// Deliberately does NOT attempt real word-segmentation ("Home Depot"
    /// from "homedepot") — that needs a dictionary or brand list to do
    /// generally, and hardcoding known brand names is exactly the kind of
    /// special-casing this file avoids elsewhere. "Homedepot" is a worse
    /// string than "Home Depot" but a strictly better one than "How doers":
    /// it's still unambiguously identifiable and editable, whereas the
    /// slogan fragment reads as a plausible-but-wrong business name.
    ///
    /// Skips common personal-email providers (gmail, yahoo, ...) — a
    /// customer's own email sometimes appears in loyalty-program context on
    /// a receipt, and "Gmail" would be a strictly worse guess than falling
    /// through to the line heuristic or nil.
    private static func likelyVendorFromDomain(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"[A-Za-z0-9_.+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})"#
        ) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let domainRange = Range(match.range(at: 1), in: text) else { return nil }

        let labels = String(text[domainRange]).lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        // Drop a leading generic subdomain label ("www", "mail", "shop", ...)
        // when there's a real registrable domain underneath it — "mail
        // .homedepot.com" should still yield "homedepot", not "mail".
        var registrableCandidates = labels
        let genericSubdomains: Set<String> = ["www", "mail", "shop", "support", "info", "email", "receipts", "orders", "order"]
        if registrableCandidates.count > 2, genericSubdomains.contains(registrableCandidates[0]) {
            registrableCandidates.removeFirst()
        }
        guard registrableCandidates.count >= 2 else { return nil }

        // Second-to-last label is the registrable name for the vast
        // majority of real-world domains (skips the TLD at the end, and any
        // remaining subdomain labels before it) — not a full public-suffix
        // implementation, but more than sufficient for "@vendor.com" style
        // receipt addresses.
        let registrable = registrableCandidates[registrableCandidates.count - 2]
        guard registrable.count >= 3 else { return nil }

        let personalEmailProviders: Set<String> = [
            "gmail", "yahoo", "hotmail", "outlook", "icloud", "aol",
            "protonmail", "live", "msn", "comcast", "verizon",
        ]
        guard !personalEmailProviders.contains(registrable) else { return nil }

        return registrable.prefix(1).uppercased() + registrable.dropFirst()
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
