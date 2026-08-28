import SwiftUI

/// "Receipt Insights" — spending insights over the receipt history. The
/// numbers are computed deterministically (`SpendingInsightsService`); the
/// optional Apple Intelligence narrative below them is generated on-device
/// and never sees anything but the already-computed digest.
struct InsightsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("receiptsGroupByWorkDate") private var groupByWorkDate = false
    @State private var digest = SpendingDigest(
        months: [], currentMonthTotal: 0, currentMonthCount: 0, previousMonthTotal: 0,
        byCategory: [], byVendorType: [], topVendors: [], biggestReceipt: nil, unusualFlags: [])
    @State private var summaryText: String?
    @State private var observations: [String] = []
    @State private var isGenerating = false
    @State private var narrativeError: String?

    var body: some View {
        NavigationStack {
            Group {
                if digest.isEmpty {
                    ContentUnavailableCompatView(
                        title: "No Spending Yet",
                        message: "Once you've saved some receipts, monthly totals, category breakdowns, and an on-device AI summary will appear here.")
                } else {
                    insightsList
                }
            }
            .navigationTitle("Receipt Insights")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
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
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal")
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
        .onChange(of: groupByWorkDate) { _ in reload() }
    }

    private var insightsList: some View {
        List {
            Section("This Month") {
                LabeledRow(label: "Total", value: SpendingInsightsService.dollars(digest.currentMonthTotal))
                LabeledRow(label: "Receipts", value: "\(digest.currentMonthCount)")
                if digest.previousMonthTotal > 0 {
                    LabeledRow(label: "Last Month", value: SpendingInsightsService.dollars(digest.previousMonthTotal))
                }
            }

            if !digest.unusualFlags.isEmpty {
                Section("Worth a Look") {
                    ForEach(digest.unusualFlags, id: \.self) { flag in
                        Label(flag, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                }
            }

            Section("Monthly Totals") {
                // Newest first, same as the Receipts list.
                ForEach(digest.months.reversed()) { month in
                    LabeledRow(
                        label: SpendingInsightsService.monthLabel(month.monthStart),
                        value: SpendingInsightsService.dollars(month.total),
                        detail: "\(month.count) receipts")
                }
            }

            if !digest.byCategory.isEmpty {
                Section("By Category") {
                    ForEach(digest.byCategory) { row in
                        LabeledRow(label: row.label, value: SpendingInsightsService.dollars(row.total))
                    }
                }
            }

            if !digest.byVendorType.isEmpty {
                Section("By Business Type") {
                    ForEach(digest.byVendorType) { row in
                        LabeledRow(label: row.label, value: SpendingInsightsService.dollars(row.total))
                    }
                }
            }

            if !digest.topVendors.isEmpty {
                Section("Top Vendors") {
                    ForEach(digest.topVendors) { row in
                        LabeledRow(label: row.label, value: SpendingInsightsService.dollars(row.total))
                    }
                }
            }

            narrativeSection
        }
    }

    /// On-device AI summary. Additive only — everything above it is exact
    /// regardless of whether Apple Intelligence is available.
    @ViewBuilder
    private var narrativeSection: some View {
        Section {
            if let summaryText {
                Text(summaryText)
                    .font(.subheadline)
                ForEach(observations, id: \.self) { observation in
                    Label(observation, systemImage: "sparkle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Summarizing…").foregroundStyle(.secondary)
                }
            } else {
                Button(summaryText == nil ? "Summarize with Apple Intelligence" : "Regenerate Summary") {
                    generateNarrative()
                }
                .disabled(!isOnDeviceModelReady)
            }
        } header: {
            Text("AI Summary")
        } footer: {
            if let narrativeError {
                Text(narrativeError).foregroundStyle(.red)
            } else if !isOnDeviceModelReady {
                Text("Requires Apple Intelligence (iOS 26 or later with an eligible device). The totals above are exact and don't need it.")
            } else {
                Text("Written on-device from the totals above — nothing leaves your phone.")
            }
        }
    }

    private var isOnDeviceModelReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return FoundationModelsService.isModelReady }
        #endif
        return false
    }

    private func reload() {
        digest = SpendingInsightsService.buildDigest(groupByWorkDate: groupByWorkDate)
    }

    private func generateNarrative() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        narrativeError = nil
        isGenerating = true
        let digest = digest
        Task {
            defer { isGenerating = false }
            do {
                let draft = try await SpendingInsightsService.narrative(for: digest)
                summaryText = draft.summary
                observations = draft.observations
            } catch {
                narrativeError = error.localizedDescription
            }
        }
        #endif
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .foregroundStyle(Theme.skyBlueBright)
                    .fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
