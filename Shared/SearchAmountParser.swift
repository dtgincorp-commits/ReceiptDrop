import Foundation

/// Deterministic amount-bound extraction from a search query — the "Swift is
/// where the guarantees live" strategy documented on
/// `SemanticSearchService.parseQuery` applied to money instead of dates.
///
/// Before this, "restaurants over hundred dollars" and "gas station receipts
/// under fifty dollars" depended entirely on a small on-device model reading
/// bound words and spelled-out numbers correctly, and it didn't reliably —
/// the same "a small model holds a constraint only as firmly as the prompt
/// lets it" failure already documented for dates and for the vendor-type
/// "other" guard. This is the deterministic pre-pass for amounts, and
/// `SemanticSearchService.finalize` lets its answer win over the model's,
/// mirroring how an explicit date already overrides the model's date
/// opinion.
///
/// It is deliberately conservative about *not* finding a bound: a vague
/// word with no number attached ("expensive", "cheap", "pricey", "around
/// $50") produces nothing, because inventing a threshold — even a
/// plausible-sounding one — is exactly the kind of guess a tax filter must
/// never make silently. See `containsAnyNumber`, which exists to draw that
/// same line one level up, in `finalize`: it tells the difference between "no
/// bound stated" (drop whatever the model invented) and "a bound stated in
/// words this parser doesn't yet recognize" (the model might be right, so
/// keep its answer).
enum SearchAmountParser {

    /// Bounds stated literally in the query, or (nil, nil) when it states
    /// none.
    static func bounds(in query: String) -> (min: Double?, max: Double?) {
        let tokens = tokenize(query.lowercased())

        if let range = explicitRangeBounds(tokens) {
            return (Swift.min(range.0, range.1), Swift.max(range.0, range.1))
        }
        // Upper-bound phrases are checked before lower-bound ones on purpose:
        // "no more than $50" contains the literal words "more than", which is
        // itself a complete lower-bound phrase, and scanning lower-bound
        // phrases first would read that as a $50 *minimum* — the opposite of
        // what the query said. Checking "no more than" (matched here, in the
        // upper list) first means the query is already resolved by the time
        // the lower-bound scan would have gotten to the false match.
        if let upper = firstBound(tokens, phrases: upperBoundPhrases) {
            return (nil, upper)
        }
        if let lower = firstBound(tokens, phrases: lowerBoundPhrases) {
            return (lower, nil)
        }
        return (nil, nil)
    }

    /// True when the query contains any number at all — digits or a spelled
    /// out number word — regardless of whether it forms a recognized bound
    /// phrase. Backs the "don't invent a threshold" guard in
    /// `SemanticSearchService.finalize`: a query with literally no number in
    /// it can't have meant to state one, so any bound the model returns for
    /// it was fabricated.
    static func containsAnyNumber(in query: String) -> Bool {
        tokenize(query.lowercased()).contains {
            if case .number = $0 { return true }
            return false
        }
    }

    // MARK: - Phrase vocabulary

    private static let lowerBoundPhrases: [[String]] = [
        ["over"], ["above"], ["more", "than"], ["greater", "than"],
        ["at", "least"], ["starting", "at"], ["from"], ["minimum"], ["min"],
    ]

    private static let upperBoundPhrases: [[String]] = [
        ["under"], ["below"], ["less", "than"], ["at", "most"],
        ["no", "more", "than"], ["up", "to"], ["maximum"], ["max"],
        ["cheaper", "than"],
    ]

