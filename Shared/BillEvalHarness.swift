import Foundation

// MARK: - Ground truth

/// Hand-verified expected result for one fixture bill photo — the `billNNN.json`
/// sitting next to `billNNN.jpg` in `BillEvalFixtures/`.
///
/// Deliberately mirrors `ExtractedBill`'s shape but with real numeric types:
/// ground truth is authored/verified by a human, so there's no reason to carry
/// the string-parsing tolerance `ExtractedBill.build` needs for model output.
struct BillGroundTruth: Codable, Equatable {
    struct Item: Codable, Equatable {
        let name: String
        let quantity: Int
        let price: Double
    }

    let vendor: String
    let items: [Item]
    let subtotal: Double?
    let tax: Double?
    let serviceCharge: Double?
    let total: Double?
}

// MARK: - Scoring

/// How one extracted item lined up against ground truth. Kept as distinct
/// cases rather than a single pass/fail because the failure *shape* is what
/// drives which Phase 1 bucket to work on: a wrong price is a price-column
/// problem, a missed item is a row-pairing problem, and a phantom item is a
/// filter problem. Collapsing them to one number hides that.
enum BillItemOutcome: String, Codable {
    /// Name and price both matched.
    case matched
    /// Name matched a truth item, price didn't.
    case wrongPrice
    /// In ground truth, nothing extracted matched it.
    case missed
    /// Extracted, but no ground-truth item matches — an invented/misfiltered row.
    case phantom
}

struct BillEvalResult: Codable {
    let fixtureName: String
    /// nil when extraction itself threw — distinct from "extracted nothing".
    let errorMessage: String?

    let matchedCount: Int
    let wrongPriceCount: Int
    let missedCount: Int
    let phantomCount: Int
    let truthItemCount: Int
    let extractedItemCount: Int

    let vendorMatched: Bool
    /// Per-field totals accuracy, counting only fields present in ground truth.
    let totalsCorrect: Int
    let totalsApplicable: Int

    let missedItemNames: [String]
    let phantomItemNames: [String]

    /// Fraction of real items found *with the right price*. `wrongPrice` is
    /// deliberately excluded — an item shown at the wrong amount is not a
    /// success for a bill-checking app.
    var itemRecall: Double {
        truthItemCount == 0 ? 1 : Double(matchedCount) / Double(truthItemCount)
    }

    var itemPrecision: Double {
        extractedItemCount == 0 ? (truthItemCount == 0 ? 1 : 0)
                                : Double(matchedCount) / Double(extractedItemCount)
    }

    var totalsAccuracy: Double {
        totalsApplicable == 0 ? 1 : Double(totalsCorrect) / Double(totalsApplicable)
    }
}

/// Pure scoring — no Vision, no Foundation Models, no network. Kept free of
/// any iOS 26+ API on purpose so it compiles and unit-tests on an older
/// toolchain (this repo's Mac is on the iOS 17.2 SDK; see README), even
/// though the extraction it scores can only actually run on-device.
enum BillEvalScorer {
    /// Money comparisons tolerate a cent of float/rounding drift.
    static let priceTolerance = 0.01

    static func score(fixtureName: String,
                      truth: BillGroundTruth,
                      extracted: ExtractedBill) -> BillEvalResult {
        var remainingTruth = Array(truth.items.enumerated())
        var outcomes: [BillItemOutcome] = []
        var phantomNames: [String] = []

        // Pass 1 — name AND price both match. Strongest evidence, so claim
        // these pairings before the looser name-only pass can steal them.
        var matchedTruthIndices = Set<Int>()
        var matchedExtractedIndices = Set<Int>()
        for (extractedIndex, item) in extracted.items.enumerated() {
            if let hit = remainingTruth.first(where: { (truthIndex, truthItem) in
                !matchedTruthIndices.contains(truthIndex)
                    && namesMatch(truthItem.name, item.name)
                    && abs(truthItem.price - item.price) <= priceTolerance
            }) {
                matchedTruthIndices.insert(hit.offset)
                matchedExtractedIndices.insert(extractedIndex)
                outcomes.append(.matched)
            }
        }

        // Pass 2 — name matches but price doesn't: a real item read at the
        // wrong amount, which is a different (and worse) failure than a miss.
        var wrongPriceCount = 0
        for (extractedIndex, item) in extracted.items.enumerated()
        where !matchedExtractedIndices.contains(extractedIndex) {
            if let hit = remainingTruth.first(where: { (truthIndex, truthItem) in
                !matchedTruthIndices.contains(truthIndex) && namesMatch(truthItem.name, item.name)
            }) {
                matchedTruthIndices.insert(hit.offset)
                matchedExtractedIndices.insert(extractedIndex)
                wrongPriceCount += 1
            } else {
                phantomNames.append(item.name)
            }
        }

        let missedNames = truth.items.enumerated()
            .filter { !matchedTruthIndices.contains($0.offset) }
            .map(\.element.name)

        remainingTruth.removeAll()

        // Totals — only score fields ground truth actually asserts, so a bill
        // with no printed service charge isn't penalized for not finding one.
        var applicable = 0
        var correct = 0
        func compare(_ expected: Double?, _ actual: Double?) {
            guard let expected else { return }
            applicable += 1
            if let actual, abs(expected - actual) <= priceTolerance { correct += 1 }
        }
        compare(truth.subtotal, extracted.subtotal)
        compare(truth.tax, extracted.tax)
        compare(truth.serviceCharge, extracted.serviceCharge)
        compare(truth.total, extracted.total)

        return BillEvalResult(
            fixtureName: fixtureName,
            errorMessage: nil,
            matchedCount: outcomes.filter { $0 == .matched }.count,
            wrongPriceCount: wrongPriceCount,
            missedCount: missedNames.count,
            phantomCount: phantomNames.count,
            truthItemCount: truth.items.count,
            extractedItemCount: extracted.items.count,
            vendorMatched: namesMatch(truth.vendor, extracted.vendor),
            totalsCorrect: correct,
            totalsApplicable: applicable,
            missedItemNames: missedNames,
            phantomItemNames: phantomNames)
    }

