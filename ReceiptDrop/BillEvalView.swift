#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Local copies — `SettingsView`'s equivalents are `private` to that file, and
/// this whole screen is DEBUG-only, so duplicating two trivial wrappers beats
/// widening their visibility for a build that never ships.
private struct EvalExportURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct EvalShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Phase 0 eval harness UI (see CHECK_A_BILL_ROADMAP.md) — runs every bundled
/// fixture bill through `BillItemizationService.itemize` and scores the result
/// against hand-verified ground truth.
///
/// DEBUG-only: this ships in no TestFlight or App Store build.
///
/// Because `itemize` dispatches on whatever provider is selected in Settings,
/// this screen scores *that* provider. Switching the AI Provider and re-running
/// is exactly the Azure-vs-Apple comparison Phase 0.5 calls for — no separate
/// code path, and no risk of the comparison drifting from the real pipeline.
struct BillEvalView: View {
    @State private var fixtures: [BillEvalFixture] = []
    @State private var summary: BillEvalSummary?
    @State private var isRunning = false
    @State private var progressText = ""
    @State private var loadError: String?
    @State private var exportURL: EvalExportURL?

    private var providerName: String { ExtractionSettings.provider.displayName }

    var body: some View {
        List {
            Section {
                LabeledContent("Provider", value: providerName)
                LabeledContent("Fixtures", value: "\(fixtures.count)")
                Button {
                    runAll()
                } label: {
                    HStack {
                        Text(isRunning ? "Running…" : "Run All Fixtures")
                        Spacer()
                        if isRunning { ProgressView() }
                    }
                    .accessibilityElement(children: .combine)
                }
                .disabled(isRunning || fixtures.isEmpty)
                if isRunning, !progressText.isEmpty {
                    Text(progressText).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Run")
            } footer: {
                Text("Scores whichever provider is selected in Settings. Switch providers and re-run to compare on identical bills.")
            }

            if let loadError {
                Section {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }

            if fixtures.isEmpty && loadError == nil {
                Section {
                    Text("No fixtures bundled yet. Add matching pairs — bill001.jpg + bill001.json — to the BillEvalFixtures/ folder in the repo, then rebuild. See that folder's README for the JSON shape.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                Section("Aggregate — \(summary.providerName)") {
                    metric("Item recall", summary.itemRecall)
                    metric("Item precision", summary.itemPrecision)
                    metric("Totals accuracy", summary.totalsAccuracy)
                    metric("Vendor accuracy", summary.vendorAccuracy)
                    LabeledContent("Bills scored", value: "\(summary.fixtureCount)")
                    if summary.erroredCount > 0 {
                        LabeledContent("Extraction errors", value: "\(summary.erroredCount)")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    LabeledContent("Missed items", value: "\(summary.missedTotal)")
                    LabeledContent("Wrong price", value: "\(summary.wrongPriceTotal)")
                    LabeledContent("Phantom items", value: "\(summary.phantomTotal)")
                } header: {
                    Text("Failure Buckets")
                } footer: {
                    Text("Largest bucket is the highest-ROI Phase 1 item to work on next.")
                }

                Section("Per Bill") {
                    ForEach(summary.results, id: \.fixtureName) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.fixtureName).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let error = result.errorMessage {
                                    Text("ERROR").font(.caption).foregroundStyle(.red)
                                        .help(error)
                                } else {
                                    Text("\(result.matchedCount)/\(result.truthItemCount)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(result.matchedCount == result.truthItemCount ? .green : .orange)
                                }
                            }
                            if let error = result.errorMessage {
                                Text(error).font(.caption2).foregroundStyle(.red)
                            } else {
                                Text("totals \(result.totalsCorrect)/\(result.totalsApplicable) · vendor \(result.vendorMatched ? "✓" : "✗") · wrong price \(result.wrongPriceCount) · phantom \(result.phantomCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !result.missedItemNames.isEmpty {
                                    Text("missed: \(result.missedItemNames.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if !result.phantomItemNames.isEmpty {
                                    Text("phantom: \(result.phantomItemNames.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Export CSV") { export(summary) }
                }
            }
        }
        .navigationTitle("Bill Eval")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFixtures)
        .sheet(item: $exportURL) { EvalShareSheet(url: $0.url) }
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        LabeledContent(label, value: String(format: "%.1f%%", value * 100))
    }

    private func loadFixtures() {
        do {
            fixtures = try BillEvalFixture.loadBundled()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func runAll() {
        isRunning = true
        summary = nil
        Task {
            var results: [BillEvalResult] = []
            for (index, fixture) in fixtures.enumerated() {
                await MainActor.run {
                    progressText = "\(index + 1) of \(fixtures.count) — \(fixture.name)"
                }
                do {
                    let extracted = try await BillItemizationService.itemize(data: fixture.imageData)
                    results.append(BillEvalScorer.score(
                        fixtureName: fixture.name, truth: fixture.truth, extracted: extracted))
                } catch {
                    results.append(BillEvalScorer.failure(
                        fixtureName: fixture.name, truth: fixture.truth,
                        error: error.localizedDescription))
                }
            }
            let built = BillEvalSummary(
                providerName: providerName, runDate: Date(), results: results)
            await MainActor.run {
                summary = built
                isRunning = false
                progressText = ""
            }
        }
    }

    private func export(_ summary: BillEvalSummary) {
        let stamp = ISO8601DateFormatter().string(from: summary.runDate)
            .replacingOccurrences(of: ":", with: "-")
        let name = "bill-eval-\(summary.providerName.replacingOccurrences(of: " ", with: "-"))-\(stamp).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try summary.csv().write(to: url, atomically: true, encoding: .utf8)
            exportURL = EvalExportURL(url: url)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One fixture pair: the bill photo plus its hand-verified expected result.
struct BillEvalFixture {
    let name: String
    let imageData: Data
    let truth: BillGroundTruth

    enum LoadError: LocalizedError {
        case decodingFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .decodingFailed(let file, let detail):
                return "Couldn't read \(file): \(detail)"
            }
        }
    }

    /// Pairs every bundled `*.json` with an image of the same base name.
    /// A JSON without a sibling image is skipped rather than treated as an
    /// error — that's the normal state while ground truth is being authored
    /// ahead of the photos being dropped in.
    static func loadBundled() throws -> [BillEvalFixture] {
        let jsonURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var fixtures: [BillEvalFixture] = []

        for jsonURL in jsonURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let base = jsonURL.deletingPathExtension().lastPathComponent
            // Only consider files following the fixture naming convention, so
            // this never trips over some unrelated bundled JSON.
            guard base.hasPrefix("bill") else { continue }

            let imageURL = ["jpg", "jpeg", "png", "heic"].lazy
                .compactMap { Bundle.main.url(forResource: base, withExtension: $0) }
                .first
            guard let imageURL, let imageData = try? Data(contentsOf: imageURL) else { continue }

            do {
                let truth = try JSONDecoder().decode(
                    BillGroundTruth.self, from: try Data(contentsOf: jsonURL))
                fixtures.append(BillEvalFixture(name: base, imageData: imageData, truth: truth))
            } catch {
                throw LoadError.decodingFailed(jsonURL.lastPathComponent, error.localizedDescription)
            }
        }
        return fixtures
    }
}
#endif
