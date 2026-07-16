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

    private var filteredEntries: [HistoryEntry] {
        guard let filterCategory else { return entries }
        return entries.filter { $0.category == filterCategory }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableCompatView(
                        title: "No Receipts Yet",
                        message: "Receipts you submit will appear here."
                    )
                } else {
                    VStack(spacing: 0) {
                        categoryFilterRow
                        if filteredEntries.isEmpty {
                            Spacer()
                            ContentUnavailableCompatView(
                                title: "No Receipts",
                                message: "No receipts in \(filterCategory ?? "this category") yet."
                            )
                            Spacer()
                        } else {
                    List {
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
                }
            }
            .navigationTitle("Receipts")
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
                            showCategories = true
                        } label: {
                            Label("Manage Categories…", systemImage: "folder.badge.gearshape")
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
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

    private func delete(_ entry: HistoryEntry) {
        SubmissionStore.removeHistory(entry)
        try? LocalReceiptStore.deleteEntry(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink)
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
            ReceiptRow(entry: entry)
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

    var body: some View {
        HStack {
            Text(label)
                .font(font)
                .foregroundStyle(Theme.skyBlue)
                .padding(.leading, CGFloat(level) * 14)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.skyBlue)
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

    @State private var showPreview = false
    @State private var missingFileAlert = false
    @State private var missingCSVAlert = false

    private var isManualEntry: Bool { entry.receiptLink == SubmissionPipeline.manualEntryLabel }
    private var isScannedText: Bool { entry.receiptLink == SubmissionPipeline.scannedTextLabel }
    private var hasFile: Bool {
        !entry.receiptLink.isEmpty && !SubmissionPipeline.isPlaceholderLabel(entry.receiptLink)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    openCategoryCSV()
                } label: {
                    Text(entry.category)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 2.5)
                        .padding(.vertical, 0.25)
                        .background(Theme.skyBlueBright)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                Text(entry.vendor.isEmpty ? "Unknown vendor" : entry.vendor)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !entry.amount.isEmpty {
                    Text("$\(entry.amount)")
                        .font(.subheadline.weight(.bold))
                }
            }
            if isManualEntry {
                HStack {
                    Spacer()
                    Label("Entered manually", systemImage: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if isScannedText {
                HStack {
                    Spacer()
                    Label("Scanned text", systemImage: "text.viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if hasFile {
                HStack {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Theme.skyBlue)
                }
            }
        }
        .padding(.vertical, 2)
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
            if let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink) {
                ReceiptPreviewView(url: url)
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
