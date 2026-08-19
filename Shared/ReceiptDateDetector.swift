import Foundation

/// Deterministic date extraction from raw receipt text — no AI, no iOS 26
/// SDK, just `NSDataDetector` (part of Foundation since iOS 4). Used as a
/// cross-check on what the AI reports: a language model can misread which
/// value belongs in which field even when it correctly recognizes a date
/// elsewhere in its own output (e.g. writing the right date into Comments
/// while reporting a different one as the work date) — this catches that by
/// checking the model's answer against what's actually printed.
enum ReceiptDateDetector {
    /// Dates actually printed in `text`, normalized to day granularity and
    /// de-duplicated. Order is not meaningful.
    static func dates(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let calendar = Calendar.current

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
            days.append(calendar.startOfDay(for: date))
        }

        var seen = Set<Date>()
        return days.filter { seen.insert($0).inserted }
    }
}
