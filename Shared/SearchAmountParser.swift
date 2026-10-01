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

    /// An amount filter: either end may be missing, and each end is either
    /// strict ("over $20" excludes $20.00) or inclusive ("at least $20"
    /// includes it). An exact amount is both ends, inclusive, equal.
    struct AmountBounds: Equatable {
        var min: Double?
        var minInclusive = true
        var max: Double?
        var maxInclusive = true

        static func exactly(_ value: Double) -> AmountBounds {
            AmountBounds(min: value, max: value)
        }

        var isEmpty: Bool { min == nil && max == nil }
        var isExact: Bool { min != nil && min == max && minInclusive && maxInclusive }

        /// Whether a receipt amount satisfies the filter. Amounts are money,
        /// compared to the cent: half a cent of slack keeps 20.0 and 19.999…
        /// from a Double round-trip on the same side of "= $20".
        func contains(_ value: Double) -> Bool {
            let cent = 0.005
            if let min {
                if minInclusive ? value < min - cent : value <= min + cent { return false }
            }
            if let max {
                if maxInclusive ? value > max + cent : value >= max - cent { return false }
            }
            return true
        }

        /// The search chip's text. Strict and inclusive ends read
        /// differently, so "over $20" never claims to include $20.00.
        var label: String? {
            func money(_ v: Double) -> String { "$" + SearchAmountParser.format(v) }
            switch (min, max) {
            case (nil, nil): return nil
            case let (lo?, hi?) where isExact && lo == hi: return "= \(money(lo))"
            case let (lo?, hi?) where minInclusive && maxInclusive: return "\(money(lo)) – \(money(hi))"
            case let (lo?, hi?):
                let lower = minInclusive ? "\(money(lo)) or more" : "over \(money(lo))"
                let upper = maxInclusive ? "\(money(hi)) or less" : "under \(money(hi))"
                return "\(lower), \(upper)"
            case let (lo?, nil): return minInclusive ? "\(money(lo)) or more" : "over \(money(lo))"
            case let (nil, hi?): return maxInclusive ? "\(money(hi)) or less" : "under \(money(hi))"
            }
        }
    }

    /// "20" for whole dollars, "19.99" otherwise.
    static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    /// Bounds stated literally in the query, or (nil, nil) when it states
    /// none. Kept for callers that only need the numbers; `amountBounds`
    /// also says which ends are strict.
    static func bounds(in query: String) -> (min: Double?, max: Double?) {
        let parsed = amountBounds(in: query)
        return (parsed.min, parsed.max)
    }

    /// Every amount condition the query states literally. In order:
    ///
    /// 1. A range — "between 20 and 40", "20 to 40", "20-40" — inclusive.
    /// 2. A lower and/or an upper bound — "over $20", "at least 20",
    ///    "$20 or more", "> 20", "under $40", "<= 40". Both may appear
    ///    ("over $20 and under $40").
    /// 3. An exact amount — "exactly $20", "equal to 20", "= 20".
    /// 4. Otherwise, a single money figure with nothing qualifying it —
    ///    "the receipt that has $20", "twenty dollars" — means that exact
    ///    amount. Unless the query hedges it ("around $50", "about 20
    ///    dollars"): a vague amount is never turned into a filter.
    static func amountBounds(in query: String) -> AmountBounds {
        let tokens = tokenize(query.lowercased())

        if let range = explicitRangeBounds(tokens) {
            return AmountBounds(min: Swift.min(range.0, range.1), max: Swift.max(range.0, range.1))
        }

        // Bounds before "exactly": "less than or equal to 20" contains the
        // words "equal to 20", and must read as an upper bound, not as 20.
        var result = AmountBounds()
        if let (value, inclusive) = firstBound(tokens, prefix: upperBoundPhrases, postfix: upperBoundSuffixes) {
            result.max = value
            result.maxInclusive = inclusive
        }
        if let (value, inclusive) = firstBound(tokens, prefix: lowerBoundPhrases, postfix: lowerBoundSuffixes) {
            result.min = value
            result.minInclusive = inclusive
        }
        if !result.isEmpty { return result }

        if let exact = firstBound(tokens, phrases: exactPhrases) {
            return .exactly(exact)
        }
        if let exact = lonelyMoneyFigure(tokens) {
            return .exactly(exact)
        }
        return AmountBounds()
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
    //
    // Each phrase carries whether its end is inclusive: "over" and "under"
    // are strict, "at least" and "at most" are not. Symbols are tokenized
    // as words (see `tokenize`), so ">=" sits in these lists like any word.

    private static let lowerBoundPhrases: [([String], inclusive: Bool)] = [
        (["over"], false), (["above"], false), (["more", "than"], false),
        (["greater", "than"], false), (["exceeding"], false), ([">"], false),
        (["at", "least"], true), (["starting", "at"], true), (["from"], true),
        (["minimum"], true), (["min"], true), ([">="], true),
        (["no", "less", "than"], true), (["not", "less", "than"], true),
        (["greater", "than", "or", "equal", "to"], true),
        (["more", "than", "or", "equal", "to"], true),
    ]

    private static let upperBoundPhrases: [([String], inclusive: Bool)] = [
        (["under"], false), (["below"], false), (["less", "than"], false),
        (["cheaper", "than"], false), (["<"], false),
        (["at", "most"], true), (["no", "more", "than"], true),
        (["not", "more", "than"], true), (["up", "to"], true),
        (["maximum"], true), (["max"], true), (["<="], true),
        (["less", "than", "or", "equal", "to"], true),
    ]

    /// Words after the number: "$20 or more", "$40 and under".
    private static let lowerBoundSuffixes: [[String]] = [
        ["or", "more"], ["or", "above"], ["or", "higher"], ["and", "up"],
        ["and", "above"], ["and", "over"],
    ]
    private static let upperBoundSuffixes: [[String]] = [
        ["or", "less"], ["or", "under"], ["or", "below"], ["or", "lower"],
        ["and", "under"], ["and", "below"], ["and", "less"],
    ]

    private static let exactPhrases: [[String]] = [
        ["exactly"], ["equal", "to"], ["equals"], ["equal"], ["="],
    ]

    /// Words that make a money figure vague. A hedged amount is never
    /// turned into an exact filter — inventing precision the user didn't
    /// state is the same silent-wrong-result failure as inventing a bound.
    private static let hedgeWords: Set<String> = [
        "around", "about", "approximately", "approx", "roughly", "near",
        "nearly", "close", "almost", "~", "ish",
    ]

    /// Every word that takes part in a comparison, plus negations.
    private static let qualifierWords: Set<String> = {
        var words: Set<String> = ["no", "not", "never", "without", "except", "excluding"]
        for (phrase, _) in lowerBoundPhrases + upperBoundPhrases { words.formUnion(phrase) }
        for phrase in lowerBoundSuffixes + upperBoundSuffixes + exactPhrases { words.formUnion(phrase) }
        // Glue words, and "from", which far more often introduces a vendor
        // or a date ("$20 from Starbucks") than an amount.
        words.subtract(["or", "and", "to", "at", "from"])
        return words
    }()

    /// The first prefix phrase followed by a number, or failing that, the
    /// first number followed by a suffix phrase. Returns the number and
    /// whether that end is inclusive (suffix forms always are: "$20 or more").
    private static func firstBound(_ tokens: [Token], prefix: [([String], inclusive: Bool)],
                                   postfix: [[String]]) -> (Double, Bool)? {
        for (phrase, inclusive) in prefix.sorted(by: { $0.0.count > $1.0.count }) {
            if let value = firstBound(tokens, phrases: [phrase]) { return (value, inclusive) }
        }
        for phrase in postfix where phrase.count < tokens.count {
            for idx in 1...(tokens.count - phrase.count) where matches(tokens, at: idx, phrase: phrase) {
                // "$20 or more", and also "20 dollars or more".
                var before = idx - 1
                if case .word(let w) = tokens[before], currencyWords.contains(w), before > 0 { before -= 1 }
                if case .number(let value, _) = tokens[before] { return (value, true) }
            }
        }
        return nil
    }

    private static let currencyWords: Set<String> = ["dollars", "dollar", "bucks", "usd"]

    /// One money figure — a "$" number, or a number followed by "dollars" /
    /// "bucks" / "usd" — when it is the only one in the query and nothing
    /// hedges it. Plain numbers without either are left alone: "receipt 20"
    /// could be anything, and a date or count must never become an amount.
    ///
    /// Also stands aside when the query contains any comparison word it
    /// failed to resolve: "not over $20" had its "over" skipped for the
    /// negation, and reading the leftover "$20" as exact would invert it.
    private static func lonelyMoneyFigure(_ tokens: [Token]) -> Double? {
        let stopWords = hedgeWords.union(qualifierWords)
        guard !tokens.contains(where: { if case .word(let w) = $0 { return stopWords.contains(w) }; return false })
        else { return nil }
        var figures: [Double] = []
        for (idx, token) in tokens.enumerated() {
            guard case .number(let value, let hadDollarSign) = token else { continue }
            var followedByCurrency = false
            if idx + 1 < tokens.count, case .word(let next) = tokens[idx + 1] {
                followedByCurrency = currencyWords.contains(next)
            }
            if hadDollarSign || followedByCurrency { figures.append(value) }
        }
        return figures.count == 1 ? figures[0] : nil
    }

    /// Finds the first occurrence of any phrase in `phrases` that is
    /// immediately followed (optionally past a bare "of", as in "a minimum
    /// of 50") by a number, and returns that number.
    ///
    /// A match preceded by "no" or "not" is skipped unless the phrase itself
    /// starts with one: "no more than $50" contains "more than $50", which
    /// read alone is a $50 *minimum* — the opposite of what was said. The
    /// negated forms are listed whole, on the side they actually belong to.
    private static func firstBound(_ tokens: [Token], phrases: [[String]]) -> Double? {
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            guard phrase.count <= tokens.count else { continue }
            for idx in 0...(tokens.count - phrase.count) {
                guard matches(tokens, at: idx, phrase: phrase) else { continue }
                if idx > 0, case .word(let before) = tokens[idx - 1], before == "no" || before == "not",
                   phrase.first != "no", phrase.first != "not" { continue }
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
            } else if "<>=≤≥~".contains(c) {
                // Comparison symbols become words the phrase lists can
                // match: ">=", "=>" and "≥" all read as ">="; "==" as "=".
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                switch (c, next) {
                case (">", "="?), ("=", ">"?): tokens.append(.word(">=")); i += 2
                case ("<", "="?), ("=", "<"?): tokens.append(.word("<=")); i += 2
                case ("=", "="?): tokens.append(.word("=")); i += 2
                case ("≥", _): tokens.append(.word(">=")); i += 1
                case ("≤", _): tokens.append(.word("<=")); i += 1
                default: tokens.append(.word(String(c))); i += 1
                }
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
