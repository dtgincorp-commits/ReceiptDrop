import Foundation

/// Scores the app's extraction against the hand-verified receipts in
/// `test-receipts/`.
///
/// The ground truth is already written down: each `*_log.csv` there is a real
/// category log, and its `Receipt_File` column names the image every row
/// describes. So the fixtures pair themselves with their expected vendor,
/// date and amount, with nothing to label by hand.
///
/// Exists because every judgement about extraction quality so far has come
/// from single receipts noticed by eye. That is how `$142.51` survived as a
/// diagnosis of "the model fabricates" for as long as it did, when the real
/// cause was a prompt example being echoed. Fifteen scored receipts answers
/// "is this provider good?" with a number, and answers "did that prompt
/// change help?" at all — which no amount of staring at one receipt can.
enum ExtractionEvalHarness {
    /// One row of a fixture log: what the receipt actually says.
    struct GroundTruth {
        let receiptFile: String
        let vendor: String
        let workDate: String
        let amount: String
    }

    struct FieldScore {
        let correct: Bool
        let expected: String
        let got: String
    }

    struct Result {
        let receiptFile: String
        let vendor: FieldScore
        let workDate: FieldScore
        let amount: FieldScore
        let needsReview: Bool
        let reviewReason: String
        let errorMessage: String?
        let seconds: Double

        var allCorrect: Bool { vendor.correct && workDate.correct && amount.correct }
    }

    // MARK: - Ground truth

    /// Parses one category log. Tolerates quoted fields containing commas,
    /// which the Comments column routinely has.
    static func groundTruth(fromCSV csv: String) -> [GroundTruth] {
        var rows: [GroundTruth] = []
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return [] }
        let columns = splitCSVLine(header)
        guard let vendorIndex = columns.firstIndex(of: "Contractor_or_Vendor_Name"),
              let dateIndex = columns.firstIndex(of: "Work_Date"),
              let amountIndex = columns.firstIndex(of: "Amount"),
              let fileIndex = columns.firstIndex(of: "Receipt_File") else { return [] }

        for line in lines.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = splitCSVLine(line)
            guard fields.count > max(vendorIndex, dateIndex, amountIndex, fileIndex) else { continue }
            rows.append(GroundTruth(receiptFile: fields[fileIndex],
                                    vendor: fields[vendorIndex],
                                    workDate: fields[dateIndex],
                                    amount: fields[amountIndex]))
        }
        return rows
    }

    /// Minimal RFC-4180-ish splitter: honours double quotes so a quoted
    /// Comments field ("Rotating beer, protein bowl") doesn't shift every
    /// column after it.
    static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            switch character {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Scoring

    /// Vendor comparison, deliberately forgiving about everything except
    /// identity.
    ///
    /// Case, punctuation and a trailing company suffix are noise: "Eureka!"
    /// and "EUREKA" are the same answer, and marking one wrong would make
    /// the score measure formatting rather than reading. Containment either
    /// way counts, so "NAAN AND KABOB" scores against "NAAN AND KABOB LLC" —
    /// but "Sul" against "NAAN AND KABOB LLC" does not, which is the
    /// distinction the whole eval exists to make.
    static func vendorMatches(expected: String, got: String) -> Bool {
        let a = normalizedVendor(expected)
        let b = normalizedVendor(got)
        guard !a.isEmpty, !b.isEmpty else { return a == b }
        // A fragment must not pass by containment alone — "sul" is inside
        // nothing here, but "a" would be inside almost everything.
        guard min(a.count, b.count) >= 4 else { return a == b }
        return a == b || a.contains(b) || b.contains(a)
    }

    static func normalizedVendor(_ value: String) -> String {
        let stripped = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        let suffixes = ["llc", "inc", "ltd", "co", "corp", "company"]
        let words = stripped.split(separator: " ").map(String.init)
            .filter { !suffixes.contains($0) }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Numeric comparison, so "89.9" and "89.90" agree and a currency symbol
    /// that slipped through does not fail an otherwise correct read.
    static func amountMatches(expected: String, got: String) -> Bool {
        guard let a = Double(expected.replacingOccurrences(of: "[^0-9.]", with: "",
                                                          options: .regularExpression)),
              let b = Double(got.replacingOccurrences(of: "[^0-9.]", with: "",
                                                      options: .regularExpression))
        else { return false }
        return abs(a - b) < 0.005
    }

    /// Dates are compared as written, both being yyyy-MM-dd by the time they
    /// reach here — the log's own format, and what `ExtractedReceipt.build`
    /// normalizes the model's answer into.
    static func dateMatches(expected: String, got: String) -> Bool {
        expected.trimmingCharacters(in: .whitespaces) == got.trimmingCharacters(in: .whitespaces)
    }

    static func score(truth: GroundTruth, extracted: ExtractedReceipt, seconds: Double) -> Result {
        Result(receiptFile: truth.receiptFile,
               vendor: FieldScore(correct: vendorMatches(expected: truth.vendor, got: extracted.vendor),
                                  expected: truth.vendor, got: extracted.vendor),
               workDate: FieldScore(correct: dateMatches(expected: truth.workDate, got: extracted.workDate),
                                    expected: truth.workDate, got: extracted.workDate),
               amount: FieldScore(correct: amountMatches(expected: truth.amount, got: extracted.amount),
                                  expected: truth.amount, got: extracted.amount),
               needsReview: extracted.needsReview,
               reviewReason: extracted.reviewReason,
               errorMessage: nil,
               seconds: seconds)
    }

    static func failure(truth: GroundTruth, error: String) -> Result {
        Result(receiptFile: truth.receiptFile,
               vendor: FieldScore(correct: false, expected: truth.vendor, got: ""),
               workDate: FieldScore(correct: false, expected: truth.workDate, got: ""),
               amount: FieldScore(correct: false, expected: truth.amount, got: ""),
               needsReview: false, reviewReason: "", errorMessage: error, seconds: 0)
    }

    // MARK: - Summary

    struct Summary {
        let results: [Result]

        var count: Int { results.count }
        var vendorCorrect: Int { results.filter(\.vendor.correct).count }
        var dateCorrect: Int { results.filter(\.workDate.correct).count }
        var amountCorrect: Int { results.filter(\.amount.correct).count }
        var allThreeCorrect: Int { results.filter(\.allCorrect).count }
        var errored: Int { results.filter { $0.errorMessage != nil }.count }
        /// Receipts the guardrails flagged. Read alongside the field scores:
        /// a wrong answer that was flagged is a much smaller problem than a
        /// wrong answer that sailed through, because the user is asked to
        /// look at it.
        var flagged: Int { results.filter(\.needsReview).count }
        /// Of the receipts that got something wrong, how many were flagged —
        /// the number that says whether the guardrails are earning their
        /// keep, independent of how good the model is.
        var wrongAndFlagged: Int { results.filter { !$0.allCorrect && $0.needsReview }.count }
        var wrongTotal: Int { results.filter { !$0.allCorrect }.count }

        var averageSeconds: Double {
            let timed = results.filter { $0.errorMessage == nil }
            guard !timed.isEmpty else { return 0 }
            return timed.reduce(0) { $0 + $1.seconds } / Double(timed.count)
        }
    }
}
