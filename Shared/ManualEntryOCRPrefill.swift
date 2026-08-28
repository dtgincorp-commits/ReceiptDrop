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

    /// Why the manual-entry path does or doesn't have a real receipt date —
    /// the difference between "we read one off the paper" and each distinct
    /// reason we couldn't, so the confirmation prompt in `ReceiptSubmitView`
    /// can say which happened instead of a single vague "couldn't read it."
    ///
    /// The three failure cases are genuinely distinguishable here (unlike on
    /// the AI path, where a provider returning an empty string can't tell us
    /// whether the receipt had no date or the model just failed to find one),
    /// because this path owns both halves of the read: whether Vision
    /// recognized any text at all, and whether `ReceiptDateDetector` found
    /// any date-shaped text in it.
    enum DateResolution: Equatable {
        /// A date was read off the receipt with enough confidence to use it.
        case found(Date)
        /// OCR came back empty — a blurry, dark, or non-textual image. We
        /// know nothing about what the receipt says, including whether it
        /// prints a date, so this can't claim "no date printed."
        case noTextRecognized
        /// Text was recognized and contains nothing date-shaped at all. The
        /// least alarming case: many receipts genuinely don't print a date.
        case noDatePrinted
        /// Dates *are* printed but none could be picked as the transaction
        /// date — several candidates with nothing to disambiguate them, or
        /// only future-dated ones (a "valid through" / return-window date).
        /// The most alarming case: the receipt's real date is very likely on
        /// the paper and we're about to write a different one.
        case ambiguous(printedDates: Int)
    }

    /// Classifies what the deterministic date read produced, as the
    /// `DateResolution` above. `text` is nil or empty when Vision recognized
    /// nothing (or the attachment couldn't be rendered for OCR at all).
    ///
    /// Pure by design — `ReceiptSubmitView` decides whether to prompt purely
    /// from this value, so the decision is unit-testable without Vision, an
    /// image, or a running view.
    static func resolveDate(in text: String?) -> DateResolution {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noTextRecognized
        }
        if let date = likelyReceiptDate(in: text) { return .found(date) }
        let printed = ReceiptDateDetector.dates(in: text)
        return printed.isEmpty ? .noDatePrinted : .ambiguous(printedDates: printed.count)
    }

    /// "Would saving right now silently write today's date into a tax
    /// record?" — the single question the confirmation prompt exists to
    /// answer, kept pure and separate from the view that asks it.
    ///
    /// `resolution` is nil when OCR hasn't finished (or never ran): treated
    /// as needing confirmation, since the date field is still sitting at its
    /// `Date()` default with nothing having read the receipt. `userEditedDate`
    /// is true once the user has touched the date picker themselves — a date
    /// a human chose is not a silent fallback, whatever OCR did or didn't
    /// find, so it's never second-guessed.
    static func needsDateConfirmation(resolution: DateResolution?, userEditedDate: Bool) -> Bool {
        if userEditedDate { return false }
        guard let resolution else { return true }
        if case .found = resolution { return false }
        return true
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
    ///
    /// Falls back to a bare `domain.tld` match (no `@` required) when the
    /// email pattern finds nothing. OCR frequently mangles the single `@`
    /// character an email match depends on — real-device testing on a Home
    /// Depot receipt read `ALEXANDER_S_PULA@HOMEDEPOT.COM` as
    /// `PULACHOMEDEPÖT.COM`, silently dropping the `@` entirely, which made
    /// the email-only version of this function find nothing and fall
    /// through to the line heuristic, which then confidently prefilled the
    /// customer's own handwriting from elsewhere on the receipt. The same
    /// receipt still prints its domain in the clear a few lines down
    /// ("Learn more at homedepot.com/credit"), so a bare-domain fallback
    /// recovers the correct vendor.
    private static func likelyVendorFromDomain(in text: String) -> String? {
        // Preferred path: a literal "user@domain.tld" is the stronger
        // signal — an email address is unambiguously the business's own
        // domain, never a third-party URL mentioned in marketing copy.
        if let emailRegex = try? NSRegularExpression(
            pattern: #"[A-Za-z0-9_.+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})"#
        ) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = emailRegex.firstMatch(in: text, range: range),
               let domainRange = Range(match.range(at: 1), in: text),
               let name = registrableVendorName(fromDomain: String(text[domainRange])) {
                return name
            }
        }

        // Fallback: no usable "@" survived OCR. Scan for every bare
        // domain-shaped token (not just the first) — collecting all of them
        // is what lets the disambiguation below tell a genuine merchant
        // domain apart from an OCR fusion artifact; taking only the first
        // match in reading order, as this used to do, is exactly what let
        // the low-light Home Depot photo through: OCR read the receipt's
        // "@" as an "S" instead of dropping it, fusing the cashier's
        // username onto the front of the real domain
        // ("PULASHOMEDEPOT.COM"), which looks like a perfectly valid domain
        // and sits *above* the clean "homedepot.com" printed in the
        // footer — so "first in reading order" picked the corrupted one.
        guard let domainRegex = try? NSRegularExpression(
            pattern: #"\b((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b"#
        ) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        var candidates: [String] = [] // lowercase registrable names, in reading order, duplicates kept (for frequency)
        for match in domainRegex.matches(in: text, range: range) {
            guard let domainRange = Range(match.range(at: 1), in: text),
                  let registrable = registrableDomainName(fromDomain: String(text[domainRange])) else { continue }
            candidates.append(registrable)
        }
        guard !candidates.isEmpty else { return nil }

        // Dedupe while keeping first-occurrence order — this is the order
        // ties fall back to below, same as the old "first match wins" rule.
        var seen = Set<String>()
        let uniqueInOrder = candidates.filter { seen.insert($0).inserted }

        // Suffix rule: OCR fusing a stray character/word onto the front of
        // a real domain is a known, recurring failure mode; two genuinely
        // different companies both printing a domain on the same receipt
        // where one's name is a proper suffix of the other's ("homedepot"
        // vs. "pulashomedepot") is far less likely. When that shape shows
        // up, treat the longer one as the fusion artifact and drop it —
        // but only when a shorter candidate is actually present in the
        // text to justify the call; a lone domain with no corroborating
        // shorter match is left completely alone; truncating an
        // unaccompanied domain on suspicion alone would risk mangling a
        // real, longer brand name that simply happens to contain a shorter
        // dictionary-ish word.
        let suffixArtifacts = Set(uniqueInOrder.filter { longer in
            uniqueInOrder.contains { shorter in shorter != longer && longer.hasSuffix(shorter) }
        })
        let survivors = uniqueInOrder.filter { !suffixArtifacts.contains($0) }
        guard !survivors.isEmpty else { return nil }

        // Among survivors, prefer whichever printed most often. A
        // merchant's own domain often appears more than once on a receipt
        // (header masthead, footer "learn more" link, loyalty program
        // text); a one-off mention — a third-party URL in a single line of
        // marketing copy — typically doesn't repeat. This is a weaker,
        // secondary signal: it only breaks ties among domains the suffix
        // rule didn't already resolve, and when frequencies tie too
        // (the common case — most domains on a receipt appear exactly
        // once), reading order still decides, same as before this fix.
        let frequency = Dictionary(candidates.map { ($0, 1) }, uniquingKeysWith: +)
        guard let chosen = survivors.max(by: { (frequency[$0] ?? 0, negativeIndex(of: $0, in: uniqueInOrder))
            < (frequency[$1] ?? 0, negativeIndex(of: $1, in: uniqueInOrder)) })
        else { return nil }

        return titleCased(chosen)
    }

    /// `uniqueInOrder`'s reading-order position, negated so that "earlier in
    /// the text" sorts as "larger" alongside frequency in the `max(by:)`
    /// tuple comparison above (both criteria should favor bigger values).
    private static func negativeIndex(of name: String, in ordered: [String]) -> Int {
        -(ordered.firstIndex(of: name) ?? 0)
    }

    /// Shared by both the `@domain.tld` match and the bare-`domain.tld`
    /// fallback above: extracts the registrable brand label from a raw
    /// domain capture and title-cases it, or returns nil when the domain is
    /// too short/generic to trust, or belongs to a personal email provider,
    /// payment processor, or other domain that would be a worse vendor
    /// guess than falling through to the line heuristic.
    private static func registrableVendorName(fromDomain domain: String) -> String? {
        guard let registrable = registrableDomainName(fromDomain: domain) else { return nil }
        return titleCased(registrable)
    }

    /// Same filtering as `registrableVendorName` above but stops short of
    /// title-casing, returning the lowercase registrable label itself.
    /// Split out so the bare-domain fallback can compare/dedupe/count
    /// candidates by their actual registrable name (`registrableDomainName`
    /// == "homedepot" from *this* domain and "homedepot" from a second,
    /// differently-cased occurrence must be recognized as the same
    /// candidate) before deciding which single one to title-case and
    /// return.
    private static func registrableDomainName(fromDomain domain: String) -> String? {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
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

        let excludedDomains: Set<String> = [
            // Personal email providers — a customer's own address sometimes
            // appears in loyalty-program context; "Gmail" would be a
            // strictly worse guess than falling through to the line
            // heuristic or nil.
            "gmail", "yahoo", "hotmail", "outlook", "icloud", "aol",
            "protonmail", "live", "msn", "comcast", "verizon",
            // Payment processors / card networks / issuers that print their
            // own domain on a receipt footer (surcharge notices, store-card
            // "powered by" branding) without being the merchant that
            // actually sold the goods — a risk unique to the bare-domain
            // fallback, since these rarely appear as "user@domain" emails.
            "visa", "mastercard", "amex", "americanexpress", "discover",
            "paypal", "venmo", "squareup", "square", "stripe", "clover",
            "synchrony", "syf", "comenity",
        ]
        guard !excludedDomains.contains(registrable) else { return nil }

        return registrable
    }

    /// Title-cases a lowercase registrable label for display — "homedepot"
    /// -> "Homedepot". Pulled out on its own so the bare-domain fallback can
    /// pick a winning candidate first and title-case only that one.
    private static func titleCased(_ registrable: String) -> String {
        registrable.prefix(1).uppercased() + registrable.dropFirst()
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
