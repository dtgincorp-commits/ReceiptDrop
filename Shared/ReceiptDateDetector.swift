import Foundation

/// Deterministic date extraction from raw receipt text — no AI, no iOS 26
/// SDK. Used as a cross-check on what the AI reports: a language model can
/// misread which value belongs in which field even when it correctly
/// recognizes a date elsewhere in its own output (e.g. writing the right
/// date into Comments while reporting a different one as the work date) —
/// this catches that by checking the model's answer against what's
/// actually printed.
///
/// Two independent passes feed the result, merged and de-duplicated:
///
/// 1. `NSDataDetector` (`.date` checking type) — handles spelled-out and
///    loosely-formatted dates ("August 12, 2026", "Aug 12th") that a
///    numeric regex won't recognize.
/// 2. A numeric-date regex (`numericDates(in:)` below) — `NSDataDetector`
///    has real, verified blind spots on plain `M/D/YY` dates: a year-like
///    number immediately before the date on the same line (a receipt
///    number, e.g. "1077 08/19/26") makes it try to parse both as one
///    malformed expression and drop the line entirely, and the word
///    "Order" immediately before a date ("Order Date: 08/12/2026") also
///    returns zero matches. Both were confirmed empirically against a real
///    Home Depot receipt — see `ReceiptDateDetectorTests` and
///    `ManualEntryOCRPrefillTests` for the exact strings. The regex pass
///    exists to catch what the first pass misses; it does not replace it,
///    since `NSDataDetector` still covers date shapes the regex doesn't
///    attempt (month names, ordinals, relative wording).
/// A third rule cuts across both passes: a date printed under a label that
/// marks it as something *other* than the transaction date — a date of
/// birth, a due date, a policy or statement period, an expiry — is not
/// reported at all. See `namesNonTransactionDate`. This is a *kind* check
/// rather than a presence check, and it exists because the presence check
/// alone provably isn't enough: a medical bill with no transaction date
/// printed anywhere returned its patient's date of birth (01/30/1969) as
/// the work date, and every existing guard passed it, because that date
/// really is printed on the page. Correctly reading the wrong kind of date
/// is a distinct failure from inventing one, and only this rule catches it.
enum ReceiptDateDetector {
    /// Dates actually printed in `text`, normalized to day granularity and
    /// de-duplicated. Dates on a line labelled as a non-transaction date
    /// (see `namesNonTransactionDate`) are excluded. Order is not
    /// meaningful.
    static func dates(in text: String) -> [Date] {
        var days: [Date] = dataDetectorDates(in: text)
        days.append(contentsOf: numericDates(in: text))

        let calendar = Calendar.current
        var seen = Set<Date>()
        return days
            .map { calendar.startOfDay(for: $0) }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Label context

    /// Phrases that, when printed on the same line as a date, mean that date
    /// is not the receipt's transaction date.
    ///
    /// Deliberately enforced here in Swift rather than by asking the model
    /// more nicely: the on-device model has now failed three separate
    /// prompt-only date fixes (see `ExtractionPrompt.preamble` and
    /// commit a11d3f7's "enforce it in Swift instead of trusting the
    /// prompt"), and a rule this mechanical does not need a language model
    /// to apply it.
    ///
    /// Kept tight on purpose. Every phrase here has essentially no other
    /// meaning on a receipt line that also carries a date, and the
    /// multi-word ones ("due date", not bare "due") exist so an ordinary
    /// word can't disqualify a real purchase date. Ordinary receipt
    /// vocabulary — "order", "sale", "served", "transaction", "paid",
    /// "total" — is emphatically *not* here.
    static let nonTransactionDateLabels: [String] = [
        // Date of birth. The confirmed failure: a patient billing statement
        // printing "01/30/1969 • Guarantor" beneath the patient's name, with
        // no transaction date anywhere on the page.
        "dob", "d o b", "date of birth", "birth date", "birthdate", "born",
        // Who the bill is *about*, on a line that therefore carries their
        // personal details rather than the visit's.
        "guarantor", "patient",
        // When an account started, not when anything was bought.
        "member since",
        // A deadline is not a purchase: the money was spent on some other
        // day, or hasn't been spent yet at all.
        "due date", "date due", "payment due", "pay by",
        // Spans, not days. A statement covering a period is not a purchase
        // made on the period's first day.
        "statement period", "billing period", "service period",
        "coverage period",
    ]

    // Deliberately **not** in the list above, though they look like they
    // belong: "expires", "expiry", "policy", "valid through", "valid
    // until".
    //
    // Two existing mechanisms already cover them, and both do it better.
    // Range wording ("valid through 09/01/2026") is dropped by the
    // `duration == 0` guard in the first pass and the explicit
    // through/until check in the second. A future expiry — the common
    // shape, since an expiry is a deadline — is dropped by
    // `ManualEntryOCRPrefill.likelyReceiptDate`'s future-date rule.
    //
    // Adding them here would also actively cost the user something: on the
    // no-AI path, a receipt whose only printed date is a policy expiry
    // currently resolves to `.ambiguous`, which raises the *loud*
    // confirmation prompt ("dates are printed here and the right one is
    // probably in front of you"). Excluding the date outright would
    // downgrade that to `.noDatePrinted`, the deliberately calmest of the
    // three prompts — a quieter warning about the same receipt. The rule
    // here exists to stop a wrong date being *stored*, not to suppress a
    // correct warning.

    /// Whether `line` labels its date as something other than the
    /// transaction date.
    ///
    /// Scope is the whole line containing the date, both sides of it — the
    /// motivating bill prints the label *after* the date ("01/30/1969 •
    /// Guarantor"), while "DOB: 01/30/1969" puts it before, and neither
    /// ordering is more canonical than the other. Line granularity is the
    /// honest compromise: a single line carrying both a labelled and an
    /// unlabelled date loses both. That errs toward reporting no date,
    /// which downstream treats as "ask the user" — the safe direction, and
    /// the opposite of what this bug did.
    ///
    /// Matching is on whole space-delimited tokens of a punctuation-stripped
    /// line, so "born" can't fire inside "reborn" and "d o b" catches
    /// "D.O.B.:".
    static func namesNonTransactionDate(_ line: String) -> Bool {
        let stripped = String(line.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " })
        let normalized = " " + stripped.split(separator: " ").joined(separator: " ") + " "
        return nonTransactionDateLabels.contains { normalized.contains(" \($0) ") }
    }

    /// The full text line containing `range` — used to judge a date by the
    /// words printed alongside it.
    private static func line(containing range: NSRange, in text: String) -> String {
        guard let r = Range(range, in: text) else { return "" }
        let start = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[start..<end])
    }

    // MARK: - Pass 1: NSDataDetector

    private static func dataDetectorDates(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)

        var days: [Date] = []
        for match in detector.matches(in: text, options: [], range: fullRange) {
            guard let date = match.date else { continue }
            // A bare time-of-day line ("Time  2:30 PM") is detected as a
            // date on *today* — left unfiltered, that would make today's
            // date look "present on the receipt" for every single scan and
            // defeat this whole check. Skip any match whose matched text is
            // only a clock time, with no actual date component.
            if let range = Range(match.range, in: text) {
                let matchedText = text[range].trimmingCharacters(in: .whitespaces)
                if matchedText.range(of: #"^\d{1,2}:\d{2}(:\d{2})?\s*([AaPp]\.?[Mm]\.?)?$"#,
                                      options: .regularExpression) != nil {
                    continue
                }
            }
            // Range wording turns a single printed date into a *span* whose
            // `.date` is the start — and the start is "now", not anything
            // printed. "Coupon valid through 09/01/2026" and "Offer good
            // until 09/01/2026" both report today with a ~13-day duration,
            // while "Expires 09/01/2026" (no range word) correctly reports
            // 09/01. Promo, coupon, and warranty lines carry that wording
            // constantly, so left unfiltered this is the same defeat as the
            // clock-time case above: today's date looks printed on the
            // receipt. A genuinely printed date always has zero duration.
            guard match.duration == 0 else { continue }
            // Right shape, wrong kind — a date of birth, a due date, a
            // policy period. See `namesNonTransactionDate`.
            if namesNonTransactionDate(line(containing: match.range, in: text)) { continue }
            days.append(date)
        }
        return days
    }