    /// Finds the first occurrence of any phrase in `phrases` that is
    /// immediately followed (optionally past a bare "of", as in "a minimum
    /// of 50") by a number, and returns that number. Longer phrases are
    /// tried first only as a matter of habit — none of the two lists
    /// actually overlap once the caller has already resolved the one real
    /// collision ("no more than" vs "more than") by checking lists in the
    /// right order.
    private static func firstBound(_ tokens: [Token], phrases: [[String]]) -> Double? {
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            guard phrase.count <= tokens.count else { continue }
            for idx in 0...(tokens.count - phrase.count) {
                guard matches(tokens, at: idx, phrase: phrase) else { continue }
                var next = idx + phrase.count
                if next < tokens.count, case .word("of") = tokens[next] { next += 1 }
                guard next < tokens.count, case .number(let value, let hadDollarSign) = tokens[next] else { continue }
                // "from" is the one lower-bound phrase that also introduces a
                // date ("from July", "receipts from 2026"), so a bare
                // (no "$") whole number shaped like a calendar year must not
                // be read as a dollar amount here — that reading belongs to
                // `SearchQueryDateParser.bareYearRange` instead. Every other
                // phrase ("over", "at least", ...) has no such double life,
                // so this exception is scoped to "from" alone.
                if phrase == ["from"], !hadDollarSign, isBareYearLike(value) { continue }
                return value
            }
        }
        return nil
    }

    private static func isBareYearLike(_ value: Double) -> Bool {
        value.truncatingRemainder(dividingBy: 1) == 0 && value >= 2000 && value <= 2100
    }

    private static func matches(_ tokens: [Token], at idx: Int, phrase: [String]) -> Bool {
        for (offset, word) in phrase.enumerated() {
            guard case .word(let w) = tokens[idx + offset], w == word else { return false }
        }
        return true
    }

    // MARK: - Ranges: "between X and Y", "X to Y", "X-Y"

    /// Always returns the pair in whatever order the two numbers appear;
    /// `bounds(in:)` is responsible for sorting them into min/max, since
    /// "between 40 and 20" and "between 20 and 40" must mean the same
    /// $20-$40 window.
    private static func explicitRangeBounds(_ tokens: [Token]) -> (Double, Double)? {
        if let betweenIdx = tokens.firstIndex(where: { if case .word("between") = $0 { return true }; return false }) {
            let numbersAfter = tokens[(betweenIdx + 1)...].compactMap { token -> Double? in
                if case .number(let value, _) = token { return value }
                return nil
            }
            if numbersAfter.count >= 2 {
                return (numbersAfter[0], numbersAfter[1])
            }
        }

        // "20 to 40" / "20-40" with no "between": two numbers with only a
        // literal "to" token, or nothing at all, separating them. The
        // adjacency case (nothing between them) is what a hyphenated range
        // tokenizes to, since the hyphen itself isn't part of either number
        // and isn't captured as its own token.
        var i = 0
        while i < tokens.count {
            if case .number(let first, _) = tokens[i] {
                if i + 1 < tokens.count, case .number(let second, _) = tokens[i + 1] {
                    return (first, second)
                }
                if i + 2 < tokens.count, case .word("to") = tokens[i + 1],
                   case .number(let second, _) = tokens[i + 2] {
                    return (first, second)
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Tokenizing

    private enum Token: Equatable {
        case word(String)
        /// `hadDollarSign` distinguishes "$2026" (unambiguously a dollar
        /// figure) from a bare "2026" (which could just as easily be a year
        /// — see the "from" guard in `firstBound`, the one place this
        /// matters).
        case number(Double, hadDollarSign: Bool)
    }

    /// Breaks `text` (already lowercased) into a stream of words and
    /// numbers. A number is either a digit run — with an optional leading
    /// "$", optional thousands commas, and an optional decimal part — or a
    /// run of spelled-out number words, merged in `mergeWordNumbers`. Every
    /// other character (whitespace, punctuation, a bare hyphen) is a
    /// separator and disappears; nothing downstream needs to know it was
    /// there except the number-adjacency check in `explicitRangeBounds`,
    /// which relies on exactly this: a hyphenated "100-150" tokenizes to two
    /// adjacent number tokens with nothing in between.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || (c == "$" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                let hadDollarSign = chars[j] == "$"
                if hadDollarSign { j += 1 }
                var digits = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "," {
                    if chars[j] != "," { digits.append(chars[j]) }
                    j += 1
                }
                if j < chars.count, chars[j] == ".", j + 1 < chars.count, chars[j + 1].isNumber {
                    digits.append(".")
                    j += 1
                    while j < chars.count, chars[j].isNumber {
                        digits.append(chars[j])
                        j += 1
                    }
                }
                if let value = Double(digits) {
                    tokens.append(.number(value, hadDollarSign: hadDollarSign))
                }
                i = j
            } else if c.isLetter {
                var j = i
                var word = ""
                while j < chars.count, chars[j].isLetter {
                    word.append(chars[j])
                    j += 1
                }
                tokens.append(.word(word))
                i = j
            } else {
                i += 1
            }
        }
        return mergeWordNumbers(tokens)
    }

    private static let ones: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static func isNumberWord(_ word: String) -> Bool {
        ones[word] != nil || tens[word] != nil || word == "hundred" || word == "thousand"
    }

    /// Collapses a run of spelled-out number words into a single `.number`
    /// token — a small hand-written reducer rather than a dependency,
    /// because the vocabulary a search query actually needs is tiny: the
    /// ones and teens, the tens, "hundred", "thousand", and "and"-joined
    /// compounds ("one hundred fifty", "two hundred and fifty"). "and" is
    /// only ever consumed when it sits between two number words — an "and"
    /// anywhere else in the query (joining two unrelated clauses) is left
    /// alone, because the lookahead requires the *next* token to also be a
    /// number word before "and" is swallowed.
    private static func mergeWordNumbers(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < tokens.count {
            if case .word(let w) = tokens[i], isNumberWord(w) {
                var total: Double = 0
                var current: Double = 0
                var consumedAny = false
                var j = i
                while j < tokens.count, case .word(let word) = tokens[j] {
                    if let value = ones[word] {
                        current += value
                        consumedAny = true
                        j += 1
                    } else if let value = tens[word] {
                        current += value
                        consumedAny = true
                        j += 1
                    } else if word == "hundred" {
                        current = (current == 0 ? 1 : current) * 100
                        consumedAny = true
                        j += 1
                    } else if word == "thousand" {
                        total += (current == 0 ? 1 : current) * 1000
                        current = 0
                        consumedAny = true
                        j += 1
                    } else if word == "and", consumedAny, j + 1 < tokens.count,
                              case .word(let next) = tokens[j + 1], isNumberWord(next) {
                        j += 1
                    } else {
                        break
                    }
                }
                if consumedAny {
                    result.append(.number(total + current, hadDollarSign: false))
                    i = j
                    continue
                }
            }
            result.append(tokens[i])
            i += 1
        }
        return result
    }
}
