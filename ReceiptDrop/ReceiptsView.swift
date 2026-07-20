import SwiftUI
import UIKit
import VisionKit

/// Submissions, read from App Group storage and grouped into a Year > Month >
/// Day tree so recent activity is easy to scan. The share extension writes
/// entries while the app is backgrounded, so we refresh whenever it foregrounds.
struct ReceiptsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var categoryStore = CategoryStore.shared
    @State private var entries: [HistoryEntry] = []
    @State private var newReceiptSource: NewReceiptSource?
    /// IDs (year/month/day) the user has manually collapsed. Everything else
    /// starts expanded.
    @State private var collapsed: Set<AnyHashable> = []
    /// Persists across launches — whether the tree groups by the date the
    /// receipt was scanned or the date printed on the receipt itself.
    @AppStorage("receiptsGroupByWorkDate") private var groupByWorkDate = false
    @State private var editingEntry: HistoryEntry?
    @State private var showCategories = false
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

    private var filteredEntries: [HistoryEntry] {
        guard let filterCategory else { return entries }
        return entries.filter { $0.category == filterCategory }
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
        let trimmed = query.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
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

    private static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    @ViewBuilder
    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.currencyString(summaryTotal))
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

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableCompatView(
                        title: "No Receipts Yet",
                        message: "Receipts you submit will appear here."
                    )
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
                                ReceiptRow(entry: entry, onReview: { editingEntry = entry })
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
                        categoryPillRow
                        ForEach(flatRows(from: YearGroup.build(from: filteredEntries, groupByWorkDate: groupByWorkDate))) { row in
                            rowView(for: row)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if case .entry(let entry) = row.kind {
                                        Button(role: .destructive) {
                                            delete(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
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
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search, or try \"restaurants over $100\"")
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
                                Label("Group by Work Date", systemImage: "checkmark")
                            } else {
                                Text("Group by Work Date")
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
                            showCategories = true
                        } label: {
                            Label("Manage Categories…", systemImage: "folder.badge.gearshape")
                        }
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal")
                    }
                    .tint(.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                newReceiptSource = .scanDocument
                            } label: {
                                Label("Scan Documents", systemImage: "doc.text.viewfinder")
                            }
                            Button {
                                newReceiptSource = .camera
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                Button {
                                    newReceiptSource = .scanText
                                } label: {
                                    Label("Scan Text", systemImage: "text.viewfinder")
                                }
                            }
                        }
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
                    } label: {
                        Label("New Receipt", systemImage: "plus")
                    }
                    .tint(.white)
                }
            }
        }
        .sheet(item: $newReceiptSource) { source in
            NewReceiptView(source: source, onComplete: reload)
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
                CategoriesView()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
    }

    private func reload() {
        entries = SubmissionStore.loadHistory()
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
    /// to clear the filter.
    private var categoryFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(label: "All", isSelected: filterCategory == nil) {
                    filterCategory = nil
                }
                ForEach(categoryStore.categories, id: \.self) { category in
                    filterPill(label: category, isSelected: filterCategory == category) {
                        filterCategory = (filterCategory == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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

    private func delete(_ entry: HistoryEntry) {
        SubmissionStore.removeHistory(entry)
        try? LocalReceiptStore.deleteEntry(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
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
            ReceiptRow(entry: entry, onReview: { editingEntry = entry })
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
    private var color: Color { level == 0 ? Theme.skyBlue : .secondary }

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
                .font(.caption.weight(.bold))
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

    @State private var showPreview = false
    @State private var missingFileAlert = false
    @State private var missingCSVAlert = false

    private var isManualEntry: Bool { entry.receiptLink == SubmissionPipeline.manualEntryLabel }
    private var isScannedText: Bool { entry.receiptLink == SubmissionPipeline.scannedTextLabel }
    private var hasPrimaryFile: Bool {
        !entry.receiptLink.isEmpty && !SubmissionPipeline.isPlaceholderLabel(entry.receiptLink)
    }
    /// Whether tapping the row should open a preview at all — true if there's
    /// a real primary file, or (even for manual/scanned-text entries with no
    /// primary photo) if extras were attached after the fact via Edit.
    private var hasFile: Bool { hasPrimaryFile || !entry.extraFiles.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    openCategoryCSV()
                } label: {
                    // Neutral rather than accent-colored: color is reserved
                    // for things that mean something (orange = needs review,
                    // green = verified, red = delete) — a category tag on
                    // every single row doesn't need to compete for that.
                    Text(entry.category)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 0.5)
                        .padding(.vertical, 0.25)
                        .background(Color.gray.opacity(0.15))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
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
                }
            }
            if isManualEntry {
                // Icon-only rather than a text label — the icon already
                // carries the meaning once you know the app; quieter, less
                // visual noise competing with the vendor/amount line above.
                HStack {
                    Spacer()
                    if !entry.extraFiles.isEmpty {
                        Label("\(entry.extraFiles.count)", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if isScannedText {
                HStack {
                    Spacer()
                    if !entry.extraFiles.isEmpty {
                        Label("\(entry.extraFiles.count)", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "text.viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if hasFile {
                HStack {
                    Spacer()
                    if !entry.extraFiles.isEmpty {
                        Label("\(entry.extraFiles.count + 1)", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Theme.skyBlue)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasFile else { return }
            if LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink) != nil {
                showPreview = true
            } else {
                missingFileAlert = true
            }
        }
        .sheet(isPresented: $showPreview) {
            let urls = previewURLs()
            if !urls.isEmpty {
                ReceiptPreviewView(urls: urls)
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

    /// Primary file first, then any extras, skipping any that can't be found
    /// (e.g. moved/deleted outside the app) rather than failing the preview.
    private func previewURLs() -> [URL] {
        var urls: [URL] = []
        if let primary = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink) {
            urls.append(primary)
        }
        for extra in entry.extraFiles {
            if let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: extra) {
                urls.append(url)
            }
        }
        return urls
    }

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