    // MARK: - Pass 2: numeric regex

    /// Matches `M/D/YY`, `M/D/YYYY`, `MM/DD/YY`, `MM/DD/YYYY` and the same
    /// shapes with `-` or `.` in place of `/` — see `ReceiptAmountDetector
    /// .separatorNormalized` for the precedent of handling multiple
    /// separator characters on this kind of receipt text.
    ///
    /// Deliberately narrow, to avoid pulling fake "dates" out of card
    /// numbers, auth codes, and SKUs, which this receipt's raw text is full
    /// of ("1077 61 46161 08/19/2026 1700", "AUTH CODE 064152/5612915",
    /// "0000-999-735"):
    ///
    /// - Both halves of the day/month pair are capped at 1-2 digits, and
    ///   `(?<!\d)` / `(?!\d)` boundaries stop the match from landing in the
    ///   middle of a longer digit run. That alone throws out
    ///   "0000-999-735" — neither "0000" nor "999" can satisfy a 1-2 digit
    ///   group, so no valid 3-part split exists anywhere in the string.
    /// - The two separators must be the *same* character (`\2`
    ///   backreference) — "064152/5612915" only has one separator at all,
    ///   so it can never match a 3-part D/M/Y shape regardless of digit
    ///   counts.
    /// - Because the regex only looks at the matched substring itself (not
    ///   surrounding tokens the way `NSDataDetector` does), a leading
    ///   receipt/reference number on the same line — "1077 08/19/26",
    ///   "1077 61 46161 08/19/2026 1700" — doesn't stop it from finding the
    ///   date; that's precisely the failure mode this pass exists to cover.
    private static let numericDatePattern =
        #"(?<!\d)(\d{1,2})([/.\-])(\d{1,2})\2(\d{4}|\d{2})(?!\d)"#

