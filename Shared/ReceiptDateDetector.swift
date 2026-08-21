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
enum ReceiptDateDetector {
    /// Dates actually printed in `text`, normalized to day granularity and
    /// de-duplicated. Order is not meaningful.
    static func dates(in text: String) -> [Date] {
        var days: [Date] = dataDetectorDates(in: text)
        days.append(contentsOf: numericDates(in: text))

        let calendar = Calendar.current
        var seen = Set<Date>()
        return days
            .map { calendar.startOfDay(for: $0) }
            .filter { seen.insert($0).inserted }
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

            results.append(date)
        }
        return results
    }
}
