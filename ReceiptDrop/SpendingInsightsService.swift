import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Receipt Insights (spending insights)
//
// Deterministic spending statistics computed from the submission history,
// optionally narrated by the on-device Apple Intelligence model. All
// arithmetic happens here in Swift — the model only ever restates numbers
// already computed, never computes or invents them (the same "never let the
// model make up values" rule the extraction pipeline enforces). That split
// means the numbers on screen are always exact even if no AI is available,
// and nothing ever leaves the phone: insights work in Offline mode too.

/// Spending statistics over the last six calendar months, grouped the same
/// way the Receipts screen groups entries — and using the same stored
/// preference (`receiptsGroupByWorkDate`), so the two screens never disagree.
/// Two modes: work date, falling back to scan date when the work date is
/// missing/unparseable (`ArchiveBackupService.periodDate`), or pure scan
/// date. Whichever mode is picked, the totals here match what you'd add up
/// reading the Receipts screen in that same mode.
struct SpendingDigest {
    struct MonthTotal: Identifiable {
        var id: Date { monthStart }
        let monthStart: Date
        let total: Double
        let count: Int
    }

    struct LabeledTotal: Identifiable {
        var id: String { label }
        let label: String
        let total: Double
        let count: Int
    }

    /// Oldest → newest, only months that have at least one receipt.
    let months: [MonthTotal]
    let currentMonthTotal: Double
    let currentMonthCount: Int
    let previousMonthTotal: Double
    /// Sorted by total, descending. Window = the whole six months.
    let byCategory: [LabeledTotal]
    let byVendorType: [LabeledTotal]
    let topVendors: [LabeledTotal]
    let biggestReceipt: (vendor: String, amount: Double)?
    /// Deterministic "unusual spending" observations (plain sentences),
    /// computed by fixed rules — not the model.
    let unusualFlags: [String]

    var isEmpty: Bool { months.isEmpty }
}