    private static func numericDates(in text: String) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: numericDatePattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())

        var results: [Date] = []
        for match in regex.matches(in: text, options: [], range: fullRange) {
            guard match.numberOfRanges == 5,
                  let g1Range = Range(match.range(at: 1), in: text),
                  let g3Range = Range(match.range(at: 3), in: text),
                  let g4Range = Range(match.range(at: 4), in: text),
                  let first = Int(text[g1Range]),
                  let second = Int(text[g3Range]) else { continue }
            let yearDigits = text[g4Range]

            // Century rule for 2-digit years: a receipt's own transaction
            // date is essentially never in the future relative to when
            // it's being scanned/OCR'd, so pick whichever century keeps the
            // year <= the current year. "26" today (2026) reads as 2026;
            // if it ever read as a future year under the 2000s assumption
            // (e.g. "40" -> 2040 while "now" is still in the 2020s), fall
            // back to the 1900s instead of ever reporting a future year for
            // a bare two-digit year. This mirrors the reasoning already
            // used for the future-date rejection in
            // `ManualEntryOCRPrefill.likelyReceiptDate` (Rule 1), just
            // applied at parse time instead of after the fact.
            let year: Int
            if yearDigits.count == 4 {
                guard let y = Int(yearDigits) else { continue }
                year = y
            } else {
                guard let twoDigit = Int(yearDigits) else { continue }
                var candidate = 2000 + twoDigit
                if candidate > currentYear { candidate -= 100 }
                year = candidate
            }

            // Day/month ordering: this app and its existing tests assume
            // US-style M/D dates (see `ManualEntryOCRPrefillTests`'s
            // "08/12/2026" == August 12), so that's the default when a
            // value is ambiguous. But a value like "13/05/2026" cannot be
            // M/D — no 13th month exists — so whichever of the two numbers
            // is > 12 is forced to be the day, and the other the month.
            // Both > 12 (or both == 0) means neither ordering can be a real
            // date at all; skip rather than guess.
            let month: Int
            let day: Int
            if first > 12, second <= 12, second >= 1 {
                day = first
                month = second
            } else if second > 12, first <= 12, first >= 1 {
                month = first
                day = second
            } else if first >= 1, first <= 12, second >= 1, second <= 12 {
                // Genuinely ambiguous — default to the app's US M/D
                // convention rather than reject outright, matching the
                // "prefer the interpretation that yields a valid date"
                // allowance: both orderings are valid dates here, so there
                // is no correctness reason to discard the line, only a
                // labeling choice.
                month = first
                day = second
            } else {
                continue
            }

            // Reject anything that isn't an actual calendar date (e.g.
            // "02/30/2026") rather than let `Calendar` silently normalize
            // the overflow into a different date than what's printed —
            // that would fabricate a date, which is exactly what this
            // detector must never do (see the type-level doc comment on
            // its AI cross-check role).
            // Built with `Calendar.current` (not the fixed Gregorian/UTC
            // calendar used for the century math above) so the resulting
            // `Date` lands on the same local calendar day that
            // `dates(in:)`'s final `startOfDay` dedup step also uses — a
            // UTC-midnight `Date` could otherwise land on the *previous*
            // local day west of Greenwich and be de-duped against the
            // wrong day.
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let localCalendar = Calendar.current
            guard let date = localCalendar.date(from: components) else { continue }
            let roundTrip = localCalendar.dateComponents([.year, .month, .day], from: date)
            guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { continue }

            // Mirror the `duration == 0` range-wording guard from the
            // NSDataDetector pass above. That guard works by an accident of
            // NSDataDetector's own parsing (it turns "through <date>" into
            // a span starting *today*, which duration == 0 catches) — the
            // regex pass has no such side effect to lean on, since it reads
            // the date digits directly regardless of the words around
            // them. Without an explicit check here, "Coupon valid through
            // 09/01/2026" would report 09/01/2026 as a printed transaction
            // date via this pass even though the other pass correctly
            // excludes it, silently reintroducing the exact bug that guard
            // exists to prevent. Checked against only the text immediately
            // before the match on the same line, matching the two range
            // phrases this receipt-text corpus is known to use.
            if let matchRange = Range(match.range, in: text) {
                let lineStart = text[..<matchRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let preceding = text[lineStart..<matchRange.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                if preceding.hasSuffix("through") || preceding.hasSuffix("until") {
                    continue
                }
            }

            // Same label check the NSDataDetector pass applies — this pass
            // reads digits directly and would otherwise happily report a
            // date of birth that the other pass correctly excluded.
            if namesNonTransactionDate(line(containing: match.range, in: text)) { continue }

            results.append(date)
        }
        return results
    }
}

