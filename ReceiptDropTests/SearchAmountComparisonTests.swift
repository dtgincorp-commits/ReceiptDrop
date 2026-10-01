import XCTest
@testable import ReceiptDrop

/// Every way a search can state an amount: =, >, <, >=, <= in words and in
/// symbols, ranges, both ends at once, and the boundaries between them.
///
/// Motivated by a real search, "Show me the receipt that has $20", that
/// came back as "over $20": the parser had no notion of an exact amount, so
/// it left the decision to the on-device model, which guessed a bound.
final class SearchAmountComparisonTests: XCTestCase {
    typealias Bounds = SearchAmountParser.AmountBounds

    private func parse(_ query: String) -> Bounds { SearchAmountParser.amountBounds(in: query) }

    private func assertParses(_ query: String, _ expected: Bounds, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parse(query), expected, query, file: file, line: line)
    }

    // MARK: - Equal

    func testTheMotivatingQueryIsAnExactAmount() {
        assertParses("Show me the receipt that has $20", .exactly(20))
    }

    func testExactAmountInWordsAndSymbols() {
        for query in ["exactly $20", "receipts equal to 20", "amount = 20", "amount == 20",
                      "amount =20", "receipts for $20", "twenty dollars", "20 dollars", "20 bucks",
                      "$20.00", "$20 from Starbucks"] {
            assertParses(query, .exactly(20))
        }
        assertParses("exactly $19.99", .exactly(19.99))
    }

    // MARK: - Greater than (strict)

    func testStrictLowerBound() {
        for query in ["over $20", "above 20", "more than 20 dollars", "greater than $20", "> 20", ">20",
                      "receipts exceeding $20"] {
            assertParses(query, Bounds(min: 20, minInclusive: false))
        }
    }

    // MARK: - Greater than or equal

    func testInclusiveLowerBound() {
        for query in ["at least $20", "minimum 20", "a minimum of 20", ">= 20", "=> 20", "≥ 20",
                      "$20 or more", "20 dollars and up", "$20 and above", "no less than 20",
                      "greater than or equal to 20", "more than or equal to $20"] {
            assertParses(query, Bounds(min: 20, minInclusive: true))
        }
    }

    // MARK: - Less than (strict)

    func testStrictUpperBound() {
        for query in ["under $20", "below 20", "less than 20", "cheaper than $20", "< 20", "<20"] {
            assertParses(query, Bounds(max: 20, maxInclusive: false))
        }
    }

    // MARK: - Less than or equal

    func testInclusiveUpperBound() {
        for query in ["at most $20", "no more than 20", "not more than 20", "up to $20", "maximum 20",
                      "<= 20", "=< 20", "≤ 20", "$20 or less", "20 dollars and under",
                      "less than or equal to 20"] {
            assertParses(query, Bounds(max: 20, maxInclusive: true))
        }
    }

    // MARK: - Two ends

    func testRangesAreInclusiveAtBothEnds() {
        for query in ["between 20 and 40", "between $40 and $20", "20 to 40", "$20-$40"] {
            assertParses(query, Bounds(min: 20, max: 40))
        }
    }

    func testBothEndsCanBeStatedSeparately() {
        assertParses("over $20 and under $40",
                     Bounds(min: 20, minInclusive: false, max: 40, maxInclusive: false))
        assertParses("at least 20 but at most 40", Bounds(min: 20, max: 40))
        assertParses("> 20 and <= 40", Bounds(min: 20, minInclusive: false, max: 40, maxInclusive: true))
    }

    // MARK: - Must not become an amount filter

    func testHedgedOrUnqualifiedNumbersAreLeftAlone() {
        for query in ["receipts around $50", "about 20 dollars", "roughly $20", "~ $20",
                      "receipts from July", "receipts from 2026", "last 30 days",
                      "receipt 20", "$20 or $30", "not over $20", "not equal to 20",
                      "expensive receipts"] {
            XCTAssertTrue(parse(query).isEmpty, "\(query) → \(parse(query))")
        }
    }

    // MARK: - Boundaries

    func testBoundaryAmountsLandOnTheRightSide() {
        let twenty = 20.0, justOver = 20.01, justUnder = 19.99
        let checks: [(String, [Double: Bool])] = [
            ("= $20", [twenty: true, justOver: false, justUnder: false]),
            ("over $20", [twenty: false, justOver: true, justUnder: false]),
            ("at least $20", [twenty: true, justOver: true, justUnder: false]),
            ("under $20", [twenty: false, justOver: false, justUnder: true]),
            ("at most $20", [twenty: true, justOver: false, justUnder: true]),
            ("between 20 and 40", [twenty: true, 40: true, 40.01: false, justUnder: false]),
        ]
        for (query, cases) in checks {
            let bounds = parse(query)
            for (amount, expected) in cases {
                XCTAssertEqual(bounds.contains(amount), expected, "\(query) with \(amount)")
            }
        }
    }

    func testAmountsCompareToTheCentDespiteFloatingPoint() {
        XCTAssertTrue(Bounds.exactly(0.3).contains(0.1 + 0.2))
        XCTAssertFalse(Bounds(min: 0.3, minInclusive: false).contains(0.1 + 0.2))
    }

    // MARK: - Chip wording

    func testChipSaysExactlyWhatTheFilterDoes() {
        XCTAssertEqual(parse("has $20").label, "= $20")
        XCTAssertEqual(parse("over $20").label, "over $20")
        XCTAssertEqual(parse("at least $20").label, "$20 or more")
        XCTAssertEqual(parse("under $20").label, "under $20")
        XCTAssertEqual(parse("at most $20").label, "$20 or less")
        XCTAssertEqual(parse("between 20 and 40").label, "$20 – $40")
        XCTAssertEqual(parse("over 20 and at most 40").label, "over $20, $40 or less")
        XCTAssertEqual(parse("exactly $19.99").label, "= $19.99")
        XCTAssertNil(parse("expensive").label)
    }

    // MARK: - Through the whole search pipeline

    private func modelAnswer(min: Double? = nil, max: Double? = nil) -> QueryParseResult {
        QueryParseResult(vendorType: nil, amountMin: min, amountMax: max)
    }

    func testTheParserOverridesAModelThatGuessedOverForAnExactAmount() throws {
        // Exactly what happened: the model said "over $20".
        let out = try SemanticSearchService.finalize(
            modelAnswer(min: 20), query: "Show me the receipt that has $20", explicit: nil)
        XCTAssertEqual(out.amountBounds, .exactly(20))
        XCTAssertEqual(out.amountBounds.label, "= $20")
    }

    func testStrictnessSurvivesTheWholePipeline() throws {
        let out = try SemanticSearchService.finalize(modelAnswer(), query: "over $20", explicit: nil)
        XCTAssertFalse(out.matchesAmount("20.00"))
        XCTAssertTrue(out.matchesAmount("20.01"))
    }

    func testStoredAmountsWithADollarSignAreSearchable() throws {
        let out = try SemanticSearchService.finalize(modelAnswer(), query: "exactly $50", explicit: nil)
        XCTAssertTrue(out.matchesAmount("$50.00"), "real stored data includes \"$50.00\"")
        XCTAssertTrue(out.matchesAmount("50.00"))
        XCTAssertFalse(out.matchesAmount(""), "no amount never satisfies an amount filter")
    }

    func testNoAmountFilterLetsEveryReceiptThrough() {
        let none = modelAnswer()
        XCTAssertTrue(none.matchesAmount(""))
        XCTAssertTrue(none.matchesAmount("$12.00"))
    }

    func testRemovingAnotherChipKeepsTheAmountStrict() throws {
        // Before, the ✕ on the vendor or date chip rebuilt the filter by hand
        // and dropped which end was strict, so "over $20" became "$20 or more".
        let out = try SemanticSearchService.finalize(
            QueryParseResult(vendorType: "restaurant", amountMin: nil, amountMax: nil),
            query: "restaurants over $20", explicit: (Date.distantPast, Date()))
        for remaining in [out.withoutVendorType(), out.withoutDate()] {
            XCTAssertEqual(remaining.amountBounds.label, "over $20")
            XCTAssertFalse(remaining.matchesAmount("20.00"))
        }
        XCTAssertTrue(out.withoutAmount().amountBounds.isEmpty)
        XCTAssertEqual(out.withoutAmount().vendorType, "restaurant")
    }
}