enum SpendingInsightsService {
    static let monthsWindow = 6

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    /// Builds the digest from history. Entries with an unparseable amount are
    /// skipped (they're already HITL-flagged in the Receipts list; silently
    /// counting them as $0 would understate a month and hide the problem).
    static func buildDigest(from entries: [HistoryEntry] = SubmissionStore.loadHistory(),
                            now: Date = Date(),
                            groupByWorkDate: Bool = true) -> SpendingDigest {
        let calendar = Calendar.current
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        guard let windowStart = calendar.date(byAdding: .month, value: -(monthsWindow - 1), to: currentMonthStart) else {
            return SpendingDigest(months: [], currentMonthTotal: 0, currentMonthCount: 0,
                                  previousMonthTotal: 0, byCategory: [], byVendorType: [],
                                  topVendors: [], biggestReceipt: nil, unusualFlags: [])
        }

        // (entry, periodDate, amount) for everything in-window with a real amount.
        // Mirrors YearGroup.build's groupByWorkDate branch in ReceiptsView.swift:
        // work date (falling back to scan date) when true, pure scan date when false.
        let dated: [(entry: HistoryEntry, date: Date, amount: Double)] = entries.compactMap { entry in
            guard let amount = Double(entry.amount), amount > 0 else { return nil }
            let date = groupByWorkDate ? ArchiveBackupService.periodDate(for: entry) : entry.timestamp
            guard date >= windowStart, date < calendar.date(byAdding: .month, value: 1, to: currentMonthStart)! else { return nil }
            return (entry, date, amount)
        }

        let byMonth = Dictionary(grouping: dated) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.date))!
        }
        let months = byMonth.keys.sorted().map { monthStart in
            let rows = byMonth[monthStart]!
            return SpendingDigest.MonthTotal(
                monthStart: monthStart,
                total: rows.reduce(0) { $0 + $1.amount },
                count: rows.count)
        }

        let currentMonth = months.first { $0.monthStart == currentMonthStart }
        let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonthStart)!
        let previousMonth = months.first { $0.monthStart == previousMonthStart }

        /// `caseSensitive: false` groups spellings that differ only in case
        /// into one row, and shows the most common spelling as the label.
        ///
        /// The confirmed case: Insights listed "SAMPLE CATEGORY" ($889.03)
        /// and "Sample Category" ($258.01) as two separate categories, while
        /// the Categories screen showed one. Neither screen was wrong about
        /// its own source — a receipt's `category` is whatever string it was
        /// saved with, and the old default seed predates the uppercasing in
        /// `CategoryStore.add` — but only this one grouped on the raw value.
        /// `ReceiptsView.filteredEntries` and `CategoriesView.receiptCount`
        /// had both already been made case-insensitive for exactly this
        /// reason; this was the screen that hadn't caught up, so the same
        /// money appeared under two headings and neither total matched what
        /// the rest of the app reported.
        ///
        /// Vendors get the same treatment, for a different reason that lands
        /// in the same place: vendor names are AI-extracted, and providers
        /// routinely disagree on capitalization for the same business (see
        /// `DuplicateDetectionService`'s note on why its vendor matching is
        /// fuzzy). "Top Vendors" splitting one merchant across two rows
        /// would understate it and could push it out of the top five
        /// entirely.
        ///
        /// Vendor TYPE stays case-sensitive: those are fixed tokens resolved
        /// through `VendorTypeToken`, never free text, so there is no case
        /// drift to absorb and folding it would only hide a real bug there.
        func totals(byKey key: (HistoryEntry) -> String,
                    caseSensitive: Bool = true,
                    label: (String) -> String = { $0 }) -> [SpendingDigest.LabeledTotal] {
            Dictionary(grouping: dated) { caseSensitive ? key($0.entry) : key($0.entry).uppercased() }
                .compactMap { rawKey, rows -> SpendingDigest.LabeledTotal? in
                    guard !rawKey.isEmpty else { return nil }
                    // The uppercased key is a grouping device, not something
                    // to show — displaying it would rewrite "Costco" as
                    // "COSTCO" for everyone, including the vast majority of
                    // users who never had a case split at all. Show the
                    // spelling that appears most often instead, breaking ties
                    // alphabetically so the label doesn't flicker between
                    // equally-common spellings on reload.
                    let displayKey: String
                    if caseSensitive {
                        displayKey = rawKey
                    } else {
                        let spellings = Dictionary(grouping: rows) { key($0.entry) }
                        displayKey = spellings
                            .max { a, b in
                                a.value.count != b.value.count
                                    ? a.value.count < b.value.count
                                    : a.key > b.key
                            }?.key ?? rawKey
                    }
                    return SpendingDigest.LabeledTotal(
                        label: label(displayKey),
                        total: rows.reduce(0) { $0 + $1.amount },
                        count: rows.count)
                }
                .sorted { $0.total > $1.total }
        }

        let biggest = dated.max { $0.amount < $1.amount }

        // Deterministic unusual-spending rules. Fixed thresholds, no model.
        var flags: [String] = []
        let priorMonths = months.filter { $0.monthStart != currentMonthStart }
        if let currentMonth, priorMonths.count >= 2 {
            let priorAverage = priorMonths.reduce(0) { $0 + $1.total } / Double(priorMonths.count)
            if priorAverage > 0, currentMonth.total > priorAverage * 1.5 {
                let percent = Int(((currentMonth.total / priorAverage) - 1) * 100)
                flags.append("This month's spending (\(dollars(currentMonth.total))) is \(percent)% above your prior monthly average (\(dollars(priorAverage))).")
            }
        }
        if dated.count >= 5, let biggest {
            let sortedAmounts = dated.map(\.amount).sorted()
            let median = sortedAmounts[sortedAmounts.count / 2]
            if median > 0, biggest.amount > median * 3 {
                let vendor = biggest.entry.vendor.isEmpty ? "an unnamed vendor" : biggest.entry.vendor
                flags.append("Largest receipt — \(vendor) at \(dollars(biggest.amount)) — is over 3× your median receipt (\(dollars(median))).")
            }
        }

        return SpendingDigest(
            months: months,
            currentMonthTotal: currentMonth?.total ?? 0,
            currentMonthCount: currentMonth?.count ?? 0,
            previousMonthTotal: previousMonth?.total ?? 0,
            byCategory: totals(byKey: { $0.category }, caseSensitive: false),
            byVendorType: totals(byKey: { $0.vendorType }, label: { VendorTypeToken.displayName(for: $0) }),
            topVendors: Array(totals(byKey: { $0.vendor }, caseSensitive: false).prefix(5)),
            biggestReceipt: biggest.map { ($0.entry.vendor, $0.amount) },
            unusualFlags: flags)
    }

    /// Plain-text rendering of the digest, handed to the model as the *only*
    /// numbers it may talk about.
    static func digestText(_ digest: SpendingDigest) -> String {
        var lines: [String] = ["Spending statistics for the last \(monthsWindow) months:"]
        for month in digest.months {
            lines.append("- \(monthLabel(month.monthStart)): \(dollars(month.total)) across \(month.count) receipts")
        }
        if !digest.byCategory.isEmpty {
            lines.append("By category: " + digest.byCategory.map { "\($0.label) \(dollars($0.total))" }.joined(separator: ", "))
        }
        if !digest.byVendorType.isEmpty {
            lines.append("By business type: " + digest.byVendorType.map { "\($0.label) \(dollars($0.total))" }.joined(separator: ", "))
        }
        if !digest.topVendors.isEmpty {
            lines.append("Top vendors: " + digest.topVendors.map { "\($0.label) \(dollars($0.total))" }.joined(separator: ", "))
        }
        if let biggest = digest.biggestReceipt {
            lines.append("Largest single receipt: \(biggest.vendor.isEmpty ? "unnamed vendor" : biggest.vendor) \(dollars(biggest.amount))")
        }
        for flag in digest.unusualFlags {
            lines.append("Notable: \(flag)")
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)

/// The narrative the on-device model writes over the digest. Text only — by
/// the time the model is involved every number is already computed.
@available(iOS 26.0, *)
@Generable
struct SpendingNarrativeDraft {
    @Guide(description: "Two or three plain, friendly sentences summarizing the provided spending statistics. Only restate numbers exactly as given — never compute, round, or invent figures.")
    var summary: String

    @Guide(description: "Up to three short observations drawn strictly from the provided statistics (largest category, a notable month-to-month change, a standout vendor). Empty if nothing stands out.")
    var observations: [String]
}

@available(iOS 26.0, *)
extension SpendingInsightsService {
    /// On-device narrative over the digest. Throws `FoundationModelsError`
    /// if Apple Intelligence isn't available — callers show the numeric
    /// digest either way; the narrative is purely additive.
    static func narrative(for digest: SpendingDigest) async throws -> SpendingNarrativeDraft {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FoundationModelsError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw FoundationModelsError.modelUnavailable("unknown status")
        }

        let instructions = """
        You summarize personal spending statistics for the owner of these \
        receipts. Use only the numbers provided, exactly as written — never \
        compute new figures, percentages, or totals yourself. Keep a neutral, \
        factual tone; this is tax-record logging, not budgeting advice.
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(
                to: digestText(digest), generating: SpendingNarrativeDraft.self).content
        } catch {
            throw FoundationModelsError.modelUnavailable(error.localizedDescription)
        }
    }
}

#endif