// MARK: - Search-query dates

/// Deterministic extraction of an *explicit* calendar date — or an explicit
/// date range — from a natural-language search query. The query-side sibling
/// of `ReceiptDateDetector`, built from the same two tools (`NSDataDetector`
/// plus a numeric regex) for the same reason: a date a user typed literally
/// is not something a language model should be asked to interpret.
///
/// ## Why this is a separate type, and must NOT be merged with `ReceiptDateDetector.dates(in:)`
///
/// The two have deliberately **opposite polarity** on
/// `NSTextCheckingResult.duration`. On receipt text, a match with a non-zero
/// duration is a *span* invented by coupon/warranty wording ("valid through
/// 09/01/2026") whose start is today rather than anything printed — so
/// `ReceiptDateDetector` rejects `duration != 0` outright, and must keep
/// doing so. On a search query, a span is precisely what we want: "between
/// Aug 1 and Aug 10" is a user asking for a range, and dropping it would
/// throw away the answer. Folding these into one shared function would force
/// one type's polarity onto the other and silently reintroduce whichever bug
/// that guard exists to prevent. Same tools, inverted meaning — keep them
/// apart.
///
/// ## Why the scope is narrow on purpose
///
/// This only claims a query that names a **specific day**. Month-level and
/// coarser phrases ("in July", "July 2025", "last month", "2 weeks ago") are
/// left to the model plus `SearchDateResolver`, which already represent them
/// correctly as whole periods. A regex that turned "in July" into the single
/// day July 1 would be a far worse bug than the gap it closes, so a
/// candidate is rejected unless a day-of-month number is actually present.
enum SearchQueryDateParser {