    static func failure(fixtureName: String, truth: BillGroundTruth, error: String) -> BillEvalResult {
        BillEvalResult(
            fixtureName: fixtureName, errorMessage: error,
            matchedCount: 0, wrongPriceCount: 0,
            missedCount: truth.items.count, phantomCount: 0,
            truthItemCount: truth.items.count, extractedItemCount: 0,
            vendorMatched: false, totalsCorrect: 0,
            totalsApplicable: [truth.subtotal, truth.tax, truth.serviceCharge, truth.total]
                .compactMap { $0 }.count,
            missedItemNames: truth.items.map(\.name), phantomItemNames: [])
    }

    /// Deliberately forgiving: OCR routinely returns "MARGARITA" for
    /// "Margarita", "Chopt Salad" for "CHOPT SALAD ", or truncates a long
    /// item name. Scoring those as failures would bury the failures that
    /// actually matter (missed rows, wrong prices) under formatting noise.
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return x == y }
        if x == y || x.hasPrefix(y) || y.hasPrefix(x) { return true }

        let xTokens = Set(x.split(separator: " ").filter { $0.count > 2 })
        let yTokens = Set(y.split(separator: " ").filter { $0.count > 2 })
        guard !xTokens.isEmpty, !yTokens.isEmpty else { return false }
        let overlap = xTokens.intersection(yTokens).count
        return Double(overlap) / Double(min(xTokens.count, yTokens.count)) >= 0.5
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}

// MARK: - Aggregate

struct BillEvalSummary: Codable {
    let providerName: String
    let runDate: Date
    let results: [BillEvalResult]

    var fixtureCount: Int { results.count }
    var erroredCount: Int { results.filter { $0.errorMessage != nil }.count }

    /// Pooled across all items in the run, not an average of per-bill rates —
    /// a 20-item bill shouldn't count the same as a 2-item one.
    var itemRecall: Double {
        let truth = results.reduce(0) { $0 + $1.truthItemCount }
        let matched = results.reduce(0) { $0 + $1.matchedCount }
        return truth == 0 ? 1 : Double(matched) / Double(truth)
    }

    var itemPrecision: Double {
        let extracted = results.reduce(0) { $0 + $1.extractedItemCount }
        let matched = results.reduce(0) { $0 + $1.matchedCount }
        return extracted == 0 ? 1 : Double(matched) / Double(extracted)
    }

    var totalsAccuracy: Double {
        let applicable = results.reduce(0) { $0 + $1.totalsApplicable }
        let correct = results.reduce(0) { $0 + $1.totalsCorrect }
        return applicable == 0 ? 1 : Double(correct) / Double(applicable)
    }

    var vendorAccuracy: Double {
        results.isEmpty ? 1 : Double(results.filter(\.vendorMatched).count) / Double(results.count)
    }

    /// Failure counts by bucket — the number that decides which Phase 1 item
    /// to work on next.
    var wrongPriceTotal: Int { results.reduce(0) { $0 + $1.wrongPriceCount } }
    var missedTotal: Int { results.reduce(0) { $0 + $1.missedCount } }
    var phantomTotal: Int { results.reduce(0) { $0 + $1.phantomCount } }

    func csv() -> String {
        var lines = ["fixture,error,truth_items,extracted_items,matched,wrong_price,missed,phantom,item_recall,item_precision,vendor_ok,totals_correct,totals_applicable"]
        for r in results {
            let error = (r.errorMessage ?? "").replacingOccurrences(of: ",", with: ";")
            lines.append("\(r.fixtureName),\(error),\(r.truthItemCount),\(r.extractedItemCount),\(r.matchedCount),\(r.wrongPriceCount),\(r.missedCount),\(r.phantomCount),\(String(format: "%.3f", r.itemRecall)),\(String(format: "%.3f", r.itemPrecision)),\(r.vendorMatched),\(r.totalsCorrect),\(r.totalsApplicable)")
        }
        return lines.joined(separator: "\n")
    }
}
