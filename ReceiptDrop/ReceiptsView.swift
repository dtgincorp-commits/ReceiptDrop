import SwiftUI
import UIKit
import VisionKit

/// Wraps a just-captured bill photo for `.sheet(item:)` presentation —
/// guarantees the review sheet always builds from the exact bytes that
/// triggered it. A plain `Data` + separate `Bool` (`.sheet(isPresented:)`)
/// let the sheet's content closure evaluate against a stale/empty snapshot
/// of the data during the rapid capture → dismiss → present chain, which
/// intermittently sent an empty image to the AI provider.
private struct CapturedBill: Identifiable {
    let id = UUID()
    let data: Data
}

/// Submissions, read from App Group storage and grouped into a Year > Month >
/// Day tree so recent activity is easy to scan. The share extension writes
/// entries while the app is backgrounded, so we refresh whenever it foregrounds.
struct ReceiptsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var categoryStore = CategoryStore.shared
    @StateObject private var receiptsNavigator = ReceiptsNavigator.shared
    @State private var entries: [HistoryEntry] = []
    @State private var commentsMap: [String: String] = [:]
    @State private var newReceiptSource: NewReceiptSource?
    /// Drives the "Try it with a sample receipt" preview — see
    /// `SampleReceiptDemoView`. Lives here rather than as a `NewReceiptSource`
    /// case: every other case in that enum ends up inside a real
    /// `SharedAttachment`/`ReceiptSubmitView` flow that can save, and this
    /// one deliberately never does.
    @State private var showSampleReceiptDemo = false
    /// IDs (year/month/day) the user has manually collapsed. Everything else
    /// starts expanded.
    @State private var collapsed: Set<AnyHashable> = []
    /// Persists across launches — whether the tree groups by the date the
    /// receipt was scanned or the date printed on the receipt itself.
    @AppStorage("receiptsGroupByWorkDate") private var groupByWorkDate = false
    // Same App Group store + key SettingsView writes, so the summary total
    // below always reflects whatever the user picked.
    @AppStorage(AppConstants.DefaultsKeys.appCurrency, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appCurrency: AppCurrency = .auto
    @State private var editingEntry: HistoryEntry?
    @State private var showCategories = false
    /// Set alongside `showCategories` when reached via "Add Category" (rather
    /// than "Manage Categories…") so the sheet opens with the new-category
    /// field ready to type into instead of just the list.
    @State private var focusNewCategoryOnOpen = false
    @State private var showBillCapture = false
    /// Shown instead of the Check a Bill capture screen when no AI provider
    /// is configured — invites the user to connect one rather than letting
    /// them start a capture that would just error at the end.
    @State private var showBillCaptureAIInvite = false
    @State private var capturedBill: CapturedBill?
    /// Bytes from a just-finished capture, held until the `fullScreenCover`
    /// has fully dismissed — presenting the review `.sheet` in the same tick
    /// as the cover's dismissal drops the presentation silently (a sheet
    /// can't reliably present while another presentation is still
    /// transitioning out). Consumed in the cover's `onDismiss`.
    @State private var pendingCapturedBillData: Data?
    /// Same problem in reverse: "Scan a New Bill" from the review sheet
    /// needs the sheet to finish dismissing before the capture
    /// `fullScreenCover` presents. Consumed in the sheet's `onDismiss`.
    @State private var pendingRescan = false
    /// nil shows every category; otherwise the tree only shows this one.
    @State private var filterCategory: String?
    @State private var searchText = ""
    /// Set only after a natural-language search (Return/submit) succeeds in
    /// understanding something — nil means "show the plain instant search
    /// results," not "show nothing."
    @State private var semanticFilter: QueryParseResult?
    @State private var isSemanticSearching = false
    @State private var semanticError: String?
    /// Toggled by the "N receipts need review" banner — shows a flat list of
    /// just those entries instead of the tree, same mechanism as search
    /// results. Replaces per-row pulsing as the primary way of surfacing
    /// this: one calm aggregate call-to-action instead of N animated nags.
    @State private var reviewFilterActive = false
    /// Set by swiping a year header — drives the delete-year confirmation
    /// alert. Same forced-backup-first flow as Settings → Archive & Backup →
    /// Delete Receipts, just reachable without leaving this screen.
    @State private var yearPendingDelete: Int?
    @State private var isDeletingYear = false
    @State private var deleteYearError: String?
    @State private var deleteYearSuccessMessage: String?
    /// Month rows are keyed by their month-start `Date` (see `MonthGroup.id`)
    /// rather than a year/month pair — simpler to carry through the swipe
    /// action and alert, then decomposed into calendar components only where
    /// `ArchiveBackupService.entries(inYear:month:)` actually needs them.
    @State private var monthPendingDelete: Date?
    @State private var isDeletingMonth = false
    @State private var deleteMonthError: String?
    @State private var deleteMonthSuccessMessage: String?
    /// Recomputed on every `reload()`, across the *entire* history — not
    /// scoped to a category or to right-after-a-merge the way the original
    /// duplicate-review flow was. That one-shot version disappeared as soon
    /// as you navigated away, with no way back to it short of re-merging.
    /// This is the durable, always-current replacement.
    @State private var duplicatePairs: [DuplicateDetectionService.Pair] = []

    /// Scales the tree's row insets with the ambient text size. `@ScaledMetric`
    /// reports how far the current size is from the default, so dividing by
    /// the base recovers a plain multiplier we can apply to each row kind's
    /// own inset (see `Row.baseVerticalInset`) rather than needing a separate
    /// `@ScaledMetric` per kind.
    @ScaledMetric(relativeTo: .subheadline) private var rowInsetUnit: CGFloat = 8
    private var rowInsetScale: CGFloat { rowInsetUnit / 8 }

    private var duplicateEntryIDs: Set<UUID> {
        Set(duplicatePairs.flatMap { [$0.first.id, $0.second.id] })
    }

    private var filteredEntries: [HistoryEntry] {
        guard let filterCategory else { return entries }
        // Case-insensitive on purpose. `CategoryStore.add` uppercases every
        // name it stores, but a receipt's own `category` string is whatever
        // it was when the receipt was saved — and restore writes entries
        // back verbatim while feeding their category names through `add`
        // (see `ReceiptModels.restore` / `restoreManifest`). A backup
        // containing "Sample Category" therefore produces an uppercased
        // "SAMPLE CATEGORY" pill with mixed-case receipts hiding behind it,
        // which an exact `==` here rendered permanently unreachable — the
        // pill showed "No Receipts" while the same receipts were plainly
        // visible under "All".
        return entries.filter { $0.category.caseInsensitiveCompare(filterCategory) == .orderedSame }
    }

    private var needsReviewEntries: [HistoryEntry] {
        filteredEntries.filter { $0.verificationStatus == .needsReview }
    }

    /// Matches vendor, amount, category, or work date against the search
    /// text — composes with the category pill filter (both apply together).
    /// A query like ">80", "<50", or ">=100" switches to a numeric amount
    /// comparison; two joined with "and" (e.g. ">20 and <=25") become a
    /// range — both conditions must hold. Comments aren't searchable: they
    /// live only in the CSV, not in HistoryEntry, so including them would
    /// mean parsing every CSV on every keystroke.
    private var searchResults: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        if let conditions = Self.parseAmountConditions(query) {
            return filteredEntries.filter { entry in
                guard let amount = Double(entry.amount) else { return false }
                return conditions.allSatisfy { Self.satisfies(amount: amount, condition: $0) }
            }.sorted { $0.timestamp > $1.timestamp }
        }

        return filteredEntries.filter { entry in
            entry.vendor.lowercased().contains(query)
                || entry.amount.lowercased().contains(query)
                || entry.category.lowercased().contains(query)
                || entry.workDate.lowercased().contains(query)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private enum AmountComparison {
        case greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    }

    private static func satisfies(amount: Double, condition: (AmountComparison, Double)) -> Bool {
        switch condition.0 {
        case .greaterThan: return amount > condition.1
        case .greaterThanOrEqual: return amount >= condition.1
        case .lessThan: return amount < condition.1
        case .lessThanOrEqual: return amount <= condition.1
        }
    }

    /// Parses one or two (joined by " and ") comparisons like ">80",
    /// ">= 100 and <= 150", "<50.25" into comparison + threshold pairs, all
    /// of which must hold. Returns nil for anything that isn't this exact
    /// shape, falling back to ordinary substring search.
    private static func parseAmountConditions(_ query: String) -> [(AmountComparison, Double)]? {
        let parts = query.components(separatedBy: " and ")
        let conditions = parts.compactMap { parseAmountComparison($0.trimmingCharacters(in: .whitespaces)) }
        guard conditions.count == parts.count, !conditions.isEmpty else { return nil }
        return conditions
    }

    /// Parses a single comparison like ">80", ">= 100", "< $20". ">="/"<="
    /// are checked before the single-character operators so they aren't
    /// misread as ">"/"<" followed by a stray "=".
    private static func parseAmountComparison(_ query: String) -> (AmountComparison, Double)? {
        // Strips any supported symbol, not just "$", so ">₹500" works the
        // same as ">$500" — independent of the display currency setting,
        // since a search query's symbol is whatever the user typed.
        let trimmed = AppCurrency.stripKnownSymbols(from: query).trimmingCharacters(in: .whitespaces)
        let operators: [(String, AmountComparison)] = [
            (">=", .greaterThanOrEqual), ("<=", .lessThanOrEqual),
            (">", .greaterThan), ("<", .lessThan),
        ]
        for (prefix, comparison) in operators where trimmed.hasPrefix(prefix) {
            let numberPart = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let value = Double(numberPart) { return (comparison, value) }
        }
        return nil
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Results from the AI-understood filter, if one is active — nil means
    /// no semantic filter is in effect (fall back to `searchResults`). The
    /// vendor-type match is a plain local equality check against
    /// HistoryEntry.vendorType, which was classified once at save time (or
    /// via the "Classify Untyped Receipts" backfill) — no AI call needed
    /// here, unlike the old design which had to ask the AI "which of my
    /// vendors are restaurants?" on every search.
    private var semanticResults: [HistoryEntry]? {
        guard let semanticFilter else { return nil }
        return filteredEntries.filter { entry in
            if let vendorType = semanticFilter.vendorType, !vendorType.isEmpty {
                guard entry.vendorType == vendorType else { return false }
            }
            guard let amount = Double(entry.amount) else {
                return semanticFilter.amountMin == nil && semanticFilter.amountMax == nil
            }
            if let min = semanticFilter.amountMin, amount < min { return false }
            if let max = semanticFilter.amountMax, amount > max { return false }
            return true
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// What the flat list actually displays, in priority order: the "needs
    /// review" filter (if active, via the banner), then the AI-understood
    /// search filter, then the plain instant search.
    private var effectiveSearchResults: [HistoryEntry] {
        if reviewFilterActive {
            return needsReviewEntries.sorted { $0.timestamp > $1.timestamp }
        }
        return semanticResults ?? searchResults
    }

    /// Parses `searchText` via whichever AI provider is configured. Fired on
    /// search-field submit, not per keystroke, since it's a real network
    /// call. If the AI can't extract anything useful, silently falls back to
    /// the plain instant search rather than showing an empty result set.
    private func runSemanticSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard ExtractionSettings.aiConfigured else {
            semanticError = "Smart search needs an AI — connect one in Settings. Plain text search above still works."
            return
        }
        semanticError = nil
        isSemanticSearching = true
        Task {
            do {
                let parsed = try await SemanticSearchService.parseQuery(query)
                await MainActor.run {
                    isSemanticSearching = false
                    semanticFilter = parsed.isEmpty ? nil : parsed
                }
            } catch {
                await MainActor.run {
                    isSemanticSearching = false
                    semanticError = error.localizedDescription
                }
            }
        }
    }

    /// Removable filter chips shown above semantic search results — tapping
    /// a chip's X clears just that part of the filter locally (no new AI
    /// call needed, since the remaining filter is applied the same way).
    @ViewBuilder
    private func semanticChipsRow(for filter: QueryParseResult) -> some View {
        HStack(spacing: 8) {
            if let vendorType = filter.vendorType, !vendorType.isEmpty {
                filterChip(label: VendorTypeToken.displayName(for: vendorType)) {
                    semanticFilter = QueryParseResult(vendorType: nil, amountMin: filter.amountMin, amountMax: filter.amountMax)
                }
            }
            if let min = filter.amountMin, let max = filter.amountMax {
                filterChip(label: "$\(Self.formatAmount(min)) – $\(Self.formatAmount(max))") {
                    semanticFilter = QueryParseResult(vendorType: filter.vendorType, amountMin: nil, amountMax: nil)
                }
            } else if let min = filter.amountMin {
                filterChip(label: "over $\(Self.formatAmount(min))") {
                    semanticFilter = QueryParseResult(vendorType: filter.vendorType, amountMin: nil, amountMax: filter.amountMax)
                }
            } else if let max = filter.amountMax {
                filterChip(label: "under $\(Self.formatAmount(max))") {
                    semanticFilter = QueryParseResult(vendorType: filter.vendorType, amountMin: filter.amountMin, amountMax: nil)
                }
            }
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func filterChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.semibold))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.skyBlueBright.opacity(0.15))
        .foregroundStyle(Theme.skyBlue)
        .clipShape(Capsule())
    }

    private static func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    // MARK: - Summary header (Oura-inspired: totals before the raw list)

    private var summaryTotal: Double {
        filteredEntries.reduce(0.0) { $0 + (Double($1.amount) ?? 0) }
    }

    /// `currencyCode` is `nil` for `.auto`, which leaves the formatter's
    /// locale-derived default in place — the existing behaviour, unchanged.
    /// A non-nil code overrides just the currency shown, independent of the
    /// device's region.
    private static func currencyString(_ value: Double, currencyCode: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        if let currencyCode {
            formatter.currencyCode = currencyCode
        }
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    @ViewBuilder
    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.currencyString(summaryTotal, currencyCode: appCurrency.currencyCode))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("· \(filteredEntries.count) receipt\(filteredEntries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Single calm aggregate call-to-action, replacing per-row pulsing as
    /// the primary way of surfacing receipts needing review — tapping opens
    /// a flat filtered list (same mechanism as search) rather than a chase
    /// of individually-animated rows.
    @ViewBuilder
    private var needsReviewBanner: some View {
        Button {
            reviewFilterActive = true
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(needsReviewEntries.count) receipt\(needsReviewEntries.count == 1 ? "" : "s") need\(needsReviewEntries.count == 1 ? "s" : "") review")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    /// Same layout as `needsReviewBanner`, purple instead of orange so the
    /// two are visually distinct at a glance — always present when
    /// `duplicatePairs` is non-empty, not just right after a merge.
    @ViewBuilder
    private var duplicatesBanner: some View {
        NavigationLink {
            DuplicateReviewView(pairs: $duplicatePairs)
        } label: {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.indigo)
                Text("\(duplicatePairs.count) possible duplicate\(duplicatePairs.count == 1 ? "" : "s") found")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.indigo.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    /// The "add a receipt" choices, shared by the toolbar "+" and the floating
    /// button so the two can't drift apart.
    @ViewBuilder
    private var newReceiptMenuItems: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
                newReceiptSource = .scanDocument
            } label: {
                Label("Scan Receipt", systemImage: "doc.text.viewfinder")
            }
            Button {
                newReceiptSource = .camera
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            // No non-AI fallback makes sense here — raw scanned
            // text with nothing to structure it into fields
            // isn't useful, unlike a photo (which can still be
            // saved and filled in by hand).
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable
                && ExtractionSettings.aiConfigured {
                Button {
                    newReceiptSource = .scanText
                } label: {
                    Label("Scan Text", systemImage: "text.viewfinder")
                }
            }
        }
        Divider()
        Button {
            newReceiptSource = .library
        } label: {
            Label("Choose from Library", systemImage: "photo.on.rectangle")
        }
        Button {
            newReceiptSource = .file
        } label: {
            Label("Choose File", systemImage: "folder")
        }
        Button {
            newReceiptSource = .manual
        } label: {
            Label("Enter Manually", systemImage: "pencil")
        }
        Divider()
        Button {
            focusNewCategoryOnOpen = true
            showCategories = true
        } label: {
            Label("Add Category", systemImage: "folder.badge.plus")
        }
    }

    /// The "+" as WhatsApp draws it: a small filled disc pinned in the header
    /// rather than a floating button. 32pt keeps it in proportion with the
    /// other toolbar glyphs — the toolbar expands the tappable region past the
    /// visible circle, so this stays comfortably above the 44pt minimum
    /// despite the smaller disc.
    private var newReceiptButtonLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Theme.actionBlue, in: Circle())
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    // The single most important screen for a first-time
                    // user: zero receipts, period (not a search or category
                    // filter narrowing an otherwise non-empty list — those
                    // stay plain captions below). Give it a real call to
                    // action instead of leaving the toolbar "+" as the only,
                    // easy-to-miss way in. The button opens the exact same
                    // `newReceiptMenuItems` the toolbar "+" and floating
                    // button already share, so there's one source of truth
                    // for "how to start a new receipt," not a second one.
                    ContentUnavailableCompatView(
                        title: "No Receipts Yet",
                        message: "Receipts you submit will appear here."
                    ) {
                        Menu {
                            newReceiptMenuItems
                        } label: {
                            Label("Scan Your First Receipt", systemImage: "camera.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Theme.actionBlue, in: Capsule())
                        }
                        .padding(.top, 8)

                        // Deliberately a plain-text button below the real
                        // capsule CTA above, not a second capsule or a menu
                        // item next to "Enter Manually" — this is a
                        // no-camera, no-receipt-in-hand fallback for someone
                        // who wants to see the pipeline work before trusting
                        // it with a real receipt (TODO.md item 9), not a
                        // third way to submit one for real. It has to read
                        // as secondary to both scanning and manual entry.
                        // Only shown while the list is genuinely empty, which
                        // is what makes this "first run" without a separate
                        // flag — once a real receipt exists this button is
                        // gone for good, same as the capsule above it.
                        Button("Try it with a sample receipt") {
                            showSampleReceiptDemo = true
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                } else if isSearching || reviewFilterActive {
                    List {
                        categoryPillRow
                        if reviewFilterActive {
                            filterChip(label: "Needs Review") { reviewFilterActive = false }
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                        }
                        if let semanticFilter, semanticResults != nil {
                            semanticChipsRow(for: semanticFilter)
                        }
                        if isSemanticSearching {
                            HStack {
                                ProgressView()
                                Text("Understanding your search…").foregroundStyle(.secondary)
                            }
                            .listRowSeparator(.hidden)
                        }
                        if let semanticError {
                            Text(semanticError).font(.caption).foregroundStyle(.red)
                                .listRowSeparator(.hidden)
                        }
                        if effectiveSearchResults.isEmpty && !isSemanticSearching {
                            ContentUnavailableCompatView(
                                title: "No Matches",
                                message: reviewFilterActive ? "Nothing needs review." : "No receipts match \"\(searchText)\"."
                            )
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(effectiveSearchResults) { entry in
                                ReceiptRow(entry: entry, onReview: { editingEntry = entry },
                                           onConfirm: { confirmReviewed(entry) },
                                           onEdit: { editingEntry = entry },
                                           isDuplicate: duplicateEntryIDs.contains(entry.id))
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            delete(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            editingEntry = entry
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(Theme.skyBlue)
                                        // Only surfaced when there's actually a flag to
                                        // dismiss — this is the "the extracted data was
                                        // fine all along" shortcut, not a general-purpose
                                        // action that belongs on every row.
                                        if entry.verificationStatus == .needsReview {
                                            Button {
                                                confirmReviewed(entry)
                                            } label: {
                                                Label("Confirm", systemImage: "checkmark.circle.fill")
                                            }
                                            .tint(.green)
                                        }
                                    }
                            }
                        }
                    }
                    .listStyle(.plain)
                } else if filteredEntries.isEmpty {
                    List {
                        categoryPillRow
                        ContentUnavailableCompatView(
                            title: "No Receipts",
                            message: "No receipts in \(filterCategory ?? "this category") yet."
                        )
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                } else {
                    List {
                        summaryHeader
                        if !needsReviewEntries.isEmpty {
                            needsReviewBanner
                        }
                        if !duplicatePairs.isEmpty {
                            duplicatesBanner
                        }
                        categoryPillRow
                        ForEach(flatRows(from: YearGroup.build(from: filteredEntries, groupByWorkDate: groupByWorkDate))) { row in
                            rowView(for: row)
                                // Scaled, not fixed: `listRowInsets` is the
                                // dominant contributor to row height once the
                                // text itself is small, so a flat value here
                                // caps how much density the small text-size
                                // setting can actually buy — the glyphs
                                // shrink but the padding around them doesn't.
                                // `rowInsetScale` is 1.0 at the default text
                                // size, so this is a no-op there.
                                .listRowInsets(EdgeInsets(
                                    top: row.baseVerticalInset * rowInsetScale,
                                    leading: 16,
                                    bottom: row.baseVerticalInset * rowInsetScale,
                                    trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if case .entry(let entry) = row.kind {
                                        Button(role: .destructive) {
                                            delete(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    } else if case .year(let year) = row.kind {
                                        Button(role: .destructive) {
                                            yearPendingDelete = year.id
                                        } label: {
                                            Label("Delete Year", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    } else if case .month(let month) = row.kind {
                                        Button(role: .destructive) {
                                            monthPendingDelete = month.id
                                        } label: {
                                            Label("Delete Month", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if case .entry(let entry) = row.kind {
                                        Button {
                                            editingEntry = entry
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(Theme.skyBlue)
                                        // Same "flag was a false alarm" shortcut as the
                                        // search-results list above — only shown when
                                        // the entry is actually flagged.
                                        if entry.verificationStatus == .needsReview {
                                            Button {
                                                confirmReviewed(entry)
                                            } label: {
                                                Label("Confirm", systemImage: "checkmark.circle.fill")
                                            }
                                            .tint(.green)
                                        }
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    // The actual density constraint. `List` enforces a 44pt
                    // minimum row height, which the year/month/day headers
                    // were sitting exactly at — so trimming their
                    // `listRowInsets` alone changed nothing, the rows were
                    // held open by the floor rather than by their padding.
                    // Lowered to 32pt: still a comfortable tap target for
                    // the collapse/expand gesture (Apple's 44pt guidance is
                    // about isolated controls; these are full-width rows),
                    // while letting the trimmed insets actually take effect.
                    // Receipt rows are taller than this on their own, so
                    // they're unaffected.
                    .environment(\.defaultMinListRowHeight, 32 * rowInsetScale)
                }
            }
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: ExtractionSettings.aiConfigured ? "Search, or try \"restaurants over $100\"" : "Search receipts")
            .onSubmit(of: .search) { runSemanticSearch() }
            .onChange(of: searchText) { _ in
                semanticFilter = nil
                semanticError = nil
                reviewFilterActive = false
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            groupByWorkDate = false
                        } label: {
                            if !groupByWorkDate {
                                Label("Group by Scan Date", systemImage: "checkmark")
                            } else {
                                Text("Group by Scan Date")
                            }
                        }
                        Button {
                            groupByWorkDate = true
                        } label: {
                            if groupByWorkDate {
                                Label("Group by Receipt Date", systemImage: "checkmark")
                            } else {
                                Text("Group by Receipt Date")
                            }
                        }
                        Divider()
                        Button {
                            collapsed = []
                        } label: {
                            Label("Expand All", systemImage: "chevron.down")
                        }
                        Button {
                            collapseAllToYears()
                        } label: {
                            Label("Collapse All", systemImage: "chevron.right")
                        }
                        Divider()
                        Button {
                            focusNewCategoryOnOpen = false
                            showCategories = true
                        } label: {
                            Label("Manage Categories…", systemImage: "folder.badge.gearshape")
                        }
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    // Hidden entirely for providers whose itemization isn't
                    // good enough to offer (currently Apple On-Device) —
                    // better than letting someone run it and conclude the
                    // feature is broken. See `supportsBillItemization`.
                    if ExtractionSettings.provider.supportsBillItemization {
                        Button {
                            if ExtractionSettings.aiConfigured {
                                showBillCapture = true
                            } else {
                                showBillCaptureAIInvite = true
                            }
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .accessibilityLabel("Check a Bill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        newReceiptMenuItems
                    } label: {
                        newReceiptButtonLabel
                    }
                    .accessibilityLabel("New Receipt")
                }
            }
        }
        .sheet(item: $newReceiptSource) { source in
            NewReceiptView(source: source, onComplete: reload)
        }
        .sheet(isPresented: $showSampleReceiptDemo) {
            SampleReceiptDemoView(onDone: { showSampleReceiptDemo = false })
        }
        .fullScreenCover(isPresented: $showBillCapture, onDismiss: {
            // Runs after the cover has fully finished dismissing, so
            // presenting the review sheet here can't collide with that
            // transition still being in flight.
            if let data = pendingCapturedBillData {
                pendingCapturedBillData = nil
                capturedBill = CapturedBill(data: data)
            }
        }) {
            BillCaptureView(
                onCancel: { showBillCapture = false },
                onCaptured: { data in
                    pendingCapturedBillData = data
                    showBillCapture = false
                })
        }
        .sheet(isPresented: $showBillCaptureAIInvite) {
            AIFeatureInviteView(
                title: "Check a Bill needs an AI",
                message: "This reads a bill line-by-line and splits out each item — it needs an AI connected to do that reading. Takes about two minutes to set up.",
                dismiss: { showBillCaptureAIInvite = false })
        }
        .sheet(item: $capturedBill, onDismiss: {
            // Same reasoning as above, in reverse: present the capture
            // cover only once this sheet has fully dismissed.
            if pendingRescan {
                pendingRescan = false
                showBillCapture = true
            }
        }) { bill in
            BillReviewView(
                photoData: bill.data,
                onDone: {
                    capturedBill = nil
                    reload()
                },
                onScanNew: {
                    pendingRescan = true
                    capturedBill = nil
                })
                // Only "Done" or "Scan a New Bill" should close this — an
                // accidental swipe-down was closing it before the user had
                // finished reading.
                .interactiveDismissDisabled(true)
        }
        .sheet(item: $editingEntry) { entry in
            EditReceiptView(
                entry: entry,
                onCancel: { editingEntry = nil },
                onComplete: {
                    editingEntry = nil
                    reload()
                })
        }
        .sheet(isPresented: $showCategories, onDismiss: reload) {
            NavigationStack {
                CategoriesView(focusNewCategoryOnAppear: focusNewCategoryOnOpen, onShowReceipts: { category in
                    filterCategory = category
                    showCategories = false
                })
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .receiptDropDidUpdateHistory)) { _ in
            reload()
        }
        // Picks up a cross-tab filter request from Settings → Categories —
        // see `ReceiptsNavigator`. Cleared immediately after applying so it
        // doesn't reapply on some later, unrelated appearance of this view.
        .onChange(of: receiptsNavigator.pendingCategoryFilter) {
            guard let category = $0 else { return }
            filterCategory = category
            receiptsNavigator.pendingCategoryFilter = nil
        }
        .alert("Delete \(yearPendingDelete.map(String.init) ?? "") Receipts?",
               isPresented: Binding(
                get: { yearPendingDelete != nil },
                set: { if !$0 { yearPendingDelete = nil } }),
               presenting: yearPendingDelete) { year in
            Button("Cancel", role: .cancel) {}
            Button("Back Up, Then Delete", role: .destructive) {
                deleteYear(year)
            }
        } message: { year in
            let count = ArchiveBackupService.entries(inYear: year).count
            Text("A full backup will be made first. Then \(count) receipt\(count == 1 ? "" : "s") from \(String(year)) — including photos — will be permanently deleted. This can only be undone by restoring that backup, and only while it still exists on this phone (the 3 most recent backups are kept).")
        }
        .alert("Couldn't Delete Year", isPresented: Binding(
            get: { deleteYearError != nil },
            set: { if !$0 { deleteYearError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteYearError ?? "")
        }
        .alert("Year Deleted", isPresented: Binding(
            get: { deleteYearSuccessMessage != nil },
            set: { if !$0 { deleteYearSuccessMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteYearSuccessMessage ?? "")
        }
        .alert("Delete \(monthPendingDelete.map(Self.monthYearLabel) ?? "") Receipts?",
               isPresented: Binding(
                get: { monthPendingDelete != nil },
                set: { if !$0 { monthPendingDelete = nil } }),
               presenting: monthPendingDelete) { monthStart in
            Button("Cancel", role: .cancel) {}
            Button("Back Up, Then Delete", role: .destructive) {
                deleteMonth(monthStart)
            }
        } message: { monthStart in
            let (year, month) = Self.yearMonthComponents(monthStart)
            let count = ArchiveBackupService.entries(inYear: year, month: month).count
            Text("A full backup will be made first. Then \(count) receipt\(count == 1 ? "" : "s") from \(Self.monthYearLabel(monthStart)) — including photos — will be permanently deleted. This can only be undone by restoring that backup, and only while it still exists on this phone (the 3 most recent backups are kept).")
        }
        .alert("Couldn't Delete Month", isPresented: Binding(
            get: { deleteMonthError != nil },
            set: { if !$0 { deleteMonthError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteMonthError ?? "")
        }
        .alert("Month Deleted", isPresented: Binding(
            get: { deleteMonthSuccessMessage != nil },
            set: { if !$0 { deleteMonthSuccessMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteMonthSuccessMessage ?? "")
        }
    }

    private static func yearMonthComponents(_ date: Date) -> (year: Int, month: Int) {
        let calendar = Calendar.current
        return (calendar.component(.year, from: date), calendar.component(.month, from: date))
    }

    private static func monthYearLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    /// Mirrors `deleteYear(_:)` exactly, scoped to one month instead of a
    /// whole year — see that function's doc comment for why this isn't
    /// shared with the Settings screen's copy.
    private func deleteMonth(_ monthStart: Date) {
        deleteMonthError = nil
        deleteMonthSuccessMessage = nil
        isDeletingMonth = true
        let (year, month) = Self.yearMonthComponents(monthStart)
        let label = Self.monthYearLabel(monthStart)
        Task {
            do {
                let backupURL = try ArchiveBackupService.buildFullBackup()
                let monthEntries = ArchiveBackupService.entries(inYear: year, month: month)
                for entry in monthEntries {
                    SubmissionStore.removeHistory(entry)
                    try? LocalReceiptStore.deleteEntry(
                        category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                        amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
                }
                await MainActor.run {
                    BackupSettings.lastBackupDate = Date()
                    isDeletingMonth = false
                    reload()
                    deleteMonthSuccessMessage = """
                        Backed up to Files → On My iPhone → Receipts4Tax → Backups → \(backupURL.lastPathComponent)

                        Deleted \(monthEntries.count) receipt\(monthEntries.count == 1 ? "" : "s") for \(label).
                        """
                }
            } catch {
                await MainActor.run {
                    isDeletingMonth = false
                    deleteMonthError = "Backup failed, so nothing was deleted: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Same forced-backup-then-delete flow as Settings → Archive & Backup →
    /// Delete Receipts (see `performDeleteYear` there) — kept as a separate
    /// copy rather than a shared helper since the two call sites reload
    /// differently afterward (this screen's own `reload()` vs. that screen's
    /// local `lastBackupDate`/`localBackups` state).
    private func deleteYear(_ year: Int) {
        deleteYearError = nil
        deleteYearSuccessMessage = nil
        isDeletingYear = true
        Task {
            do {
                let backupURL = try ArchiveBackupService.buildFullBackup()
                let yearEntries = ArchiveBackupService.entries(inYear: year)
                for entry in yearEntries {
                    SubmissionStore.removeHistory(entry)
                    try? LocalReceiptStore.deleteEntry(
                        category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                        amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
                }
                await MainActor.run {
                    BackupSettings.lastBackupDate = Date()
                    isDeletingYear = false
                    reload()
                    deleteYearSuccessMessage = """
                        Backed up to Files → On My iPhone → Receipts4Tax → Backups → \(backupURL.lastPathComponent)

                        Deleted \(yearEntries.count) receipt\(yearEntries.count == 1 ? "" : "s") for \(year).
                        """
                }
            } catch {
                await MainActor.run {
                    isDeletingYear = false
                    deleteYearError = "Backup failed, so nothing was deleted: \(error.localizedDescription)"
                }
            }
        }
    }

    private func reload() {
        entries = SubmissionStore.loadHistory()
        // One CSV parse per category, not per row — see commentsByReceipt.
        commentsMap = LocalReceiptStore.commentsByReceipt(
            categories: Array(Set(entries.map(\.category))))
        duplicatePairs = DuplicateDetectionService.findPairs(in: entries)
    }

    /// The AI-written Comments for this entry (its per-receipt summary), or
    /// empty if the CSV row is gone or had no comments.
    private func summary(for entry: HistoryEntry) -> String {
        commentsMap[LocalReceiptStore.commentsKey(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink)] ?? ""
    }

    /// `categoryFilterRow` wrapped for use as the List's own first row
    /// (rather than a sibling VStack element) — the List needs to be the
    /// single scrollable view directly under the navigation title for
    /// .searchable's pull-down-to-reveal / scroll-to-hide behavior to work;
    /// splitting the pills into a separate VStack sibling broke that.
    private var categoryPillRow: some View {
        categoryFilterRow
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Horizontal row of tappable category pills — tap one to filter the
    /// tree down to just that category, tap "All" (or the same pill again)
    /// to clear the filter. Wrapped in a `ScrollViewReader` so a filter set
    /// from elsewhere (the Categories sheet's Receipts row) scrolls the
    /// newly-selected pill into view instead of leaving it offscreen.
    private var categoryFilterRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill(label: "All", isSelected: filterCategory == nil) {
                        filterCategory = nil
                    }
                    .id(String?.none as String?)
                    ForEach(categoryStore.categories, id: \.self) { category in
                        filterPill(label: category, isSelected: filterCategory == category) {
                            filterCategory = (filterCategory == category) ? nil : category
                        }
                        .id(String?.some(category))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: filterCategory) { newValue in
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func filterPill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Theme.skyBlueBright : Color.gray.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Collapses every month (which also hides the days beneath it) while
    /// leaving Year headers visible and expandable — a compact overview
    /// rather than hiding everything, including the years themselves.
    private func collapseAllToYears() {
        let years = YearGroup.build(from: filteredEntries, groupByWorkDate: groupByWorkDate)
        collapsed = Set(years.flatMap { year in year.months.map { AnyHashable($0.id) } })
    }

    /// Runs off the main thread — same reasoning as `DuplicateReviewView
    /// .delete`: `LocalReceiptStore.deleteEntry` rewrites the category's CSV
    /// through `NSFileCoordinator`, which can genuinely stall for a few
    /// seconds under contention (e.g. the Files app browsing the same
    /// folder). Calling it synchronously from the swipe action froze the
    /// whole screen for however long that took.
    private func delete(_ entry: HistoryEntry) {
        Task {
            SubmissionStore.removeHistory(entry)
            try? LocalReceiptStore.deleteEntry(
                category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
            await MainActor.run { reload() }
        }
    }

    /// Dismisses a `.needsReview` flag in place — for when the tester looks
    /// at the already-extracted vendor/amount/date and decides it was right
    /// all along, so the only thing worth doing is clearing the flag, not
    /// resaving the whole entry through Edit. Unlike `delete`, this never
    /// touches the CSV or filesystem — `SubmissionPipeline.confirmReviewed`
    /// only rewrites the App Group History store, which is fast enough to
    /// call straight from the main thread, no `Task`/off-main hop needed.
    private func confirmReviewed(_ entry: HistoryEntry) {
        SubmissionPipeline.confirmReviewed(entry)
        reload()
    }

    /// Flattens the Year > Month > Day > receipt tree into a single list of
    /// rows, skipping children of anything collapsed. Every row shares the
    /// same list-row insets, so headers and receipts all share one left
    /// margin instead of the staircase indent `DisclosureGroup` nesting gives.
    private func flatRows(from years: [YearGroup]) -> [Row] {
        var rows: [Row] = []
        for year in years {
            rows.append(Row(id: AnyHashable(year.id), kind: .year(year)))
            guard !collapsed.contains(AnyHashable(year.id)) else { continue }
            for month in year.months {
                rows.append(Row(id: AnyHashable(month.id), kind: .month(month)))
                guard !collapsed.contains(AnyHashable(month.id)) else { continue }
                for day in month.days {
                    rows.append(Row(id: AnyHashable(day.id), kind: .day(day)))
                    guard !collapsed.contains(AnyHashable(day.id)) else { continue }
                    for entry in day.entries {
                        rows.append(Row(id: AnyHashable(entry.id), kind: .entry(entry)))
                    }
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(for row: Row) -> some View {
        switch row.kind {
        case .year(let year):
            HeaderRow(label: year.label, font: .title3.bold(), level: 0,
                     isExpanded: expandedBinding(for: row.id))
        case .month(let month):
            HeaderRow(label: month.label, font: .headline, level: 1,
                     isExpanded: expandedBinding(for: row.id))
        case .day(let day):
            HeaderRow(label: day.label, font: .subheadline.bold(), level: 2,
                     isExpanded: expandedBinding(for: row.id))
        case .entry(let entry):
            ReceiptRow(entry: entry, onReview: { editingEntry = entry },
                       onConfirm: { confirmReviewed(entry) },
                       onEdit: { editingEntry = entry },
                       isDuplicate: duplicateEntryIDs.contains(entry.id))
        }
    }

    private func expandedBinding(for id: AnyHashable) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(id) } else { collapsed.insert(id) }
            })
    }

    private struct Row: Identifiable {
        let id: AnyHashable
        let kind: Kind
        enum Kind {
            case year(YearGroup)
            case month(MonthGroup)
            case day(DayGroup)
            case entry(HistoryEntry)
        }

        /// Header rows carry their own font and read as structure, not
        /// content, so they get tighter vertical insets than receipt rows —
        /// with the day header (the one repeated most often, once per day
        /// with receipts) tightest of all. Previously every row shared a
        /// flat 8pt top/bottom, which meant three stacked headers
        /// (year → month → day) spent ~48pt of fixed padding before the
        /// first receipt appeared.
        var baseVerticalInset: CGFloat {
            switch kind {
            case .year: return 6
            case .month: return 4
            case .day: return 3
            // A typical receipt row is a single line of text carrying ~28pt
            // of padding around it (this inset top and bottom, plus
            // ReceiptRow's own vertical padding) — two thirds of the row's
            // height was empty space rather than content.
            case .entry: return 5
            }
        }
    }
}

/// A collapsible year/month/day header. `level` steps the label in slightly
/// per depth (year 0, month 1, day 2) while receipt rows stay unindented, so
/// the tree reads top-to-bottom without the badge/vendor line drifting.
private struct HeaderRow: View {
    let label: String
    let font: Font
    let level: Int
    @Binding var isExpanded: Bool

    /// Year stays the colored anchor of the hierarchy; Month/Day go quieter
    /// and uppercase-tracked (Oura-style micro-labels) so they read as
    /// structure rather than competing with the year for attention.
    private var color: Color { level <= 1 ? Theme.skyBlue : .secondary }

    var body: some View {
        HStack {
            Text(label)
                .font(font)
                .foregroundStyle(color)
                .textCase(level == 0 ? nil : .uppercase)
                .tracking(level == 0 ? 0 : 0.6)
                .padding(.leading, CGFloat(level) * 14)
            Spacer()
            Image(systemName: "chevron.down")
                // .caption2 rather than .caption: the chevron sets the row's
                // minimum height whenever it's taller than the label, which
                // for the day header (.subheadline) it otherwise is — so the
                // smallest, most-repeated header row was being held open by
                // its own disclosure arrow.
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
    }
}

// MARK: - Tree grouping

private struct DayGroup: Identifiable {
    let id: Date
    let label: String
    let entries: [HistoryEntry]
}

private struct MonthGroup: Identifiable {
    let id: Date
    let label: String
    let days: [DayGroup]
}

private struct YearGroup: Identifiable {
    let id: Int
    let label: String
    let months: [MonthGroup]

    /// Groups entries by calendar day, then month, then year, each sorted
    /// newest-first, with day labels like "July 14th, Tuesday". When
    /// `groupByWorkDate` is true, entries group by the date printed on the
    /// receipt instead of when it was scanned; entries with a missing or
    /// unparseable work date fall back to their scan date so nothing goes
    /// missing from the tree.
    static func build(from entries: [HistoryEntry], groupByWorkDate: Bool) -> [YearGroup] {
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        let workDateFormatter = DateFormatter()
        workDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        workDateFormatter.dateFormat = AppConstants.sheetDateFormat

        func groupingDate(for entry: HistoryEntry) -> Date {
            if groupByWorkDate, !entry.workDate.isEmpty,
               let parsed = workDateFormatter.date(from: entry.workDate) {
                return calendar.startOfDay(for: parsed)
            }
            return calendar.startOfDay(for: entry.timestamp)
        }

        let byDay = Dictionary(grouping: entries, by: groupingDate)
        let days: [(date: Date, group: DayGroup)] = byDay.map { date, items in
            let dayNumber = calendar.component(.day, from: date)
            let label = "\(monthFormatter.string(from: date)) \(dayNumber)\(ordinalSuffix(dayNumber)), \(weekdayFormatter.string(from: date))"
            let sorted = items.sorted { $0.timestamp > $1.timestamp }
            return (date, DayGroup(id: date, label: label, entries: sorted))
        }

        let byMonth = Dictionary(grouping: days) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        let months: [(date: Date, group: MonthGroup)] = byMonth.map { monthStart, dayEntries in
            let sortedDays = dayEntries.sorted { $0.date > $1.date }.map { $0.group }
            return (monthStart, MonthGroup(id: monthStart, label: monthFormatter.string(from: monthStart), days: sortedDays))
        }

        let byYear = Dictionary(grouping: months) { calendar.component(.year, from: $0.date) }
        let years: [YearGroup] = byYear.map { year, monthEntries in
            let sortedMonths = monthEntries.sorted { $0.date > $1.date }.map { $0.group }
            return YearGroup(id: year, label: String(year), months: sortedMonths)
        }
        return years.sorted { $0.id > $1.id }
    }

    private static func ordinalSuffix(_ day: Int) -> String {
        switch (day % 10, day % 100) {
        case (1, let hundreds) where hundreds != 11: return "st"
        case (2, let hundreds) where hundreds != 12: return "nd"
        case (3, let hundreds) where hundreds != 13: return "rd"
        default: return "th"
        }
    }
}

// MARK: - Row

private struct ReceiptRow: View {
    let entry: HistoryEntry
    let onReview: () -> Void
    let onConfirm: () -> Void
    /// Opens Edit for this entry on the parent screen — rows can't present
    /// `EditReceiptView` themselves because `editingEntry`/its sheet live up
    /// on `ReceiptsView`. Same callback-up pattern as `onReview`/`onConfirm`.
    let onEdit: () -> Void
    var isDuplicate: Bool = false

    @State private var showPreview = false
    /// Set when the user taps the preview's summary bar, and acted on only
    /// once the preview sheet has actually finished dismissing (see the
    /// `onDismiss` below).
    @State private var editAfterPreview = false
    @State private var missingFileAlert = false
    @State private var missingCSVAlert = false

    // Scale with the ambient text-size setting (System default, or the
    // AppTextSize override applied at the TabView root) rather than staying
    // fixed at 6pt regardless — plain Dynamic Type only scales text itself,
    // so without this the row's own chrome would stay exactly as tall at
    // Small as at Large, and the text-size picker would barely change how
    // many receipts fit on screen. At Medium (the default) these evaluate to
    // exactly 6, unchanged from before.
    @ScaledMetric(relativeTo: .subheadline) private var rowSpacing: CGFloat = 4
    @ScaledMetric(relativeTo: .subheadline) private var verticalPadding: CGFloat = 4

    private var isManualEntry: Bool { entry.receiptLink == SubmissionPipeline.manualEntryLabel }
    private var isScannedText: Bool { entry.receiptLink == SubmissionPipeline.scannedTextLabel }
    private var hasPrimaryFile: Bool {
        !entry.receiptLink.isEmpty && !SubmissionPipeline.isPlaceholderLabel(entry.receiptLink)
    }
    /// Whether tapping the row should open a preview at all — true if there's
    /// a real primary file, or (even for manual/scanned-text entries with no
    /// primary photo) if extras were attached after the fact via Edit.
    private var hasFile: Bool { hasPrimaryFile || !entry.extraFiles.isEmpty }

    /// Same three mutually-exclusive cases and paperclip-count logic as
    /// before (manual entries and scanned-text entries count only their
    /// extras; a receipt with a real primary file counts extras + 1) — just
    /// placed inline in the main row instead of claiming a full line of its
    /// own. Icon sizing/color per case is unchanged too, including
    /// `doc.text.magnifyingglass` deliberately having no `.font()` override
    /// (renders at the default, slightly larger icon size).
    @ViewBuilder
    private var sourceIndicator: some View {
        if isManualEntry {
            if !entry.extraFiles.isEmpty {
                Label("\(entry.extraFiles.count)", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "pencil")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if isScannedText {
            if !entry.extraFiles.isEmpty {
                Label("\(entry.extraFiles.count)", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "text.viewfinder")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if hasFile {
            if !entry.extraFiles.isEmpty {
                Label("\(entry.extraFiles.count + 1)", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Theme.skyBlue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    openCategoryCSV()
                } label: {
                    // Back to the accent color per user preference — sharper
                    // corners and tighter padding than the original for a
                    // sleeker, Oura-like tag rather than a soft badge.
                    Text(entry.category)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.skyBlueBright)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                if isDuplicate {
                    // Same visual language as the category tag right next to
                    // it (same font/padding/corner treatment) so it reads as
                    // a sibling badge, not a different kind of UI element —
                    // just a different, alarm-toned color to stand apart.
                    Text("DUP")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.indigo)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .fixedSize()
                }
                Text(entry.vendor.isEmpty ? "Unknown vendor" : entry.vendor)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if entry.verificationStatus == .needsReview {
                    // Static, not pulsing — the aggregate "N receipts need
                    // review" banner above the list is now the primary,
                    // calmer way this gets surfaced; this stays as a quiet
                    // per-row marker for browsing the tree directly.
                    Button(action: onReview) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                } else if entry.verificationStatus == .verified {
                    ZStack {
                        Circle().fill(Color.green)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.black)
                    }
                    .frame(width: 18, height: 18)
                }
                // Folded into the main line rather than a line of its own —
                // it's purely an affordance (the whole row is already
                // tappable), not information that needs its own vertical
                // space. This is what actually shrinks row height; the
                // text-size setting alone couldn't, since Dynamic Type only
                // scales text, not a whole extra line.
                sourceIndicator
                if !entry.amount.isEmpty {
                    Text("$\(entry.amount)")
                        .font(.subheadline.weight(.bold))
                }
            }
            if entry.verificationStatus == .needsReview, !entry.reviewReason.isEmpty {
                HStack {
                    Spacer()
                    Text("Needs review — \(entry.reviewReason)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    // Right where the flag is actually read, not just on a
                    // swipe gesture someone might never discover — this is
                    // the moment they're already deciding whether the flag
                    // is worth acting on.
                    Button(action: onConfirm) {
                        Label("Looks Good", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasFile else { return }
            if LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink) != nil {
                showPreview = true
            } else {
                missingFileAlert = true
            }
        }
        // `onDismiss`, deliberately — do NOT "simplify" this into calling
        // `onEdit()` straight from the tap. Edit is presented by a different
        // sheet (`.sheet(item: $editingEntry)`) on `ReceiptsView`, and SwiftUI
        // won't reliably present a second sheet while this one is still up:
        // the request is either dropped or fights the dismissal. So the tap
        // only records the intent and dismisses; `onDismiss` fires after the
        // preview is genuinely gone, which is the deterministic moment the
        // Edit sheet is free to present.
        .sheet(isPresented: $showPreview, onDismiss: {
            guard editAfterPreview else { return }
            editAfterPreview = false
            onEdit()
        }) {
            let urls = previewURLs()
            if !urls.isEmpty {
                ReceiptPreviewSheet(entry: entry, urls: urls, onEdit: {
                    editAfterPreview = true
                    showPreview = false
                })
            }
        }
        .alert("File not found", isPresented: $missingFileAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(entry.receiptLink) couldn't be located — it may have been moved or deleted in the Files app.")
        }
        .alert("CSV not found", isPresented: $missingCSVAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No log file yet for \(entry.category) — open the app once to let it save, then try again.")
        }
    }

    private func previewURLs() -> [URL] { ReceiptPreviewSheet.urls(for: entry) }

    /// Deep-links into the Files app at this category's CSV log using the
    /// `shareddocuments://` scheme (works for files in the app's own visible
    /// Documents directory).
    private func openCategoryCSV() {
        guard let fileURL = LocalReceiptStore.documentsLogFileURL(category: entry.category),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            missingCSVAlert = true
            return
        }
        let urlString = fileURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        guard let filesURL = URL(string: urlString) else {
            missingCSVAlert = true
            return
        }
        UIApplication.shared.open(filesURL)
    }
}

/// Shown in place of an AI-only feature (currently just Check a Bill) when no
/// provider is configured — invites the user into the Connect AI wizard
/// rather than either hiding the entry point or letting them hit a raw error
/// partway through. Not reused for every AI-only feature (search and
/// classify show an inline message instead, since they have a "keep going
/// without AI" path this feature doesn't).
private struct AIFeatureInviteView: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    @State private var showConnectAI = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    showConnectAI = true
                } label: {
                    Text("Connect an AI")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .padding(.top, 8)
                Button("Not Now", action: dismiss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss)
                }
            }
        }
        .sheet(isPresented: $showConnectAI) {
            ConnectAIView {
                showConnectAI = false
                dismiss()
            }
        }
    }
}