    /// Inclusive day bounds for the explicit date(s) named in `query`, or nil
    /// when the query names no specific day. Same contract as
    /// `SearchDateResolver.resolve` — `from` is the start of the first day,
    /// `to` the last instant of the last — so callers can use either
    /// interchangeably.
    ///
    /// Several dates in one query collapse to a single span from the earliest
    /// to the latest ("between Aug 1 and Aug 10" → Aug 1 00:00 through Aug 10
    /// 23:59:59). Over-inclusive beats silently empty, the same trade-off
    /// `SearchDateResolver` makes for "2 weeks ago".
    static func explicitRange(in query: String,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> (from: Date, to: Date)? {
        var days = numericDays(in: query, now: now, calendar: calendar)
        days.append(contentsOf: detectorDays(in: query, now: now, calendar: calendar))

        guard let earliest = days.min(), let latest = days.max() else { return nil }
        let start = calendar.startOfDay(for: earliest)
        guard let dayAfter = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: latest)) else { return nil }
        return (start, dayAfter.addingTimeInterval(-1))
    }

    // MARK: - Pass 1: numeric regex

    /// `M/D/YY`, `M/D/YYYY` and the `-` / `.` variants — the same shape
    /// `ReceiptDateDetector.numericDatePattern` matches, and for the same
    /// reasons (matched separators via the `\2` backreference, digit-run
    /// boundaries so the match can't land inside a longer number).
    private static let fullDatePattern =
        #"(?<!\d)(\d{1,2})([/.\-])(\d{1,2})\2(\d{4}|\d{2})(?!\d)"#

    /// A yearless `M/D` — "anything on 8/4". Restricted to `/` alone, unlike
    /// the full pattern above: a query is full of amounts, and "between 5-10"
    /// or "20-40" would otherwise read as May 10 / a nonsense date rather
    /// than the money range the user meant. A slash between two small numbers
    /// has no competing meaning in this app's query vocabulary; a hyphen very
    /// much does.
    ///
    /// Both boundaries exclude a date separator as well as a digit, so this
    /// can only match a *whole* yearless date, never a fragment of a
    /// complete one — the full pattern above owns those. The trailing
    /// `(?![/.\-]\d)` rules out the "8/4" head of "8/4/26"; the leading
    /// `(?<![/.\-])` rules out its "4/26" tail, which is the subtler of the
    /// two and was a confirmed bug — without it "anything on 8/4/26"
    /// resolved to April 26, and "from 8/1/26 to 8/15/26" stretched the
    /// filter back to January.
    private static let bareMonthDayPattern =
        #"(?<![\d/.\-])(\d{1,2})/(\d{1,2})(?!\d)(?![/.\-]\d)"#

    private static func numericDays(in query: String, now: Date, calendar: Calendar) -> [Date] {
        let currentYear = calendar.component(.year, from: now)
        var days: [Date] = []

        if let regex = try? NSRegularExpression(pattern: fullDatePattern) {
            for match in regex.matches(in: query, options: [],
                                       range: NSRange(query.startIndex..., in: query)) {
                guard let first = intGroup(match, 1, in: query),
                      let second = intGroup(match, 3, in: query),
                      let yearText = textGroup(match, 4, in: query) else { continue }
                // Century rule for a 2-digit year, mirroring
                // `ReceiptDateDetector`: never resolve a bare "26" into a
                // future year. A user searching their own receipt history is
                // asking about the past.
                let year: Int
                if yearText.count == 4 {
                    guard let parsed = Int(yearText) else { continue }
                    year = parsed
                } else {
                    guard let twoDigit = Int(yearText) else { continue }
                    var candidate = 2000 + twoDigit
                    if candidate > currentYear { candidate -= 100 }
                    year = candidate
                }
                if let date = date(first: first, second: second, year: year, calendar: calendar) {
                    days.append(date)
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: bareMonthDayPattern) {
            for match in regex.matches(in: query, options: [],
                                       range: NSRange(query.startIndex..., in: query)) {
                guard let first = intGroup(match, 1, in: query),
                      let second = intGroup(match, 2, in: query) else { continue }
                // No year stated: take the most recent occurrence that has
                // already happened. Same rule `SearchDateResolver` applies to
                // a bare named month ("July" said in March means last July) —
                // nobody searches their receipts for a day that hasn't
                // arrived yet.
                guard var date = date(first: first, second: second, year: currentYear, calendar: calendar) else { continue }
                if calendar.startOfDay(for: date) > calendar.startOfDay(for: now),
                   let shifted = calendar.date(byAdding: .year, value: -1, to: date) {
                    date = shifted
                }
                days.append(date)
            }
        }

        return days
    }

    /// Month/day ordering plus real-calendar validation. Whichever value is
    /// > 12 must be the day; ambiguous pairs default to the app's US M/D
    /// convention (the same choice `ReceiptDateDetector` documents). The
    /// round-trip check rejects "02/30" rather than letting `Calendar`
    /// normalize the overflow into a different day than the user typed.
    private static func date(first: Int, second: Int, year: Int, calendar: Calendar) -> Date? {
        let month: Int
        let day: Int
        if first > 12, second <= 12, second >= 1 {
            day = first
            month = second
        } else if second > 12, first <= 12, first >= 1 {
            month = first
            day = second
        } else if (1...12).contains(first), (1...12).contains(second) {
            month = first
            day = second
        } else {
            return nil
        }
        guard let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: candidate)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return candidate
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        textGroup(match, index, in: text).flatMap { Int($0) }
    }

    private static func textGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Pass 2: NSDataDetector

    /// Catches the spelled-out forms the numeric pass can't — "August 4th",
    /// "on Aug 4 2025", "between Aug 1 and Aug 10" — and, unlike the receipt
    /// side, keeps spans (see the polarity note on the type).
    ///
    /// Strictly limited to matches containing a month *name*: everything with
    /// digit separators belongs to the numeric pass, which is both stricter
    /// and more accurate on those. Verified failures when this pass was
    /// allowed to read numeric dates too — it returned April 26 for "8/4/26"
    /// and January 26 for "8/1/26", and it silently normalized the
    /// impossible "02/30/2026" into March 2 rather than rejecting it.
    /// Because `explicitRange` spans the earliest to the latest day it finds,
    /// a single such misread doesn'"'"'t just add a wrong date, it stretches the
    /// whole filter around it. One pass per notation, no overlap.
    private static func detectorDays(in query: String, now: Date, calendar: Calendar) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        var days: [Date] = []
        for match in detector.matches(in: query, options: [],
                                      range: NSRange(query.startIndex..., in: query)) {
            guard let date = match.date,
                  let range = Range(match.range, in: query) else { continue }
            let matched = String(query[range]).trimmingCharacters(in: .whitespaces)
            guard namesASpecificDay(matched) else { continue }

            // A bare month/day with no year stated resolves to the most
            // recent past occurrence, exactly as the numeric pass does.
            // NSDataDetector will happily hand back a *future* "December 4th"
            // when asked in August.
            let shift: Int
            if statesAFourDigitYear(matched) {
                shift = 0
            } else {
                shift = calendar.startOfDay(for: date) > calendar.startOfDay(for: now) ? -1 : 0
            }
            func adjusted(_ value: Date) -> Date? {
                shift == 0 ? value : calendar.date(byAdding: .year, value: shift, to: value)
            }

            if let start = adjusted(date) { days.append(start) }
            if match.duration > 0, let end = adjusted(date.addingTimeInterval(match.duration)) {
                days.append(end)
            }
        }
        return days
    }

    /// The gate that keeps amount queries and month-level phrases out.
    ///
    /// Two conditions, both required:
    ///
    /// 1. **A day-of-month number is present.** "in July" and "July 2025"
    ///    carry no 1–2 digit number, so they fall through to the model's
    ///    `named_month` descriptor and stay whole months. This is the check
    ///    that stops the pre-pass from hijacking coarse date phrases.
    /// 2. **A month name is present.** `NSDataDetector` reads amount phrasing
    ///    as dates surprisingly often — "between 20 and 40" is a verified
    ///    case — and such matches never contain one. Requiring a month name
    ///    keeps "receipts over 100", "under 50" and "between 20 and 40"
    ///    date-free, which is the whole point: a money query must never come
    ///    back with a date filter stapled to it. It also draws the line
    ///    against the numeric pass, which owns every slash/dash notation.
    private static func namesASpecificDay(_ matched: String) -> Bool {
        // A lone clock time ("2:30 PM") is detected as a date on *today* —
        // the same trap `ReceiptDateDetector` guards against.
        if matched.range(of: #"^\d{1,2}:\d{2}(:\d{2})?\s*([AaPp]\.?[Mm]\.?)?$"#,
                         options: .regularExpression) != nil {
            return false
        }
        guard matched.range(of: #"(?<!\d)\d{1,2}(?!\d)"#, options: .regularExpression) != nil else {
            return false
        }
        let lowered = matched.lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.contains { lowered.contains($0) }
    }

    private static func statesAFourDigitYear(_ matched: String) -> Bool {
        matched.range(of: #"(?<!\d)\d{4}(?!\d)"#, options: .regularExpression) != nil
    }
}
